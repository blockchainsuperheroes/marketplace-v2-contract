// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
/// - Signed listings (nftprof 2026-11-03, go 2026-11-06): a seller lists by signing an EIP-712 Order,
///   with no transaction. Cancelling one order costs gas; incrementNonce cancels every listing, signed
///   or on-chain. An order may carry a price rule instead of a fixed price:
///     price = clamp(schedule(t) × floorFactor(F / F0), priceMin, priceMax)
///   Each fill also needs our co-signer's FillAuth, at most 5 minutes old, naming the buyer and the
///   clean floor F. The co-signer enforces the order's audience (collectors only, holders of X, named
///   wallets) and refuses fat-finger and phishing patterns. It can't change what the seller signed: the
///   contract never sells outside [priceMin, priceMax] or to a buyer above their maxPrice.
///   Signed orders pay today's fee and royalty (within the hard caps). A seller who signed
///   acceptFeeChanges = false is protected instead: the order is refused while either rate is above
///   what they signed. Named-wallet orders (a Merkle root checked here) are free, like listPrivate.
/// - Floor reference (nftprof 2026-11-07): per collection, the co-signer's F is clamped to a band
///   around an on-chain reference that widens with time (−fall / +rise per day); the reference then
///   moves to the clamped F. Signed fills priced below floorBackstopBps of the band's low end are refused.
/// - Flags (nftprof 2026-11-07): the flagger reports tokens (e.g. stolen). A flagged token sells only as a
///   signed order whose buyer accepted the warning; it is then held (no resale here) unless the
///   co-signer marked the buyer high-reputation or the flagger clears it. The claimant (original owner)
///   may buy it back at no more than max(price paid, floor reference). Flags bind this marketplace only.
/// - Owner powers: fee, royalties, tip jar, floor- and royalty-fund withdrawals and creator allowances (above), which collections trade, pause / unpause,
///   naming a guardian (a hot key that can only pause) and the co-signer, and, while paused, refunding
///   offers to their bidders. The owner can never move anyone's NFT or money elsewhere.
contract PentagonMarketplaceV3 is Ownable2Step, ReentrancyGuard, Pausable, EIP712 {
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant MAX_ROYALTY_BPS = 1000;
    uint256 public constant MAX_DURATION = 180 days;
    uint256 public constant PAYOUT_GAS = 50_000;
    /// A co-signer's FillAuth (and the floor in it) is good for at most this long.
    uint256 private constant MAX_AUTH_WINDOW = 5 minutes;
    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10_000;

    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address seller,address collection,uint256 tokenId,uint96 startPrice,uint96 endPrice,uint40 rampStart,uint40 rampEnd,uint128 floorRef,uint16 upBps,uint16 downBps,uint96 priceMin,uint96 priceMax,bytes32 audience,uint8 audienceKind,uint16 feeBps,uint16 royaltyBps,bool acceptFeeChanges,uint64 nonce,uint40 start,uint40 expiry,uint256 salt)"
    );
    bytes32 private constant FILL_AUTH_TYPEHASH = keccak256(
        "FillAuth(bytes32 orderHash,address buyer,uint128 floor,uint40 deadline,bool flagAck,bool clearFlag)"
    );

    uint8 private constant ORDER_FILLED = 1;
    uint8 private constant ORDER_CANCELLED = 2;
    /// audienceKind: 0 = everyone; NAMED = `audience` is a Merkle root of the wallets that may buy,
    /// checked here, and the sale is free like listPrivate; any other kind is enforced by the co-signer.
    uint8 private constant AUDIENCE_NAMED = 1;
    uint8 private constant FLAG_FLAGGED = 1;
    uint8 private constant FLAG_HELD = 2;
    uint256 private constant SALE_SIGNED = 1;
    uint256 private constant SALE_ACK = 2;
    uint256 private constant SALE_CLEAR = 4;

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

    /// A signed listing. Every field is static, so its EIP-712 struct hash is keccak256(abi.encode(TYPEHASH, order)).
    /// Fixed price: startPrice = endPrice, rampStart = rampEnd = 0, floorRef = upBps = downBps = 0,
    /// priceMin = priceMax = the price.
    struct Order {
        address seller;
        address collection;
        uint256 tokenId;
        uint96 startPrice; // schedule: startPrice until rampStart,
        uint96 endPrice; // then a straight line to endPrice at rampEnd, then held
        uint40 rampStart;
        uint40 rampEnd;
        uint128 floorRef; // F0, the clean floor when signed; 0 = ignore the floor
        uint16 upBps; // how fully the price follows the floor up (0..10000)
        uint16 downBps; // and down (0..10000)
        uint96 priceMin; // never sold below this
        uint96 priceMax; // or above this, whatever the floor does
        bytes32 audience; // who may buy (see audienceKind)
        uint8 audienceKind; // 0 = everyone, AUDIENCE_NAMED = Merkle root of wallets, other = co-signer
        uint16 feeBps; // the fee / royalty rates shown when signed
        uint16 royaltyBps;
        bool acceptFeeChanges; // true: pay today's rates even if raised (up to the caps); false: refused while above
        uint64 nonce; // must equal sellerNonce[seller]; incrementNonce cancels it
        uint40 start;
        uint40 expiry; // at most MAX_DURATION after start
        uint256 salt;
    }

    struct SignedBuy {
        Order order;
        bytes sellerSig;
        uint128 floor; // F, from the co-signer
        uint40 authDeadline;
        bytes cosignerSig;
        uint256 maxPrice; // the price the buyer saw
        bytes32[] proof; // AUDIENCE_NAMED: the buyer is in the order's Merkle root
        bool flagAck; // co-signer: the buyer accepted the flagged-token warning
        bool clearFlag; // co-signer: a high-reputation buyer; the purchase clears the flag
    }

    /// Per collection: the on-chain floor reference that bounds the co-signer's F (see _floor).
    struct FloorRef {
        uint128 ref;
        uint40 updatedAt;
    }

    /// A token reported (e.g. stolen) by the flagger. Binds this marketplace only.
    struct Flag {
        uint8 state; // FLAG_FLAGGED: sellable only signed + acknowledged; FLAG_HELD: bought while flagged, no resale
        uint96 paid; // what the holder paid for it while flagged
        address claimant; // the original owner, who may buy it back at max(paid, floor ref)
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

    /// seller => EIP-712 order hash => ORDER_FILLED / ORDER_CANCELLED (0 = open). Keyed by seller so a
    /// cancel by hash can only ever touch the caller's own orders (the hash commits to the seller).
    mapping(address => mapping(bytes32 => uint8)) public orderStatus;
    mapping(address => FloorRef) public floorRefs;
    mapping(address => mapping(uint256 => Flag)) public flags;

    address public guardian; // may pause (never unpause); 0 = owner only
    address public cosigner; // signs FillAuths for signed orders; 0 = signed orders can't be filled
    address public flagger; // flags, clears and names claimants
    uint16 public floorFallBpsPerDay; // how fast F may fall below the reference, per day since it last moved
    uint32 public floorRiseBpsPerDay; // and rise above it
    uint16 public floorBackstopBps; // signed fills priced below this share of the floor band's low end are refused
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
    event OrderFilled(bytes32 indexed orderHash, address indexed seller, address indexed buyer, uint256 price);
    event OrderCancelled(bytes32 indexed orderHash, address indexed seller);
    event CosignerSet(address cosigner);
    event FlaggerSet(address flagger);
    event FloorParamsSet(uint256 fallBpsPerDay, uint256 riseBpsPerDay, uint256 backstopBps);
    event FloorRefUpdated(address indexed collection, uint256 ref);
    event FlagSet(address indexed collection, uint256 indexed tokenId, uint256 state, address claimant, uint256 paid);

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
    error BadPriceRule();
    error OrderNotLive();
    error BadSellerSig();
    error BadCosignerSig();
    error AuthExpired();
    error CosignerNotSet();
    error RateAboveSigned();
    error BelowFloorBackstop();
    error NotFlagger();
    error TokenFlagged();
    error TokenHeld();
    error AboveClaimantPrice();
    error RefAlreadySet();

    constructor(address owner_, address tipJar_, uint16 feeBps_, uint16 defaultRoyaltyBps_)
        Ownable(owner_)
        EIP712("PentagonMarketplaceV3", "1")
    {
        if (tipJar_ == address(0)) revert ZeroAddress();
        tipJar = tipJar_;
        emit TipJarSet(tipJar_);
        _setFee(feeBps_);
        _setDefaultRoyalty(defaultRoyaltyBps_);
        _setFloorParams(2000, 5000, 1000); // −20% / +50% per day, refuse below 10% of the band's low end
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
            _beforeSale(it.collection, it.tokenId, msg.sender, l.price, 0);
            // Reverts if the seller no longer owns the NFT or revoked approval.
            IERC721(it.collection).transferFrom(l.seller, msg.sender, it.tokenId);
            _settle(it.collection, it.tokenId, l.seller, msg.sender, l.price, fee, l.royaltyBps, 0);
        }
        _finishPurchase(spent, tip);
    }

    // ───────────────────────────── Signed listings ─────────────────────────────

    /// Buy one or more signed listings. Send at least sum(price + fee); the rest is refunded. `tip` as in buy().
    function buySigned(SignedBuy[] calldata items, uint256 tip) external payable nonReentrant whenNotPaused {
        if (cosigner == address(0)) revert CosignerNotSet();
        uint256 spent;
        for (uint256 i; i < items.length; ++i) {
            spent += _fillSigned(items[i]);
            if (spent > msg.value) revert InsufficientPayment();
        }
        _finishPurchase(spent, tip);
    }

    /// One signed fill; returns what the buyer owes for it (price + fee).
    function _fillSigned(SignedBuy calldata it) internal returns (uint256) {
        Order calldata o = it.order;
        bytes32 h = _checkOrder(o, it.sellerSig);
        bool named = o.audienceKind == AUDIENCE_NAMED;
        if (named && !MerkleProof.verifyCalldata(it.proof, o.audience, keccak256(bytes.concat(keccak256(abi.encode(msg.sender)))))) {
            revert NotPrivateBuyer();
        }
        if (it.authDeadline < block.timestamp || it.authDeadline > block.timestamp + MAX_AUTH_WINDOW) revert AuthExpired();
        if (
            !SignatureChecker.isValidSignatureNow(
                cosigner, fillAuthDigest(h, msg.sender, it.floor, it.authDeadline, it.flagAck, it.clearFlag), it.cosignerSig
            )
        ) revert BadCosignerSig();

        (uint256 f, uint256 low) = _floor(o.collection, it.floor);
        uint256 price = priceAt(o, f, block.timestamp);
        if (price > it.maxPrice) revert PriceAboveMax();
        if (price < (low * floorBackstopBps) / BPS) revert BelowFloorBackstop();
        orderStatus[o.seller][h] = ORDER_FILLED;
        if (listings[o.collection][o.tokenId].seller != address(0)) _removeListing(o.collection, o.tokenId);

        // Named-wallet orders are free, like listPrivate. Others pay today's fee and royalty (_checkOrder
        // refused the order if a raise is above what a seller who didn't accept fee changes signed).
        uint256 fee;
        uint256 royaltyCap;
        if (!named) {
            fee = (price * feeBps) / BPS;
            royaltyCap = MAX_ROYALTY_BPS;
        }
        _beforeSale(
            o.collection, o.tokenId, msg.sender, price,
            SALE_SIGNED | (it.flagAck ? SALE_ACK : 0) | (it.clearFlag ? SALE_CLEAR : 0)
        );
        // Reverts if the seller no longer owns the NFT or revoked approval.
        IERC721(o.collection).transferFrom(o.seller, msg.sender, o.tokenId);
        _settle(o.collection, o.tokenId, o.seller, msg.sender, price, fee, royaltyCap, 0);
        emit OrderFilled(h, o.seller, msg.sender, price);
        return price + fee;
    }

    /// Cancel signed orders you made, by their hashes (works when paused). A hash that isn't one of your
    /// orders cancels nothing. To cancel all of them at once, incrementNonce().
    function cancelOrders(bytes32[] calldata orderHashes) external {
        for (uint256 i; i < orderHashes.length; ++i) {
            bytes32 h = orderHashes[i];
            if (orderStatus[msg.sender][h] == ORDER_FILLED) revert OrderNotLive();
            orderStatus[msg.sender][h] = ORDER_CANCELLED;
            emit OrderCancelled(h, msg.sender);
        }
    }

    /// The EIP-712 digest a seller signs for `o`; also its id in orderStatus and in FillAuth.
    function hashOrder(Order calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, o)));
    }

    /// The EIP-712 digest the co-signer signs to let `buyer` fill `orderHash` at clean floor `floor`.
    function fillAuthDigest(bytes32 orderHash, address buyer, uint128 floor, uint40 deadline, bool flagAck, bool clearFlag)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(FILL_AUTH_TYPEHASH, orderHash, buyer, floor, deadline, flagAck, clearFlag))
        );
    }

    /// The co-signer's floor `f` clamped to the collection's band right now, and the band's low end.
    /// The band is the reference ± a per-day rate × the time since the reference last moved, so a
    /// one-shot crash is softened while a real, sustained move gets through within days, and the band
    /// keeps widening while nothing fills (it can't get stuck). ref = 0 (never seeded): f is taken as is.
    function floorBand(address collection, uint256 f) public view returns (uint256 clamped, uint256 low) {
        FloorRef memory r = floorRefs[collection];
        if (r.ref == 0) return (f, f);
        uint256 dt = block.timestamp - r.updatedAt;
        uint256 fall = (dt * floorFallBpsPerDay) / 1 days;
        low = fall >= BPS ? 0 : (uint256(r.ref) * (BPS - fall)) / BPS;
        uint256 high = Math.mulDiv(r.ref, BPS + (dt * floorRiseBpsPerDay) / 1 days, BPS);
        clamped = f < low ? low : f > high ? high : f;
    }

    /// Clamp f to the band and move the reference to it.
    function _floor(address collection, uint256 f) internal returns (uint256 clamped, uint256 low) {
        (clamped, low) = floorBand(collection, f);
        if (clamped == 0) return (0, 0); // never seeded and no floor given: nothing to anchor
        uint256 ref = clamped > type(uint128).max ? type(uint128).max : clamped;
        floorRefs[collection] = FloorRef(uint128(ref), uint40(block.timestamp));
        emit FloorRefUpdated(collection, ref);
    }

    /// The price of `o` at time `t` with clean floor `floor`:
    ///   clamp(schedule(t) × floorFactor(floor / floorRef), priceMin, priceMax)
    /// floorFactor = 1 + up × (r − 1) when r ≥ 1, else 1 − down × (1 − r), with r = floor / floorRef.
    function priceAt(Order calldata o, uint256 floor, uint256 t) public pure returns (uint256 price) {
        if (
            o.priceMin == 0 || o.priceMin > o.priceMax || o.rampStart > o.rampEnd || o.upBps > BPS
                || o.downBps > BPS || (o.floorRef == 0 && (o.upBps != 0 || o.downBps != 0))
        ) revert BadPriceRule();

        if (t <= o.rampStart) {
            price = o.startPrice;
        } else if (t >= o.rampEnd) {
            price = o.endPrice;
        } else if (o.endPrice >= o.startPrice) {
            price = o.startPrice + Math.mulDiv(o.endPrice - o.startPrice, t - o.rampStart, o.rampEnd - o.rampStart);
        } else {
            price = o.startPrice - Math.mulDiv(o.startPrice - o.endPrice, t - o.rampStart, o.rampEnd - o.rampStart);
        }

        if (o.floorRef != 0 && (o.upBps != 0 || o.downBps != 0)) {
            uint256 r = Math.mulDiv(floor, ONE, o.floorRef);
            uint256 factor = r >= ONE
                ? ONE + Math.mulDiv(r - ONE, o.upBps, BPS)
                : ONE - Math.mulDiv(ONE - r, o.downBps, BPS);
            price = Math.mulDiv(price, factor, ONE);
        }

        if (price < o.priceMin) price = o.priceMin;
        if (price > o.priceMax) price = o.priceMax;
    }

    /// Everything about an order except the co-signer and the buyer's price limit. Returns its hash.
    function _checkOrder(Order calldata o, bytes calldata sig) internal view returns (bytes32 h) {
        h = hashOrder(o);
        if (orderStatus[o.seller][h] != 0) revert OrderNotLive();
        if (o.seller == msg.sender) revert SelfTrade();
        if (!collectionAllowed[o.collection]) revert CollectionNotAllowed();
        if (
            o.nonce != sellerNonce[o.seller] || block.timestamp < o.start || block.timestamp > o.expiry
                || o.expiry - o.start > MAX_DURATION
        ) revert OrderNotLive();
        if (
            o.audienceKind != AUDIENCE_NAMED && !o.acceptFeeChanges
                && (feeBps > o.feeBps || _royaltyBps(o.collection) > o.royaltyBps)
        ) revert RateAboveSigned();
        // SignatureChecker: ECDSA via tryRecover (no address(0) match) or ERC-1271 for contract wallets.
        if (!SignatureChecker.isValidSignatureNow(o.seller, h, sig)) revert BadSellerSig();
    }

    function _finishPurchase(uint256 spent, uint256 tip) internal {
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
            _beforeSale(collection, id, bidder, price, 0);
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

    /// The co-signer can only allow or refuse fills of what sellers signed; 0 stops all signed fills.
    function setCosigner(address cosigner_) external onlyOwner {
        cosigner = cosigner_;
        emit CosignerSet(cosigner_);
    }

    function setFlagger(address flagger_) external onlyOwner {
        flagger = flagger_;
        emit FlaggerSet(flagger_);
    }

    /// Bounds keep the band honest: it always opens fully within 20 days of no fills (fall ≥ 5%/day),
    /// and the backstop never refuses more than half the band's low end.
    function setFloorParams(uint16 fallBpsPerDay, uint32 riseBpsPerDay, uint16 backstopBps) external onlyOwner {
        _setFloorParams(fallBpsPerDay, riseBpsPerDay, backstopBps);
    }

    /// One-time seed of a collection's floor reference (otherwise the first signed fill seeds it).
    function seedFloorRef(address collection, uint128 ref) external onlyOwner {
        if (floorRefs[collection].ref != 0) revert RefAlreadySet();
        if (ref == 0) revert BadPrice();
        floorRefs[collection] = FloorRef(ref, uint40(block.timestamp));
        emit FloorRefUpdated(collection, ref);
    }

    /// Flag a token (or update its claimant), or clear it (flagged = false). A token already held keeps
    /// its hold; only clearing lifts it.
    function setFlag(address collection, uint256 tokenId, bool flagged, address claimant) external {
        if (msg.sender != flagger) revert NotFlagger();
        Flag storage fl = flags[collection][tokenId];
        if (!flagged) {
            delete flags[collection][tokenId];
        } else {
            if (fl.state == 0) fl.state = FLAG_FLAGGED;
            fl.claimant = claimant;
        }
        emit FlagSet(collection, tokenId, fl.state, fl.claimant, fl.paid);
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

    /// Called before every sale (listing, signed order, offer), before the NFT moves. Enforces flags
    /// (nftprof 2026-11-07): a flagged token sells only as a signed order whose buyer acknowledged the
    /// warning; that purchase holds it (no resale) unless the co-signer marked the buyer high-reputation.
    /// The claimant may always buy it back at no more than max(paid, floor ref), which clears it.
    function _beforeSale(address collection, uint256 tokenId, address buyer, uint256 price, uint256 how) internal {
        Flag storage fl = flags[collection][tokenId];
        uint8 state = fl.state;
        if (state == 0) return;
        if (buyer == fl.claimant) {
            uint256 ref = floorRefs[collection].ref;
            if (price > (fl.paid > ref ? fl.paid : ref)) revert AboveClaimantPrice();
            delete flags[collection][tokenId];
        } else if (state == FLAG_HELD) {
            revert TokenHeld();
        } else if (how & (SALE_SIGNED | SALE_ACK) != (SALE_SIGNED | SALE_ACK)) {
            revert TokenFlagged();
        } else if (how & SALE_CLEAR != 0) {
            delete flags[collection][tokenId];
        } else {
            fl.state = FLAG_HELD;
            fl.paid = uint96(price);
        }
        emit FlagSet(collection, tokenId, fl.state, fl.claimant, fl.paid);
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

    function _setFloorParams(uint16 fallBpsPerDay, uint32 riseBpsPerDay, uint16 backstopBps) internal {
        if (fallBpsPerDay < 500 || fallBpsPerDay > 5000 || riseBpsPerDay < 500 || riseBpsPerDay > 100_000 || backstopBps > 5000) {
            revert BpsTooHigh();
        }
        floorFallBpsPerDay = fallBpsPerDay;
        floorRiseBpsPerDay = riseBpsPerDay;
        floorBackstopBps = backstopBps;
        emit FloorParamsSet(fallBpsPerDay, riseBpsPerDay, backstopBps);
    }

    function _setDefaultRoyalty(uint16 bps) internal {
        if (bps > MAX_ROYALTY_BPS) revert BpsTooHigh();
        defaultRoyaltyBps = bps;
        emit DefaultRoyaltySet(bps);
    }

}
