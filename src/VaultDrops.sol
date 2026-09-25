// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PentagonVaultDrops
 * @notice "Vault Drops" — PC reward redemption. Project-only auctions on Pentagon Chain where
 *         users bid earned PC; the prize is an NFT the project treasury holds on ANOTHER chain
 *         (e.g. Ethereum). Bonvoy-points model: the auction is fully trustless on this chain;
 *         prize delivery is a first-party fulfillment with an on-chain receipt + refund failsafe.
 *         Points Store (2026-09-25): claims are Points-only (fixed redeemPrice, no bidding) and
 *         delivered-claim PC stays in the contract as owner-withdrawable proceeds (no burn).
 *
 * @dev Reuses the tested PentagonAuctionHouse bid core (native-PC escrow, min increment,
 *      instant griefing-safe outbid refunds, 10-min soft-close). Deliberately holds NO NFTs —
 *      the prize is a reference. Key safety ordering: the claim stays ESCROWED at settlement and
 *      only becomes owner proceeds on markFulfilled(); if the project fails to deliver within
 *      fulfillWindow, the claimer reclaims the full amount.
 *
 *      ⚠ UNAUDITED. forge test + audit before deployment. Holds bidder funds.
 */
/// @dev UPGRADEABLE (nftprof 2026-09-25): deployed behind a TransparentUpgradeableProxy whose
///      ProxyAdmin is owned by the treasury hardware wallet — only it can upgrade (fixes/tuning).
///      Rules for every future version: never reorder/remove state vars; only append, consuming
///      `__gap`. ReentrancyGuard (OZ 5) keeps its flag in a namespaced slot, so it's proxy-safe.
contract PentagonVaultDrops is Initializable, ReentrancyGuard {
    struct Drop {
        // prize reference (informational — the prize lives on another chain, in the treasury)
        uint64 prizeChainId;
        address prizeContract;
        uint256 prizeTokenId;
        // auction state (native PC)
        uint64 startTime;
        uint64 endTime;
        uint256 startPrice;
        uint256 redeemPrice; // 0 = auction only; >0 = "redeem now": first to pay this wins instantly
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

    uint256 public dropCounter;
    mapping(uint256 => Drop) public drops;
    mapping(address => uint256) public pendingReturns; // griefing-safe native refund fallback

    uint64 public fulfillWindow; // reclaim failsafe after this (7 days, set in initialize)
    // PC from DELIVERED claims (nftprof 2026-09-25: no burn, no auto-transfer — it stays in the
    // contract and the owner may withdraw it later). Open claims are never part of this: a claim's
    // PC moves here only when its NFT is delivered, so withdrawals can't touch anyone's escrow.
    uint256 public proceeds;

    // Owner (two-step transfer). Plain storage instead of OZ Ownable so it can be set by
    // initialize() behind the proxy.
    address public owner;
    address public pendingOwner;

    // Reserved for future versions' state (append-only upgrades).
    uint256[40] private __gap;

    event DropCreated(uint256 indexed dropId, uint64 prizeChainId, address prizeContract, uint256 prizeTokenId, uint256 startPrice, uint64 startTime, uint64 endTime, uint256 redeemPrice);
    event DropRedeemed(uint256 indexed dropId, address indexed redeemer, uint256 amount);
    // Settlement-ledger events (payment.pentagon.games event_tracker indexes these): one row per
    // claim, keyed by an idempotency ref, with its delivery or reversal. PC always moves from/to the
    // claimer's OWN wallet (custodial AA spend rail) — never pooled across users.
    event Claimed(uint256 indexed dropId, address indexed claimer, uint256 amount, bytes32 ref);
    event Delivered(uint256 indexed dropId, uint256 amount);
    event Reclaimed(uint256 indexed dropId, address indexed claimer, uint256 amount);
    event BidPlaced(uint256 indexed dropId, address indexed bidder, uint256 amount, uint256 timestamp);
    event BidIncreased(uint256 indexed dropId, address indexed bidder, uint256 newAmount);
    event DropExtended(uint256 indexed dropId, uint64 newEndTime);
    event DropSettled(uint256 indexed dropId, address indexed winner, uint256 amount);
    event DropFulfilled(uint256 indexed dropId, address indexed winner, bytes32 prizeTxHash, uint256 amount);
    event BidReclaimed(uint256 indexed dropId, address indexed winner, uint256 amount);
    event DropCancelled(uint256 indexed dropId);
    event ConfigUpdated(uint64 fulfillWindow);
    event ProceedsWithdrawn(address indexed to, uint256 amount);
    event PendingReturnWithdrawn(address indexed account, uint256 amount);

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // the bare implementation can never be initialized or used
    }

    function initialize(address owner_) external initializer {
        require(owner_ != address(0), "Zero owner");
        owner = owner_;
        fulfillWindow = 7 days;
        emit OwnershipTransferred(address(0), owner_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ─── Create (project-only) ──────────────────────────────────
    function createDrop(
        uint64 prizeChainId,
        address prizeContract,
        uint256 prizeTokenId,
        uint256 startPrice,
        uint64 duration,
        uint64 startTime,
        uint256 redeemPrice
    ) external onlyOwner returns (uint256 dropId) {
        require(startPrice >= MIN_INCREMENT, "Start price too low");
        require(duration > 0 && duration <= MAX_DURATION, "Bad duration");
        require(redeemPrice == 0 || redeemPrice >= startPrice, "Redeem below start");
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
            redeemPrice: redeemPrice,
            highestBid: 0,
            highestBidder: address(0),
            settledAt: 0,
            fulfilled: false,
            reclaimed: false
        });
        emit DropCreated(dropId, prizeChainId, prizeContract, prizeTokenId, startPrice, start, start + duration, redeemPrice);
    }

    // ─── Redeem now (fixed price, first come first served) ─────
    /// @notice Straight redemption: pay `redeemPrice` and the drop settles to you instantly.
    ///         Any standing highest bidder is refunded. Same escrow/fulfill/reclaim path after.
    function redeem(uint256 dropId) external payable nonReentrant {
        Drop storage d = drops[dropId];
        require(d.endTime != 0, "No drop");
        require(d.redeemPrice != 0, "Not redeemable");
        require(d.settledAt == 0, "Settled");
        require(block.timestamp >= d.startTime, "Not started");
        require(block.timestamp < d.endTime, "Ended");
        require(msg.value == d.redeemPrice, "Pay exact redeem price");

        address prev = d.highestBidder;
        uint256 prevBid = d.highestBid;
        d.highestBid = msg.value;
        d.highestBidder = msg.sender;
        d.endTime = uint64(block.timestamp);
        d.settledAt = uint64(block.timestamp);

        if (prev != address(0)) _refund(prev, prevBid);
        emit DropRedeemed(dropId, msg.sender, msg.value);
        emit DropSettled(dropId, msg.sender, msg.value);
        emit Claimed(dropId, msg.sender, msg.value, keccak256(abi.encode(dropId, msg.sender)));
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
        // Points-claim drops (redeemPrice set) are NEVER auctions: claim at the fixed price only.
        // PC bidding lives in the Auction House; the two are deliberately not mixed (nftprof).
        require(d.redeemPrice == 0, "Points claim only");

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
        require(d.redeemPrice == 0, "Points claim only");
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
    ///         the delivery tx hash. Only then does the claim's PC become owner proceeds.
    function markFulfilled(uint256 dropId, bytes32 prizeTxHash) external onlyOwner nonReentrant {
        Drop storage d = drops[dropId];
        require(d.settledAt != 0, "Not settled");
        require(d.highestBidder != address(0), "No winner");
        require(!d.fulfilled, "Already fulfilled");
        require(!d.reclaimed, "Reclaimed");
        d.fulfilled = true;

        uint256 amount = d.highestBid;
        proceeds += amount; // stays in the contract; owner may withdraw later
        emit DropFulfilled(dropId, d.highestBidder, prizeTxHash, amount);
        emit Delivered(dropId, amount);
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
        emit Reclaimed(dropId, msg.sender, amount);
    }

    // ─── Escape hatch: wrong markFulfilled ──────────────────────
    /// @notice markFulfilled permanently blocks reclaimBid, so a mistaken mark (NFT never actually
    ///         delivered) would leave the claimer with neither. The owner makes the claimer whole with
    ///         exactly that claim's amount — from proceeds (send no value) or freshly funded (send the
    ///         exact amount, e.g. if proceeds were already withdrawn). `fulfilled` stays set.
    function ownerRefund(uint256 dropId) external payable onlyOwner nonReentrant {
        Drop storage d = drops[dropId];
        require(d.fulfilled, "Not fulfilled");
        require(!d.reclaimed, "Already reclaimed");
        uint256 amount = d.highestBid;
        if (msg.value == 0) {
            require(proceeds >= amount, "Insufficient proceeds");
            proceeds -= amount;
        } else {
            require(msg.value == amount, "Must fund exact bid");
        }
        d.reclaimed = true;
        (bool ok, ) = payable(d.highestBidder).call{value: amount}("");
        require(ok, "Refund failed");
        emit BidReclaimed(dropId, d.highestBidder, amount);
        emit Reclaimed(dropId, d.highestBidder, amount);
    }

    // ─── Owner proceeds (delivered claims only) ─────────────────
    function withdrawProceeds(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        require(amount > 0 && amount <= proceeds, "Bad amount");
        proceeds -= amount;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Withdraw failed");
        emit ProceedsWithdrawn(to, amount);
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
    function setConfig(uint64 _fulfillWindow) external onlyOwner {
        require(_fulfillWindow >= 1 days && _fulfillWindow <= 90 days, "Bad window");
        fulfillWindow = _fulfillWindow;
        emit ConfigUpdated(_fulfillWindow);
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
