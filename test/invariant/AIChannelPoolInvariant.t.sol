// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/ai-channel/AIChannelPool.sol";
import "../../src/nutbox/dapps/ai-channel/AIChannelPoolFactory.sol";

contract AIChannelInvariantToken is ERC20 {
    constructor() ERC20("Invariant AI Channel", "IAIC") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract AIChannelClaimHandler is Test {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CLAIM_TYPEHASH = keccak256(
        "Claim(uint256 chainId,address pool,bytes32 channelKey,bytes32 rewardPolicyHash,uint256 orderId,uint256 amount,address to,uint256 deadline)"
    );

    AIChannelPool public immutable pool;
    AIChannelInvariantToken public immutable token;
    uint256 private immutable signerKey;
    uint256 public nextOrder;

    constructor(AIChannelPool _pool, AIChannelInvariantToken _token, uint256 _signerKey) {
        pool = _pool;
        token = _token;
        signerKey = _signerKey;
    }

    function claim(uint256 rawAmount) external {
        uint256 available = token.balanceOf(address(pool));
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        uint256 orderId = nextOrder++;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Nutbox AIChannelPool"), keccak256("1"), block.chainid, address(pool))
        );
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_TYPEHASH,
                block.chainid,
                address(pool),
                pool.channelKey(),
                pool.rewardPolicyHash(),
                orderId,
                amount,
                address(this),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        pool.claim(orderId, amount, deadline, abi.encodePacked(r, s, v));
    }
}

contract AIChannelPoolInvariantTest is Test {
    uint256 private constant INITIAL_REWARDS = 1_000_000 ether;
    bytes32 private constant CHANNEL_KEY = keccak256("TagAgent");
    bytes32 private constant POLICY_HASH = keccak256("invariant-policy");

    AIChannelPool private pool;
    AIChannelInvariantToken private token;
    AIChannelClaimHandler private handler;

    function setUp() public {
        uint256 signerKey = 0xA11CE;
        Committee committee = new Committee(payable(makeAddr("fee-recipient")));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        CommunityFactory communityFactory = new CommunityFactory(address(committee));
        HourlyTickCalculator calculator = new HourlyTickCalculator(address(communityFactory));
        AIChannelPoolFactory factory = new AIChannelPoolFactory(address(communityFactory), vm.addr(signerKey));
        token = new AIChannelInvariantToken();
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(factory));

        Community community = Community(
            payable(communityFactory.createCommunity(
                    false, address(token), address(0), bytes(""), address(calculator), bytes("")
                ))
        );
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("TagAgent AI Channel", ratios, address(factory), abi.encode(CHANNEL_KEY, POLICY_HASH));
        pool = AIChannelPool(payable(community.activedPools(0)));
        token.transfer(address(pool), INITIAL_REWARDS);
        handler = new AIChannelClaimHandler(pool, token, signerKey);
        targetContract(address(handler));
    }

    function invariantRewardsAreConserved() public view {
        assertEq(token.balanceOf(address(pool)) + token.balanceOf(address(handler)), INITIAL_REWARDS);
        assertEq(pool.totalClaimed(), token.balanceOf(address(handler)));
    }

    function invariantPolicyIdentityAndVirtualStakeDoNotChange() public view {
        assertEq(pool.channelKey(), CHANNEL_KEY);
        assertEq(pool.rewardPolicyHash(), POLICY_HASH);
        assertEq(pool.getTotalStakedAmount(), 1 ether);
        assertEq(pool.getUserStakedAmount(address(pool)), 1 ether);
    }
}
