// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title SetPaymaster
 * @notice Gas abstraction for commerce transactions on Set Chain
 * @dev Operator-managed ETH sponsorship vault for authorized merchants.
 *      This contract does not implement ERC-4337 paymaster validation and does not
 *      bind payouts to a specific transaction hash or measured gas usage.
 *
 * Key features:
 * - Merchant sponsorship with spend limits
 * - Per-transaction and daily limits
 * - Category-based sponsorship tiers
 * - Automatic refund of unused gas
 */
contract SetPaymaster is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Sponsorship tier with limits
    /// @dev Packed: name(string=2 slots) + limits(16+16=1 slot) + month+active(16+1=1 slot)
    struct SponsorshipTier {
        string name;
        uint128 maxPerTransaction;  // Max gas sponsorship per tx (wei), max ~3.4e38
        uint128 maxPerDay;          // Max gas sponsorship per day (wei)
        uint128 maxPerMonth;        // Max gas sponsorship per month (wei)
        bool active;
    }

    /// @notice Merchant sponsorship record
    /// @dev Packed into 3 storage slots (was 7):
    ///   Slot 1: active(1) + tierId(1) + lastDayReset(8) + lastMonthReset(8) = 18 bytes
    ///   Slot 2: spentToday(16) + spentThisMonth(16) = 32 bytes
    ///   Slot 3: totalSponsored(16) = 16 bytes
    struct MerchantSponsorship {
        bool active;
        uint8 tierId;
        uint64 lastDayReset;
        uint64 lastMonthReset;
        uint128 spentToday;
        uint128 spentThisMonth;
        uint128 totalSponsored;
    }

    /// @notice Commerce operation types that can be sponsored
    enum OperationType {
        ORDER_CREATE,
        ORDER_UPDATE,
        PAYMENT_PROCESS,
        INVENTORY_UPDATE,
        RETURN_PROCESS,
        COMMITMENT_ANCHOR,
        OTHER
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Sponsorship tiers
    mapping(uint256 => SponsorshipTier) public tiers;

    /// @notice Next tier ID
    uint256 public nextTierId;

    /// @notice Merchant sponsorships
    mapping(address => MerchantSponsorship) public merchantSponsorship;

    /// @notice Total gas sponsored
    uint256 public totalGasSponsored;

    /// @notice Treasury address for deposits
    address public treasury;

    /// @notice Minimum deposit to sponsor
    uint256 public minDeposit;

    /// @notice Operator addresses that can execute sponsorships
    mapping(address => bool) public operators;

    // =========================================================================
    // Events
    // =========================================================================

    event TierCreated(uint256 indexed tierId, string name, uint256 maxPerTx, uint256 maxPerDay);
    event TierUpdated(uint256 indexed tierId, uint256 maxPerTx, uint256 maxPerDay);
    event TierStatusUpdated(uint256 indexed tierId, bool active);
    event MerchantSponsored(address indexed merchant, uint256 tierId);
    event MerchantRevoked(address indexed merchant);
    event GasSponsored(address indexed merchant, uint256 amount, OperationType operationType);
    event GasRefunded(address indexed merchant, uint256 amount);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event OperatorUpdated(address indexed operator, bool authorized);
    event MinDepositUpdated(uint256 minDeposit);
    event BatchSponsorshipCompleted(uint256 processed, uint256 succeeded, uint256 failed);
    event BatchSponsorshipFailed(address indexed merchant, string reason);
    event ContractUpgraded(address indexed newImplementation, address indexed authorizer);

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum merchants per batch operation
    uint256 public constant MAX_BATCH_SIZE = 100;

    // =========================================================================
    // Errors
    // =========================================================================

    error NotSponsored();
    error TierNotActive();
    error ExceedsTransactionLimit(uint256 requested, uint256 max);
    error ExceedsDailyLimit(uint256 requested, uint256 remaining);
    error ExceedsMonthlyLimit(uint256 requested, uint256 remaining);
    error InsufficientBalance();
    error NotOperator();
    error InvalidTier();
    error InvalidTierLimits();
    error InvalidAddress();
    error ArrayLengthMismatch();
    error BatchTooLarge();
    error EmptyArray();
    error TransferFailed();
    error BelowMinimumDeposit(uint256 sent, uint256 minimum);
    error WithdrawFailed();
    error InvalidRefundAmount();
    error RefundValueMismatch(uint256 expected, uint256 actual);
    error RefundExceedsSponsored(uint256 requested, uint256 available);

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) {
            revert NotOperator();
        }
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
     * @notice Initialize the paymaster
     * @param _owner Owner address
     * @param _treasury Treasury address for deposits
     */
    function initialize(
        address _owner,
        address _treasury
    ) public initializer {
        if (_owner == address(0) || _treasury == address(0)) {
            revert InvalidAddress();
        }
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        treasury = _treasury;
        minDeposit = 0.01 ether;

        // Create default tiers
        _createDefaultTiers();
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /**
     * @notice Create a new sponsorship tier
     * @param _name Tier name
     * @param _maxPerTx Max per transaction
     * @param _maxPerDay Max per day
     * @param _maxPerMonth Max per month
     */
    function createTier(
        string calldata _name,
        uint256 _maxPerTx,
        uint256 _maxPerDay,
        uint256 _maxPerMonth
    ) external onlyOwner returns (uint256 tierId) {
        if (_maxPerTx > _maxPerDay || _maxPerDay > _maxPerMonth) {
            revert InvalidTierLimits();
        }
        if (_maxPerMonth > type(uint128).max) {
            revert InvalidTierLimits();
        }
        tierId = nextTierId++;

        tiers[tierId] = SponsorshipTier({
            name: _name,
            maxPerTransaction: uint128(_maxPerTx),
            maxPerDay: uint128(_maxPerDay),
            maxPerMonth: uint128(_maxPerMonth),
            active: true
        });

        emit TierCreated(tierId, _name, _maxPerTx, _maxPerDay);
    }

    /**
     * @notice Update an existing tier
     * @param _tierId Tier ID
     * @param _maxPerTx Max per transaction
     * @param _maxPerDay Max per day
     * @param _maxPerMonth Max per month
     */
    function updateTier(
        uint256 _tierId,
        uint256 _maxPerTx,
        uint256 _maxPerDay,
        uint256 _maxPerMonth
    ) external onlyOwner {
        if (_tierId >= nextTierId) {
            revert InvalidTier();
        }
        if (_maxPerTx > _maxPerDay || _maxPerDay > _maxPerMonth) {
            revert InvalidTierLimits();
        }
        if (_maxPerMonth > type(uint128).max) {
            revert InvalidTierLimits();
        }
        SponsorshipTier storage tier = tiers[_tierId];
        tier.maxPerTransaction = uint128(_maxPerTx);
        tier.maxPerDay = uint128(_maxPerDay);
        tier.maxPerMonth = uint128(_maxPerMonth);

        emit TierUpdated(_tierId, _maxPerTx, _maxPerDay);
    }

    /**
     * @notice Enable or disable a tier
     * @param _tierId Tier ID
     * @param _active Whether the tier is active
     */
    function setTierActive(uint256 _tierId, bool _active) external onlyOwner {
        if (_tierId >= nextTierId) {
            revert InvalidTier();
        }

        tiers[_tierId].active = _active;
        emit TierStatusUpdated(_tierId, _active);
    }

    /**
     * @notice Set operator authorization
     * @param _operator Operator address
     * @param _authorized Whether authorized
     */
    function setOperator(address _operator, bool _authorized) external onlyOwner {
        if (_operator == address(0)) {
            revert InvalidAddress();
        }
        operators[_operator] = _authorized;
        emit OperatorUpdated(_operator, _authorized);
    }

    /**
     * @notice Update treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) {
            revert InvalidAddress();
        }
        treasury = _treasury;
    }

    /**
     * @notice Update minimum deposit amount
     * @param _minDeposit New minimum deposit
     */
    function setMinDeposit(uint256 _minDeposit) external onlyOwner {
        minDeposit = _minDeposit;
        emit MinDepositUpdated(_minDeposit);
    }

    // =========================================================================
    // Merchant Functions
    // =========================================================================

    /**
     * @notice Sponsor a merchant
     * @param _merchant Merchant address
     * @param _tierId Sponsorship tier ID
     */
    function sponsorMerchant(
        address _merchant,
        uint256 _tierId
    ) external onlyOwner {
        if (_merchant == address(0)) {
            revert InvalidAddress();
        }
        if (_tierId >= nextTierId || !tiers[_tierId].active) {
            revert InvalidTier();
        }

        merchantSponsorship[_merchant] = MerchantSponsorship({
            active: true,
            tierId: uint8(_tierId),
            spentToday: 0,
            spentThisMonth: 0,
            lastDayReset: uint64(block.timestamp),
            lastMonthReset: uint64(block.timestamp),
            totalSponsored: 0
        });

        emit MerchantSponsored(_merchant, _tierId);
    }

    /**
     * @notice Revoke merchant sponsorship
     * @param _merchant Merchant address
     */
    function revokeMerchant(address _merchant) external onlyOwner {
        if (_merchant == address(0)) {
            revert InvalidAddress();
        }
        merchantSponsorship[_merchant].active = false;
        emit MerchantRevoked(_merchant);
    }

    /**
     * @notice Check if a merchant can be sponsored for an amount
     * @param _merchant Merchant address
     * @param _amount Gas amount requested
     * @return sponsorable Whether sponsorship is possible
     * @return reason Reason if cannot sponsor
     */
    function canSponsor(
        address _merchant,
        uint256 _amount
    ) external view returns (bool sponsorable, string memory reason) {
        return _canSponsor(_merchant, _amount);
    }

    // =========================================================================
    // Sponsorship Execution
    // =========================================================================

    /**
     * @notice Execute gas sponsorship for a merchant
     * @param _merchant Merchant address
     * @param _amount Gas amount to sponsor
     * @param _operationType Type of commerce operation
     */
    function executeSponsorship(
        address _merchant,
        uint256 _amount,
        OperationType _operationType
    ) external onlyOperator nonReentrant {
        MerchantSponsorship storage sponsorship = merchantSponsorship[_merchant];

        if (!sponsorship.active) {
            revert NotSponsored();
        }

        SponsorshipTier storage tier = tiers[sponsorship.tierId];
        if (!tier.active) {
            revert TierNotActive();
        }

        // Check transaction limit
        if (_amount > tier.maxPerTransaction) {
            revert ExceedsTransactionLimit(_amount, tier.maxPerTransaction);
        }

        // Reset and check daily limit
        _resetDailyIfNeeded(sponsorship);
        if (sponsorship.spentToday + _amount > tier.maxPerDay) {
            revert ExceedsDailyLimit(_amount, tier.maxPerDay - sponsorship.spentToday);
        }

        // Reset and check monthly limit
        _resetMonthlyIfNeeded(sponsorship);
        if (sponsorship.spentThisMonth + _amount > tier.maxPerMonth) {
            revert ExceedsMonthlyLimit(_amount, tier.maxPerMonth - sponsorship.spentThisMonth);
        }

        // Check balance
        if (address(this).balance < _amount) {
            revert InsufficientBalance();
        }

        // Update spending (unchecked: limit checks above prevent overflow)
        unchecked {
            uint128 amount128 = uint128(_amount);
            sponsorship.spentToday += amount128;
            sponsorship.spentThisMonth += amount128;
            sponsorship.totalSponsored += amount128;
        }

        // Transfer gas to merchant
        (bool success, ) = _merchant.call{value: _amount}("");
        if (!success) revert TransferFailed();

        emit GasSponsored(_merchant, _amount, _operationType);
    }

    /**
     * @notice Refund unused gas sponsorship
     * @param _merchant Merchant address
     * @param _refundAmount Amount to refund
     */
    function refundUnusedGas(
        address _merchant,
        uint256 _refundAmount
    ) external payable onlyOperator nonReentrant {
        if (_merchant == address(0)) revert InvalidAddress();
        if (msg.value != _refundAmount) {
            revert RefundValueMismatch(_refundAmount, msg.value);
        }

        _applyRefund(_merchant, _refundAmount);
    }

    // =========================================================================
    // Deposit / Withdraw
    // =========================================================================

    /**
     * @notice Deposit ETH to fund sponsorships
     */
    function deposit() external payable {
        if (msg.value < minDeposit) revert BelowMinimumDeposit(msg.value, minDeposit);
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw ETH from paymaster
     * @param _amount Amount to withdraw
     */
    function withdraw(uint256 _amount) external onlyOwner {
        if (address(this).balance < _amount) revert InsufficientBalance();

        (bool success, ) = treasury.call{value: _amount}("");
        if (!success) revert WithdrawFailed();

        emit Withdrawn(treasury, _amount);
    }

    /**
     * @notice Get paymaster balance
     */
    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @notice Get merchant's remaining daily allowance
     * @param _merchant Merchant address
     */
    function getRemainingDailyAllowance(
        address _merchant
    ) external view returns (uint256) {
        return _getRemainingDailyAllowance(_merchant);
    }

    /**
     * @notice Get merchant's sponsorship details
     * @param _merchant Merchant address
     */
    function getMerchantDetails(
        address _merchant
    ) external view returns (
        bool active,
        uint256 tierId,
        uint256 spentToday,
        uint256 spentThisMonth,
        uint256 totalSponsored
    ) {
        return _getMerchantDetails(_merchant);
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    function _createDefaultTiers() internal {
        // Tier 0: Starter (free tier)
        tiers[0] = SponsorshipTier({
            name: "Starter",
            maxPerTransaction: 0.001 ether,
            maxPerDay: 0.01 ether,
            maxPerMonth: 0.1 ether,
            active: true
        });

        // Tier 1: Growth
        tiers[1] = SponsorshipTier({
            name: "Growth",
            maxPerTransaction: 0.005 ether,
            maxPerDay: 0.05 ether,
            maxPerMonth: 0.5 ether,
            active: true
        });

        // Tier 2: Enterprise
        tiers[2] = SponsorshipTier({
            name: "Enterprise",
            maxPerTransaction: 0.01 ether,
            maxPerDay: 0.1 ether,
            maxPerMonth: 1 ether,
            active: true
        });

        nextTierId = 3;
    }

    function _resetDailyIfNeeded(MerchantSponsorship storage s) internal {
        // unchecked: block.timestamp is always >= lastDayReset
        unchecked {
            if (block.timestamp - s.lastDayReset >= 1 days) {
                s.spentToday = 0;
                s.lastDayReset = uint64(block.timestamp);
            }
        }
    }

    function _resetMonthlyIfNeeded(MerchantSponsorship storage s) internal {
        // unchecked: block.timestamp is always >= lastMonthReset
        unchecked {
            if (block.timestamp - s.lastMonthReset >= 30 days) {
                s.spentThisMonth = 0;
                s.lastMonthReset = uint64(block.timestamp);
            }
        }
    }

    function _getTodaySpent(
        MerchantSponsorship storage s
    ) internal view returns (uint256) {
        if (block.timestamp - s.lastDayReset >= 1 days) {
            return 0;
        }
        return s.spentToday;
    }

    function _getMonthSpent(
        MerchantSponsorship storage s
    ) internal view returns (uint256) {
        if (block.timestamp - s.lastMonthReset >= 30 days) {
            return 0;
        }
        return s.spentThisMonth;
    }

    function _canSponsor(
        address _merchant,
        uint256 _amount
    ) internal view returns (bool, string memory) {
        MerchantSponsorship storage sponsorship = merchantSponsorship[_merchant];

        if (!sponsorship.active) {
            return (false, "Not sponsored");
        }

        SponsorshipTier storage tier = tiers[sponsorship.tierId];

        if (!tier.active) {
            return (false, "Tier not active");
        }

        if (_amount > tier.maxPerTransaction) {
            return (false, "Exceeds transaction limit");
        }

        uint256 todaySpent = _getTodaySpent(sponsorship);
        if (todaySpent + _amount > tier.maxPerDay) {
            return (false, "Exceeds daily limit");
        }

        uint256 monthSpent = _getMonthSpent(sponsorship);
        if (monthSpent + _amount > tier.maxPerMonth) {
            return (false, "Exceeds monthly limit");
        }

        if (address(this).balance < _amount) {
            return (false, "Insufficient paymaster balance");
        }

        return (true, "");
    }

    function _getRemainingDailyAllowance(
        address _merchant
    ) internal view returns (uint256) {
        MerchantSponsorship storage sponsorship = merchantSponsorship[_merchant];

        if (!sponsorship.active) {
            return 0;
        }

        SponsorshipTier storage tier = tiers[sponsorship.tierId];
        uint256 spent = _getTodaySpent(sponsorship);

        if (spent >= tier.maxPerDay) {
            return 0;
        }

        return tier.maxPerDay - spent;
    }

    function _getMerchantDetails(
        address _merchant
    ) internal view returns (
        bool active,
        uint256 tierId,
        uint256 spentToday,
        uint256 spentThisMonth,
        uint256 totalSponsored
    ) {
        MerchantSponsorship storage s = merchantSponsorship[_merchant];
        return (
            s.active,
            s.tierId,
            _getTodaySpent(s),
            _getMonthSpent(s),
            s.totalSponsored
        );
    }

    function _applyRefund(address _merchant, uint256 _refundAmount) internal {
        if (_refundAmount == 0) revert InvalidRefundAmount();

        MerchantSponsorship storage sponsorship = merchantSponsorship[_merchant];
        _resetDailyIfNeeded(sponsorship);
        _resetMonthlyIfNeeded(sponsorship);

        if (_refundAmount > sponsorship.totalSponsored) {
            revert RefundExceedsSponsored(_refundAmount, sponsorship.totalSponsored);
        }

        uint128 refund128 = uint128(_refundAmount);
        uint128 dailyRefund = refund128 > sponsorship.spentToday
            ? sponsorship.spentToday
            : refund128;
        uint128 monthlyRefund = refund128 > sponsorship.spentThisMonth
            ? sponsorship.spentThisMonth
            : refund128;

        sponsorship.spentToday -= dailyRefund;
        sponsorship.spentThisMonth -= monthlyRefund;
        sponsorship.totalSponsored -= refund128;

        emit GasRefunded(_merchant, _refundAmount);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {
        emit ContractUpgraded(newImplementation, msg.sender);
    }

    // =========================================================================
    // Batch Operations
    // =========================================================================

    /**
     * @notice Sponsor multiple merchants in a single transaction
     * @param _merchants Array of merchant addresses
     * @param _tierIds Array of tier IDs for each merchant
     */
    function batchSponsorMerchants(
        address[] calldata _merchants,
        uint256[] calldata _tierIds
    ) external onlyOwner {
        if (_merchants.length == 0) revert EmptyArray();
        if (_merchants.length != _tierIds.length) revert ArrayLengthMismatch();
        if (_merchants.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        for (uint256 i = 0; i < _merchants.length; i++) {
            if (_merchants[i] == address(0)) revert InvalidAddress();
            if (_tierIds[i] >= nextTierId || !tiers[_tierIds[i]].active) {
                revert InvalidTier();
            }

            merchantSponsorship[_merchants[i]] = MerchantSponsorship({
                active: true,
                tierId: uint8(_tierIds[i]),
                spentToday: 0,
                spentThisMonth: 0,
                lastDayReset: uint64(block.timestamp),
                lastMonthReset: uint64(block.timestamp),
                totalSponsored: 0
            });

            emit MerchantSponsored(_merchants[i], _tierIds[i]);
        }
    }

    /**
     * @notice Revoke sponsorship for multiple merchants
     * @param _merchants Array of merchant addresses
     */
    function batchRevokeMerchants(address[] calldata _merchants) external onlyOwner {
        if (_merchants.length == 0) revert EmptyArray();
        if (_merchants.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        for (uint256 i = 0; i < _merchants.length; i++) {
            if (_merchants[i] == address(0)) revert InvalidAddress();
            merchantSponsorship[_merchants[i]].active = false;
            emit MerchantRevoked(_merchants[i]);
        }
    }

    /**
     * @notice Execute sponsorship for multiple merchants in a single transaction
     * @param _merchants Array of merchant addresses
     * @param _amounts Array of amounts to sponsor
     * @param _operationTypes Array of operation types
     * @return succeeded Count of successful sponsorships
     * @return failed Count of failed sponsorships
     * @dev Skips merchants that fail validation rather than reverting
     */
    function batchExecuteSponsorship(
        address[] calldata _merchants,
        uint256[] calldata _amounts,
        OperationType[] calldata _operationTypes
    ) external onlyOperator nonReentrant returns (uint256 succeeded, uint256 failed) {
        if (_merchants.length == 0) revert EmptyArray();
        if (_merchants.length != _amounts.length || _amounts.length != _operationTypes.length) {
            revert ArrayLengthMismatch();
        }
        if (_merchants.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        for (uint256 i = 0; i < _merchants.length; i++) {
            if (_merchants[i] == address(0)) {
                emit BatchSponsorshipFailed(_merchants[i], "Invalid merchant");
                failed++;
                continue;
            }
            MerchantSponsorship storage sponsorship = merchantSponsorship[_merchants[i]];

            // Skip inactive merchants
            if (!sponsorship.active) {
                emit BatchSponsorshipFailed(_merchants[i], "Not sponsored");
                failed++;
                continue;
            }

            SponsorshipTier storage tier = tiers[sponsorship.tierId];
            if (!tier.active) {
                emit BatchSponsorshipFailed(_merchants[i], "Tier not active");
                failed++;
                continue;
            }

            // Skip if exceeds transaction limit
            if (_amounts[i] > tier.maxPerTransaction) {
                emit BatchSponsorshipFailed(_merchants[i], "Exceeds tx limit");
                failed++;
                continue;
            }

            // Reset and check daily limit
            _resetDailyIfNeeded(sponsorship);
            if (sponsorship.spentToday + _amounts[i] > tier.maxPerDay) {
                emit BatchSponsorshipFailed(_merchants[i], "Exceeds daily limit");
                failed++;
                continue;
            }

            // Reset and check monthly limit
            _resetMonthlyIfNeeded(sponsorship);
            if (sponsorship.spentThisMonth + _amounts[i] > tier.maxPerMonth) {
                emit BatchSponsorshipFailed(_merchants[i], "Exceeds monthly limit");
                failed++;
                continue;
            }

            // Check balance
            if (address(this).balance < _amounts[i]) {
                emit BatchSponsorshipFailed(_merchants[i], "Insufficient balance");
                failed++;
                continue;
            }

            // Update spending
            uint128 amt = uint128(_amounts[i]);
            sponsorship.spentToday += amt;
            sponsorship.spentThisMonth += amt;
            sponsorship.totalSponsored += amt;

            // Transfer gas to merchant
            (bool success, ) = _merchants[i].call{value: _amounts[i]}("");
            if (success) {
                emit GasSponsored(_merchants[i], _amounts[i], _operationTypes[i]);
                succeeded++;
            } else {
                // Rollback spending updates on failed transfer
                sponsorship.spentToday -= amt;
                sponsorship.spentThisMonth -= amt;
                sponsorship.totalSponsored -= amt;
                emit BatchSponsorshipFailed(_merchants[i], "Transfer failed");
                failed++;
            }
        }

        emit BatchSponsorshipCompleted(_merchants.length, succeeded, failed);
        return (succeeded, failed);
    }

    /**
     * @notice Batch refund unused gas for multiple merchants
     * @param _merchants Array of merchant addresses
     * @param _refundAmounts Array of refund amounts
     */
    function batchRefundUnusedGas(
        address[] calldata _merchants,
        uint256[] calldata _refundAmounts
    ) external payable onlyOperator nonReentrant {
        if (_merchants.length == 0) revert EmptyArray();
        if (_merchants.length != _refundAmounts.length) revert ArrayLengthMismatch();
        if (_merchants.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 totalRefundAmount = 0;
        for (uint256 i = 0; i < _merchants.length; i++) {
            if (_merchants[i] == address(0)) revert InvalidAddress();
            totalRefundAmount += _refundAmounts[i];
        }

        if (msg.value != totalRefundAmount) {
            revert RefundValueMismatch(totalRefundAmount, msg.value);
        }

        for (uint256 i = 0; i < _merchants.length; i++) {
            _applyRefund(_merchants[i], _refundAmounts[i]);
        }
    }

    /**
     * @notice Get sponsorship status for multiple merchants
     * @param _merchants Array of merchant addresses
     * @return statuses Array of active status for each merchant
     * @return tiers_ Array of tier IDs for each merchant
     */
    function batchGetMerchantStatus(
        address[] calldata _merchants
    ) external view returns (bool[] memory statuses, uint256[] memory tiers_) {
        statuses = new bool[](_merchants.length);
        tiers_ = new uint256[](_merchants.length);

        for (uint256 i = 0; i < _merchants.length; i++) {
            MerchantSponsorship storage s = merchantSponsorship[_merchants[i]];
            statuses[i] = s.active;
            tiers_[i] = s.tierId;
        }

        return (statuses, tiers_);
    }

    /**
     * @notice Check if multiple merchants can be sponsored for given amounts
     * @param _merchants Array of merchant addresses
     * @param _amounts Array of requested amounts
     * @return canSponsor_ Array of booleans indicating sponsorability
     * @return reasons Array of rejection reasons (empty if sponsorable)
     */
    function batchCanSponsor(
        address[] calldata _merchants,
        uint256[] calldata _amounts
    ) external view returns (bool[] memory canSponsor_, string[] memory reasons) {
        if (_merchants.length != _amounts.length) revert ArrayLengthMismatch();

        canSponsor_ = new bool[](_merchants.length);
        reasons = new string[](_merchants.length);

        for (uint256 i = 0; i < _merchants.length; i++) {
            (canSponsor_[i], reasons[i]) = _canSponsor(_merchants[i], _amounts[i]);
        }

        return (canSponsor_, reasons);
    }

    /**
     * @notice Get remaining daily allowances for multiple merchants
     * @param _merchants Array of merchant addresses
     * @return allowances Array of remaining daily allowances
     */
    function batchGetRemainingDailyAllowance(
        address[] calldata _merchants
    ) external view returns (uint256[] memory allowances) {
        allowances = new uint256[](_merchants.length);

        for (uint256 i = 0; i < _merchants.length; i++) {
            allowances[i] = _getRemainingDailyAllowance(_merchants[i]);
        }

        return allowances;
    }

    /**
     * @notice Get comprehensive details for multiple merchants
     * @param _merchants Array of merchant addresses
     * @return active Merchant active flags
     * @return tierIds Merchant tier IDs
     * @return spentToday Daily spend per merchant
     * @return spentThisMonth Monthly spend per merchant
     * @return totalSponsored Total sponsored per merchant
     */
    function batchGetMerchantDetails(
        address[] calldata _merchants
    ) external view returns (
        bool[] memory active,
        uint256[] memory tierIds,
        uint256[] memory spentToday,
        uint256[] memory spentThisMonth,
        uint256[] memory totalSponsored
    ) {
        active = new bool[](_merchants.length);
        tierIds = new uint256[](_merchants.length);
        spentToday = new uint256[](_merchants.length);
        spentThisMonth = new uint256[](_merchants.length);
        totalSponsored = new uint256[](_merchants.length);

        for (uint256 i = 0; i < _merchants.length; i++) {
            (
                active[i],
                tierIds[i],
                spentToday[i],
                spentThisMonth[i],
                totalSponsored[i]
            ) = _getMerchantDetails(_merchants[i]);
        }

        return (active, tierIds, spentToday, spentThisMonth, totalSponsored);
    }

    /**
     * @notice Update tier for multiple merchants
     * @param _merchants Array of merchant addresses
     * @param _newTierId New tier ID to assign
     */
    function batchUpdateMerchantTier(
        address[] calldata _merchants,
        uint256 _newTierId
    ) external onlyOwner {
        if (_merchants.length == 0) revert EmptyArray();
        if (_merchants.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (_newTierId >= nextTierId || !tiers[_newTierId].active) revert InvalidTier();

        for (uint256 i = 0; i < _merchants.length; i++) {
            if (_merchants[i] == address(0)) revert InvalidAddress();
            MerchantSponsorship storage s = merchantSponsorship[_merchants[i]];
            if (s.active) {
                s.tierId = uint8(_newTierId);
                emit MerchantSponsored(_merchants[i], _newTierId);
            }
        }
    }

    // =========================================================================
    // Monitoring Functions
    // =========================================================================

    /**
     * @notice Get comprehensive paymaster status
     * @return paymasterBalance Current contract balance
     * @return totalSponsored_ Total gas ever sponsored
     * @return tierCount Number of tiers
     * @return treasuryAddr Treasury address
     */
    function getPaymasterStatus() external view returns (
        uint256 paymasterBalance,
        uint256 totalSponsored_,
        uint256 tierCount,
        address treasuryAddr
    ) {
        return (
            address(this).balance,
            0, // totalGasSponsored removed (derivable from events)
            nextTierId,
            treasury
        );
    }

    /**
     * @notice Get all active tier details
     * @return tierIds Array of tier IDs
     * @return names Array of tier names
     * @return maxPerTx Array of max per transaction limits
     * @return maxPerDay_ Array of max per day limits
     * @return maxPerMonth_ Array of max per month limits
     */
    function getAllTiers() external view returns (
        uint256[] memory tierIds,
        string[] memory names,
        uint256[] memory maxPerTx,
        uint256[] memory maxPerDay_,
        uint256[] memory maxPerMonth_
    ) {
        // Count active tiers
        uint256 activeCount = 0;
        for (uint256 i = 0; i < nextTierId; i++) {
            if (tiers[i].active) activeCount++;
        }

        tierIds = new uint256[](activeCount);
        names = new string[](activeCount);
        maxPerTx = new uint256[](activeCount);
        maxPerDay_ = new uint256[](activeCount);
        maxPerMonth_ = new uint256[](activeCount);

        uint256 index = 0;
        for (uint256 i = 0; i < nextTierId; i++) {
            if (tiers[i].active) {
                tierIds[index] = i;
                names[index] = tiers[i].name;
                maxPerTx[index] = tiers[i].maxPerTransaction;
                maxPerDay_[index] = tiers[i].maxPerDay;
                maxPerMonth_[index] = tiers[i].maxPerMonth;
                index++;
            }
        }

        return (tierIds, names, maxPerTx, maxPerDay_, maxPerMonth_);
    }

    // =========================================================================
    // Receive
    // =========================================================================

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // =========================================================================
    // Storage Gap
    // =========================================================================

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;
}
