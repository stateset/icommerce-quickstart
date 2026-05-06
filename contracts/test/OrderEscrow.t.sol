// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../commerce/OrderEscrow.sol";
import "./MockSsUSD.sol";

contract OrderEscrowTest is Test {
    OrderEscrow escrow;
    MockSsUSD token;

    address operator = address(0xA);
    address buyer = address(0xB);
    address seller = address(0xC);
    address marketplace = address(0xDADA);

    bytes32 constant ORDER = keccak256("ORD-TEST");
    bytes32 constant RECEIPT = keccak256("delivered+receipt+v1");
    uint128 constant AMOUNT = 1_000_000_000; // 1,000 ssUSD (6dp)

    function setUp() public {
        escrow = new OrderEscrow(operator);
        token = new MockSsUSD();
        token.mint(buyer, AMOUNT * 10);
    }

    // ─── happy path ────────────────────────────────────────────────────────
    function test_lock_then_release_after_delivery() public {
        vm.prank(buyer);
        token.approve(address(escrow), AMOUNT);
        vm.prank(buyer);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(0)
        );
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(token.balanceOf(buyer), AMOUNT * 9);

        vm.prank(buyer); // buyer attests delivery; confirmationWindow=0 → instant
        escrow.markDelivered(ORDER, RECEIPT);

        vm.prank(seller);
        escrow.release(ORDER);
        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint256(escrow.statusOf(ORDER)), uint256(OrderEscrow.Status.Released));
    }

    // ─── operator attestation + confirmation window ────────────────────────
    function test_operator_delivers_buyer_window_blocks_release() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(2 days)
        );
        vm.stopPrank();

        vm.prank(operator);
        escrow.markDelivered(ORDER, RECEIPT);

        vm.prank(seller);
        vm.expectRevert(OrderEscrow.ConfirmationWindowOpen.selector);
        escrow.release(ORDER);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(seller);
        escrow.release(ORDER);
        assertEq(token.balanceOf(seller), AMOUNT);
    }

    // ─── refund on missed shipment ─────────────────────────────────────────
    function test_buyer_refund_after_deadline() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 1 days), uint64(0)
        );
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(OrderEscrow.DeadlineNotReached.selector);
        escrow.refund(ORDER);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(buyer);
        escrow.refund(ORDER);
        assertEq(token.balanceOf(buyer), AMOUNT * 10);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ─── safety: cannot lock twice with same id ────────────────────────────
    function test_revert_double_lock() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT * 2);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(0)
        );
        vm.expectRevert(OrderEscrow.OrderExists.selector);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(0)
        );
        vm.stopPrank();
    }

    // ─── dispute → operator resolves to seller ──────────────────────────────
    function test_dispute_resolved_to_seller() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(2 days)
        );
        vm.stopPrank();
        vm.prank(buyer);
        escrow.markDelivered(ORDER, RECEIPT);
        vm.prank(buyer);
        escrow.dispute(ORDER, keccak256("damaged"));
        assertEq(uint256(escrow.statusOf(ORDER)), uint256(OrderEscrow.Status.Disputed));

        // Seller cannot release while disputed
        vm.prank(seller);
        vm.expectRevert(OrderEscrow.OrderNotDelivered.selector);
        escrow.release(ORDER);

        // Only operator resolves
        vm.prank(operator);
        escrow.resolveDispute(ORDER, true);
        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(uint256(escrow.statusOf(ORDER)), uint256(OrderEscrow.Status.Released));
    }

    // ─── dispute → operator refunds buyer ──────────────────────────────────
    function test_dispute_resolved_to_buyer() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(0)
        );
        vm.stopPrank();
        vm.prank(buyer);
        escrow.markDelivered(ORDER, RECEIPT);
        vm.prank(buyer);
        escrow.dispute(ORDER, keccak256("never_arrived"));

        vm.prank(operator);
        escrow.resolveDispute(ORDER, false);
        assertEq(token.balanceOf(buyer), AMOUNT * 10);
        assertEq(uint256(escrow.statusOf(ORDER)), uint256(OrderEscrow.Status.Refunded));
    }

    // ─── safety: only buyer can dispute, only operator can resolve ─────────
    function test_revert_dispute_by_random() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(0)
        );
        vm.stopPrank();
        vm.prank(operator);
        escrow.markDelivered(ORDER, RECEIPT);

        vm.prank(address(0xDEAD));
        vm.expectRevert(OrderEscrow.NotAuthorized.selector);
        escrow.dispute(ORDER, keccak256("fake"));

        vm.prank(buyer);
        escrow.dispute(ORDER, keccak256("real"));

        vm.prank(seller);
        vm.expectRevert(OrderEscrow.NotAuthorized.selector);
        escrow.resolveDispute(ORDER, true);
    }

    // ─── marketplace fee split: 2% on release ──────────────────────────────
    function test_marketplace_fee_on_release() public {
        uint16 FEE_BPS = 200; // 2%
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lockWithFee(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(0),
            marketplace, FEE_BPS
        );
        vm.stopPrank();
        vm.prank(buyer);
        escrow.markDelivered(ORDER, RECEIPT);
        vm.prank(seller);
        escrow.release(ORDER);

        uint256 fee = (uint256(AMOUNT) * FEE_BPS) / 10000;
        assertEq(token.balanceOf(marketplace), fee, "marketplace got fee");
        assertEq(token.balanceOf(seller), AMOUNT - fee, "seller got rest");
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ─── marketplace fee: refund pays no fee ───────────────────────────────
    function test_no_fee_on_refund() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lockWithFee(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 1 days), uint64(0),
            marketplace, 500
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(buyer);
        escrow.refund(ORDER);

        assertEq(token.balanceOf(marketplace), 0, "marketplace gets nothing on refund");
        assertEq(token.balanceOf(buyer), AMOUNT * 10);
    }

    // ─── fee cap enforced ──────────────────────────────────────────────────
    function test_revert_fee_too_high() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(OrderEscrow.FeeTooHigh.selector, 1500, 1000));
        escrow.lockWithFee(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 1 days), uint64(0),
            marketplace, 1500 // > 10% MAX_FEE_BPS
        );
        vm.stopPrank();
    }

    // ─── yield sweep: surplus token in escrow goes to recipient ────────────
    function test_sweep_yield() public {
        // Lock 1000
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(0)
        );
        vm.stopPrank();
        assertEq(escrow.totalLocked(address(token)), AMOUNT);

        // Simulate yield arriving (e.g. someone airdrops, or a rebase happens).
        // For a vanilla ERC-20 we just mint extra tokens directly to escrow.
        token.mint(address(escrow), 50_000_000); // 50 ssUSD of "yield"

        // yieldAvailable should reflect the surplus, totalLocked unchanged
        assertEq(escrow.yieldAvailable(IERC20(address(token))), 50_000_000);

        // Operator sweeps to a treasury address
        address treasury = address(0xFEE);
        vm.prank(operator);
        escrow.sweepYield(IERC20(address(token)), treasury);
        assertEq(token.balanceOf(treasury), 50_000_000);
        assertEq(escrow.yieldAvailable(IERC20(address(token))), 0);

        // Release still works — the locked amount is intact
        vm.prank(buyer);
        escrow.markDelivered(ORDER, RECEIPT);
        vm.prank(seller);
        escrow.release(ORDER);
        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(escrow.totalLocked(address(token)), 0);
    }

    function test_revert_sweep_by_non_operator() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(OrderEscrow.NotAuthorized.selector);
        escrow.sweepYield(IERC20(address(token)), address(0xFEE));
    }

    // ─── safety: unauthorized release ──────────────────────────────────────
    function test_revert_release_by_random() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), AMOUNT);
        escrow.lock(
            ORDER, seller, IERC20(address(token)), AMOUNT,
            uint64(block.timestamp + 7 days), uint64(0)
        );
        vm.stopPrank();
        vm.prank(operator);
        escrow.markDelivered(ORDER, RECEIPT);

        vm.prank(address(0xDEAD));
        vm.expectRevert("not seller");
        escrow.release(ORDER);
    }
}
