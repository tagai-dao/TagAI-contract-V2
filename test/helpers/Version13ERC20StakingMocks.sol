// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPoolFactory} from "../../src/interfaces/IPoolFactory.sol";

contract MockERC20StakingPool {
    address public immutable factory;
    address public immutable community;
    address public immutable stakeToken;
    string public name;

    constructor(address community_, string memory name_, address stakeToken_) {
        factory = msg.sender;
        community = community_;
        name = name_;
        stakeToken = stakeToken_;
    }

    function getFactory() external view returns (address) {
        return factory;
    }

    function getCommunity() external view returns (address) {
        return community;
    }

    function getUserStakedAmount(address) external pure returns (uint256) {
        return 0;
    }

    function getTotalStakedAmount() external pure returns (uint256) {
        return 0;
    }
}

/// @dev Test double for Nutbox's non-locking ERC20StakingFactory.
/// Its packed metadata is exactly one 20-byte ERC20 staking-token address.
contract MockERC20StakingFactory is IPoolFactory {
    event ERC20StakingCreated(address indexed pool, address indexed community, string name, address erc20Token);

    function createPool(address community, string memory name, bytes calldata meta) external returns (address pool) {
        require(msg.sender == community, "ONLY_COMMUNITY");
        require(meta.length == 20, "INVALID_META");
        address stakeToken;
        assembly {
            stakeToken := shr(96, calldataload(meta.offset))
        }
        require(stakeToken.code.length != 0, "INVALID_STAKE_TOKEN");
        pool = address(new MockERC20StakingPool(community, name, stakeToken));
        emit ERC20StakingCreated(pool, community, name, stakeToken);
    }
}
