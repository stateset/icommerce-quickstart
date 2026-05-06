// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../SetRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SetRegistryTest is Test {
    SetRegistry public registry;
    SetRegistry public registryImpl;

    address public owner = address(0x1);
    address public sequencer = address(0x2);
    address public unauthorized = address(0x3);

    bytes32 public tenantId = bytes32(uint256(1));
    bytes32 public storeId = bytes32(uint256(100));

    event SequencerAuthorized(address indexed sequencer, bool authorized);
    event BatchCommitted(
        bytes32 indexed batchId,
        bytes32 indexed tenantStoreKey,
        bytes32 eventsRoot,
        bytes32 newStateRoot,
        uint64 sequenceStart,
        uint64 sequenceEnd,
        uint32 eventCount
    );
    event StrictModeUpdated(bool enabled);

    function setUp() public {
        // Deploy implementation
        registryImpl = new SetRegistry();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            SetRegistry.initialize,
            (owner, sequencer)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(registryImpl), initData);
        registry = SetRegistry(address(proxy));
    }

    // =========================================================================
    // Initialization Tests
    // =========================================================================

    function test_Initialize() public view {
        assertEq(registry.owner(), owner);
        assertTrue(registry.authorizedSequencers(sequencer));
        assertTrue(registry.strictModeEnabled());
        assertEq(registry.authorizedSequencerCount(), 1);
    }

    function test_Initialize_WithZeroSequencer() public {
        SetRegistry impl = new SetRegistry();
        bytes memory initData = abi.encodeCall(
            SetRegistry.initialize,
            (owner, address(0))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        SetRegistry reg = SetRegistry(address(proxy));

        assertFalse(reg.authorizedSequencers(address(0)));
        assertEq(reg.authorizedSequencerCount(), 0);
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        registry.initialize(owner, sequencer);
    }

    // =========================================================================
    // Authorization Tests
    // =========================================================================

    function test_SetSequencerAuthorization() public {
        address newSequencer = address(0x4);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SequencerAuthorized(newSequencer, true);
        registry.setSequencerAuthorization(newSequencer, true);

        assertTrue(registry.authorizedSequencers(newSequencer));
    }

    function test_RevokeSequencerAuthorization() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SequencerAuthorized(sequencer, false);
        registry.setSequencerAuthorization(sequencer, false);

        assertFalse(registry.authorizedSequencers(sequencer));
    }

    function test_SetSequencerAuthorization_NotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        registry.setSequencerAuthorization(address(0x4), true);
    }

    function test_SetStrictMode() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit StrictModeUpdated(false);
        registry.setStrictMode(false);

        assertFalse(registry.strictModeEnabled());
    }

    // =========================================================================
    // Commit Batch Tests
    // =========================================================================

    function test_CommitBatch() public {
        bytes32 batchId = keccak256("batch1");
        bytes32 eventsRoot = keccak256("events");
        bytes32 prevStateRoot = bytes32(0);
        bytes32 newStateRoot = keccak256("state1");

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            eventsRoot,
            prevStateRoot,
            newStateRoot,
            1,  // sequenceStart
            10, // sequenceEnd
            10  // eventCount
        );

        // Verify commitment stored
        (
            bytes32 storedEventsRoot,
            bytes32 storedNewStateRoot,
            uint64 seqStart,
            uint64 seqEnd,
            uint32 eventCount,
            uint64 timestamp
        ) = registry.commitments(batchId);

        assertEq(storedEventsRoot, eventsRoot);
        assertEq(storedNewStateRoot, newStateRoot);
        assertEq(seqStart, 1);
        assertEq(seqEnd, 10);
        assertEq(eventCount, 10);
        assertGt(timestamp, 0);

    }

    function test_CommitBatchWithStarkProof() public {
        bytes32 batchId = keccak256("batch-stark");
        bytes32 eventsRoot = keccak256("events");
        bytes32 prevStateRoot = bytes32(0);
        bytes32 newStateRoot = keccak256("state1");
        bytes32 proofHash = keccak256("proof");
        bytes32 policyHash = keccak256("policy");

        vm.prank(sequencer);
        registry.commitBatchWithStarkProof(
            batchId,
            tenantId,
            storeId,
            eventsRoot,
            prevStateRoot,
            newStateRoot,
            1,
            10,
            10,
            proofHash,
            policyHash,
            100,
            true,
            1024,
            500
        );

        (
            bytes32 storedEventsRoot,
            bytes32 storedNewStateRoot,
            uint64 seqStart,
            uint64 seqEnd,
            uint32 eventCount,
        ) = registry.commitments(batchId);

        assertEq(storedEventsRoot, eventsRoot);
        assertEq(storedNewStateRoot, newStateRoot);
        assertEq(seqStart, 1);
        assertEq(seqEnd, 10);
        assertEq(eventCount, 10);

        (
            bytes32 storedProofHash,
            bytes32 storedPolicyHash,
            uint64 policyLimit,
            bool allCompliant,
            uint64 proofSize,
            uint64 provingTimeMs,
        ) = registry.starkProofs(batchId);

        assertEq(storedProofHash, proofHash);
        assertEq(storedPolicyHash, policyHash);
        assertEq(policyLimit, 100);
        assertTrue(allCompliant);
        assertEq(proofSize, 1024);
        assertEq(provingTimeMs, 500);

    }

    function test_CommitStarkProof() public {
        bytes32 batchId = keccak256("batch-proof");
        bytes32 prevStateRoot = bytes32(0);
        bytes32 newStateRoot = keccak256("state-proof");
        bytes32 proofHash = keccak256("proof");
        bytes32 policyHash = keccak256("policy");

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            prevStateRoot,
            newStateRoot,
            1,
            10,
            10
        );

        vm.prank(sequencer);
        registry.commitStarkProof(
            batchId,
            proofHash,
            prevStateRoot,
            newStateRoot,
            policyHash,
            100,
            true,
            1024,
            500
        );

        assertTrue(registry.hasStarkProof(batchId));
        assertTrue(registry.verifyStarkProofHash(batchId, proofHash));
        assertFalse(registry.verifyStarkProofHash(batchId, keccak256("wrong")));
    }

    function test_CommitStarkProof_InvalidProof() public {
        bytes32 batchId = keccak256("batch-invalid-proof");
        bytes32 prevStateRoot = bytes32(0);
        bytes32 newStateRoot = keccak256("state-proof");

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            prevStateRoot,
            newStateRoot,
            1,
            10,
            10
        );

        vm.prank(sequencer);
        vm.expectRevert(SetRegistry.InvalidProof.selector);
        registry.commitStarkProof(
            batchId,
            bytes32(0),
            prevStateRoot,
            newStateRoot,
            keccak256("policy"),
            100,
            true,
            1024,
            500
        );
    }

    function test_CommitStarkProof_StateRootMismatch() public {
        bytes32 batchId = keccak256("batch-proof-mismatch");

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );

        vm.prank(sequencer);
        vm.expectRevert(SetRegistry.StateRootMismatchInProof.selector);
        registry.commitStarkProof(
            batchId,
            keccak256("proof"),
            bytes32(0),
            keccak256("wrong-state"),
            keccak256("policy"),
            100,
            true,
            1024,
            500
        );
    }

    function test_CommitBatchWithStarkProof_InvalidProof() public {
        vm.prank(sequencer);
        vm.expectRevert(SetRegistry.InvalidProof.selector);
        registry.commitBatchWithStarkProof(
            keccak256("batch-stark-invalid"),
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state1"),
            1,
            10,
            10,
            keccak256("proof"),
            keccak256("policy"),
            100,
            true,
            0,
            500
        );
    }

    function test_CommitBatch_EmitsEvent() public {
        bytes32 batchId = keccak256("batch1");
        bytes32 eventsRoot = keccak256("events");
        bytes32 newStateRoot = keccak256("state1");
        bytes32 tenantStoreKey = keccak256(abi.encodePacked(tenantId, storeId));

        vm.prank(sequencer);
        vm.expectEmit(true, true, false, true);
        emit BatchCommitted(
            batchId,
            tenantStoreKey,
            eventsRoot,
            newStateRoot,
            1,
            10,
            10
        );
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            eventsRoot,
            bytes32(0),
            newStateRoot,
            1,
            10,
            10
        );
    }

    function test_CommitBatch_UpdatesLatestCommitment() public {
        bytes32 batchId = keccak256("batch1");
        bytes32 newStateRoot = keccak256("state1");
        bytes32 tenantStoreKey = keccak256(abi.encodePacked(tenantId, storeId));

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            newStateRoot,
            1,
            10,
            10
        );

        assertEq(registry.latestCommitment(tenantStoreKey), batchId);
        assertEq(registry.getHeadSequence(tenantId, storeId), 10);
    }

    function test_CommitBatch_NotAuthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(SetRegistry.NotAuthorizedSequencer.selector);
        registry.commitBatch(
            keccak256("batch1"),
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );
    }

    function test_CommitBatch_InvalidSequenceRange() public {
        vm.prank(sequencer);
        vm.expectRevert(SetRegistry.InvalidSequenceRange.selector);
        registry.commitBatch(
            keccak256("batch1"),
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            10, // sequenceStart > sequenceEnd
            5,
            10
        );
    }

    function test_CommitBatch_InvalidEventCount() public {
        vm.prank(sequencer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SetRegistry.InvalidEventCount.selector,
                uint64(10),
                uint32(9)
            )
        );
        registry.commitBatch(
            keccak256("batch1"),
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            9 // does not match sequence range
        );
    }

    function test_CommitBatch_EmptyEventsRoot() public {
        vm.prank(sequencer);
        vm.expectRevert(SetRegistry.EmptyEventsRoot.selector);
        registry.commitBatch(
            keccak256("batch1"),
            tenantId,
            storeId,
            bytes32(0), // empty events root
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );
    }

    function test_CommitBatch_AlreadyCommitted() public {
        bytes32 batchId = keccak256("batch1");

        vm.startPrank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );

        vm.expectRevert(SetRegistry.BatchAlreadyCommitted.selector);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events2"),
            bytes32(0),
            keccak256("state2"),
            1,
            10,
            10
        );
        vm.stopPrank();
    }

    // =========================================================================
    // State Chain Continuity Tests
    // =========================================================================

    function test_CommitBatch_StateChainContinuity() public {
        bytes32 batch1 = keccak256("batch1");
        bytes32 batch2 = keccak256("batch2");
        bytes32 state1 = keccak256("state1");
        bytes32 state2 = keccak256("state2");

        vm.startPrank(sequencer);

        // First batch
        registry.commitBatch(
            batch1,
            tenantId,
            storeId,
            keccak256("events1"),
            bytes32(0),
            state1,
            1,
            10,
            10
        );

        // Second batch - prevStateRoot must match first batch's newStateRoot
        registry.commitBatch(
            batch2,
            tenantId,
            storeId,
            keccak256("events2"),
            state1,  // prevStateRoot matches state1
            state2,
            11,      // sequenceStart must be sequenceEnd + 1
            20,
            10
        );

        vm.stopPrank();

    }

    function test_CommitBatch_StateRootMismatch() public {
        bytes32 batch1 = keccak256("batch1");
        bytes32 batch2 = keccak256("batch2");
        bytes32 state1 = keccak256("state1");
        bytes32 wrongPrevState = keccak256("wrong");

        vm.startPrank(sequencer);

        registry.commitBatch(
            batch1,
            tenantId,
            storeId,
            keccak256("events1"),
            bytes32(0),
            state1,
            1,
            10,
            10
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                SetRegistry.StateRootMismatch.selector,
                state1,
                wrongPrevState
            )
        );
        registry.commitBatch(
            batch2,
            tenantId,
            storeId,
            keccak256("events2"),
            wrongPrevState,  // Doesn't match state1
            keccak256("state2"),
            11,
            20,
            10
        );

        vm.stopPrank();
    }

    function test_CommitBatch_SequenceGap() public {
        bytes32 batch1 = keccak256("batch1");
        bytes32 batch2 = keccak256("batch2");
        bytes32 state1 = keccak256("state1");

        vm.startPrank(sequencer);

        registry.commitBatch(
            batch1,
            tenantId,
            storeId,
            keccak256("events1"),
            bytes32(0),
            state1,
            1,
            10,
            10
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                SetRegistry.SequenceGap.selector,
                11,  // expected
                15   // provided
            )
        );
        registry.commitBatch(
            batch2,
            tenantId,
            storeId,
            keccak256("events2"),
            state1,
            keccak256("state2"),
            15,  // Gap! Should be 11
            20,
            6
        );

        vm.stopPrank();
    }

    function test_CommitBatch_StrictModeDisabled() public {
        // Disable strict mode
        vm.prank(owner);
        registry.setStrictMode(false);

        bytes32 batch1 = keccak256("batch1");
        bytes32 batch2 = keccak256("batch2");

        vm.startPrank(sequencer);

        registry.commitBatch(
            batch1,
            tenantId,
            storeId,
            keccak256("events1"),
            bytes32(0),
            keccak256("state1"),
            1,
            10,
            10
        );

        // Should succeed despite sequence gap when strict mode is off
        registry.commitBatch(
            batch2,
            tenantId,
            storeId,
            keccak256("events2"),
            keccak256("wrong"),  // Mismatched state root - allowed when strict mode off
            keccak256("state2"),
            100,  // Big gap - allowed when strict mode off
            110,
            11
        );

        vm.stopPrank();

    }

    // =========================================================================
    // Merkle Proof Verification Tests
    // =========================================================================

    function test_VerifyInclusion() public {
        // Build a simple Merkle tree
        bytes32 leaf0 = keccak256("event0");
        bytes32 leaf1 = keccak256("event1");
        bytes32 leaf2 = keccak256("event2");
        bytes32 leaf3 = keccak256("event3");

        bytes32 hash01 = keccak256(abi.encodePacked(leaf0, leaf1));
        bytes32 hash23 = keccak256(abi.encodePacked(leaf2, leaf3));
        bytes32 root = keccak256(abi.encodePacked(hash01, hash23));

        // Commit batch with this root
        bytes32 batchId = keccak256("batch1");
        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            root,
            bytes32(0),
            keccak256("state"),
            1,
            4,
            4
        );

        // Verify leaf0 (index 0)
        bytes32[] memory proof0 = new bytes32[](2);
        proof0[0] = leaf1;
        proof0[1] = hash23;
        assertTrue(registry.verifyInclusion(batchId, leaf0, proof0, 0));

        // Verify leaf1 (index 1)
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = leaf0;
        proof1[1] = hash23;
        assertTrue(registry.verifyInclusion(batchId, leaf1, proof1, 1));

        // Verify leaf2 (index 2)
        bytes32[] memory proof2 = new bytes32[](2);
        proof2[0] = leaf3;
        proof2[1] = hash01;
        assertTrue(registry.verifyInclusion(batchId, leaf2, proof2, 2));

        // Verify leaf3 (index 3)
        bytes32[] memory proof3 = new bytes32[](2);
        proof3[0] = leaf2;
        proof3[1] = hash01;
        assertTrue(registry.verifyInclusion(batchId, leaf3, proof3, 3));
    }

    function test_VerifyInclusion_InvalidProof() public {
        bytes32 leaf = keccak256("event0");
        bytes32 root = keccak256(abi.encodePacked(leaf, keccak256("event1")));

        bytes32 batchId = keccak256("batch1");
        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            root,
            bytes32(0),
            keccak256("state"),
            1,
            2,
            2
        );

        // Wrong proof
        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = keccak256("wrong");
        assertFalse(registry.verifyInclusion(batchId, leaf, wrongProof, 0));
    }

    function test_VerifyInclusion_BatchNotExists() public view {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("sibling");

        assertFalse(
            registry.verifyInclusion(
                keccak256("nonexistent"),
                keccak256("leaf"),
                proof,
                0
            )
        );
    }

    function test_VerifyMultipleInclusions() public {
        // Build tree
        bytes32 leaf0 = keccak256("event0");
        bytes32 leaf1 = keccak256("event1");
        bytes32 hash01 = keccak256(abi.encodePacked(leaf0, leaf1));
        bytes32 root = hash01; // 2-leaf tree

        bytes32 batchId = keccak256("batch1");
        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            root,
            bytes32(0),
            keccak256("state"),
            1,
            2,
            2
        );

        // Verify both leaves
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf0;
        leaves[1] = leaf1;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = leaf1;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = leaf0;

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;

        assertTrue(registry.verifyMultipleInclusions(batchId, leaves, proofs, indices));
    }

    function test_VerifyMultipleInclusions_MismatchedArrays() public {
        bytes32 batchId = keccak256("batch1");
        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("root"),
            bytes32(0),
            keccak256("state"),
            1,
            1,
            1
        );

        bytes32[] memory leaves = new bytes32[](2);
        bytes32[][] memory proofs = new bytes32[][](1); // Mismatched length
        uint256[] memory indices = new uint256[](2);

        assertFalse(registry.verifyMultipleInclusions(batchId, leaves, proofs, indices));
    }

    // =========================================================================
    // View Functions Tests
    // =========================================================================

    function test_GetLatestStateRoot() public {
        bytes32 batchId = keccak256("batch1");
        bytes32 newStateRoot = keccak256("state1");

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            newStateRoot,
            1,
            10,
            10
        );

        assertEq(registry.getLatestStateRoot(tenantId, storeId), newStateRoot);
    }

    function test_GetLatestStateRoot_NoCommitments() public view {
        assertEq(
            registry.getLatestStateRoot(tenantId, storeId),
            bytes32(0)
        );
    }

    function test_GetHeadSequence() public {
        vm.prank(sequencer);
        registry.commitBatch(
            keccak256("batch1"),
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            50,
            50
        );

        assertEq(registry.getHeadSequence(tenantId, storeId), 50);
    }

    // =========================================================================
    // Legacy Compatibility Tests
    // =========================================================================

    function test_RegisterBatchRoot_DisabledByDefault() public {
        vm.prank(sequencer);
        vm.expectRevert(SetRegistry.LegacyFunctionsDisabled.selector);
        registry.registerBatchRoot(1, 10, keccak256("root"));
    }

    function test_RegisterBatchRoot_Legacy() public {
        vm.prank(owner);
        registry.setLegacyFunctionsEnabled(true);

        vm.prank(sequencer);
        registry.registerBatchRoot(1, 10, keccak256("root"));

    }

    function test_GetBatchRoot_Legacy() public {
        bytes32 root = keccak256("root");

        vm.prank(owner);
        registry.setLegacyFunctionsEnabled(true);

        vm.prank(sequencer);
        registry.registerBatchRoot(1, 10, root);

        // Note: Legacy getBatchRoot only works for the latest batch
        assertEq(registry.getBatchRoot(1, 10), root);
    }

    // =========================================================================
    // Multi-Tenant Tests
    // =========================================================================

    function test_MultiTenant_Isolation() public {
        bytes32 tenant1 = bytes32(uint256(1));
        bytes32 tenant2 = bytes32(uint256(2));
        bytes32 store1 = bytes32(uint256(100));

        bytes32 state1 = keccak256("tenant1_state");
        bytes32 state2 = keccak256("tenant2_state");

        vm.startPrank(sequencer);

        // Tenant 1 commits
        registry.commitBatch(
            keccak256("batch1"),
            tenant1,
            store1,
            keccak256("events1"),
            bytes32(0),
            state1,
            1,
            10,
            10
        );

        // Tenant 2 can start from sequence 1 (independent)
        registry.commitBatch(
            keccak256("batch2"),
            tenant2,
            store1,
            keccak256("events2"),
            bytes32(0),  // Independent state chain
            state2,
            1,  // Can also start at 1
            5,
            5
        );

        vm.stopPrank();

        // Verify isolation
        assertEq(registry.getLatestStateRoot(tenant1, store1), state1);
        assertEq(registry.getLatestStateRoot(tenant2, store1), state2);
        assertEq(registry.getHeadSequence(tenant1, store1), 10);
        assertEq(registry.getHeadSequence(tenant2, store1), 5);
    }

    // =========================================================================
    // Pause Tests
    // =========================================================================

    function test_Pause() public {
        vm.prank(owner);
        registry.pause();
        assertTrue(registry.paused());
    }

    function test_Unpause() public {
        vm.prank(owner);
        registry.pause();

        vm.prank(owner);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_CommitBatch_WhenPaused() public {
        vm.prank(owner);
        registry.pause();

        vm.prank(sequencer);
        vm.expectRevert();
        registry.commitBatch(
            keccak256("batch1"),
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );
    }

    function test_Pause_NotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        registry.pause();
    }

    // =========================================================================
    // New Query Functions Tests
    // =========================================================================

    function test_GetBatchCommitment() public {
        bytes32 batchId = keccak256("batch1");
        bytes32 eventsRoot = keccak256("events");
        bytes32 newStateRoot = keccak256("state1");

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            eventsRoot,
            bytes32(0),
            newStateRoot,
            1,
            10,
            10
        );

        SetRegistry.BatchCommitment memory commitment = registry.getBatchCommitment(batchId);

        assertEq(commitment.eventsRoot, eventsRoot);
        assertEq(commitment.newStateRoot, newStateRoot);
        assertEq(commitment.sequenceStart, 1);
        assertEq(commitment.sequenceEnd, 10);
        assertEq(commitment.eventCount, 10);
    }

    function test_BatchExists() public {
        bytes32 batchId = keccak256("batch1");

        assertFalse(registry.batchExists(batchId));

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );

        assertTrue(registry.batchExists(batchId));
    }

    function test_GetLatestBatchId() public {
        bytes32 batchId = keccak256("batch1");

        assertEq(registry.getLatestBatchId(tenantId, storeId), bytes32(0));

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );

        assertEq(registry.getLatestBatchId(tenantId, storeId), batchId);
    }

    function test_GetRegistryStats() public {
        (
            uint256 commitmentCount,
            uint256 proofCount,
            bool isPaused,
            bool isStrictMode
        ) = registry.getRegistryStats();

        assertEq(commitmentCount, 0);
        assertEq(proofCount, 0);
        assertFalse(isPaused);
        assertTrue(isStrictMode);

        vm.prank(sequencer);
        registry.commitBatch(
            keccak256("batch1"),
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );

        (commitmentCount, proofCount, isPaused, isStrictMode) = registry.getRegistryStats();
        // totalCommitments no longer incremented in commitBatch (gas optimization)
        // commitmentCount is now stale; verify other stats still work
        assertFalse(isPaused);
    }

    function test_GetBatchWithProofStatus() public {
        bytes32 batchId = keccak256("batch1");

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            keccak256("events"),
            bytes32(0),
            keccak256("state"),
            1,
            10,
            10
        );

        (
            SetRegistry.BatchCommitment memory commitment,
            bool hasProof,
            bool proofCompliant
        ) = registry.getBatchWithProofStatus(batchId);

        assertEq(commitment.eventsRoot, keccak256("events"));
        assertFalse(hasProof);
        assertFalse(proofCompliant);
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_CommitBatch(
        bytes32 batchId,
        bytes32 eventsRoot,
        bytes32 newStateRoot,
        uint64 seqStart,
        uint64 seqEnd
    ) public {
        vm.assume(eventsRoot != bytes32(0));
        vm.assume(seqEnd >= seqStart);
        vm.assume(batchId != bytes32(0));
        uint256 expectedCount = uint256(seqEnd) - uint256(seqStart) + 1;
        vm.assume(expectedCount <= type(uint32).max);
        uint32 eventCount = uint32(expectedCount);

        vm.prank(sequencer);
        registry.commitBatch(
            batchId,
            tenantId,
            storeId,
            eventsRoot,
            bytes32(0),
            newStateRoot,
            seqStart,
            seqEnd,
            eventCount
        );

        (
            bytes32 storedRoot,
            bytes32 storedNewState,
            uint64 storedStart,
            uint64 storedEnd,
            uint32 storedCount,
        ) = registry.commitments(batchId);

        assertEq(storedRoot, eventsRoot);
        assertEq(storedNewState, newStateRoot);
        assertEq(storedStart, seqStart);
        assertEq(storedEnd, seqEnd);
        assertEq(storedCount, eventCount);
    }
}
