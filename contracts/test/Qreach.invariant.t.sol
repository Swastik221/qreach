// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Qreach} from "../src/Qreach.sol";
import {MockQUSDC, MockRouter, MockQIEID} from "./mocks/Mocks.sol";

/// @notice Random sequences of actions by one sponsor and one creator.
contract Handler is Test {
    Qreach public pp;
    MockQUSDC public usdc;
    address public sponsor = makeAddr("sponsor");
    address public creator = makeAddr("creator");
    uint256[] public ids;
    uint256 public postNonce;

    constructor(Qreach pp_, MockQUSDC usdc_) {
        pp = pp_;
        usdc = usdc_;
        usdc.mint(sponsor, 1e15);
        vm.prank(sponsor);
        usdc.approve(address(pp), type(uint256).max);
    }

    function create(uint256 amount) external {
        amount = bound(amount, pp.MIN_AMOUNT(), 1e9);
        vm.prank(sponsor);
        ids.push(
            pp.createCampaign(
                creator, amount, uint64(block.timestamp + 1 days), uint64(block.timestamp + 3 days), 1 hours, "b"
            )
        );
    }

    function act(uint256 seed, uint8 action) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        action = action % 7;
        if (action == 0) {
            vm.prank(creator);
            try pp.accept(id) {} catch {}
        } else if (action == 1) {
            postNonce++;
            vm.prank(creator);
            try pp.submitWork(id, string.concat("https://x.com/p/", vm.toString(postNonce))) {} catch {}
        } else if (action == 2) {
            vm.prank(sponsor);
            try pp.approveAndPay(id) {} catch {}
        } else if (action == 3) {
            try pp.autoRelease(id) {} catch {}
        } else if (action == 4) {
            try pp.refundExpired(id) {} catch {}
        } else if (action == 5) {
            vm.prank(sponsor);
            try pp.cancel(id) {} catch {}
        } else {
            vm.prank(creator);
            try pp.decline(id) {} catch {}
        }
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }

    function count() external view returns (uint256) {
        return ids.length;
    }
}

contract QreachInvariantTest is Test {
    Qreach pp;
    MockQUSDC usdc;
    Handler h;

    function setUp() public {
        usdc = new MockQUSDC();
        MockRouter router = new MockRouter(usdc, 1e9);
        pp = new Qreach(address(usdc), address(router), address(new MockQIEID()));
        h = new Handler(pp, usdc);
        targetContract(address(h));
    }

    /// Contract balance always equals the sum of amounts still in escrow.
    function invariant_balanceEqualsOpenEscrow() public view {
        uint256 open;
        uint256 n = h.count();
        for (uint256 i; i < n; i++) {
            Qreach.Campaign memory c = pp.getCampaign(h.ids(i));
            if (
                c.status == Qreach.Status.Created || c.status == Qreach.Status.Accepted
                    || c.status == Qreach.Status.Submitted
            ) open += c.amount;
        }
        assertEq(usdc.balanceOf(address(pp)), open);
    }

    /// Creator earnings recorded on-chain equal what the creator actually received.
    function invariant_statsMatchPayouts() public view {
        assertEq(pp.creatorStats(h.creator()).earned, usdc.balanceOf(h.creator()));
    }

    /// No QUSDC is created or lost: sponsor + creator + escrow always hold exactly what was minted.
    function invariant_qusdcConserved() public view {
        assertEq(usdc.balanceOf(h.sponsor()) + usdc.balanceOf(h.creator()) + usdc.balanceOf(address(pp)), 1e15);
    }
}
