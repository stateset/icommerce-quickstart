// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title INAVOracle
 * @notice Interface for T-Bill NAV attestation oracle
 */
interface INAVOracle {
    // =========================================================================
    // Types
    // =========================================================================

    struct NAVReport {
        uint256 totalAssets;      // Total T-Bill value in USD (18 decimals)
        uint256 totalShares;      // Total ssUSD shares outstanding
        uint256 navPerShare;      // NAV per share (1e18 = $1.00)
        uint256 timestamp;        // Block timestamp of attestation
        uint256 reportDate;       // Date of T-Bill valuation (YYYYMMDD)
        bytes32 proofHash;        // Hash of off-chain proof documents
        address attestor;         // Address that submitted attestation
    }

    // =========================================================================
    // Events
    // =========================================================================

    event NAVAttested(
        uint256 totalAssets,
        uint256 navPerShare,
        uint256 reportDate,
        address indexed attestor
    );

    event AttestorUpdated(address indexed attestor, bool authorized);

    event StalenessUpdated(uint256 maxStalenessSeconds);

    event SSDCUpdated(address indexed SSDC);

    event MaxNavChangeBpsUpdated(uint256 bps);

    // =========================================================================
    // Functions
    // =========================================================================

    function attestNAV(
        uint256 totalAssets,
        uint256 reportDate,
        bytes32 proofHash
    ) external;

    function getCurrentNAVPerShare() external view returns (uint256);

    function getTotalAssets() external view returns (uint256);

    function getLastReportDate() external view returns (uint256);

    function isNAVFresh() external view returns (bool);

    function getCurrentNAV() external view returns (NAVReport memory);

    function getNAVHistory(uint256 count) external view returns (NAVReport[] memory);

    function setAuthorizedAttestor(address attestor, bool authorized) external;

    function setMaxStaleness(uint256 seconds_) external;

    function setSSDC(address SSDC_) external;

    function authorizedAttestors(address attestor) external view returns (bool);

    function maxStalenessSeconds() external view returns (uint256);
}
