// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SocialCuration} from "../src/nutbox/dapps/social-curation/SocialCuration.sol";
import {SocialCurationFactory} from "../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";
import {Community} from "../src/nutbox/Community.sol";
import {ICalculator} from "../src/interfaces/ICalculator.sol";

/**
 * @notice 对已 inject 的 SocialCuration 做 EIP-712 claim。
 *         HourlyTick 需至少跨过 1 个小时才有可领奖励；可用 --fork-url + 本脚本里的 WARP_HOURS。
 *
 * Env:
 *   PRIVATE_KEY          claimSigner（部署时 SCF 的 signer）
 *   POOL                 SocialCuration 地址
 *   CLAIM_AMOUNT         可选，默认取 pool 可提额度的一部分
 *   WARP_HOURS           可选，fork 模拟时 warp 小时数（broadcast 时勿设）
 *   BROADCAST_CLAIM=1    设为 1 时真正上链 claim
 *
 * Fork 验证（不上链）:
 *   WARP_HOURS=2 forge script script/ClaimImportSmoke.s.sol --fork-url $RPC -vvv
 *
 * 上链 claim（需已过整点小时）:
 *   BROADCAST_CLAIM=1 forge script script/ClaimImportSmoke.s.sol --rpc-url $RPC --broadcast --chain 46630 -vvv
 */
contract ClaimImportSmokeScript is Script {
    bytes32 constant CLAIM_TYPEHASH =
        keccak256("Claim(uint256 chainId,address pool,uint256 orderId,uint256 amount,address to,uint256 deadline)");

    address constant SCF = 0xd52624320654FBEA5F1f988d5F4E55B74C56e67D;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        address pool = vm.envAddress("POOL");

        uint256 warpHours = vm.envOr("WARP_HOURS", uint256(0));
        if (warpHours > 0) {
            vm.warp(block.timestamp + warpHours * 3600);
            console.log("Warped hours:", warpHours);
            console.log("Now:", block.timestamp);
        }

        SocialCuration curation = SocialCuration(payable(pool));
        Community community = Community(payable(curation.community()));
        address token = community.getCommunityToken();
        address claimSigner = SocialCurationFactory(SCF).claimSigner();
        require(signer == claimSigner, "PRIVATE_KEY is not claimSigner");

        ICalculator calc = ICalculator(community.rewardCalculator());
        uint256 head = calc.rewardHead();
        uint256 lastCursor = community.getLastRewardCursor();
        uint256 pending = calc.calculateReward(address(community), lastCursor, head);
        console.log("Community pending reward:", pending);
        console.log("Pool token bal:", IERC20(token).balanceOf(pool));
        console.log("Community token bal:", IERC20(token).balanceOf(address(community)));

        uint256 claimAmount = vm.envOr("CLAIM_AMOUNT", uint256(0));
        if (claimAmount == 0) {
            // 单池 100% 分配，领 pending 的一半
            claimAmount = pending / 2;
        }
        require(claimAmount > 0, "no claimable amount yet (wait >= 1 hour after inject)");

        uint256 orderId = vm.envOr("ORDER_ID", uint256(1));
        uint256 deadline = block.timestamp + 7 days;

        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, block.chainid, pool, orderId, claimAmount, signer, deadline)
        );
        bytes32 digest = _hashTypedDataV4(pool, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("Claim amount:", claimAmount);
        console.log("OrderId:", orderId);
        console.log("Deadline:", deadline);

        bool doBroadcast = vm.envOr("BROADCAST_CLAIM", false);
        if (doBroadcast) {
            vm.startBroadcast(pk);
            curation.claim{value: 0}(orderId, claimAmount, deadline, signature);
            vm.stopBroadcast();
            console.log("Claimed on-chain. User bal:", IERC20(token).balanceOf(signer));
        } else {
            uint256 balBefore = IERC20(token).balanceOf(signer);
            vm.prank(signer);
            curation.claim{value: 0}(orderId, claimAmount, deadline, signature);
            console.log("Simulated claim OK. Delta:", IERC20(token).balanceOf(signer) - balBefore);
        }
    }

    /// @dev 与 OZ EIP712("Nutbox SocialCuration","1") 一致
    function _hashTypedDataV4(address verifyingContract, bytes32 structHash) internal view returns (bytes32) {
        bytes32 typeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 domainSeparator = keccak256(
            abi.encode(
                typeHash,
                keccak256(bytes("Nutbox SocialCuration")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
