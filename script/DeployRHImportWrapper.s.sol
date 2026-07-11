// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ImportHelper} from "../src/helper/ImportHelper.sol";
import {TagAISwapWrapper} from "../src/helper/TagAISwapWrapper.sol";

/**
 * @title DeployRHImportWrapper
 * @notice 仅部署 ImportHelper + TagAISwapWrapper（复用已部署的 Nutbox / IPShare）。
 *
 * RH testnet (46630):
 *   FOUNDRY_PROFILE=rh_testnet forge script script/DeployRHImportWrapper.s.sol:DeployRHImportWrapperScript \
 *     --broadcast --slow --gas-estimate-multiplier 300 -vvv
 *
 * 可选覆盖（.env）:
 *   RH_COMMUNITY_FACTORY / RH_SCF / RH_COMMITTEE / RH_IPSHARE / RH_WETH / RH_FEE_ADDRESS
 */
contract DeployRHImportWrapperScript is Script {
    uint256 internal constant RH_TESTNET_CHAIN_ID = 46630;
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;

    // deployments/46630/addresses.json（既有栈）
    address internal constant TN_COMMUNITY_FACTORY = 0x3DC52C69C3C8be568372E16d50E9F3FEc796610c;
    address internal constant TN_SCF = 0xd52624320654FBEA5F1f988d5F4E55B74C56e67D;
    address internal constant TN_COMMITTEE = 0xa77253Ac630502A35A6FcD210A01f613D33ba7cD;
    address internal constant TN_IPSHARE = 0x33a1F7760f48c53E811aFaCa931B27124cafdC19;
    // Uniswap WETH9 on RH testnet
    address internal constant TN_WETH = 0x37E402B8081eFcE1D82A09a066512278006e4691;

    address internal constant MN_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // 显式 fork 测试网（勿用 .env 的 RH_RPC_URL——那边常是 mainnet）
        string memory rpc = "https://rpc.testnet.chain.robinhood.com";
        if (block.chainid == RH_MAINNET_CHAIN_ID) {
            rpc = "https://rpc.mainnet.chain.robinhood.com";
        }
        vm.createSelectFork(rpc);

        address communityFactory = vm.envOr("RH_COMMUNITY_FACTORY", TN_COMMUNITY_FACTORY);
        address scf = vm.envOr("RH_SCF", TN_SCF);
        address committee = vm.envOr("RH_COMMITTEE", TN_COMMITTEE);
        address ipshare = vm.envOr("RH_IPSHARE", TN_IPSHARE);
        address weth = vm.envOr("RH_WETH", _defaultWeth());
        address feeAddress = vm.envOr("RH_FEE_ADDRESS", deployer);

        console.log("=== Deploy ImportHelper + TagAISwapWrapper ===");
        console.log("Chain:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("CommunityFactory:", communityFactory);
        console.log("SCF:", scf);
        console.log("Committee:", committee);
        console.log("IPShare:", ipshare);
        console.log("WETH:", weth);
        console.log("feeAddress:", feeAddress);

        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(scf.code.length > 0, "SCF missing");
        require(committee.code.length > 0, "Committee missing");
        require(ipshare.code.length > 0, "IPShare missing");
        require(weth.code.length > 0, "WETH missing");

        vm.startBroadcast(pk);

        ImportHelper importHelper = new ImportHelper(communityFactory, scf, committee, ipshare);
        console.log("ImportHelper:", address(importHelper));

        TagAISwapWrapper wrapper = new TagAISwapWrapper(address(importHelper), ipshare, weth, feeAddress);
        console.log("TagAISwapWrapper:", address(wrapper));

        vm.stopBroadcast();

        _patchAddresses(block.chainid, address(importHelper), address(wrapper), weth);
        console.log("=== Done ===");
    }

    function _defaultWeth() internal view returns (address) {
        if (block.chainid == RH_MAINNET_CHAIN_ID) return MN_WETH;
        if (block.chainid == RH_TESTNET_CHAIN_ID) return TN_WETH;
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_testnet|rh_mainnet");
    }

    /// @dev 只更新 ImportHelper / TagAISwapWrapper / WETH 字段，保留其余已部署地址。
    function _patchAddresses(uint256 chainId, address importHelper, address wrapper, address weth) internal {
        string memory path = string.concat("deployments/", vm.toString(chainId), "/addresses.json");
        // 读已有 JSON 再写回关键键（简单拼接：整文件重写时合并已知常量）
        // 测试网：用已知栈地址 + 新地址
        if (chainId == RH_TESTNET_CHAIN_ID) {
            string memory json = string.concat(
                "{\n",
                '  "chainId": 46630,\n',
                '  "deployer": "0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611",\n',
                '  "Committee": "', vm.toString(TN_COMMITTEE), '",\n',
                '  "CommunityFactory": "', vm.toString(TN_COMMUNITY_FACTORY), '",\n',
                '  "HourlyTickCalculator": "0xf5D8d9402A4603bD67400500E62880eee91cF12C",\n',
                '  "SocialCurationFactory": "', vm.toString(TN_SCF), '",\n',
                '  "DFXStarScoreStakingFactory": "0xddbAba530728b5B8939d7fdDC334432490916e90",\n',
                '  "IPShare": "', vm.toString(TN_IPSHARE), '",\n',
                '  "PoolManager": "0x552815eF68E6eb418A3d65D0AA1043d93204F612",\n',
                '  "Pump": "0x8c701E56A178A9cEd02D731e057Af6E709A66A9e",\n',
                '  "TokenImplementation": "0x5Aa71794E2Fe52a0c554f5da7249Cc55B39B2b93",\n',
                '  "TagAISwapHook": "0x644dD54B13Bdf38AFF947cA2a46EE4b9144E60cC",\n',
                '  "WETH": "', vm.toString(weth), '",\n',
                '  "ImportHelper": "', vm.toString(importHelper), '",\n',
                '  "TagAISwapWrapper": "', vm.toString(wrapper), '"\n',
                "}\n"
            );
            vm.writeFile(path, json);
            console.log("Updated:", path);
        } else {
            console.log("Skip addresses.json patch for chain", chainId);
        }
    }
}
