// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeployBSCPump18Script} from "../../script/DeployBSCPump18.s.sol";

contract Pump18SaltHarness is DeployBSCPump18Script {
    function mine(bytes32 hash) external pure returns (bytes32 salt, address predicted, uint256 memoryGrowth) {
        uint256 beforePtr;
        uint256 afterPtr;
        assembly ("memory-safe") { beforePtr := mload(0x40) }
        (salt, predicted) = _mineSalt(hash);
        assembly ("memory-safe") { afterPtr := mload(0x40) }
        memoryGrowth = afterPtr - beforePtr;
    }
}

contract Pump18SaltTest is Test {
    function test_miningReusesBoundedMemoryAndReturnsExactCreate2Address() public {
        Pump18SaltHarness h = new Pump18SaltHarness();
        for (uint256 i; i < 3; ++i) {
            bytes32 hash = keccak256(abi.encode("V18 CREATE2 regression", i));
            (bytes32 salt, address predicted, uint256 growth) = h.mine(hash);
            address expected = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff), address(0x4e59b44847b379578588920cA78FbF26c0B4956C), salt, hash
                            )
                        )
                    )
                )
            );
            assertEq(predicted, expected);
            assertEq(uint16(uint160(predicted)), 0x0cc1);
            assertLe(growth, 256, "salt attempts must not grow memory");
        }
    }
}
