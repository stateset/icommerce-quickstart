// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../commerce/SetPaymaster.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SetPaymasterTest is Test {
    SetPaymaster public paymaster;
    SetPaymaster public paymasterImpl;

    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public operator = address(0x3);
    address public merchant = address(0x4);
    address public unauthorized = address(0x5);

    event TierCreated(uint256 indexed tierId, string name, uint256 maxPerTx, uint256 maxPerDay);
    event TierUpdated(uint256 indexed tierId, uint256 maxPerTx, uint256 maxPerDay);
    event TierStatusUpdated(uint256 indexed tierId, bool active);
    event MerchantSponsored(address indexed merchant, uint256 tierId);
    event MerchantRevoked(address indexed merchant);
    event GasSponsored(
        address indexed merchant,
        uint256 amount,
        SetPaymaster.OperationType operationType
    );
    event GasRefunded(address indexed merchant, uint256 amount);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event OperatorUpdated(address indexed operator, bool authorized);
    event MinDepositUpdated(uint256 minDeposit);

    function setUp() public {
        // Deploy implementation
        paymasterImpl = new SetPaymaster();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            SetPaymaster.initialize,
            (owner, treasury)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(paymasterImpl), initData);
        paymaster = SetPaymaster(payable(address(proxy)));

        // Fund paymaster
        vm.deal(address(paymaster), 10 ether);
        vm.deal(operator, 10 ether);

        // Set up operator
        vm.prank(owner);
        paymaster.setOperator(operator, true);
    }

    // =========================================================================
    // Initialization Tests
    // =========================================================================

    function test_Initialize() public view {
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.treasury(), treasury);
        assertEq(paymaster.minDeposit(), 0.01 ether);
        assertEq(paymaster.nextTierId(), 3); // 3 default tiers created
    }

    function test_DefaultTiers() public view {
        // Tier 0: Starter
        (
            string memory name0,
            uint256 maxPerTx0,
            uint256 maxPerDay0,
            uint256 maxPerMonth0,
            bool active0
        ) = paymaster.tiers(0);
        assertEq(name0, "Starter");
        assertEq(maxPerTx0, 0.001 ether);
        assertEq(maxPerDay0, 0.01 ether);
        assertEq(maxPerMonth0, 0.1 ether);
        assertTrue(active0);

        // Tier 1: Growth
        (
            string memory name1,
            uint256 maxPerTx1,
            uint256 maxPerDay1,
            uint256 maxPerMonth1,
            bool active1
        ) = paymaster.tiers(1);
        assertEq(name1, "Growth");
        assertEq(maxPerTx1, 0.005 ether);
        assertEq(maxPerDay1, 0.05 ether);
        assertEq(maxPerMonth1, 0.5 ether);
        assertTrue(active1);

        // Tier 2: Enterprise
        (
            string memory name2,
            uint256 maxPerTx2,
            uint256 maxPerDay2,
            uint256 maxPerMonth2,
            bool active2
        ) = paymaster.tiers(2);
        assertEq(name2, "Enterprise");
        assertEq(maxPerTx2, 0.01 ether);
        assertEq(maxPerDay2, 0.1 ether);
        assertEq(maxPerMonth2, 1 ether);
        assertTrue(active2);
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        paymaster.initialize(owner, treasury);
    }

    // =========================================================================
    // Tier Management Tests
    // =========================================================================

    function test_CreateTier() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TierCreated(3, "Premium", 0.02 ether, 0.2 ether);

        uint256 tierId = paymaster.createTier(
            "Premium",
            0.02 ether,
            0.2 ether,
            2 ether
        );

        assertEq(tierId, 3);
        assertEq(paymaster.nextTierId(), 4);

        (string memory name, uint256 maxPerTx, uint256 maxPerDay, , bool active) = paymaster.tiers(
            3
        );
        assertEq(name, "Premium");
        assertEq(maxPerTx, 0.02 ether);
        assertEq(maxPerDay, 0.2 ether);
        assertTrue(active);
    }

    function test_CreateTier_InvalidLimits() public {
        vm.prank(owner);
        vm.expectRevert(SetPaymaster.InvalidTierLimits.selector);
        paymaster.createTier("Broken", 0.2 ether, 0.1 ether, 1 ether);
    }

    function test_CreateTier_NotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        paymaster.createTier("Premium", 0.02 ether, 0.2 ether, 2 ether);
    }

    function test_UpdateTier() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TierUpdated(0, 0.002 ether, 0.02 ether);

        paymaster.updateTier(0, 0.002 ether, 0.02 ether, 0.2 ether);

        (, uint256 maxPerTx, uint256 maxPerDay, uint256 maxPerMonth, ) = paymaster.tiers(0);
        assertEq(maxPerTx, 0.002 ether);
        assertEq(maxPerDay, 0.02 ether);
        assertEq(maxPerMonth, 0.2 ether);
    }

    function test_UpdateTier_InvalidTier() public {
        vm.prank(owner);
        vm.expectRevert(SetPaymaster.InvalidTier.selector);
        paymaster.updateTier(99, 0.002 ether, 0.02 ether, 0.2 ether);
    }

    function test_SetTierActive() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TierStatusUpdated(1, false);
        paymaster.setTierActive(1, false);

        (, , , , bool active) = paymaster.tiers(1);
        assertFalse(active);
    }

    // =========================================================================
    // Operator Tests
    // =========================================================================

    function test_SetOperator() public {
        address newOperator = address(0x10);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit OperatorUpdated(newOperator, true);
        paymaster.setOperator(newOperator, true);

        assertTrue(paymaster.operators(newOperator));
    }

    function test_SetOperator_NotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        paymaster.setOperator(address(0x10), true);
    }

    function test_SetMinDeposit() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MinDepositUpdated(0.02 ether);
        paymaster.setMinDeposit(0.02 ether);
        assertEq(paymaster.minDeposit(), 0.02 ether);
    }

    // =========================================================================
    // Merchant Sponsorship Tests
    // =========================================================================

    function test_SponsorMerchant() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit MerchantSponsored(merchant, 1);
        paymaster.sponsorMerchant(merchant, 1);

        (
            bool active,
            uint256 tierId,
            uint256 spentToday,
            uint256 spentThisMonth,
            uint256 totalSponsored
        ) = paymaster.getMerchantDetails(merchant);

        assertTrue(active);
        assertEq(tierId, 1);
        assertEq(spentToday, 0);
        assertEq(spentThisMonth, 0);
        assertEq(totalSponsored, 0);
    }

    function test_SponsorMerchant_InvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(SetPaymaster.InvalidAddress.selector);
        paymaster.sponsorMerchant(address(0), 1);
    }

    function test_SponsorMerchant_InvalidTier() public {
        vm.prank(owner);
        vm.expectRevert(SetPaymaster.InvalidTier.selector);
        paymaster.sponsorMerchant(merchant, 999); // Non-existent tier
    }

    function test_RevokeMerchant() public {
        vm.startPrank(owner);
        paymaster.sponsorMerchant(merchant, 1);

        vm.expectEmit(true, false, false, false);
        emit MerchantRevoked(merchant);
        paymaster.revokeMerchant(merchant);
        vm.stopPrank();

        (bool active, , , , ) = paymaster.getMerchantDetails(merchant);
        assertFalse(active);
    }

    // =========================================================================
    // Can Sponsor Tests
    // =========================================================================

    function test_CanSponsor() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 1); // Growth tier

        (bool can, string memory reason) = paymaster.canSponsor(merchant, 0.001 ether);
        assertTrue(can);
        assertEq(reason, "");
    }

    function test_CanSponsor_NotSponsored() public view {
        (bool can, string memory reason) = paymaster.canSponsor(merchant, 0.001 ether);
        assertFalse(can);
        assertEq(reason, "Not sponsored");
    }

    function test_CanSponsor_ExceedsTransactionLimit() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 0); // Starter tier: 0.001 ether max per tx

        (bool can, string memory reason) = paymaster.canSponsor(merchant, 0.002 ether);
        assertFalse(can);
        assertEq(reason, "Exceeds transaction limit");
    }

    function test_CanSponsor_InsufficientBalance() public {
        // Deploy new paymaster with no balance
        SetPaymaster impl = new SetPaymaster();
        bytes memory initData = abi.encodeCall(SetPaymaster.initialize, (owner, treasury));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        SetPaymaster emptyPaymaster = SetPaymaster(payable(address(proxy)));

        vm.prank(owner);
        emptyPaymaster.sponsorMerchant(merchant, 0);

        (bool can, string memory reason) = emptyPaymaster.canSponsor(merchant, 0.0001 ether);
        assertFalse(can);
        assertEq(reason, "Insufficient paymaster balance");
    }

    // =========================================================================
    // Execute Sponsorship Tests
    // =========================================================================

    function test_ExecuteSponsorship() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 1); // Growth tier

        uint256 merchantBalanceBefore = merchant.balance;
        uint256 sponsorAmount = 0.001 ether;

        vm.prank(operator);
        vm.expectEmit(true, false, false, true);
        emit GasSponsored(merchant, sponsorAmount, SetPaymaster.OperationType.ORDER_CREATE);
        paymaster.executeSponsorship(
            merchant,
            sponsorAmount,
            SetPaymaster.OperationType.ORDER_CREATE
        );

        assertEq(merchant.balance, merchantBalanceBefore + sponsorAmount);

        (, , uint256 spentToday, uint256 spentThisMonth, uint256 totalSponsored) = paymaster
            .getMerchantDetails(merchant);
        assertEq(spentToday, sponsorAmount);
        assertEq(spentThisMonth, sponsorAmount);
        assertEq(totalSponsored, sponsorAmount);
    }

    function test_ExecuteSponsorship_NotOperator() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 1);

        vm.prank(unauthorized);
        vm.expectRevert(SetPaymaster.NotOperator.selector);
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);
    }

    function test_ExecuteSponsorship_NotSponsored() public {
        vm.prank(operator);
        vm.expectRevert(SetPaymaster.NotSponsored.selector);
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);
    }

    function test_ExecuteSponsorship_ExceedsTransactionLimit() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 0); // Starter: 0.001 ether max

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                SetPaymaster.ExceedsTransactionLimit.selector,
                0.002 ether,
                0.001 ether
            )
        );
        paymaster.executeSponsorship(merchant, 0.002 ether, SetPaymaster.OperationType.ORDER_CREATE);
    }

    function test_ExecuteSponsorship_ExceedsDailyLimit() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 0); // Starter: 0.01 ether daily limit

        vm.startPrank(operator);

        // Use up daily limit
        for (uint256 i = 0; i < 10; i++) {
            paymaster.executeSponsorship(
                merchant,
                0.001 ether,
                SetPaymaster.OperationType.ORDER_CREATE
            );
        }

        // Next should fail - daily limit exhausted
        vm.expectRevert(
            abi.encodeWithSelector(
                SetPaymaster.ExceedsDailyLimit.selector,
                0.001 ether,
                0
            )
        );
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);

        vm.stopPrank();
    }

    function test_ExecuteSponsorship_ExceedsMonthlyLimit() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 0); // Starter: 0.1 ether monthly limit

        uint256 currentTime = block.timestamp;
        // Use up monthly limit over multiple "days"
        for (uint256 day = 0; day < 10; day++) {
            currentTime += 1 days;
            vm.warp(currentTime);
            vm.roll(block.number + 1);

            vm.startPrank(operator);
            for (uint256 i = 0; i < 10; i++) {
                paymaster.executeSponsorship(
                    merchant,
                    0.001 ether,
                    SetPaymaster.OperationType.ORDER_CREATE
                );
            }
            vm.stopPrank();
        }

        // Should now be at monthly limit (0.1 ether)
        // Next day...
        currentTime += 2 days;
        vm.warp(currentTime);
        vm.roll(block.number + 1);

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                SetPaymaster.ExceedsMonthlyLimit.selector,
                0.001 ether,
                0
            )
        );
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);

        vm.stopPrank();
    }

    function test_ExecuteSponsorship_InsufficientBalance() public {
        // Create paymaster with limited balance
        SetPaymaster impl = new SetPaymaster();
        bytes memory initData = abi.encodeCall(SetPaymaster.initialize, (owner, treasury));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        SetPaymaster limitedPaymaster = SetPaymaster(payable(address(proxy)));

        // Fund with small amount
        vm.deal(address(limitedPaymaster), 0.0001 ether);

        vm.startPrank(owner);
        limitedPaymaster.setOperator(operator, true);
        limitedPaymaster.sponsorMerchant(merchant, 1);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(SetPaymaster.InsufficientBalance.selector);
        limitedPaymaster.executeSponsorship(
            merchant,
            0.001 ether,
            SetPaymaster.OperationType.ORDER_CREATE
        );
    }

    function test_ExecuteSponsorship_OwnerCanExecute() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 1);

        // Owner can execute without being an operator
        vm.prank(owner);
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);

    }

    // =========================================================================
    // Daily/Monthly Reset Tests
    // =========================================================================

    function test_DailyReset() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 0); // Starter

        vm.startPrank(operator);

        // Spend some gas
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);

        (, , uint256 spentToday1, , ) = paymaster.getMerchantDetails(merchant);
        assertEq(spentToday1, 0.001 ether);

        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);

        // Spend again - daily should have reset
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);

        (, , uint256 spentToday2, uint256 spentMonth, ) = paymaster.getMerchantDetails(merchant);
        assertEq(spentToday2, 0.001 ether); // Reset to just this tx
        assertEq(spentMonth, 0.002 ether); // Still accumulates monthly

        vm.stopPrank();
    }

    function test_MonthlyReset() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 2); // Enterprise for higher limits

        vm.startPrank(operator);

        // Spend some gas
        paymaster.executeSponsorship(merchant, 0.01 ether, SetPaymaster.OperationType.ORDER_CREATE);

        (, , , uint256 spentMonth1, ) = paymaster.getMerchantDetails(merchant);
        assertEq(spentMonth1, 0.01 ether);

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        // Spend again - monthly should have reset
        paymaster.executeSponsorship(merchant, 0.01 ether, SetPaymaster.OperationType.ORDER_CREATE);

        (, , , uint256 spentMonth2, uint256 total) = paymaster.getMerchantDetails(merchant);
        assertEq(spentMonth2, 0.01 ether); // Reset to just this tx
        assertEq(total, 0.02 ether); // Total still accumulates

        vm.stopPrank();
    }

    // =========================================================================
    // Refund Tests
    // =========================================================================

    function test_RefundUnusedGas() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 1);

        uint256 paymasterBalanceBefore = paymaster.balance();

        vm.startPrank(operator);

        // Execute sponsorship
        paymaster.executeSponsorship(merchant, 0.005 ether, SetPaymaster.OperationType.ORDER_CREATE);

        // Refund some
        vm.expectEmit(true, false, false, true);
        emit GasRefunded(merchant, 0.002 ether);
        paymaster.refundUnusedGas{value: 0.002 ether}(merchant, 0.002 ether);

        vm.stopPrank();

        (, , uint256 spentToday, uint256 spentMonth, uint256 total) = paymaster.getMerchantDetails(
            merchant
        );
        assertEq(spentToday, 0.003 ether);
        assertEq(spentMonth, 0.003 ether);
        assertEq(total, 0.003 ether);
        assertEq(paymaster.balance(), paymasterBalanceBefore - 0.003 ether);
    }

    function test_RefundUnusedGas_MoreThanSpent() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 1);

        vm.startPrank(operator);

        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);

        vm.expectRevert(
            abi.encodeWithSelector(
                SetPaymaster.RefundExceedsSponsored.selector,
                0.01 ether,
                0.001 ether
            )
        );
        paymaster.refundUnusedGas{value: 0.01 ether}(merchant, 0.01 ether);

        vm.stopPrank();

        (, , uint256 spentToday, uint256 spentMonth, uint256 totalSponsored) = paymaster
            .getMerchantDetails(merchant);
        assertEq(spentToday, 0.001 ether);
        assertEq(spentMonth, 0.001 ether);
        assertEq(totalSponsored, 0.001 ether);
    }

    function test_RefundUnusedGas_RequiresMatchingValue() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 1);

        vm.prank(operator);
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                SetPaymaster.RefundValueMismatch.selector,
                0.001 ether,
                0.0005 ether
            )
        );
        paymaster.refundUnusedGas{value: 0.0005 ether}(merchant, 0.001 ether);
    }

    function test_BatchRefundUnusedGas() public {
        address merchantTwo = address(0x6);

        vm.startPrank(owner);
        paymaster.sponsorMerchant(merchant, 1);
        paymaster.sponsorMerchant(merchantTwo, 1);
        vm.stopPrank();

        vm.startPrank(operator);
        paymaster.executeSponsorship(merchant, 0.002 ether, SetPaymaster.OperationType.ORDER_CREATE);
        paymaster.executeSponsorship(
            merchantTwo,
            0.003 ether,
            SetPaymaster.OperationType.PAYMENT_PROCESS
        );

        address[] memory merchants = new address[](2);
        merchants[0] = merchant;
        merchants[1] = merchantTwo;

        uint256[] memory refunds = new uint256[](2);
        refunds[0] = 0.001 ether;
        refunds[1] = 0.002 ether;

        paymaster.batchRefundUnusedGas{value: 0.003 ether}(merchants, refunds);
        vm.stopPrank();

        (, , uint256 spentTodayOne, uint256 spentMonthOne, uint256 totalOne) = paymaster
            .getMerchantDetails(merchant);
        (, , uint256 spentTodayTwo, uint256 spentMonthTwo, uint256 totalTwo) = paymaster
            .getMerchantDetails(merchantTwo);

        assertEq(spentTodayOne, 0.001 ether);
        assertEq(spentMonthOne, 0.001 ether);
        assertEq(totalOne, 0.001 ether);
        assertEq(spentTodayTwo, 0.001 ether);
        assertEq(spentMonthTwo, 0.001 ether);
        assertEq(totalTwo, 0.001 ether);
    }

    // =========================================================================
    // Deposit/Withdraw Tests
    // =========================================================================

    function test_Deposit() public {
        uint256 balanceBefore = paymaster.balance();

        vm.deal(address(this), 1 ether);
        vm.expectEmit(true, false, false, true);
        emit Deposited(address(this), 0.1 ether);
        paymaster.deposit{value: 0.1 ether}();

        assertEq(paymaster.balance(), balanceBefore + 0.1 ether);
    }

    function test_Deposit_BelowMinimum() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                SetPaymaster.BelowMinimumDeposit.selector,
                0.001 ether,
                0.01 ether
            )
        );
        paymaster.deposit{value: 0.001 ether}();
    }

    function test_Deposit_ViaReceive() public {
        uint256 balanceBefore = paymaster.balance();

        vm.deal(address(this), 1 ether);
        vm.expectEmit(true, false, false, true);
        emit Deposited(address(this), 0.5 ether);
        (bool success, ) = address(paymaster).call{value: 0.5 ether}("");
        assertTrue(success);

        assertEq(paymaster.balance(), balanceBefore + 0.5 ether);
    }

    function test_Withdraw() public {
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(treasury, 1 ether);
        paymaster.withdraw(1 ether);

        assertEq(treasury.balance, treasuryBalanceBefore + 1 ether);
    }

    function test_Withdraw_NotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        paymaster.withdraw(1 ether);
    }

    function test_Withdraw_InsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert(SetPaymaster.InsufficientBalance.selector);
        paymaster.withdraw(100 ether);
    }

    // =========================================================================
    // View Functions Tests
    // =========================================================================

    function test_GetRemainingDailyAllowance() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 0); // Starter: 0.01 ether daily

        assertEq(paymaster.getRemainingDailyAllowance(merchant), 0.01 ether);

        vm.prank(operator);
        paymaster.executeSponsorship(merchant, 0.001 ether, SetPaymaster.OperationType.ORDER_CREATE);

        assertEq(paymaster.getRemainingDailyAllowance(merchant), 0.009 ether);
    }

    function test_GetRemainingDailyAllowance_NotSponsored() public view {
        assertEq(paymaster.getRemainingDailyAllowance(merchant), 0);
    }

    function test_GetRemainingDailyAllowance_Exhausted() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 0); // Starter: 0.01 ether daily

        vm.startPrank(operator);
        for (uint256 i = 0; i < 10; i++) {
            paymaster.executeSponsorship(
                merchant,
                0.001 ether,
                SetPaymaster.OperationType.ORDER_CREATE
            );
        }
        vm.stopPrank();

        assertEq(paymaster.getRemainingDailyAllowance(merchant), 0);
    }

    // =========================================================================
    // Treasury Management Tests
    // =========================================================================

    function test_SetTreasury() public {
        address newTreasury = address(0x99);

        vm.prank(owner);
        paymaster.setTreasury(newTreasury);

        assertEq(paymaster.treasury(), newTreasury);
    }

    function test_SetTreasury_NotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        paymaster.setTreasury(address(0x99));
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_ExecuteSponsorship(uint256 amount) public {
        // Bound to valid range for Enterprise tier
        amount = bound(amount, 1 wei, 0.01 ether);

        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 2); // Enterprise tier

        uint256 merchantBalanceBefore = merchant.balance;

        vm.prank(operator);
        paymaster.executeSponsorship(
            merchant,
            amount,
            SetPaymaster.OperationType.PAYMENT_PROCESS
        );

        assertEq(merchant.balance, merchantBalanceBefore + amount);
    }

    function testFuzz_CreateTier(
        uint256 maxPerTx,
        uint256 maxPerDay,
        uint256 maxPerMonth
    ) public {
        vm.assume(maxPerTx > 0 && maxPerDay > 0 && maxPerMonth > 0);
        vm.assume(maxPerMonth <= type(uint128).max);
        vm.assume(maxPerTx <= maxPerDay);
        vm.assume(maxPerDay <= maxPerMonth);

        vm.prank(owner);
        uint256 tierId = paymaster.createTier("Fuzz", maxPerTx, maxPerDay, maxPerMonth);

        (, uint256 storedMaxPerTx, uint256 storedMaxPerDay, uint256 storedMaxPerMonth, ) = paymaster
            .tiers(tierId);

        assertEq(storedMaxPerTx, maxPerTx);
        assertEq(storedMaxPerDay, maxPerDay);
        assertEq(storedMaxPerMonth, maxPerMonth);
    }

    // =========================================================================
    // All Operation Types Test
    // =========================================================================

    function test_AllOperationTypes() public {
        vm.prank(owner);
        paymaster.sponsorMerchant(merchant, 2); // Enterprise

        SetPaymaster.OperationType[7] memory ops = [
            SetPaymaster.OperationType.ORDER_CREATE,
            SetPaymaster.OperationType.ORDER_UPDATE,
            SetPaymaster.OperationType.PAYMENT_PROCESS,
            SetPaymaster.OperationType.INVENTORY_UPDATE,
            SetPaymaster.OperationType.RETURN_PROCESS,
            SetPaymaster.OperationType.COMMITMENT_ANCHOR,
            SetPaymaster.OperationType.OTHER
        ];

        vm.startPrank(operator);
        for (uint256 i = 0; i < ops.length; i++) {
            paymaster.executeSponsorship(merchant, 0.001 ether, ops[i]);
        }
        vm.stopPrank();

    }
}
