// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IOwnableCollection {
    function owner() external view returns (address);
}

/// @title Pentagon Marketplace V3
/// @notice Fixed-price listings and escrowed offers for ERC-721, paid in the chain's native coin
/// (ETH on Ethereum, PC on Pentagon). NFTs never leave the seller's wallet until a sale; offer money
/// is held here until filled or cancelled.
///
/// Rules, in one place:
/// - Fee: buyer side only, hard-capped at 5%. Royalty: our registry only; a collection's own ERC-2981
///   is ignored. Collections nobody has registered pay the default royalty to the floor fund. Capped
///   at 10%. Both rates are frozen into each listing / offer when it is made.
/// - Who registers a royalty: the collection's own owner() (self-serve, on our site), or our owner.
///   Our owner can override any registration and block self-serve for a collection (disputes,
///   renounced or wrong owner()).
/// - The off-chain PC rebate is only safe while fee + royalty costs a wash trader more than the
///   rebate returns, so the default royalty is part of that safety argument: re-check the rebate
///   before lowering it or the fee (docs/REBATE-DESIGN.md).
/// - Nobody can buy their own listing or fill their own offer.
/// - A listing is live only while the seller still owns the NFT, it has not expired (max 180 days)
///   and the seller has not bumped their nonce (cancel-all). Every sale deletes it; anyone may clear
///   a listing that is no longer live, so it can never come back at an old price.
/// - Offers name one collection and are only filled with that collection's tokens. An offer may
///   restrict which tokens fill it with a Merkle root of token ids (trait offers, single-item offers).
/// - Payouts are pushed with a gas limit; if a receiver rejects them they are kept for withdraw().
/// - Owner powers: fee, royalties, treasury / floor fund, which collections trade, pause / unpause,
///   naming a guardian (a hot key that can only pause), and, while paused, refunding offers to their
///   bidders. The owner can never move anyone's NFT or money elsewhere.
contract PentagonMarketplaceV3 is Ownable2Step, ReentrancyGuard, Pausable {
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant MAX_ROYALTY_BPS = 1000;
    uint256 public constant MAX_DURATION = 180 days;
    uint256 public constant PAYOUT_GAS = 50_000;

    struct Listing {
        address seller;
        uint96 price;
        uint40 expiry;
        uint64 nonce;
        uint16 feeBps;
        uint16 royaltyBps;
    }

    struct Offer {
        address bidder;
        uint96 price; // per NFT, excluding fee
        address collection;
        uint40 expiry;
        uint16 feeBps;
        uint16 royaltyBps;
        uint16 remaining;
        bytes32 tokensRoot; // 0 = any token of the collection
    }

    struct Royalty {
        address receiver;
        uint16 bps;
    }

    struct BuyItem {
        address collection;
        uint256 tokenId;
        uint256 maxPrice; // the price the buyer saw; the listing must not be dearer
    }

    mapping(address => bool) public collectionAllowed;
    mapping(address => mapping(uint256 => Listing)) public listings;
    mapping(address => uint64) public sellerNonce;
    mapping(uint256 => Offer) public offers;
    uint256 public offerCount;
    mapping(address => Royalty) public registeredRoyalty;
    mapping(address => uint256) public pendingPayouts;
    mapping(address => bool) public selfServeBlocked;

    address public treasury;
    address public floorFund;
    address public guardian; // may pause (never unpause); 0 = owner only
    uint16 public feeBps;
    uint16 public defaultRoyaltyBps;

    event Listed(address indexed collection, uint256 indexed tokenId, address indexed seller, uint256 price, uint256 expiry, uint256 feeBps, uint256 royaltyBps);
    event ListingRemoved(address indexed collection, uint256 indexed tokenId, address indexed seller);
    event NonceIncremented(address indexed seller, uint256 nonce);
    /// offerId 0 = bought from a listing
    event Sale(address indexed collection, uint256 indexed tokenId, address seller, address indexed buyer, uint256 price, uint256 fee, uint256 royalty, uint256 offerId);
    event RoyaltyPaid(address indexed collection, uint256 indexed tokenId, address indexed receiver, uint256 amount, bool registered);
    event OfferPlaced(uint256 indexed offerId, address indexed bidder, address indexed collection, uint256 price, uint256 quantity, uint256 expiry, uint256 feeBps, bytes32 tokensRoot);
    event OfferClosed(uint256 indexed offerId, uint256 refund);
    event PayoutDeferred(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event CollectionAllowed(address indexed collection, bool allowed);
    event FeeSet(uint256 bps);
    event RoyaltyRegistered(address indexed collection, address receiver, uint256 bps, address indexed by);
    event SelfServeBlocked(address indexed collection, bool blocked);
    event DefaultRoyaltySet(uint256 bps);
    event TreasurySet(address treasury);
    event FloorFundSet(address floorFund);
    event GuardianSet(address guardian);

    error CollectionNotAllowed();
    error LengthMismatch();
    error BadExpiry();
    error BadPrice();
    error BadQuantity();
    error NotTokenOwner();
    error NotApproved();
    error NotSeller();
    error NotListed();
    error ListingNotLive();
    error PriceAboveMax();
    error InsufficientPayment();
    error WrongPayment();
    error OfferNotLive();
    error NotBidder();
    error TokenNotInOffer();
    error SelfTrade();
    error BpsTooHigh();
    error ZeroAddress();
    error NotCollectionOwner();
    error SelfServeIsBlocked();
    error NothingToWithdraw();
    error WithdrawFailed();
    error NotGuardian();

    constructor(address owner_, address treasury_, address floorFund_, uint16 feeBps_, uint16 defaultRoyaltyBps_)
        Ownable(owner_)
    {
        _setTreasury(treasury_);
        _setFloorFund(floorFund_);
        _setFee(feeBps_);
        _setDefaultRoyalty(defaultRoyaltyBps_);
    }

    // ───────────────────────────── Listings ─────────────────────────────

    /// List (or re-price) NFTs you own. Re-listing a token replaces its old listing.
    function list(address collection, uint256[] calldata tokenIds, uint256[] calldata prices, uint256 expiry)
        external
        whenNotPaused
    {
        if (!collectionAllowed[collection]) revert CollectionNotAllowed();
        if (tokenIds.length != prices.length) revert LengthMismatch();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_DURATION) revert BadExpiry();
        IERC721 nft = IERC721(collection);
        bool approvedAll = nft.isApprovedForAll(msg.sender, address(this));
        uint64 nonce = sellerNonce[msg.sender];
        uint16 royaltyBps = _royaltyBps(collection);
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (nft.ownerOf(id) != msg.sender) revert NotTokenOwner();
            if (!approvedAll && nft.getApproved(id) != address(this)) revert NotApproved();
            if (prices[i] == 0 || prices[i] > type(uint96).max) revert BadPrice();
            listings[collection][id] = Listing(msg.sender, uint96(prices[i]), uint40(expiry), nonce, feeBps, royaltyBps);
            emit Listed(collection, id, msg.sender, prices[i], expiry, feeBps, royaltyBps);
        }
    }

    function delist(address collection, uint256[] calldata tokenIds) external {
        for (uint256 i; i < tokenIds.length; ++i) {
            if (listings[collection][tokenIds[i]].seller != msg.sender) revert NotSeller();
            _removeListing(collection, tokenIds[i]);
        }
    }

    /// Cancel every listing you have ever made, in one transaction.
    function incrementNonce() external {
        uint64 n = ++sellerNonce[msg.sender];
        emit NonceIncremented(msg.sender, n);
    }

    /// Anyone (our keeper) may delete listings that are no longer live: the seller sold or moved the
    /// NFT, revoked approval, the listing expired or was cancelled by nonce. Live listings are skipped.
    function clearStale(address collection, uint256[] calldata tokenIds) external {
        for (uint256 i; i < tokenIds.length; ++i) {
            Listing memory l = listings[collection][tokenIds[i]];
            if (l.seller != address(0) && !_isLive(collection, tokenIds[i], l)) _removeListing(collection, tokenIds[i]);
        }
    }

    function isListingLive(address collection, uint256 tokenId) external view returns (bool) {
        Listing memory l = listings[collection][tokenId];
        return l.seller != address(0) && _isLive(collection, tokenId, l);
    }

    /// Buy one or more listings. Send at least sum(price + fee); the rest is refunded.
    function buy(BuyItem[] calldata items) external payable nonReentrant whenNotPaused {
        uint256 spent;
        for (uint256 i; i < items.length; ++i) {
            BuyItem calldata it = items[i];
            Listing memory l = listings[it.collection][it.tokenId];
            if (l.seller == address(0)) revert NotListed();
            if (l.seller == msg.sender) revert SelfTrade();
            if (!collectionAllowed[it.collection]) revert CollectionNotAllowed();
            if (l.expiry < block.timestamp || l.nonce != sellerNonce[l.seller]) revert ListingNotLive();
            if (l.price > it.maxPrice) revert PriceAboveMax();
            delete listings[it.collection][it.tokenId];
            uint256 fee = (uint256(l.price) * l.feeBps) / 10_000;
            spent += uint256(l.price) + fee;
            if (spent > msg.value) revert InsufficientPayment();
            // Reverts if the seller no longer owns the NFT or revoked approval.
            IERC721(it.collection).transferFrom(l.seller, msg.sender, it.tokenId);
            _settle(it.collection, it.tokenId, l.seller, msg.sender, l.price, fee, l.royaltyBps, 0);
        }
        if (msg.value > spent) _pay(msg.sender, msg.value - spent);
    }

    // ───────────────────────────── Offers ─────────────────────────────

    /// Offer `price` per NFT for `quantity` NFTs of `collection`. Send exactly (price + fee) * quantity.
    /// `tokensRoot` limits which tokens fill it (Merkle root over token ids; 0 = any token).
    function placeOffer(address collection, uint256 price, uint256 quantity, uint256 expiry, bytes32 tokensRoot)
        external
        payable
        whenNotPaused
        returns (uint256 offerId)
    {
        if (!collectionAllowed[collection]) revert CollectionNotAllowed();
        if (price == 0 || price > type(uint96).max) revert BadPrice();
        if (quantity == 0 || quantity > type(uint16).max) revert BadQuantity();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_DURATION) revert BadExpiry();
        uint256 fee = (price * feeBps) / 10_000;
        if (msg.value != (price + fee) * quantity) revert WrongPayment();
        offerId = ++offerCount;
        offers[offerId] = Offer(
            msg.sender, uint96(price), collection, uint40(expiry), feeBps, _royaltyBps(collection), uint16(quantity), tokensRoot
        );
        emit OfferPlaced(offerId, msg.sender, collection, price, quantity, expiry, feeBps, tokensRoot);
    }

    /// Sell NFTs you own into an offer. Only the offer's own collection can fill it.
    /// `proofs[i]` proves tokenIds[i] is in the offer's token set (empty when the offer takes any token).
    function acceptOffer(uint256 offerId, uint256[] calldata tokenIds, bytes32[][] calldata proofs)
        external
        nonReentrant
        whenNotPaused
    {
        Offer storage o = offers[offerId];
        address collection = o.collection;
        if (o.bidder == address(0) || o.expiry < block.timestamp) revert OfferNotLive();
        if (o.bidder == msg.sender) revert SelfTrade();
        if (!collectionAllowed[collection]) revert CollectionNotAllowed();
        if (tokenIds.length == 0 || tokenIds.length > o.remaining) revert BadQuantity();
        if (o.tokensRoot != bytes32(0) && proofs.length != tokenIds.length) revert LengthMismatch();
        o.remaining -= uint16(tokenIds.length);

        address bidder = o.bidder;
        uint256 price = o.price;
        uint256 fee = (price * o.feeBps) / 10_000;
        bytes32 root = o.tokensRoot;
        uint16 royaltyBps = o.royaltyBps;
        if (o.remaining == 0) delete offers[offerId];

        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (root != bytes32(0) && !MerkleProof.verifyCalldata(proofs[i], root, _leaf(id))) revert TokenNotInOffer();
            if (listings[collection][id].seller != address(0)) _removeListing(collection, id);
            // Reverts unless the caller owns this token of the offer's collection and approved us.
            IERC721(collection).transferFrom(msg.sender, bidder, id);
            _settle(collection, id, msg.sender, bidder, price, fee, royaltyBps, offerId);
        }
    }

    /// Withdraw the unfilled part of your offer (works when paused and after expiry).
    function cancelOffer(uint256 offerId) external nonReentrant {
        if (offers[offerId].bidder != msg.sender) revert NotBidder();
        _closeOffer(offerId);
    }

    /// Refund offers to their own bidders when winding down. Only while paused, so the owner can never
    /// clear competing offers off a live book. Money only goes back to the bidder.
    function refundOffers(uint256[] calldata offerIds) external onlyOwner whenPaused nonReentrant {
        for (uint256 i; i < offerIds.length; ++i) {
            if (offers[offerIds[i]].bidder != address(0)) _closeOffer(offerIds[i]);
        }
    }

    // ───────────────────────────── Payouts ─────────────────────────────

    /// Collect payouts that could not be pushed to you.
    function withdraw() external nonReentrant {
        _withdraw(msg.sender);
    }

    /// Anyone may push a payee's held payout to the payee (and only to the payee), e.g. for a contract
    /// wallet that can receive with more gas but can't call withdraw() itself.
    function withdrawFor(address payee) external nonReentrant {
        _withdraw(payee);
    }

    /// Who is paid the royalty for a collection right now, at what rate, and whether a creator registered.
    function royaltyFor(address collection) public view returns (address receiver, uint256 bps, bool registered) {
        Royalty memory r = registeredRoyalty[collection];
        if (r.receiver != address(0)) return (r.receiver, r.bps, true);
        return (floorFund, defaultRoyaltyBps, false);
    }

    // ───────────────────────────── Admin ─────────────────────────────

    function setCollectionAllowed(address collection, bool allowed) external onlyOwner {
        collectionAllowed[collection] = allowed;
        emit CollectionAllowed(collection, allowed);
    }

    /// New fee applies to listings and offers made from now on; existing ones keep theirs.
    function setFee(uint16 bps) external onlyOwner {
        _setFee(bps);
    }

    /// Register a creator's royalty (after they have proved control of the collection to us).
    /// receiver = 0 removes the registration, sending royalties back to the floor fund.
    function registerRoyalty(address collection, address receiver, uint16 bps) external onlyOwner {
        _registerRoyalty(collection, receiver, bps);
    }

    /// Self-serve: the wallet the collection contract names as its owner() sets the collection's
    /// royalty. receiver = 0 removes it (royalties go back to the floor fund).
    function registerRoyaltyAsCreator(address collection, address receiver, uint16 bps) external {
        if (selfServeBlocked[collection]) revert SelfServeIsBlocked();
        if (collectionOwner(collection) != msg.sender) revert NotCollectionOwner();
        _registerRoyalty(collection, receiver, bps);
    }

    /// Stop (or allow again) self-serve for a collection whose owner() can't be trusted.
    function setSelfServeBlocked(address collection, bool blocked) external onlyOwner {
        selfServeBlocked[collection] = blocked;
        emit SelfServeBlocked(collection, blocked);
    }

    /// The collection contract's owner(), or 0 if it has none.
    function collectionOwner(address collection) public view returns (address) {
        try IOwnableCollection(collection).owner() returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }

    function setDefaultRoyalty(uint16 bps) external onlyOwner {
        _setDefaultRoyalty(bps);
    }

    function setTreasury(address treasury_) external onlyOwner {
        _setTreasury(treasury_);
    }

    function setFloorFund(address floorFund_) external onlyOwner {
        _setFloorFund(floorFund_);
    }

    /// The owner or the guardian (a hot key for emergencies) can pause; only the owner can unpause.
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardian();
        _pause();
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _isLive(address collection, uint256 tokenId, Listing memory l) internal view returns (bool) {
        // A disallowed collection's listings count as stale, so they can be cleared and can't all come
        // back at their old prices if the collection is allowed again.
        if (!collectionAllowed[collection]) return false;
        if (l.expiry < block.timestamp || l.nonce != sellerNonce[l.seller]) return false;
        IERC721 nft = IERC721(collection);
        try nft.ownerOf(tokenId) returns (address owner) {
            if (owner != l.seller) return false;
        } catch {
            return false; // burned
        }
        return nft.isApprovedForAll(l.seller, address(this)) || nft.getApproved(tokenId) == address(this);
    }

    function _removeListing(address collection, uint256 tokenId) internal {
        address seller = listings[collection][tokenId].seller;
        delete listings[collection][tokenId];
        emit ListingRemoved(collection, tokenId, seller);
    }

    function _settle(
        address collection,
        uint256 tokenId,
        address seller,
        address buyer,
        uint256 price,
        uint256 fee,
        uint256 royaltyBps,
        uint256 offerId
    ) internal {
        // The seller pays the lower of the rate frozen into their order and today's rate, to today's
        // receiver: a later registration can't raise what an open listing or offer pays.
        (address receiver, uint256 currentBps, bool registered) = royaltyFor(collection);
        if (currentBps < royaltyBps) royaltyBps = currentBps;
        uint256 royalty = (price * royaltyBps) / 10_000;
        if (fee > 0) _pay(treasury, fee);
        if (royalty > 0) {
            _pay(receiver, royalty);
            emit RoyaltyPaid(collection, tokenId, receiver, royalty, registered);
        }
        _pay(seller, price - royalty);
        emit Sale(collection, tokenId, seller, buyer, price, fee, royalty, offerId);
    }

    function _withdraw(address payee) internal {
        uint256 amount = pendingPayouts[payee];
        if (amount == 0) revert NothingToWithdraw();
        pendingPayouts[payee] = 0;
        (bool ok,) = payee.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(payee, amount);
    }

    function _closeOffer(uint256 offerId) internal {
        Offer memory o = offers[offerId];
        delete offers[offerId];
        uint256 refund = (uint256(o.price) + (uint256(o.price) * o.feeBps) / 10_000) * o.remaining;
        if (refund > 0) _pay(o.bidder, refund);
        emit OfferClosed(offerId, refund);
    }

    /// Push native coin with a gas limit and without copying return data; keep it for withdraw() on failure.
    function _pay(address to, uint256 amount) internal {
        bool ok;
        assembly {
            ok := call(PAYOUT_GAS, to, amount, 0, 0, 0, 0)
        }
        if (!ok) {
            pendingPayouts[to] += amount;
            emit PayoutDeferred(to, amount);
        }
    }

    /// Leaf format of OpenZeppelin's StandardMerkleTree over ["uint256"] (double-hashed).
    function _leaf(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(tokenId))));
    }

    function _royaltyBps(address collection) internal view returns (uint16) {
        Royalty memory r = registeredRoyalty[collection];
        return r.receiver != address(0) ? r.bps : defaultRoyaltyBps;
    }

    function _registerRoyalty(address collection, address receiver, uint16 bps) internal {
        if (bps > MAX_ROYALTY_BPS) revert BpsTooHigh();
        if (receiver == address(0)) delete registeredRoyalty[collection];
        else registeredRoyalty[collection] = Royalty(receiver, bps);
        emit RoyaltyRegistered(collection, receiver, receiver == address(0) ? 0 : bps, msg.sender);
    }

    function _setFee(uint16 bps) internal {
        if (bps > MAX_FEE_BPS) revert BpsTooHigh();
        feeBps = bps;
        emit FeeSet(bps);
    }

    function _setDefaultRoyalty(uint16 bps) internal {
        if (bps > MAX_ROYALTY_BPS) revert BpsTooHigh();
        defaultRoyaltyBps = bps;
        emit DefaultRoyaltySet(bps);
    }

    function _setTreasury(address t) internal {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    function _setFloorFund(address f) internal {
        if (f == address(0)) revert ZeroAddress();
        floorFund = f;
        emit FloorFundSet(f);
    }
}
