// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/ISSDC.sol";
import "./interfaces/INAVOracle.sol";

/**
 * @title SSDC (StateSet Dollar Coin)
 * @notice Rebasing stablecoin backed by T-Bills
 * @dev Internal shares-based accounting, external rebasing balanceOf
 *
 * Key mechanics:
 * - _shares[account]: Fixed internal accounting (only changes on transfer/mint/burn)
 * - balanceOf(account): Returns shares × NAV per share (rebases with yield)
 * - totalSupply(): Returns total shares × NAV per share
 *
 * This design allows yield distribution without gas costs per holder.
 */
contract SSDC is
    ISSDC,
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Precision for calculations
    uint256 public constant PRECISION = 1e18;

    /// @notice Token decimals
    uint8 public constant DECIMALS = 18;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice Token name
    string private _name;

    /// @notice Token symbol
    string private _symbol;

    /// @notice Shares per account
    mapping(address => uint256) private _shares;

    /// @notice Allowances (in amount terms, not shares)
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @notice Total shares outstanding
    uint256 private _totalShares;

    /// @notice NAV oracle contract
    address public navOracle;

    /// @notice Treasury vault (only address that can mint/burn)
    address public treasuryVault;

    // =========================================================================
    // Staleness Protection
    // =========================================================================

    /// @notice Whether to enforce NAV staleness checks
    bool public enforceNavStaleness;

    /// @notice Behavior when NAV is stale: true = revert, false = use fallback ($1.00)
    bool public revertOnStaleNav;

    /// @notice Event emitted when stale NAV fallback is used
    event StaleNavFallback(uint256 staleTimestamp, uint256 fallbackNav);

    /// @notice Event emitted when staleness settings change
    event StalenessSettingsUpdated(bool enforced, bool revertOnStale);

    // =========================================================================
    // Enhanced Monitoring Events
    // =========================================================================

    /// @notice Emitted for large transfers (configurable threshold)
    event LargeTransfer(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 shares,
        uint256 navPerShare
    );

    /// @notice Threshold for large transfer alerts (in USD, 18 decimals)
    uint256 public largeTransferThreshold;

    /// @notice Emitted when total supply changes significantly
    event SupplyChange(
        uint256 previousSupply,
        uint256 newSupply,
        int256 delta,
        string indexed changeType  // "mint" or "burn"
    );

    /// @notice Emitted when contract is upgraded
    event ContractUpgraded(address indexed newImplementation, address indexed authorizer);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotTreasuryVault();
    error TransferToZeroAddress();
    error TransferFromZeroAddress();
    error TransferAmountExceedsBalance();
    error TransferSharesExceedsBalance();
    error ApproveToZeroAddress();
    error ApproveFromZeroAddress();
    error InsufficientAllowance();
    error MintToZeroAddress();
    error BurnFromZeroAddress();
    error BurnAmountExceedsBalance();
    error StaleNAV();
    error InvalidAddress();
    error ArrayLengthMismatch();
    error EmptyArray();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyTreasury() {
        if (msg.sender != treasuryVault) revert NotTreasuryVault();
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
     * @notice Initialize SSDC
     * @param owner_ Owner address
     * @param navOracle_ NAV oracle address
     */
    function initialize(
        address owner_,
        address navOracle_
    ) public initializer {
        __Ownable_init(owner_);
        __Pausable_init();
        __UUPSUpgradeable_init();

        _name = "StateSet Dollar Coin";
        _symbol = "SSDC";
        navOracle = navOracle_;
    }

    // =========================================================================
    // ERC20 Interface (Rebasing)
    // =========================================================================

    /**
     * @notice Token name
     */
    function name() external view returns (string memory) {
        return _name;
    }

    /**
     * @notice Token symbol
     */
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /**
     * @notice Token decimals
     */
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Total supply (rebasing)
     * @dev Returns total shares × NAV per share
     */
    function totalSupply() external view returns (uint256) {
        return _sharesToAmountView(_totalShares);
    }

    /**
     * @notice Balance of account (rebasing)
     * @dev Returns shares × NAV per share
     */
    function balanceOf(address account) external view returns (uint256) {
        return _sharesToAmountView(_shares[account]);
    }

    /**
     * @notice Transfer tokens
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Get allowance
     */
    function allowance(
        address owner_,
        address spender
    ) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    /**
     * @notice Approve spender
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Increase the allowance granted to `spender`
     * @dev Atomic increase to avoid race conditions
     * @param spender Account to increase allowance for
     * @param addedValue Amount to add to current allowance
     * @return True if successful
     */
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        address owner_ = msg.sender;
        _approve(owner_, spender, _allowances[owner_][spender] + addedValue);
        return true;
    }

    /**
     * @notice Decrease the allowance granted to `spender`
     * @dev Atomic decrease to avoid race conditions
     * @param spender Account to decrease allowance for
     * @param subtractedValue Amount to subtract from current allowance
     * @return True if successful
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        address owner_ = msg.sender;
        uint256 currentAllowance = _allowances[owner_][spender];
        if (currentAllowance < subtractedValue) {
            revert InsufficientAllowance();
        }
        unchecked {
            _approve(owner_, spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    /**
     * @notice Transfer from another account
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // =========================================================================
    // Shares Interface
    // =========================================================================

    /**
     * @notice Get shares of account
     */
    function sharesOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    /**
     * @notice Get total shares
     */
    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    /**
     * @notice Convert amount to shares
     */
    function getSharesByAmount(uint256 amount) external view returns (uint256) {
        return _amountToSharesView(amount);
    }

    /**
     * @notice Convert shares to amount
     */
    function getAmountByShares(uint256 shares) external view returns (uint256) {
        return _sharesToAmountView(shares);
    }

    /**
     * @notice Transfer shares directly
     */
    function transferShares(address to, uint256 shares) external returns (bool) {
        _transferShares(msg.sender, to, shares);
        return true;
    }

    /**
     * @notice Transfer shares from another account
     */
    function transferSharesFrom(
        address from,
        address to,
        uint256 shares
    ) external returns (bool) {
        uint256 amount = _sharesToAmount(shares);
        _spendAllowance(from, msg.sender, amount);
        _transferShares(from, to, shares);
        return true;
    }

    // =========================================================================
    // Minting/Burning (Treasury Only)
    // =========================================================================

    /**
     * @notice Mint shares
     * @param to Recipient
     * @param shares Shares to mint
     */
    function mintShares(address to, uint256 shares) external onlyTreasury {
        if (to == address(0)) revert MintToZeroAddress();

        _totalShares += shares;
        _shares[to] += shares;

        uint256 amount = _sharesToAmount(shares);
        emit Transfer(address(0), to, amount);
        emit SharesMinted(to, shares, amount);
    }

    /**
     * @notice Burn shares
     * @param from Account to burn from
     * @param shares Shares to burn
     */
    function burnShares(address from, uint256 shares) external onlyTreasury {
        if (from == address(0)) revert BurnFromZeroAddress();
        if (_shares[from] < shares) revert BurnAmountExceedsBalance();

        _shares[from] -= shares;
        _totalShares -= shares;

        uint256 amount = _sharesToAmount(shares);
        emit Transfer(from, address(0), amount);
        emit SharesBurned(from, shares, amount);
    }

    // =========================================================================
    // NAV Interface
    // =========================================================================

    /**
     * @notice Get current NAV per share
     */
    function getNavPerShare() external view returns (uint256) {
        return _getNavPerShareView();
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /**
     * @notice Set treasury vault
     * @param treasuryVault_ New treasury vault address
     */
    function setTreasuryVault(address treasuryVault_) external onlyOwner {
        if (treasuryVault_ == address(0)) revert InvalidAddress();
        treasuryVault = treasuryVault_;
        emit TreasuryVaultUpdated(treasuryVault_);
    }

    /**
     * @notice Set NAV oracle
     * @param navOracle_ New NAV oracle address
     */
    function setNavOracle(address navOracle_) external onlyOwner {
        if (navOracle_ == address(0)) revert InvalidAddress();
        address oldOracle = navOracle;
        navOracle = navOracle_;
        emit NavOracleUpdated(oldOracle, navOracle_);
    }

    /**
     * @notice Configure NAV staleness protection
     * @param enforce_ Whether to check NAV staleness
     * @param revertOnStale_ If true, revert on stale NAV; if false, use $1.00 fallback
     * @dev Recommended: enforce_=true, revertOnStale_=false for graceful degradation
     *      For maximum safety: enforce_=true, revertOnStale_=true
     */
    function setStalenessSettings(bool enforce_, bool revertOnStale_) external onlyOwner {
        enforceNavStaleness = enforce_;
        revertOnStaleNav = revertOnStale_;
        emit StalenessSettingsUpdated(enforce_, revertOnStale_);
    }

    /**
     * @notice Check if NAV is currently stale
     * @return isStale True if NAV oracle reports stale data
     * @return timestamp Last NAV update timestamp
     */
    function isNavStale() external view returns (bool isStale, uint256 timestamp) {
        if (navOracle == address(0)) {
            return (false, 0);
        }
        INAVOracle oracle = INAVOracle(navOracle);
        INAVOracle.NAVReport memory report = oracle.getCurrentNAV();
        return (!oracle.isNAVFresh(), report.timestamp);
    }

    /**
     * @notice Set threshold for large transfer monitoring
     * @param threshold_ Threshold in USD (18 decimals), 0 to disable
     */
    function setLargeTransferThreshold(uint256 threshold_) external onlyOwner {
        largeTransferThreshold = threshold_;
        emit LargeTransferThresholdUpdated(threshold_);
    }

    /// @notice Event when large transfer threshold changes
    event LargeTransferThresholdUpdated(uint256 newThreshold);

    /**
     * @notice Pause all token transfers
     * @dev Can only be called by owner in emergency situations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause token transfers
     * @dev Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /**
     * @dev Get NAV per share from oracle with staleness check
     * @notice If enforceNavStaleness is true:
     *         - revertOnStaleNav = true: reverts with StaleNAV error
     *         - revertOnStaleNav = false: returns $1.00 fallback (emits event in non-view context)
     */
    function _getNavPerShare() internal returns (uint256) {
        uint256 nav = _resolveNav();
        if (nav == PRECISION && navOracle != address(0) && enforceNavStaleness) {
            // Stale NAV fallback — emit warning only in non-view context
            emit StaleNavFallback(block.timestamp, PRECISION);
        }
        return nav;
    }

    /**
     * @dev Get NAV per share (view version - no event emission)
     */
    function _getNavPerShareView() internal view returns (uint256) {
        return _resolveNav();
    }

    /**
     * @dev Core NAV resolution logic shared by view and non-view callers
     */
    function _resolveNav() internal view returns (uint256) {
        if (navOracle == address(0)) {
            return PRECISION; // $1.00 default
        }

        INAVOracle oracle = INAVOracle(navOracle);

        if (enforceNavStaleness && !oracle.isNAVFresh()) {
            if (revertOnStaleNav) {
                revert StaleNAV();
            }
            return PRECISION; // Fallback to $1.00
        }

        return oracle.getCurrentNAVPerShare();
    }

    /**
     * @dev Convert amount to shares using current NAV
     */
    function _amountToShares(uint256 amount) internal returns (uint256) {
        return (amount * PRECISION) / _getNavPerShare();
    }

    /**
     * @dev Convert amount to shares (view version)
     */
    function _amountToSharesView(uint256 amount) internal view returns (uint256) {
        return (amount * PRECISION) / _resolveNav();
    }

    /**
     * @dev Convert shares to amount using current NAV
     */
    function _sharesToAmount(uint256 shares) internal returns (uint256) {
        return (shares * _getNavPerShare()) / PRECISION;
    }

    /**
     * @dev Convert shares to amount (view version)
     */
    function _sharesToAmountView(uint256 shares) internal view returns (uint256) {
        return (shares * _resolveNav()) / PRECISION;
    }

    /**
     * @dev Transfer tokens (converts amount to shares internally)
     * @notice Reverts when paused
     */
    function _transfer(address from, address to, uint256 amount) internal whenNotPaused {
        if (from == address(0)) revert TransferFromZeroAddress();
        if (to == address(0)) revert TransferToZeroAddress();

        uint256 sharesToTransfer = _amountToShares(amount);

        if (_shares[from] < sharesToTransfer) {
            revert TransferAmountExceedsBalance();
        }

        _shares[from] -= sharesToTransfer;
        _shares[to] += sharesToTransfer;

        emit Transfer(from, to, amount);
        emit SharesTransferred(from, to, sharesToTransfer);

        // Emit monitoring event for large transfers
        if (largeTransferThreshold > 0 && amount >= largeTransferThreshold) {
            emit LargeTransfer(from, to, amount, sharesToTransfer, _getNavPerShareView());
        }
    }

    /**
     * @dev Transfer shares directly
     * @notice Reverts when paused
     */
    function _transferShares(address from, address to, uint256 shares) internal whenNotPaused {
        if (from == address(0)) revert TransferFromZeroAddress();
        if (to == address(0)) revert TransferToZeroAddress();
        if (_shares[from] < shares) revert TransferSharesExceedsBalance();

        _shares[from] -= shares;
        _shares[to] += shares;

        uint256 amount = _sharesToAmount(shares);
        emit Transfer(from, to, amount);
        emit SharesTransferred(from, to, shares);
    }

    /**
     * @dev Approve spender
     */
    function _approve(address owner_, address spender, uint256 amount) internal {
        if (owner_ == address(0)) revert ApproveFromZeroAddress();
        if (spender == address(0)) revert ApproveToZeroAddress();

        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    /**
     * @dev Spend allowance
     */
    function _spendAllowance(
        address owner_,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = _allowances[owner_][spender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert InsufficientAllowance();
            _allowances[owner_][spender] = currentAllowance - amount;
        }
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

    // =========================================================================
    // Batch Operations
    // =========================================================================

    /**
     * @notice Transfer to multiple recipients
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to transfer
     * @return success True if all transfers succeeded
     */
    function batchTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external returns (bool success) {
        if (recipients.length == 0) revert EmptyArray();
        if (recipients.length != amounts.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < recipients.length; i++) {
            _transfer(msg.sender, recipients[i], amounts[i]);
        }

        return true;
    }

    /**
     * @notice Transfer shares to multiple recipients
     * @param recipients Array of recipient addresses
     * @param sharesAmounts Array of shares to transfer
     * @return success True if all transfers succeeded
     */
    function batchTransferShares(
        address[] calldata recipients,
        uint256[] calldata sharesAmounts
    ) external returns (bool success) {
        if (recipients.length == 0) revert EmptyArray();
        if (recipients.length != sharesAmounts.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < recipients.length; i++) {
            _transferShares(msg.sender, recipients[i], sharesAmounts[i]);
        }

        return true;
    }

    // =========================================================================
    // Monitoring Functions
    // =========================================================================

    /**
     * @notice Get comprehensive token status
     * @return totalSupply_ Total supply (rebased)
     * @return totalShares_ Total shares outstanding
     * @return navPerShare_ Current NAV per share
     * @return isPaused_ Whether transfers are paused
     * @return treasuryVault_ Treasury vault address
     * @return navOracle_ NAV oracle address
     */
    function getTokenStatus() external view returns (
        uint256 totalSupply_,
        uint256 totalShares_,
        uint256 navPerShare_,
        bool isPaused_,
        address treasuryVault_,
        address navOracle_
    ) {
        navPerShare_ = _getNavPerShareView();
        return (
            _sharesToAmountView(_totalShares),
            _totalShares,
            navPerShare_,
            paused(),
            treasuryVault,
            navOracle
        );
    }

    /**
     * @notice Get account details including shares and rebased balance
     * @param account Account to query
     * @return balance Rebased balance
     * @return shares Account's shares
     * @return percentOfSupply Percentage of total supply (basis points)
     */
    function getAccountDetails(address account) external view returns (
        uint256 balance,
        uint256 shares,
        uint256 percentOfSupply
    ) {
        shares = _shares[account];
        balance = _sharesToAmountView(shares);

        if (_totalShares > 0) {
            percentOfSupply = (shares * 10000) / _totalShares;
        } else {
            percentOfSupply = 0;
        }

        return (balance, shares, percentOfSupply);
    }

    /**
     * @notice Get balances for multiple accounts
     * @param accounts Array of account addresses
     * @return balances Array of rebased balances
     */
    function batchBalanceOf(
        address[] calldata accounts
    ) external view returns (uint256[] memory balances) {
        balances = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            balances[i] = _sharesToAmountView(_shares[accounts[i]]);
        }
        return balances;
    }

    /**
     * @notice Get shares for multiple accounts
     * @param accounts Array of account addresses
     * @return shares Array of shares
     */
    function batchSharesOf(
        address[] calldata accounts
    ) external view returns (uint256[] memory shares) {
        shares = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            shares[i] = _shares[accounts[i]];
        }
        return shares;
    }

    /**
     * @notice Convert multiple amounts to shares
     * @param amounts Array of amounts
     * @return shares Array of equivalent shares
     */
    function batchGetSharesByAmount(
        uint256[] calldata amounts
    ) external view returns (uint256[] memory shares) {
        shares = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; i++) {
            shares[i] = _amountToSharesView(amounts[i]);
        }
        return shares;
    }

    /**
     * @notice Convert multiple shares to amounts
     * @param sharesArray Array of shares
     * @return amounts Array of equivalent amounts
     */
    function batchGetAmountByShares(
        uint256[] calldata sharesArray
    ) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](sharesArray.length);
        for (uint256 i = 0; i < sharesArray.length; i++) {
            amounts[i] = _sharesToAmountView(sharesArray[i]);
        }
        return amounts;
    }

    /**
     * @notice Calculate expected balance after NAV change
     * @param account Account to simulate for
     * @param newNavPerShare Hypothetical NAV per share
     * @return expectedBalance Expected balance at new NAV
     */
    function simulateBalanceAtNAV(
        address account,
        uint256 newNavPerShare
    ) external view returns (uint256 expectedBalance) {
        uint256 shares = _shares[account];
        return (shares * newNavPerShare) / PRECISION;
    }

    /**
     * @notice Get yield accrued compared to a baseline NAV
     * @param account Account to check
     * @param baselineNAV NAV per share at baseline (e.g., when deposited)
     * @return yieldAccrued Amount of yield earned
     * @return yieldPercent Yield percentage (basis points)
     */
    function getAccruedYield(
        address account,
        uint256 baselineNAV
    ) external view returns (uint256 yieldAccrued, uint256 yieldPercent) {
        uint256 shares = _shares[account];
        uint256 currentNAV = _getNavPerShareView();

        uint256 currentValue = (shares * currentNAV) / PRECISION;
        uint256 baselineValue = (shares * baselineNAV) / PRECISION;

        if (currentValue > baselineValue) {
            yieldAccrued = currentValue - baselineValue;
            if (baselineValue > 0) {
                yieldPercent = (yieldAccrued * 10000) / baselineValue;
            }
        }

        return (yieldAccrued, yieldPercent);
    }

    // =========================================================================
    // Storage Gap
    // =========================================================================

    uint256[50] private __gap;
}