// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";

/**
 * @title MockVault
 * @notice Simplified Vault mock for PCS V4 integration testing.
 *         Supports lock/settle/take operations.
 */
contract MockVault {
    address public locker;

    // Track operations
    uint256 public takeCount;
    uint256 public settleCount;
    uint256 public lockCount;

    event TakeCalled(address currency, address to, uint256 amount);
    event SettleCalled(uint256 amount);
    event LockCalled(address caller);
    event SyncCalled(address currency);

    function lock(bytes calldata data) external returns (bytes memory) {
        locker = msg.sender;
        lockCount++;
        emit LockCalled(msg.sender);

        // Callback to the caller
        bytes memory result = ILockCallback(msg.sender).lockAcquired(data);

        locker = address(0);
        return result;
    }

    function take(Currency currency, address to, uint256 amount) external {
        takeCount++;
        address currencyAddr = Currency.unwrap(currency);
        emit TakeCalled(currencyAddr, to, amount);

        // For native ETH, transfer from vault balance
        if (currencyAddr == address(0)) {
            if (address(this).balance >= amount) {
                (bool success,) = to.call{value: amount}("");
                require(success, "MockVault: ETH transfer failed");
            }
        }
    }

    function settle() external payable returns (uint256) {
        settleCount++;
        emit SettleCalled(msg.value);
        return msg.value;
    }

    function settleFor(address /* recipient */) external payable returns (uint256) {
        settleCount++;
        emit SettleCalled(msg.value);
        return msg.value;
    }

    function sync(Currency currency) external {
        emit SyncCalled(Currency.unwrap(currency));
    }

    function getLocker() external view returns (address) {
        return locker;
    }

    function getUnsettledDeltasCount() external pure returns (uint256) {
        return 0;
    }

    function currencyDelta(address /* settler */, Currency /* currency */) external pure returns (int256) {
        return 0;
    }

    function isAppRegistered(address /* app */) external pure returns (bool) {
        return true;
    }

    function registerApp(address /* app */) external {}

    function reservesOfApp(address /* app */, Currency /* currency */) external pure returns (uint256) {
        return 0;
    }

    function getVaultReserve() external pure returns (Currency, uint256) {
        return (Currency.wrap(address(0)), 0);
    }

    function accountAppBalanceDelta(
        Currency /* currency0 */,
        Currency /* currency1 */,
        BalanceDelta /* delta */,
        address /* settler */,
        BalanceDelta /* hookDelta */,
        address /* hook */
    ) external {}

    function accountAppBalanceDelta(
        Currency /* currency0 */,
        Currency /* currency1 */,
        BalanceDelta /* delta */,
        address /* settler */
    ) external {}

    function accountAppBalanceDelta(Currency /* currency */, int128 /* delta */, address /* settler */) external {}

    function clear(Currency /* currency */, uint256 /* amount */) external {}

    function collectFee(Currency /* currency */, uint256 /* amount */, address /* recipient */) external {}

    function mint(address /* to */, Currency /* currency */, uint256 /* amount */) external {}

    function burn(address /* from */, Currency /* currency */, uint256 /* amount */) external {}

    receive() external payable {}
}
