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

contract AIChannelTestToken is ERC20 {
    constructor() ERC20("AI Channel Test", "AIT") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract AIChannelPoolTest is Test {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CLAIM_TYPEHASH = keccak256(
        "Claim(uint256 chainId,address pool,bytes32 channelKey,bytes32 rewardPolicyHash,uint256 orderId,uint256 amount,address to,uint256 deadline)"
    );
    bytes32 private constant CHANNEL_KEY = keccak256("TagAgent");
    bytes32 private constant POLICY_HASH = keccak256("approved-policy-document");

    uint256 private signerKey = 0xA11CE;
    address private signer;
    address private user;
    Committee private committee;
    CommunityFactory private communityFactory;
    HourlyTickCalculator private calculator;
    AIChannelPoolFactory private factory;
    AIChannelTestToken private token;
    Community private community;
    AIChannelPool private pool;

    function setUp() public {
        signer = vm.addr(signerKey);
        user = makeAddr("channel-user");
        committee = new Committee(payable(makeAddr("fee-recipient")));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        factory = new AIChannelPoolFactory(address(communityFactory), signer);
        token = new AIChannelTestToken();

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(factory));

        community = Community(
            payable(communityFactory.createCommunity(
                    false, address(token), address(0), bytes(""), address(calculator), bytes("")
                ))
        );

        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("TagAgent AI Channel", ratios, address(factory), abi.encode(CHANNEL_KEY, POLICY_HASH));
        pool = AIChannelPool(payable(community.activedPools(0)));
        token.transfer(address(pool), 1_000_000 ether);
        vm.deal(user, 10 ether);
    }

    function testFactoryBindsChannelAndPolicyMetadata() public view {
        assertEq(pool.factory(), address(factory));
        assertEq(pool.community(), address(community));
        assertEq(pool.channelKey(), CHANNEL_KEY);
        assertEq(pool.rewardPolicyHash(), POLICY_HASH);
        assertTrue(factory.createdPoolOfChannel(address(community), CHANNEL_KEY));
        assertEq(pool.getTotalStakedAmount(), 1 ether);
        assertEq(pool.getUserStakedAmount(address(pool)), 1 ether);
        assertEq(pool.getUserStakedAmount(user), 0);
    }

    function testClaimUsesPolicyBoundEIP712Authorization() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(user, 7, 250 ether, deadline, POLICY_HASH, signerKey);

        vm.prank(user);
        pool.claim(7, 250 ether, deadline, signature);

        assertEq(token.balanceOf(user), 250 ether);
        assertEq(pool.totalClaimed(), 250 ether);
        assertTrue(pool.claimedOrders(user, 7));
    }

    function testClaimRejectsWrongPolicyCommitment() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(user, 8, 100 ether, deadline, keccak256("different-policy"), signerKey);

        vm.expectRevert("Bad signature");
        vm.prank(user);
        pool.claim(8, 100 ether, deadline, signature);
    }

    function testClaimRejectsReplayExpiryAndWrongSigner() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(user, 9, 10 ether, deadline, POLICY_HASH, signerKey);
        vm.prank(user);
        pool.claim(9, 10 ether, deadline, signature);

        vm.expectRevert("Claimed");
        vm.prank(user);
        pool.claim(9, 10 ether, deadline, signature);

        vm.warp(deadline + 1);
        vm.expectRevert("Expired");
        vm.prank(user);
        pool.claim(10, 10 ether, deadline, signature);

        // Foundry rolls the warped timestamp back with the expected revert.
        // Use a value that is valid in either timestamp context.
        uint256 newDeadline = deadline + 2 days;
        bytes memory wrongSignature = _signature(user, 11, 10 ether, newDeadline, POLICY_HASH, 0xB0B);
        vm.expectRevert("Bad signature");
        vm.prank(user);
        pool.claim(11, 10 ether, newDeadline, wrongSignature);
    }

    function testSignerRotationInvalidatesOldAuthorizations() public {
        uint256 newKey = 0xCAFE;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory oldSignature = _signature(user, 12, 10 ether, deadline, POLICY_HASH, signerKey);
        factory.adminSetClaimSigner(vm.addr(newKey));

        vm.expectRevert("Bad signature");
        vm.prank(user);
        pool.claim(12, 10 ether, deadline, oldSignature);

        bytes memory newSignature = _signature(user, 12, 10 ether, deadline, POLICY_HASH, newKey);
        vm.prank(user);
        pool.claim(12, 10 ether, deadline, newSignature);
        assertEq(token.balanceOf(user), 10 ether);
    }

    function testFactoryRejectsDuplicateChannel() public {
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5_000;
        ratios[1] = 5_000;
        vm.expectRevert("Channel pool already exists");
        community.adminAddPool(
            "Duplicate", ratios, address(factory), abi.encode(CHANNEL_KEY, keccak256("another-policy"))
        );
    }

    function testFactoryRejectsMalformedOrZeroMetadata() public {
        Committee otherCommittee = new Committee(payable(makeAddr("other-fee")));
        otherCommittee.adminSetCreateCommunityFee(0);
        otherCommittee.adminSetCommunitySettingsFee(0);
        CommunityFactory otherCommunityFactory = new CommunityFactory(address(otherCommittee));
        HourlyTickCalculator otherCalculator = new HourlyTickCalculator(address(otherCommunityFactory));
        AIChannelPoolFactory otherFactory = new AIChannelPoolFactory(address(otherCommunityFactory), signer);
        otherCommittee.adminAddContract(address(otherCalculator));
        otherCommittee.adminAddContract(address(otherFactory));
        Community otherCommunity = Community(
            payable(otherCommunityFactory.createCommunity(
                    false, address(token), address(0), bytes(""), address(otherCalculator), bytes("")
                ))
        );
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;

        vm.expectRevert("Invalid meta length");
        otherCommunity.adminAddPool("Bad", ratios, address(otherFactory), hex"01");

        vm.expectRevert("Invalid channel key");
        otherCommunity.adminAddPool("Bad", ratios, address(otherFactory), abi.encode(bytes32(0), POLICY_HASH));

        vm.expectRevert("Invalid reward policy");
        otherCommunity.adminAddPool("Bad", ratios, address(otherFactory), abi.encode(CHANNEL_KEY, bytes32(0)));
    }

    function testFuzzClaimAmountAndOrder(uint128 rawAmount, uint256 orderId) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000 ether);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(user, orderId, amount, deadline, POLICY_HASH, signerKey);

        vm.prank(user);
        pool.claim(orderId, amount, deadline, signature);

        assertEq(token.balanceOf(user), amount);
        assertEq(pool.totalClaimed(), amount);
    }

    function _signature(
        address to,
        uint256 orderId,
        uint256 amount,
        uint256 deadline,
        bytes32 policyHash,
        uint256 privateKey
    ) private view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Nutbox AIChannelPool"), keccak256("1"), block.chainid, address(pool))
        );
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_TYPEHASH, block.chainid, address(pool), CHANNEL_KEY, policyHash, orderId, amount, to, deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
