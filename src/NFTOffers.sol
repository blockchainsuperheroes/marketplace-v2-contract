// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PentagonNFTOffers
 * @notice Per-token (individual) offers — the buyer-initiated mirror of PentagonPrivateSale.
 *         A buyer makes an offer on ONE specific tokenId and ESCROWS the funds up front; the
 *         current owner accepts, or the buyer cancels / reclaims after expiry. Because funds are
 *         escrowed in the contract (not merely an ERC20 allowance, as the legacy v1.1 collection
 *         bids used), a "ghost offer" backed by spent balance is impossible by construction.
 *
 *         Same OTC family as private sales; this is the half where the BUYER names the token and
 *         price. Unique-item collections (PEGNAMES, PentaPets) need this — a collection-wide bid
 *         can't target one specific NFT.
 *
 * @dev Native PC (paymentToken address(0)) or an ERC20 (WPC). Pentagon Chain (3344) only for now.
 *      Marketplace fee taken from the sale (default 2.5%), ERC-2981 royalty honored, griefing-safe
 *      native refunds. ⚠ UNAUDITED — run `forge test` + audit before deployment.
 */
contract PentagonNFTOffers is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Offer {
        address buyer;
        address collection;
        uint256 tokenId;
        uint256 price; // escrowed amount, in paymentToken
        address paymentToken; // address(0) = native PC, else ERC20 (e.g. WPC)
        uint64 expiry;
        bool active;
    }

    uint256 public constant FEE_DENOMINATOR = 10000;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 90 days;

    uint256 public marketplaceFee = 250; // 2.5% — buyer-initiated open-market offer, taxed like a sale
    uint256 public offerCounter;
    mapping(uint256 => Offer) public offers;
    mapping(address => uint256) public pendingReturns; // failed native refunds (griefing-safe)
    mapping(address => uint256) public feesAccrued; // per paymentToken, withdrawable by owner

    event OfferCreated(
        uint256 indexed offerId,
        address indexed buyer,
        address indexed collection,
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint64 expiry
    );
    event OfferAccepted(uint256 indexed offerId, address indexed seller, address indexed buyer, uint256 price);
    event OfferCancelled(uint256 indexed offerId);
    event FeeUpdated(uint256 fee);
    event FeesWithdrawn(address indexed token, uint256 amount);
    event PendingReturnWithdrawn(address indexed account, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // ─── Buyer: make an escrowed offer on a specific token ──────────────────
    function makeOffer(
        address collection,
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint64 duration
    ) external payable nonReentrant returns (uint256 offerId) {
        require(price > 0, "Price 0");
        require(duration >= MIN_DURATION && duration <= MAX_DURATION, "Bad duration");
        // Token must exist; you can't make an offer on a token you already own.
        require(IERC721(collection).ownerOf(tokenId) != msg.sender, "Own token");

        if (paymentToken == address(0)) {
            require(msg.value == price, "Wrong native value");
        } else {
            require(msg.value == 0, "No native for ERC20 offer");
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price); // escrow
        }

        offerId = ++offerCounter;
        offers[offerId] = Offer({
            buyer: msg.sender,
            collection: collection,
            tokenId: tokenId,
            price: price,
            paymentToken: paymentToken,
            expiry: uint64(block.timestamp) + duration,
            active: true
        });
        emit OfferCreated(offerId, msg.sender, collection, tokenId, price, paymentToken, uint64(block.timestamp) + duration);
    }

    // ─── Seller: accept an offer for a token you currently own ──────────────
    /// @dev Approve this contract for the token first (setApprovalForAll or approve).
    function acceptOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.active, "Inactive");
        require(block.timestamp <= o.expiry, "Expired");
        require(IERC721(o.collection).ownerOf(o.tokenId) == msg.sender, "Not token owner");
        o.active = false;

        uint256 fee = (o.price * marketplaceFee) / FEE_DENOMINATOR;
        (address royaltyReceiver, uint256 royaltyAmount) = _royalty(o.collection, o.tokenId, o.price);
        require(fee + royaltyAmount <= o.price, "fee + royalty exceeds price");
        uint256 proceeds = o.price - fee - royaltyAmount;

        // NFT: seller → buyer. Funds (already escrowed): contract → seller / royalty; fee retained.
        IERC721(o.collection).safeTransferFrom(msg.sender, o.buyer, o.tokenId);
        if (fee > 0) feesAccrued[o.paymentToken] += fee;
        _pay(o.paymentToken, msg.sender, proceeds);
        if (royaltyAmount > 0) _pay(o.paymentToken, royaltyReceiver, royaltyAmount);
        emit OfferAccepted(offerId, msg.sender, o.buyer, o.price);
    }

    // ─── Buyer: cancel; anyone: reclaim after expiry (refund escrow) ────────
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.active, "Inactive");
        require(msg.sender == o.buyer, "Not buyer");
        o.active = false;
        _refund(o.paymentToken, o.buyer, o.price);
        emit OfferCancelled(offerId);
    }

    /// @notice Permissionless once expired — cleans up and refunds the buyer's escrow.
    function reclaimExpired(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.active, "Inactive");
        require(block.timestamp > o.expiry, "Not expired");
        o.active = false;
        _refund(o.paymentToken, o.buyer, o.price);
        emit OfferCancelled(offerId);
    }

    // ─── Views ──────────────────────────────────────────────────────────────
    /// @notice Is this offer currently acceptable? (active, unexpired). Handy for wallets/bots.
    function isLive(uint256 offerId) external view returns (bool) {
        Offer storage o = offers[offerId];
        return o.active && block.timestamp <= o.expiry;
    }

    // ─── Admin ────────────────────────────────────────────────────────────
    function setFee(uint256 fee) external onlyOwner {
        require(fee <= 1000, "Fee too high (max 10%)");
        marketplaceFee = fee;
        emit FeeUpdated(fee);
    }

    function withdrawFees(address token, uint256 amount) external onlyOwner {
        require(amount <= feesAccrued[token], "Exceeds accrued");
        feesAccrued[token] -= amount;
        _pay(token, owner(), amount);
        emit FeesWithdrawn(token, amount);
    }

    function withdrawPending() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingReturns[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Withdraw failed");
        emit PendingReturnWithdrawn(msg.sender, amount);
    }

    // ─── Internal ───────────────────────────────────────────────────────────
    function _royalty(address collection, uint256 tokenId, uint256 price)
        internal
        view
        returns (address receiver, uint256 amount)
    {
        try IERC2981(collection).royaltyInfo(tokenId, price) returns (address r, uint256 a) {
            return (r, a);
        } catch {
            return (address(0), 0);
        }
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "Native transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Never reverts the caller; a failed native refund escrows to pendingReturns.
    function _refund(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) pendingReturns[to] += amount;
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
