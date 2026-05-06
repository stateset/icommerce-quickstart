// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../stablecoin/NAVOracle.sol";
import "../stablecoin/SSDC.sol";

/**
 * @title MockssUSD
 * @notice Minimal mock for NAVOracle testing
 */
contract MockssUSD {
    uint256 private _totalShares;

    function setTotalShares(uint256 shares) external {
        _totalShares = shares;
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }
}

/**
 * @title NAVOracleTest
 * @notice Unit tests for NAVOracle contract
 */
contract NAVOracleTest is Test {
    NAVOracle public oracle;
    MockssUSD public mockSsUSD;

    address public owner = address(0x1);
    address public attestor = address(0x2);
    address public attestor2 = address(0x3);
    address public unauthorized = address(0x100);

    uint256 constant MAX_STALENESS = 24 hours;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock SSDC
        mockSsUSD = new MockssUSD();

        // Deploy NAVOracle
        NAVOracle impl = new NAVOracle();
        oracle = NAVOracle(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(NAVOracle.initialize, (owner, attestor, MAX_STALENESS))
        )));

        // Set SSDC
        oracle.setSSDC(address(mockSsUSD));

        vm.stopPrank();
    }

    // =========================================================================
    // Initialization Tests
    // =========================================================================

    function test_Initialization() public view {
        assertEq(oracle.owner(), owner);
        assertTrue(oracle.authorizedAttestors(attestor));
        assertEq(oracle.maxStalenessSeconds(), MAX_STALENESS);
        assertEq(oracle.SSDC(), address(mockSsUSD));

        // Initial NAV should be $1.00
        assertEq(oracle.getCurrentNAVPerShare(), 1e18);
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        oracle.initialize(owner, attestor, MAX_STALENESS);
    }

    // =========================================================================
    // Attestation Tests
    // =========================================================================

    function test_AttestNAV() public {
        // Set total shares (simulates SSDC supply)
        mockSsUSD.setTotalShares(1000 * 1e18);

        vm.prank(attestor);
        oracle.attestNAV(
            1050 * 1e18,  // Total assets: $1050
            20240101,      // Report date
            bytes32("proof123")
        );

        INAVOracle.NAVReport memory report = oracle.getCurrentNAV();

        assertEq(report.totalAssets, 1050 * 1e18);
        assertEq(report.totalShares, 1000 * 1e18);
        assertEq(report.reportDate, 20240101);
        assertEq(report.attestor, attestor);

        // NAV per share: 1050 / 1000 = 1.05
        assertEq(report.navPerShare, 1.05e18);
    }

    function test_AttestNAVNoShares() public {
        // No shares = initial NAV
        mockSsUSD.setTotalShares(0);

        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        // Should use INITIAL_NAV_PER_SHARE
        assertEq(oracle.getCurrentNAVPerShare(), 1e18);
    }

    function test_AttestNAVMultipleTimes() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        // First attestation
        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        // Second attestation (later date)
        vm.prank(attestor);
        oracle.attestNAV(1010 * 1e18, 20240102, bytes32(0));

        assertEq(oracle.getCurrentNAVPerShare(), 1.01e18);
        assertEq(oracle.getHistoryCount(), 2);
    }

    function test_RevertAttestZeroAssets() public {
        vm.prank(attestor);
        vm.expectRevert(NAVOracle.InvalidTotalAssets.selector);
        oracle.attestNAV(0, 20240101, bytes32(0));
    }

    function test_RevertAttestOldDate() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        // First attestation
        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240102, bytes32(0));

        // Try to attest with older date
        vm.prank(attestor);
        vm.expectRevert(NAVOracle.ReportDateNotNew.selector);
        oracle.attestNAV(1010 * 1e18, 20240101, bytes32(0));
    }

    function test_RevertAttestSameDate() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        vm.prank(attestor);
        vm.expectRevert(NAVOracle.ReportDateNotNew.selector);
        oracle.attestNAV(1010 * 1e18, 20240101, bytes32(0));
    }

    function test_RevertUnauthorizedAttestor() public {
        vm.prank(unauthorized);
        vm.expectRevert(NAVOracle.NotAuthorizedAttestor.selector);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));
    }

    // =========================================================================
    // NAV Change Limit Tests
    // =========================================================================

    function test_RevertNAVIncreaseTooLarge() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        // First attestation
        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        // Try 10% increase (exceeds 5% limit)
        vm.prank(attestor);
        vm.expectRevert(NAVOracle.NAVChangeExceedsLimit.selector);
        oracle.attestNAV(1100 * 1e18, 20240102, bytes32(0));
    }

    function test_RevertNAVDecreaseTooLarge() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        // First attestation
        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        // Try 5% decrease (exceeds 1% allowed decrease)
        vm.prank(attestor);
        vm.expectRevert(NAVOracle.NAVChangeExceedsLimit.selector);
        oracle.attestNAV(950 * 1e18, 20240102, bytes32(0));
    }

    function test_AllowSmallNAVDecrease() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        // 0.5% decrease should be allowed
        vm.prank(attestor);
        oracle.attestNAV(995 * 1e18, 20240102, bytes32(0));

        assertApproxEqRel(oracle.getCurrentNAVPerShare(), 0.995e18, 0.001e18);
    }

    function test_AllowMaxNAVIncrease() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        // 5% increase is the limit
        vm.prank(attestor);
        oracle.attestNAV(1050 * 1e18, 20240102, bytes32(0));

        assertEq(oracle.getCurrentNAVPerShare(), 1.05e18);
    }

    // =========================================================================
    // Staleness Tests
    // =========================================================================

    function test_IsNAVFresh() public {
        // Fresh after initialization
        assertTrue(oracle.isNAVFresh());
    }

    function test_IsNAVStale() public {
        // Advance time past staleness
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        assertFalse(oracle.isNAVFresh());
    }

    function test_NAVFreshAfterAttestation() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        // Make stale
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        assertFalse(oracle.isNAVFresh());

        // Attest
        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        // Now fresh
        assertTrue(oracle.isNAVFresh());
    }

    // =========================================================================
    // History Tests
    // =========================================================================

    function test_NAVHistory() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        // Multiple attestations
        for (uint256 i = 1; i <= 5; i++) {
            vm.prank(attestor);
            oracle.attestNAV(1000 * 1e18 + i * 1e18, 20240100 + i, bytes32(0));
        }

        assertEq(oracle.getHistoryCount(), 5); // 5 attestations + initial = 5 historical

        INAVOracle.NAVReport[] memory history = oracle.getNAVHistory(3);
        assertEq(history.length, 3);
    }

    function test_NAVHistoryLimitedByCount() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        // Only 2 attestations
        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));

        vm.prank(attestor);
        oracle.attestNAV(1001 * 1e18, 20240102, bytes32(0));

        // Request 10 but only 2 in history (initial + first)
        INAVOracle.NAVReport[] memory history = oracle.getNAVHistory(10);
        assertEq(history.length, 2);
    }

    // =========================================================================
    // Admin Tests
    // =========================================================================

    function test_SetAuthorizedAttestor() public {
        vm.prank(owner);
        oracle.setAuthorizedAttestor(attestor2, true);

        assertTrue(oracle.authorizedAttestors(attestor2));

        // New attestor can attest
        mockSsUSD.setTotalShares(1000 * 1e18);
        vm.prank(attestor2);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));
    }

    function test_RevokeAttestor() public {
        vm.prank(owner);
        oracle.setAuthorizedAttestor(attestor, false);

        assertFalse(oracle.authorizedAttestors(attestor));

        // Revoked attestor cannot attest
        vm.prank(attestor);
        vm.expectRevert(NAVOracle.NotAuthorizedAttestor.selector);
        oracle.attestNAV(1000 * 1e18, 20240101, bytes32(0));
    }

    function test_SetMaxStaleness() public {
        vm.prank(owner);
        oracle.setMaxStaleness(48 hours);

        assertEq(oracle.maxStalenessSeconds(), 48 hours);
    }

    function test_SetssUSD() public {
        address newSsUSD = address(0x999);

        vm.prank(owner);
        oracle.setSSDC(newSsUSD);

        assertEq(oracle.SSDC(), newSsUSD);
    }

    function test_RevertNonOwnerAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        oracle.setAuthorizedAttestor(attestor2, true);

        vm.prank(unauthorized);
        vm.expectRevert();
        oracle.setMaxStaleness(48 hours);

        vm.prank(unauthorized);
        vm.expectRevert();
        oracle.setSSDC(address(0x999));
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    function test_GetTotalAssets() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        vm.prank(attestor);
        oracle.attestNAV(5000 * 1e18, 20240101, bytes32(0));

        assertEq(oracle.getTotalAssets(), 5000 * 1e18);
    }

    function test_GetLastReportDate() public {
        mockSsUSD.setTotalShares(1000 * 1e18);

        vm.prank(attestor);
        oracle.attestNAV(1000 * 1e18, 20240315, bytes32(0));

        assertEq(oracle.getLastReportDate(), 20240315);
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_AttestNAV(uint256 totalAssets, uint256 totalShares) public {
        // Bound to reasonable values
        totalAssets = bound(totalAssets, 1e18, 1e30);
        totalShares = bound(totalShares, 1e18, 1e30);

        mockSsUSD.setTotalShares(totalShares);

        vm.prank(attestor);
        oracle.attestNAV(totalAssets, 20240101, bytes32(0));

        uint256 expectedNav = (totalAssets * 1e18) / totalShares;
        assertEq(oracle.getCurrentNAVPerShare(), expectedNav);
    }

    function testFuzz_MaxStaleness(uint256 staleness) public {
        staleness = bound(staleness, 1 hours, 7 days);

        vm.prank(owner);
        oracle.setMaxStaleness(staleness);

        assertTrue(oracle.isNAVFresh());

        vm.warp(block.timestamp + staleness + 1);
        assertFalse(oracle.isNAVFresh());
    }
}
