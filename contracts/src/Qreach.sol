// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal QIEDEX (UniswapV2-style) router interface used by Qreach.
interface IQIEDEXRouter {
    function WETH() external view returns (address);

    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
}

/// @notice QIE ID (.qie names) registry. tokenId = uint256(keccak256(abi.encodePacked(parent, label))).
interface IQIEID {
    function domainOwnerByName(string calldata label, string calldata parent) external view returns (address);
}

/// @title Qreach
/// @notice Escrow for paid creator posts, with a public on-chain record of every paid post.
///         A sponsor locks QUSDC for a named creator. The creator accepts, posts, and submits
///         the post URL. When the sponsor approves (or stays silent past the review window),
///         the creator is paid and a PaidPromotion record is written that anyone can look up.
/// @dev No owner, no fees, no upgrades. Only QUSDC is accepted.
contract Qreach is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Created,
        Accepted,
        Submitted,
        Paid,
        Refunded,
        Declined
    }

    struct Campaign {
        address sponsor;
        uint64 acceptBy;
        uint32 reviewWindow;
        Status status;
        address creator;
        uint64 deliverBy;
        uint64 submittedAt;
        uint128 amount;
        uint64 paidAt;
        bytes32 postHash;
    }

    struct Stats {
        uint32 completed;
        uint32 expired;
        uint128 earned;
    }

    uint256 public constant MIN_AMOUNT = 500_000; // 0.5 QUSDC (6 decimals)
    uint256 public constant MAX_BRIEF = 500;
    uint256 public constant MAX_URL = 300;
    uint32 public constant MIN_REVIEW = 1 hours;
    uint32 public constant MAX_REVIEW = 7 days;

    IERC20 public immutable qusdc;
    IQIEDEXRouter public immutable router;
    IQIEID public immutable qieId;
    uint256 public constant MAX_LABEL = 64;

    uint256 public nextId = 1;
    mapping(uint256 => Campaign) internal _campaigns;
    /// @dev Every campaign a post was submitted to. A post can appear more than once (the contract
    ///      cannot tell who really wrote it), so nobody can lock a post away from its real creator.
    mapping(bytes32 => uint256[]) internal _campaignsOfPost;
    /// @notice Campaign in which `creator` already used a post (0 if never). Stops a creator from
    ///         being paid twice for one post.
    mapping(address => mapping(bytes32 => uint256)) public campaignOfCreatorPost;
    mapping(address => Stats) internal _stats;
    /// @notice .qie label (without ".qie") an address has claimed. Re-check ownership when reading,
    ///         because a name can be transferred after it was claimed.
    mapping(address => string) public qieLabelOf;

    event CampaignCreated(
        uint256 indexed id,
        address indexed sponsor,
        address indexed creator,
        uint256 amount,
        uint64 acceptBy,
        uint64 deliverBy,
        uint32 reviewWindow,
        string brief
    );
    event Accepted(uint256 indexed id, address indexed creator);
    event Declined(uint256 indexed id, address indexed creator);
    event WorkSubmitted(uint256 indexed id, address indexed creator, bytes32 indexed postHash, string url);
    event PaidPromotion(
        uint256 indexed id,
        address indexed sponsor,
        address indexed creator,
        uint256 amount,
        bytes32 postHash,
        uint64 paidAt,
        bool autoReleased
    );
    event QieNameSet(address indexed account, string label);
    event Refunded(uint256 indexed id, address indexed sponsor, uint256 amount);

    error ZeroAddress();
    error SelfDeal();
    error AmountTooSmall();
    error AmountTooLarge();
    error BadDeadlines();
    error BadReviewWindow();
    error BriefTooLong();
    error BadUrl();
    error PostAlreadyUsed();
    error NotSponsor();
    error NotCreator();
    error WrongStatus();
    error TooLate();
    error TooEarly();
    error NotExpired();
    error SwapShort();
    error RefundFailed();
    error OnlyRouter();
    error NotNameOwner();
    error BadLabel();

    constructor(address qusdc_, address router_, address qieId_) {
        if (qusdc_ == address(0) || router_ == address(0) || qieId_ == address(0)) revert ZeroAddress();
        qusdc = IERC20(qusdc_);
        router = IQIEDEXRouter(router_);
        qieId = IQIEID(qieId_);
    }

    /// @dev The router refunds unused QIE here during createCampaignWithQIE.
    receive() external payable {
        if (msg.sender != address(router)) revert OnlyRouter();
    }

    // ------------------------------------------------------------------
    // Sponsor actions
    // ------------------------------------------------------------------

    /// @notice Lock `amount` QUSDC for `creator`. The sponsor must approve this contract first.
    function createCampaign(
        address creator,
        uint256 amount,
        uint64 acceptBy,
        uint64 deliverBy,
        uint32 reviewWindow,
        string calldata brief
    ) external nonReentrant returns (uint256 id) {
        _validate(creator, amount, acceptBy, deliverBy, reviewWindow, brief);
        qusdc.safeTransferFrom(msg.sender, address(this), amount);
        id = _create(creator, amount, acceptBy, deliverBy, reviewWindow, brief);
    }

    /// @notice Pay in native QIE: the contract swaps QIE for exactly `amountOut` QUSDC on QIEDEX
    ///         and returns any unused QIE to the sender.
    function createCampaignWithQIE(
        address creator,
        uint256 amountOut,
        uint64 acceptBy,
        uint64 deliverBy,
        uint32 reviewWindow,
        string calldata brief,
        uint256 swapDeadline
    ) external payable nonReentrant returns (uint256 id) {
        _validate(creator, amountOut, acceptBy, deliverBy, reviewWindow, brief);

        uint256 nativeBefore = address(this).balance - msg.value;
        uint256 qusdcBefore = qusdc.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(qusdc);
        router.swapETHForExactTokens{value: msg.value}(amountOut, path, address(this), swapDeadline);

        if (qusdc.balanceOf(address(this)) - qusdcBefore < amountOut) revert SwapShort();

        uint256 leftover = address(this).balance - nativeBefore;
        if (leftover > 0) {
            (bool ok,) = msg.sender.call{value: leftover}("");
            if (!ok) revert RefundFailed();
        }

        id = _create(creator, amountOut, acceptBy, deliverBy, reviewWindow, brief);
    }

    /// @notice Cancel before the creator accepts. Full refund.
    function cancel(uint256 id) external nonReentrant {
        Campaign storage c = _campaigns[id];
        if (msg.sender != c.sponsor) revert NotSponsor();
        if (c.status != Status.Created) revert WrongStatus();
        _refund(id, c);
    }

    /// @notice Approve the submitted post and pay the creator.
    function approveAndPay(uint256 id) external nonReentrant {
        Campaign storage c = _campaigns[id];
        if (msg.sender != c.sponsor) revert NotSponsor();
        if (c.status != Status.Submitted) revert WrongStatus();
        _pay(id, c, false);
    }

    // ------------------------------------------------------------------
    // Creator actions
    // ------------------------------------------------------------------

    function accept(uint256 id) external {
        Campaign storage c = _campaigns[id];
        if (msg.sender != c.creator) revert NotCreator();
        if (c.status != Status.Created) revert WrongStatus();
        if (block.timestamp > c.acceptBy) revert TooLate();
        c.status = Status.Accepted;
        emit Accepted(id, msg.sender);
    }

    /// @notice Decline an offer. The sponsor is refunded in the same transaction.
    function decline(uint256 id) external nonReentrant {
        Campaign storage c = _campaigns[id];
        if (msg.sender != c.creator) revert NotCreator();
        if (c.status != Status.Created) revert WrongStatus();
        c.status = Status.Declined;
        uint256 amount = c.amount;
        emit Declined(id, msg.sender);
        emit Refunded(id, c.sponsor, amount);
        qusdc.safeTransfer(c.sponsor, amount);
    }

    /// @notice Submit the post URL. The app normalises the URL before sending it,
    ///         so the same post always gives the same hash.
    function submitWork(uint256 id, string calldata url) external {
        Campaign storage c = _campaigns[id];
        if (msg.sender != c.creator) revert NotCreator();
        if (c.status != Status.Accepted) revert WrongStatus();
        if (block.timestamp > c.deliverBy) revert TooLate();
        _checkUrl(bytes(url));

        bytes32 postHash = keccak256(bytes(url));
        if (campaignOfCreatorPost[msg.sender][postHash] != 0) revert PostAlreadyUsed();

        campaignOfCreatorPost[msg.sender][postHash] = id;
        _campaignsOfPost[postHash].push(id);
        c.postHash = postHash;
        c.submittedAt = uint64(block.timestamp);
        c.status = Status.Submitted;
        emit WorkSubmitted(id, msg.sender, postHash, url);
    }

    // ------------------------------------------------------------------
    // Anyone
    // ------------------------------------------------------------------

    /// @notice Pay the creator if the sponsor did not act within the review window.
    function autoRelease(uint256 id) external nonReentrant {
        Campaign storage c = _campaigns[id];
        if (c.status != Status.Submitted) revert WrongStatus();
        if (block.timestamp <= uint256(c.submittedAt) + c.reviewWindow) revert TooEarly();
        _pay(id, c, true);
    }

    /// @notice Refund the sponsor if the creator did not accept by acceptBy,
    ///         or did not submit by deliverBy. Funds always go to the sponsor.
    function refundExpired(uint256 id) external nonReentrant {
        Campaign storage c = _campaigns[id];
        if (c.status == Status.Created) {
            if (block.timestamp <= c.acceptBy) revert NotExpired();
        } else if (c.status == Status.Accepted) {
            if (block.timestamp <= c.deliverBy) revert NotExpired();
            _stats[c.creator].expired += 1;
        } else {
            revert WrongStatus();
        }
        _refund(id, c);
    }

    // ------------------------------------------------------------------
    // Names
    // ------------------------------------------------------------------

    /// @notice Link the caller to a .qie name they own, so apps can show "riya.qie" instead of 0x...
    ///         Pass an empty label to clear it. The label must be the part before ".qie".
    function setQieName(string calldata label) external {
        uint256 n = bytes(label).length;
        if (n > MAX_LABEL) revert BadLabel();
        if (n > 0) {
            address owner_;
            try qieId.domainOwnerByName(label, "qie") returns (address o) {
                owner_ = o;
            } catch {
                revert NotNameOwner();
            }
            if (owner_ != msg.sender) revert NotNameOwner();
        }
        qieLabelOf[msg.sender] = label;
        emit QieNameSet(msg.sender, label);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getCampaign(uint256 id) external view returns (Campaign memory) {
        return _campaigns[id];
    }

    function creatorStats(address creator) external view returns (Stats memory) {
        return _stats[creator];
    }

    /// @notice How many campaigns a post (hash of its normalised URL) was submitted to.
    function postCampaignCount(bytes32 postHash) external view returns (uint256) {
        return _campaignsOfPost[postHash].length;
    }

    /// @notice Campaign ids for a post, oldest first, `start` to `start + max` (clamped).
    function campaignsOfPost(bytes32 postHash, uint256 start, uint256 max)
        external
        view
        returns (uint256[] memory ids)
    {
        uint256[] storage all = _campaignsOfPost[postHash];
        if (start >= all.length) return new uint256[](0);
        uint256 end = start + max > all.length ? all.length : start + max;
        ids = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            ids[i - start] = all[i];
        }
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _validate(
        address creator,
        uint256 amount,
        uint64 acceptBy,
        uint64 deliverBy,
        uint32 reviewWindow,
        string calldata brief
    ) internal view {
        if (creator == address(0)) revert ZeroAddress();
        if (creator == msg.sender) revert SelfDeal();
        if (amount < MIN_AMOUNT) revert AmountTooSmall();
        if (amount > type(uint128).max) revert AmountTooLarge();
        if (acceptBy <= block.timestamp || deliverBy <= acceptBy) revert BadDeadlines();
        if (reviewWindow < MIN_REVIEW || reviewWindow > MAX_REVIEW) revert BadReviewWindow();
        if (bytes(brief).length > MAX_BRIEF) revert BriefTooLong();
    }

    function _create(
        address creator,
        uint256 amount,
        uint64 acceptBy,
        uint64 deliverBy,
        uint32 reviewWindow,
        string calldata brief
    ) internal returns (uint256 id) {
        id = nextId++;
        Campaign storage c = _campaigns[id];
        c.sponsor = msg.sender;
        c.creator = creator;
        c.amount = uint128(amount);
        c.acceptBy = acceptBy;
        c.deliverBy = deliverBy;
        c.reviewWindow = reviewWindow;
        c.status = Status.Created;
        emit CampaignCreated(id, msg.sender, creator, amount, acceptBy, deliverBy, reviewWindow, brief);
    }

    function _pay(uint256 id, Campaign storage c, bool auto_) internal {
        c.status = Status.Paid;
        c.paidAt = uint64(block.timestamp);
        Stats storage s = _stats[c.creator];
        s.completed += 1;
        s.earned += c.amount;
        emit PaidPromotion(id, c.sponsor, c.creator, c.amount, c.postHash, c.paidAt, auto_);
        qusdc.safeTransfer(c.creator, c.amount);
    }

    function _refund(uint256 id, Campaign storage c) internal {
        c.status = Status.Refunded;
        emit Refunded(id, c.sponsor, c.amount);
        qusdc.safeTransfer(c.sponsor, c.amount);
    }

    /// @dev 10..300 bytes, must start with "https://", printable ASCII, no spaces.
    function _checkUrl(bytes calldata u) internal pure {
        if (u.length < 10 || u.length > MAX_URL) revert BadUrl();
        if (
            u[0] != "h" || u[1] != "t" || u[2] != "t" || u[3] != "p" || u[4] != "s" || u[5] != ":" || u[6] != "/"
                || u[7] != "/"
        ) revert BadUrl();
        for (uint256 i = 8; i < u.length; i++) {
            bytes1 ch = u[i];
            if (ch <= 0x20 || ch >= 0x7f) revert BadUrl();
        }
    }
}
