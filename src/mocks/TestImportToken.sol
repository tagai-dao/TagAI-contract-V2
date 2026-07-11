// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev 测试用可 mint ERC20，方便 ImportHelper / Nutbox inject / claim 联调
contract TestImportToken is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_, address recipient, uint256 initialMint)
        ERC20(name_, symbol_)
    {
        if (initialMint > 0) {
            _mint(recipient, initialMint);
        }
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
