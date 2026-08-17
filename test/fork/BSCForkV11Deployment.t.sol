// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkIndexBrokerNFT.t.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {IndexBrokerNFT} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import {IndexBrokerNFTAMM} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";
import {IndexBrokerNFTFactory} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {StonkBrokerRenderer} from "../../src/nutbox/dapps/index-broker-nft/StonkBrokerRenderer.sol";

interface IHistoricalIndexBrokerNFTFactory {
    function priceOracle() external view returns (address);
}

/**
 * @title BSCForkV11Deployment
 * @notice Post-deployment BSC fork smoke tests bound to the published V11 addresses.
 * @dev Inherits the full Index Broker lifecycle test, but replaces locally deployed
 *      Pump/Hook/Factory contracts with the exact BSC mainnet deployments.
 */
contract BSCForkV11Deployment is BSCForkIndexBrokerNFT {
    address internal constant PUMP_V11 = 0x8fEF5b4c0f761a0cc447800e3019B089ac306F28;
    address internal constant TOKEN_IMPLEMENTATION_V11 = 0xfD40C112F39D372786265a032C546D05Feec4D66;
    address internal constant HOOK_V11 = 0x9E38747072F326b4e614EfF6FdCA8529db090cc1;

    address internal constant INDEX_BROKER_FACTORY_V11 = 0xFa26Bf8d0830EC78ff7B2D959a1724f5E178392E;
    address internal constant INDEX_BROKER_POOL_TEMPLATE_V11 = 0xd4064239369b1A1dd78b1EcC5C1050F7A21c2303;
    address internal constant INDEX_BROKER_AMM_TEMPLATE_V11 = 0x1712C2BEdc1A9F5611D879e31caf9dfd1F665175;
    address internal constant INDEX_BROKER_PRICE_ORACLE_V11 = 0x85060fd888a936C77555F6D7899e46e102a697e3;
    address internal constant STONK_RENDERER_V11 = 0xd4B6120f566CDecD88b7Be6f994a6c7493F8a068;
    address internal constant STONK_FACE_RENDERER_V11 = 0x42f24CfAaaE018c24f44820bfA9C0694981551CC;
    address internal constant STONK_BODY_RENDERER_V11 = 0xA6269124844addc89A62CBb760b0b58a28977b42;
    address internal constant STONK_ACCESSORY_RENDERER_V11 = 0xc76717354091DcFb177c3B4e162aBC4Fca202D87;

    address internal constant V11_TARGET_OWNER = 0x871fb7006C5964B21695Ba20006021777A26146C;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    function _deployProductionStack() internal override {
        pump = Pump(payable(PUMP_V11));
        hook = TagAISwapHook(payable(HOOK_V11));
        calculator = HourlyTickCalculator(pump.getCalculator());
        router = new CLPoolManagerRouter(IVault(VAULT), ICLPoolManager(CL_POOL_MANAGER));
    }

    function _indexBrokerFactory() internal override returns (IndexBrokerNFTFactory factory) {
        factory = IndexBrokerNFTFactory(INDEX_BROKER_FACTORY_V11);

        if (!ICommittee(COMMITTEE).verifyContract(address(factory))) {
            vm.prank(Ownable(COMMITTEE).owner());
            ICommittee(COMMITTEE).adminAddContract(address(factory));
        }
    }

    function test_fork_v11PublishedDeploymentWiring() public onlyBscFork {
        assertGt(PUMP_V11.code.length, 0, "Pump code missing");
        assertEq(keccak256(PUMP_V11.code), keccak256(type(Pump).runtimeCode), "Pump bytecode");
        assertEq(keccak256(TOKEN_IMPLEMENTATION_V11.code), keccak256(type(Token).runtimeCode), "Token bytecode");
        assertEq(pump.tokenImplementation(), TOKEN_IMPLEMENTATION_V11, "Pump Token implementation");
        assertEq(pump.getIPShare(), IPSHARE, "Pump IPShare");
        assertEq(pump.getFeeReceiver(), FEE_RECEIVER, "Pump fee receiver");
        assertEq(pump.getPoolManager(), CL_POOL_MANAGER, "Pump pool manager");
        assertEq(pump.getVault(), VAULT, "Pump Vault");
        assertEq(pump.getHookAddress(), HOOK_V11, "Pump Hook");
        assertEq(pump.getCalculator(), address(calculator), "Pump calculator");
        assertEq(pump.nutboxCommunityFactory(), COMMUNITY_FACTORY, "Pump CommunityFactory");
        assertEq(pump.socialCurationFactory(), SOCIAL_CURATION_FACTORY, "Pump SocialCurationFactory");
        assertEq(pump.nutboxCommittee(), COMMITTEE, "Pump Committee");
        assertTrue(
            pump.owner() == V11_TARGET_OWNER || pump.pendingOwner() == V11_TARGET_OWNER,
            "Pump ownership not assigned to target"
        );

        assertEq(address(hook.pump()), PUMP_V11, "Hook Pump");
        assertEq(address(hook.clPoolManager()), CL_POOL_MANAGER, "Hook pool manager");
        assertEq(address(hook.vault()), VAULT, "Hook Vault");
        assertEq(hook.getHooksRegistrationBitmap(), TARGET_HOOK_BITMAP, "Hook bitmap");

        IndexBrokerNFTFactory factory = IndexBrokerNFTFactory(INDEX_BROKER_FACTORY_V11);
        assertEq(factory.communityFactory(), COMMUNITY_FACTORY, "Factory CommunityFactory");
        assertEq(factory.pump(), PUMP_V11, "Factory Pump");
        assertEq(factory.defaultRenderer(), STONK_RENDERER_V11, "Factory renderer");
        assertEq(factory.poolTemplate(), INDEX_BROKER_POOL_TEMPLATE_V11, "Factory Pool template");
        assertEq(factory.ammTemplate(), INDEX_BROKER_AMM_TEMPLATE_V11, "Factory AMM template");
        assertEq(
            IHistoricalIndexBrokerNFTFactory(address(factory)).priceOracle(),
            INDEX_BROKER_PRICE_ORACLE_V11,
            "Factory historical oracle"
        );
        assertEq(factory.basketRegistry(), BASKET_REGISTRY, "Factory BasketRegistry");
        assertEq(factory.basketSwapRouter(), BASKET_SWAP_ROUTER, "Factory BasketSwapRouter");
        assertEq(factory.indexV3Router(), PANCAKE_V3_SMART_ROUTER, "Factory V3 router");
        assertEq(factory.indexV3Fee(), BNB_USDT_V3_FEE, "Factory V3 fee");
        assertEq(factory.defaultIndexToken(), INDEX_TOKEN, "Factory index token");
        assertEq(factory.platformFeeBps(), 30, "Factory platform fee");
        assertTrue(
            factory.owner() == V11_TARGET_OWNER || factory.pendingOwner() == V11_TARGET_OWNER,
            "Factory ownership not assigned to target"
        );

        assertEq(
            keccak256(INDEX_BROKER_POOL_TEMPLATE_V11.code), keccak256(type(IndexBrokerNFT).runtimeCode), "Pool bytecode"
        );
        // The recorded AMM is the pre-route-registry deployment. Its address remains covered
        // by this historical smoke test until the unpublished NFT deployment record is replaced.
        assertGt(INDEX_BROKER_AMM_TEMPLATE_V11.code.length, 0, "AMM code missing");

        StonkBrokerRenderer renderer = StonkBrokerRenderer(STONK_RENDERER_V11);
        assertEq(address(renderer.faceRenderer()), STONK_FACE_RENDERER_V11, "Face renderer");
        assertEq(address(renderer.bodyRenderer()), STONK_BODY_RENDERER_V11, "Body renderer");
        assertEq(address(renderer.accessoryRenderer()), STONK_ACCESSORY_RENDERER_V11, "Accessory renderer");

        NutboxRouter historicalOracle = NutboxRouter(payable(INDEX_BROKER_PRICE_ORACLE_V11));
        assertEq(historicalOracle.wrappedNative(), WBNB, "Historical oracle WBNB");
        assertTrue(historicalOracle.allowedV2Factory(PANCAKE_V2_FACTORY), "Historical oracle V2 factory");
        assertTrue(historicalOracle.allowedV3Factory(PANCAKE_V3_FACTORY), "Historical oracle V3 factory");
        assertTrue(historicalOracle.allowedPancakeV4CLManager(CL_POOL_MANAGER), "Historical oracle V4 manager");
    }
}
