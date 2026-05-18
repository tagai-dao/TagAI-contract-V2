// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../../src/interfaces/IIPShare.sol";

/**
 * @title MockIPShare
 * @notice Minimal IPShare mock implementing only the functions Pump/Token/Hook need.
 */
contract MockIPShare is IIPShare {
    uint256 public createFee = 0.001 ether;
    mapping(address => bool) private _created;
    uint256 public totalCaptured;

    function createShare(address subject) external payable override {
        require(msg.value >= createFee, "Insufficient fee");
        _created[subject] = true;
    }

    function ipshareCreated(address subject) external view override returns (bool) {
        return _created[subject];
    }

    function valueCapture(address /* subject */) external payable override {
        totalCaptured += msg.value;
    }

    // ─── Stubs (not used in integration tests) ───

    function ipshareBalance(address, address) external pure override returns (uint256) { return 0; }
    function ipshareSupply(address) external pure override returns (uint256) { return 0; }
    function buyShares(address, address, uint256) external payable override returns (uint256) { return 0; }
    function sellShares(address, uint256, uint256) external pure override {}
    function getPendingProfits(address, address) external pure override returns (uint256) { return 0; }
    function getMaxStaker(address) external pure override returns (address, uint256) { return (address(0), 0); }
    function getBuyAmountByValue(uint256, uint256) external pure override returns (uint256) { return 0; }

    receive() external payable {}
}
