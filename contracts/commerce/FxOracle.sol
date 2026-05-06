// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FxOracle
/// @notice On-chain FX quote registry for cross-currency commerce.
///         Each quote is keyed by a `pair` identifier — by convention
///         keccak256(abi.encodePacked("EUR/ssUSD")) — and stores the
///         quote-currency-per-base-unit rate scaled by 1e18.
///
///         Example: 1 EUR = 1.0625 ssUSD → rate = 1.0625e18.
///                   convert(EURpair, 100e18 EUR) = 106.25e18 ssUSD-equiv (18dp).
///
/// @dev v1 is operator-permissioned: only the operator (sequencer or a
///      designated FX desk) can post quotes. v2 will accept multi-source
///      attestations or a STARK proof bounding the rate against an external
///      reference. Stale quotes are rejected on read; freshness is per-pair.
contract FxOracle {
    struct Quote {
        uint256 rate;        // quote-per-base-unit, 1e18 scale
        uint64 updatedAt;    // unix seconds
        uint64 ttl;          // seconds until quote is considered stale
        address poster;      // who posted this quote
    }

    /// @notice The single trusted operator. v1 has one role; v2 splits
    ///         "post" and "admin" so a multi-sig can rotate posters.
    address public immutable operator;

    /// @notice pairId → latest quote
    mapping(bytes32 => Quote) public quotes;

    event QuotePosted(
        bytes32 indexed pair,
        uint256 rate,
        uint64 updatedAt,
        uint64 ttl,
        address poster
    );

    error NotOperator();
    error ZeroRate();
    error UnknownPair();
    error StaleQuote(uint64 updatedAt, uint64 ttl, uint64 nowTs);

    constructor(address _operator) {
        require(_operator != address(0), "operator=0");
        operator = _operator;
    }

    /// @notice Convert a UTF-8 currency pair like "EUR/ssUSD" to the on-chain id.
    function pairId(string calldata pairText) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(pairText));
    }

    /// @notice Operator posts a fresh quote. ttl is how long it stays fresh.
    function postQuote(bytes32 pair, uint256 rate, uint64 ttl) external {
        if (msg.sender != operator) revert NotOperator();
        if (rate == 0) revert ZeroRate();
        require(ttl > 0 && ttl <= 7 days, "bad ttl");
        quotes[pair] = Quote({
            rate: rate,
            updatedAt: uint64(block.timestamp),
            ttl: ttl,
            poster: msg.sender
        });
        emit QuotePosted(pair, rate, uint64(block.timestamp), ttl, msg.sender);
    }

    /// @notice Read the latest quote, reverting if stale or missing.
    function getQuote(bytes32 pair) public view returns (uint256 rate, uint64 updatedAt) {
        Quote storage q = quotes[pair];
        if (q.updatedAt == 0) revert UnknownPair();
        if (block.timestamp > uint256(q.updatedAt) + q.ttl) {
            revert StaleQuote(q.updatedAt, q.ttl, uint64(block.timestamp));
        }
        return (q.rate, q.updatedAt);
    }

    /// @notice Convert `amountIn` units of the base currency to the quote
    ///         currency using the latest fresh on-chain quote.
    /// @param pair         keccak256(BASE/QUOTE)
    /// @param amountIn     amount of base currency, scaled by 1e18 (use the
    ///                     same scale callers use for tokens)
    /// @return amountOut   amount in quote currency, scaled by 1e18
    /// @return rate        the on-chain rate that was applied
    /// @return updatedAt   when the quote was posted
    function convert(bytes32 pair, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 rate, uint64 updatedAt)
    {
        (rate, updatedAt) = getQuote(pair);
        amountOut = (amountIn * rate) / 1e18;
    }

    /// @notice Convenience helper: is this quote fresh right now?
    function isFresh(bytes32 pair) external view returns (bool) {
        Quote storage q = quotes[pair];
        if (q.updatedAt == 0) return false;
        return block.timestamp <= uint256(q.updatedAt) + q.ttl;
    }
}
