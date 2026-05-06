// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/INAVOracle.sol";
import "./interfaces/ISSDC.sol";

/**
 * @title NAVOracle
 * @notice Oracle for T-Bill Net Asset Value attestation
 * @dev Company attests daily NAV of T-Bill holdings backing SSDC
 */
contract NAVOracle is
    INAVOracle,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Precision for NAV calculations (1e18 = $1.00)
    uint256 public constant PRECISION = 1e18;

    /// @notice Initial NAV per share ($1.00)
    uint256 public constant INITIAL_NAV_PER_SHARE = 1e18;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Default maximum NAV change per attestation (5%)
    uint256 public constant DEFAULT_MAX_NAV_CHANGE_BPS = 500;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice Current NAV report
    NAVReport private _currentNAV;

    /// @notice Historical NAV reports
    NAVReport[] private _navHistory;

    /// @notice Authorized attestors
    mapping(address => bool) public authorizedAttestors;

    /// @notice Maximum staleness for NAV (default 24 hours)
    uint256 public maxStalenessSeconds;

    /// @notice SSDC token address
    address public SSDC;

    /// @notice Configurable maximum NAV change per attestation (in basis points)
    uint256 public maxNavChangeBps;

    // =========================================================================
    // Multi-Sig Attestation Storage
    // =========================================================================

    /// @notice Minimum attestors required to finalize NAV (threshold)
    uint256 public attestationThreshold;

    /// @notice Total number of authorized attestors
    uint256 public attestorCount;

    /// @notice Pending NAV attestation waiting for threshold
    struct PendingAttestation {
        uint256 totalAssets;
        uint256 reportDate;
        bytes32 proofHash;
        uint256 attestationCount;
        uint256 createdAt;
        bool finalized;
    }

    /// @notice Current pending attestation (keyed by hash of attestation data)
    mapping(bytes32 => PendingAttestation) public pendingAttestations;

    /// @notice Track which attestors have signed which pending attestation
    mapping(bytes32 => mapping(address => bool)) public hasAttested;

    /// @notice Current pending attestation key (if any)
    bytes32 public currentPendingKey;

    /// @notice Expiry time for pending attestations (default 4 hours)
    uint256 public pendingAttestationExpiry;

    // =========================================================================
    // Errors
    // =========================================================================

    error NotAuthorizedAttestor();
    error NAVChangeExceedsLimit();
    error InvalidReportDate();
    error ReportDateNotNew();
    error InvalidTotalAssets();
    error InvalidAddress();
    error InvalidStaleness();
    error InvalidNavChangeBps();
    error ArrayLengthMismatch();
    error EmptyArray();
    error AlreadyAttested();
    error AttestationExpired();
    error AttestationMismatch();
    error InvalidThreshold();
    error ThresholdNotMet();
    error MultiSigRequired();
    error SSDCNotSet();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyAttestor() {
        if (!authorizedAttestors[msg.sender]) revert NotAuthorizedAttestor();
        _;
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the oracle
     * @param owner_ Owner address
     * @param attestor_ Initial attestor address
     * @param maxStaleness_ Maximum staleness in seconds
     */
    function initialize(
        address owner_,
        address attestor_,
        uint256 maxStaleness_
    ) public initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        authorizedAttestors[attestor_] = true;
        attestorCount = 1;
        maxStalenessSeconds = maxStaleness_;
        maxNavChangeBps = DEFAULT_MAX_NAV_CHANGE_BPS;

        // Multi-sig defaults: threshold of 1 (backwards compatible)
        // Owner should call setAttestationThreshold() to enable multi-sig
        attestationThreshold = 1;
        pendingAttestationExpiry = 4 hours;

        // Initialize with $1.00 NAV
        _currentNAV = NAVReport({
            totalAssets: 0,
            totalShares: 0,
            navPerShare: INITIAL_NAV_PER_SHARE,
            timestamp: block.timestamp,
            reportDate: 0,
            proofHash: bytes32(0),
            attestor: attestor_
        });

        emit AttestorUpdated(attestor_, true);
    }

    // =========================================================================
    // Attestation (Multi-Sig)
    // =========================================================================

    event AttestationSubmitted(bytes32 indexed attestationKey, address indexed attestor, uint256 totalAssets, uint256 reportDate);
    event AttestationSigned(bytes32 indexed attestationKey, address indexed attestor, uint256 signatureCount, uint256 threshold);
    event AttestationFinalized(bytes32 indexed attestationKey, uint256 totalAssets, uint256 navPerShare);
    event AttestationExpiredEvent(bytes32 indexed attestationKey);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PendingExpiryUpdated(uint256 oldExpiry, uint256 newExpiry);
    event ssUSDUpdated(address indexed ssUSD);
    event ContractUpgraded(address indexed newImplementation, address indexed authorizer);

    /**
     * @notice Attest T-Bill NAV (multi-sig when threshold > 1)
     * @param totalAssets Total T-Bill value in USD (18 decimals)
     * @param reportDate Date of valuation (YYYYMMDD format)
     * @param proofHash Hash of off-chain proof documents
     * @dev When threshold > 1, this creates/signs a pending attestation
     *      When threshold = 1, this directly applies the NAV (backwards compatible)
     */
    function attestNAV(
        uint256 totalAssets,
        uint256 reportDate,
        bytes32 proofHash
    ) external onlyAttestor {
        if (totalAssets == 0) revert InvalidTotalAssets();
        if (reportDate <= _currentNAV.reportDate) revert ReportDateNotNew();

        // Single attestor mode (backwards compatible)
        if (attestationThreshold == 1) {
            _finalizeAttestation(totalAssets, reportDate, proofHash, msg.sender);
            return;
        }

        // Multi-sig mode
        bytes32 attestationKey = keccak256(abi.encodePacked(totalAssets, reportDate, proofHash));

        // Check if attestor already signed this attestation
        if (hasAttested[attestationKey][msg.sender]) {
            revert AlreadyAttested();
        }

        // Check if there's an existing pending attestation that expired
        if (currentPendingKey != bytes32(0) && currentPendingKey != attestationKey) {
            PendingAttestation storage existing = pendingAttestations[currentPendingKey];
            if (block.timestamp > existing.createdAt + pendingAttestationExpiry) {
                // Clear expired attestation
                emit AttestationExpiredEvent(currentPendingKey);
                currentPendingKey = bytes32(0);
            } else {
                // Different attestation in progress - must match or wait for expiry
                revert AttestationMismatch();
            }
        }

        // Create or update pending attestation
        PendingAttestation storage pending = pendingAttestations[attestationKey];

        if (pending.createdAt == 0) {
            // New pending attestation
            pending.totalAssets = totalAssets;
            pending.reportDate = reportDate;
            pending.proofHash = proofHash;
            pending.attestationCount = 1;
            pending.createdAt = block.timestamp;
            pending.finalized = false;
            currentPendingKey = attestationKey;

            emit AttestationSubmitted(attestationKey, msg.sender, totalAssets, reportDate);
        } else {
            // Check if expired
            if (block.timestamp > pending.createdAt + pendingAttestationExpiry) {
                revert AttestationExpired();
            }
            pending.attestationCount++;
        }

        hasAttested[attestationKey][msg.sender] = true;

        emit AttestationSigned(attestationKey, msg.sender, pending.attestationCount, attestationThreshold);

        // Check if threshold reached
        if (pending.attestationCount >= attestationThreshold) {
            _finalizeAttestation(totalAssets, reportDate, proofHash, msg.sender);
            pending.finalized = true;
            currentPendingKey = bytes32(0);

            emit AttestationFinalized(attestationKey, totalAssets, _currentNAV.navPerShare);
        }
    }

    /**
     * @dev Internal function to finalize NAV attestation
     */
    function _finalizeAttestation(
        uint256 totalAssets,
        uint256 reportDate,
        bytes32 proofHash,
        address finalAttestor
    ) internal {
        // Get total shares from ssUSD
        uint256 totalShares;
        if (SSDC != address(0)) {
            totalShares = ISSDC(SSDC).totalShares();
        }

        // Calculate new NAV per share
        uint256 newNavPerShare;
        if (totalShares == 0) {
            newNavPerShare = INITIAL_NAV_PER_SHARE;
        } else {
            newNavPerShare = (totalAssets * PRECISION) / totalShares;
        }

        // Validate NAV change is within limits (only after initial attestation)
        if (_currentNAV.totalAssets > 0 && totalShares > 0) {
            uint256 previousNav = _currentNAV.navPerShare;
            uint256 maxChange = (previousNav * maxNavChangeBps) / BPS_DENOMINATOR;

            if (newNavPerShare > previousNav + maxChange) {
                revert NAVChangeExceedsLimit();
            }
            // NAV should not decrease for T-Bills (principal protected)
            // But allow small decreases for fees
            if (newNavPerShare < previousNav - (previousNav * 100 / BPS_DENOMINATOR)) {
                revert NAVChangeExceedsLimit();
            }
        }

        // Store previous NAV in history
        if (_currentNAV.timestamp > 0) {
            _navHistory.push(_currentNAV);
        }

        // Update current NAV
        _currentNAV = NAVReport({
            totalAssets: totalAssets,
            totalShares: totalShares,
            navPerShare: newNavPerShare,
            timestamp: block.timestamp,
            reportDate: reportDate,
            proofHash: proofHash,
            attestor: finalAttestor
        });

        emit NAVAttested(totalAssets, newNavPerShare, reportDate, finalAttestor);
    }

    /**
     * @notice Get pending attestation status
     * @return key Current pending attestation key
     * @return totalAssets Pending total assets
     * @return reportDate Pending report date
     * @return signatureCount Current signature count
     * @return threshold Required signatures
     * @return expiresAt When the pending attestation expires
     * @return isActive Whether there's an active pending attestation
     */
    function getPendingAttestation() external view returns (
        bytes32 key,
        uint256 totalAssets,
        uint256 reportDate,
        uint256 signatureCount,
        uint256 threshold,
        uint256 expiresAt,
        bool isActive
    ) {
        key = currentPendingKey;
        threshold = attestationThreshold;

        if (key != bytes32(0)) {
            PendingAttestation storage pending = pendingAttestations[key];
            totalAssets = pending.totalAssets;
            reportDate = pending.reportDate;
            signatureCount = pending.attestationCount;
            expiresAt = pending.createdAt + pendingAttestationExpiry;
            isActive = !pending.finalized && block.timestamp <= expiresAt;
        }
    }

    /**
     * @notice Check if an attestor has signed the current pending attestation
     */
    function hasAttestorSigned(address attestor) external view returns (bool) {
        if (currentPendingKey == bytes32(0)) return false;
        return hasAttested[currentPendingKey][attestor];
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @notice Get current NAV per share
     * @return NAV per share (1e18 = $1.00)
     */
    function getCurrentNAVPerShare() external view returns (uint256) {
        return _currentNAV.navPerShare;
    }

    /**
     * @notice Get total assets
     */
    function getTotalAssets() external view returns (uint256) {
        return _currentNAV.totalAssets;
    }

    /**
     * @notice Get last report date
     */
    function getLastReportDate() external view returns (uint256) {
        return _currentNAV.reportDate;
    }

    /**
     * @notice Check if NAV is fresh (not stale)
     */
    function isNAVFresh() public view returns (bool) {
        return block.timestamp <= _currentNAV.timestamp + maxStalenessSeconds;
    }

    /**
     * @notice Get current NAV report
     */
    function getCurrentNAV() external view returns (NAVReport memory) {
        return _currentNAV;
    }

    /**
     * @notice Get NAV history
     * @param count Number of historical reports to return
     */
    function getNAVHistory(uint256 count) external view returns (NAVReport[] memory) {
        uint256 length = _navHistory.length;
        uint256 resultCount = count > length ? length : count;

        NAVReport[] memory result = new NAVReport[](resultCount);

        for (uint256 i = 0; i < resultCount; i++) {
            result[i] = _navHistory[length - resultCount + i];
        }

        return result;
    }

    /**
     * @notice Get total history count
     */
    function getHistoryCount() external view returns (uint256) {
        return _navHistory.length;
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /**
     * @notice Set attestor authorization
     * @dev Updates attestorCount for multi-sig threshold validation
     */
    function setAuthorizedAttestor(
        address attestor,
        bool authorized
    ) external onlyOwner {
        if (attestor == address(0)) revert InvalidAddress();

        bool wasAuthorized = authorizedAttestors[attestor];
        authorizedAttestors[attestor] = authorized;

        // Update attestor count
        if (authorized && !wasAuthorized) {
            attestorCount++;
        } else if (!authorized && wasAuthorized) {
            attestorCount--;
            // Ensure threshold doesn't exceed attestor count
            if (attestationThreshold > attestorCount && attestorCount > 0) {
                uint256 oldThreshold = attestationThreshold;
                attestationThreshold = attestorCount;
                emit ThresholdUpdated(oldThreshold, attestorCount);
            }
        }

        emit AttestorUpdated(attestor, authorized);
    }

    /**
     * @notice Set attestation threshold (multi-sig)
     * @param threshold_ Number of attestors required (1 = single-sig, >1 = multi-sig)
     * @dev Threshold cannot exceed current attestor count
     */
    function setAttestationThreshold(uint256 threshold_) external onlyOwner {
        if (threshold_ == 0 || threshold_ > attestorCount) {
            revert InvalidThreshold();
        }
        uint256 oldThreshold = attestationThreshold;
        attestationThreshold = threshold_;
        emit ThresholdUpdated(oldThreshold, threshold_);
    }

    /**
     * @notice Set pending attestation expiry time
     * @param expiry_ Time in seconds before pending attestation expires (min 1 hour, max 24 hours)
     */
    function setPendingAttestationExpiry(uint256 expiry_) external onlyOwner {
        if (expiry_ < 1 hours || expiry_ > 24 hours) {
            revert InvalidStaleness();
        }
        uint256 oldExpiry = pendingAttestationExpiry;
        pendingAttestationExpiry = expiry_;
        emit PendingExpiryUpdated(oldExpiry, expiry_);
    }

    /**
     * @notice Set maximum staleness period
     * @param seconds_ New staleness period (must be between 1 hour and 7 days)
     */
    function setMaxStaleness(uint256 seconds_) external onlyOwner {
        // Validate reasonable bounds
        if (seconds_ < 1 hours || seconds_ > 7 days) {
            revert InvalidStaleness();
        }
        maxStalenessSeconds = seconds_;
        emit StalenessUpdated(seconds_);
    }

    /**
     * @notice Set SSDC token address
     * @param SSDC_ New SSDC address (cannot be zero)
     */
    function setSSDC(address SSDC_) external onlyOwner {
        _setSSDC(SSDC_);
    }

    /**
     * @notice Backward-compatible setter alias
     * @dev Kept to avoid breaking older integrations/tests
     */
    function setssUSD(address ssUSD_) external onlyOwner {
        _setSSDC(ssUSD_);
    }

    /**
     * @notice Backward-compatible getter alias
     * @dev Kept to avoid breaking older integrations/tests
     */
    function ssUSD() external view returns (address) {
        return SSDC;
    }

    /**
     * @notice Set maximum NAV change per attestation
     * @param bps_ New maximum in basis points (10 = 0.1%, 500 = 5%)
     * @dev Must be between 10 bps (0.1%) and 1000 bps (10%)
     */
    function setMaxNavChangeBps(uint256 bps_) external onlyOwner {
        if (bps_ < 10 || bps_ > 1000) revert InvalidNavChangeBps();
        maxNavChangeBps = bps_;
        emit MaxNavChangeBpsUpdated(bps_);
    }

    // =========================================================================
    // Monitoring Functions
    // =========================================================================

    /**
     * @notice Get seconds since last attestation
     * @return seconds_ Time elapsed since last NAV update
     */
    function secondsSinceLastAttestation() external view returns (uint256 seconds_) {
        return block.timestamp - _currentNAV.timestamp;
    }

    /**
     * @notice Check if attestation is overdue
     * @return overdue True if NAV is stale (exceeds maxStalenessSeconds)
     */
    function isAttestationOverdue() external view returns (bool overdue) {
        return block.timestamp - _currentNAV.timestamp > maxStalenessSeconds;
    }

    /**
     * @notice Get comprehensive oracle status
     * @return navPerShare Current NAV per share
     * @return lastUpdate Timestamp of last attestation
     * @return isFresh True if NAV is within staleness period
     * @return reportDate Last report date (YYYYMMDD)
     * @return totalAssets Current total assets
     * @return configuredMaxChange Maximum allowed NAV change (bps)
     */
    function getOracleStatus() external view returns (
        uint256 navPerShare,
        uint256 lastUpdate,
        bool isFresh,
        uint256 reportDate,
        uint256 totalAssets,
        uint256 configuredMaxChange
    ) {
        return (
            _currentNAV.navPerShare,
            _currentNAV.timestamp,
            isNAVFresh(),
            _currentNAV.reportDate,
            _currentNAV.totalAssets,
            maxNavChangeBps
        );
    }

    /**
     * @notice Calculate the maximum NAV value allowed for next attestation
     * @return maxNav Maximum NAV per share that can be attested
     */
    function getMaxAllowedNavChange() external view returns (uint256 maxNav) {
        uint256 currentNav = _currentNAV.navPerShare;
        uint256 maxChange = (currentNav * maxNavChangeBps) / BPS_DENOMINATOR;
        return currentNav + maxChange;
    }

    /**
     * @notice Get number of historical NAV reports
     * @return count Number of reports in history
     */
    function getHistoryLength() external view returns (uint256 count) {
        return _navHistory.length;
    }

    // =========================================================================
    // Batch Operations
    // =========================================================================

    /**
     * @notice Set multiple attestors at once
     * @param attestors Array of attestor addresses
     * @param authorized Array of authorization flags
     */
    function batchSetAuthorizedAttestors(
        address[] calldata attestors,
        bool[] calldata authorized
    ) external onlyOwner {
        if (attestors.length == 0) revert EmptyArray();
        if (attestors.length != authorized.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < attestors.length; i++) {
            if (attestors[i] == address(0)) revert InvalidAddress();
            bool wasAuthorized = authorizedAttestors[attestors[i]];
            authorizedAttestors[attestors[i]] = authorized[i];

            if (authorized[i] && !wasAuthorized) {
                attestorCount++;
            } else if (!authorized[i] && wasAuthorized) {
                attestorCount--;
            }

            emit AttestorUpdated(attestors[i], authorized[i]);
        }

        if (attestationThreshold > attestorCount && attestorCount > 0) {
            uint256 oldThreshold = attestationThreshold;
            attestationThreshold = attestorCount;
            emit ThresholdUpdated(oldThreshold, attestorCount);
        }
    }

    /**
     * @notice Check authorization for multiple addresses
     * @param addresses Array of addresses to check
     * @return authorized Array of authorization flags
     */
    function batchIsAuthorized(
        address[] calldata addresses
    ) external view returns (bool[] memory authorized) {
        authorized = new bool[](addresses.length);
        for (uint256 i = 0; i < addresses.length; i++) {
            authorized[i] = authorizedAttestors[addresses[i]];
        }
        return authorized;
    }

    // =========================================================================
    // Historical Analytics
    // =========================================================================

    /**
     * @notice Get NAV statistics over history
     * @return avgNav Average NAV per share
     * @return minNav Minimum NAV per share
     * @return maxNav Maximum NAV per share
     * @return volatility Standard deviation estimate (simplified)
     * @return historyCount Number of historical reports
     */
    function getNAVStatistics() external view returns (
        uint256 avgNav,
        uint256 minNav,
        uint256 maxNav,
        uint256 volatility,
        uint256 historyCount
    ) {
        historyCount = _navHistory.length;

        if (historyCount == 0) {
            return (_currentNAV.navPerShare, _currentNAV.navPerShare, _currentNAV.navPerShare, 0, 0);
        }

        uint256 sum = _currentNAV.navPerShare;
        minNav = _currentNAV.navPerShare;
        maxNav = _currentNAV.navPerShare;

        for (uint256 i = 0; i < historyCount; i++) {
            uint256 nav = _navHistory[i].navPerShare;
            sum += nav;

            if (nav < minNav) minNav = nav;
            if (nav > maxNav) maxNav = nav;
        }

        avgNav = sum / (historyCount + 1);

        // Simple volatility estimate: range / average (in basis points)
        if (avgNav > 0) {
            volatility = ((maxNav - minNav) * BPS_DENOMINATOR) / avgNav;
        }

        return (avgNav, minNav, maxNav, volatility, historyCount);
    }

    /**
     * @notice Get NAV change trend
     * @return currentNav Current NAV per share
     * @return previousNav Previous NAV per share (or current if no history)
     * @return changeBps Change in basis points
     * @return isPositive True if NAV increased
     */
    function getNAVTrend() external view returns (
        uint256 currentNav,
        uint256 previousNav,
        uint256 changeBps,
        bool isPositive
    ) {
        currentNav = _currentNAV.navPerShare;

        if (_navHistory.length == 0) {
            return (currentNav, currentNav, 0, true);
        }

        previousNav = _navHistory[_navHistory.length - 1].navPerShare;

        if (currentNav >= previousNav) {
            isPositive = true;
            changeBps = ((currentNav - previousNav) * BPS_DENOMINATOR) / previousNav;
        } else {
            isPositive = false;
            changeBps = ((previousNav - currentNav) * BPS_DENOMINATOR) / previousNav;
        }

        return (currentNav, previousNav, changeBps, isPositive);
    }

    /**
     * @notice Get NAV at specific historical index
     * @param index History index (0 = oldest)
     * @return report NAV report at index
     */
    function getHistoricalNAV(uint256 index) external view returns (NAVReport memory report) {
        if (index >= _navHistory.length) {
            return _currentNAV;
        }
        return _navHistory[index];
    }

    /**
     * @notice Get cumulative yield since a baseline
     * @param baselineNav NAV per share at baseline
     * @return yieldBps Yield in basis points
     * @return yieldAmount Yield amount per share
     */
    function getCumulativeYield(
        uint256 baselineNav
    ) external view returns (uint256 yieldBps, uint256 yieldAmount) {
        uint256 currentNav = _currentNAV.navPerShare;

        if (currentNav > baselineNav) {
            yieldAmount = currentNav - baselineNav;
            yieldBps = (yieldAmount * BPS_DENOMINATOR) / baselineNav;
        }

        return (yieldBps, yieldAmount);
    }

    /**
     * @notice Calculate annualized yield based on history
     * @return annualizedBps Estimated annualized yield in basis points
     * @return periodDays Number of days in calculation period
     */
    function getAnnualizedYield() external view returns (
        uint256 annualizedBps,
        uint256 periodDays
    ) {
        if (_navHistory.length == 0) {
            return (0, 0);
        }

        NAVReport memory oldest = _navHistory[0];
        uint256 currentNav = _currentNAV.navPerShare;
        uint256 startNav = oldest.navPerShare;

        if (startNav == 0 || currentNav <= startNav) {
            return (0, 0);
        }

        uint256 periodSeconds = _currentNAV.timestamp - oldest.timestamp;
        if (periodSeconds == 0) {
            return (0, 0);
        }

        periodDays = periodSeconds / 1 days;
        if (periodDays == 0) periodDays = 1;

        // Calculate total yield in bps
        uint256 totalYieldBps = ((currentNav - startNav) * BPS_DENOMINATOR) / startNav;

        // Annualize: (totalYield / days) * 365
        annualizedBps = (totalYieldBps * 365) / periodDays;

        return (annualizedBps, periodDays);
    }

    /**
     * @notice Get NAV reports within a date range
     * @param startDate Start date (YYYYMMDD format)
     * @param endDate End date (YYYYMMDD format)
     * @return reports Array of NAV reports in range
     */
    function getNAVHistoryInRange(
        uint256 startDate,
        uint256 endDate
    ) external view returns (NAVReport[] memory reports) {
        // Count matching reports
        uint256 count = 0;
        for (uint256 i = 0; i < _navHistory.length; i++) {
            if (_navHistory[i].reportDate >= startDate && _navHistory[i].reportDate <= endDate) {
                count++;
            }
        }

        // Include current NAV if in range
        bool includesCurrent = _currentNAV.reportDate >= startDate && _currentNAV.reportDate <= endDate;
        if (includesCurrent) count++;

        // Build result array
        reports = new NAVReport[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < _navHistory.length; i++) {
            if (_navHistory[i].reportDate >= startDate && _navHistory[i].reportDate <= endDate) {
                reports[idx++] = _navHistory[i];
            }
        }

        if (includesCurrent) {
            reports[idx] = _currentNAV;
        }

        return reports;
    }

    /**
     * @notice Check health of NAV oracle
     * @return isFresh NAV is within staleness period
     * @return hasHistory Has historical data
     * @return hasAttestor Has at least one attestor
     * @return SSDCLinked SSDC contract is linked
     * @return healthScore Overall health score (0-100)
     */
function getOracleHealth() external view returns (
        bool isFresh,
        bool hasHistory,
        bool hasAttestor,
        bool SSDCLinked,
        uint256 healthScore
    ) {
        isFresh = block.timestamp <= _currentNAV.timestamp + maxStalenessSeconds;
        hasHistory = _navHistory.length > 0;
        hasAttestor = authorizedAttestors[_currentNAV.attestor];
        SSDCLinked = SSDC != address(0);

        healthScore = 0;
        if (isFresh) healthScore += 40;
        if (hasHistory) healthScore += 20;
        if (hasAttestor) healthScore += 20;
        if (SSDCLinked) healthScore += 20;

        return (isFresh, hasHistory, hasAttestor, SSDCLinked, healthScore);
    }

    // =========================================================================
    // Upgrade
    // =========================================================================

    /**
     * @dev Authorize upgrade (owner only)
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {
        emit ContractUpgraded(newImplementation, msg.sender);
    }

    function _setSSDC(address ssdc_) internal {
        if (ssdc_ == address(0)) revert InvalidAddress();
        SSDC = ssdc_;
        emit SSDCUpdated(ssdc_);
        emit ssUSDUpdated(ssdc_);
    }

    // =========================================================================
    // Storage Gap
    // =========================================================================

    uint256[50] private __gap;
}
