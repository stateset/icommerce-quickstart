// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OrderEscrow
/// @notice Holds buyer funds against a commerce order until the seller proves
///         delivery. If the seller never ships (timeout), the buyer can pull
///         their funds back. This is the "no chargebacks" primitive: once the
///         buyer locks funds the seller can rely on payment, and once goods
///         are delivered (signed off by the buyer's agent or a delivery
///         oracle) the seller can withdraw.
///
/// Lifecycle:
///   LOCKED   ─ funds in escrow, waiting on shipment + delivery
///   DELIVERED ─ delivery proof submitted, in confirmation window
///   RELEASED ─ seller has withdrawn
///   REFUNDED ─ buyer pulled funds back after timeout
///
/// Two trust roles:
///   - operator (typically the StateSet sequencer): can attest delivery on
///     behalf of either party; reduces buyer-seller standoff in the happy
///     path. Demo is permissioned; production would multi-sig this.
///   - buyer + seller: hold their own keys; only they can confirm or refund.
///
/// Out of scope (v1): on-chain dispute arbitration, partial refunds,
/// multi-shipment orders, fee splits. Those layer on top.
contract OrderEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status { None, Locked, Delivered, Disputed, Released, Refunded }

    struct Order {
        address buyer;
        address seller;
        IERC20 token;
        uint128 amount;
        uint64 lockedAt;
        uint64 deliveredAt;
        uint64 deliveryDeadline;     // after this, buyer can refund unless delivered
        uint64 confirmationWindow;   // seconds buyer has to dispute after delivery
        bytes32 deliveryReceiptHash; // hash of the off-chain delivery receipt
        Status status;
        address feeRecipient;        // marketplace / platform; address(0) = no fee
        uint16 feeBps;               // basis points (1 bps = 0.01%); ≤ MAX_FEE_BPS
    }

    /// @notice Maximum platform fee = 10% (1000 bps). Hard-capped to keep the
    ///         primitive trustworthy regardless of who deploys it.
    uint16 public constant MAX_FEE_BPS = 1000;

    /// @notice The trusted operator (sequencer). Can submit delivery proofs.
    address public immutable operator;

    /// @notice orderId → escrow record. orderId comes from the commerce engine.
    mapping(bytes32 => Order) public orders;

    /// @notice Sum of `amount` (display units) currently locked per token.
    ///         For rebasing tokens like SSDC, balanceOf(this) - totalLocked[token]
    ///         is the surplus earned while funds were escrowed — sweepable to a
    ///         yield recipient via sweepYield().
    mapping(address => uint256) public totalLocked;

    event Locked(
        bytes32 indexed orderId,
        address indexed buyer,
        address indexed seller,
        address token,
        uint256 amount,
        uint64 deliveryDeadline
    );
    event Delivered(bytes32 indexed orderId, bytes32 receiptHash, address attestedBy);
    event Disputed(bytes32 indexed orderId, address indexed by, bytes32 reasonHash);
    event DisputeResolved(bytes32 indexed orderId, bool inFavorOfSeller, address resolvedBy);
    event Released(bytes32 indexed orderId, address to, uint256 amount);
    event Refunded(bytes32 indexed orderId, address to, uint256 amount);
    event FeeTaken(bytes32 indexed orderId, address indexed recipient, uint256 amount);
    event YieldSwept(address indexed token, address indexed recipient, uint256 amount);

    error OrderExists();
    error OrderNotLocked();
    error OrderNotDelivered();
    error OrderNotDisputed();
    error NotAuthorized();
    error DeadlineNotReached();
    error ConfirmationWindowOpen();
    error ZeroAmount();
    error FeeTooHigh(uint16 feeBps, uint16 maxBps);

    constructor(address _operator) {
        require(_operator != address(0), "operator=0");
        operator = _operator;
    }

    /// @notice Buyer (or a relayer with their approval) locks funds against an order.
    ///         Caller must be the buyer; they must have `approve`d this contract.
    /// @dev Convenience overload — no marketplace fee.
    function lock(
        bytes32 orderId,
        address seller,
        IERC20 token,
        uint128 amount,
        uint64 deliveryDeadline,
        uint64 confirmationWindow
    ) external nonReentrant {
        _lock(orderId, seller, token, amount, deliveryDeadline, confirmationWindow,
              address(0), 0);
    }

    /// @notice Lock with a marketplace / platform fee. The fee is taken on
    ///         release() (or seller-wins resolveDispute); refunds always
    ///         return the full amount to the buyer (the platform earns
    ///         only on completed transactions).
    function lockWithFee(
        bytes32 orderId,
        address seller,
        IERC20 token,
        uint128 amount,
        uint64 deliveryDeadline,
        uint64 confirmationWindow,
        address feeRecipient,
        uint16 feeBps
    ) external nonReentrant {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps, MAX_FEE_BPS);
        require(feeRecipient != address(0) || feeBps == 0, "fee=0 needs no recipient");
        _lock(orderId, seller, token, amount, deliveryDeadline, confirmationWindow,
              feeRecipient, feeBps);
    }

    function _lock(
        bytes32 orderId,
        address seller,
        IERC20 token,
        uint128 amount,
        uint64 deliveryDeadline,
        uint64 confirmationWindow,
        address feeRecipient,
        uint16 feeBps
    ) internal {
        if (amount == 0) revert ZeroAmount();
        if (orders[orderId].status != Status.None) revert OrderExists();
        require(seller != address(0) && seller != msg.sender, "bad seller");
        require(deliveryDeadline > block.timestamp, "deadline in past");

        orders[orderId] = Order({
            buyer: msg.sender,
            seller: seller,
            token: token,
            amount: amount,
            lockedAt: uint64(block.timestamp),
            deliveredAt: 0,
            deliveryDeadline: deliveryDeadline,
            confirmationWindow: confirmationWindow,
            deliveryReceiptHash: bytes32(0),
            status: Status.Locked,
            feeRecipient: feeRecipient,
            feeBps: feeBps
        });

        token.safeTransferFrom(msg.sender, address(this), amount);
        totalLocked[address(token)] += amount;
        emit Locked(orderId, msg.sender, seller, address(token), amount, deliveryDeadline);
    }

    /// @dev Pays out `total` to seller, less any platform fee. Returns the
    ///      portion that went to the seller (for event emission).
    function _payoutToSeller(bytes32 orderId, Order storage o, uint256 total)
        internal
        returns (uint256 toSeller)
    {
        if (o.feeBps != 0 && o.feeRecipient != address(0)) {
            uint256 fee = (total * o.feeBps) / 10000;
            if (fee > 0) {
                o.token.safeTransfer(o.feeRecipient, fee);
                emit FeeTaken(orderId, o.feeRecipient, fee);
            }
            toSeller = total - fee;
        } else {
            toSeller = total;
        }
        if (toSeller > 0) o.token.safeTransfer(o.seller, toSeller);
    }

    /// @notice Mark the order as delivered. Either the buyer (auto-confirms,
    ///         starts the confirmation window) or the operator (records the
    ///         delivery receipt for the buyer to dispute) can attest.
    function markDelivered(bytes32 orderId, bytes32 receiptHash) external {
        Order storage o = orders[orderId];
        if (o.status != Status.Locked) revert OrderNotLocked();
        if (msg.sender != o.buyer && msg.sender != operator) revert NotAuthorized();

        o.status = Status.Delivered;
        o.deliveredAt = uint64(block.timestamp);
        o.deliveryReceiptHash = receiptHash;
        emit Delivered(orderId, receiptHash, msg.sender);
    }

    /// @notice Seller withdraws funds after delivery + confirmation window.
    ///         If the buyer attested directly, the window can be 0 → instant.
    function release(bytes32 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.status != Status.Delivered) revert OrderNotDelivered();
        if (block.timestamp < uint256(o.deliveredAt) + o.confirmationWindow) {
            revert ConfirmationWindowOpen();
        }
        require(msg.sender == o.seller || msg.sender == operator, "not seller");

        o.status = Status.Released;
        totalLocked[address(o.token)] -= o.amount;
        uint256 toSeller = _payoutToSeller(orderId, o, o.amount);
        emit Released(orderId, o.seller, toSeller);
    }

    /// @notice Buyer raises a dispute during the confirmation window. Funds
    ///         freeze in escrow until the operator (an arbiter, multi-sig,
    ///         or oracle in production) resolves it. v1 has a single trust
    ///         root; v2 will route disputes to a 2-of-3 oracle.
    /// @param reasonHash Hash of an off-chain dispute filing (VES event,
    ///                   email, photos, etc.) so the resolver can audit it.
    function dispute(bytes32 orderId, bytes32 reasonHash) external {
        Order storage o = orders[orderId];
        if (o.status != Status.Delivered) revert OrderNotDelivered();
        if (msg.sender != o.buyer) revert NotAuthorized();

        o.status = Status.Disputed;
        emit Disputed(orderId, msg.sender, reasonHash);
    }

    /// @notice Operator resolves a dispute. Routes funds to the winning side.
    function resolveDispute(bytes32 orderId, bool inFavorOfSeller)
        external
        nonReentrant
    {
        Order storage o = orders[orderId];
        if (o.status != Status.Disputed) revert OrderNotDisputed();
        if (msg.sender != operator) revert NotAuthorized();

        uint256 amt = o.amount;
        totalLocked[address(o.token)] -= amt;
        if (inFavorOfSeller) {
            o.status = Status.Released;
            uint256 toSeller = _payoutToSeller(orderId, o, amt);
            emit Released(orderId, o.seller, toSeller);
        } else {
            o.status = Status.Refunded;
            // Refunds always return the full amount; the platform earns only
            // on completed transactions, mirroring real-world card networks.
            o.token.safeTransfer(o.buyer, amt);
            emit Refunded(orderId, o.buyer, amt);
        }
        emit DisputeResolved(orderId, inFavorOfSeller, msg.sender);
    }

    /// @notice Buyer recovers funds if the seller missed the delivery deadline.
    function refund(bytes32 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.status != Status.Locked) revert OrderNotLocked();
        if (block.timestamp < o.deliveryDeadline) revert DeadlineNotReached();
        require(msg.sender == o.buyer || msg.sender == operator, "not buyer");

        o.status = Status.Refunded;
        uint256 amt = o.amount;
        totalLocked[address(o.token)] -= amt;
        o.token.safeTransfer(o.buyer, amt);
        emit Refunded(orderId, o.buyer, amt);
    }

    /// @notice View helper for off-chain agents.
    function statusOf(bytes32 orderId) external view returns (Status) {
        return orders[orderId].status;
    }

    /// @notice The amount of `token` currently held by this contract that is
    ///         NOT backing an active locked order. For rebasing tokens, this is
    ///         the yield earned by escrowed funds; for non-rebasing tokens it
    ///         is normally 0 (or accidental transfers).
    function yieldAvailable(IERC20 token) public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 locked = totalLocked[address(token)];
        return bal > locked ? bal - locked : 0;
    }

    /// @notice Sweep accrued yield to a recipient. Operator-only — the operator
    ///         is the protocol's policy oracle for who earns the yield (a
    ///         marketplace, a yield pool, the buyer's wallet, etc.).
    function sweepYield(IERC20 token, address recipient) external nonReentrant {
        if (msg.sender != operator) revert NotAuthorized();
        require(recipient != address(0), "recipient=0");
        uint256 surplus = yieldAvailable(token);
        if (surplus == 0) return;
        token.safeTransfer(recipient, surplus);
        emit YieldSwept(address(token), recipient, surplus);
    }
}
