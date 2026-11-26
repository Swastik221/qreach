// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Qreach} from "../src/Qreach.sol";
import {MockQUSDC, MockRouter, MockQIEID} from "./mocks/Mocks.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Pays with QIE, then tries to re-enter Qreach when the leftover QIE comes back.
contract ReentrantSponsor {
    Qreach immutable pp;
    uint256 public target;
    bytes public reentryError;

    constructor(Qreach pp_) {
        pp = pp_;
    }

    function setTarget(uint256 t) external {
        target = t;
    }

    function go(address creator, uint256 amt, uint64 a, uint64 d, uint256 v) external returns (uint256) {
        return pp.createCampaignWithQIE{value: v}(creator, amt, a, d, 1 hours, "x", block.timestamp + 60);
    }

    receive() external payable {
        if (target == 0 || msg.sender != address(pp)) return;
        uint256 t = target;
        target = 0;
        try pp.cancel(t) {}
        catch (bytes memory e) {
            reentryError = e;
        }
    }
}

/// A router that calls back into Qreach during the swap.
contract ReentrantRouter {
    address public constant WETH = address(0xBEEF);
    Qreach public pp;

    function setTarget(Qreach pp_) external {
        pp = pp_;
    }

    function swapETHForExactTokens(uint256, address[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory)
    {
        pp.refundExpired(1);
        return new uint256[](2);
    }
}

contract QreachTest is Test {
    Qreach pp;
    MockQUSDC usdc;
    MockRouter router;
    MockQIEID qid;

    address sponsor = makeAddr("sponsor");
    address creator = makeAddr("creator");
    address stranger = makeAddr("stranger");

    uint256 constant AMT = 2_000_000; // 2 QUSDC
    uint32 constant REVIEW = 1 days;
    string constant URL = "https://x.com/riya/status/1234567890";
    string constant BRIEF = "Post about TechFest 2026 with the Qreach link";

    uint64 acceptBy;
    uint64 deliverBy;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockQUSDC();
        router = new MockRouter(usdc, 1e9); // 1 QUSDC unit = 1 gwei QIE
        qid = new MockQIEID();
        pp = new Qreach(address(usdc), address(router), address(qid));
        usdc.mint(sponsor, 100_000_000);
        vm.prank(sponsor);
        usdc.approve(address(pp), type(uint256).max);
        acceptBy = uint64(block.timestamp + 1 days);
        deliverBy = uint64(block.timestamp + 3 days);
    }

    // ---------------- helpers ----------------

    function _create() internal returns (uint256 id) {
        vm.prank(sponsor);
        id = pp.createCampaign(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
    }

    function _accepted() internal returns (uint256 id) {
        id = _create();
        vm.prank(creator);
        pp.accept(id);
    }

    function _submitted() internal returns (uint256 id) {
        id = _accepted();
        vm.prank(creator);
        pp.submitWork(id, URL);
    }

    function _status(uint256 id) internal view returns (Qreach.Status) {
        return pp.getCampaign(id).status;
    }

    // ---------------- constructor ----------------

    function test_constructor_rejectsZero() public {
        vm.expectRevert(Qreach.ZeroAddress.selector);
        new Qreach(address(0), address(router), address(qid));
        vm.expectRevert(Qreach.ZeroAddress.selector);
        new Qreach(address(usdc), address(0), address(qid));
        vm.expectRevert(Qreach.ZeroAddress.selector);
        new Qreach(address(usdc), address(router), address(0));
    }

    // ---------------- .qie names ----------------

    function test_setQieName_ownerCanClaim() public {
        qid.register("riya", creator);
        vm.expectEmit(true, false, false, true);
        emit Qreach.QieNameSet(creator, "riya");
        vm.prank(creator);
        pp.setQieName("riya");
        assertEq(pp.qieLabelOf(creator), "riya");
    }

    function test_setQieName_strangerCannotClaim() public {
        qid.register("riya", creator);
        vm.prank(stranger);
        vm.expectRevert(Qreach.NotNameOwner.selector);
        pp.setQieName("riya");
    }

    function test_setQieName_unknownNameReverts() public {
        vm.prank(creator);
        vm.expectRevert(Qreach.NotNameOwner.selector);
        pp.setQieName("nobody");
    }

    function test_setQieName_tooLongReverts() public {
        vm.prank(creator);
        vm.expectRevert(Qreach.BadLabel.selector);
        pp.setQieName("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"); // 65 chars
    }

    function test_setQieName_emptyClears() public {
        qid.register("riya", creator);
        vm.startPrank(creator);
        pp.setQieName("riya");
        pp.setQieName("");
        vm.stopPrank();
        assertEq(pp.qieLabelOf(creator), "");
    }

    // ---------------- create ----------------

    function test_create_locksFunds() public {
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(usdc.balanceOf(address(pp)), AMT);
        Qreach.Campaign memory c = pp.getCampaign(id);
        assertEq(c.sponsor, sponsor);
        assertEq(c.creator, creator);
        assertEq(c.amount, AMT);
        assertEq(uint8(c.status), uint8(Qreach.Status.Created));
        assertEq(pp.nextId(), 2);
    }

    function test_create_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Qreach.CampaignCreated(1, sponsor, creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
        _create();
    }

    function test_create_revertsZeroCreator() public {
        vm.prank(sponsor);
        vm.expectRevert(Qreach.ZeroAddress.selector);
        pp.createCampaign(address(0), AMT, acceptBy, deliverBy, REVIEW, BRIEF);
    }

    function test_create_revertsSelfDeal() public {
        vm.prank(sponsor);
        vm.expectRevert(Qreach.SelfDeal.selector);
        pp.createCampaign(sponsor, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
    }

    function test_create_revertsSmallAmount() public {
        vm.prank(sponsor);
        vm.expectRevert(Qreach.AmountTooSmall.selector);
        pp.createCampaign(creator, 499_999, acceptBy, deliverBy, REVIEW, BRIEF);
    }

    function test_create_revertsAcceptByInPast() public {
        vm.prank(sponsor);
        vm.expectRevert(Qreach.BadDeadlines.selector);
        pp.createCampaign(creator, AMT, uint64(block.timestamp), deliverBy, REVIEW, BRIEF);
    }

    function test_create_revertsDeliverBeforeAccept() public {
        vm.prank(sponsor);
        vm.expectRevert(Qreach.BadDeadlines.selector);
        pp.createCampaign(creator, AMT, acceptBy, acceptBy, REVIEW, BRIEF);
    }

    function test_create_revertsReviewTooShort() public {
        vm.prank(sponsor);
        vm.expectRevert(Qreach.BadReviewWindow.selector);
        pp.createCampaign(creator, AMT, acceptBy, deliverBy, 1 hours - 1, BRIEF);
    }

    function test_create_revertsReviewTooLong() public {
        vm.prank(sponsor);
        vm.expectRevert(Qreach.BadReviewWindow.selector);
        pp.createCampaign(creator, AMT, acceptBy, deliverBy, 7 days + 1, BRIEF);
    }

    function test_create_revertsLongBrief() public {
        bytes memory b = new bytes(501);
        for (uint256 i; i < b.length; i++) {
            b[i] = "a";
        }
        vm.prank(sponsor);
        vm.expectRevert(Qreach.BriefTooLong.selector);
        pp.createCampaign(creator, AMT, acceptBy, deliverBy, REVIEW, string(b));
    }

    function test_create_revertsWithoutApproval() public {
        usdc.mint(stranger, AMT);
        vm.prank(stranger);
        vm.expectRevert();
        pp.createCampaign(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
    }

    // ---------------- create with QIE ----------------

    function test_createWithQIE_exactOutAndRefundsLeftover() public {
        uint256 cost = AMT * 1e9;
        vm.deal(sponsor, cost + 5 ether);
        vm.prank(sponsor);
        uint256 id = pp.createCampaignWithQIE{value: cost + 5 ether}(
            creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF, block.timestamp + 60
        );
        assertEq(usdc.balanceOf(address(pp)), AMT);
        assertEq(sponsor.balance, 5 ether);
        assertEq(address(pp).balance, 0);
        assertEq(pp.getCampaign(id).amount, AMT);
    }

    function test_createWithQIE_revertsIfNotEnoughValue() public {
        vm.deal(sponsor, 1);
        vm.prank(sponsor);
        vm.expectRevert(bytes("EXCESSIVE_INPUT_AMOUNT"));
        pp.createCampaignWithQIE{value: 1}(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF, block.timestamp + 60);
    }

    function test_createWithQIE_revertsOnShortSwap() public {
        router.setShortChange(true);
        uint256 cost = AMT * 1e9;
        vm.deal(sponsor, cost);
        vm.prank(sponsor);
        vm.expectRevert(Qreach.SwapShort.selector);
        pp.createCampaignWithQIE{value: cost}(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF, block.timestamp + 60);
    }

    function test_createWithQIE_validatesBeforeSwap() public {
        vm.deal(sponsor, 1 ether);
        vm.prank(sponsor);
        vm.expectRevert(Qreach.SelfDeal.selector);
        pp.createCampaignWithQIE{value: 1 ether}(sponsor, AMT, acceptBy, deliverBy, REVIEW, BRIEF, block.timestamp + 60);
    }

    function test_receive_onlyRouter() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(pp).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---------------- cancel ----------------

    function test_cancel_refunds() public {
        uint256 id = _create();
        uint256 before = usdc.balanceOf(sponsor);
        vm.prank(sponsor);
        pp.cancel(id);
        assertEq(usdc.balanceOf(sponsor), before + AMT);
        assertEq(uint8(_status(id)), uint8(Qreach.Status.Refunded));
    }

    function test_cancel_onlySponsor() public {
        uint256 id = _create();
        vm.prank(stranger);
        vm.expectRevert(Qreach.NotSponsor.selector);
        pp.cancel(id);
    }

    function test_cancel_notAfterAccept() public {
        uint256 id = _accepted();
        vm.prank(sponsor);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.cancel(id);
    }

    // ---------------- accept / decline ----------------

    function test_accept_onlyCreator() public {
        uint256 id = _create();
        vm.prank(stranger);
        vm.expectRevert(Qreach.NotCreator.selector);
        pp.accept(id);
    }

    function test_accept_afterDeadlineReverts() public {
        uint256 id = _create();
        vm.warp(acceptBy + 1);
        vm.prank(creator);
        vm.expectRevert(Qreach.TooLate.selector);
        pp.accept(id);
    }

    function test_accept_twiceReverts() public {
        uint256 id = _accepted();
        vm.prank(creator);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.accept(id);
    }

    function test_accept_unknownIdReverts() public {
        vm.prank(creator);
        vm.expectRevert(Qreach.NotCreator.selector);
        pp.accept(99);
    }

    function test_decline_refundsSponsor() public {
        uint256 id = _create();
        uint256 before = usdc.balanceOf(sponsor);
        vm.prank(creator);
        pp.decline(id);
        assertEq(usdc.balanceOf(sponsor), before + AMT);
        assertEq(uint8(_status(id)), uint8(Qreach.Status.Declined));
    }

    function test_decline_onlyCreator() public {
        uint256 id = _create();
        vm.prank(sponsor);
        vm.expectRevert(Qreach.NotCreator.selector);
        pp.decline(id);
    }

    function test_decline_notAfterAccept() public {
        uint256 id = _accepted();
        vm.prank(creator);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.decline(id);
    }

    // ---------------- submitWork ----------------

    function test_submit_recordsPost() public {
        uint256 id = _submitted();
        Qreach.Campaign memory c = pp.getCampaign(id);
        assertEq(uint8(c.status), uint8(Qreach.Status.Submitted));
        assertEq(c.postHash, keccak256(bytes(URL)));
        assertEq(c.submittedAt, block.timestamp);
        assertEq(pp.campaignOfCreatorPost(creator, keccak256(bytes(URL))), id);
        uint256[] memory ids = pp.campaignsOfPost(keccak256(bytes(URL)), 0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
    }

    function test_submit_onlyCreator() public {
        uint256 id = _accepted();
        vm.prank(stranger);
        vm.expectRevert(Qreach.NotCreator.selector);
        pp.submitWork(id, URL);
    }

    function test_submit_beforeAcceptReverts() public {
        uint256 id = _create();
        vm.prank(creator);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.submitWork(id, URL);
    }

    function test_submit_afterDeliverByReverts() public {
        uint256 id = _accepted();
        vm.warp(deliverBy + 1);
        vm.prank(creator);
        vm.expectRevert(Qreach.TooLate.selector);
        pp.submitWork(id, URL);
    }

    function test_submit_rejectsBadUrls() public {
        uint256 id = _accepted();
        string[] memory bad = new string[](5);
        bad[0] = "http://x.com/riya/status/1";
        bad[1] = "https://x.com/riya status";
        bad[2] = "https://";
        bad[3] = "ftp://example.com/file";
        bad[4] = unicode"https://x.com/é";
        for (uint256 i; i < bad.length; i++) {
            vm.prank(creator);
            vm.expectRevert(Qreach.BadUrl.selector);
            pp.submitWork(id, bad[i]);
        }
    }

    function test_submit_rejectsTooLongUrl() public {
        uint256 id = _accepted();
        bytes memory u = bytes.concat("https://x.com/", new bytes(0));
        bytes memory pad = new bytes(300);
        for (uint256 i; i < pad.length; i++) {
            pad[i] = "a";
        }
        vm.prank(creator);
        vm.expectRevert(Qreach.BadUrl.selector);
        pp.submitWork(id, string(bytes.concat(u, pad)));
    }

    function test_submit_reusedPostReverts() public {
        _submitted();
        vm.prank(sponsor);
        uint256 id2 = pp.createCampaign(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
        vm.prank(creator);
        pp.accept(id2);
        vm.prank(creator);
        vm.expectRevert(Qreach.PostAlreadyUsed.selector);
        pp.submitWork(id2, URL);
    }

    // ---------------- approveAndPay ----------------

    function test_approve_paysCreatorAndDiscloses() public {
        uint256 id = _submitted();
        vm.expectEmit(true, true, true, true);
        emit Qreach.PaidPromotion(id, sponsor, creator, AMT, keccak256(bytes(URL)), uint64(block.timestamp), false);
        vm.prank(sponsor);
        pp.approveAndPay(id);

        assertEq(usdc.balanceOf(creator), AMT);
        assertEq(usdc.balanceOf(address(pp)), 0);
        uint256[] memory ids = pp.campaignsOfPost(keccak256(bytes(URL)), 0, 10);
        assertEq(ids.length, 1);
        Qreach.Campaign memory c = pp.getCampaign(ids[0]);
        assertEq(ids[0], id);
        assertEq(c.sponsor, sponsor);
        assertEq(c.creator, creator);
        assertEq(c.amount, AMT);
        assertEq(c.paidAt, block.timestamp);
        assertEq(uint8(c.status), uint8(Qreach.Status.Paid));
    }

    function test_approve_updatesStats() public {
        uint256 id = _submitted();
        vm.prank(sponsor);
        pp.approveAndPay(id);
        Qreach.Stats memory s = pp.creatorStats(creator);
        assertEq(s.completed, 1);
        assertEq(s.expired, 0);
        assertEq(s.earned, AMT);
    }

    function test_approve_onlySponsor() public {
        uint256 id = _submitted();
        vm.prank(creator);
        vm.expectRevert(Qreach.NotSponsor.selector);
        pp.approveAndPay(id);
    }

    function test_approve_beforeSubmitReverts() public {
        uint256 id = _accepted();
        vm.prank(sponsor);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.approveAndPay(id);
    }

    function test_approve_twiceReverts() public {
        uint256 id = _submitted();
        vm.prank(sponsor);
        pp.approveAndPay(id);
        vm.prank(sponsor);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.approveAndPay(id);
    }

    // ---------------- autoRelease ----------------

    function test_autoRelease_tooEarlyReverts() public {
        uint256 id = _submitted();
        vm.warp(block.timestamp + REVIEW);
        vm.expectRevert(Qreach.TooEarly.selector);
        pp.autoRelease(id);
    }

    function test_autoRelease_anyonePaysAfterWindow() public {
        uint256 id = _submitted();
        vm.warp(block.timestamp + REVIEW + 1);
        vm.prank(stranger);
        pp.autoRelease(id);
        assertEq(usdc.balanceOf(creator), AMT);
        assertEq(uint8(_status(id)), uint8(Qreach.Status.Paid));
    }

    function test_autoRelease_notBeforeSubmit() public {
        uint256 id = _accepted();
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.autoRelease(id);
    }

    function test_autoRelease_afterPaidReverts() public {
        uint256 id = _submitted();
        vm.prank(sponsor);
        pp.approveAndPay(id);
        vm.warp(block.timestamp + REVIEW + 1);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.autoRelease(id);
    }

    // ---------------- refundExpired ----------------

    function test_refundExpired_notAccepted() public {
        uint256 id = _create();
        vm.warp(acceptBy + 1);
        uint256 before = usdc.balanceOf(sponsor);
        vm.prank(stranger);
        pp.refundExpired(id);
        assertEq(usdc.balanceOf(sponsor), before + AMT);
        assertEq(pp.creatorStats(creator).expired, 0);
    }

    function test_refundExpired_notDelivered() public {
        uint256 id = _accepted();
        vm.warp(deliverBy + 1);
        pp.refundExpired(id);
        assertEq(uint8(_status(id)), uint8(Qreach.Status.Refunded));
        assertEq(pp.creatorStats(creator).expired, 1);
    }

    function test_refundExpired_tooEarlyReverts() public {
        uint256 id = _create();
        vm.expectRevert(Qreach.NotExpired.selector);
        pp.refundExpired(id);
        vm.prank(creator);
        pp.accept(id);
        vm.expectRevert(Qreach.NotExpired.selector);
        pp.refundExpired(id);
    }

    function test_refundExpired_notAfterSubmit() public {
        uint256 id = _submitted();
        vm.warp(deliverBy + 30 days);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.refundExpired(id);
    }

    function test_refundExpired_noDoubleRefund() public {
        uint256 id = _create();
        vm.warp(acceptBy + 1);
        pp.refundExpired(id);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.refundExpired(id);
    }

    // ---------------- disclosure ----------------

    function test_disclosure_unknownPost() public view {
        assertEq(pp.postCampaignCount(keccak256("https://x.com/none")), 0);
        assertEq(pp.campaignsOfPost(keccak256("https://x.com/none"), 0, 10).length, 0);
    }

    function test_disclosure_submittedButNotPaid() public {
        uint256 id = _submitted();
        uint256[] memory ids = pp.campaignsOfPost(keccak256(bytes(URL)), 0, 10);
        assertEq(ids[0], id);
        assertEq(pp.getCampaign(id).paidAt, 0);
        assertEq(uint8(pp.getCampaign(id).status), uint8(Qreach.Status.Submitted));
    }

    /// Someone else submitting a creator's post first must not block the real creator.
    function test_submit_squatterCannotBlockRealCreator() public {
        address squatSponsor = makeAddr("squatSponsor");
        address squatter = makeAddr("squatter");
        usdc.mint(squatSponsor, AMT);
        vm.startPrank(squatSponsor);
        usdc.approve(address(pp), AMT);
        uint256 bad = pp.createCampaign(squatter, AMT, acceptBy, deliverBy, REVIEW, "squat");
        vm.stopPrank();
        vm.prank(squatter);
        pp.accept(bad);
        vm.prank(squatter);
        pp.submitWork(bad, URL);

        uint256 good = _submitted(); // real creator submits the same post afterwards
        uint256[] memory ids = pp.campaignsOfPost(keccak256(bytes(URL)), 0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], bad);
        assertEq(ids[1], good);
        assertEq(pp.postCampaignCount(keccak256(bytes(URL))), 2);
    }

    function test_campaignsOfPost_pagination() public {
        bytes32 h = keccak256(bytes(URL));
        for (uint256 i; i < 3; i++) {
            address cr = makeAddr(string(abi.encodePacked("cr", i)));
            vm.prank(sponsor);
            uint256 id = pp.createCampaign(cr, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
            vm.prank(cr);
            pp.accept(id);
            vm.prank(cr);
            pp.submitWork(id, URL);
        }
        assertEq(pp.campaignsOfPost(h, 0, 2).length, 2);
        assertEq(pp.campaignsOfPost(h, 2, 2).length, 1);
        assertEq(pp.campaignsOfPost(h, 2, 2)[0], 3);
        assertEq(pp.campaignsOfPost(h, 5, 2).length, 0);
    }

    // ---------------- deadline boundaries ----------------

    function test_accept_atExactDeadlineWorks_andRefundNotYet() public {
        uint256 id = _create();
        vm.warp(acceptBy);
        vm.expectRevert(Qreach.NotExpired.selector);
        pp.refundExpired(id);
        vm.prank(creator);
        pp.accept(id);
        assertEq(uint8(_status(id)), uint8(Qreach.Status.Accepted));
    }

    function test_submit_atExactDeadlineWorks_andRefundNotYet() public {
        uint256 id = _accepted();
        vm.warp(deliverBy);
        vm.expectRevert(Qreach.NotExpired.selector);
        pp.refundExpired(id);
        vm.prank(creator);
        pp.submitWork(id, URL);
        assertEq(uint8(_status(id)), uint8(Qreach.Status.Submitted));
    }

    // ---------------- funding failures ----------------

    function test_create_revertsInsufficientBalance() public {
        vm.startPrank(stranger);
        usdc.approve(address(pp), AMT);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, AMT));
        pp.createCampaign(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
        vm.stopPrank();
    }

    function test_create_revertsInsufficientAllowance() public {
        usdc.mint(stranger, AMT);
        vm.startPrank(stranger);
        usdc.approve(address(pp), AMT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pp), AMT - 1, AMT)
        );
        pp.createCampaign(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
        vm.stopPrank();
        assertEq(pp.nextId(), 1);
    }

    function test_createWithQIE_revertsAfterSwapDeadline() public {
        vm.deal(sponsor, 1 ether);
        vm.prank(sponsor);
        vm.expectRevert(bytes("EXPIRED"));
        pp.createCampaignWithQIE{value: 1 ether}(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF, block.timestamp - 1);
    }

    function test_createWithQIE_validatesAmountBeforeSwap() public {
        vm.deal(sponsor, 1 ether);
        vm.prank(sponsor);
        vm.expectRevert(Qreach.AmountTooSmall.selector);
        pp.createCampaignWithQIE{value: 1 ether}(creator, 1, acceptBy, deliverBy, REVIEW, BRIEF, block.timestamp + 60);
    }

    // ---------------- events and stats ----------------

    function test_autoRelease_emitsAndCountsStats() public {
        uint256 id = _submitted();
        vm.warp(block.timestamp + REVIEW + 1);
        vm.expectEmit(true, true, true, true);
        emit Qreach.PaidPromotion(id, sponsor, creator, AMT, keccak256(bytes(URL)), uint64(block.timestamp), true);
        pp.autoRelease(id);
        Qreach.Stats memory s = pp.creatorStats(creator);
        assertEq(s.completed, 1);
        assertEq(s.earned, AMT);
    }

    function test_decline_emitsDeclinedAndRefunded() public {
        uint256 id = _create();
        vm.expectEmit(true, true, false, false);
        emit Qreach.Declined(id, creator);
        vm.expectEmit(true, true, false, true);
        emit Qreach.Refunded(id, sponsor, AMT);
        vm.prank(creator);
        pp.decline(id);
    }

    function test_decline_stillAllowedAfterAcceptDeadline() public {
        uint256 id = _create();
        vm.warp(acceptBy + 1);
        vm.prank(creator);
        pp.decline(id);
        assertEq(usdc.balanceOf(address(pp)), 0);
    }

    // ---------------- terminal states and unknown ids ----------------

    function test_terminalStates_cannotMoveFundsAgain() public {
        uint256 paid = _submitted();
        vm.prank(sponsor);
        pp.approveAndPay(paid);
        vm.prank(sponsor);
        uint256 declined = pp.createCampaign(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
        vm.prank(creator);
        pp.decline(declined);
        vm.prank(sponsor);
        uint256 cancelled = pp.createCampaign(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF);
        vm.prank(sponsor);
        pp.cancel(cancelled);

        vm.warp(deliverBy + 30 days);
        uint256[3] memory ids = [paid, declined, cancelled];
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(Qreach.WrongStatus.selector);
            pp.refundExpired(ids[i]);
            vm.expectRevert(Qreach.WrongStatus.selector);
            pp.autoRelease(ids[i]);
            vm.prank(sponsor);
            vm.expectRevert(Qreach.WrongStatus.selector);
            pp.cancel(ids[i]);
            vm.prank(sponsor);
            vm.expectRevert(Qreach.WrongStatus.selector);
            pp.approveAndPay(ids[i]);
            vm.prank(creator);
            vm.expectRevert(Qreach.WrongStatus.selector);
            pp.decline(ids[i]);
        }
        assertEq(usdc.balanceOf(address(pp)), 0);
        assertEq(usdc.balanceOf(creator), AMT);
    }

    function test_unknownId_reverts() public {
        vm.expectRevert(Qreach.NotSponsor.selector);
        pp.approveAndPay(42);
        vm.expectRevert(Qreach.NotSponsor.selector);
        pp.cancel(42);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.autoRelease(42);
        vm.expectRevert(Qreach.WrongStatus.selector);
        pp.refundExpired(42);
    }

    // ---------------- reentrancy ----------------

    /// The leftover-QIE refund hands control to the sponsor; re-entering must fail.
    function test_reentrancy_viaLeftoverRefundIsBlocked() public {
        ReentrantSponsor att = new ReentrantSponsor(pp);
        uint256 cost = AMT * 1e9;
        vm.deal(address(att), 2 * cost + 1 ether);
        uint256 first = att.go(creator, AMT, acceptBy, deliverBy, cost); // exact, no callback
        att.setTarget(first);
        att.go(creator, AMT, acceptBy, deliverBy, cost + 1 ether);
        assertEq(att.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(uint8(_status(first)), uint8(Qreach.Status.Created));
        assertEq(usdc.balanceOf(address(pp)), 2 * AMT);
        assertEq(address(att).balance, 1 ether);
    }

    /// A router calling back into Qreach during the swap is stopped by the guard.
    function test_reentrancy_viaRouterIsBlocked() public {
        ReentrantRouter bad = new ReentrantRouter();
        Qreach q = new Qreach(address(usdc), address(bad), address(qid));
        bad.setTarget(q);
        vm.deal(sponsor, 1 ether);
        vm.prank(sponsor);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        q.createCampaignWithQIE{value: 1 ether}(creator, AMT, acceptBy, deliverBy, REVIEW, BRIEF, block.timestamp + 60);
    }

    // ---------------- fuzz ----------------

    function testFuzz_fullFlowPaysExactAmount(uint256 amount, uint32 review) public {
        amount = bound(amount, pp.MIN_AMOUNT(), 50_000_000);
        review = uint32(bound(review, pp.MIN_REVIEW(), pp.MAX_REVIEW()));
        vm.prank(sponsor);
        uint256 id = pp.createCampaign(creator, amount, acceptBy, deliverBy, review, BRIEF);
        vm.prank(creator);
        pp.accept(id);
        vm.prank(creator);
        pp.submitWork(id, URL);
        vm.warp(block.timestamp + uint256(review) + 1);
        pp.autoRelease(id);
        assertEq(usdc.balanceOf(creator), amount);
        assertEq(usdc.balanceOf(address(pp)), 0);
    }

    function testFuzz_strangerCannotMoveFunds(address who) public {
        vm.assume(who != sponsor && who != creator);
        uint256 id = _submitted();
        vm.startPrank(who);
        vm.expectRevert(Qreach.NotSponsor.selector);
        pp.approveAndPay(id);
        vm.expectRevert(Qreach.NotSponsor.selector);
        pp.cancel(id);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(pp)), AMT);
    }
}
