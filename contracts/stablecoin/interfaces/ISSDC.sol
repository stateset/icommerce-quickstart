// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ISSDC
 * @notice Interface for StateSet Dollar Coin (rebasing stablecoin)
 */
interface ISSDC is IERC20 {
    // =========================================================================
    // Events
    // =========================================================================

    event SharesMinted(address indexed to, uint256 shares, uint256 amount);

    event SharesBurned(address indexed from, uint256 shares, uint256 amount);

    event SharesTransferred(address indexed from, address indexed to, uint256 shares);

    event TreasuryVaultUpdated(address indexed treasuryVault);

    event NavOracleUpdated(address indexed oldOracle, address indexed newOracle);

    // =========================================================================
    // Shares Interface
    // =========================================================================

    /**
     * @notice Get shares held by an account
     * @param account Address to query
     * @return shares Number of shares
     */
    function sharesOf(address account) external view returns (uint256 shares);

    /**
     * @notice Get total shares outstanding
     * @return Total shares
     */
    function totalShares() external view returns (uint256);

    /**
     * @notice Convert amount to shares at current NAV
     * @param amount Amount in SSDC terms
     * @return shares Equivalent shares
     */
    function getSharesByAmount(uint256 amount) external view returns (uint256 shares);

    /**
     * @notice Convert shares to amount at current NAV
     * @param shares Number of shares
     * @return amount Equivalent SSDC amount
     */
    function getAmountByShares(uint256 shares) external view returns (uint256 amount);

    /**
     * @notice Transfer shares directly
     * @param to Recipient
     * @param shares Shares to transfer
     * @return success True if successful
     */
    function transferShares(address to, uint256 shares) external returns (bool success);

    /**
     * @notice Transfer shares from another account
     * @param from Source account
     * @param to Recipient
     * @param shares Shares to transfer
     * @return success True if successful
     */
    function transferSharesFrom(
        address from,
        address to,
        uint256 shares
    ) external returns (bool success);

    // =========================================================================
    // Minting/Burning (TreasuryVault only)
    // =========================================================================

    /**
     * @notice Mint shares to an account
     * @param to Recipient
     * @param shares Shares to mint
     */
    function mintShares(address to, uint256 shares) external;

    /**
     * @notice Burn shares from an account
     * @param from Account to burn from
     * @param shares Shares to burn
     */
    function burnShares(address from, uint256 shares) external;

    // =========================================================================
    // NAV Interface
    // =========================================================================

    /**
     * @notice Get current NAV per share
     * @return NAV per share (1e18 = $1.00)
     */
    function getNavPerShare() external view returns (uint256);

    /**
     * @notice Get the NAV oracle address
     * @return NAV oracle contract
     */
    function navOracle() external view returns (address);

    /**
     * @notice Get the treasury vault address
     * @return Treasury vault contract
     */
    function treasuryVault() external view returns (address);

    // =========================================================================
    // Admin
    // =========================================================================

    /**
     * @notice Set treasury vault address
     * @param treasuryVault_ New treasury vault
     */
    function setTreasuryVault(address treasuryVault_) external;
}