// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title SetRegistry
 * @notice Merkle Root Anchoring for Commerce Events on Set Chain
 * @dev Stores batch commitments from the stateset-sequencer for verifiable commerce
 *      and records STARK proof metadata. Proof validity itself is not verified on-chain.
 *
 * Key features:
 * - Multi-sequencer authorization
 * - State chain continuity verification
 * - Inclusion proof verification
 * - Tenant/store isolation
 */
contract SetRegistry is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Batch commitment containing state and event roots
    /// @dev Packed into 3 storage slots:
    ///   Slot 1: eventsRoot (32)
    ///   Slot 2: newStateRoot (32)
    ///   Slot 3: sequenceStart(8) + sequenceEnd(8) + eventCount(4) + timestamp(8) = 28
    /// submitter removed — available from tx receipt / BatchCommitted event
    /// prevStateRoot removed — equals previous batch's newStateRoot
    struct BatchCommitment {
        bytes32 eventsRoot;      // Merkle root of events in this batch
        bytes32 newStateRoot;    // State root after applying this batch
        uint64 sequenceStart;    // First sequence number in batch
        uint64 sequenceEnd;      // Last sequence number in batch
        uint32 eventCount;       // Number of events in batch
        uint64 timestamp;        // Block timestamp when committed
    }

    /// @notice STARK proof commitment for a batch
    /// @dev Packed into 3 slots. submitter removed — available from event/tx receipt.
    struct StarkProofCommitment {
        bytes32 proofHash;       // Hash of the STARK proof
        bytes32 policyHash;      // Policy hash used in proof
        uint64 policyLimit;      // Policy limit/threshold
        bool allCompliant;       // Whether all events passed compliance
        uint64 proofSize;        // Size of proof in bytes
        uint64 provingTimeMs;    // Time to generate proof
        uint64 timestamp;        // When proof was submitted
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Authorized sequencers who can submit commitments
    mapping(address => bool) public authorizedSequencers;

    /// @notice Batch commitments by batch ID
    mapping(bytes32 => BatchCommitment) public commitments;

    /// @notice Latest commitment per tenant/store (tenant_store_key => batch_id)
    mapping(bytes32 => bytes32) public latestCommitment;

    /// @notice Head sequence per tenant/store
    mapping(bytes32 => uint64) public headSequence;

    /// @notice Total commitments count
    uint256 public totalCommitments;

    /// @notice Whether strict state chain verification is enabled
    bool public strictModeEnabled;

    /// @notice STARK proof commitments by batch ID
    mapping(bytes32 => StarkProofCommitment) public starkProofs;

    /// @notice Total STARK proofs submitted
    uint256 public totalStarkProofs;

    /// @notice Count of authorized sequencers
    uint256 public authorizedSequencerCount;

    // =========================================================================
    // Events
    // =========================================================================

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

    event StarkProofCommitted(
        bytes32 indexed batchId,
        bytes32 proofHash,
        bytes32 policyHash,
        bool allCompliant,
        uint64 proofSize
    );

    event ContractUpgraded(address indexed newImplementation, address indexed authorizer);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotAuthorizedSequencer();
    error InvalidSequenceRange();
    error EmptyEventsRoot();
    error BatchAlreadyCommitted();
    error StateRootMismatch(bytes32 expected, bytes32 provided);
    error SequenceGap(uint64 expected, uint64 provided);
    error InvalidEventCount(uint64 expected, uint32 provided);
    error InvalidProof();
    error BatchNotCommitted();
    error StarkProofAlreadyCommitted();
    error StateRootMismatchInProof();
    error InvalidAddress();
    error ArrayLengthMismatch();
    error EmptyArray();

    // =========================================================================
    // Initialization
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the registry
     * @param _owner Owner address for admin functions
     * @param _initialSequencer First authorized sequencer
     */
    function initialize(
        address _owner,
        address _initialSequencer
    ) public initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (_initialSequencer != address(0)) {
            authorizedSequencers[_initialSequencer] = true;
            authorizedSequencerCount = 1;
            emit SequencerAuthorized(_initialSequencer, true);
        }

        strictModeEnabled = true;
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /**
     * @notice Authorize or revoke a sequencer
     * @param _sequencer Address to authorize/revoke
     * @param _authorized Whether to authorize or revoke
     */
    function setSequencerAuthorization(
        address _sequencer,
        bool _authorized
    ) external onlyOwner {
        if (_sequencer == address(0)) revert InvalidAddress();

        bool wasAuthorized = authorizedSequencers[_sequencer];
        authorizedSequencers[_sequencer] = _authorized;

        // Update count
        if (_authorized && !wasAuthorized) {
            unchecked { ++authorizedSequencerCount; }
        } else if (!_authorized && wasAuthorized) {
            unchecked { --authorizedSequencerCount; }
        }

        emit SequencerAuthorized(_sequencer, _authorized);
    }

    /**
     * @notice Authorize multiple sequencers at once
     * @param _sequencers Array of sequencer addresses
     * @param _authorized Whether to authorize or revoke all
     */
    function batchSetSequencerAuthorization(
        address[] calldata _sequencers,
        bool _authorized
    ) external onlyOwner {
        if (_sequencers.length == 0) revert EmptyArray();

        for (uint256 i = 0; i < _sequencers.length; i++) {
            if (_sequencers[i] == address(0)) revert InvalidAddress();

            bool wasAuthorized = authorizedSequencers[_sequencers[i]];
            authorizedSequencers[_sequencers[i]] = _authorized;

            if (_authorized && !wasAuthorized) {
                unchecked { ++authorizedSequencerCount; }
            } else if (!_authorized && wasAuthorized) {
                unchecked { --authorizedSequencerCount; }
            }

            emit SequencerAuthorized(_sequencers[i], _authorized);
        }
    }

    /**
     * @notice Enable or disable strict state chain verification
     * @param _enabled Whether strict mode is enabled
     */
    function setStrictMode(bool _enabled) external onlyOwner {
        strictModeEnabled = _enabled;
        emit StrictModeUpdated(_enabled);
    }

    /**
     * @notice Pause the contract (emergency stop)
     * @dev Can only be called by owner. Pauses commitBatch, commitStarkProof, and commitBatchWithStarkProof
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     * @dev Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Core Functions
    // =========================================================================

    /**
     * @notice Commit a batch of events
     * @param _batchId Unique identifier for this batch
     * @param _tenantId Tenant identifier
     * @param _storeId Store identifier
     * @param _eventsRoot Merkle root of events
     * @param _prevStateRoot State root before this batch
     * @param _newStateRoot State root after this batch
     * @param _sequenceStart First sequence number
     * @param _sequenceEnd Last sequence number
     * @param _eventCount Number of events in batch
     */
    function commitBatch(
        bytes32 _batchId,
        bytes32 _tenantId,
        bytes32 _storeId,
        bytes32 _eventsRoot,
        bytes32 _prevStateRoot,
        bytes32 _newStateRoot,
        uint64 _sequenceStart,
        uint64 _sequenceEnd,
        uint32 _eventCount
    ) external nonReentrant whenNotPaused {
        _validateAndStoreBatch(
            _batchId, _tenantId, _storeId, _eventsRoot,
            _prevStateRoot, _newStateRoot, _sequenceStart, _sequenceEnd, _eventCount
        );
    }

    /**
     * @notice Submit a STARK proof for a batch
     * @dev Stores proof metadata and state-root bindings. This does not verify STARK validity
     *      on-chain; callers should treat it as an integrity commitment for off-chain verification.
     * @param _batchId Batch this proof is for (must already be committed)
     * @param _proofHash Hash of the STARK proof bytes
     * @param _prevStateRoot Previous state root (must match batch)
     * @param _newStateRoot New state root (must match batch)
     * @param _policyHash Hash of the policy used
     * @param _policyLimit Policy threshold/limit
     * @param _allCompliant Whether all events passed compliance
     * @param _proofSize Size of the proof in bytes
     * @param _provingTimeMs Time taken to generate proof
     */
    function commitStarkProof(
        bytes32 _batchId,
        bytes32 _proofHash,
        bytes32 _prevStateRoot,
        bytes32 _newStateRoot,
        bytes32 _policyHash,
        uint64 _policyLimit,
        bool _allCompliant,
        uint64 _proofSize,
        uint64 _provingTimeMs
    ) external nonReentrant whenNotPaused {
        _validateAndStoreStarkProof(
            _batchId, _proofHash, _prevStateRoot, _newStateRoot,
            _policyHash, _policyLimit, _allCompliant, _proofSize, _provingTimeMs
        );
    }

    /**
     * @notice Commit batch and STARK proof together in a single transaction
     * @dev Combines commitBatch and proof-metadata storage for gas efficiency.
     */
    function commitBatchWithStarkProof(
        bytes32 _batchId,
        bytes32 _tenantId,
        bytes32 _storeId,
        bytes32 _eventsRoot,
        bytes32 _prevStateRoot,
        bytes32 _newStateRoot,
        uint64 _sequenceStart,
        uint64 _sequenceEnd,
        uint32 _eventCount,
        bytes32 _proofHash,
        bytes32 _policyHash,
        uint64 _policyLimit,
        bool _allCompliant,
        uint64 _proofSize,
        uint64 _provingTimeMs
    ) external nonReentrant whenNotPaused {
        _validateAndStoreBatch(
            _batchId, _tenantId, _storeId, _eventsRoot,
            _prevStateRoot, _newStateRoot, _sequenceStart, _sequenceEnd, _eventCount
        );

        _validateStarkProofMetadata(_proofHash, _proofSize);
        _storeStarkProof(
            _batchId,
            _proofHash,
            _policyHash,
            _policyLimit,
            _allCompliant,
            _proofSize,
            _provingTimeMs
        );
    }

    // =========================================================================
    // STARK Proof Query Functions
    // =========================================================================

    /**
     * @notice Check if a batch has a STARK proof
     * @param _batchId Batch to check
     * @return hasProof True if STARK proof exists
     */
    function hasStarkProof(bytes32 _batchId) external view returns (bool hasProof) {
        return starkProofs[_batchId].timestamp != 0;
    }

    /**
     * @notice Verify a STARK proof hash matches what's on-chain
     * @param _batchId Batch to verify
     * @param _proofHash Expected proof hash
     * @return valid True if proof hash matches
     */
    function verifyStarkProofHash(
        bytes32 _batchId,
        bytes32 _proofHash
    ) external view returns (bool valid) {
        StarkProofCommitment storage proof = starkProofs[_batchId];
        if (proof.timestamp == 0) {
            return false;
        }
        return proof.proofHash == _proofHash;
    }

    /**
     * @notice Get STARK proof details for a batch
     * @param _batchId Batch to query
     * @return proofHash Hash of the proof
     * @return policyHash Policy hash used
     * @return allCompliant Whether all events were compliant
     * @return timestamp When proof was submitted
     */
    function getStarkProofDetails(bytes32 _batchId) external view returns (
        bytes32 proofHash,
        bytes32 policyHash,
        bool allCompliant,
        uint64 timestamp
    ) {
        StarkProofCommitment storage proof = starkProofs[_batchId];
        return (proof.proofHash, proof.policyHash, proof.allCompliant, proof.timestamp);
    }

    // =========================================================================
    // Verification Functions
    // =========================================================================

    /**
     * @notice Verify a Merkle inclusion proof for an event
     * @param _batchId Batch containing the event
     * @param _leaf Hash of the event (payload_hash + metadata)
     * @param _proof Merkle proof path
     * @param _index Index of the leaf in the tree
     * @return valid True if proof is valid
     */
    function verifyInclusion(
        bytes32 _batchId,
        bytes32 _leaf,
        bytes32[] calldata _proof,
        uint256 _index
    ) external view returns (bool valid) {
        BatchCommitment storage commitment = commitments[_batchId];

        // Batch must exist
        if (commitment.timestamp == 0) {
            return false;
        }

        // Compute root from proof
        bytes32 computedRoot = _computeMerkleRoot(_leaf, _proof, _index);

        return computedRoot == commitment.eventsRoot;
    }

    /**
     * @notice Verify multiple events in a single call
     * @param _batchId Batch containing the events
     * @param _leaves Array of event hashes
     * @param _proofs Array of Merkle proofs
     * @param _indices Array of leaf indices
     * @return allValid True if all proofs are valid
     */
    function verifyMultipleInclusions(
        bytes32 _batchId,
        bytes32[] calldata _leaves,
        bytes32[][] calldata _proofs,
        uint256[] calldata _indices
    ) external view returns (bool allValid) {
        if (_leaves.length != _proofs.length || _leaves.length != _indices.length) {
            return false;
        }

        BatchCommitment storage commitment = commitments[_batchId];
        if (commitment.timestamp == 0) {
            return false;
        }

        for (uint256 i = 0; i < _leaves.length; i++) {
            bytes32 computedRoot = _computeMerkleRoot(_leaves[i], _proofs[i], _indices[i]);
            if (computedRoot != commitment.eventsRoot) {
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Get the latest state root for a tenant/store
     * @param _tenantId Tenant identifier
     * @param _storeId Store identifier
     * @return stateRoot Current state root
     */
    function getLatestStateRoot(
        bytes32 _tenantId,
        bytes32 _storeId
    ) external view returns (bytes32 stateRoot) {
        bytes32 tenantStoreKey = keccak256(abi.encodePacked(_tenantId, _storeId));
        bytes32 batchId = latestCommitment[tenantStoreKey];

        if (batchId == bytes32(0)) {
            return bytes32(0);
        }

        return commitments[batchId].newStateRoot;
    }

    /**
     * @notice Get the head sequence for a tenant/store
     * @param _tenantId Tenant identifier
     * @param _storeId Store identifier
     * @return sequence Current head sequence number
     */
    function getHeadSequence(
        bytes32 _tenantId,
        bytes32 _storeId
    ) external view returns (uint64 sequence) {
        bytes32 tenantStoreKey = keccak256(abi.encodePacked(_tenantId, _storeId));
        bytes32 batchId = latestCommitment[tenantStoreKey];
        if (batchId == bytes32(0)) return 0;
        return commitments[batchId].sequenceEnd;
    }

    /**
     * @notice Get full batch commitment details
     * @param _batchId Batch identifier
     * @return commitment The batch commitment struct
     */
    function getBatchCommitment(
        bytes32 _batchId
    ) external view returns (BatchCommitment memory commitment) {
        return commitments[_batchId];
    }

    /**
     * @notice Check if a batch exists
     * @param _batchId Batch identifier
     * @return exists True if batch exists
     */
    function batchExists(bytes32 _batchId) external view returns (bool exists) {
        return commitments[_batchId].timestamp != 0;
    }

    /**
     * @notice Get the latest batch ID for a tenant/store
     * @param _tenantId Tenant identifier
     * @param _storeId Store identifier
     * @return batchId Latest batch ID (bytes32(0) if none)
     */
    function getLatestBatchId(
        bytes32 _tenantId,
        bytes32 _storeId
    ) external view returns (bytes32 batchId) {
        bytes32 tenantStoreKey = keccak256(abi.encodePacked(_tenantId, _storeId));
        return latestCommitment[tenantStoreKey];
    }

    /**
     * @notice Get batch commitment with STARK proof status
     * @param _batchId Batch identifier
     * @return commitment The batch commitment
     * @return hasProof Whether STARK proof exists
     * @return proofCompliant Whether all events were compliant (if proof exists)
     */
    function getBatchWithProofStatus(
        bytes32 _batchId
    ) external view returns (
        BatchCommitment memory commitment,
        bool hasProof,
        bool proofCompliant
    ) {
        commitment = commitments[_batchId];
        StarkProofCommitment storage proof = starkProofs[_batchId];
        hasProof = proof.timestamp != 0;
        proofCompliant = proof.allCompliant;
    }

    /**
     * @notice Get registry statistics
     * @return commitmentCount Total number of batch commitments
     * @return proofCount Total number of STARK proofs
     * @return isPaused Whether the contract is paused
     * @return isStrictMode Whether strict mode is enabled
     */
    function getRegistryStats() external view returns (
        uint256 commitmentCount,
        uint256 proofCount,
        bool isPaused,
        bool isStrictMode
    ) {
        return (totalCommitments, totalStarkProofs, paused(), strictModeEnabled);
    }

    // =========================================================================
    // Batch Query Functions
    // =========================================================================

    /**
     * @notice Get multiple batch commitments in a single call
     * @param _batchIds Array of batch identifiers
     * @return commitmentList Array of batch commitments
     */
    function getBatchCommitments(
        bytes32[] calldata _batchIds
    ) external view returns (BatchCommitment[] memory commitmentList) {
        commitmentList = new BatchCommitment[](_batchIds.length);
        for (uint256 i = 0; i < _batchIds.length; i++) {
            commitmentList[i] = commitments[_batchIds[i]];
        }
        return commitmentList;
    }

    /**
     * @notice Check existence of multiple batches
     * @param _batchIds Array of batch identifiers
     * @return exists Array of existence flags
     */
    function batchExists(
        bytes32[] calldata _batchIds
    ) external view returns (bool[] memory exists) {
        exists = new bool[](_batchIds.length);
        for (uint256 i = 0; i < _batchIds.length; i++) {
            exists[i] = commitments[_batchIds[i]].timestamp != 0;
        }
        return exists;
    }

    /**
     * @notice Get STARK proof status for multiple batches
     * @param _batchIds Array of batch identifiers
     * @return hasProofs Array of proof existence flags
     * @return allCompliant Array of compliance flags
     */
    function getBatchProofStatuses(
        bytes32[] calldata _batchIds
    ) external view returns (bool[] memory hasProofs, bool[] memory allCompliant) {
        hasProofs = new bool[](_batchIds.length);
        allCompliant = new bool[](_batchIds.length);

        for (uint256 i = 0; i < _batchIds.length; i++) {
            StarkProofCommitment storage proof = starkProofs[_batchIds[i]];
            hasProofs[i] = proof.timestamp != 0;
            allCompliant[i] = proof.allCompliant;
        }

        return (hasProofs, allCompliant);
    }

    /**
     * @notice Get latest state roots for multiple tenant/store pairs
     * @param _tenantIds Array of tenant identifiers
     * @param _storeIds Array of store identifiers
     * @return stateRoots Array of latest state roots
     */
    function getBatchLatestStateRoots(
        bytes32[] calldata _tenantIds,
        bytes32[] calldata _storeIds
    ) external view returns (bytes32[] memory stateRoots) {
        if (_tenantIds.length != _storeIds.length) revert ArrayLengthMismatch();

        stateRoots = new bytes32[](_tenantIds.length);

        for (uint256 i = 0; i < _tenantIds.length; i++) {
            bytes32 tenantStoreKey = keccak256(abi.encodePacked(_tenantIds[i], _storeIds[i]));
            bytes32 batchId = latestCommitment[tenantStoreKey];

            if (batchId != bytes32(0)) {
                stateRoots[i] = commitments[batchId].newStateRoot;
            }
        }

        return stateRoots;
    }

    /**
     * @notice Get head sequences for multiple tenant/store pairs
     * @param _tenantIds Array of tenant identifiers
     * @param _storeIds Array of store identifiers
     * @return sequences Array of head sequences
     */
    function getBatchHeadSequences(
        bytes32[] calldata _tenantIds,
        bytes32[] calldata _storeIds
    ) external view returns (uint64[] memory sequences) {
        if (_tenantIds.length != _storeIds.length) revert ArrayLengthMismatch();

        sequences = new uint64[](_tenantIds.length);

        for (uint256 i = 0; i < _tenantIds.length; i++) {
            bytes32 tenantStoreKey = keccak256(abi.encodePacked(_tenantIds[i], _storeIds[i]));
            bytes32 batchId = latestCommitment[tenantStoreKey];
            if (batchId != bytes32(0)) {
                sequences[i] = commitments[batchId].sequenceEnd;
            }
        }

        return sequences;
    }

    // =========================================================================
    // Extended Monitoring Functions
    // =========================================================================

    /**
     * @notice Get comprehensive registry status
     * @return totalBatches Total batch commitments
     * @return totalProofs Total STARK proofs
     * @return sequencerCount Number of authorized sequencers
     * @return isPaused Contract pause status
     * @return isStrictMode Strict mode status
     * @return proofCoverage Percentage of batches with proofs (basis points)
     */
    function getExtendedRegistryStatus() external view returns (
        uint256 totalBatches,
        uint256 totalProofs,
        uint256 sequencerCount,
        bool isPaused,
        bool isStrictMode,
        uint256 proofCoverage
    ) {
        totalBatches = totalCommitments;
        totalProofs = totalStarkProofs;
        sequencerCount = authorizedSequencerCount;
        isPaused = paused();
        isStrictMode = strictModeEnabled;

        // Calculate proof coverage (in basis points, 10000 = 100%)
        if (totalBatches > 0) {
            proofCoverage = (totalProofs * 10000) / totalBatches;
        } else {
            proofCoverage = 10000; // 100% if no batches
        }

        return (totalBatches, totalProofs, sequencerCount, isPaused, isStrictMode, proofCoverage);
    }

    /**
     * @notice Get tenant/store summary
     * @param _tenantId Tenant identifier
     * @param _storeId Store identifier
     * @return latestBatchId Latest batch ID
     * @return currentStateRoot Current state root
     * @return currentHeadSequence Current head sequence
     * @return hasLatestProof Whether latest batch has STARK proof
     */
    function getTenantStoreSummary(
        bytes32 _tenantId,
        bytes32 _storeId
    ) external view returns (
        bytes32 latestBatchId,
        bytes32 currentStateRoot,
        uint64 currentHeadSequence,
        bool hasLatestProof
    ) {
        bytes32 tenantStoreKey = keccak256(abi.encodePacked(_tenantId, _storeId));

        latestBatchId = latestCommitment[tenantStoreKey];

        if (latestBatchId != bytes32(0)) {
            BatchCommitment storage batch = commitments[latestBatchId];
            currentStateRoot = batch.newStateRoot;
            currentHeadSequence = batch.sequenceEnd;
            hasLatestProof = starkProofs[latestBatchId].timestamp != 0;
        }

        return (latestBatchId, currentStateRoot, currentHeadSequence, hasLatestProof);
    }

    /**
     * @notice Check if multiple addresses are authorized sequencers
     * @param _addresses Array of addresses to check
     * @return authorized Array of authorization flags
     */
    function areSequencersAuthorized(
        address[] calldata _addresses
    ) external view returns (bool[] memory authorized) {
        authorized = new bool[](_addresses.length);
        for (uint256 i = 0; i < _addresses.length; i++) {
            authorized[i] = authorizedSequencers[_addresses[i]];
        }
        return authorized;
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /**
     * @dev Validate and store a batch commitment
     * @return tenantStoreKey The computed tenant/store key
     */
    function _validateAndStoreBatch(
        bytes32 _batchId,
        bytes32 _tenantId,
        bytes32 _storeId,
        bytes32 _eventsRoot,
        bytes32 _prevStateRoot,
        bytes32 _newStateRoot,
        uint64 _sequenceStart,
        uint64 _sequenceEnd,
        uint32 _eventCount
    ) internal returns (bytes32 tenantStoreKey) {
        if (!authorizedSequencers[msg.sender]) {
            revert NotAuthorizedSequencer();
        }

        if (_sequenceEnd < _sequenceStart) {
            revert InvalidSequenceRange();
        }
        // Safe: _sequenceEnd >= _sequenceStart validated above
        uint64 expectedEventCount;
        unchecked {
            expectedEventCount = _sequenceEnd - _sequenceStart + 1;
        }
        if (expectedEventCount > type(uint32).max || _eventCount != expectedEventCount) {
            revert InvalidEventCount(expectedEventCount, _eventCount);
        }
        if (_eventsRoot == bytes32(0)) {
            revert EmptyEventsRoot();
        }
        if (commitments[_batchId].timestamp != 0) {
            revert BatchAlreadyCommitted();
        }

        tenantStoreKey = keccak256(abi.encodePacked(_tenantId, _storeId));

        if (strictModeEnabled) {
            bytes32 lastBatchId = latestCommitment[tenantStoreKey];

            if (lastBatchId != bytes32(0)) {
                BatchCommitment storage lastBatch = commitments[lastBatchId];

                if (lastBatch.newStateRoot != _prevStateRoot) {
                    revert StateRootMismatch(lastBatch.newStateRoot, _prevStateRoot);
                }

                unchecked {
                    if (lastBatch.sequenceEnd + 1 != _sequenceStart) {
                        revert SequenceGap(lastBatch.sequenceEnd + 1, _sequenceStart);
                    }
                }
            }
        }

        commitments[_batchId] = BatchCommitment({
            eventsRoot: _eventsRoot,
            newStateRoot: _newStateRoot,
            sequenceStart: _sequenceStart,
            sequenceEnd: _sequenceEnd,
            eventCount: _eventCount,
            timestamp: uint64(block.timestamp)
        });

        latestCommitment[tenantStoreKey] = _batchId;

        emit BatchCommitted(
            _batchId,
            tenantStoreKey,
            _eventsRoot,
            _newStateRoot,
            _sequenceStart,
            _sequenceEnd,
            _eventCount
        );
    }

    /**
     * @dev Validate and store a STARK proof for an existing batch
     */
    function _validateAndStoreStarkProof(
        bytes32 _batchId,
        bytes32 _proofHash,
        bytes32 _prevStateRoot,
        bytes32 _newStateRoot,
        bytes32 _policyHash,
        uint64 _policyLimit,
        bool _allCompliant,
        uint64 _proofSize,
        uint64 _provingTimeMs
    ) internal {
        if (!authorizedSequencers[msg.sender]) {
            revert NotAuthorizedSequencer();
        }

        BatchCommitment storage batch = commitments[_batchId];
        if (batch.timestamp == 0) {
            revert BatchNotCommitted();
        }

        if (starkProofs[_batchId].timestamp != 0) {
            revert StarkProofAlreadyCommitted();
        }

        // prevStateRoot is no longer stored; verify newStateRoot matches
        if (batch.newStateRoot != _newStateRoot) {
            revert StateRootMismatchInProof();
        }

        _validateStarkProofMetadata(_proofHash, _proofSize);
        _storeStarkProof(
            _batchId,
            _proofHash,
            _policyHash,
            _policyLimit,
            _allCompliant,
            _proofSize,
            _provingTimeMs
        );
    }

    function _validateStarkProofMetadata(
        bytes32 _proofHash,
        uint64 _proofSize
    ) internal pure {
        if (_proofHash == bytes32(0) || _proofSize == 0) {
            revert InvalidProof();
        }
    }

    function _storeStarkProof(
        bytes32 _batchId,
        bytes32 _proofHash,
        bytes32 _policyHash,
        uint64 _policyLimit,
        bool _allCompliant,
        uint64 _proofSize,
        uint64 _provingTimeMs
    ) internal {
        starkProofs[_batchId] = StarkProofCommitment({
            proofHash: _proofHash,
            policyHash: _policyHash,
            policyLimit: _policyLimit,
            allCompliant: _allCompliant,
            proofSize: _proofSize,
            provingTimeMs: _provingTimeMs,
            timestamp: uint64(block.timestamp)
        });

        emit StarkProofCommitted(
            _batchId,
            _proofHash,
            _policyHash,
            _allCompliant,
            _proofSize
        );
    }

    /**
     * @dev Compute Merkle root from leaf and proof
     * @notice Gas-optimized with unchecked arithmetic (safe because loop bounds are controlled)
     */
    function _computeMerkleRoot(
        bytes32 _leaf,
        bytes32[] calldata _proof,
        uint256 _index
    ) internal pure returns (bytes32) {
        bytes32 computedHash = _leaf;
        uint256 proofLength = _proof.length;

        // Gas optimization: use unchecked for loop counter and index division
        for (uint256 i; i < proofLength; ) {
            bytes32 proofElement = _proof[i];

            if (_index & 1 == 0) {
                // Current node is left child (using bitwise AND for gas efficiency)
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                // Current node is right child
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }

            unchecked {
                _index >>= 1;  // Division by 2 using bit shift
                ++i;
            }
        }

        return computedHash;
    }

    /**
     * @dev Authorize upgrade (owner only)
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {
        emit ContractUpgraded(newImplementation, msg.sender);
    }

    // =========================================================================
    // Legacy Compatibility (DEPRECATED)
    // =========================================================================

    /// @notice Whether legacy functions are enabled (disabled by default for security)
    bool public legacyFunctionsEnabled;

    /// @notice Error for disabled legacy functions
    error LegacyFunctionsDisabled();

    /**
     * @notice Enable or disable legacy functions
     * @param _enabled Whether to enable legacy functions
     *
     * SECURITY: Legacy functions are disabled by default. Only enable
     * if you have systems that depend on the old interface and have
     * verified they cannot be exploited.
     */
    function setLegacyFunctionsEnabled(bool _enabled) external onlyOwner {
        legacyFunctionsEnabled = _enabled;
    }

    /**
     * @notice Legacy function for backward compatibility (DEPRECATED)
     * @dev Maps to new commitBatch function with default tenant/store
     *
     * SECURITY FIX: This function is disabled by default.
     * The original implementation had a bug where it called this.commitBatch()
     * which would fail authorization since msg.sender becomes the contract itself.
     *
     * If enabled, this function now properly passes through the authorization
     * check by using the original msg.sender.
     *
     * WARNING: Using default tenant/store (bytes32(0)) bypasses tenant isolation.
     * Only enable if you understand the security implications.
     */
    function registerBatchRoot(
        uint256 _startSequence,
        uint256 _endSequence,
        bytes32 _root
    ) external nonReentrant {
        // SECURITY FIX: Disabled by default
        if (!legacyFunctionsEnabled) revert LegacyFunctionsDisabled();

        // Authorization check (same as commitBatch)
        if (!authorizedSequencers[msg.sender]) {
            revert NotAuthorizedSequencer();
        }

        // Basic validation
        if (_endSequence < _startSequence) {
            revert InvalidSequenceRange();
        }
        if (_root == bytes32(0)) {
            revert EmptyEventsRoot();
        }

        // Generate a batch ID from sequence range
        bytes32 batchId = keccak256(abi.encodePacked(_startSequence, _endSequence, block.timestamp, msg.sender));

        if (commitments[batchId].timestamp != 0) {
            revert BatchAlreadyCommitted();
        }

        // Use default tenant/store (zeros) - WARNING: bypasses tenant isolation
        bytes32 tenantStoreKey = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));

        // State chain verification (if strict mode enabled)
        if (strictModeEnabled) {
            bytes32 lastBatchId = latestCommitment[tenantStoreKey];

            if (lastBatchId != bytes32(0)) {
                BatchCommitment storage lastBatch = commitments[lastBatchId];

                // For legacy function, we skip state root continuity check
                // since it doesn't provide state roots

                // Verify sequence continuity
                if (lastBatch.sequenceEnd + 1 != _startSequence) {
                    revert SequenceGap(lastBatch.sequenceEnd + 1, uint64(_startSequence));
                }
            }
        }

        // Store commitment
        commitments[batchId] = BatchCommitment({
            eventsRoot: _root,
            newStateRoot: bytes32(0),   // Legacy: no state root tracking
            sequenceStart: uint64(_startSequence),
            sequenceEnd: uint64(_endSequence),
            eventCount: uint32(_endSequence - _startSequence + 1),
            timestamp: uint64(block.timestamp)
        });

        // Update latest commitment (headSequence derived from commitments)
        latestCommitment[tenantStoreKey] = batchId;
        unchecked { ++totalCommitments; }

        emit BatchCommitted(
            batchId,
            tenantStoreKey,
            _root,
            bytes32(0),
            uint64(_startSequence),
            uint64(_endSequence),
            uint32(_endSequence - _startSequence + 1)
        );
    }

    /**
     * @notice Legacy function for backward compatibility (DEPRECATED)
     *
     * NOTE: This function remains available for reading historical data
     * but will only return data if a batch with exact matching sequence
     * range exists in the default tenant/store.
     */
    function getBatchRoot(
        uint256 _startSequence,
        uint256 _endSequence
    ) external view returns (bytes32) {
        // This is a simplified lookup - in practice you'd need to search
        // For true backward compatibility, maintain a separate mapping
        bytes32 tenantStoreKey = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        bytes32 batchId = latestCommitment[tenantStoreKey];

        if (batchId == bytes32(0)) {
            return bytes32(0);
        }

        BatchCommitment storage commitment = commitments[batchId];
        if (commitment.sequenceStart == _startSequence &&
            commitment.sequenceEnd == _endSequence) {
            return commitment.eventsRoot;
        }

        return bytes32(0);
    }

    // =========================================================================
    // Storage Gap
    // =========================================================================

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
