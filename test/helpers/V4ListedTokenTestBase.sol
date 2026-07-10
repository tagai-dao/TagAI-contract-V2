// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {V4PumpTestBase} from "./V4PumpTestBase.sol";
import {Token} from "../../src/pump/Token.sol";

/// @dev V4 stack with a listed token ready for Hook / pool tests.
abstract contract V4ListedTokenTestBase is V4PumpTestBase {
    Token internal token;

    function setUp() public virtual override {
        super.setUp();
        if (!envReady) return;
        token = _createAndListToken("LISTED");
    }
}
