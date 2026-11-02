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
/// - Fee: buyer side only, hard-capped at 5%, and it goes to the collection's floor fund, not to us. Royalty: our registry only; a collection's own ERC-2981
///   is ignored. Capped at 10%. Both rates are frozen into each listing / offer when it is made.
/// - Two balances are HELD HERE per collection (nftprof 2026-11-02):
///   - floorFundOf: the fee. Only our owner withdraws it, to any wallet, to buy that collection's floor
///     NFTs (here or on other marketplaces) for Redeem. The creator can never withdraw it, so a creator
///     wash-trading their own collection still pays the fee (audit F-14).
///   - royaltyFundOf: the default royalty of collections nobody has registered. Our owner withdraws it to
///     itself or the collection's owner(). The collection's owner() can withdraw only what our owner has
///     approved for it (creatorAllowance), after agreeing with us what it is for; an active creator can
///     be given an open allowance.
/// - Who registers a royalty: the collection's own owner() (self-serve, on our site), or our owner.
///   Our owner can override any registration and block self-serve for a collection (disputes,
///   renounced or wrong owner()).
/// - The off-chain PC rebate is only safe while fee + royalty costs a wash trader more than the
///   rebate returns, so the default royalty is part of that safety argument: re-check the rebate
///   before lowering it or the fee (docs/REBATE-DESIGN.md).
/// - Nobody can buy their own listing or fill their own offer.
/// - Free person-to-person sales: listPrivate names the one wallet that may buy. No fee and no
///   royalty are charged on it (and the off-chain PC rebate, which is a share of the fee, is nothing).
/// - Tips: a buyer may add an optional tip to any purchase, at most 5% of what the items cost; it goes
///   to the tip jar (NFTC liquidity), which the owner sets.
/// - A listing is live only while the seller still owns the NFT, it has not expired (max 180 days)
///   and the seller has not bumped their nonce (cancel-all). Every sale deletes it; anyone may clear
///   a listing that is no longer live, so it can never come back at an old price.
/// - Offers name one collection and are only filled with that collection's tokens. An offer may
///   restrict which tokens fill it with a Merkle root of token ids (trait offers, single-item offers).
/// - Payouts are pushed with a gas limit; if a receiver rejects them they are kept for withdraw().
/// - Owner powers: fee, royalties, tip jar, floor- and royalty-fund withdrawals and creator allowances (above), which collections trade, pause / unpause,
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
    /// collection => tokenId => the only wallet allowed to buy that listing (0 = anyone)
    mapping(address => mapping(uint256 => address)) public privateBuyer;
    /// Fees held per collection, for floor buys (see the header).
    mapping(address => uint256) public floorFundOf;
    /// Unregistered royalties held per collection (see the header).
    mapping(address => uint256) public royaltyFundOf;
    /// How much of royaltyFundOf the collection's owner() may withdraw; type(uint256).max = open.
    mapping(address => uint256) public creatorAllowance;
    /// The owner() wallet the allowance was granted to; only it may use the allowance.
    mapping(address => address) public creatorAllowanceHolder;

    address public guardian; // may pause (never unpause); 0 = owner only
    address public tipJar; // where buyer tips go (NFTC liquidity)
    uint16 public feeBps;
    uint16 public defaultRoyaltyBps;

    event Listed(address indexed collection, uint256 indexed tokenId, address indexed seller, uint256 price, uint256 expiry, uint256 feeBps, uint256 royaltyBps);
    event PrivateListed(address indexed collection, uint256 indexed tokenId, address indexed seller, address buyer);
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
    event FloorFundWithdrawn(address indexed collection, address indexed to, uint256 amount, address indexed by);
    event RoyaltyFundWithdrawn(address indexed collection, address indexed to, uint256 amount, address indexed by);
    event CreatorAllowanceSet(address indexed collection, address indexed holder, uint256 amount);
    event GuardianSet(address guardian);
    event TipJarSet(address tipJar);
    event Tipped(address indexed buyer, uint256 amount);

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
    error NotPrivateBuyer();
    error TipTooHigh();
    error BpsTooHigh();
    error ZeroAddress();
    error NotCollectionOwner();
    error SelfServeIsBlocked();
    error NothingToWithdraw();
    error WithdrawFailed();
    error NotGuardian();
    error RenounceDisabled();
    error NotAllowedToWithdraw();
    error BadRecipient();
    error AmountTooHigh();

    constructor(address owner_, address tipJar_, uint16 feeBps_, uint16 defaultRoyaltyBps_)
        Ownable(owner_)
    {
        if (tipJar_ == address(0)) revert ZeroAddress();
        tipJar = tipJar_;
        emit TipJarSet(tipJar_);
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
        uint16 royaltyBps = _royaltyBps(collection);
        for (uint256 i; i < tokenIds.length; ++i) {
            _list(collection, tokenIds[i], prices[i], expiry, feeBps, royaltyBps);
            if (privateBuyer[collection][tokenIds[i]] != address(0)) delete privateBuyer[collection][tokenIds[i]];
        }
    }

    /// Free person-to-person sale: only `buyer` can buy it, and no fee or royalty is charged.
    function listPrivate(address collection, uint256 tokenId, uint256 price, address buyer, uint256 expiry)
        external
        whenNotPaused
    {
        if (!collectionAllowed[collection]) revert CollectionNotAllowed();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_DURATION) revert BadExpiry();
        if (buyer == address(0)) revert ZeroAddress();
        if (buyer == msg.sender) revert SelfTrade();
        _list(collection, tokenId, price, expiry, 0, 0);
        privateBuyer[collection][tokenId] = buyer;
        emit PrivateListed(collection, tokenId, msg.sender, buyer);
    }

    function _list(address collection, uint256 id, uint256 price, uint256 expiry, uint16 fee, uint16 royaltyBps) internal {
        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(id) != msg.sender) revert NotTokenOwner();
        if (!nft.isApprovedForAll(msg.sender, address(this)) && nft.getApproved(id) != address(this)) revert NotApproved();
        if (price == 0 || price > type(uint96).max) revert BadPrice();
        listings[collection][id] = Listing(msg.sender, uint96(price), uint40(expiry), sellerNonce[msg.sender], fee, royaltyBps);
        emit Listed(collection, id, msg.sender, price, expiry, fee, royaltyBps);
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
    /// `tip` (optional, at most MAX_FEE_BPS of the items' cost) goes to the tip jar; send it on top.
    function buy(BuyItem[] calldata items, uint256 tip) external payable nonReentrant whenNotPaused {
        uint256 spent;
        for (uint256 i; i < items.length; ++i) {
            BuyItem calldata it = items[i];
            Listing memory l = listings[it.collection][it.tokenId];
            if (l.seller == address(0)) revert NotListed();
            if (l.seller == msg.sender) revert SelfTrade();
            address pb = privateBuyer[it.collection][it.tokenId];
            if (pb != address(0)) {
                if (pb != msg.sender) revert NotPrivateBuyer();
                delete privateBuyer[it.collection][it.tokenId];
            }
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
        if (tip > 0) {
            if (tip > (spent * MAX_FEE_BPS) / 10_000) revert TipTooHigh();
            spent += tip;
            if (spent > msg.value) revert InsufficientPayment();
            _pay(tipJar, tip);
            emit Tipped(msg.sender, tip);
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
        return (address(this), defaultRoyaltyBps, false); // held in royaltyFundOf[collection]
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
    /// receiver = 0 removes the registration; royalties go back into the collection's floor fund.
    function registerRoyalty(address collection, address receiver, uint16 bps) external onlyOwner {
        _registerRoyalty(collection, receiver, bps);
    }

    /// Self-serve: the wallet the collection contract names as its owner() sets the collection's
    /// royalty. receiver = 0 removes it (royalties go back into the collection's floor fund).
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


    /// Withdraw a collection's fees to buy its floor NFTs. Our owner only; to any wallet (e.g. the one
    /// that buys on other marketplaces).
    function withdrawFloorFund(address collection, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert BadRecipient();
        if (amount == 0 || amount > floorFundOf[collection]) revert AmountTooHigh();
        floorFundOf[collection] -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit FloorFundWithdrawn(collection, to, amount, msg.sender);
    }

    /// Let the collection's owner() withdraw up to `amount` of its royalty fund (replaces any earlier
    /// allowance; type(uint256).max = open, 0 = none). The allowance belongs to the wallet that is the
    /// owner() now: if the collection changes hands, the new owner() starts with nothing (audit F-15).
    function setCreatorAllowance(address collection, uint256 amount) external onlyOwner {
        address holder = collectionOwner(collection);
        if (amount != 0 && holder == address(0)) revert NotCollectionOwner();
        creatorAllowance[collection] = amount;
        creatorAllowanceHolder[collection] = holder;
        emit CreatorAllowanceSet(collection, holder, amount);
    }

    /// Withdraw a collection's unregistered royalties. Callers: our owner always; the collection's
    /// owner() wallet up to its allowance (and while self-serve isn't blocked). Recipient: our owner or
    /// the collection's owner(), nobody else.
    function withdrawRoyaltyFund(address collection, address to, uint256 amount) external nonReentrant {
        address cOwner = collectionOwner(collection);
        if (msg.sender != owner()) {
            if (
                cOwner == address(0) || msg.sender != cOwner || msg.sender != creatorAllowanceHolder[collection]
                    || selfServeBlocked[collection]
            ) {
                revert NotAllowedToWithdraw();
            }
            uint256 allowance = creatorAllowance[collection];
            if (amount > allowance) revert NotAllowedToWithdraw();
            if (allowance != type(uint256).max) creatorAllowance[collection] = allowance - amount;
        }
        if (to != owner() && (cOwner == address(0) || to != cOwner)) revert BadRecipient();
        if (amount == 0 || amount > royaltyFundOf[collection]) revert AmountTooHigh();
        royaltyFundOf[collection] -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit RoyaltyFundWithdrawn(collection, to, amount, msg.sender);
    }

    /// Disabled: an ownerless marketplace would strand floor funds and lose unpause and refunds.
    /// Hand over with the two-step transferOwnership instead.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// The owner or the guardian (a hot key for emergencies) can pause; only the owner can unpause.
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardian();
        _pause();
    }

    function setTipJar(address tipJar_) external onlyOwner {
        if (tipJar_ == address(0)) revert ZeroAddress();
        tipJar = tipJar_;
        emit TipJarSet(tipJar_);
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
        if (privateBuyer[collection][tokenId] != address(0)) delete privateBuyer[collection][tokenId];
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
        // The fee goes to the collection, not to us (nftprof 2026-11-02): into its floor fund.
        if (fee > 0) floorFundOf[collection] += fee;
        if (royalty > 0) {
            if (registered) _pay(receiver, royalty);
            else royaltyFundOf[collection] += royalty;
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

}
