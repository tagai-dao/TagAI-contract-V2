// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../src/helper/ImportHelperV2.sol";
import "../src/helper/ImportedTokenSwapWrapper.sol";

interface IRHImportMulticall {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }
    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory);
}

/// @notice Deploys only the helper; Wrapper registrar activation remains an owner/Safe transaction.
contract DeployRHImportHelperV2 is Script {
    address public constant OLD_HELPER = 0xD0baaF8D314b0C6AB6bebd24ddbC86157c9c7b09;
    address public constant WRAPPER = 0x53e65DE68A0eB7f3662579F44Eb9849Ae5cA44ab;
    address public constant COMMUNITY_FACTORY = 0x24328DccA1bA54EeE82e2993F021802e64290486;
    address public constant TRADE_FACTORY = 0x73cb7A6Ad01686659F72011eb952fBa53fe6212B;
    address public constant COMMITTEE = 0x7B0ddC305C32AAEbabc0FE372a4460e9903e95D0;
    address public constant CALCULATOR = 0x3DC52C69C3C8be568372E16d50E9F3FEc796610c;
    address public constant MULTICALL = 0xcA11bde05977b3631167028862bE2a173976CA11;
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @dev All deployed-contract getters execute in one Multicall at the selected fork block.
    function preflight() public view returns (address admin) {
        require(block.chainid == 4663, "RH mainnet only");
        require(MULTICALL.code.length > 0, "Multicall missing");
        require(COMMUNITY_FACTORY.code.length > 0, "Community factory missing");
        IRHImportMulticall.Call3[] memory calls = new IRHImportMulticall.Call3[](9);
        calls[0] = _call(WRAPPER, abi.encodeWithSignature("owner()"));
        calls[1] = _call(WRAPPER, abi.encodeWithSignature("registrar()"));
        calls[2] = _call(WRAPPER, abi.encodeWithSignature("wrappedNative()"));
        calls[3] = _call(OLD_HELPER, abi.encodeWithSignature("swapWrapper()"));
        calls[4] = _call(TRADE_FACTORY, abi.encodeWithSignature("communityFactory()"));
        calls[5] = _call(TRADE_FACTORY, abi.encodeWithSignature("claimSigner()"));
        calls[6] = _call(CALCULATOR, abi.encodeWithSignature("communityFactory()"));
        calls[7] = _call(COMMITTEE, abi.encodeWithSignature("verifyContract(address)", TRADE_FACTORY));
        calls[8] = _call(COMMITTEE, abi.encodeWithSignature("verifyContract(address)", CALCULATOR));
        (bool ok, bytes memory data) = MULTICALL.staticcall(abi.encodeCall(IRHImportMulticall.aggregate3, (calls)));
        require(ok, "Multicall failed");
        IRHImportMulticall.Result[] memory rows = abi.decode(data, (IRHImportMulticall.Result[]));
        require(rows.length == calls.length, "Incomplete Multicall");
        for (uint256 i; i < rows.length; ++i) {
            require(rows[i].success, "Required read failed");
        }
        admin = abi.decode(rows[0].returnData, (address));
        require(admin != address(0), "Wrapper owner missing");
        require(abi.decode(rows[1].returnData, (address)) == OLD_HELPER, "Registrar already changed");
        require(abi.decode(rows[2].returnData, (address)) == WETH, "Wrong wrapped native");
        require(abi.decode(rows[3].returnData, (address)) == WRAPPER, "Old helper wrapper mismatch");
        require(abi.decode(rows[4].returnData, (address)) == COMMUNITY_FACTORY, "Trade factory mismatch");
        require(abi.decode(rows[5].returnData, (address)) != address(0), "Claim signer missing");
        require(abi.decode(rows[6].returnData, (address)) == COMMUNITY_FACTORY, "Calculator factory mismatch");
        require(abi.decode(rows[7].returnData, (bool)), "Trade factory not allowed");
        require(abi.decode(rows[8].returnData, (bool)), "Calculator not allowed");
    }

    function _call(address target, bytes memory data) private pure returns (IRHImportMulticall.Call3 memory) {
        return IRHImportMulticall.Call3(target, false, data);
    }

    function run() external returns (ImportHelperV2 helper) {
        address admin = preflight();
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        helper = new ImportHelperV2(COMMUNITY_FACTORY, TRADE_FACTORY, COMMITTEE, CALCULATOR, WRAPPER);
        vm.stopBroadcast();
        require(helper.owner() == admin, "Unexpected helper owner");
        require(helper.defaultPoolCount() == 1, "Unexpected defaults");
        console2.log("ImportHelperV2", address(helper));
        console2.log("ImportHelperV2 owner", admin);
        console2.log("Registrar activation target", WRAPPER);
        console2.logBytes(abi.encodeCall(ImportedTokenSwapWrapper.setRegistrar, (address(helper))));
    }
}
