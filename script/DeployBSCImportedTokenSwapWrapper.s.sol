// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ICommunityFactory} from "../src/interfaces/ICommunityFactory.sol";
import {ImportHelper} from "../src/helper/ImportHelper.sol";
import {ImportedTokenSwapWrapper} from "../src/helper/ImportedTokenSwapWrapper.sol";

/**
 * @title DeployBSCImportedTokenSwapWrapper
 * @notice Replaces the BSC imported-token Wrapper and its immutable ImportHelper binding, then
 *         copies the existing NIULAI, Bicat and QQQB Community/deployer registrations.
 *
 * Dry run:
 *   FOUNDRY_PROFILE=bsc_mainnet forge script \
 *     script/DeployBSCImportedTokenSwapWrapper.s.sol:DeployBSCImportedTokenSwapWrapperScript \
 *     --rpc-url bsc -vvv
 *
 * Broadcast and verify (must be run by the user):
 *   FOUNDRY_PROFILE=bsc_mainnet forge script \
 *     script/DeployBSCImportedTokenSwapWrapper.s.sol:DeployBSCImportedTokenSwapWrapperScript \
 *     --rpc-url bsc --broadcast --slow --legacy --gas-price 50000000 \
 *     --gas-estimate-multiplier 150 --verify --etherscan-api-key "$BSCSCAN_API_KEY" -vvv
 *
 * IMPORTED_WRAPPER_OWNER must explicitly select the final Wrapper owner. The new Wrapper uses
 * Ownable2Step, so a target different from the deployer must later call acceptOwnership().
 * This script deliberately does not edit deployments/56/version11.json; record only confirmed
 * broadcast addresses and transaction hashes.
 */
contract DeployBSCImportedTokenSwapWrapperScript is Script {
    string internal constant VERSION11_PATH = "deployments/56/version11.json";

    address internal constant NIULAI = 0xBEEA1D618e533a387D941F58a7d4c9b7bD377777;
    address internal constant BICAT = 0xDBc6333a7D8bCd95f96641EDA4D095E69F207777;
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;

    struct HistoricalBinding {
        address token;
        address community;
        address deployer;
        uint256 pendingTokenFee;
    }

    address internal committee;
    address internal communityFactory;
    address internal socialCurationFactory;
    address internal hourlyTickCalculator;
    address internal nutboxRouter;
    address internal feeReceiver;
    address internal ipshare;
    ImportedTokenSwapWrapper internal previousWrapper;

    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        _loadVersion11();

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        require(vm.envExists("IMPORTED_WRAPPER_OWNER"), "IMPORTED_WRAPPER_OWNER must be explicit");
        address targetOwner = vm.envAddress("IMPORTED_WRAPPER_OWNER");
        require(targetOwner != address(0), "Wrapper owner missing");

        _validateDependencies();
        HistoricalBinding[3] memory bindings = _loadHistoricalBindings();

        console2.log("=== BSC Imported Token Wrapper Deploy ===");
        console2.log("Deployment record", VERSION11_PATH);
        console2.log("Deployer", deployer);
        console2.log("Target owner", targetOwner);
        console2.log("Previous Wrapper", address(previousWrapper));
        _logBindings(bindings);

        vm.startBroadcast(privateKey);

        ImportedTokenSwapWrapper wrapper = new ImportedTokenSwapWrapper(nutboxRouter, feeReceiver, ipshare);
        ImportHelper helper = new ImportHelper(
            communityFactory, socialCurationFactory, committee, hourlyTickCalculator, address(wrapper)
        );
        wrapper.setRegistrar(address(helper));

        for (uint256 i; i < bindings.length; ++i) {
            wrapper.registerImportedToken(bindings[i].token, bindings[i].community, bindings[i].deployer);
        }

        if (targetOwner != deployer) wrapper.transferOwnership(targetOwner);

        vm.stopBroadcast();

        _validateDeployment(wrapper, helper, bindings, deployer, targetOwner);

        console2.log("=== Deployment simulation/broadcast complete ===");
        console2.log("ImportedTokenSwapWrapper", address(wrapper));
        console2.log("ImportHelper", address(helper));
        if (targetOwner != deployer) {
            console2.log("ACTION REQUIRED: target owner must accept Wrapper ownership", targetOwner);
        }
        console2.log("ACTION REQUIRED: update API/frontend Wrapper + ImportHelper addresses together");
        console2.log("ACTION REQUIRED: keep the previous Wrapper available until its pending fees are flushed");
        console2.log("ACTION REQUIRED: record only confirmed broadcast addresses and transaction hashes");
    }

    function _loadVersion11() internal {
        require(vm.exists(VERSION11_PATH), "deployments/56/version11.json missing");
        string memory json = vm.readFile(VERSION11_PATH);
        require(vm.parseJsonUint(json, ".version") == 11, "Expected deployment version 11");

        committee = vm.parseJsonAddress(json, ".Committee");
        communityFactory = vm.parseJsonAddress(json, ".CommunityFactory");
        socialCurationFactory = vm.parseJsonAddress(json, ".SocialCurationFactory");
        hourlyTickCalculator = vm.parseJsonAddress(json, ".HourlyTickCalculator");
        nutboxRouter = vm.parseJsonAddress(json, ".NutboxRouter");
        feeReceiver = vm.parseJsonAddress(json, ".FeeReceiver");
        ipshare = vm.parseJsonAddress(json, ".IPShare");
        previousWrapper = ImportedTokenSwapWrapper(payable(vm.parseJsonAddress(json, ".ImportedTokenSwapWrapper")));
    }

    function _validateDependencies() internal view {
        require(committee.code.length > 0, "Committee missing");
        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(socialCurationFactory.code.length > 0, "SocialCurationFactory missing");
        require(hourlyTickCalculator.code.length > 0, "HourlyTickCalculator missing");
        require(nutboxRouter.code.length > 0, "NutboxRouter missing");
        require(feeReceiver != address(0), "FeeReceiver missing");
        require(ipshare.code.length > 0, "IPShare missing");
        require(address(previousWrapper).code.length > 0, "Previous Wrapper missing");
        require(address(previousWrapper.nutboxRouter()) == nutboxRouter, "Previous NutboxRouter mismatch");
        require(previousWrapper.feeAddress() == feeReceiver, "Previous FeeReceiver mismatch");
        require(address(previousWrapper.ipshare()) == ipshare, "Previous IPShare mismatch");
    }

    function _loadHistoricalBindings() internal view returns (HistoricalBinding[3] memory bindings) {
        bindings[0] = _loadHistoricalBinding(NIULAI);
        bindings[1] = _loadHistoricalBinding(BICAT);
        bindings[2] = _loadHistoricalBinding(QQQB);
    }

    function _loadHistoricalBinding(address token) internal view returns (HistoricalBinding memory binding) {
        (bool registered, address community, address deployer) = previousWrapper.getImportedMarket(token);
        require(registered, "Historical token is not registered");
        require(token.code.length > 0, "Historical token missing");
        require(community.code.length > 0, "Historical Community missing");
        require(deployer != address(0), "Historical deployer missing");
        require(ICommunityFactory(communityFactory).createdCommunity(community), "CommunityFactory binding mismatch");
        require(ICommunity(community).getCommunityToken() == token, "Community token mismatch");
        require(
            ICommunity(community).rewardCalculator() == hourlyTickCalculator, "Community Reward Calculator mismatch"
        );

        binding = HistoricalBinding({
            token: token,
            community: community,
            deployer: deployer,
            pendingTokenFee: previousWrapper.pendingNutboxInjection(token)
        });
    }

    function _validateDeployment(
        ImportedTokenSwapWrapper wrapper,
        ImportHelper helper,
        HistoricalBinding[3] memory bindings,
        address deployer,
        address targetOwner
    ) internal view {
        require(address(wrapper).code.length > 0, "Wrapper deployment failed");
        require(address(helper).code.length > 0, "ImportHelper deployment failed");
        require(address(wrapper.nutboxRouter()) == nutboxRouter, "Wrapper NutboxRouter mismatch");
        require(wrapper.wrappedNative() == previousWrapper.wrappedNative(), "Wrapper wrapped native mismatch");
        require(wrapper.feeAddress() == feeReceiver, "Wrapper FeeReceiver mismatch");
        require(address(wrapper.ipshare()) == ipshare, "Wrapper IPShare mismatch");
        require(wrapper.registrar() == address(helper), "Wrapper registrar mismatch");
        require(!wrapper.paused(), "Wrapper unexpectedly paused");

        require(helper.communityFactory() == communityFactory, "Helper CommunityFactory mismatch");
        require(helper.socialCurationFactory() == socialCurationFactory, "Helper SocialCurationFactory mismatch");
        require(helper.committee() == committee, "Helper Committee mismatch");
        require(helper.hourlyTickCalculator() == hourlyTickCalculator, "Helper Calculator mismatch");
        require(address(helper.swapWrapper()) == address(wrapper), "Helper Wrapper mismatch");

        for (uint256 i; i < bindings.length; ++i) {
            (bool registered, address community, address historicalDeployer) =
                wrapper.getImportedMarket(bindings[i].token);
            require(registered, "New Wrapper registration missing");
            require(community == bindings[i].community, "New Wrapper Community mismatch");
            require(historicalDeployer == bindings[i].deployer, "New Wrapper deployer mismatch");
            require(wrapper.pendingNutboxInjection(bindings[i].token) == 0, "New Wrapper pending fee is not zero");
        }

        require(wrapper.owner() == deployer, "Unexpected Wrapper owner");
        if (targetOwner == deployer) {
            require(wrapper.pendingOwner() == address(0), "Unexpected pending owner");
        } else {
            require(wrapper.pendingOwner() == targetOwner, "Wrapper ownership handover missing");
        }
    }

    function _logBindings(HistoricalBinding[3] memory bindings) internal pure {
        string[3] memory names = [string("NIULAI"), string("Bicat"), string("QQQB")];
        for (uint256 i; i < bindings.length; ++i) {
            console2.log(names[i]);
            console2.log("  Token", bindings[i].token);
            console2.log("  Community", bindings[i].community);
            console2.log("  Deployer/dev", bindings[i].deployer);
            console2.log("  Previous Wrapper pending token fee", bindings[i].pendingTokenFee);
        }
    }
}
