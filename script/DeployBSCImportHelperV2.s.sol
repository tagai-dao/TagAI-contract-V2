// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../src/helper/ImportHelperV2.sol";
import "../src/helper/ImportedTokenSwapWrapper.sol";
import "../src/nutbox/Committee.sol";

/// @notice Deploys one new helper. Wrapper registrar activation is a separate owner/Safe call.
contract DeployBSCImportHelperV2 is Script {
    address constant OLD_HELPER = 0xcCB0f9a9db22cCC29fDd315180F89747118ec296;
    address constant WRAPPER = 0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F;
    address constant TRADE_FACTORY = 0x774A48Ba391a1013Ae43289eBdf871618822CD67;

    function run() external returns (ImportHelperV2 helper) {
        require(block.chainid == 56, "BSC only");
        ImportHelper old = ImportHelper(payable(OLD_HELPER));
        require(address(old.swapWrapper()) == WRAPPER, "Unexpected wrapper");
        require(Committee(payable(old.committee())).verifyContract(TRADE_FACTORY), "Trade factory not allowed");
        require(TradeCurationFactory(TRADE_FACTORY).communityFactory() == old.communityFactory(), "Factory mismatch");
        require(ImportedTokenSwapWrapper(payable(WRAPPER)).registrar() == OLD_HELPER, "Registrar already changed");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY_MAIN"));
        helper = new ImportHelperV2(
            old.communityFactory(), TRADE_FACTORY, old.committee(), old.hourlyTickCalculator(), WRAPPER
        );
        vm.stopBroadcast();
        require(helper.owner() == ImportedTokenSwapWrapper(payable(WRAPPER)).owner(), "Helper owner mismatch");
        require(helper.defaultPoolCount() == 1, "Unexpected defaults");
        console2.log("ImportHelperV2", address(helper));
        console2.log("ImportHelperV2 owner", helper.owner());
        console2.log("Registrar activation target", WRAPPER);
        console2.log("Registrar activation owner", ImportedTokenSwapWrapper(payable(WRAPPER)).owner());
        console2.logBytes(abi.encodeCall(ImportedTokenSwapWrapper.setRegistrar, (address(helper))));
    }
}
