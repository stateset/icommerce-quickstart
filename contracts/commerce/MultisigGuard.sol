// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title MultisigGuard
/// @notice Minimal `m-of-n` multisig that executes arbitrary calls once at
///         least `threshold` owner signatures are present. Owners sign a
///         canonical `(chainId, this, target, value, data, nonce)` tuple
///         off-chain; any relayer can submit the bundle.
///
///         Designed to plug in wherever the StateSet quickstart contracts
///         expose a single-key admin/operator role:
///
///           • `SSDC.setTreasuryVault(multisigGuard)` — multisig becomes
///             the only address that can `mintShares`/`burnShares`. Closes
///             the THREAT_MODEL.md "single-key SSDC.treasuryVault" item.
///
///           • Deploy `OrderEscrow(multisigGuard)` at construction time —
///             `OrderEscrow.operator` is `immutable`, so the multisig role
///             must be set on deploy, not transferred later. Closes the
///             "single-key OrderEscrow.operator" item for new deploys.
///
///           • `NAVOracle` exposes its own multi-attestor threshold in
///             `attestNAV`; this guard is for the *admin* surface
///             (setAuthorizedAttestor, setMaxStaleness, etc.) — point the
///             owner role at the guard, same as SSDC.
///
/// @dev Out of scope: owner rotation, EIP-1271 contract signers, ERC-4337
///      bundling. v1 keeps the surface as small as audit-able and still
///      useful for the demo. Production deployments that want
///      Safe-compatible features should swap this for the Safe contracts.
contract MultisigGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice Owners authorised to sign. Order is the insertion order; the
    ///         set is fixed at construction.
    address[] private _owners;
    mapping(address => bool) public isOwner;

    /// @notice Minimum signatures required to execute.
    uint8 public immutable threshold;

    /// @notice Strictly-monotonic nonce. Bumped before each call so a
    ///         malicious target re-entering `execute` cannot replay the
    ///         current signature set.
    uint256 public nonce;

    event Executed(uint256 indexed nonce, address indexed target, uint256 value, bytes32 dataHash);

    error InvalidOwnerSet();
    error InvalidThreshold();
    error NotOwner(address recovered);
    error DuplicateOrUnorderedSigner(address current, address previous);
    error InsufficientSignatures(uint256 supplied, uint8 required);
    error CallFailed(bytes returndata);

    /// @param owners_      The fixed signing set. Must be non-empty, ≤ 32, no
    ///                     duplicates, no zero address.
    /// @param threshold_   Number of distinct owner signatures required. Must
    ///                     satisfy `1 ≤ threshold_ ≤ owners_.length`.
    ///
    /// Why owners are immutable: rotation introduces a meta-governance layer
    /// (who can rotate the rotator?) that doubles the audit surface. For a
    /// quickstart the right answer is "redeploy"; production should reach for
    /// Safe.
    constructor(address[] memory owners_, uint8 threshold_) {
        // Why ≤ 32 owners: keeps the per-signature loop bounded so a malicious
        // construction can't push gas costs into the unbounded-fees region.
        if (owners_.length == 0 || owners_.length > 32) revert InvalidOwnerSet();
        if (threshold_ == 0 || threshold_ > owners_.length) revert InvalidThreshold();

        for (uint256 i = 0; i < owners_.length; i++) {
            address o = owners_[i];
            // Why reject zero + duplicates *here*: `recover` returns
            // `address(0)` on a malformed signature; a zero-owner would let
            // such a sig appear valid. Duplicates would break the
            // strict-ascending de-dup invariant in `execute`.
            if (o == address(0) || isOwner[o]) revert InvalidOwnerSet();
            isOwner[o] = true;
            _owners.push(o);
        }
        threshold = threshold_;
    }

    /// @notice The exact bytes32 that each owner must sign with
    ///         `eth_signMessage` (EIP-191 personal-sign envelope applied by
    ///         `toEthSignedMessageHash()`).
    /// @dev    `chainid` + `address(this)` bind the bundle to one chain and one
    ///         guard instance — preventing a signature from one deploy being
    ///         replayed on another.
    function callHash(address target, uint256 value, bytes calldata data, uint256 nonce_)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), target, value, data, nonce_));
    }

    /// @notice Execute `target.call{value: value}(data)` if `signatures` contain
    ///         at least `threshold` distinct owner signatures over the canonical
    ///         hash at the current nonce.
    /// @dev    Signatures MUST be sorted by recovered address ascending. This
    ///         provides O(n) deduplication without an extra seen-set; an
    ///         attacker who passes the same owner sig twice fails the strict
    ///         inequality and reverts.
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes[] calldata signatures
    ) external payable returns (bytes memory) {
        if (signatures.length < threshold) {
            revert InsufficientSignatures(signatures.length, threshold);
        }
        bytes32 ethHash = callHash(target, value, data, nonce).toEthSignedMessageHash();
        address lastSigner = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ethHash.recover(signatures[i]);
            // Why strict `>`: a strictly ascending order both deduplicates and
            // makes the check O(1) per sig. If a forged sig recovers to
            // address(0), `lastSigner` is also address(0) on the first
            // iteration; the constructor's zero-owner reject keeps this safe
            // (no owner can equal address(0)), and the isOwner check below is
            // the second line of defence.
            if (signer <= lastSigner) revert DuplicateOrUnorderedSigner(signer, lastSigner);
            if (!isOwner[signer]) revert NotOwner(signer);
            lastSigner = signer;
        }

        uint256 currentNonce = nonce;
        // Why bump nonce BEFORE the external call: a malicious target that
        // re-enters `execute` sees a fresh nonce and therefore cannot replay
        // this same signature set.
        unchecked {
            nonce = currentNonce + 1;
        }

        (bool ok, bytes memory ret) = target.call{ value: value }(data);
        if (!ok) revert CallFailed(ret);

        emit Executed(currentNonce, target, value, keccak256(data));
        return ret;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function ownersCount() external view returns (uint256) {
        return _owners.length;
    }

    /// @notice Accept ETH so the guard can fund value-bearing calls
    ///         (e.g. forwarding gas or paying for a paymaster deposit).
    receive() external payable { }
}
