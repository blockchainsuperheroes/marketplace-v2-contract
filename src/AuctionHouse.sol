// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PentagonAuctionHouse
 * @notice Live (English ascending) auctions for Pentagon Marketplace v1.3.
 * @dev Standalone sibling to PentagonMarketplaceV2. Implements "Feature 3: Live Auctions"
 *      from the marketplace-v2-contract v2-dev spec: scheduled start, soft-close anti-snipe,
 *      live bid log, increase-bid, immediate outbid refund, permissionless settlement.
 *      Reserve (Feature 4) and Sealed (Feature 5) auctions are intentionally NOT in this
 *      contract yet — they extend this once Live is shipped + audited.
 *
 *      Fee model mirrors PentagonMarketplaceV2: per-collection bps fee deducted from the
 *      winning bid on settlement and retained for owner withdrawal; ERC-2981 royalty honored.
 *      The 20:40:40 PC rebate is paid by a separate reward-distributor (out of scope here).
 *
 *      ⚠ UNAUDITED / NOT COMPILED IN-REPO YET. Run `forge build` + `forge test` and audit
 *      before any deployment. Handles escrowed NFTs and funds.
 */
contract PentagonAuctionHouse is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    // ─── Structs ────────────────────────────────────────────────
    struct Auction {
        address seller;
        address collection;
        uint256 tokenId;
        address paymentToken; // address(0) = native (PC/ETH); else ERC20 (wPC/WETH)
        uint64 startTime;
        uint64 endTime;
        uint256 startPrice;
        uint256 highestBid;
        address highestBidder;
        bool settled;
    }

    // ─── Constants ──────────────────────────────────────────────
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MIN_INCREMENT = 0.01 ether; // also enforced as min start price
    uint64 public constant SOFT_CLOSE_WINDOW = 10 minutes;
    uint64 public constant SOFT_CLOSE_EXTENSION = 10 minutes;
    uint64 public constant MAX_DURATION = 30 days;

    // ─── State ──────────────────────────────────────────────────
    uint256 public auctionCounter;
    mapping(uint256 => Auction) public auctions;
    mapping(address => uint256) public marketplaceFees; // bps, per collection
    mapping(address => bool) public whitelistedCollections;
    // griefing-safe fallback: if a native outbid refund fails, it is credited here to pull
    mapping(address => uint256) public pendingReturns;

    // ─── Events ─────────────────────────────────────────────────
    event AuctionCreated(uint256 indexed auctionId, address indexed collection, uint256 indexed tokenId, address seller, uint256 startPrice, uint64 startTime, uint64 endTime, address paymentToken);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount, uint256 timestamp);
    event BidIncreased(uint256 indexed auctionId, address indexed bidder, uint256 newAmount);
    event AuctionExtended(uint256 indexed auctionId, uint64 newEndTime);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 amount);
    event AuctionCancelled(uint256 indexed auctionId);
    event CollectionWhitelisted(address indexed collection, bool status);
    event MarketplaceFeeUpdated(address indexed collection, uint256 fee);
    event FundsWithdrawn(address indexed admin, address indexed token, uint256 amount);
    event PendingReturnWithdrawn(address indexed account, uint256 amount);

    // ─── Constructor ────────────────────────────────────────────
    constructor() Ownable(msg.sender) {}

    // ─── Modifiers ──────────────────────────────────────────────
    modifier onlyWhitelisted(address collection) {
        require(whitelistedCollections[collection], "Collection not whitelisted");
        _;
    }

    // ─── Create ─────────────────────────────────────────────────
    function createAuction(
        address collection,
        uint256 tokenId,
        uint256 startPrice,
        uint64 duration,
        uint64 startTime,
        address paymentToken
    ) external onlyWhitelisted(collection) returns (uint256 auctionId) {
        require(startPrice >= MIN_INCREMENT, "Start price too low");
        require(duration > 0 && duration <= MAX_DURATION, "Bad duration");

        uint64 start = startTime == 0 ? uint64(block.timestamp) : startTime;
        require(start >= block.timestamp, "Start in past");

        IERC721 nft = IERC721(collection);
        require(nft.ownerOf(tokenId) == msg.sender, "Not token owner");

        // Escrow the NFT into the auction house.
        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        auctionId = ++auctionCounter;
        auctions[auctionId] = Auction({
            seller: msg.sender,
            collection: collection,
            tokenId: tokenId,
            paymentToken: paymentToken,
            startTime: start,
            endTime: start + duration,
            startPrice: startPrice,
            highestBid: 0,
            highestBidder: address(0),
            settled: false
        });

        emit AuctionCreated(auctionId, collection, tokenId, msg.sender, startPrice, start, start + duration, paymentToken);
    }

    // ─── Bid ────────────────────────────────────────────────────
    /// @param amount used only for ERC20 auctions; native auctions read msg.value.
    function bid(uint256 auctionId, uint256 amount) external payable nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0), "No auction");
        require(!a.settled, "Settled");
        require(block.timestamp >= a.startTime, "Not started");
        require(block.timestamp < a.endTime, "Ended");

        uint256 bidAmount;
        if (a.paymentToken == address(0)) {
            bidAmount = msg.value;
        } else {
            require(msg.value == 0, "Native not accepted");
            bidAmount = amount;
        }

        uint256 minBid = a.highestBid == 0 ? a.startPrice : a.highestBid + MIN_INCREMENT;
        require(bidAmount >= minBid, "Bid too low");

        if (a.paymentToken != address(0)) {
            IERC20(a.paymentToken).safeTransferFrom(msg.sender, address(this), bidAmount);
        }

        address prevBidder = a.highestBidder;
        uint256 prevBid = a.highestBid;

        a.highestBid = bidAmount;
        a.highestBidder = msg.sender;

        // Immediate outbid refund (native: griefing-safe fallback to pendingReturns).
        if (prevBidder != address(0)) {
            _refund(a.paymentToken, prevBidder, prevBid);
        }

        _maybeExtend(auctionId, a);
        emit BidPlaced(auctionId, msg.sender, bidAmount, block.timestamp);
    }

    /// @notice Current highest bidder tops up without losing position.
    function increaseBid(uint256 auctionId, uint256 amount) external payable nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.highestBidder == msg.sender, "Not highest bidder");
        require(!a.settled, "Settled");
        require(block.timestamp < a.endTime, "Ended");

        uint256 added = a.paymentToken == address(0) ? msg.value : amount;
        require(added >= MIN_INCREMENT, "Increment too small");
        if (a.paymentToken != address(0)) {
            require(msg.value == 0, "Native not accepted");
            IERC20(a.paymentToken).safeTransferFrom(msg.sender, address(this), added);
        }

        a.highestBid += added;
        _maybeExtend(auctionId, a);
        emit BidIncreased(auctionId, msg.sender, a.highestBid);
    }

    // ─── Settle ─────────────────────────────────────────────────
    /// @notice Permissionless after endTime. Keeper cron should call it to auto-finalize.
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0), "No auction");
        require(!a.settled, "Settled");
        require(block.timestamp >= a.endTime, "Not ended");
        a.settled = true;

        // No bids → return NFT to seller.
        if (a.highestBidder == address(0)) {
            IERC721(a.collection).safeTransferFrom(address(this), a.seller, a.tokenId);
            emit AuctionSettled(auctionId, address(0), 0);
            return;
        }

        uint256 price = a.highestBid;
        uint256 fee = (price * marketplaceFees[a.collection]) / FEE_DENOMINATOR;

        uint256 royaltyAmount;
        address royaltyReceiver;
        try IERC2981(a.collection).royaltyInfo(a.tokenId, price) returns (address receiver, uint256 amt) {
            royaltyReceiver = receiver;
            royaltyAmount = amt;
        } catch {}

        require(fee + royaltyAmount <= price, "Fee + royalty exceeds price");
        uint256 sellerProceeds = price - fee - royaltyAmount;

        // NFT to winner; funds out; fee retained in contract for owner withdrawal.
        IERC721(a.collection).safeTransferFrom(address(this), a.highestBidder, a.tokenId);
        _payout(a.paymentToken, a.seller, sellerProceeds);
        if (royaltyAmount > 0) _payout(a.paymentToken, royaltyReceiver, royaltyAmount);

        emit AuctionSettled(auctionId, a.highestBidder, price);
    }

    // ─── Cancel ─────────────────────────────────────────────────
    /// @notice Seller may cancel only while there are no bids.
    function cancelAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller == msg.sender, "Not seller");
        require(!a.settled, "Settled");
        require(a.highestBidder == address(0), "Has bids");
        a.settled = true;
        IERC721(a.collection).safeTransferFrom(address(this), a.seller, a.tokenId);
        emit AuctionCancelled(auctionId);
    }

    /// @notice Owner safety hatch: refund highest bidder and return NFT to seller.
    function adminCancelAuction(uint256 auctionId) external onlyOwner nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0) && !a.settled, "Invalid auction");
        a.settled = true;
        if (a.highestBidder != address(0)) {
            _refund(a.paymentToken, a.highestBidder, a.highestBid);
        }
        IERC721(a.collection).safeTransferFrom(address(this), a.seller, a.tokenId);
        emit AuctionCancelled(auctionId);
    }

    // ─── Pull-payment fallback ──────────────────────────────────
    function withdrawPending() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingReturns[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Withdraw failed");
        emit PendingReturnWithdrawn(msg.sender, amount);
    }

    // ─── Admin ──────────────────────────────────────────────────
    function whitelistCollection(address collection, bool status) external onlyOwner {
        whitelistedCollections[collection] = status;
        emit CollectionWhitelisted(collection, status);
    }

    function setMarketplaceFee(address collection, uint256 fee) external onlyOwner {
        require(fee <= 1000, "Fee too high (max 10%)");
        marketplaceFees[collection] = fee;
        emit MarketplaceFeeUpdated(collection, fee);
    }

    function withdrawFunds(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool ok, ) = payable(owner()).call{value: amount}("");
            require(ok, "Native withdraw failed");
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
        emit FundsWithdrawn(owner(), token, amount);
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }

    // ─── Views ──────────────────────────────────────────────────
    function minNextBid(uint256 auctionId) external view returns (uint256) {
        Auction storage a = auctions[auctionId];
        return a.highestBid == 0 ? a.startPrice : a.highestBid + MIN_INCREMENT;
    }

    // ─── Internal ───────────────────────────────────────────────
    function _maybeExtend(uint256 auctionId, Auction storage a) internal {
        if (a.endTime - block.timestamp <= SOFT_CLOSE_WINDOW) {
            a.endTime = uint64(block.timestamp) + SOFT_CLOSE_EXTENSION;
            emit AuctionExtended(auctionId, a.endTime);
        }
    }

    function _payout(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "Native transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Like _payout but never reverts the caller for native: failed sends are escrowed
    ///      to pendingReturns so a malicious outbid bidder cannot block new bids.
    function _refund(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) pendingReturns[to] += amount;
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ─── ERC721 receiver (accept escrowed NFTs via safeTransferFrom) ───
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
