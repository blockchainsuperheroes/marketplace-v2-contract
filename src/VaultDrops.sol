// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PentagonVaultDrops
 * @notice "Vault Drops" — PC reward redemption. Project-only auctions on Pentagon Chain where
 *         users bid earned PC; the prize is an NFT the project treasury holds on ANOTHER chain
 *         (e.g. Ethereum). Bonvoy-points model: the auction is fully trustless on this chain;
 *         prize delivery is a first-party fulfillment with an on-chain receipt + refund failsafe.
 *
 * @dev Reuses the tested PentagonAuctionHouse bid core (native-PC escrow, min increment,
 *      instant griefing-safe outbid refunds, 10-min soft-close). Deliberately holds NO NFTs —
 *      the prize is a reference. Key safety ordering: the winning bid stays ESCROWED at
 *      settlement and is only split burn/treasury on markFulfilled(); if the project fails to
 *      deliver within fulfillWindow, the winner reclaims a full refund.
 *
 *      ⚠ UNAUDITED. forge test + audit before deployment. Holds bidder funds.
 */
contract PentagonVaultDrops is Ownable, ReentrancyGuard {
    struct Drop {
        // prize reference (informational — the prize lives on another chain, in the treasury)
        uint64 prizeChainId;
        address prizeContract;
        uint256 prizeTokenId;
        // auction state (native PC)
        uint64 startTime;
        uint64 endTime;
        uint256 startPrice;
        uint256 highestBid;
        address highestBidder;
        uint64 settledAt; // 0 = not settled
        bool fulfilled;
        bool reclaimed;
    }

    uint256 public constant MIN_INCREMENT = 0.01 ether;
    uint64 public constant SOFT_CLOSE_WINDOW = 10 minutes;
    uint64 public constant SOFT_CLOSE_EXTENSION = 10 minutes;
    uint64 public constant MAX_DURATION = 30 days;
    uint256 public constant BPS = 10000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public dropCounter;
    mapping(uint256 => Drop) public drops;
    mapping(address => uint256) public pendingReturns; // griefing-safe native refund fallback

    // Winning-bid split, applied on fulfillment (owner-tunable).
    uint256 public burnBps = 5000; // 50% burned — the PC sink
    address public treasury; // remainder
    uint64 public fulfillWindow = 7 days; // reclaim failsafe after this

    event DropCreated(uint256 indexed dropId, uint64 prizeChainId, address prizeContract, uint256 prizeTokenId, uint256 startPrice, uint64 startTime, uint64 endTime);
    event BidPlaced(uint256 indexed dropId, address indexed bidder, uint256 amount, uint256 timestamp);
    event BidIncreased(uint256 indexed dropId, address indexed bidder, uint256 newAmount);
    event DropExtended(uint256 indexed dropId, uint64 newEndTime);
    event DropSettled(uint256 indexed dropId, address indexed winner, uint256 amount);
    event DropFulfilled(uint256 indexed dropId, address indexed winner, bytes32 prizeTxHash, uint256 burned, uint256 toTreasury);
    event BidReclaimed(uint256 indexed dropId, address indexed winner, uint256 amount);
    event DropCancelled(uint256 indexed dropId);
    event ConfigUpdated(uint256 burnBps, address treasury, uint64 fulfillWindow);
    event PendingReturnWithdrawn(address indexed account, uint256 amount);

    constructor() Ownable(msg.sender) {
        treasury = msg.sender;
    }

    // ─── Create (project-only) ──────────────────────────────────
    function createDrop(
        uint64 prizeChainId,
        address prizeContract,
        uint256 prizeTokenId,
        uint256 startPrice,
        uint64 duration,
        uint64 startTime
    ) external onlyOwner returns (uint256 dropId) {
        require(startPrice >= MIN_INCREMENT, "Start price too low");
        require(duration > 0 && duration <= MAX_DURATION, "Bad duration");
        uint64 start = startTime == 0 ? uint64(block.timestamp) : startTime;
        require(start >= block.timestamp, "Start in past");

        dropId = ++dropCounter;
        drops[dropId] = Drop({
            prizeChainId: prizeChainId,
            prizeContract: prizeContract,
            prizeTokenId: prizeTokenId,
            startTime: start,
            endTime: start + duration,
            startPrice: startPrice,
            highestBid: 0,
            highestBidder: address(0),
            settledAt: 0,
            fulfilled: false,
            reclaimed: false
        });
        emit DropCreated(dropId, prizeChainId, prizeContract, prizeTokenId, startPrice, start, start + duration);
    }

    // ─── Bid (native PC) ────────────────────────────────────────
    function bid(uint256 dropId) external payable nonReentrant {
        Drop storage d = drops[dropId];
        require(d.endTime != 0, "No drop");
        require(d.settledAt == 0, "Settled");
        require(block.timestamp >= d.startTime, "Not started");
        require(block.timestamp < d.endTime, "Ended");

        uint256 minBid = d.highestBid == 0 ? d.startPrice : d.highestBid + MIN_INCREMENT;
        require(msg.value >= minBid, "Bid too low");

        address prev = d.highestBidder;
        uint256 prevBid = d.highestBid;
        d.highestBid = msg.value;
        d.highestBidder = msg.sender;

        if (prev != address(0)) _refund(prev, prevBid);
        _maybeExtend(dropId, d);
        emit BidPlaced(dropId, msg.sender, msg.value, block.timestamp);
    }

    function increaseBid(uint256 dropId) external payable nonReentrant {
        Drop storage d = drops[dropId];
        require(d.highestBidder == msg.sender, "Not highest bidder");
        require(d.settledAt == 0, "Settled");
        require(block.timestamp < d.endTime, "Ended");
        require(msg.value >= MIN_INCREMENT, "Increment too small");
        d.highestBid += msg.value;
        _maybeExtend(dropId, d);
        emit BidIncreased(dropId, msg.sender, d.highestBid);
    }

    // ─── Settle (permissionless) ────────────────────────────────
    /// @notice Records the winner. Winning PC stays escrowed until fulfillment (or reclaim).
    function settleDrop(uint256 dropId) external nonReentrant {
        Drop storage d = drops[dropId];
        require(d.endTime != 0, "No drop");
        require(d.settledAt == 0, "Settled");
        require(block.timestamp >= d.endTime, "Not ended");
        d.settledAt = uint64(block.timestamp);
        emit DropSettled(dropId, d.highestBidder, d.highestBid);
    }

    // ─── Fulfill (project delivers prize on the other chain) ───
    /// @notice After delivering the prize NFT to the winner on the prize chain, the owner posts
    ///         the delivery tx hash. Only then is the winning bid split burn/treasury.
    function markFulfilled(uint256 dropId, bytes32 prizeTxHash) external onlyOwner nonReentrant {
        Drop storage d = drops[dropId];
        require(d.settledAt != 0, "Not settled");
        require(d.highestBidder != address(0), "No winner");
        require(!d.fulfilled, "Already fulfilled");
        require(!d.reclaimed, "Reclaimed");
        d.fulfilled = true;

        uint256 amount = d.highestBid;
        uint256 burned = (amount * burnBps) / BPS;
        uint256 toTreasury = amount - burned;
        if (burned > 0) {
            (bool okB, ) = payable(BURN_ADDRESS).call{value: burned}("");
            require(okB, "Burn failed");
        }
        if (toTreasury > 0) {
            (bool okT, ) = payable(treasury).call{value: toTreasury}("");
            require(okT, "Treasury transfer failed");
        }
        emit DropFulfilled(dropId, d.highestBidder, prizeTxHash, burned, toTreasury);
    }

    // ─── Failsafe: full refund if the project doesn't deliver ──
    function reclaimBid(uint256 dropId) external nonReentrant {
        Drop storage d = drops[dropId];
        require(d.settledAt != 0, "Not settled");
        require(msg.sender == d.highestBidder, "Not winner");
        require(!d.fulfilled, "Fulfilled");
        require(!d.reclaimed, "Already reclaimed");
        require(block.timestamp >= uint256(d.settledAt) + fulfillWindow, "Fulfill window open");
        d.reclaimed = true;
        uint256 amount = d.highestBid;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Refund failed");
        emit BidReclaimed(dropId, msg.sender, amount);
    }

    // ─── Cancel (owner, only while no bids) ─────────────────────
    function cancelDrop(uint256 dropId) external onlyOwner {
        Drop storage d = drops[dropId];
        require(d.endTime != 0 && d.settledAt == 0, "Invalid drop");
        require(d.highestBidder == address(0), "Has bids");
        d.settledAt = uint64(block.timestamp);
        emit DropCancelled(dropId);
    }

    // ─── Config ─────────────────────────────────────────────────
    function setConfig(uint256 _burnBps, address _treasury, uint64 _fulfillWindow) external onlyOwner {
        require(_burnBps <= BPS, "burnBps > 100%");
        require(_treasury != address(0), "Zero treasury");
        require(_fulfillWindow >= 1 days && _fulfillWindow <= 90 days, "Bad window");
        burnBps = _burnBps;
        treasury = _treasury;
        fulfillWindow = _fulfillWindow;
        emit ConfigUpdated(_burnBps, _treasury, _fulfillWindow);
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

    // ─── Views ──────────────────────────────────────────────────
    function minNextBid(uint256 dropId) external view returns (uint256) {
        Drop storage d = drops[dropId];
        return d.highestBid == 0 ? d.startPrice : d.highestBid + MIN_INCREMENT;
    }

    // ─── Internal ───────────────────────────────────────────────
    function _maybeExtend(uint256 dropId, Drop storage d) internal {
        if (d.endTime - block.timestamp <= SOFT_CLOSE_WINDOW) {
            d.endTime = uint64(block.timestamp) + SOFT_CLOSE_EXTENSION;
            emit DropExtended(dropId, d.endTime);
        }
    }

    /// @dev Never reverts the caller: failed native sends escrow to pendingReturns so a
    ///      malicious outbid bidder cannot block new bids.
    function _refund(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) pendingReturns[to] += amount;
    }

    receive() external payable {}
}
