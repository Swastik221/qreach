// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Qreach, IQIEDEXRouter} from "../src/Qreach.sol";
import {MockQUSDC, MockRouter, MockQIEID} from "../test/mocks/Mocks.sol";

/// Mainnet (chain 1990). Dry run first (no --broadcast), then broadcast:
///   forge script script/Deploy.s.sol --rpc-url qie_mainnet --account deployer
///   forge script script/Deploy.s.sol --rpc-url qie_mainnet --account deployer --broadcast
/// Any other chain deploys mocks (QUSDC/QIEDEX exist only on mainnet).
/// The deploy block for NEXT_PUBLIC_DEPLOY_BLOCK is the receipt's blockNumber in
/// broadcast/Deploy.s.sol/1990/run-latest.json, not the block logged during simulation.
contract Deploy is Script {
    // Official addresses: qie.digital/developers and qiedex.qie.digital/qiedex-contracts (checked 2026-11-27).
    address constant QUSDC = 0x3F43DA82eC9A4f5285F10FaF1F26EcA7319E5DA5;
    address constant ROUTER = 0x08cd2e72e156D8563B4351eb4065C262A9f553Ef;
    address constant WQIE = 0x0087904D95BEe9E5F24dc8852804b547981A9139;
    // Not listed in QIE docs; verified on chain (domainOwnerByName works, see Qreach.fork.t.sol).
    address constant QIE_ID = 0x9aab56e7727af53A3131985BFB16d845319b7bdc;

    function run() external returns (Qreach pp) {
        if (block.chainid == 1990) _preflight();
        vm.startBroadcast();
        if (block.chainid == 1990) {
            pp = new Qreach(QUSDC, ROUTER, QIE_ID);
        } else {
            MockQUSDC usdc = new MockQUSDC();
            MockRouter router = new MockRouter(usdc, 1e9);
            MockQIEID qid = new MockQIEID();
            pp = new Qreach(address(usdc), address(router), address(qid));
            console2.log("MockQIEID", address(qid));
            console2.log("MockQUSDC", address(usdc));
            console2.log("MockRouter", address(router));
        }
        vm.stopBroadcast();
        console2.log("Qreach", address(pp));
        console2.log("chain", block.chainid);
        console2.log("block (simulation)", block.number);
    }

    /// Refuse to deploy if any mainnet dependency does not look right.
    function _preflight() internal view {
        require(QUSDC.code.length > 0 && ROUTER.code.length > 0 && QIE_ID.code.length > 0, "dependency has no code");
        require(IERC20Metadata(QUSDC).decimals() == 6, "QUSDC decimals != 6");
        require(keccak256(bytes(IERC20Metadata(QUSDC).symbol())) == keccak256("QUSDC"), "QUSDC symbol");
        require(IQIEDEXRouter(ROUTER).WETH() == WQIE, "router WQIE mismatch");
        (bool ok,) = QIE_ID.staticcall(abi.encodeWithSignature("domainOwnerByName(string,string)", "qie", "qie"));
        require(ok, "QIE ID does not resolve qie.qie");
        console2.log("preflight ok");
    }
}
