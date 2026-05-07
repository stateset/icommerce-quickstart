// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../commerce/FxOracle.sol";

contract FxOracleTest is Test {
    FxOracle oracle;
    address operator = address(0xA);

    bytes32 constant EUR_SSUSD = keccak256(abi.encodePacked("EUR/ssUSD"));
    bytes32 constant JPY_SSUSD = keccak256(abi.encodePacked("JPY/ssUSD"));

    function setUp() public {
        oracle = new FxOracle(operator);
    }

    function test_post_then_convert() public {
        // 1 EUR = 1.0625 ssUSD → 1.0625e18
        vm.prank(operator);
        oracle.postQuote(EUR_SSUSD, 1.0625e18, 1 hours);

        (uint256 amountOut, uint256 rate,) = oracle.convert(EUR_SSUSD, 100e18);
        assertEq(rate, 1.0625e18);
        assertEq(amountOut, 106.25e18);
    }

    function test_convert_jpy_small_unit() public {
        // 1 JPY = 0.0064 ssUSD
        vm.prank(operator);
        oracle.postQuote(JPY_SSUSD, 0.0064e18, 1 hours);

        // 10,000 JPY → 64 ssUSD
        (uint256 amountOut,,) = oracle.convert(JPY_SSUSD, 10_000e18);
        assertEq(amountOut, 64e18);
    }

    function test_revert_stale_quote() public {
        vm.prank(operator);
        oracle.postQuote(EUR_SSUSD, 1.0625e18, 60); // 60s TTL

        vm.warp(block.timestamp + 61);
        vm.expectRevert(); // StaleQuote
        oracle.convert(EUR_SSUSD, 1e18);
    }

    function test_revert_unknown_pair() public {
        vm.expectRevert(FxOracle.UnknownPair.selector);
        oracle.convert(EUR_SSUSD, 1e18);
    }

    function test_revert_non_operator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(FxOracle.NotOperator.selector);
        oracle.postQuote(EUR_SSUSD, 1.0625e18, 1 hours);
    }

    function test_isFresh_lifecycle() public {
        assertFalse(oracle.isFresh(EUR_SSUSD));
        vm.prank(operator);
        oracle.postQuote(EUR_SSUSD, 1.0625e18, 60);
        assertTrue(oracle.isFresh(EUR_SSUSD));
        vm.warp(block.timestamp + 61);
        assertFalse(oracle.isFresh(EUR_SSUSD));
    }

    function test_pairId_helper() public view {
        bytes32 expected = keccak256(abi.encodePacked("EUR/ssUSD"));
        assertEq(oracle.pairId("EUR/ssUSD"), expected);
    }
}
