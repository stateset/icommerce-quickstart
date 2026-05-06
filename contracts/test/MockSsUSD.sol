// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Test stand-in for ssUSD: 6-decimal ERC-20 with public mint.
/// Used by the agent-receipt demo and integration tests. The production
/// stablecoin is SSDC.sol (rebasing, NAV-oracle-backed).
contract MockSsUSD is ERC20 {
    constructor() ERC20("StateSet USD (Test)", "ssUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
