// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../SetRegistry.sol";
import "../commerce/SetPaymaster.sol";
import "../commerce/SetPaymentBatch.sol";
import "../commerce/OrderEscrow.sol";
import "../commerce/FxOracle.sol";
import "../stablecoin/SSDC.sol";
import "../stablecoin/NAVOracle.sol";
import "../test/MockSsUSD.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Public-testnet / mainnet deployment of the StateSet stack.
/// @notice Identical contract set to DeployAgentReceipt, but with explicit
///         env-driven configuration of every operator/admin address so a
///         real ops team can hand each role to a multi-sig.
///
/// Required env (set before invoking):
///   DEPLOYER_PRIVATE_KEY        the signer for the deploy txs
///   OWNER_ADDRESS               admin of upgradeable proxies (multi-sig)
///   SEQUENCER_ADDRESS           authorized SetRegistry / SetPaymentBatch sequencer
///   ESCROW_OPERATOR_ADDRESS     OrderEscrow operator (dispute resolver, sweepYield)
///   FX_OPERATOR_ADDRESS         FxOracle quote poster
///   NAV_ATTESTOR_ADDRESS        NAVOracle initial attestor
///   TREASURY_ADDRESS            SSDC treasury vault (only address that can mint)
///   USDC_ADDRESS                (optional) live USDC for SetPaymentBatch
///
/// Optional:
///   FUND_BUYERS                 if "1", mint a small SSDC test allocation
///                               (default 0 — production deploys keep supply at 0
///                                and let the bridge mint against fiat reserves)
///   BUYER_ADDRESS / SELLER_ADDRESS  test wallets to mint to if FUND_BUYERS=1
///
/// Run:
///   forge script script/DeploySepolia.s.sol:DeploySepolia \
///     --rpc-url $SEPOLIA_RPC --broadcast --verify
contract DeploySepolia is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envAddress("OWNER_ADDRESS");
        address sequencer = vm.envAddress("SEQUENCER_ADDRESS");
        address escrowOperator = vm.envAddress("ESCROW_OPERATOR_ADDRESS");
        address fxOperator = vm.envAddress("FX_OPERATOR_ADDRESS");
        address navAttestor = vm.envAddress("NAV_ATTESTOR_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address usdc = vm.envOr("USDC_ADDRESS", address(0));

        bool fundBuyers = vm.envOr("FUND_BUYERS", uint256(0)) == 1;
        address buyer = vm.envOr("BUYER_ADDRESS", address(0));
        address seller = vm.envOr("SELLER_ADDRESS", address(0));

        console.log("=== StateSet public-testnet deploy ===");
        console.log("deployer       ", deployer);
        console.log("owner          ", owner);
        console.log("sequencer      ", sequencer);
        console.log("escrowOperator ", escrowOperator);
        console.log("fxOperator     ", fxOperator);
        console.log("navAttestor    ", navAttestor);
        console.log("treasury       ", treasury);
        console.log("usdc           ", usdc);
        console.log("fundBuyers     ", fundBuyers);

        require(owner != deployer, "OWNER_ADDRESS must be a multi-sig (not the deployer EOA)");

        vm.startBroadcast(deployerKey);

        // ── SetRegistry (UUPS) ────────────────────────────────────────────
        SetRegistry registryImpl = new SetRegistry();
        bytes memory regInit = abi.encodeCall(SetRegistry.initialize, (owner, sequencer));
        SetRegistry registry = SetRegistry(address(new ERC1967Proxy(address(registryImpl), regInit)));
        console.log("SetRegistry  ", address(registry));

        // ── SetPaymaster (UUPS) ───────────────────────────────────────────
        SetPaymaster paymasterImpl = new SetPaymaster();
        bytes memory paymasterInit = abi.encodeCall(SetPaymaster.initialize, (owner, treasury));
        SetPaymaster paymaster = SetPaymaster(payable(address(new ERC1967Proxy(address(paymasterImpl), paymasterInit))));
        console.log("SetPaymaster ", address(paymaster));

        // ── NAVOracle (UUPS) ──────────────────────────────────────────────
        NAVOracle navImpl = new NAVOracle();
        bytes memory navInit = abi.encodeCall(
            NAVOracle.initialize,
            (owner, navAttestor, uint256(7 days))
        );
        NAVOracle nav = NAVOracle(address(new ERC1967Proxy(address(navImpl), navInit)));
        console.log("NAVOracle    ", address(nav));

        // ── SSDC (UUPS, treasury controls mint) ──────────────────────────
        SSDC ssdcImpl = new SSDC();
        bytes memory ssdcInit = abi.encodeCall(SSDC.initialize, (owner, address(nav)));
        SSDC ssdc = SSDC(address(new ERC1967Proxy(address(ssdcImpl), ssdcInit)));
        console.log("SSDC         ", address(ssdc));

        // Treasury is the address allowed to mint/burn SSDC.
        // In production this MUST be a multi-sig hot-wallet for the bridge.
        // In a fresh deploy the owner sets the treasury vault first.
        require(owner == deployer ? false : true, "owner != deployer");

        // We can't call setTreasuryVault as `owner` from this script (the
        // multi-sig must do it post-deploy). Print the call instead.
        console.log("");
        console.log("POST-DEPLOY: as owner multi-sig, call:");
        console.log("  ssdc.setTreasuryVault(treasury)");
        console.log("  nav.setSSDC(address(ssdc))");

        // ── MockSsUSD (test token; skip in mainnet) ──────────────────────
        MockSsUSD mockSsUsd = new MockSsUSD();
        console.log("MockSsUSD    ", address(mockSsUsd));

        // ── SetPaymentBatch (UUPS) ───────────────────────────────────────
        SetPaymentBatch paymentImpl = new SetPaymentBatch();
        bytes memory paymentInit = abi.encodeCall(
            SetPaymentBatch.initialize,
            (owner, sequencer, usdc, address(ssdc), address(registry))
        );
        SetPaymentBatch paymentBatch = SetPaymentBatch(
            address(new ERC1967Proxy(address(paymentImpl), paymentInit))
        );
        console.log("PaymentBatch ", address(paymentBatch));

        // ── OrderEscrow (plain) ──────────────────────────────────────────
        OrderEscrow escrow = new OrderEscrow(escrowOperator);
        console.log("OrderEscrow  ", address(escrow));

        // ── FxOracle (plain) ─────────────────────────────────────────────
        FxOracle fx = new FxOracle(fxOperator);
        console.log("FxOracle     ", address(fx));

        // Optional test funding (skip on mainnet)
        if (fundBuyers && buyer != address(0) && seller != address(0)) {
            require(deployer == treasury, "FUND_BUYERS=1 requires deployer == treasury");
            // mintShares only callable after owner sets treasury. So skip
            // here and require ops to do it post-deploy with the treasury key.
            console.log("");
            console.log("POST-DEPLOY (FUND_BUYERS): as treasury, call:");
            console.log("  ssdc.mintShares(buyer, 100_000e18)");
            console.log("  ssdc.mintShares(seller, 10_000e18)");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Address bundle (pin in your secrets store) ===");
        console.log("export SET_REGISTRY=  ", address(registry));
        console.log("export SET_PAYMASTER= ", address(paymaster));
        console.log("export NAV_ORACLE=    ", address(nav));
        console.log("export SSDC=          ", address(ssdc));
        console.log("export PAYMENT_BATCH= ", address(paymentBatch));
        console.log("export ORDER_ESCROW=  ", address(escrow));
        console.log("export FX_ORACLE=     ", address(fx));
        console.log("export MOCK_SSUSD=    ", address(mockSsUsd));
    }
}
