// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../test/MockSsUSD.sol";
import "../commerce/SetPaymentBatch.sol";
import "../commerce/OrderEscrow.sol";
import "../commerce/FxOracle.sol";
import "../SetRegistry.sol";
import "../stablecoin/SSDC.sol";
import "../stablecoin/NAVOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// Deploys the contracts the Agent Receipt demo needs on top of an existing
/// SetRegistry deployment:
///
///   1. MockSsUSD              — test stablecoin (6 decimals, public mint)
///   2. SetPaymentBatch (UUPS) — x402 batch settlement, sequencer-gated
///
/// Then funds buyer + seller with ssUSD so the demo can run end-to-end.
///
/// Reads from env:
///   DEPLOYER_PRIVATE_KEY  default: anvil[0]
///   SEQUENCER_ADDRESS     default: anvil[1] (already authorized on SetRegistry)
///   SET_REGISTRY_ADDRESS  default: 0xe7f1725e7734ce288f8367e1bb143e90bb3f0512
///   BUYER_ADDRESS         default: anvil[2]
///   SELLER_ADDRESS        default: anvil[3]
///   MINT_AMOUNT           default: 100_000_000_000 (100,000 ssUSD with 6 decimals)
contract DeployLocal is Script {
    function run() external {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);

        address sequencer = vm.envOr(
            "SEQUENCER_ADDRESS",
            address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8)
        );
        address registryEnv = vm.envOr("SET_REGISTRY_ADDRESS", address(0));
        address buyer = vm.envOr(
            "BUYER_ADDRESS",
            address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC)
        );
        address seller = vm.envOr(
            "SELLER_ADDRESS",
            address(0x90F79bf6EB2c4f870365E785982E1f101E93b906)
        );
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(100_000_000_000));

        console.log("=== Agent Receipt deploy ===");
        console.log("Deployer  ", deployer);
        console.log("Sequencer ", sequencer);
        console.log("Buyer     ", buyer);
        console.log("Seller    ", seller);

        vm.startBroadcast(deployerKey);

        // SetRegistry — redeploy unless the env var pointed at one
        address registry;
        if (registryEnv != address(0)) {
            registry = registryEnv;
            console.log("Registry  ", registry, "(reused)");
        } else {
            SetRegistry regImpl = new SetRegistry();
            bytes memory regInit = abi.encodeCall(
                SetRegistry.initialize,
                (deployer, sequencer)
            );
            registry = address(new ERC1967Proxy(address(regImpl), regInit));
            console.log("Registry  ", registry, "(fresh deploy)");
        }

        MockSsUSD ssUSD = new MockSsUSD();
        console.log("MockSsUSD ", address(ssUSD));

        SetPaymentBatch impl = new SetPaymentBatch();
        bytes memory init = abi.encodeCall(
            SetPaymentBatch.initialize,
            (deployer, sequencer, address(0), address(ssUSD), registry)
        );
        SetPaymentBatch payments = SetPaymentBatch(
            address(new ERC1967Proxy(address(impl), init))
        );
        console.log("PaymentBatch", address(payments));

        ssUSD.mint(buyer, mintAmount);
        ssUSD.mint(seller, mintAmount / 10);
        console.log("Buyer  ssUSD", ssUSD.balanceOf(buyer));
        console.log("Seller ssUSD", ssUSD.balanceOf(seller));

        OrderEscrow escrow = new OrderEscrow(sequencer);
        console.log("OrderEscrow", address(escrow));

        FxOracle fx = new FxOracle(sequencer);
        console.log("FxOracle  ", address(fx));

        // ── Production rebasing stablecoin: SSDC + NAVOracle ──────────────
        NAVOracle navImpl = new NAVOracle();
        bytes memory navInit = abi.encodeCall(
            NAVOracle.initialize,
            (deployer, deployer, uint256(7 days))   // owner=deployer, attestor=deployer
        );
        NAVOracle nav = NAVOracle(address(new ERC1967Proxy(address(navImpl), navInit)));
        console.log("NAVOracle ", address(nav));

        SSDC ssdcImpl = new SSDC();
        bytes memory ssdcInit = abi.encodeCall(SSDC.initialize, (deployer, address(nav)));
        SSDC ssdc = SSDC(address(new ERC1967Proxy(address(ssdcImpl), ssdcInit)));
        ssdc.setTreasuryVault(deployer); // deployer can mintShares directly for the demo
        // Tell the NAVOracle which SSDC contract to read totalShares from — required
        // for newNavPerShare to be computed correctly during attestNAV.
        nav.setSSDC(address(ssdc));
        console.log("SSDC       ", address(ssdc));

        // Mint SSDC shares to buyer/seller. Default NAV is $1.00, so 1 share = 1 SSDC.
        // SSDC has 18 decimals (vs MockSsUSD's 6).
        ssdc.mintShares(buyer, 100_000e18);  // 100,000 SSDC
        ssdc.mintShares(seller, 10_000e18);  // 10,000 SSDC

        // Approve SSDC as a settlement asset on SetPaymentBatch (alongside ssUSD).
        payments.configureAsset(
            address(ssdc),
            true,
            1e16,             // min: 0.01 SSDC
            1e30,             // max: 1e12 SSDC
            1e32              // daily: 1e14 SSDC
        );

        vm.stopBroadcast();

        // Seed FX quotes from a separate broadcast as the operator (sequencer key).
        uint256 sequencerKey = vm.envOr(
            "SEQUENCER_PRIVATE_KEY",
            uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d)
        );
        vm.startBroadcast(sequencerKey);
        // Quotes are scaled 1e18; 1-hour TTL is plenty for a demo run.
        // Realistic mid-rates (May 2026 vibe; replace with a feed in prod).
        fx.postQuote(keccak256(abi.encodePacked("EUR/ssUSD")), 1.0625e18, uint64(1 hours));
        fx.postQuote(keccak256(abi.encodePacked("GBP/ssUSD")), 1.2700e18, uint64(1 hours));
        fx.postQuote(keccak256(abi.encodePacked("JPY/ssUSD")), 0.0064e18, uint64(1 hours));
        fx.postQuote(keccak256(abi.encodePacked("MXN/ssUSD")), 0.0590e18, uint64(1 hours));
        vm.stopBroadcast();

        console.log("");
        console.log("export AGENT_RECEIPT_REGISTRY=", registry);
        console.log("export AGENT_RECEIPT_SSUSD=", address(ssUSD));
        console.log("export AGENT_RECEIPT_PAYMENTS=", address(payments));
        console.log("export AGENT_RECEIPT_ESCROW=", address(escrow));
        console.log("export AGENT_RECEIPT_FX=", address(fx));
        console.log("export AGENT_RECEIPT_SSDC=", address(ssdc));
        console.log("export AGENT_RECEIPT_NAV=", address(nav));
    }
}
