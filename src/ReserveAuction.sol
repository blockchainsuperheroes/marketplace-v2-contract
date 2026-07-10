// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PentagonReserveAuction
 * @notice Reserve auctions (v2-dev Feature 4): Live-auction mechanics plus a HIDDEN reserve.
 *         The reserve is committed at creation as keccak256(abi.encodePacked(reservePrice, salt))
 *         — provably fixed upfront, unreadable on-chain. The seller reveals (price, salt) any
 *         time before settlement; at settlement the sale only executes if the reserve was
 *         revealed AND the highest bid meets it. Otherwise: NFT back to seller, bidder refunded.
 *
 * @dev Native-PC bids. Same tested core as PentagonAuctionHouse: escrow, 0.01 min increment,
 *      instant griefing-safe outbid refunds, 10-min soft close, permissionless settle, and the
 *      fee rebate (default 40% winner / 40% seller, platform keeps the rest).
 *      ⚠ UNAUDITED. forge test + audit before deployment.
 */
contract PentagonReserveAuction is Ownable, ReentrancyGuard, IERC721Receiver {
    struct Auction {
        address seller;
        address collection;
        uint256 tokenId;
        uint64 startTime;
        uint64 endTime;
        uint256 startPrice;
        uint256 highestBid;
        address highestBidder;
        bytes32 reserveHash;
        uint256 reserve; // set on reveal
        bool revealed;
        bool settled;
    }

    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MIN_INCREMENT = 0.01 ether;
    uint64 public constant SOFT_CLOSE_WINDOW = 10 minutes;
    uint64 public constant SOFT_CLOSE_EXTENSION = 10 minutes;
    uint64 public constant MAX_DURATION = 30 days;

    uint256 public auctionCounter;
    mapping(uint256 => Auction) public auctions;
    mapping(address => uint256) public marketplaceFees; // bps per collection
    mapping(address => bool) public whitelistedCollections;
    mapping(address => uint256) public pendingReturns;

    uint256 public buyerRebateBps = 4000; // share of FEE to the winner
    uint256 public sellerRebateBps = 4000; // share of FEE to the seller

    event ReserveAuctionCreated(uint256 indexed auctionId, address indexed collection, uint256 indexed tokenId, address seller, uint256 startPrice, bytes32 reserveHash, uint64 startTime, uint64 endTime);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount, bool reserveMet, uint256 timestamp);
    event AuctionExtended(uint256 indexed auctionId, uint64 newEndTime);
    event ReserveRevealed(uint256 indexed auctionId, uint256 reservePrice, bool met);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 amount); // winner=0 → no sale
    event AuctionCancelled(uint256 indexed auctionId);
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
    /// @param reserveHash keccak256(abi.encodePacked(uint256 reservePrice, bytes32 salt))
    function createReserveAuction(
        address collection,
        uint256 tokenId,
        uint256 startPrice,
        bytes32 reserveHash,
        uint64 duration,
        uint64 startTime
    ) external onlyWhitelisted(collection) returns (uint256 auctionId) {
        require(startPrice >= MIN_INCREMENT, "Start price too low");
        require(reserveHash != bytes32(0), "No reserve hash");
        require(duration > 0 && duration <= MAX_DURATION, "Bad duration");
        uint64 start = startTime == 0 ? uint64(block.timestamp) : startTime;
        require(start >= block.timestamp, "Start in past");

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);

        auctionId = ++auctionCounter;
        Auction storage a = auctions[auctionId];
        a.seller = msg.sender;
        a.collection = collection;
        a.tokenId = tokenId;
        a.startTime = start;
        a.endTime = start + duration;
        a.startPrice = startPrice;
        a.reserveHash = reserveHash;
        emit ReserveAuctionCreated(auctionId, collection, tokenId, msg.sender, startPrice, reserveHash, start, start + duration);
    }

    // ─── Bid (native PC) ────────────────────────────────────────
    function bid(uint256 auctionId) external payable nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0), "No auction");
        require(!a.settled, "Settled");
        require(block.timestamp >= a.startTime, "Not started");
        require(block.timestamp < a.endTime, "Ended");

        uint256 minBid = a.highestBid == 0 ? a.startPrice : a.highestBid + MIN_INCREMENT;
        require(msg.value >= minBid, "Bid too low");

        address prev = a.highestBidder;
        uint256 prevBid = a.highestBid;
        a.highestBid = msg.value;
        a.highestBidder = msg.sender;

        if (prev != address(0)) _refund(prev, prevBid);
        if (a.endTime - block.timestamp <= SOFT_CLOSE_WINDOW) {
            a.endTime = uint64(block.timestamp) + SOFT_CLOSE_EXTENSION;
            emit AuctionExtended(auctionId, a.endTime);
        }
        emit BidPlaced(auctionId, msg.sender, msg.value, a.revealed && msg.value >= a.reserve, block.timestamp);
    }

    // ─── Reveal (seller) ────────────────────────────────────────
    /// @notice Seller publishes the committed reserve. Must happen before settlement for the
    ///         sale to execute. Revealing early is fine — bidding continues normally.
    function revealReserve(uint256 auctionId, uint256 reservePrice, bytes32 salt) external {
        Auction storage a = auctions[auctionId];
        require(msg.sender == a.seller, "Not seller");
        require(!a.settled, "Settled");
        require(!a.revealed, "Already revealed");
        require(keccak256(abi.encodePacked(reservePrice, salt)) == a.reserveHash, "Bad reveal");
        a.reserve = reservePrice;
        a.revealed = true;
        emit ReserveRevealed(auctionId, reservePrice, a.highestBid >= reservePrice);
    }

    // ─── Settle (permissionless) ────────────────────────────────
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0), "No auction");
        require(!a.settled, "Settled");
        require(block.timestamp >= a.endTime, "Not ended");
        a.settled = true;

        bool sold = a.revealed && a.highestBidder != address(0) && a.highestBid >= a.reserve;
        if (!sold) {
            // Reserve unmet or never revealed: NFT home, bidder made whole.
            IERC721(a.collection).safeTransferFrom(address(this), a.seller, a.tokenId);
            if (a.highestBidder != address(0)) _refund(a.highestBidder, a.highestBid);
            emit AuctionSettled(auctionId, address(0), 0);
            return;
        }

        uint256 price = a.highestBid;
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
        if (winnerRebate > 0) _refund(a.highestBidder, winnerRebate);
        emit AuctionSettled(auctionId, a.highestBidder, price);
    }

    // ─── Cancel ─────────────────────────────────────────────────
    function cancelAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller == msg.sender, "Not seller");
        require(!a.settled, "Settled");
        require(a.highestBidder == address(0), "Has bids");
        a.settled = true;
        IERC721(a.collection).safeTransferFrom(address(this), a.seller, a.tokenId);
        emit AuctionCancelled(auctionId);
    }

    function adminCancelAuction(uint256 auctionId) external onlyOwner nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0) && !a.settled, "Invalid auction");
        a.settled = true;
        if (a.highestBidder != address(0)) _refund(a.highestBidder, a.highestBid);
        IERC721(a.collection).safeTransferFrom(address(this), a.seller, a.tokenId);
        emit AuctionCancelled(auctionId);
    }

    // ─── Admin / views / plumbing ───────────────────────────────
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

    function minNextBid(uint256 auctionId) external view returns (uint256) {
        Auction storage a = auctions[auctionId];
        return a.highestBid == 0 ? a.startPrice : a.highestBid + MIN_INCREMENT;
    }

    function _payout(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Native transfer failed");
    }

    /// @dev Never reverts the caller; failed sends escrow to pendingReturns.
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
