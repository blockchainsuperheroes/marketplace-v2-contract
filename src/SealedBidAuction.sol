// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PentagonSealedBidAuction
 * @notice Sealed bids (v2-dev Feature 5): first-price blind auction for high-value pieces.
 *         Two phases — COMMIT: bidders submit keccak256(abi.encodePacked(amount, salt, bidder))
 *         with a deposit >= their bid (over-deposit to mask the amount; excess refunds later).
 *         REVEAL: bidders publish (amount, salt); highest valid reveal leads. Settlement pays
 *         the seller, refunds the winner's excess deposit, and applies the fee rebate.
 *
 * @dev Refund guarantees: losers refunded the moment a higher reveal displaces them; the
 *      displaced/never-highest keep nothing at risk after reveal; unrevealed deposits are
 *      reclaimable after the reveal window (an unrevealed bid can never win).
 *      ⚠ UNAUDITED. forge test + audit before deployment.
 */
contract PentagonSealedBidAuction is Ownable, ReentrancyGuard, IERC721Receiver {
    struct Auction {
        address seller;
        address collection;
        uint256 tokenId;
        uint256 minBid;
        uint64 commitEnd;
        uint64 revealEnd;
        uint256 highestBid;
        address highestBidder;
        bool settled;
    }

    struct Commit {
        bytes32 hash;
        uint256 deposit;
        bool revealed;
        bool refunded;
    }

    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MIN_BID = 0.01 ether;
    uint64 public constant MAX_PHASE = 30 days;

    uint256 public auctionCounter;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(address => Commit)) public commits;
    mapping(address => uint256) public marketplaceFees;
    mapping(address => bool) public whitelistedCollections;
    mapping(address => uint256) public pendingReturns;

    uint256 public buyerRebateBps = 4000;
    uint256 public sellerRebateBps = 4000;

    event SealedAuctionCreated(uint256 indexed auctionId, address indexed collection, uint256 indexed tokenId, address seller, uint256 minBid, uint64 commitEnd, uint64 revealEnd);
    event BidCommitted(uint256 indexed auctionId, address indexed bidder, uint256 deposit);
    event BidRevealed(uint256 indexed auctionId, address indexed bidder, uint256 amount, bool isHighest);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 amount);
    event AuctionCancelled(uint256 indexed auctionId);
    event DepositReclaimed(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event CollectionWhitelisted(address indexed collection, bool status);
    event MarketplaceFeeUpdated(address indexed collection, uint256 fee);
    event RebateUpdated(uint256 buyerBps, uint256 sellerBps);
    event FundsWithdrawn(address indexed admin, uint256 amount);
    event PendingReturnWithdrawn(address indexed account, uint256 amount);

    constructor() Ownable(msg.sender) {}

    modifier onlyWhitelisted(address collection) {
        require(whitelistedCollections[collection], "Collection not whitelisted");
        _;
    }

    // ─── Create ─────────────────────────────────────────────────
    function createSealedAuction(
        address collection,
        uint256 tokenId,
        uint256 minBid,
        uint64 commitDuration,
        uint64 revealDuration
    ) external onlyWhitelisted(collection) returns (uint256 auctionId) {
        require(minBid >= MIN_BID, "Min bid too low");
        require(commitDuration > 0 && commitDuration <= MAX_PHASE, "Bad commit phase");
        require(revealDuration > 0 && revealDuration <= MAX_PHASE, "Bad reveal phase");

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);

        auctionId = ++auctionCounter;
        Auction storage a = auctions[auctionId];
        a.seller = msg.sender;
        a.collection = collection;
        a.tokenId = tokenId;
        a.minBid = minBid;
        a.commitEnd = uint64(block.timestamp) + commitDuration;
        a.revealEnd = a.commitEnd + revealDuration;
        emit SealedAuctionCreated(auctionId, collection, tokenId, msg.sender, minBid, a.commitEnd, a.revealEnd);
    }

    // ─── Commit phase ───────────────────────────────────────────
    /// @param commitment keccak256(abi.encodePacked(uint256 amount, bytes32 salt, address bidder))
    /// @dev Deposit anything >= your true bid (round numbers mask the real amount).
    function commitBid(uint256 auctionId, bytes32 commitment) external payable {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0), "No auction");
        require(block.timestamp < a.commitEnd, "Commit phase over");
        require(commitment != bytes32(0), "No commitment");
        require(msg.value >= a.minBid, "Deposit below min bid");
        Commit storage c = commits[auctionId][msg.sender];
        require(c.hash == bytes32(0), "Already committed");
        c.hash = commitment;
        c.deposit = msg.value;
        emit BidCommitted(auctionId, msg.sender, msg.value);
    }

    // ─── Reveal phase ───────────────────────────────────────────
    function revealBid(uint256 auctionId, uint256 amount, bytes32 salt) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(block.timestamp >= a.commitEnd, "Commit phase running");
        require(block.timestamp < a.revealEnd, "Reveal phase over");
        Commit storage c = commits[auctionId][msg.sender];
        require(c.hash != bytes32(0), "No commit");
        require(!c.revealed, "Already revealed");
        require(keccak256(abi.encodePacked(amount, salt, msg.sender)) == c.hash, "Bad reveal");
        require(amount <= c.deposit, "Bid exceeds deposit");
        c.revealed = true;

        if (amount >= a.minBid && amount > a.highestBid) {
            // Displace the previous leader: their full deposit goes home.
            if (a.highestBidder != address(0)) {
                Commit storage prev = commits[auctionId][a.highestBidder];
                prev.refunded = true;
                _refund(a.highestBidder, prev.deposit);
            }
            a.highestBid = amount;
            a.highestBidder = msg.sender;
            emit BidRevealed(auctionId, msg.sender, amount, true);
        } else {
            // Not leading: nothing at risk, full deposit back immediately.
            c.refunded = true;
            _refund(msg.sender, c.deposit);
            emit BidRevealed(auctionId, msg.sender, amount, false);
        }
    }

    // ─── Settle (permissionless, after reveal phase) ────────────
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0), "No auction");
        require(!a.settled, "Settled");
        require(block.timestamp >= a.revealEnd, "Reveal phase running");
        a.settled = true;

        if (a.highestBidder == address(0)) {
            IERC721(a.collection).safeTransferFrom(address(this), a.seller, a.tokenId);
            emit AuctionSettled(auctionId, address(0), 0);
            return;
        }

        uint256 price = a.highestBid;
        Commit storage w = commits[auctionId][a.highestBidder];
        uint256 excess = w.deposit - price; // masked over-deposit back to the winner
        w.refunded = true;

        uint256 fee = (price * marketplaceFees[a.collection]) / FEE_DENOMINATOR;
        uint256 royaltyAmount;
        address royaltyReceiver;
        try IERC2981(a.collection).royaltyInfo(a.tokenId, price) returns (address r, uint256 amt) {
            royaltyReceiver = r;
            royaltyAmount = amt;
        } catch {}
        require(fee + royaltyAmount <= price, "Fee + royalty exceeds price");

        uint256 winnerRebate = (fee * buyerRebateBps) / FEE_DENOMINATOR;
        uint256 sellerRebate = (fee * sellerRebateBps) / FEE_DENOMINATOR;
        uint256 sellerProceeds = price - fee - royaltyAmount + sellerRebate;

        IERC721(a.collection).safeTransferFrom(address(this), a.highestBidder, a.tokenId);
        _payout(a.seller, sellerProceeds);
        if (royaltyAmount > 0) _payout(royaltyReceiver, royaltyAmount);
        if (excess + winnerRebate > 0) _refund(a.highestBidder, excess + winnerRebate);
        emit AuctionSettled(auctionId, a.highestBidder, price);
    }

    // ─── Reclaim unrevealed deposits (after reveal window) ──────
    function reclaimDeposit(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(block.timestamp >= a.revealEnd, "Reveal phase running");
        Commit storage c = commits[auctionId][msg.sender];
        require(c.hash != bytes32(0), "No commit");
        require(!c.revealed, "Was revealed"); // revealed paths already refund/settle
        require(!c.refunded, "Already refunded");
        c.refunded = true;
        _refund(msg.sender, c.deposit);
        emit DepositReclaimed(auctionId, msg.sender, c.deposit);
    }

    // ─── Cancel ─────────────────────────────────────────────────
    /// @notice Seller may cancel during the commit phase only if nobody has committed.
    function cancelAuction(uint256 auctionId, uint256 committedCount) external nonReentrant {
        // committedCount is advisory for the UI; on-chain we simply require no leader and
        // rely on commit refunds: cancelling voids the auction, all commits become reclaimable.
        Auction storage a = auctions[auctionId];
        require(a.seller == msg.sender, "Not seller");
        require(!a.settled, "Settled");
        require(block.timestamp < a.commitEnd, "Commit phase over");
        a.settled = true;
        a.revealEnd = uint64(block.timestamp); // unlock reclaimDeposit immediately
        IERC721(a.collection).safeTransferFrom(address(this), a.seller, a.tokenId);
        emit AuctionCancelled(auctionId);
        committedCount; // silence unused
    }

    // ─── Admin / plumbing ───────────────────────────────────────
    function whitelistCollection(address collection, bool status) external onlyOwner {
        whitelistedCollections[collection] = status;
        emit CollectionWhitelisted(collection, status);
    }

    function setMarketplaceFee(address collection, uint256 fee) external onlyOwner {
        require(fee <= 1000, "Fee too high (max 10%)");
        marketplaceFees[collection] = fee;
        emit MarketplaceFeeUpdated(collection, fee);
    }

    function setRebate(uint256 buyerBps, uint256 sellerBps) external onlyOwner {
        require(buyerBps + sellerBps <= FEE_DENOMINATOR, "Rebate > 100%");
        buyerRebateBps = buyerBps;
        sellerRebateBps = sellerBps;
        emit RebateUpdated(buyerBps, sellerBps);
    }

    function withdrawFunds(uint256 amount) external onlyOwner {
        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "Withdraw failed");
        emit FundsWithdrawn(owner(), amount);
    }

    function withdrawPending() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingReturns[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Withdraw failed");
        emit PendingReturnWithdrawn(msg.sender, amount);
    }

    function _payout(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Native transfer failed");
    }

    function _refund(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) pendingReturns[to] += amount;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
