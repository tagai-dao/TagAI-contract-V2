// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ImportedTokenSwapWrapper} from "../src/helper/ImportedTokenSwapWrapper.sol";

interface IImportedCommunityBinding {
    function owner() external view returns (address);
    function devFund() external view returns (address);
    function getCommunityToken() external view returns (address);
}

/// @notice One-time, idempotent migration of the 55 RH version-10 imported markets.
/// @dev The list was exported from the RH application database and every token/community binding,
///      owner, devFund and CommunityFactory provenance was checked on-chain before this script was written.
contract RegisterRHImportedMarketsScript is Script {
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;
    ImportedTokenSwapWrapper internal constant WRAPPER =
        ImportedTokenSwapWrapper(payable(0x53e65DE68A0eB7f3662579F44Eb9849Ae5cA44ab));

    uint256 internal registeredCount;
    uint256 internal skippedCount;

    function run() external {
        require(block.chainid == RH_MAINNET_CHAIN_ID, "RH mainnet only");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        require(WRAPPER.owner() == sender, "sender is not wrapper owner");

        vm.startBroadcast(pk);

        _register(
            WRAPPER,
            0x020bfC650A365f8BB26819deAAbF3E21291018b4,
            0xACf2dD03E250C6Be0D8D6784DEdd7B62C4878226,
            0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611
        ); // CASHCAT
        _register(
            WRAPPER,
            0xe0Cc2751249B797871b694AD3779755b7D4b1111,
            0xF04F1aA6F4a3c243376dEEb3770BB96eC9F34f61,
            0x2D2D4EA9bD726f73B0fEe6485e18c330d90f85EB
        ); // CASHDOG
        _register(
            WRAPPER,
            0xba01E973CBf66970EC9Dc72cF9981d0684a17777,
            0x6190eDc77131158166492F02Ee18b6680f66Fc17,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // BB
        _register(
            WRAPPER,
            0x1b0E319c6A659F002271B69dB8A7df2F911c153E,
            0x98a21c0FAeD90D0cBaf673CB323F25C7188f144b,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // GME
        _register(
            WRAPPER,
            0xe934e36A439C94017B64a3FecE66AF12099aBF50,
            0xd73FF4f8966eABD7E7d6102B3B9E830bfFE22968,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // STONKBROKER
        _register(
            WRAPPER,
            0xcaCB0e9caCcee63ec4d82952E561a291c68Bcb68,
            0x33CCaD4D62B61Bc6E6dAEC5c73A07e932CAf99Db,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // GG
        _register(
            WRAPPER,
            0xD5f1afEA47b1A9eab414D2ee740cF1d6d039E725,
            0xaBe8C25d22c5d31ec344AeDfecF07c7A5d2Fc885,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // microduck
        _register(
            WRAPPER,
            0x39dBED3a2bd333467115dE45665cC57F813C4571,
            0x0169c1d89d4c31c7A2e01EC185B67C64A9FEe757,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // PONS
        _register(
            WRAPPER,
            0x5317C0d077D2eEB639448939b930D49c4984B63B,
            0xB4a7e94afA8d80e8c2a8fb16a3c9619246376753,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // COPPERINU
        _register(
            WRAPPER,
            0xAc77646bcff9d52e99800534192E0290933F4094,
            0x96aCC8a2260D4Ba316958685966FDec6B987cD01,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // MARTIANS
        _register(
            WRAPPER,
            0x6245e67affA44a23077f0Ea7f981a8DC743a0c47,
            0x4b94971b941f30E2D01DAE3dAB2DcA5d892Eb0AE,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // FRONG
        _register(
            WRAPPER,
            0xc72F232a6869e6CF34dC06129AfFD07F8a2a246A,
            0xaF1f58Cbe676034a80AeE18cD916b77507c0626B,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // MANCER
        _register(
            WRAPPER,
            0xeE5576Fa1Bcaa380e591D01245f406f3f384eb01,
            0xb08D1A4361955Cef35Fcb35840B7f2E86fcB5852,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // DTF
        _register(
            WRAPPER,
            0x7b630F080807DF83908b4aDE46BA6396EE66b098,
            0x4d0CC05b1944650A5F2aF4963d6C852e58Fa5DcB,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // BLINK
        _register(
            WRAPPER,
            0xded852De9fe9bA9b6f27f39e8e81CF851A5C79cc,
            0x67E798FdE7D07cFF68e43b9bf50942a1ab430e39,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // ROBINCAT
        _register(
            WRAPPER,
            0x62073cA9e1A71413C300eB642220AD4785Ea7777,
            0x27B07e449f5afdC2ACaE0ba05341A22e4ca9948A,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // ROBIN
        _register(
            WRAPPER,
            0xbe98b75361935b18d688409424a869a4C3dC7401,
            0x9193DFF7598E13329A6528A069be4C6090322268,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // NUDES
        _register(
            WRAPPER,
            0xc32B91Fe216aF1B834dB02f33326E983Ad8Cf201,
            0xCbb5c38Ee132cb995EA00757e5a3d0891374070f,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // CAMELTOE
        _register(
            WRAPPER,
            0x12D5ee7917cA430073C3A638ee1e6f0648A98a01,
            0x136af26C4107a461D7B5eb5621c6d6aCf87CD60b,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // FATCOIN
        _register(
            WRAPPER,
            0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18,
            0x6aF2fde7Dc841a899b9dB144f4d0008d2c3f66dc,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // AI
        _register(
            WRAPPER,
            0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C,
            0x9aeB16911Dfb42A63E04718f07803770911c2a05,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // RDDT
        _register(
            WRAPPER,
            0x117cc2133c37B721F49dE2A7a74833232B3B4C0C,
            0x0f5C7BCEfdc9fD72c838cA188Cc615327D17Bc9b,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // SPY
        _register(
            WRAPPER,
            0x5e81213613b6B86EaB4c6c50d718d34359459786,
            0x9FC3a2eAfAD147542f0a25Ec33901AaA2291864d,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // TTWO
        _register(
            WRAPPER,
            0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,
            0x1b3Fc9fbeb0E65A101404B3d439397b81C52b87B,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // NVDA
        _register(
            WRAPPER,
            0xD5f3879160bc7c32ebb4dC785F8a4F505888de68,
            0xE6C6082e1cc04BBbF308bd54b167965E2f00260c,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // QQQ
        _register(
            WRAPPER,
            0x1D11f0496982706C5e14A514D4E79F2e6BdE4516,
            0xE5f2D4458afdc59af793ca554677F7A1AE42BDB9,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // DJT
        _register(
            WRAPPER,
            0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa,
            0xA0774906ae17Fa8C60fC5591aB87c3a5699e2BCC,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // SPCX
        _register(
            WRAPPER,
            0xfB5b5778d45AE47F15323fb59B666c655174A79C,
            0xdA0A7978D7e02FCD8Db5128aBE8a2e92448eD00a,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // HOODon
        _register(
            WRAPPER,
            0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e,
            0x02D558e8013ba69CfE38c07Bb216D1729F2D6Fa8,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // GLD
        _register(
            WRAPPER,
            0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9,
            0xACEeB117f373D035A2606CAef3028b11CC19Ad68,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // AAPL
        _register(
            WRAPPER,
            0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802,
            0xe78Fcc5DD8A8f821c86e956a61b36f0D11302094,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // RAM
        _register(
            WRAPPER,
            0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F,
            0xC379551e851B1C541bcE28661A53E7514f6C5088,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // QUOTRON
        _register(
            WRAPPER,
            0xe81880c1C5054245e036359f5c7be31606E79F56,
            0x723Ab2f035a56C171a1281e54eD5BC8809D3B104,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // JINQIAN
        _register(
            WRAPPER,
            0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3,
            0xC60ACB873ba1ba5eA5F902fDdB477a7CA1D70DC3,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // GOOGL
        _register(
            WRAPPER,
            0xF0C4BF4C582cb3836e98394b1d4e7B7281101bE8,
            0x2A8DFB0d7DB5b8054F0DeC3fFB14049a8256be48,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // RBLX
        _register(
            WRAPPER,
            0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2,
            0xbD3739542a534009e893F10Bf268d02D1117aE6D,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // COST
        _register(
            WRAPPER,
            0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c,
            0xBaFfB1037cf55ab5E9a470c10a2616cAadcA1afE,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // HOOKR
        _register(
            WRAPPER,
            0x9F2C82a2b5C40472A3c6Aa3d678C5858345EC71e,
            0x4003118Ed7dCE636E56D231245bda9f2E575F6d6,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // LIGMA
        _register(
            WRAPPER,
            0x32aC8C1D7672667D5EbdEa22935F7B06fC8D496f,
            0x6F9f765e0d15359359D9af77529BC087A4Bbb825,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // HOOD
        _register(
            WRAPPER,
            0x322F0929c4625eD5bAd873c95208D54E1c003b2d,
            0x87eA916eF603E852C54f2980455928F0f26F96CC,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // TSLA
        _register(
            WRAPPER,
            0xe8ffd7e24187F72afB08d75B1bb13088A989a791,
            0x337c7d48d3A5F5D5A72b66323Cc2E410E4718595,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // DELTA
        _register(
            WRAPPER,
            0x385b36Ff682Ab4C76E7c37A66b96aABC466471d5,
            0x6244254C645Ab3ef2eD4CB8aDAdcD307581519D0,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // POOLS
        _register(
            WRAPPER,
            0x5Cb6F181081301b44905F3ae15419112ecaBd8A6,
            0x70cF77633B27e0feD920eAFD1CcD213eDDdD2D85,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // PIPEDOG
        _register(
            WRAPPER,
            0xec262a75e413fAfD0dF80480274532C79D42da09,
            0x1caAb7B5a4f9A47a1f0a38c981f21e195D30E43d,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // MSTR
        _register(
            WRAPPER,
            0xC35968C7F5475bb03a43C7382526F4118E01C0de,
            0x1C5Ca0d9A9e8070941967f52285de44fCA0Ed805,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // VISTA
        _register(
            WRAPPER,
            0xf2915d1e3C1B0c769d0c756Ec43F1c1f6c99cD03,
            0xA79AF357Ea0323c446a55928d2b85B6e99B2CA80,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // ARROW
        _register(
            WRAPPER,
            0x62C71cd34a52c30d894419CBcc55Db2aFA8032eA,
            0x54feb0B1e58902330Ff9315852d0cc8071475076,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // YOLO
        _register(
            WRAPPER,
            0x0762C1708F0D23F86b29D6B857121FF7DF357506,
            0xc7AC5449C91C165B39829faC7A07eC0e5b665ebA,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // website
        _register(
            WRAPPER,
            0x4285267dbF14881D7DB9d279f2007Aa79e627964,
            0x2df9C258dac754aBF0aF30A255b625392D72ceDa,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // AXIOAI
        _register(
            WRAPPER,
            0x4a6Eec8A30b49d289B9Fc865Fd374b4D61eab8fB,
            0x5A372B2c2D21E160964FaC22D2230d7670C60772,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // Liluni
        _register(
            WRAPPER,
            0xB528a38eA684eD26ea0Eee9de5d222DA6228c10D,
            0x3c506Fc40109F3Aa5e2867dc1713259212C2aAE0,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // ROBLOXIANS
        _register(
            WRAPPER,
            0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5,
            0x135B1F492d53c960781773BC03A58Dfd540A0DA7,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // CRCL
        _register(
            WRAPPER,
            0x98096d17e191B3dA1d5f99a6D7b3584351b11E18,
            0xA11cEA165c92b0C4Da2452349EB6eA485987EE55,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // BONER
        _register(
            WRAPPER,
            0x20024E485c0B22b42855589700721b28320A7777,
            0x5580Cd17cF6c237f8dfb69cE6d4d260285768781,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // PRISM
        _register(
            WRAPPER,
            0x8F69Ff1BeC499C9b66c6Ea8Ce35e1C23535BdF77,
            0x7b3Fcfd9Cdfe29091a2074751f1F5925239D9856,
            0xcb3A8062935b1C3f2C8eA4965eD490623aa186AD
        ); // CATAMINE

        vm.stopBroadcast();

        console.log("Registered:", registeredCount);
        console.log("Skipped (already matching):", skippedCount);
        require(registeredCount + skippedCount == 55, "unexpected migration count");
    }

    function _register(ImportedTokenSwapWrapper wrapper, address token, address community, address deployer) internal {
        require(token.code.length > 0, "token has no code");
        require(community.code.length > 0, "community has no code");
        require(deployer != address(0), "zero deployer");

        IImportedCommunityBinding binding = IImportedCommunityBinding(community);
        require(binding.getCommunityToken() == token, "community token mismatch");
        require(binding.owner() == deployer, "community owner mismatch");
        require(binding.devFund() == deployer, "community devFund mismatch");

        (bool registered, address currentCommunity, address currentDeployer) = wrapper.getImportedMarket(token);
        if (registered) {
            require(currentCommunity == community && currentDeployer == deployer, "existing binding mismatch");
            skippedCount++;
            return;
        }

        wrapper.registerImportedToken(token, community, deployer);
        registeredCount++;
    }
}
