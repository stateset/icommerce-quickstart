// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../commerce/MultisigGuard.sol";
import "./MockSsUSD.sol";

contract MultisigGuardTest is Test {
    MultisigGuard guard;

    // Three distinct owners with known private keys so we can sign in-test.
    uint256 internal constant K1 = 0xA11CE;
    uint256 internal constant K2 = 0xB0B;
    uint256 internal constant K3 = 0xC0DE;

    address internal owner1;
    address internal owner2;
    address internal owner3;

    // A non-owner key for negative tests.
    uint256 internal constant K_BAD = 0xDEAD;
    address internal nonOwner;

    function setUp() public {
        owner1 = vm.addr(K1);
        owner2 = vm.addr(K2);
        owner3 = vm.addr(K3);
        nonOwner = vm.addr(K_BAD);

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;
        guard = new MultisigGuard(owners, 2);
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _sign(uint256 key, address target, uint256 value, bytes memory data, uint256 nonce_)
        internal
        view
        returns (bytes memory)
    {
        bytes32 ethHash =
            MessageHashUtils.toEthSignedMessageHash(guard.callHash(target, value, data, nonce_));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// Build a sorted-by-address signatures array for keys `(k1, k2)`.
    function _sortedSigs(
        uint256 k1,
        uint256 k2,
        address target,
        uint256 value,
        bytes memory data,
        uint256 nonce_
    ) internal view returns (bytes[] memory) {
        address a1 = vm.addr(k1);
        address a2 = vm.addr(k2);
        bytes[] memory sigs = new bytes[](2);
        if (a1 < a2) {
            sigs[0] = _sign(k1, target, value, data, nonce_);
            sigs[1] = _sign(k2, target, value, data, nonce_);
        } else {
            sigs[0] = _sign(k2, target, value, data, nonce_);
            sigs[1] = _sign(k1, target, value, data, nonce_);
        }
        return sigs;
    }

    // ─── construction validation ─────────────────────────────────────────

    function test_constructor_rejects_empty_owner_set() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(MultisigGuard.InvalidOwnerSet.selector);
        new MultisigGuard(empty, 1);
    }

    function test_constructor_rejects_more_than_32_owners() public {
        address[] memory too_many = new address[](33);
        for (uint256 i = 0; i < 33; i++) {
            too_many[i] = address(uint160(i + 1));
        }
        vm.expectRevert(MultisigGuard.InvalidOwnerSet.selector);
        new MultisigGuard(too_many, 1);
    }

    function test_constructor_rejects_zero_address_owner() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = address(0);
        vm.expectRevert(MultisigGuard.InvalidOwnerSet.selector);
        new MultisigGuard(owners, 1);
    }

    function test_constructor_rejects_duplicate_owner() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner1;
        vm.expectRevert(MultisigGuard.InvalidOwnerSet.selector);
        new MultisigGuard(owners, 1);
    }

    function test_constructor_rejects_zero_threshold() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        vm.expectRevert(MultisigGuard.InvalidThreshold.selector);
        new MultisigGuard(owners, 0);
    }

    function test_constructor_rejects_threshold_above_owners() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        vm.expectRevert(MultisigGuard.InvalidThreshold.selector);
        new MultisigGuard(owners, 3);
    }

    // ─── happy path: 2-of-3 executes a call ──────────────────────────────

    function test_execute_calls_target_with_two_signatures() public {
        MockSsUSD token = new MockSsUSD();
        // Set up a call the guard will make: mint 1000 tokens to address(0xBEEF)
        bytes memory data = abi.encodeWithSelector(token.mint.selector, address(0xBEEF), 1000);

        bytes[] memory sigs = _sortedSigs(K1, K2, address(token), 0, data, guard.nonce());
        guard.execute(address(token), 0, data, sigs);

        assertEq(token.balanceOf(address(0xBEEF)), 1000);
        assertEq(guard.nonce(), 1, "nonce must advance");
    }

    function test_execute_with_three_signatures_when_threshold_two_succeeds() public {
        MockSsUSD token = new MockSsUSD();
        bytes memory data = abi.encodeWithSelector(token.mint.selector, address(0xCAFE), 5);

        // Build 3 sorted sigs.
        bytes[] memory sigs = new bytes[](3);
        bytes memory s1 = _sign(K1, address(token), 0, data, guard.nonce());
        bytes memory s2 = _sign(K2, address(token), 0, data, guard.nonce());
        bytes memory s3 = _sign(K3, address(token), 0, data, guard.nonce());
        // Sort by recovered address ascending.
        address[3] memory addrs = [owner1, owner2, owner3];
        bytes[3] memory sigsByKey = [s1, s2, s3];
        // Bubble-sort 3 entries.
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (sigsByKey[i], sigsByKey[j]) = (sigsByKey[j], sigsByKey[i]);
                }
            }
        }
        sigs[0] = sigsByKey[0];
        sigs[1] = sigsByKey[1];
        sigs[2] = sigsByKey[2];

        guard.execute(address(token), 0, data, sigs);
        assertEq(token.balanceOf(address(0xCAFE)), 5);
    }

    // ─── rejection paths ─────────────────────────────────────────────────

    function test_execute_reverts_with_one_signature_when_threshold_two() public {
        MockSsUSD token = new MockSsUSD();
        bytes memory data = abi.encodeWithSelector(token.mint.selector, address(0xBEEF), 1);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(K1, address(token), 0, data, guard.nonce());
        vm.expectRevert(abi.encodeWithSelector(MultisigGuard.InsufficientSignatures.selector, 1, 2));
        guard.execute(address(token), 0, data, sigs);
    }

    function test_execute_reverts_when_signature_from_non_owner() public {
        MockSsUSD token = new MockSsUSD();
        bytes memory data = abi.encodeWithSelector(token.mint.selector, address(0xBEEF), 1);
        // Use a non-owner key in place of K2 — recovered signer will not be in isOwner.
        bytes[] memory sigs = _sortedSigs(K1, K_BAD, address(token), 0, data, guard.nonce());
        vm.expectRevert(); // NotOwner(...) with dynamic address — match by selector below
        guard.execute(address(token), 0, data, sigs);
    }

    function test_execute_reverts_on_duplicate_signer_same_sig() public {
        MockSsUSD token = new MockSsUSD();
        bytes memory data = abi.encodeWithSelector(token.mint.selector, address(0xBEEF), 1);
        bytes memory s = _sign(K1, address(token), 0, data, guard.nonce());
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = s;
        sigs[1] = s;
        // Strict ascending fails when both recover to the same address.
        vm.expectRevert(); // DuplicateOrUnorderedSigner(...)
        guard.execute(address(token), 0, data, sigs);
    }

    function test_execute_reverts_on_out_of_order_signatures() public {
        MockSsUSD token = new MockSsUSD();
        bytes memory data = abi.encodeWithSelector(token.mint.selector, address(0xBEEF), 1);
        // Force two valid sigs in DESCENDING address order — should fail.
        bytes memory sA = _sign(K1, address(token), 0, data, guard.nonce());
        bytes memory sB = _sign(K2, address(token), 0, data, guard.nonce());
        bytes[] memory sigs = new bytes[](2);
        if (owner1 < owner2) {
            sigs[0] = sB;
            sigs[1] = sA;
        } else {
            sigs[0] = sA;
            sigs[1] = sB;
        }
        vm.expectRevert(); // DuplicateOrUnorderedSigner(...)
        guard.execute(address(token), 0, data, sigs);
    }

    // ─── replay & isolation ──────────────────────────────────────────────

    function test_execute_bumps_nonce_so_old_sigs_cannot_replay() public {
        MockSsUSD token = new MockSsUSD();
        bytes memory data = abi.encodeWithSelector(token.mint.selector, address(0xBEEF), 1);
        uint256 startNonce = guard.nonce();
        bytes[] memory sigs = _sortedSigs(K1, K2, address(token), 0, data, startNonce);

        guard.execute(address(token), 0, data, sigs);
        // Same payload again → nonce is now startNonce+1, recovered hash differs,
        // so the same sigs no longer recover to a valid (signer, ethHash) pair.
        // We expect either NotOwner (recovered == random) or DuplicateOrUnorderedSigner.
        vm.expectRevert();
        guard.execute(address(token), 0, data, sigs);
    }

    function test_signatures_for_one_guard_cannot_be_used_on_another() public {
        // Deploy a sibling guard with the same owner set + threshold. Same
        // chainid, different `address(this)` — callHash() must differ.
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;
        MultisigGuard other = new MultisigGuard(owners, 2);

        MockSsUSD token = new MockSsUSD();
        bytes memory data = abi.encodeWithSelector(token.mint.selector, address(0xBEEF), 1);
        // Sign against the FIRST guard.
        bytes[] memory sigs = _sortedSigs(K1, K2, address(token), 0, data, 0);

        // Submit to the SECOND guard — recovery yields a different address.
        vm.expectRevert();
        other.execute(address(token), 0, data, sigs);
    }

    // ─── failure bubbling ────────────────────────────────────────────────

    function test_execute_reverts_when_target_call_reverts() public {
        // Target call that always reverts: call a non-existent selector on a token.
        MockSsUSD token = new MockSsUSD();
        bytes memory data = abi.encodeWithSignature("doesNotExist()");
        bytes[] memory sigs = _sortedSigs(K1, K2, address(token), 0, data, guard.nonce());
        vm.expectRevert(); // CallFailed
        guard.execute(address(token), 0, data, sigs);
    }

    // ─── views ───────────────────────────────────────────────────────────

    function test_getOwners_returns_constructor_order() public view {
        address[] memory got = guard.getOwners();
        assertEq(got.length, 3);
        assertEq(got[0], owner1);
        assertEq(got[1], owner2);
        assertEq(got[2], owner3);
        assertEq(guard.ownersCount(), 3);
    }

    function test_isOwner_membership_matches_constructor() public view {
        assertTrue(guard.isOwner(owner1));
        assertTrue(guard.isOwner(owner2));
        assertTrue(guard.isOwner(owner3));
        assertFalse(guard.isOwner(nonOwner));
        assertFalse(guard.isOwner(address(0)));
    }
}
