// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {PentagonMarketplaceV3 as M} from "../src/MarketplaceV3.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// Stateful fuzz (invariant) tests and stateless fuzz tests for PentagonMarketplaceV3.
///
/// The Handler drives random actors through every external function (trading and owner powers), keeps an
/// independent model of what the contract SHOULD hold, and after every marketplace call checks:
///   - every tracked address's (balance + pendingPayouts) moved by exactly what the rules say, and nobody
///     else (including the owner) received anything;
///   - every NFT that changed hands did so as part of an expected sale, from the seller, to the buyer/bidder,
///     in the offer's / listing's own collection.
/// Anything unexpected is recorded as a violation and fails invariant_noHandlerViolations.
///
/// Signed listings (be39502, c491f88): sellers sign EIP-712 orders (fixed price, time ramps, floor-following
/// rules; everyone / named wallets / co-signer audiences), buyers fill them with a co-signer FillAuth, the
/// flagger flags tokens. For every signed fill the model decides beforehand whether it must succeed, and
/// both directions are violations: a fill the rules refuse that goes through, and a fill the rules allow
/// that reverts.
///
/// Run (high effort, used for docs/AUDIT-SELF-REVIEW.md):
///   FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=200 FOUNDRY_FUZZ_RUNS=20000 \
///     forge test --match-path test/MarketplaceV3.invariant.t.sol

contract InvNFT is ERC721 {
    address public owner; // what the marketplace's self-serve royalty reads as the collection's creator

    constructor(string memory n) ERC721(n, n) {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setOwner(address o) external {
        owner = o;
    }
}

/// Self-serve creator royalties (registerRoyaltyAsCreator / setSelfServeBlocked) landed in cbc2d8f, while
/// this file was being written. They are reached with low-level calls so the file also builds against the
/// earlier version (where the calls simply fail).
library SelfServe {
    function register(M m, address collection, address receiver, uint16 bps) internal returns (bool ok) {
        (ok,) = address(m).call(
            abi.encodeWithSignature("registerRoyaltyAsCreator(address,address,uint16)", collection, receiver, bps)
        );
    }

    function setBlocked(M m, address collection, bool blocked) internal returns (bool ok) {
        (ok,) = address(m).call(abi.encodeWithSignature("setSelfServeBlocked(address,bool)", collection, blocked));
    }

    function supported(M m) internal view returns (bool) {
        // probe with a contract that has owner() (the marketplace itself); see F-7 for why not address(0)
        (bool ok,) = address(m).staticcall(abi.encodeWithSignature("collectionOwner(address)", address(m)));
        return ok;
    }
}

/// A smart wallet whose receive() can accept, reject, run out of gas under the push limit, or try to
/// re-enter the marketplace.
contract TrickyWallet {
    M public m;
    uint8 public mode; // 0 accept, 1 reject, 2 heavy (OOG with <= 60k gas, ok with more), 3 re-enter then accept
    bool public reentryWorked;

    constructor(M m_) {
        m = m_;
    }

    function setMode(uint8 x) external {
        mode = x;
    }

    address public signer; // ERC-1271: a signature by this key counts as the wallet's own

    function setSigner(address s) external {
        signer = s;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        address rec = ecrecover(hash, uint8(sig[64]), bytes32(sig[0:32]), bytes32(sig[32:64]));
        return rec != address(0) && rec == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    receive() external payable {
        uint8 md = mode;
        if (md == 1) revert("rejecting");
        if (md == 2 && gasleft() <= 60_000) {
            while (true) {} // burns the push stipend -> payout deferred
        }
        if (md == 3) {
            try m.withdraw() {
                reentryWorked = true;
            } catch {}
            try m.cancelOffer(1) {
                reentryWorked = true;
            } catch {}
            try m.incrementNonce() {} catch {} // allowed: not guarded, only affects this wallet's listings
            try m.buySigned(new M.SignedBuy[](0), 0) {
                reentryWorked = true;
            } catch {}
        }
    }
}

contract Handler is Test {
    M public m;
    address public owner;
    InvNFT[3] internal nfts; // 0 and 1 allowed at start, 2 not
    address[] internal actors;
    TrickyWallet[] internal wallets;
    address[] internal jars; // tip-jar candidates
    address[] internal receivers;
    address[] public tracked;
    uint256 internal constant TOKENS = 6;

    // ── independent model of owner settings ──
    uint16 public gFee = 250;
    uint16 public gDefRoy = 250;
    mapping(address => uint256) public gFloorFund; // model of floorFundOf (fees only, since 52655e7)
    mapping(address => uint256) public gRoyFund; // model of royaltyFundOf (unregistered royalties)
    mapping(address => uint256) public gAllowance; // model of creatorAllowance
    mapping(address => uint256) public gAllowanceSet; // value of the last setCreatorAllowance
    mapping(address => uint256) public gCreatorTaken; // creator withdrawals since that set
    mapping(address => address) public gHolder; // model of creatorAllowanceHolder (owner() at grant time)
    uint256 public badAllowanceSpends; // creator spends by anyone but the holder-while-owner() (must stay 0)
    address public gTipJar;
    mapping(address => mapping(uint256 => address)) internal gPriv; // model of privateBuyer
    bool public gPaused;
    mapping(address => bool) public gAllowed;
    mapping(address => address) public gRegRecv;
    mapping(address => uint16) public gRegBps;
    mapping(address => bool) public gBlocked;
    bool public selfServe;
    address public gGuardian;

    // ── signed listings, the floor reference and flags (be39502, c491f88) ──
    bytes32 internal constant ORDER_TYPEHASH_ = keccak256(
        "Order(address seller,address collection,uint256 tokenId,uint96 startPrice,uint96 endPrice,uint40 rampStart,uint40 rampEnd,uint128 floorRef,uint16 upBps,uint16 downBps,uint96 priceMin,uint96 priceMax,bytes32 audience,uint8 audienceKind,uint16 feeBps,uint16 royaltyBps,bool acceptFeeChanges,uint64 nonce,uint40 start,uint40 expiry,uint256 salt)"
    );
    bytes32 internal constant FILL_AUTH_TYPEHASH_ =
        keccak256("FillAuth(bytes32 orderHash,address buyer,uint128 floor,uint40 deadline,bool flagAck,bool clearFlag)");

    struct SO {
        M.Order o;
        bytes32 h; // its EIP-712 digest, and its id in orderStatus
        address namedA; // AUDIENCE_NAMED: the wallets in the order's Merkle root
        address namedB; // 0 = one wallet only
    }

    struct GF {
        uint8 state; // 1 flagged, 2 held
        uint96 paid;
        address claimant;
    }

    uint256 internal constant SO_MAX = 16;
    SO[] internal orders; // the last SO_MAX orders signed (a ring)
    uint256 internal soNext;
    uint256 internal saltCounter;
    mapping(address => uint256) internal keyOf; // each actor's signing key (smart wallets: their ERC-1271 signer's)
    uint256[2] internal csKeys;
    address[2] internal csAddrs;
    address[2] internal flaggers;
    uint256 internal strangerKey;
    address public gCosigner;
    address public gFlagger;
    uint16 public gFall = 2000;
    uint32 public gRise = 5000;
    uint16 public gBackstop = 1000;
    mapping(address => uint256) public gRef; // model of floorRefs[c].ref
    mapping(address => uint256) public gRefAt; // and of .updatedAt
    mapping(address => mapping(uint256 => GF)) internal gFlag; // model of flags
    mapping(address => mapping(bytes32 => uint8)) public gOS; // model of orderStatus (1 filled, 2 cancelled)

    // ── model of listings / offers ──
    struct GL {
        address seller;
        uint96 price;
        uint40 expiry;
        uint64 nonce;
        uint16 feeBps;
        uint16 royaltyBps;
    }

    struct GO {
        address bidder;
        uint96 price;
        address collection;
        uint40 expiry;
        uint16 feeBps;
        uint16 royaltyBps;
        uint16 remaining;
        bytes32 root;
        uint256 idA;
        uint256 idB;
        uint8 kind; // 0 any, 1 single token, 2 two tokens
    }

    mapping(address => mapping(uint256 => GL)) internal gl;
    mapping(uint256 => GO) internal go;
    uint256 public ghostEscrow;

    string[] public violations;
    mapping(bytes32 => uint256) public calls;
    bytes32[] public callKeys;

    // per-call expectation scratch
    int256[] internal _pre;
    address[] internal _preOwn;
    address[] internal _eAddr;
    int256[] internal _eAmt;

    struct Move {
        address c;
        uint256 id;
        address from;
        address to;
    }

    Move[] internal _moves;
    uint256 internal _vBefore;
    uint256[3] internal _preFloor;
    int256[3] internal _eFloor;
    uint256[3] internal _preRoy;
    int256[3] internal _eRoyFund;

    constructor() {
        owner = makeAddr("owner");
        address t1 = makeAddr("tipJar1");
        m = new M(owner, t1, 250, 250);
        gTipJar = t1;
        for (uint256 i; i < 3; ++i) {
            nfts[i] = new InvNFT(string(abi.encodePacked("C", vm.toString(i))));
        }
        for (uint256 i; i < 5; ++i) {
            wallets.push(new TrickyWallet(m));
        }
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(address(wallets[0]));
        actors.push(address(wallets[1]));
        jars.push(t1);
        jars.push(makeAddr("tipJar2"));
        jars.push(address(wallets[2]));
        receivers.push(makeAddr("creator"));
        receivers.push(address(wallets[4]));

        vm.startPrank(owner);
        m.setCollectionAllowed(address(nfts[0]), true);
        m.setCollectionAllowed(address(nfts[1]), true);
        vm.stopPrank();
        gAllowed[address(nfts[0])] = true;
        gAllowed[address(nfts[1])] = true;
        selfServe = SelfServe.supported(m);
        nfts[0].setOwner(receivers[0]); // a creator EOA
        nfts[1].setOwner(receivers[1]); // a creator smart wallet
        nfts[2].setOwner(actors[0]); // a trader who is also the creator

        for (uint256 c; c < 3; ++c) {
            for (uint256 id = 1; id <= TOKENS; ++id) {
                nfts[c].mint(actors[(id + c) % actors.length], id);
            }
            for (uint256 a; a < actors.length; ++a) {
                vm.prank(actors[a]);
                nfts[c].setApprovalForAll(address(m), true);
            }
        }
        for (uint256 i; i < actors.length; ++i) tracked.push(actors[i]);
        for (uint256 i; i < jars.length; ++i) tracked.push(jars[i]);
        tracked.push(address(wallets[3])); // a spare smart wallet (was the floor-fund wallet before 1049d1f)
        for (uint256 i; i < receivers.length; ++i) tracked.push(receivers[i]);
        tracked.push(owner);
        tracked.push(makeAddr("stranger"));

        // signed listings: every actor can sign (the smart wallets through ERC-1271); a co-signer and a
        // flagger are set
        string[3] memory names = ["alice", "bob", "carol"];
        for (uint256 i; i < 3; ++i) {
            keyOf[actors[i]] = uint256(keccak256(abi.encodePacked(names[i])));
            require(vm.addr(keyOf[actors[i]]) == actors[i], "actor key");
        }
        uint256 wk = uint256(keccak256("walletSigner"));
        for (uint256 i; i < 2; ++i) {
            wallets[i].setSigner(vm.addr(wk));
            keyOf[address(wallets[i])] = wk;
            csKeys[i] = uint256(keccak256(abi.encodePacked("cosigner", i)));
            csAddrs[i] = vm.addr(csKeys[i]);
        }
        flaggers[0] = makeAddr("flaggerA");
        flaggers[1] = makeAddr("flaggerB");
        strangerKey = uint256(keccak256("strangerKey"));
        vm.startPrank(owner);
        m.setCosigner(csAddrs[0]);
        m.setFlagger(flaggers[0]);
        vm.stopPrank();
        gCosigner = csAddrs[0];
        gFlagger = flaggers[0];
    }

    // ───────────────────────────── views for the test contract ─────────────────────────────

    function trackedLength() external view returns (uint256) {
        return tracked.length;
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    function callKeyCount() external view returns (uint256) {
        return callKeys.length;
    }

    function nft(uint256 i) external view returns (address) {
        return address(nfts[i]);
    }

    function wallet(uint256 i) external view returns (address) {
        return address(wallets[i]);
    }

    function ghostListing(address c, uint256 id) external view returns (GL memory) {
        return gl[c][id];
    }

    function ghostPrivate(address c, uint256 id) external view returns (address) {
        return gPriv[c][id];
    }

    function ghostOffer(uint256 id) external view returns (GO memory) {
        return go[id];
    }

    function ghostFlag(address c, uint256 id) external view returns (GF memory) {
        return gFlag[c][id];
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _count(bytes32 k) internal {
        if (calls[k] == 0) callKeys.push(k);
        ++calls[k];
    }

    function _v(string memory s) internal {
        violations.push(s);
    }

    function _val(address a) internal view returns (int256) {
        return int256(a.balance + m.pendingPayouts(a));
    }

    function _leaf(uint256 id) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id))));
    }

    function _hashPair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encode(x, y)) : keccak256(abi.encode(y, x));
    }

    /// Expect a royalty: pushed to the registered receiver, or (unregistered) held in royaltyFundOf[c].
    function _expRoy(address c, uint256 roy) internal {
        if (gRegRecv[c] != address(0)) {
            _exp(gRegRecv[c], int256(roy));
        } else {
            _eRoyFund[_ci(c)] += int256(roy);
        }
    }

    function _ci(address c) internal view returns (uint256) {
        for (uint256 i; i < 3; ++i) {
            if (address(nfts[i]) == c) return i;
        }
        revert("unknown collection");
    }

    function _royBps(address c) internal view returns (uint16) {
        return gRegRecv[c] != address(0) ? gRegBps[c] : gDefRoy;
    }

    /// Royalty a sale pays (R1): the lower of the rate frozen into the order and today's rate.
    function _settleRoy(address c, uint256 price, uint16 frozenBps) internal view returns (uint256) {
        uint16 cur = _royBps(c);
        return (price * (cur < frozenBps ? cur : frozenBps)) / 10_000;
    }

    // seller floor: the least each seller must net, from the royalty rate frozen into their orders
    address[] internal _sfAddr;
    uint256[] internal _sfMin;

    function _sellerFloor(address seller, uint256 minAmount) internal {
        for (uint256 i; i < _sfAddr.length; ++i) {
            if (_sfAddr[i] == seller) {
                _sfMin[i] += minAmount;
                return;
            }
        }
        _sfAddr.push(seller);
        _sfMin.push(minAmount);
    }

    /// Independent of the exact payout model: no seller ever nets less than price - price * frozenBps,
    /// i.e. never pays more royalty than the rate frozen into their listing / the offer they filled.
    function _checkSellerFloors(bool ok, string memory tag) internal {
        if (ok) {
            for (uint256 i; i < _sfAddr.length; ++i) {
                for (uint256 k; k < tracked.length; ++k) {
                    if (tracked[k] != _sfAddr[i]) continue;
                    if (_val(tracked[k]) - _pre[k] < int256(_sfMin[i])) {
                        _v(string.concat(tag, ": seller paid more royalty than the frozen rate"));
                    }
                }
            }
        }
        delete _sfAddr;
        delete _sfMin;
    }

    function _liveModel(address c, uint256 id, GL memory l) internal view returns (bool) {
        if (l.seller == address(0) || !gAllowed[c]) return false; // R2: disallowed collection = stale
        if (l.expiry < block.timestamp || l.nonce != m.sellerNonce(l.seller)) return false;
        if (InvNFT(c).ownerOf(id) != l.seller) return false;
        return InvNFT(c).isApprovedForAll(l.seller, address(m)) || InvNFT(c).getApproved(id) == address(m);
    }

    function _begin() internal {
        _vBefore = violations.length;
        delete _eAddr;
        delete _eAmt;
        delete _moves;
        delete _pre;
        delete _preOwn;
        for (uint256 i; i < tracked.length; ++i) {
            _pre.push(_val(tracked[i]));
        }
        for (uint256 c; c < 3; ++c) {
            _preFloor[c] = m.floorFundOf(address(nfts[c]));
            _eFloor[c] = 0;
            _preRoy[c] = m.royaltyFundOf(address(nfts[c]));
            _eRoyFund[c] = 0;
        }
        for (uint256 c; c < 3; ++c) {
            for (uint256 id = 1; id <= TOKENS; ++id) {
                _preOwn.push(nfts[c].ownerOf(id));
            }
        }
    }

    function _exp(address a, int256 x) internal {
        for (uint256 i; i < _eAddr.length; ++i) {
            if (_eAddr[i] == a) {
                _eAmt[i] += x;
                return;
            }
        }
        _eAddr.push(a);
        _eAmt.push(x);
    }

    function _move(address c, uint256 id, address from, address to) internal {
        _moves.push(Move(c, id, from, to));
    }

    function _expected(address a) internal view returns (int256) {
        for (uint256 i; i < _eAddr.length; ++i) {
            if (_eAddr[i] == a) return _eAmt[i];
        }
        return 0;
    }

    function _isTracked(address a) internal view returns (bool) {
        for (uint256 i; i < tracked.length; ++i) {
            if (tracked[i] == a) return true;
        }
        return false;
    }

    /// Check that money and NFTs moved exactly as expected (or not at all if the call reverted).
    function _end(bool ok, string memory tag) internal {
        if (!ok) {
            delete _eAddr;
            delete _eAmt;
            delete _moves;
        }
        for (uint256 i; i < _eAddr.length; ++i) {
            if (_eAmt[i] != 0 && !_isTracked(_eAddr[i])) {
                _v(string.concat(tag, ": value expected for untracked ", vm.toString(_eAddr[i])));
            }
        }
        for (uint256 i; i < tracked.length; ++i) {
            int256 d = _val(tracked[i]) - _pre[i];
            int256 e = _expected(tracked[i]);
            if (d != e) {
                _v(
                    string.concat(
                        tag,
                        ": value delta of ",
                        vm.toString(tracked[i]),
                        " is ",
                        vm.toString(d),
                        " expected ",
                        vm.toString(e)
                    )
                );
            }
        }
        uint256 matched;
        for (uint256 c; c < 3; ++c) {
            for (uint256 id = 1; id <= TOKENS; ++id) {
                address before = _preOwn[c * TOKENS + id - 1];
                address now_ = nfts[c].ownerOf(id);
                if (before == now_) continue;
                bool found;
                for (uint256 k; k < _moves.length; ++k) {
                    Move memory mv = _moves[k];
                    if (mv.c == address(nfts[c]) && mv.id == id && mv.from == before && mv.to == now_) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    _v(string.concat(tag, ": unexpected NFT move c", vm.toString(c), " #", vm.toString(id)));
                } else {
                    ++matched;
                }
            }
        }
        if (ok && matched != _moves.length) _v(string.concat(tag, ": expected NFT move did not happen"));
        // Floor funds: change exactly as expected. Only withdrawFloorFund ever expects a decrease, so this
        // also proves floor funds never leave any other way.
        for (uint256 c; c < 3; ++c) {
            int256 e = ok ? _eFloor[c] : int256(0);
            int256 d = int256(m.floorFundOf(address(nfts[c]))) - int256(_preFloor[c]);
            if (d != e) _v(string.concat(tag, ": floorFundOf changed unexpectedly, c", vm.toString(c)));
            if (d < 0 && keccak256(bytes(tag)) != keccak256("withdrawFloorFund")) {
                _v(string.concat(tag, ": floor fund left other than via withdrawFloorFund"));
            }
            if (ok) {
                gFloorFund[address(nfts[c])] = uint256(int256(gFloorFund[address(nfts[c])]) + e);
            }
            // Royalty funds: same, and only withdrawRoyaltyFund may lower them.
            int256 er = ok ? _eRoyFund[c] : int256(0);
            int256 dr = int256(m.royaltyFundOf(address(nfts[c]))) - int256(_preRoy[c]);
            if (dr != er) _v(string.concat(tag, ": royaltyFundOf changed unexpectedly, c", vm.toString(c)));
            if (dr < 0 && keccak256(bytes(tag)) != keccak256("withdrawRoyaltyFund")) {
                _v(string.concat(tag, ": royalty fund left other than via withdrawRoyaltyFund"));
            }
            if (ok) {
                gRoyFund[address(nfts[c])] = uint256(int256(gRoyFund[address(nfts[c])]) + er);
            }
        }
        _count(keccak256(abi.encodePacked(tag, ok ? ".ok" : ".revert")));
        // A call the marketplace rejected (and that broke nothing) reverts the handler call too, so forge's
        // per-selector "Reverts" column counts rejected calls and Calls - Reverts counts successful ones.
        if (!ok && violations.length == _vBefore) revert("marketplace rejected the call");
    }

    // ───────────────────────────── trading actions ─────────────────────────────

    function list(uint256 cSeed, uint256 idSeed, uint256 price, uint256 dur, uint8 mode) external {
        address c = address(nfts[cSeed % 3]);
        if (!gAllowed[c] && mode % 4 != 0) {
            for (uint256 k = 1; k < 3; ++k) {
                if (gAllowed[address(nfts[(cSeed + k) % 3])]) {
                    c = address(nfts[(cSeed + k) % 3]);
                    break;
                }
            }
        }
        uint256 id = idSeed % TOKENS + 1;
        address seller = InvNFT(c).ownerOf(id);
        if (mode % 4 != 0 && !InvNFT(c).isApprovedForAll(seller, address(m))) {
            vm.prank(seller); // most sellers approve before listing (as the UI makes them)
            InvNFT(c).setApprovalForAll(address(m), true);
        }
        price = bound(price, 1, 50 ether);
        dur = bound(dur, 1, 180 days);
        bool mustFail;
        if (mode % 13 == 1) {
            dur = 180 days + 1;
            mustFail = true;
        }
        if (mode % 13 == 2) {
            seller = actors[(mode / 13) % actors.length]; // maybe not the owner
            mustFail = InvNFT(c).ownerOf(id) != seller;
        }
        uint64 nonce = m.sellerNonce(seller);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        ids[0] = id;
        prices[0] = price;
        _begin();
        bool ok;
        vm.prank(seller);
        try m.list(c, ids, prices, block.timestamp + dur) {
            ok = true;
        } catch {}
        if (ok) {
            if (mustFail) _v("list: should have reverted");
            if (gPaused) _v("list: while paused");
            if (!gAllowed[c]) _v("list: collection not allowed");
            gl[c][id] = GL(seller, uint96(price), uint40(block.timestamp + dur), nonce, gFee, _royBps(c));
            delete gPriv[c][id]; // a public relist makes it public
        }
        _end(ok, "list");
    }

    /// Free person-to-person listing: only `buyer` may buy; fee and royalty are 0.
    function listPrivate(uint256 cSeed, uint256 idSeed, uint256 price, uint256 dur, uint256 buyerSeed, uint8 mode)
        external
    {
        address c = address(nfts[cSeed % 3]);
        if (!gAllowed[c] && mode % 4 != 0) {
            for (uint256 k = 1; k < 3; ++k) {
                if (gAllowed[address(nfts[(cSeed + k) % 3])]) {
                    c = address(nfts[(cSeed + k) % 3]);
                    break;
                }
            }
        }
        uint256 id = idSeed % TOKENS + 1;
        address seller = InvNFT(c).ownerOf(id);
        if (mode % 4 != 0 && !InvNFT(c).isApprovedForAll(seller, address(m))) {
            vm.prank(seller);
            InvNFT(c).setApprovalForAll(address(m), true);
        }
        address buyer = actors[buyerSeed % actors.length];
        price = bound(price, 1, 50 ether);
        dur = bound(dur, 1, 180 days);
        bool mustFail = buyer == seller; // SelfTrade
        if (mode % 11 == 1) {
            buyer = address(0);
            mustFail = true;
        }
        uint64 nonce = m.sellerNonce(seller);
        _begin();
        bool ok;
        vm.prank(seller);
        try m.listPrivate(c, id, price, buyer, block.timestamp + dur) {
            ok = true;
        } catch {}
        if (ok) {
            if (mustFail) _v("listPrivate: should have reverted");
            if (gPaused) _v("listPrivate: while paused");
            if (!gAllowed[c]) _v("listPrivate: collection not allowed");
            gl[c][id] = GL(seller, uint96(price), uint40(block.timestamp + dur), nonce, 0, 0);
            gPriv[c][id] = buyer;
        }
        _end(ok, "listPrivate");
    }

    function delist(uint256 aSeed, uint256 cSeed, uint256 idSeed) external {
        address who = actors[aSeed % actors.length];
        address c = address(nfts[cSeed % 3]);
        uint256 id = idSeed % TOKENS + 1;
        if (aSeed % 2 == 0 && gl[c][id].seller != address(0)) who = gl[c][id].seller;
        _begin();
        bool ok;
        vm.prank(who);
        try m.delist(c, _one(id)) {
            ok = true;
        } catch {}
        if (ok) {
            if (gl[c][id].seller != who) _v("delist: non-seller removed a listing");
            _clearListing(c, id);
        }
        _end(ok, "delist");
    }

    function incrementNonce(uint256 aSeed) external {
        address who = actors[aSeed % actors.length];
        _begin();
        vm.prank(who);
        m.incrementNonce();
        _end(true, "incrementNonce");
    }

    function clearStale(uint256 cSeed, uint256 idSeed) external {
        address c = address(nfts[cSeed % 3]);
        uint256 id = idSeed % TOKENS + 1;
        GL memory l = gl[c][id];
        bool live = _liveModel(c, id, l);
        _begin();
        bool ok;
        try m.clearStale(c, _one(id)) {
            ok = true;
        } catch {}
        if (ok) {
            (address sellerAfter,,,,,) = m.listings(c, id);
            bool removed = l.seller != address(0) && sellerAfter == address(0);
            if (live && removed) _v("clearStale: removed a live listing");
            if (l.seller != address(0) && !live && !removed) _v("clearStale: left a stale listing");
            if (removed) _clearListing(c, id);
        } else {
            _v("clearStale: reverted");
        }
        _end(ok, "clearStale");
    }

    struct BuyCtx {
        address buyer;
        uint256 total;
        uint256 value;
        uint256 tip;
        bool mustFail;
        bool ok;
    }

    function buy(uint256 buyerSeed, uint256 pick, uint8 n, uint256 overpay, uint8 mode, uint256 tipSeed) external {
        uint256[18] memory slots;
        uint256 cnt;
        for (uint256 c; c < 3; ++c) {
            for (uint256 id = 1; id <= TOKENS; ++id) {
                GL memory g = gl[address(nfts[c])][id];
                if (g.seller == address(0)) continue;
                // mostly aim at listings that should be buyable; sometimes at any listing (stale ones too)
                if (mode % 5 != 0 && !_liveModel(address(nfts[c]), id, g)) continue;
                slots[cnt++] = c * TOKENS + id - 1;
            }
        }
        n = uint8(bound(n, 1, 3));
        if (cnt > 0 && n > cnt && mode % 7 != 0) n = uint8(cnt); // distinct items, except sometimes (duplicates must revert)
        BuyCtx memory x;
        x.buyer = actors[buyerSeed % actors.length];
        M.BuyItem[] memory items = new M.BuyItem[](n);
        GL[] memory ls = new GL[](n);
        uint64[] memory nonces = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(pick, i)));
            uint256 s = cnt == 0 ? r % 18 : mode % 7 == 0 ? slots[r % cnt] : slots[(pick + i) % cnt];
            address c = address(nfts[s / TOKENS]);
            uint256 id = s % TOKENS + 1;
            ls[i] = gl[c][id];
            nonces[i] = m.sellerNonce(ls[i].seller);
            uint256 maxP = ls[i].price;
            if (mode % 10 == 1 && i == 0 && maxP > 0) {
                maxP -= 1; // listing is dearer than the buyer saw
                x.mustFail = true;
            }
            items[i] = M.BuyItem(c, id, maxP);
            x.total += uint256(ls[i].price) + (uint256(ls[i].price) * ls[i].feeBps) / 10_000;
        }
        // a private listing's named buyer usually buys it; anyone else must be refused
        address pb0 = gPriv[items[0].collection][items[0].tokenId];
        if (pb0 != address(0) && mode % 3 != 0) x.buyer = pb0;
        {
            // a flagged token's claimant sometimes buys it back through its on-chain listing
            GF memory f0 = gFlag[items[0].collection][items[0].tokenId];
            if (f0.state != 0 && f0.claimant != address(0) && pb0 == address(0) && mode % 4 == 1) x.buyer = f0.claimant;
        }
        if (mode % 11 == 2 && ls[0].seller != address(0)) {
            x.buyer = ls[0].seller; // self-trade attempt
            x.mustFail = true;
        }
        for (uint256 i; i < n; ++i) {
            address pb = gPriv[items[i].collection][items[i].tokenId];
            if (pb != address(0) && pb != x.buyer) x.mustFail = true;
        }
        uint256 maxTip = (x.total * 500) / 10_000;
        x.tip = tipSeed % 3 == 0 ? 0 : bound(tipSeed, 0, maxTip);
        if (mode % 17 == 4) {
            x.tip = maxTip + 1; // over the 5% cap
            x.mustFail = true;
        }
        x.value = x.total + x.tip + bound(overpay, 0, 2 ether);
        if (mode % 13 == 3 && x.total + x.tip > 0) {
            x.value = x.total + x.tip - 1;
            x.mustFail = true;
        }
        vm.deal(x.buyer, x.buyer.balance + x.value);
        _begin();
        for (uint256 i; i < n; ++i) {
            uint256 fee = (uint256(ls[i].price) * ls[i].feeBps) / 10_000;
            uint256 roy = _settleRoy(items[i].collection, ls[i].price, ls[i].royaltyBps);
            _sellerFloor(ls[i].seller, uint256(ls[i].price) - (uint256(ls[i].price) * ls[i].royaltyBps) / 10_000);
            _eFloor[_ci(items[i].collection)] += int256(fee); // the fee goes to the collection's floor fund
            _expRoy(items[i].collection, roy);
            _exp(ls[i].seller, int256(uint256(ls[i].price) - roy));
            _move(items[i].collection, items[i].tokenId, ls[i].seller, x.buyer);
        }
        _exp(x.buyer, -int256(x.total + x.tip));
        _exp(gTipJar, int256(x.tip)); // the tip goes to the tip jar and nowhere else
        vm.prank(x.buyer);
        try m.buy{value: x.value}(items, x.tip) {
            x.ok = true;
        } catch {}
        if (x.ok) {
            if (x.mustFail) _v("buy: should have reverted");
            if (gPaused) _v("buy: while paused");
            uint256 maxPaid;
            for (uint256 i; i < n; ++i) {
                GL memory l = ls[i];
                if (l.seller == address(0)) _v("buy: bought a token with no listing");
                if (l.seller == x.buyer) _v("buy: self-trade");
                if (l.expiry < block.timestamp) _v("buy: expired listing");
                if (l.nonce != nonces[i]) _v("buy: cancelled (nonce) listing");
                if (!gAllowed[items[i].collection]) _v("buy: collection not allowed");
                if (l.price > items[i].maxPrice) _v("buy: price above maxPrice");
                if (l.feeBps > m.MAX_FEE_BPS() || l.royaltyBps > m.MAX_ROYALTY_BPS()) _v("buy: bps over cap");
                _plainSaleFlag(items[i].collection, items[i].tokenId, x.buyer, l.price, "buy");
                maxPaid += items[i].maxPrice + (items[i].maxPrice * l.feeBps) / 10_000;
                address pb = gPriv[items[i].collection][items[i].tokenId];
                if (pb != address(0)) {
                    if (pb != x.buyer) _v("buy: someone other than the private buyer bought a private listing");
                    if (l.feeBps != 0 || l.royaltyBps != 0) _v("buy: private listing charged fee or royalty");
                }
                _clearListing(items[i].collection, items[i].tokenId);
            }
            if (x.total > maxPaid) _v("buy: paid more than maxPrice + frozen fee");
            if (x.tip * 10_000 > x.total * 500) _v("buy: tip above 5% of the items' cost");
        }
        _checkSellerFloors(x.ok, "buy");
        _end(x.ok, "buy");
    }

    struct OfferArgs {
        address bidder;
        address c;
        uint256 price;
        uint256 qty;
        uint256 dur;
        uint8 kind;
        uint256 idA;
        uint256 idB;
        bytes32 root;
        uint256 value;
        bool mustFail;
    }

    function placeOffer(uint256 bSeed, uint256 cSeed, uint256 price, uint256 qty, uint256 dur, uint256 shape, uint8 mode)
        external
    {
        OfferArgs memory a;
        a.bidder = actors[bSeed % actors.length];
        a.c = address(nfts[cSeed % 3]);
        a.price = bound(price, 1, 20 ether);
        a.qty = bound(qty, 1, 3);
        a.dur = bound(dur, 1, 180 days);
        a.kind = uint8(shape % 3);
        a.idA = (shape / 3) % TOKENS + 1;
        a.idB = (shape / 18) % TOKENS + 1;
        if (a.idB == a.idA) a.idB = a.idA % TOKENS + 1;
        a.root = a.kind == 0 ? bytes32(0) : a.kind == 1 ? _leaf(a.idA) : _hashPair(_leaf(a.idA), _leaf(a.idB));
        uint256 fee = (a.price * gFee) / 10_000;
        a.value = (a.price + fee) * a.qty;
        if (mode % 9 == 1) {
            a.value += 1;
            a.mustFail = true;
        }
        vm.deal(a.bidder, a.bidder.balance + a.value);
        _begin();
        _exp(a.bidder, -int256(a.value));
        bool ok;
        uint256 oid;
        vm.prank(a.bidder);
        try m.placeOffer{value: a.value}(a.c, a.price, a.qty, block.timestamp + a.dur, a.root) returns (uint256 r) {
            ok = true;
            oid = r;
        } catch {}
        if (ok) {
            if (a.mustFail) _v("placeOffer: should have reverted");
            if (gPaused) _v("placeOffer: while paused");
            if (!gAllowed[a.c]) _v("placeOffer: collection not allowed");
            go[oid] = GO(
                a.bidder,
                uint96(a.price),
                a.c,
                uint40(block.timestamp + a.dur),
                gFee,
                _royBps(a.c),
                uint16(a.qty),
                a.root,
                a.idA,
                a.idB,
                a.kind
            );
            ghostEscrow += a.value;
        }
        _end(ok, "placeOffer");
    }

    struct AcceptCtx {
        uint256 oid;
        address c;
        address seller;
        uint256[] ids;
        bytes32[][] proofs;
        bool mustFail;
        bool ok;
    }

    function acceptOffer(uint256 sSeed, uint256 oSeed, uint8 n, uint8 mode) external {
        uint256 oc = m.offerCount();
        if (oc == 0) return;
        AcceptCtx memory x;
        x.oid = bound(oSeed, 1, oc);
        GO memory o = go[x.oid];
        x.c = o.collection == address(0) ? address(nfts[sSeed % 3]) : o.collection;
        n = uint8(bound(n, 1, 2));
        if (o.kind == 1) {
            x.seller = InvNFT(x.c).ownerOf(o.idA);
            x.ids = _one(o.idA);
            x.proofs = new bytes32[][](1);
        } else if (o.kind == 2) {
            x.seller = InvNFT(x.c).ownerOf(o.idA);
            x.proofs = new bytes32[][](n);
            x.proofs[0] = _proof(_leaf(o.idB));
            if (n == 2) {
                x.ids = new uint256[](2);
                x.ids[0] = o.idA;
                x.ids[1] = o.idB;
                x.proofs[1] = _proof(_leaf(o.idA));
            } else {
                x.ids = _one(o.idA);
            }
        } else {
            x.seller = actors[sSeed % actors.length];
            uint256[] memory tmp = new uint256[](n);
            uint256 k;
            for (uint256 id = 1; id <= TOKENS && k < n; ++id) {
                if (InvNFT(x.c).ownerOf(id) == x.seller) tmp[k++] = id;
            }
            if (k == 0) tmp[k++] = sSeed % TOKENS + 1;
            x.ids = new uint256[](k);
            for (uint256 i; i < k; ++i) {
                x.ids[i] = tmp[i];
            }
            x.proofs = new bytes32[][](0);
        }
        if (mode % 7 == 1 && o.kind != 0) {
            // a token outside the offer's set, with a proof for a different token
            for (uint256 t = 1; t <= TOKENS; ++t) {
                if (t != o.idA && (o.kind == 1 || t != o.idB)) {
                    x.ids = _one(t);
                    x.proofs = new bytes32[][](1);
                    x.proofs[0] = _proof(_leaf(o.idA));
                    x.seller = InvNFT(x.c).ownerOf(t);
                    x.mustFail = true;
                    break;
                }
            }
        } else if (mode % 7 == 2 && o.bidder != address(0)) {
            x.seller = o.bidder; // self-trade attempt
            x.mustFail = true;
        } else if (mode % 7 == 3) {
            // the seller tries to fill with a token id they only own in a DIFFERENT collection
            address other = address(nfts[(sSeed / 7) % 3]);
            if (other != x.c) {
                for (uint256 t = 1; t <= TOKENS; ++t) {
                    address ow = InvNFT(other).ownerOf(t);
                    if (InvNFT(x.c).ownerOf(t) != ow) {
                        x.seller = ow;
                        x.ids = _one(t);
                        x.proofs = new bytes32[][](o.kind == 0 ? 0 : 1);
                        if (o.kind != 0) x.proofs[0] = _proof(_leaf(o.idA));
                        x.mustFail = true;
                        break;
                    }
                }
            }
        }
        uint256 fee = (uint256(o.price) * o.feeBps) / 10_000;
        uint256 roy = _settleRoy(x.c, o.price, o.royaltyBps);
        _begin();
        for (uint256 i; i < x.ids.length; ++i) {
            _sellerFloor(x.seller, uint256(o.price) - (uint256(o.price) * o.royaltyBps) / 10_000);
            _eFloor[_ci(x.c)] += int256(fee);
            _expRoy(x.c, roy);
            _exp(x.seller, int256(uint256(o.price) - roy));
            _move(x.c, x.ids[i], x.seller, o.bidder);
        }
        vm.prank(x.seller);
        try m.acceptOffer(x.oid, x.ids, x.proofs) {
            x.ok = true;
        } catch {}
        if (x.ok) {
            if (x.mustFail) _v("acceptOffer: should have reverted");
            if (gPaused) _v("acceptOffer: while paused");
            if (o.bidder == address(0)) _v("acceptOffer: filled a closed offer");
            if (o.expiry < block.timestamp) _v("acceptOffer: filled an expired offer");
            if (!gAllowed[x.c]) _v("acceptOffer: collection not allowed");
            if (x.seller == o.bidder) _v("acceptOffer: self-trade");
            if (x.ids.length > o.remaining) _v("acceptOffer: overfilled");
            for (uint256 i; i < x.ids.length; ++i) {
                if (o.kind != 0 && x.ids[i] != o.idA && (o.kind == 1 || x.ids[i] != o.idB)) {
                    _v("acceptOffer: token outside the offer's set");
                }
                _plainSaleFlag(x.c, x.ids[i], o.bidder, o.price, "acceptOffer");
                _clearListing(x.c, x.ids[i]);
            }
            go[x.oid].remaining -= uint16(x.ids.length);
            ghostEscrow -= (uint256(o.price) + fee) * x.ids.length;
            if (go[x.oid].remaining == 0) delete go[x.oid];
        }
        _checkSellerFloors(x.ok, "acceptOffer");
        _end(x.ok, "acceptOffer");
    }

    function cancelOffer(uint256 aSeed, uint256 oSeed) external {
        uint256 oc = m.offerCount();
        if (oc == 0) return;
        uint256 oid = bound(oSeed, 1, oc);
        GO memory o = go[oid];
        address who = (aSeed % 3 != 0 && o.bidder != address(0)) ? o.bidder : actors[aSeed % actors.length];
        uint256 refund = (uint256(o.price) + (uint256(o.price) * o.feeBps) / 10_000) * o.remaining;
        _begin();
        _exp(who, int256(refund));
        bool ok;
        vm.prank(who);
        try m.cancelOffer(oid) {
            ok = true;
        } catch {}
        if (ok) {
            if (who != o.bidder) _v("cancelOffer: non-bidder cancelled");
            ghostEscrow -= refund;
            delete go[oid];
        }
        _end(ok, "cancelOffer");
    }

    function withdraw(uint256 seed) external {
        address a = tracked[seed % tracked.length];
        if (seed % 3 != 0) {
            for (uint256 i; i < tracked.length; ++i) {
                address t = tracked[(seed + i) % tracked.length];
                if (m.pendingPayouts(t) > 0) {
                    a = t;
                    break;
                }
            }
        }
        _begin();
        bool ok;
        vm.prank(a);
        try m.withdraw() {
            ok = true;
        } catch {}
        if (ok && m.pendingPayouts(a) != 0) _v("withdraw: pending not cleared");
        _end(ok, "withdraw"); // balance + pending is unchanged by a withdraw
    }

    /// R3: anyone pushes a payee's held payout. Only the payee may gain: _end checks every tracked
    /// address's balance + pending is unchanged (the payee's just moves from pending to balance).
    function withdrawFor(uint256 callerSeed, uint256 payeeSeed) external {
        address caller = tracked[callerSeed % tracked.length];
        address payee = tracked[payeeSeed % tracked.length];
        if (payeeSeed % 3 != 0) {
            for (uint256 i; i < tracked.length; ++i) {
                address t = tracked[(payeeSeed + i) % tracked.length];
                if (m.pendingPayouts(t) > 0) {
                    payee = t;
                    break;
                }
            }
        }
        uint256 pending = m.pendingPayouts(payee);
        uint256 payeeBal = payee.balance;
        _begin();
        bool ok;
        vm.prank(caller);
        try m.withdrawFor(payee) {
            ok = true;
        } catch {}
        if (ok) {
            if (m.pendingPayouts(payee) != 0) _v("withdrawFor: pending not cleared");
            if (payee.balance != payeeBal + pending) _v("withdrawFor: payee not paid exactly its pending");
        }
        _end(ok, "withdrawFor");
    }

    // ───────────────────────────── environment actions ─────────────────────────────

    function transferNftOutside(uint256 cSeed, uint256 idSeed, uint256 toSeed) external {
        InvNFT c = nfts[cSeed % 3];
        uint256 id = idSeed % TOKENS + 1;
        address from = c.ownerOf(id);
        address to = actors[toSeed % actors.length];
        if (from == to) return;
        vm.prank(from);
        c.transferFrom(from, to, id);
        _count("transferNftOutside");
    }

    function setApproval(uint256 aSeed, uint256 cSeed, uint8 x) external {
        bool on = x % 4 != 0;
        vm.prank(actors[aSeed % actors.length]);
        nfts[cSeed % 3].setApprovalForAll(address(m), on);
        _count("setApproval");
    }

    function approveOne(uint256 cSeed, uint256 idSeed, bool toMarket) external {
        InvNFT c = nfts[cSeed % 3];
        uint256 id = idSeed % TOKENS + 1;
        vm.prank(c.ownerOf(id));
        c.approve(toMarket ? address(m) : address(0), id);
        _count("approveOne");
    }

    function setWalletMode(uint256 wSeed, uint8 md) external {
        wallets[wSeed % wallets.length].setMode(md % 4);
        _count("setWalletMode");
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + (dt % 8 == 0 ? bound(dt, 0, 200 days) : bound(dt, 0, 2 days)));
        _count("warp");
    }

    // ───────────────────────────── owner powers ─────────────────────────────

    function ownerSetFee(uint256 bps) external {
        bps = bound(bps, 0, 600);
        _begin();
        bool ok;
        vm.prank(owner);
        try m.setFee(uint16(bps)) {
            ok = true;
        } catch {}
        if (ok) {
            if (bps > 500) _v("setFee: above cap");
            gFee = uint16(bps);
        }
        _end(ok, "ownerSetFee");
    }

    function ownerSetDefaultRoyalty(uint256 bps) external {
        bps = bound(bps, 0, 1100);
        _begin();
        bool ok;
        vm.prank(owner);
        try m.setDefaultRoyalty(uint16(bps)) {
            ok = true;
        } catch {}
        if (ok) {
            if (bps > 1000) _v("setDefaultRoyalty: above cap");
            gDefRoy = uint16(bps);
        }
        _end(ok, "ownerSetDefaultRoyalty");
    }

    function ownerRegisterRoyalty(uint256 cSeed, uint256 rSeed, uint256 bps) external {
        address c = address(nfts[cSeed % 3]);
        address r = rSeed % 3 == 2 ? address(0) : receivers[rSeed % 2];
        bps = bound(bps, 0, 1100);
        _begin();
        bool ok;
        vm.prank(owner);
        try m.registerRoyalty(c, r, uint16(bps)) {
            ok = true;
        } catch {}
        if (ok) {
            if (bps > 1000) _v("registerRoyalty: above cap");
            gRegRecv[c] = r;
            gRegBps[c] = r == address(0) ? 0 : uint16(bps);
        }
        _end(ok, "ownerRegisterRoyalty");
    }

    /// renounceOwnership is disabled (F-5 fix): it must always revert, even for the owner.
    function ownerTriesRenounce() external {
        _begin();
        bool ok;
        vm.prank(owner);
        try m.renounceOwnership() {
            ok = true;
        } catch {}
        if (ok) _v("renounceOwnership: succeeded");
        _end(ok, "ownerTriesRenounce");
    }

    /// Someone (our owner, the collection's owner(), or a stranger) withdraws a collection's floor fund (the
    /// fees). Allowed since 52655e7: our owner only, to any non-zero wallet. A creator never can (F-14 fix).
    function withdrawFloorFund(uint256 callerSeed, uint256 cSeed, uint256 toSeed, uint256 amount) external {
        address c = address(nfts[cSeed % 3]);
        address cOwner = InvNFT(c).owner();
        uint256 k = callerSeed % 4;
        address caller = k == 0
            ? owner
            : (k == 1 && cOwner != address(0)) ? cOwner : tracked[(callerSeed / 4) % tracked.length];
        uint256 j = toSeed % 4;
        address to = j == 0
            ? owner
            : (j == 1 && cOwner != address(0)) ? cOwner : j == 2 ? caller : tracked[(toSeed / 4) % tracked.length];
        uint256 bal = gFloorFund[c];
        amount = bal == 0 ? bound(amount, 1, 1 ether) : bound(amount, 1, bal);
        if (toSeed % 9 == 0) amount = bal + 1; // more than held
        _begin();
        _exp(to, int256(amount));
        _eFloor[_ci(c)] = -int256(amount);
        bool ok;
        vm.prank(caller);
        try m.withdrawFloorFund(c, to, amount) {
            ok = true;
        } catch {}
        if (ok) {
            if (caller != owner) _v("withdrawFloorFund: someone other than our owner reduced floorFundOf");
            if (amount > bal) _v("withdrawFloorFund: withdrew more than the fund held");
        }
        _end(ok, "withdrawFloorFund");
    }

    /// Someone withdraws a collection's royalty fund (unregistered royalties). Allowed: our owner, to itself or
    /// the collection's owner(); or the collection's owner() while self-serve isn't blocked, up to its
    /// allowance, to the same two recipients.
    function withdrawRoyaltyFund(uint256 callerSeed, uint256 cSeed, uint256 toSeed, uint256 amount) external {
        address c = address(nfts[cSeed % 3]);
        address cOwner = InvNFT(c).owner();
        uint256 k = callerSeed % 5;
        address caller = k == 0
            ? owner
            : (k == 4 && gHolder[c] != address(0))
                ? gHolder[c] // the wallet the allowance was granted to, possibly no longer owner()
                : (k != 3 && cOwner != address(0)) ? cOwner : tracked[(callerSeed / 5) % tracked.length];
        uint256 j = toSeed % 4;
        address to = j == 0
            ? owner
            : (j == 1 && cOwner != address(0)) ? cOwner : j == 2 ? caller : tracked[(toSeed / 4) % tracked.length];
        uint256 bal = gRoyFund[c];
        uint256 allow = gAllowance[c];
        amount = bal == 0 ? bound(amount, 1, 1 ether) : bound(amount, 1, bal);
        if (toSeed % 7 == 0 && allow != type(uint256).max && allow < type(uint256).max - 1) amount = allow + 1; // over the allowance
        if (toSeed % 11 == 0) amount = bal + 1; // more than held
        bool callerOk = caller == owner
            || (cOwner != address(0) && caller == cOwner && caller == gHolder[c] && !gBlocked[c] && amount <= allow);
        bool toOk = to == owner || (cOwner != address(0) && to == cOwner);
        _begin();
        _exp(to, int256(amount));
        _eRoyFund[_ci(c)] = -int256(amount);
        bool ok;
        vm.prank(caller);
        try m.withdrawRoyaltyFund(c, to, amount) {
            ok = true;
        } catch {}
        if (ok) {
            if (!callerOk) _v("withdrawRoyaltyFund: a caller who may not withdraw did");
            if (!toOk) _v("withdrawRoyaltyFund: paid a recipient other than our owner / the collection owner");
            if (amount > bal) _v("withdrawRoyaltyFund: withdrew more than the fund held");
            if (caller != owner) {
                // F-15: only the wallet the allowance was granted to, while it is still owner(), may spend it
                if (caller != gHolder[c] || caller != cOwner) {
                    ++badAllowanceSpends;
                    _v("withdrawRoyaltyFund: allowance spent by someone other than its holder-while-owner()");
                }
                gCreatorTaken[c] += amount;
                if (allow != type(uint256).max) gAllowance[c] = allow - amount;
                if (gAllowanceSet[c] != type(uint256).max && gCreatorTaken[c] > gAllowanceSet[c]) {
                    _v("withdrawRoyaltyFund: creator took more than its allowance");
                }
            }
        }
        _end(ok, "withdrawRoyaltyFund");
    }

    function ownerSetCreatorAllowance(uint256 cSeed, uint256 amount) external {
        address c = address(nfts[cSeed % 3]);
        uint256 k = amount % 4;
        amount = k == 0 ? 0 : k == 1 ? type(uint256).max : bound(amount, 1, 2 ether);
        address holder = InvNFT(c).owner();
        bool mustFail = amount != 0 && holder == address(0); // NotCollectionOwner
        _begin();
        bool ok;
        vm.prank(owner);
        try m.setCreatorAllowance(c, amount) {
            ok = true;
        } catch {}
        if (ok) {
            if (mustFail) _v("setCreatorAllowance: granted an allowance to a collection with no owner()");
            gAllowance[c] = amount;
            gAllowanceSet[c] = amount;
            gCreatorTaken[c] = 0;
            gHolder[c] = holder;
        } else if (!mustFail) {
            _v("setCreatorAllowance: owner call reverted");
        }
        _end(ok, "ownerSetCreatorAllowance");
    }

    function ownerSetAllowed(uint256 cSeed, uint8 x) external {
        bool allowed = x % 3 != 0;
        address c = address(nfts[cSeed % 3]);
        _begin();
        vm.prank(owner);
        m.setCollectionAllowed(c, allowed);
        gAllowed[c] = allowed;
        _end(true, "ownerSetAllowed");
    }

    function ownerPause(uint8 x) external {
        bool p = x % 4 == 0; // mostly unpause, so trading is not frozen most of the time
        _begin();
        bool ok;
        vm.prank(owner);
        if (p) {
            try m.pause() {
                ok = true;
            } catch {}
        } else {
            try m.unpause() {
                ok = true;
            } catch {}
        }
        if (ok) gPaused = p;
        _end(ok, "ownerPause");
    }

    function ownerSetTipJar(uint256 seed) external {
        address t = seed % 4 == 3 ? address(wallets[3]) : jars[seed % jars.length];
        _begin();
        vm.prank(owner);
        m.setTipJar(t);
        gTipJar = t;
        _end(true, "ownerSetTipJar");
    }

    function ownerSetGuardian(uint256 seed) external {
        address g = seed % 3 == 0 ? address(0) : actors[seed % actors.length];
        _begin();
        vm.prank(owner);
        m.setGuardian(g);
        gGuardian = g;
        _end(true, "ownerSetGuardian");
    }

    /// R4: the guardian (or someone else) tries to pause or unpause. Only owner / guardian may pause; only
    /// the owner may unpause.
    function guardianPause(uint256 seed, bool unpause_) external {
        address who = seed % 2 == 0 && gGuardian != address(0) ? gGuardian : actors[seed % actors.length];
        _begin();
        bool ok;
        vm.prank(who);
        if (unpause_) {
            try m.unpause() {
                ok = true;
            } catch {}
            if (ok) _v("guardianPause: a non-owner unpaused");
        } else {
            try m.pause() {
                ok = true;
            } catch {}
            if (ok) {
                if (who != gGuardian) _v("guardianPause: a non-guardian paused");
                gPaused = true;
            }
        }
        _end(ok, "guardianPause");
    }

    function ownerRefundOffers(uint256 s1, uint256 s2) external {
        uint256 oc = m.offerCount();
        if (oc == 0) return;
        uint256 a = bound(s1, 1, oc);
        uint256 b = bound(s2, 1, oc);
        uint256[] memory ids = new uint256[](a == b ? 1 : 2);
        ids[0] = a;
        if (a != b) ids[1] = b;
        uint256[] memory refunds = new uint256[](ids.length);
        _begin();
        for (uint256 i; i < ids.length; ++i) {
            GO memory o = go[ids[i]];
            if (o.bidder == address(0)) continue;
            refunds[i] = (uint256(o.price) + (uint256(o.price) * o.feeBps) / 10_000) * o.remaining;
            _exp(o.bidder, int256(refunds[i]));
        }
        bool ok;
        vm.prank(owner);
        try m.refundOffers(ids) {
            ok = true;
        } catch {}
        if (ok) {
            if (!gPaused) _v("refundOffers: while not paused");
            for (uint256 i; i < ids.length; ++i) {
                if (go[ids[i]].bidder == address(0)) continue;
                ghostEscrow -= refunds[i];
                delete go[ids[i]];
            }
        }
        _end(ok, "ownerRefundOffers");
    }

    // ───────────────────────────── self-serve creator royalties ─────────────────────────────

    /// The collection's owner() (or someone pretending) registers a royalty for it.
    function creatorRegisterRoyalty(uint256 cSeed, uint256 callerSeed, uint256 rSeed, uint256 bps) external {
        address c = address(nfts[cSeed % 3]);
        address creator = InvNFT(c).owner();
        address caller = callerSeed % 4 == 0 ? actors[(callerSeed / 4) % actors.length] : creator;
        if (caller == address(0)) caller = actors[0]; // msg.sender is never 0 on chain
        uint256 r = rSeed % 4;
        address recv = r == 0 ? receivers[0] : r == 1 ? receivers[1] : r == 2 ? caller : address(0);
        if (!_isTracked(recv) && recv != address(0)) recv = receivers[0];
        bps = bound(bps, 0, 1100);
        _begin();
        vm.prank(caller);
        bool ok = SelfServe.register(m, c, recv, uint16(bps));
        if (ok) {
            if (!selfServe) _v("selfServe: succeeded on a version without it");
            if (caller != creator || creator == address(0)) _v("selfServe: non-creator registered a royalty");
            if (gBlocked[c]) _v("selfServe: registered while blocked");
            if (bps > 1000) _v("selfServe: above cap");
            gRegRecv[c] = recv;
            gRegBps[c] = recv == address(0) ? 0 : uint16(bps);
        }
        _end(ok, "creatorRegisterRoyalty");
    }

    function ownerSetSelfServeBlocked(uint256 cSeed, bool blocked) external {
        address c = address(nfts[cSeed % 3]);
        _begin();
        vm.prank(owner);
        bool ok = SelfServe.setBlocked(m, c, blocked);
        if (ok) gBlocked[c] = blocked;
        else if (selfServe) _v("setSelfServeBlocked: owner call reverted");
        _end(ok, "ownerSetSelfServeBlocked");
    }

    /// The collection contract's owner() changes hands (or is renounced).
    function setCollectionOwner(uint256 cSeed, uint256 seed) external {
        uint256 k = seed % 4;
        address o = k == 0 ? receivers[0] : k == 1 ? receivers[1] : k == 2 ? actors[seed / 4 % actors.length] : address(0);
        nfts[cSeed % 3].setOwner(o);
        _count("setCollectionOwner");
    }

    /// A non-owner tries every owner power; all must revert.
    function strangerAdmin(uint256 aSeed, uint8 which) external {
        address who = actors[aSeed % actors.length];
        _begin();
        bool ok;
        vm.startPrank(who);
        uint8 w = which % 18;
        if (w == 0) try m.setFee(1) { ok = true; } catch {}
        if (w == 1) try m.setDefaultRoyalty(0) { ok = true; } catch {}
        if (w == 2) try m.registerRoyalty(address(nfts[0]), who, 1000) { ok = true; } catch {}
        if (w == 3) try m.renounceOwnership() { ok = true; } catch {}
        if (w == 4) {
            // nobody but our owner, creators included, may take the fees
            uint256 amt = gFloorFund[address(nfts[0])];
            _eFloor[0] = -int256(amt == 0 ? 1 : amt); // only checked if the stranger's call succeeded
            _exp(who, int256(amt == 0 ? 1 : amt));
            try m.withdrawFloorFund(address(nfts[0]), who, amt == 0 ? 1 : amt) { ok = true; } catch {}
        }
        if (w == 5) try m.setCollectionAllowed(address(nfts[2]), true) { ok = true; } catch {}
        if (w == 6 && who != gGuardian) try m.pause() { ok = true; } catch {}
        if (w == 7) try m.unpause() { ok = true; } catch {}
        if (w == 8) try m.refundOffers(_one(1)) { ok = true; } catch {}
        if (w == 9) try m.transferOwnership(who) { ok = true; } catch {}
        if (w == 10) ok = SelfServe.setBlocked(m, address(nfts[0]), true);
        if (w == 11) try m.setTipJar(who) { ok = true; } catch {}
        if (w == 12) try m.setCreatorAllowance(address(nfts[0]), type(uint256).max) { ok = true; } catch {}
        if (w == 13) try m.setCosigner(who) { ok = true; } catch {}
        if (w == 14) try m.setFlagger(who) { ok = true; } catch {}
        if (w == 15) try m.setFloorParams(5000, 500, 0) { ok = true; } catch {}
        if (w == 16) try m.seedFloorRef(address(nfts[2]), 1) { ok = true; } catch {}
        if (w == 17) try m.setFlag(address(nfts[0]), 1, true, who) { ok = true; } catch {} // actors are never the flagger
        vm.stopPrank();
        if (ok) _v("strangerAdmin: a non-owner used an owner power");
        _end(ok, "strangerAdmin");
    }

    // ───────────────────────────── signed listings ─────────────────────────────

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Leaf of a named-wallet order's Merkle root (OpenZeppelin StandardMerkleTree over ["address"]).
    function _wleaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PentagonMarketplaceV3"),
                keccak256("1"),
                block.chainid,
                address(m)
            )
        );
    }

    /// The EIP-712 digest of an Order, built field by field from the type string a wallet shows the seller
    /// (not with the contract's abi.encode(TYPEHASH, order) shortcut).
    function _orderDigest(M.Order memory o) internal view returns (bytes32) {
        bytes memory a = abi.encode(
            ORDER_TYPEHASH_, o.seller, o.collection, o.tokenId, o.startPrice, o.endPrice, o.rampStart, o.rampEnd, o.floorRef, o.upBps, o.downBps
        );
        bytes memory b = abi.encode(
            o.priceMin, o.priceMax, o.audience, o.audienceKind, o.feeBps, o.royaltyBps, o.acceptFeeChanges, o.nonce, o.start, o.expiry, o.salt
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(), keccak256(bytes.concat(a, b))));
    }

    function _authDigest(bytes32 oh, address buyer, uint128 floor, uint40 dl, bool ack, bool clear)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked("\x19\x01", _domain(), keccak256(abi.encode(FILL_AUTH_TYPEHASH_, oh, buyer, floor, dl, ack, clear)))
        );
    }

    /// Independent model of floorBand: the co-signer's F clamped to the band around the reference, and the
    /// band's low end.
    function _band(address c, uint256 F) internal view returns (uint256 f, uint256 low) {
        uint256 ref = gRef[c];
        if (ref == 0) return (F, F);
        uint256 dt = block.timestamp - gRefAt[c];
        uint256 fall = (dt * gFall) / 1 days;
        low = fall >= 10_000 ? 0 : (ref * (10_000 - fall)) / 10_000;
        uint256 high = (ref * (10_000 + (dt * gRise) / 1 days)) / 10_000;
        f = F < low ? low : F > high ? high : F;
    }

    /// Independent model of priceAt, in plain arithmetic: (the rule is well formed, the price now).
    function _modelPrice(M.Order memory o, uint256 f) internal view returns (bool, uint256 p) {
        if (o.priceMin == 0 || o.priceMin > o.priceMax || o.rampStart > o.rampEnd) return (false, 0);
        if (o.upBps > 10_000 || o.downBps > 10_000) return (false, 0);
        if (o.floorRef == 0 && (o.upBps != 0 || o.downBps != 0)) return (false, 0);
        uint256 t = block.timestamp;
        if (t <= o.rampStart) {
            p = o.startPrice;
        } else if (t >= o.rampEnd) {
            p = o.endPrice;
        } else {
            uint256 span = uint256(o.rampEnd) - o.rampStart;
            uint256 gone = t - o.rampStart;
            p = o.endPrice >= o.startPrice
                ? o.startPrice + (uint256(o.endPrice - o.startPrice) * gone) / span
                : o.startPrice - (uint256(o.startPrice - o.endPrice) * gone) / span;
        }
        if (o.floorRef != 0 && (o.upBps != 0 || o.downBps != 0)) {
            uint256 r = (f * 1e18) / o.floorRef;
            uint256 factor =
                r >= 1e18 ? 1e18 + ((r - 1e18) * o.upBps) / 10_000 : 1e18 - ((1e18 - r) * o.downBps) / 10_000;
            p = p * (factor / 1e18) + (p * (factor % 1e18)) / 1e18; // = floor(p * factor / 1e18), without overflow
        }
        if (p < o.priceMin) p = o.priceMin;
        if (p > o.priceMax) p = o.priceMax;
        return (true, p);
    }

    /// A seller signs an order (no transaction). The handler keeps the last SO_MAX of them. Most are what
    /// the listing UI would produce; some are malformed, already stale, or signed by someone who does not own
    /// the token, and the model must refuse those at fill time.
    function signOrder(uint256 cSeed, uint256 idSeed, uint256 p1, uint256 p2, uint256 shape, uint256 dur, uint8 mode)
        external
    {
        mode = uint8(uint256(keccak256(abi.encode(mode, shape)))); // spread: the fuzzer favours 0 and 255
        address c = mode % 4 != 0 ? _allowedCollection(cSeed) : address(nfts[cSeed % 3]);
        _makeOrder(c, idSeed % TOKENS + 1, p1, p2, shape, dur, mode);
        _count("signOrder");
    }

    /// The first allowed collection at or after cSeed (that one itself if none is allowed).
    function _allowedCollection(uint256 cSeed) internal view returns (address) {
        for (uint256 k; k < 3; ++k) {
            address c = address(nfts[(cSeed % 3 + k) % 3]);
            if (gAllowed[c]) return c;
        }
        return address(nfts[cSeed % 3]);
    }

    /// Sign one order for token `id` of `c` and keep it; returns its slot in `orders`.
    function _makeOrder(address c, uint256 id, uint256 p1, uint256 p2, uint256 shape, uint256 dur, uint8 mode)
        internal
        returns (uint256 slot)
    {
        SO memory s;
        M.Order memory o;
        o.collection = c;
        o.tokenId = id;
        o.seller = InvNFT(o.collection).ownerOf(o.tokenId);
        if (mode % 13 == 2) o.seller = actors[(mode / 13) % actors.length]; // maybe not the owner
        if (mode % 4 != 0 && !InvNFT(o.collection).isApprovedForAll(o.seller, address(m))) {
            vm.prank(o.seller);
            InvNFT(o.collection).setApprovalForAll(address(m), true);
        }
        p1 = bound(p1, 1, 50 ether);
        p2 = bound(p2, 1, 50 ether);
        if (shape % 4 < 2) {
            // a fixed price
            o.startPrice = o.endPrice = o.priceMin = o.priceMax = uint96(p1);
        } else {
            // a price that moves with time and, for shape % 4 == 3, with the floor
            o.startPrice = uint96(p1);
            o.endPrice = uint96(p2);
            o.rampStart = uint40(block.timestamp + (shape / 4) % 3 days);
            o.rampEnd = o.rampStart + uint40((shape / 1e6) % 30 days);
            o.priceMin = uint96((p1 < p2 ? p1 : p2) / (1 + (shape / 7) % 3));
            if (o.priceMin == 0) o.priceMin = 1;
            o.priceMax = uint96((p1 < p2 ? p2 : p1) * (1 + (shape / 11) % 3));
            if (shape % 4 == 3) {
                o.floorRef = uint128(bound(shape / 1e9, 1e15, 100 ether));
                o.upBps = uint16((shape / 13) % 10_001);
                o.downBps = uint16((shape / 17) % 10_001);
            }
        }
        uint256 ak = (shape / 5) % 6; // 0-2 everyone, 3-4 named wallets, 5 enforced by the co-signer
        if (ak == 3 || ak == 4) {
            o.audienceKind = 1;
            s.namedA = actors[(shape / 23) % actors.length];
            if (s.namedA == o.seller) s.namedA = actors[((shape / 23) % actors.length + 1) % actors.length];
            if (ak == 4) s.namedB = actors[(shape / 29) % actors.length];
            if (s.namedB == s.namedA) s.namedB = address(0);
            o.audience = s.namedB == address(0) ? _wleaf(s.namedA) : _hashPair(_wleaf(s.namedA), _wleaf(s.namedB));
        } else if (ak == 5) {
            o.audienceKind = 2;
            o.audience = keccak256("collectors only");
        }
        o.feeBps = gFee;
        o.royaltyBps = _royBps(o.collection);
        o.acceptFeeChanges = mode % 3 != 0;
        o.nonce = m.sellerNonce(o.seller);
        o.start = uint40(block.timestamp);
        o.expiry = uint40(block.timestamp + bound(dur, 1, 180 days));
        o.salt = ++saltCounter;
        // orders no listing UI would produce
        if (mode % 17 == 5) o.priceMin = o.priceMax + 1;
        if (mode % 19 == 6) o.expiry = o.start + uint40(180 days + 1);
        if (mode % 23 == 7) o.start = uint40(block.timestamp + 1 days);
        if (mode % 29 == 8) o.upBps = 10_001;
        s.o = o;
        s.h = m.hashOrder(o);
        if (s.h != _orderDigest(o)) _v("hashOrder: not the EIP-712 hash of the Order type");
        if (orders.length < SO_MAX) {
            slot = orders.length;
            orders.push(s);
        } else {
            slot = soNext % SO_MAX;
            orders[slot] = s;
        }
        ++soNext;
    }

    struct SBuy {
        address buyer;
        uint256 n;
        uint256 total;
        uint256 value;
        uint256 tip;
        bool expectOk;
        bool ok;
        bool badDigest;
        bytes4 err; // the error the marketplace gave, when it refused
        bool lenient; // the second fill may legitimately fail (see buySigned)
        uint256[2] slot;
        uint256[2] price;
        uint256[2] fee;
        uint256[2] roy;
        bool[2] simOk;
        uint8[2] flagBefore;
        address[2] claimantBefore;
    }

    struct Snap {
        uint256[3] ref;
        uint256[3] refAt;
        GF[2] flag;
        uint8[2] os;
    }

    /// An order that is open, current, in its time window and still backed by the token (found = true), not
    /// on the token of order `avoid`; any order if there is none. `orders` must not be empty.
    function _pickOrder(uint256 seed, uint256 avoid) internal view returns (uint256, bool found) {
        uint256 cnt = orders.length;
        for (uint256 k; k < cnt; ++k) {
            uint256 idx = (seed % cnt + k) % cnt;
            SO storage s = orders[idx];
            if (gOS[s.o.seller][s.h] != 0 || s.o.nonce != m.sellerNonce(s.o.seller)) continue;
            if (!gAllowed[s.o.collection]) continue;
            if (block.timestamp < s.o.start || block.timestamp > s.o.expiry) continue;
            if (InvNFT(s.o.collection).ownerOf(s.o.tokenId) != s.o.seller) continue;
            if (avoid != type(uint256).max && _sameToken(idx, avoid)) continue;
            return (idx, true);
        }
        return (seed % cnt, false);
    }

    /// A token the model has as held (looked for first) or flagged, scanning from `seed`.
    function _findFlagged(uint256 seed) internal view returns (bool, address c, uint256 id) {
        for (uint8 want = 2; want > 0; --want) {
            for (uint256 k; k < 3 * TOKENS; ++k) {
                uint256 t = (seed % (3 * TOKENS) + k) % (3 * TOKENS);
                c = address(nfts[t / TOKENS]);
                id = t % TOKENS + 1;
                if (gFlag[c][id].state == want) return (true, c, id);
            }
        }
        return (false, address(0), 0);
    }

    /// Just before a fill, sometimes: the seller cancels everything (incrementNonce) or this one order, or the
    /// flagger flags the token. The fill that follows must then be refused, or go down the flagged path.
    function _lastMoment(SBuy memory x, uint256 bits) internal {
        SO storage s = orders[x.slot[0]];
        uint256 pre = (bits >> 64) % 40;
        if (pre == 0) {
            vm.prank(s.o.seller);
            m.incrementNonce();
        } else if (pre == 1 && gOS[s.o.seller][s.h] == 0) {
            bytes32[] memory hs = new bytes32[](1);
            hs[0] = s.h;
            vm.prank(s.o.seller);
            m.cancelOrders(hs);
            gOS[s.o.seller][s.h] = 2;
        } else if (pre < 6 && gFlagger != address(0) && gFlag[s.o.collection][s.o.tokenId].state == 0) {
            address claimant = (bits >> 72) % 3 == 0 ? address(0) : actors[(bits >> 80) % actors.length];
            vm.prank(gFlagger);
            m.setFlag(s.o.collection, s.o.tokenId, true, claimant);
            gFlag[s.o.collection][s.o.tokenId] = GF(1, 0, claimant);
            _count(keccak256("buySigned.pre.flag"));
        }
    }

    /// The second order of a two-order fill: an open order on another token, else a fresh one on the next
    /// token of the same collection (so the second fill meets the floor band right after it moved). Sometimes
    /// any order at all, the first one included.
    function _secondOrder(uint256 first, uint256 pick, uint256 bits, uint8 mode) internal returns (uint256 slot) {
        if (mode % 7 == 0) {
            (slot,) = _pickOrder(pick / 3 + 1, type(uint256).max);
            return slot;
        }
        bool found;
        (slot, found) = _pickOrder(pick / 3 + 1, first);
        if (found) return slot;
        if (orders.length == SO_MAX && soNext % SO_MAX == first) ++soNext; // do not overwrite the first order
        uint256 r = uint256(keccak256(abi.encode(pick, bits, first)));
        address c = orders[first].o.collection;
        uint256 p = r >> 8;
        uint256 ref = gRef[c];
        if (ref != 0 && ref < 100 ether) p = bound(p, ref / 4 + 1, ref * 2 > 50 ether ? 50 ether : ref * 2);
        return _makeOrder(c, orders[first].o.tokenId % TOKENS + 1, p, r >> 40, r >> 72, r >> 104, 1);
    }

    /// The first order to fill. Mostly one that should go through: an open order if there is one, else a
    /// freshly signed one (sometimes on a flagged token, so the flag paths are walked). Sometimes any order.
    function _firstOrder(uint256 pick, uint256 bits, uint8 mode) internal returns (uint256 slot) {
        if (mode % 5 == 0 && orders.length > 0) return pick % orders.length;
        uint256 r = uint256(keccak256(abi.encode(pick, bits)));
        uint8 clean = [1, 3, 10, 11][r % 4]; // modes that make a well-formed order (3: no fee changes accepted)
        (bool hasFlag, address fc, uint256 fid) = _findFlagged(pick);
        if (hasFlag && gAllowed[fc] && bits % 2 == 1) return _makeOrder(fc, fid, r >> 8, r >> 40, r >> 72, r >> 104, clean);
        bool found;
        if (orders.length > 0) (slot, found) = _pickOrder(pick, type(uint256).max);
        if (!found) {
            address c = _allowedCollection(pick);
            uint256 p = r >> 8;
            uint256 ref = gRef[c];
            if (ref != 0 && ref < 100 ether) p = bound(p, ref / 4 + 1, ref * 2 > 50 ether ? 50 ether : ref * 2);
            slot = _makeOrder(c, (pick / 3) % TOKENS + 1, p, r >> 40, r >> 72, r >> 104, clean);
        }
    }

    function _sameToken(uint256 a, uint256 b) internal view returns (bool) {
        return orders[a].o.collection == orders[b].o.collection && orders[a].o.tokenId == orders[b].o.tokenId;
    }

    function _pickBuyer(SO storage s, uint256 seed, uint8 mode) internal view returns (address b) {
        b = actors[seed % actors.length];
        if (s.o.audienceKind == 1 && mode % 8 != 0) b = s.namedA; // a named order's wallet usually buys it
        GF memory fl = gFlag[s.o.collection][s.o.tokenId];
        if (fl.state != 0 && fl.claimant != address(0) && mode % 4 == 1) b = fl.claimant; // a buy-back
        if (mode % 11 == 2) b = s.o.seller; // self-trade attempt
        else if (b == s.o.seller) b = actors[(seed % actors.length + 1) % actors.length];
    }

    /// The co-signer's F: sometimes none, sometimes anything, mostly near the reference (or the order's price).
    function _pickFloor(M.Order memory o, uint256 r, uint8 mode) internal view returns (uint128) {
        uint256 k = r % 8;
        if (k == 0) return 0;
        if (k == 1) return uint128(bound(r >> 8, 1e15, 200 ether));
        if (k == 7 && mode % 29 == 3) return type(uint128).max;
        uint256 base = gRef[o.collection] != 0 ? gRef[o.collection] : o.floorRef != 0 ? o.floorRef : o.startPrice;
        uint256 F = (base * bound(r >> 8, 2_000, 30_000)) / 10_000;
        return F > type(uint128).max ? type(uint128).max : uint128(F);
    }

    function _snapshot(SBuy memory x) internal view returns (Snap memory sn) {
        for (uint256 c; c < 3; ++c) {
            sn.ref[c] = gRef[address(nfts[c])];
            sn.refAt[c] = gRefAt[address(nfts[c])];
        }
        for (uint256 i; i < x.n; ++i) {
            SO storage s = orders[x.slot[i]];
            sn.flag[i] = gFlag[s.o.collection][s.o.tokenId];
            sn.os[i] = gOS[s.o.seller][s.h];
        }
    }

    function _restore(SBuy memory x, Snap memory sn) internal {
        for (uint256 c; c < 3; ++c) {
            gRef[address(nfts[c])] = sn.ref[c];
            gRefAt[address(nfts[c])] = sn.refAt[c];
        }
        for (uint256 i; i < x.n; ++i) {
            SO storage s = orders[x.slot[i]];
            gFlag[s.o.collection][s.o.tokenId] = sn.flag[i];
            gOS[s.o.seller][s.h] = sn.os[i];
        }
    }

    /// The model's verdict on one signed fill, applied to the model as the contract would apply it:
    /// (it must succeed, price, fee, royalty). The caller rolls the model back if the real call fails.
    /// Not covered here (the caller covers them): the two signatures, the auth window, maxPrice, payment.
    ///
    /// The price and fee are worked out even when the fill must be refused, so the buyer always offers the
    /// true price and enough money. Otherwise the marketplace would refuse for PriceAboveMax alone and a
    /// missing check further on (a cancelled order, a held token, the claimant's cap) could never show.
    function _simFill(SO storage s, address buyer, uint256 F, bool ack, bool clear, bool inSet)
        internal
        returns (bool ok, uint256 price, uint256 fee, uint256 roy)
    {
        M.Order memory o = s.o;
        address c = o.collection;
        bool named = o.audienceKind == 1;
        ok = gOS[o.seller][s.h] == 0 && o.seller != buyer && gAllowed[c];
        if (o.nonce != m.sellerNonce(o.seller) || block.timestamp < o.start || block.timestamp > o.expiry) {
            ok = false;
        } else if (uint256(o.expiry) - o.start > 180 days) {
            ok = false;
        }
        if (!named && !o.acceptFeeChanges && (gFee > o.feeBps || _royBps(c) > o.royaltyBps)) ok = false;
        if (named && !inSet) ok = false;
        // the floor: clamp F to the band and move the reference to it
        (uint256 f, uint256 low) = _band(c, F);
        if (f == 0) {
            low = 0;
        } else {
            gRef[c] = f > type(uint128).max ? type(uint128).max : f;
            gRefAt[c] = block.timestamp;
        }
        bool valid;
        (valid, price) = _modelPrice(o, f);
        if (!valid) return (false, 0, 0, 0); // a malformed rule has no price
        if (price < (low * gBackstop) / 10_000) ok = false;
        gOS[o.seller][s.h] = 1;
        if (!named) {
            fee = (price * gFee) / 10_000; // the rates of today, not the signed ones
            roy = (price * _royBps(c)) / 10_000;
        }
        GF storage fl = gFlag[c][o.tokenId];
        if (fl.state != 0) {
            if (buyer == fl.claimant) {
                if (price > (fl.paid > gRef[c] ? fl.paid : gRef[c])) ok = false;
                delete gFlag[c][o.tokenId];
            } else if (fl.state == 2 || !ack) {
                ok = false;
            } else if (clear) {
                delete gFlag[c][o.tokenId];
            } else {
                fl.state = 2;
                fl.paid = uint96(price);
            }
        }
        if (InvNFT(c).ownerOf(o.tokenId) != o.seller) ok = false;
        if (!InvNFT(c).isApprovedForAll(o.seller, address(m)) && InvNFT(c).getApproved(o.tokenId) != address(m)) {
            ok = false;
        }
    }

    function _prepItem(SBuy memory x, uint256 i, uint256 r, uint256 bits, uint8 mode)
        internal
        returns (M.SignedBuy memory it)
    {
        SO storage s = orders[x.slot[i]];
        it.order = s.o;
        GF memory fl = gFlag[s.o.collection][s.o.tokenId];
        x.flagBefore[i] = fl.state;
        x.claimantBefore[i] = fl.claimant;
        it.floor = _pickFloor(s.o, r, mode);
        it.flagAck = fl.state != 0 ? bits % 4 != 0 : bits % 8 == 0;
        it.clearFlag = (bits >> 3) % 4 == 0;
        it.authDeadline = uint40(block.timestamp + (r >> 16) % 301);
        bool ok = true;
        if (mode % 31 == 9) {
            // an auth that has expired, or one good for longer than 5 minutes
            it.authDeadline = uint40((r >> 30) % 2 == 0 ? block.timestamp - 1 : block.timestamp + 301);
            ok = false;
        }
        uint256 ck = gCosigner == csAddrs[1] ? csKeys[1] : csKeys[0];
        if (mode % 37 == 11) {
            ck = strangerKey; // not the co-signer
            ok = false;
        }
        uint256 sk = keyOf[s.o.seller];
        if (mode % 41 == 13 || sk == 0) {
            sk = strangerKey; // not the seller
            ok = false;
        }
        if (s.o.audienceKind == 1) {
            if (x.buyer == s.namedA) {
                if (s.namedB != address(0)) it.proof = _proof(_wleaf(s.namedB));
            } else {
                it.proof = _proof(_wleaf(s.namedA));
            }
        }
        bytes32 digest = _authDigest(s.h, x.buyer, it.floor, it.authDeadline, it.flagAck, it.clearFlag);
        if (digest != m.fillAuthDigest(s.h, x.buyer, it.floor, it.authDeadline, it.flagAck, it.clearFlag)) {
            x.badDigest = true;
        }
        it.sellerSig = _sign(sk, s.h);
        it.cosignerSig = _sign(ck, digest);
        bool simOk;
        (simOk, x.price[i], x.fee[i], x.roy[i]) = _simFill(
            s, x.buyer, it.floor, it.flagAck, it.clearFlag, x.buyer == s.namedA || (s.namedB != address(0) && x.buyer == s.namedB)
        );
        x.simOk[i] = ok && simOk;
        it.maxPrice = x.price[i] + ((r >> 40) % 3 == 0 ? (r >> 44) % 1 ether : 0);
        if (mode % 10 == 1 && i == 0 && x.price[i] > 0) {
            it.maxPrice = x.price[i] - 1; // the order is dearer than the buyer saw
            x.simOk[i] = false;
        }
    }

    /// Fill one or two signed orders. The model decides beforehand whether the fill must succeed, and both
    /// directions are checked: a fill the rules refuse must revert, and a fill the rules allow must go through.
    function buySigned(uint256 buyerSeed, uint256 pick, uint256 fSeed, uint256 overpay, uint256 bits, uint8 mode, uint256 tipSeed)
        external
    {
        SBuy memory x;
        bits = uint256(keccak256(abi.encode(bits, pick))); // spread: the fuzzer favours 0 and max
        mode = uint8(bits >> 200);
        x.n = bits % 5 == 0 ? 2 : 1;
        x.slot[0] = _firstOrder(pick, bits, mode);
        if (x.n == 2) {
            x.slot[1] = _secondOrder(x.slot[0], pick, bits, mode);
            // A smart-wallet seller may act when it is paid. TrickyWallet in mode 3 calls incrementNonce(),
            // which cancels its own other orders in the middle of the call. With two orders from such a
            // seller, the second fill is then rightly refused (OrderNotLive), if the wallet had the gas for it.
            address s0 = orders[x.slot[0]].o.seller;
            x.lenient = s0 == orders[x.slot[1]].o.seller && s0.code.length != 0 && TrickyWallet(payable(s0)).mode() == 3;
        }
        _lastMoment(x, bits);
        x.buyer = _pickBuyer(orders[x.slot[0]], buyerSeed, mode);
        Snap memory snap = _snapshot(x);
        M.SignedBuy[] memory items = new M.SignedBuy[](x.n);
        x.expectOk = !gPaused && gCosigner != address(0);
        for (uint256 i; i < x.n; ++i) {
            items[i] = _prepItem(x, i, uint256(keccak256(abi.encode(fSeed, i))), bits >> (8 * (i + 1)), mode);
            if (!x.simOk[i]) x.expectOk = false;
            x.total += x.price[i] + x.fee[i];
        }
        // the same token twice in one call: the second transfer cannot happen
        if (x.n == 2 && _sameToken(x.slot[0], x.slot[1])) x.expectOk = false;
        uint256 maxTip = (x.total * 500) / 10_000;
        x.tip = tipSeed % 3 == 0 ? 0 : bound(tipSeed, 0, maxTip);
        if (mode % 17 == 4) {
            x.tip = maxTip + 1; // over the 5% cap
            x.expectOk = false;
        }
        x.value = x.total + x.tip + bound(overpay, 0, 2 ether);
        if (mode % 13 == 3 && x.total + x.tip > 0) {
            x.value = x.total + x.tip - 1;
            x.expectOk = false;
        }
        vm.deal(x.buyer, x.buyer.balance + x.value);
        _begin();
        if (x.badDigest) _v("fillAuthDigest: not the EIP-712 hash of the FillAuth type");
        for (uint256 i; i < x.n; ++i) {
            if (!x.simOk[i]) continue;
            M.Order memory o = items[i].order;
            // the least the seller nets: all of it on a named-wallet sale; else the price less the royalty
            // they signed, or less the cap if they accepted rate changes
            uint256 worstBps = o.audienceKind == 1 ? 0 : o.acceptFeeChanges ? 1000 : o.royaltyBps;
            _sellerFloor(o.seller, x.price[i] - (x.price[i] * worstBps) / 10_000);
            _eFloor[_ci(o.collection)] += int256(x.fee[i]);
            _expRoy(o.collection, x.roy[i]);
            _exp(o.seller, int256(x.price[i] - x.roy[i]));
            _move(o.collection, o.tokenId, o.seller, x.buyer);
        }
        _exp(x.buyer, -int256(x.total + x.tip));
        _exp(gTipJar, int256(x.tip));
        vm.prank(x.buyer);
        try m.buySigned{value: x.value}(items, x.tip) {
            x.ok = true;
        } catch (bytes memory e) {
            x.err = bytes4(e);
        }
        if (x.ok) {
            if (!x.expectOk) _v("buySigned: filled, but the rules refuse this fill");
            _afterSignedFill(x, items);
        } else {
            if (x.expectOk && !(x.lenient && x.err == M.OrderNotLive.selector)) {
                _v(string.concat("buySigned: refused a fill the rules allow, error ", vm.toString(x.err)));
            }
            _restore(x, snap);
        }
        _checkSellerFloors(x.ok, "buySigned");
        _end(x.ok, "buySigned");
    }

    /// Checks on a successful signed fill that do not go through _simFill, and the coverage counters.
    function _afterSignedFill(SBuy memory x, M.SignedBuy[] memory items) internal {
        if (gPaused) _v("buySigned: while paused");
        for (uint256 i; i < x.n; ++i) {
            M.Order memory o = items[i].order;
            uint256 p = x.price[i];
            bool named = o.audienceKind == 1;
            if (p < o.priceMin || p > o.priceMax) _v("buySigned: sold outside [priceMin, priceMax]");
            if (p > items[i].maxPrice) _v("buySigned: price above the maxPrice the buyer set");
            if (x.fee[i] * 10_000 > p * 500 || x.roy[i] * 10_000 > p * 1000) _v("buySigned: fee or royalty over the cap");
            if (named && (x.fee[i] != 0 || x.roy[i] != 0)) _v("buySigned: a named-wallet order was charged");
            if (!named && !o.acceptFeeChanges && (gFee > o.feeBps || _royBps(o.collection) > o.royaltyBps)) {
                _v("buySigned: rates above what the seller signed");
            }
            if (o.seller == x.buyer) _v("buySigned: self-trade");
            if (!gAllowed[o.collection]) _v("buySigned: collection not allowed");
            if (block.timestamp > o.expiry || block.timestamp < o.start) _v("buySigned: outside the time window of the order");
            if (items[i].authDeadline < block.timestamp || items[i].authDeadline > block.timestamp + 5 minutes) {
                _v("buySigned: auth outside its 5-minute window");
            }
            if (m.orderStatus(o.seller, orders[x.slot[i]].h) != 1) _v("buySigned: order not marked filled");
            _clearListing(o.collection, o.tokenId); // a signed fill removes the on-chain listing of the token
            _count(keccak256("buySigned.fills"));
            if (named) _count(keccak256("buySigned.named"));
            if (o.floorRef != 0) _count(keccak256("buySigned.floorRule"));
            if (o.seller.code.length != 0) _count(keccak256("buySigned.1271seller"));
            if (x.flagBefore[i] != 0) {
                if (x.buyer == x.claimantBefore[i]) _count(keccak256("buySigned.claimantBuyback"));
                else if (gFlag[o.collection][o.tokenId].state == 2) _count(keccak256("buySigned.flaggedNowHeld"));
                else _count(keccak256("buySigned.flagCleared"));
            }
        }
        if (x.n == 2) _count(keccak256("buySigned.batch2"));
    }

    /// A sale by an on-chain listing or an offer: a flagged or held token may only go to its claimant, at no
    /// more than max(what the holder paid, the floor reference). That clears the flag.
    function _plainSaleFlag(address c, uint256 id, address buyer, uint256 price, string memory tag) internal {
        GF storage fl = gFlag[c][id];
        if (fl.state == 0) return;
        if (buyer != fl.claimant) {
            _v(string.concat(tag, ": a flagged or held token was sold to someone other than its claimant"));
            return;
        }
        if (price > (fl.paid > gRef[c] ? fl.paid : gRef[c])) {
            _v(string.concat(tag, ": the claimant paid more than max(paid, floor ref)"));
        }
        delete gFlag[c][id];
        _count(keccak256("plain.claimantBuyback"));
    }

    /// The seller (or someone else) cancels an order by its hash. Only the caller's own order can be affected.
    function cancelOrders(uint256 aSeed, uint256 pick) external {
        if (orders.length == 0) return;
        SO storage s = orders[pick % orders.length];
        address who = aSeed % 4 == 0 ? actors[(aSeed / 4) % actors.length] : s.o.seller;
        bool mustFail = gOS[who][s.h] == 1; // already filled
        bytes32[] memory hs = new bytes32[](1);
        hs[0] = s.h;
        _begin();
        bool ok;
        vm.prank(who);
        try m.cancelOrders(hs) {
            ok = true;
        } catch {}
        if (ok) {
            if (mustFail) _v("cancelOrders: cancelled a filled order");
            gOS[who][s.h] = 2;
            if (m.orderStatus(who, s.h) != 2) _v("cancelOrders: not marked cancelled");
        } else if (!mustFail) {
            _v("cancelOrders: reverted");
        }
        _end(ok, "cancelOrders");
    }

    function ownerSetCosigner(uint256 seed) external {
        seed = uint256(keccak256(abi.encode(seed)));
        address c = seed % 16 == 0 ? address(0) : csAddrs[(seed >> 8) % 2];
        _begin();
        vm.prank(owner);
        m.setCosigner(c);
        gCosigner = c;
        _end(true, "ownerSetCosigner");
    }

    function ownerSetFlagger(uint256 seed) external {
        seed = uint256(keccak256(abi.encode(seed)));
        address f = seed % 16 == 0 ? address(0) : flaggers[(seed >> 8) % 2];
        _begin();
        vm.prank(owner);
        m.setFlagger(f);
        gFlagger = f;
        _end(true, "ownerSetFlagger");
    }

    function ownerSetFloorParams(uint256 fall, uint256 rise, uint256 back, uint8 mode) external {
        fall = bound(fall, 500, 5000);
        rise = bound(rise, 500, 100_000);
        back = bound(back, 0, 5000);
        bool mustFail = mode % 6 == 0;
        if (mustFail) {
            uint256 w = (mode / 6) % 5; // one value just outside its bounds
            if (w == 0) fall = 499;
            if (w == 1) fall = 5001;
            if (w == 2) rise = 499;
            if (w == 3) rise = 100_001;
            if (w == 4) back = 5001;
        }
        _begin();
        bool ok;
        vm.prank(owner);
        try m.setFloorParams(uint16(fall), uint32(rise), uint16(back)) {
            ok = true;
        } catch {}
        if (ok) {
            if (mustFail) _v("setFloorParams: outside the bounds");
            gFall = uint16(fall);
            gRise = uint32(rise);
            gBackstop = uint16(back);
        } else if (!mustFail) {
            _v("setFloorParams: owner call reverted");
        }
        _end(ok, "ownerSetFloorParams");
    }

    function ownerSeedFloorRef(uint256 cSeed, uint256 ref) external {
        address c = address(nfts[cSeed % 3]);
        ref = ref % 7 == 0 ? 0 : bound(ref, 1e15, 100 ether);
        bool mustFail = gRef[c] != 0 || ref == 0; // one-time, and never to 0
        _begin();
        bool ok;
        vm.prank(owner);
        try m.seedFloorRef(c, uint128(ref)) {
            ok = true;
        } catch {}
        if (ok) {
            if (mustFail) _v("seedFloorRef: re-seeded, or seeded with 0");
            gRef[c] = ref;
            gRefAt[c] = block.timestamp;
        } else if (!mustFail) {
            _v("seedFloorRef: owner call reverted");
        }
        _end(ok, "ownerSeedFloorRef");
    }

    /// The flagger (or someone else) flags a token, renames its claimant, or clears it.
    function flaggerSetFlag(uint256 callerSeed, uint256 cSeed, uint256 idSeed, uint256 claimantSeed, uint8 x) external {
        address c = address(nfts[cSeed % 3]);
        uint256 id = idSeed % TOKENS + 1;
        x = uint8(uint256(keccak256(abi.encode(x, idSeed))));
        if (x % 2 == 0 && orders.length > 0) {
            // mostly a token somebody has signed an order for
            c = orders[idSeed % orders.length].o.collection;
            id = orders[idSeed % orders.length].o.tokenId;
        }
        bool flagged = x % 5 < 2;
        if (!flagged && x % 4 < 2) {
            // a clear mostly aims at a token that is flagged, so flags stay few and the other paths keep trading
            (bool has, address fc, uint256 fid) = _findFlagged(idSeed);
            if (has) (c, id) = (fc, fid);
        }
        address caller =
            (callerSeed % 4 != 0 && gFlagger != address(0)) ? gFlagger : tracked[callerSeed % tracked.length];
        address claimant = claimantSeed % 4 == 0 ? address(0) : actors[claimantSeed % actors.length];
        _begin();
        bool ok;
        vm.prank(caller);
        try m.setFlag(c, id, flagged, claimant) {
            ok = true;
        } catch {}
        if (ok) {
            if (caller != gFlagger) _v("setFlag: someone other than the flagger set a flag");
            if (!flagged) {
                delete gFlag[c][id];
            } else {
                if (gFlag[c][id].state == 0) gFlag[c][id].state = 1; // a held token keeps its hold
                gFlag[c][id].claimant = claimant;
            }
        } else if (caller == gFlagger) {
            _v("setFlag: the flagger call reverted");
        }
        _end(ok, "flaggerSetFlag");
    }

    /// "" when the signed-listing storage matches the model, else what differs.
    function signedStateMismatch() public view returns (string memory) {
        if (m.cosigner() != gCosigner) return "cosigner";
        if (m.flagger() != gFlagger) return "flagger";
        if (m.floorFallBpsPerDay() != gFall || m.floorRiseBpsPerDay() != gRise || m.floorBackstopBps() != gBackstop) {
            return "floor params";
        }
        if (gFall < 500 || gFall > 5000 || gRise < 500 || gRise > 100_000 || gBackstop > 5000) {
            return "floor params out of bounds";
        }
        for (uint256 c; c < 3; ++c) {
            address col = address(nfts[c]);
            (uint128 ref, uint40 at) = m.floorRefs(col);
            if (ref != gRef[col] || at != gRefAt[col]) return "floor reference";
            for (uint256 id = 1; id <= TOKENS; ++id) {
                (uint8 st, uint96 paid, address cl) = m.flags(col, id);
                GF storage g = gFlag[col][id];
                if (st != g.state || paid != g.paid || cl != g.claimant) return "flag";
            }
        }
        for (uint256 i; i < orders.length; ++i) {
            if (m.orderStatus(orders[i].o.seller, orders[i].h) != gOS[orders[i].o.seller][orders[i].h]) {
                return "order status";
            }
        }
        return "";
    }

    function _one(uint256 x) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = x;
    }

    /// The marketplace deleted this listing (sale, delist, clearStale, fill): privateBuyer goes with it.
    function _clearListing(address c, uint256 id) internal {
        delete gl[c][id];
        delete gPriv[c][id];
    }

    function _proof(bytes32 x) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](1);
        r[0] = x;
    }
}

contract MarketplaceV3InvariantTest is StdInvariant, Test {
    Handler h;
    M m;

    function setUp() public {
        h = new Handler();
        m = h.m();
        targetContract(address(h));
        bytes4[] memory s = new bytes4[](61);
        s[0] = Handler.list.selector;
        s[1] = Handler.delist.selector;
        s[2] = Handler.incrementNonce.selector;
        s[3] = Handler.clearStale.selector;
        s[4] = Handler.buy.selector;
        s[5] = Handler.placeOffer.selector;
        s[6] = Handler.acceptOffer.selector;
        s[7] = Handler.cancelOffer.selector;
        s[8] = Handler.withdraw.selector;
        s[9] = Handler.transferNftOutside.selector;
        s[10] = Handler.setApproval.selector;
        s[11] = Handler.approveOne.selector;
        s[12] = Handler.setWalletMode.selector;
        s[13] = Handler.warp.selector;
        s[14] = Handler.ownerSetFee.selector;
        s[15] = Handler.ownerSetDefaultRoyalty.selector;
        s[16] = Handler.ownerRegisterRoyalty.selector;
        s[17] = Handler.ownerTriesRenounce.selector;
        s[18] = Handler.withdrawFloorFund.selector;
        s[19] = Handler.ownerSetAllowed.selector;
        s[20] = Handler.ownerPause.selector;
        s[21] = Handler.ownerRefundOffers.selector;
        s[22] = Handler.strangerAdmin.selector;
        // weight the core trading paths
        s[23] = Handler.buy.selector;
        s[24] = Handler.creatorRegisterRoyalty.selector;
        s[25] = Handler.ownerSetSelfServeBlocked.selector;
        s[26] = Handler.setCollectionOwner.selector;
        // weights: the trading paths are picked more often than environment / admin noise
        s[27] = Handler.buy.selector;
        s[28] = Handler.buy.selector;
        s[29] = Handler.list.selector;
        s[30] = Handler.list.selector;
        s[31] = Handler.acceptOffer.selector;
        s[32] = Handler.acceptOffer.selector;
        s[33] = Handler.placeOffer.selector;
        s[34] = Handler.withdraw.selector;
        s[35] = Handler.cancelOffer.selector;
        s[36] = Handler.withdrawFor.selector;
        s[37] = Handler.ownerSetGuardian.selector;
        s[38] = Handler.guardianPause.selector;
        s[39] = Handler.listPrivate.selector;
        s[40] = Handler.listPrivate.selector;
        s[41] = Handler.ownerSetTipJar.selector;
        s[42] = Handler.withdrawRoyaltyFund.selector;
        s[43] = Handler.withdrawRoyaltyFund.selector;
        s[44] = Handler.ownerSetCreatorAllowance.selector;
        s[45] = Handler.setCollectionOwner.selector;
        // signed listings, the floor reference and flags
        s[46] = Handler.signOrder.selector;
        s[47] = Handler.signOrder.selector;
        s[48] = Handler.signOrder.selector;
        s[49] = Handler.buySigned.selector;
        s[50] = Handler.buySigned.selector;
        s[51] = Handler.buySigned.selector;
        s[52] = Handler.buySigned.selector;
        s[53] = Handler.buySigned.selector;
        s[54] = Handler.cancelOrders.selector;
        s[55] = Handler.ownerSetCosigner.selector;
        s[56] = Handler.ownerSetFlagger.selector;
        s[57] = Handler.ownerSetFloorParams.selector;
        s[58] = Handler.ownerSeedFloorRef.selector;
        s[59] = Handler.flaggerSetFlag.selector;
        s[60] = Handler.flaggerSetFlag.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    /// Contract balance == escrow of live offers + all pending payouts + all floor funds (exactly; no stray
    /// or missing wei).
    function invariant_balanceEqualsEscrowPlusPending() public view {
        uint256 esc;
        uint256 n = m.offerCount();
        for (uint256 i = 1; i <= n; ++i) {
            (address bidder, uint96 price,,, uint16 fee,, uint16 remaining,) = m.offers(i);
            if (bidder != address(0)) esc += (uint256(price) + (uint256(price) * fee) / 10_000) * remaining;
        }
        uint256 pend;
        for (uint256 i; i < h.trackedLength(); ++i) {
            pend += m.pendingPayouts(h.tracked(i));
        }
        uint256 floors;
        uint256 roys;
        for (uint256 c; c < 3; ++c) {
            floors += m.floorFundOf(h.nft(c));
            roys += m.royaltyFundOf(h.nft(c));
            assertEq(m.floorFundOf(h.nft(c)), h.gFloorFund(h.nft(c)), "floorFundOf != model");
            assertEq(m.royaltyFundOf(h.nft(c)), h.gRoyFund(h.nft(c)), "royaltyFundOf != model");
        }
        assertEq(address(m).balance, esc + pend + floors + roys, "balance != escrow + pending + floor + royalty funds");
        assertEq(esc, h.ghostEscrow(), "on-chain escrow != model escrow");
    }

    /// Every per-call check in the handler (payment splits, NFT moves, who may do what) held.
    function invariant_noHandlerViolations() public view {
        if (h.violationCount() > 0) {
            assertTrue(false, h.violations(0));
        }
    }

    /// A creator never withdraws more of a royalty fund than the allowance our owner last set (unless open),
    /// and the on-chain allowance is always what is left of it.
    function invariant_creatorAllowanceNeverExceeded() public view {
        assertEq(h.badAllowanceSpends(), 0, "allowance spent by someone other than its holder-while-owner()");
        for (uint256 c; c < 3; ++c) {
            address col = h.nft(c);
            assertEq(m.creatorAllowance(col), h.gAllowance(col), "creatorAllowance != model");
            assertEq(m.creatorAllowanceHolder(col), h.gHolder(col), "creatorAllowanceHolder != model");
            uint256 set = h.gAllowanceSet(col);
            if (set != type(uint256).max) {
                assertLe(h.gCreatorTaken(col), set, "creator took more than the allowance");
                assertEq(m.creatorAllowance(col), set - h.gCreatorTaken(col), "allowance not reduced by withdrawals");
            }
        }
    }

    /// Fee and royalty never exceed the caps, globally or frozen into any listing / offer.
    function invariant_capsHold() public view {
        assertLe(m.feeBps(), m.MAX_FEE_BPS());
        assertLe(m.defaultRoyaltyBps(), m.MAX_ROYALTY_BPS());
        for (uint256 c; c < 3; ++c) {
            address col = h.nft(c);
            (, uint16 rb) = m.registeredRoyalty(col);
            assertLe(rb, m.MAX_ROYALTY_BPS());
            for (uint256 id = 1; id <= 6; ++id) {
                (,,,, uint16 f, uint16 r) = m.listings(col, id);
                assertLe(f, m.MAX_FEE_BPS());
                assertLe(r, m.MAX_ROYALTY_BPS());
            }
        }
        uint256 n = m.offerCount();
        for (uint256 i = 1; i <= n; ++i) {
            (,,,, uint16 f, uint16 r,,) = m.offers(i);
            assertLe(f, m.MAX_FEE_BPS());
            assertLe(r, m.MAX_ROYALTY_BPS());
        }
    }

    /// Storage matches the independent model (frozen rates, prices, expiries, remaining counts).
    function invariant_storageMatchesModel() public view {
        for (uint256 c; c < 3; ++c) {
            address col = h.nft(c);
            for (uint256 id = 1; id <= 6; ++id) {
                (address s, uint96 p, uint40 e, uint64 nn, uint16 f, uint16 r) = m.listings(col, id);
                Handler.GL memory g = h.ghostListing(col, id);
                assertEq(s, g.seller, "listing seller");
                assertEq(p, g.price, "listing price");
                assertEq(e, g.expiry, "listing expiry");
                assertEq(nn, g.nonce, "listing nonce");
                assertEq(f, g.feeBps, "listing fee");
                assertEq(r, g.royaltyBps, "listing royalty");
                assertEq(m.privateBuyer(col, id), h.ghostPrivate(col, id), "privateBuyer");
            }
        }
        uint256 n = m.offerCount();
        for (uint256 i = 1; i <= n; ++i) {
            (address b, uint96 p, address col, uint40 e, uint16 f, uint16 r, uint16 rem, bytes32 root) = m.offers(i);
            Handler.GO memory g = h.ghostOffer(i);
            assertEq(b, g.bidder, "offer bidder");
            assertEq(p, g.price, "offer price");
            assertEq(col, g.collection, "offer collection");
            assertEq(e, g.expiry, "offer expiry");
            assertEq(f, g.feeBps, "offer fee");
            assertEq(r, g.royaltyBps, "offer royalty");
            assertEq(rem, g.remaining, "offer remaining");
            assertEq(root, g.root, "offer root");
        }
        assertEq(m.paused(), h.gPaused());
        assertEq(m.guardian(), h.gGuardian());
        assertEq(m.tipJar(), h.gTipJar());
        for (uint256 c; c < 3; ++c) {
            (address rr, uint256 bps, bool reg) = m.royaltyFor(h.nft(c));
            address want = h.gRegRecv(h.nft(c));
            assertEq(reg, want != address(0), "royalty registered flag");
            assertEq(rr, want != address(0) ? want : address(m), "royalty receiver");
            assertEq(bps, want != address(0) ? h.gRegBps(h.nft(c)) : h.gDefRoy(), "royalty bps");
        }
    }

    /// No smart-wallet receive() ever managed to re-enter a guarded function.
    function invariant_noReentry() public view {
        for (uint256 i; i < 5; ++i) {
            assertFalse(TrickyWallet(payable(h.wallet(i))).reentryWorked(), "re-entered a guarded function");
        }
    }

    /// Signed listings: the co-signer, flagger, floor parameters (within their bounds), every floor reference,
    /// every flag and every tracked order's status are what the independent model says.
    function invariant_signedStateMatchesModel() public view {
        assertEq(h.signedStateMismatch(), "", "signed-listing storage != model");
    }

    function afterInvariant() public view {
        uint256 k = h.callKeyCount();
        string[35] memory names = [
            "list", "delist", "incrementNonce", "clearStale", "buy", "placeOffer", "acceptOffer", "cancelOffer",
            "withdraw", "ownerSetFee", "ownerSetDefaultRoyalty", "ownerRegisterRoyalty", "ownerTriesRenounce",
            "withdrawFloorFund", "ownerSetAllowed", "ownerPause", "ownerRefundOffers", "strangerAdmin",
            "creatorRegisterRoyalty", "ownerSetSelfServeBlocked", "withdrawFor", "ownerSetGuardian", "guardianPause",
            "listPrivate", "ownerSetTipJar", "withdrawRoyaltyFund", "ownerSetCreatorAllowance",
            "buySigned", "cancelOrders", "ownerSetCosigner", "ownerSetFlagger", "ownerSetFloorParams",
            "ownerSeedFloorRef", "flaggerSetFlag", ""
        ];
        k;
        console2.log("self-serve royalties present in this build", h.selfServe());
        for (uint256 i; i < 34; ++i) {
            console2.log(
                names[i],
                h.calls(keccak256(abi.encodePacked(names[i], ".ok"))),
                h.calls(keccak256(abi.encodePacked(names[i], ".revert")))
            );
        }
        console2.log("pending total wallets / escrow", address(m).balance, h.ghostEscrow());
        console2.log("signed orders made / filled", h.calls("signOrder"), h.calls(keccak256("buySigned.fills")));
        console2.log("  named / floor rule / ERC-1271 seller", h.calls(keccak256("buySigned.named")), h.calls(keccak256("buySigned.floorRule")), h.calls(keccak256("buySigned.1271seller")));
        console2.log("  two in one call", h.calls(keccak256("buySigned.batch2")));
        console2.log("  flagged: now held / cleared / claimant buy-back", h.calls(keccak256("buySigned.flaggedNowHeld")), h.calls(keccak256("buySigned.flagCleared")), h.calls(keccak256("buySigned.claimantBuyback")));
        console2.log("claimant buy-backs by listing or offer", h.calls(keccak256("plain.claimantBuyback")));
        console2.log("flagged just before a fill (fills that went through)", h.calls(keccak256("buySigned.pre.flag")));
    }
}

/// Stateless fuzz tests on the payment maths.
contract MarketplaceV3FuzzTest is Test {
    M m;
    InvNFT a;
    address owner = makeAddr("owner");
    address tipJar = makeAddr("tipJar");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address creator = makeAddr("creator");

    function setUp() public {
        m = new M(owner, tipJar, 250, 250);
        a = new InvNFT("A");
        vm.prank(owner);
        m.setCollectionAllowed(address(a), true);
        for (uint256 i = 1; i <= 5; ++i) a.mint(seller, i);
        vm.prank(seller);
        a.setApprovalForAll(address(m), true);
    }

    function _one(uint256 x) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = x;
    }

    function testFuzz_buySplitIsExact(uint256 price, uint256 feeBps, uint256 royBps, bool registered, uint256 over)
        public
    {
        price = bound(price, 1, type(uint96).max);
        feeBps = bound(feeBps, 0, 500);
        royBps = bound(royBps, 0, 1000);
        over = bound(over, 0, 10 ether);
        vm.startPrank(owner);
        m.setFee(uint16(feeBps));
        if (registered) m.registerRoyalty(address(a), creator, uint16(royBps));
        else m.setDefaultRoyalty(uint16(royBps));
        vm.stopPrank();
        vm.prank(seller);
        m.list(address(a), _one(1), _one(price), block.timestamp + 1 days);

        uint256 fee = (price * feeBps) / 10_000;
        uint256 roy = (price * royBps) / 10_000;
        vm.deal(buyer, price + fee + over);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, price);
        vm.prank(buyer);
        m.buy{value: price + fee + over}(items, 0);

        assertEq(a.ownerOf(1), buyer);
        assertEq(buyer.balance, over, "buyer paid exactly price + frozen fee");
        if (registered) assertEq(creator.balance, roy);
        assertEq(m.floorFundOf(address(a)), fee, "the fee, and only the fee, in the floor fund");
        assertEq(m.royaltyFundOf(address(a)), registered ? 0 : roy, "unregistered royalty in the royalty fund");
        assertEq(seller.balance, price - roy);
        assertEq(tipJar.balance, 0);
        assertLe(fee, (price * 500) / 10_000);
        assertLe(roy, (price * 1000) / 10_000);
        assertEq(address(m).balance, m.floorFundOf(address(a)) + m.royaltyFundOf(address(a)));
    }

    function testFuzz_offerEscrowRoundTrip(uint256 price, uint256 qty, uint256 fill, uint256 feeBps) public {
        price = bound(price, 1, type(uint96).max / 4);
        qty = bound(qty, 1, 5);
        fill = bound(fill, 0, qty);
        feeBps = bound(feeBps, 0, 500);
        vm.prank(owner);
        m.setFee(uint16(feeBps));
        uint256 fee = (price * feeBps) / 10_000;
        uint256 cost = (price + fee) * qty;
        vm.deal(buyer, cost);
        vm.prank(buyer);
        uint256 oid = m.placeOffer{value: cost}(address(a), price, qty, block.timestamp + 1 days, bytes32(0));
        // owner changes everything mid-flight; frozen terms must still apply
        vm.startPrank(owner);
        m.setFee(0);
        m.setDefaultRoyalty(1000);
        vm.stopPrank();
        if (fill > 0) {
            uint256[] memory ids = new uint256[](fill);
            for (uint256 i; i < fill; ++i) {
                ids[i] = i + 1;
            }
            vm.prank(seller);
            m.acceptOffer(oid, ids, new bytes32[][](0));
        }
        if (fill < qty) {
            vm.prank(buyer);
            m.cancelOffer(oid);
        }
        uint256 roy = (price * 250) / 10_000; // frozen at placement (and min(frozen, 10%) = 2.5%)
        assertEq(address(m).balance, (fee + roy) * fill, "only the floor fund is left");
        assertEq(buyer.balance, (price + fee) * (qty - fill), "unfilled part refunded");
        assertEq(m.floorFundOf(address(a)), fee * fill, "frozen fee per fill");
        assertEq(m.royaltyFundOf(address(a)), roy * fill, "frozen royalty per fill");
        assertEq(seller.balance, (price - roy) * fill);
    }

    /// Whatever the owner does while offers and pending payouts exist, the escrow stays put; the only owner
    /// path that moves escrow (refundOffers) pays the bidder.
    function testFuzz_ownerCannotMoveEscrow(uint256 seed, address newJar, address newRecv) public {
        vm.assume(newJar != address(0) && newRecv != address(0));
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        uint256 oid = m.placeOffer{value: 1.025 ether}(address(a), 1 ether, 1, block.timestamp + 1 days, bytes32(0));
        uint256 bal = address(m).balance;
        vm.startPrank(owner);
        for (uint256 i; i < 8; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i))) % 8;
            if (r == 0) m.setFee(uint16(seed % 501));
            if (r == 1) m.setDefaultRoyalty(uint16(seed % 1001));
            if (r == 2) m.registerRoyalty(address(a), newRecv, uint16(seed % 1001));
            if (r == 3) m.setTipJar(newJar);
            if (r == 4) m.setGuardian(newRecv);
            if (r == 5) m.setCollectionAllowed(address(a), seed % 2 == 0);
            if (r == 6 && !m.paused()) m.pause();
            if (r == 7 && m.paused()) m.unpause();
        }
        assertEq(address(m).balance, bal, "owner settings moved escrow");
        if (!m.paused()) m.pause();
        uint256 before = buyer.balance;
        m.refundOffers(_one(oid));
        vm.stopPrank();
        assertEq(buyer.balance - before, 1.025 ether, "refund went to the bidder");
        assertEq(address(m).balance, 0);
    }

    // ───────── behaviours documented in docs/AUDIT-SELF-REVIEW.md (these PASS: they pin current behaviour) ─────────

    /// F-1: a listing that went stale because the seller revoked approval comes back to life, at its old
    /// price, when the seller approves the marketplace again (e.g. to list something else), unless someone
    /// called clearStale (or the seller bumped their nonce) in between. Same for an NFT that leaves and
    /// later returns to the seller's wallet.
    function test_F1_staleListingRevivesOnReapproval() public {
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 30 days);
        vm.prank(seller);
        a.setApprovalForAll(address(m), false); // seller "cancels" by revoking approval
        assertFalse(m.isListingLive(address(a), 1));
        vm.warp(block.timestamp + 10 days); // price of the NFT goes up meanwhile; keeper did not run
        vm.prank(seller);
        a.setApprovalForAll(address(m), true); // seller re-approves to list token 2
        vm.prank(seller);
        m.list(address(a), _one(2), _one(5 ether), block.timestamp + 30 days);
        assertTrue(m.isListingLive(address(a), 1), "old 1 ETH listing is live again");
        vm.deal(buyer, 2 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
        assertEq(a.ownerOf(1), buyer);
    }

    /// F-2: the royalty RECEIVER is read at sale time (the rate is min(frozen, current) since b7a1443).
    /// Re-registering a collection redirects the royalty of every open listing / offer to the new receiver.
    function test_F2_openOrdersPayTheCurrentReceiver() public {
        address newRecv = makeAddr("newReceiver");
        vm.prank(owner);
        m.registerRoyalty(address(a), creator, 1000); // creator at 10%
        vm.startPrank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 30 days);
        m.list(address(a), _one(2), _one(1 ether), block.timestamp + 30 days);
        vm.stopPrank();
        vm.prank(owner);
        m.registerRoyalty(address(a), newRecv, 1000); // receiver changed, same rate
        vm.deal(buyer, 3 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
        assertEq(newRecv.balance, 0.1 ether, "new receiver got the open listing's royalty");
        assertEq(creator.balance, 0);
        vm.prank(owner);
        m.registerRoyalty(address(a), address(0), 0); // deregistered: floor fund at the 2.5% default
        items[0] = M.BuyItem(address(a), 2, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
        assertEq(m.floorFundOf(address(a)), 0.05 ether, "the two sales' fees");
        assertEq(m.royaltyFundOf(address(a)), 0.025 ether, "min(frozen 10%, current 2.5%) into the royalty fund");
    }

    /// F-3: maxPrice bounds the price only. If the owner raises the fee and the seller re-lists at the same
    /// price, a buyer who sends a generous msg.value pays the new fee (bounded by the 5% cap).
    function test_F3_feeNotCoveredByMaxPrice() public {
        vm.prank(owner);
        m.setFee(0);
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 30 days); // buyer sees 1 ETH, 0 fee
        vm.prank(owner);
        m.setFee(500);
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 30 days); // same price, new 5% fee
        vm.deal(buyer, 2 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.prank(buyer);
        m.buy{value: 2 ether}(items, 0); // wallet "sent a bit extra"
        assertEq(buyer.balance, 2 ether - 1.05 ether);
    }

    /// F-4: setting the tip jar (or a registered royalty receiver) to a contract that cannot receive, e.g. the
    /// marketplace itself, strands those payouts in pendingPayouts forever. Only owner misconfiguration.
    function test_F4_tipJarThatCannotReceiveStrandsTips() public {
        vm.prank(owner);
        m.setTipJar(address(m));
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 30 days);
        vm.deal(buyer, 2 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.075 ether}(items, 0.05 ether);
        assertEq(m.pendingPayouts(address(m)), 0.05 ether, "tip parked under the marketplace's own address");
        assertEq(address(m).balance, 0.05 ether + m.floorFundOf(address(a)) + m.royaltyFundOf(address(a)));
    }

    /// F-6 (only on the build with self-serve royalties): a collection's owner() can raise its royalty to
    /// 10% in front of a seller's list() transaction. list() has no max-royalty argument, so the seller's
    /// listing freezes the higher rate and the seller nets 10% less than they saw. Before self-serve only
    /// our own owner could do this.
    function test_F6_creatorCanFrontRunListingRoyalty() public {
        if (!SelfServe.supported(m)) {
            vm.skip(true);
            return;
        }
        InvNFT c = new InvNFT("C");
        c.setOwner(creator);
        vm.prank(owner);
        m.setCollectionAllowed(address(c), true);
        c.mint(seller, 1);
        vm.prank(seller);
        c.setApprovalForAll(address(m), true);
        (, uint256 bpsSeen,) = m.royaltyFor(address(c));
        assertEq(bpsSeen, 250); // what the seller's UI shows
        vm.prank(creator); // front-run
        assertTrue(SelfServe.register(m, address(c), creator, 1000));
        vm.prank(seller);
        m.list(address(c), _one(1), _one(1 ether), block.timestamp + 30 days);
        (,,,,, uint16 frozen) = m.listings(address(c), 1);
        assertEq(frozen, 1000, "seller's listing froze the creator's new 10%");
    }

    /// F-7 (self-serve build): collectionOwner() is documented as "0 if it has none", but it reverts for
    /// an address with no code (and for a contract whose owner() returns malformed data), because a failed
    /// ABI decode in try/catch is not caught. Only a view; registerRoyaltyAsCreator reverts either way.
    function test_F7_collectionOwnerRevertsForNonContract() public {
        if (!SelfServe.supported(m)) {
            vm.skip(true);
            return;
        }
        (bool ok,) = address(m).staticcall(abi.encodeWithSignature("collectionOwner(address)", makeAddr("eoa")));
        assertFalse(ok, "reverts instead of returning 0");
        (ok,) = address(m).staticcall(abi.encodeWithSignature("collectionOwner(address)", address(a)));
        assertTrue(ok, "contract without owner() returns 0");
    }

    function _sellOne(InvNFT c, uint256 id) internal {
        c.mint(seller, id);
        vm.prank(seller);
        c.setApprovalForAll(address(m), true);
        vm.prank(seller);
        m.list(address(c), _one(id), _one(1 ether), block.timestamp + 1 days);
        vm.deal(buyer, buyer.balance + 1.025 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(c), id, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
    }

    /// Floor fund (the fees): only our owner can take it out, to any non-zero wallet; nobody else, creators
    /// included, whatever their registration, allowance or block status.
    function testFuzz_floorFundOnlyOwner(address caller, address to, uint256 amount, bool reg, uint8 pick) public {
        vm.assume(caller != address(0) && to != address(0) && to.code.length == 0 && uint160(to) > 0x10000);
        vm.assume(caller != address(m) && to != address(m));
        if (pick % 3 == 0) caller = owner;
        else if (pick % 3 == 1) caller = creator;
        InvNFT c = new InvNFT("F");
        c.setOwner(creator);
        vm.prank(owner);
        m.setCollectionAllowed(address(c), true);
        if (reg) {
            vm.prank(creator);
            m.registerRoyaltyAsCreator(address(c), creator, 500);
        }
        vm.prank(owner);
        m.setCreatorAllowance(address(c), type(uint256).max); // even an open royalty allowance doesn't help
        _sellOne(c, 1);
        uint256 held = m.floorFundOf(address(c));
        assertEq(held, 0.025 ether);
        amount = bound(amount, 1, held);
        uint256 toBefore = to.balance;
        vm.prank(caller);
        (bool ok,) = address(m).call(abi.encodeCall(M.withdrawFloorFund, (address(c), to, amount)));
        assertEq(ok, caller == owner, "only our owner withdraws the floor fund");
        if (ok) assertEq(to.balance - toBefore, amount);
        assertEq(m.floorFundOf(address(c)), ok ? held - amount : held);
    }

    /// Royalty fund: our owner to itself / the collection's owner(); the collection's owner() only up to its
    /// allowance and while not blocked, to the same two; nobody else.
    function testFuzz_royaltyFundRules(address caller, address to, uint256 amount, uint256 allowance, bool blocked, uint8 pick)
        public
    {
        vm.assume(caller != address(0) && to != address(0) && to.code.length == 0 && uint160(to) > 0x10000);
        vm.assume(caller != address(m) && to != address(m));
        if (pick % 3 == 0) caller = owner;
        else if (pick % 3 == 1) caller = creator;
        if ((pick / 3) % 3 == 0) to = owner;
        else if ((pick / 3) % 3 == 1) to = creator;
        a.setOwner(creator);
        _sellOne(a, 6); // unregistered: 2.5% royalty into the royalty fund
        uint256 held = m.royaltyFundOf(address(a));
        assertEq(held, 0.025 ether);
        allowance = (pick / 9) % 3 == 0 ? type(uint256).max : bound(allowance, 0, held);
        vm.startPrank(owner);
        m.setCreatorAllowance(address(a), allowance);
        if (blocked) m.setSelfServeBlocked(address(a), true);
        vm.stopPrank();
        amount = bound(amount, 1, held);
        uint256 toBefore = to.balance;
        vm.prank(caller);
        (bool ok,) = address(m).call(abi.encodeCall(M.withdrawRoyaltyFund, (address(a), to, amount)));
        bool callerOk = caller == owner || (caller == creator && !blocked && amount <= allowance);
        bool toOk = to == owner || to == creator;
        assertEq(ok, callerOk && toOk, "withdraw allowed iff caller, allowance and recipient allow it");
        if (ok) {
            assertEq(to.balance - toBefore, amount);
            assertEq(m.royaltyFundOf(address(a)), held - amount);
            if (caller != owner && allowance != type(uint256).max) {
                assertEq(m.creatorAllowance(address(a)), allowance - amount, "allowance reduced");
            }
        } else {
            assertEq(m.royaltyFundOf(address(a)), held);
        }
    }

    /// F-8 (fixed in 52655e7): a collection's owner() used to be able to self-register and take the whole
    /// floor fund. Now the fees are owner-only, and the royalty fund only up to the allowance our owner sets.
    function test_F8_fixed_creatorCannotTakeTheFunds() public {
        a.setOwner(creator);
        _sellOne(a, 6);
        assertEq(m.floorFundOf(address(a)), 0.025 ether);
        assertEq(m.royaltyFundOf(address(a)), 0.025 ether);
        vm.startPrank(creator);
        m.registerRoyaltyAsCreator(address(a), creator, 0); // registering no longer unlocks anything
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        m.withdrawFloorFund(address(a), creator, 0.025 ether);
        vm.expectRevert(M.NotAllowedToWithdraw.selector); // no allowance yet
        m.withdrawRoyaltyFund(address(a), creator, 0.025 ether);
        vm.stopPrank();
        vm.prank(owner);
        m.setCreatorAllowance(address(a), 0.01 ether);
        vm.startPrank(creator);
        vm.expectRevert(M.NotAllowedToWithdraw.selector); // over the allowance
        m.withdrawRoyaltyFund(address(a), creator, 0.02 ether);
        m.withdrawRoyaltyFund(address(a), creator, 0.01 ether);
        vm.expectRevert(M.NotAllowedToWithdraw.selector); // allowance used up
        m.withdrawRoyaltyFund(address(a), creator, 1);
        vm.stopPrank();
        assertEq(creator.balance, 0.01 ether);
        assertEq(m.floorFundOf(address(a)), 0.025 ether, "fees untouched");
    }

    /// Tips: accepted up to 5% of the items' cost (price + fee), refused above, and paid only to tipJar.
    function testFuzz_tipCappedAndPaidToTipJar(uint256 price, uint256 tip, bool otherJar) public {
        price = bound(price, 1, type(uint96).max);
        address jar = makeAddr("tipJar");
        if (otherJar) {
            vm.prank(owner);
            m.setTipJar(jar);
        }
        address to = otherJar ? jar : tipJar;
        vm.prank(seller);
        m.list(address(a), _one(1), _one(price), block.timestamp + 1 days);
        uint256 cost = price + (price * 250) / 10_000;
        tip = bound(tip, 0, cost);
        vm.deal(buyer, cost + tip);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, price);
        uint256 before = to.balance;
        vm.prank(buyer);
        (bool ok,) = address(m).call{value: cost + tip}(abi.encodeCall(M.buy, (items, tip)));
        assertEq(ok, tip * 10_000 <= cost * 500, "tip allowed iff <= 5% of cost");
        if (ok) {
            assertEq(to.balance - before, tip, "tip went to the tip jar, and only the tip");
            assertEq(buyer.balance, 0);
        }
    }

    /// Private listings: only the named buyer can buy; the seller gets the full price, no fee, no royalty.
    function testFuzz_privateListingOnlyItsBuyer(address caller, uint256 price) public {
        price = bound(price, 1, type(uint96).max);
        vm.assume(caller != address(0) && caller != seller && caller.code.length == 0 && uint160(caller) > 0x10000);
        vm.prank(seller);
        m.listPrivate(address(a), 1, price, buyer, block.timestamp + 1 days);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, price);
        vm.deal(caller, price);
        vm.prank(caller);
        (bool ok,) = address(m).call{value: price}(abi.encodeCall(M.buy, (items, 0)));
        assertEq(ok, caller == buyer, "only the private buyer can buy");
        if (ok) {
            assertEq(a.ownerOf(1), buyer);
            assertEq(seller.balance, price, "seller got the full price");
            assertEq(m.floorFundOf(address(a)), 0, "no fee");
            assertEq(m.royaltyFundOf(address(a)), 0, "no royalty");
            assertEq(m.privateBuyer(address(a), 1), address(0), "cleared after the sale");
        }
    }

    /// F-12: a private sale emits Sale(price, fee 0, royalty 0). Two colluding wallets can trade any NFT back
    /// and forth for free. The contract is fine with that, but the off-chain rebate must pay a share of the
    /// fee actually paid (Sale.fee), never a share of Sale.price, or this becomes a free money pump.
    function test_F12_privateSaleIsFreeSoRebateMustUseFeePaid() public {
        vm.prank(seller);
        m.listPrivate(address(a), 1, 10 ether, buyer, block.timestamp + 1 days);
        vm.deal(buyer, 10 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 10 ether);
        vm.expectEmit(true, true, true, true, address(m));
        emit M.Sale(address(a), 1, seller, buyer, 10 ether, 0, 0, 0);
        vm.prank(buyer);
        m.buy{value: 10 ether}(items, 0);
        assertEq(seller.balance, 10 ether); // the round trip cost the pair nothing
    }

    /// F-14 (fixed in 52655e7): a registered creator wash-trading their own collection used to get the fee
    /// back from the floor fund. Now the fee stays in a fund only our owner can withdraw, so the round trip
    /// costs exactly the 2.5% fee, more than the 2% rebate (80% of Sale.fee) it earns.
    function test_F14_fixed_creatorWashTradeStillPaysTheFee() public {
        address sellerW = makeAddr("creatorWalletA");
        address buyerW = makeAddr("creatorWalletB");
        InvNFT c = new InvNFT("C");
        c.setOwner(creator);
        vm.startPrank(owner);
        m.setCollectionAllowed(address(c), true);
        m.setCreatorAllowance(address(c), type(uint256).max); // even with an open royalty allowance
        vm.stopPrank();
        vm.prank(creator);
        m.registerRoyaltyAsCreator(address(c), creator, 1000); // royalty to a third wallet of theirs
        c.mint(sellerW, 1);
        vm.prank(sellerW);
        c.setApprovalForAll(address(m), true);
        vm.deal(buyerW, 10.25 ether);
        uint256 groupBefore = sellerW.balance + buyerW.balance + creator.balance;

        vm.prank(sellerW);
        m.list(address(c), _one(1), _one(10 ether), block.timestamp + 1 days);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(c), 1, 10 ether);
        vm.prank(buyerW);
        m.buy{value: 10.25 ether}(items, 0);
        assertEq(m.floorFundOf(address(c)), 0.25 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        m.withdrawFloorFund(address(c), creator, 0.25 ether);
        vm.prank(creator);
        vm.expectRevert(M.AmountTooHigh.selector); // the royalty fund is empty: registered royalties are pushed
        m.withdrawRoyaltyFund(address(c), creator, 0.25 ether);

        uint256 groupAfter = sellerW.balance + buyerW.balance + creator.balance;
        assertEq(groupBefore - groupAfter, 0.25 ether, "the round trip costs exactly the fee");
        assertGt(groupBefore - groupAfter, (0.25 ether * 80) / 100, "more than the 80%-of-fee rebate it earns");
    }

    /// F-15 (fixed in 66ef13d): the allowance stays with the wallet it was granted to. If the collection's
    /// owner() changes hands, the new owner() starts with nothing until our owner grants it one, and the old
    /// holder can't use it either while it is no longer owner().
    function test_F15_fixed_allowanceStaysWithTheWalletItWasGranted() public {
        a.setOwner(creator);
        _sellOne(a, 6);
        vm.prank(owner);
        m.setCreatorAllowance(address(a), type(uint256).max); // granted to `creator`
        assertEq(m.creatorAllowanceHolder(address(a)), creator);
        address newOwner = makeAddr("newCollectionOwner");
        a.setOwner(newOwner); // the collection contract changes hands
        vm.prank(newOwner);
        vm.expectRevert(M.NotAllowedToWithdraw.selector);
        m.withdrawRoyaltyFund(address(a), newOwner, 0.025 ether);
        vm.prank(creator); // the old holder is no longer owner()
        vm.expectRevert(M.NotAllowedToWithdraw.selector);
        m.withdrawRoyaltyFund(address(a), creator, 0.025 ether);
        vm.prank(owner);
        m.setCreatorAllowance(address(a), 0.01 ether); // a fresh grant, to the new owner()
        vm.prank(newOwner);
        m.withdrawRoyaltyFund(address(a), newOwner, 0.01 ether);
        assertEq(newOwner.balance, 0.01 ether);
        // no owner() at all: only a zero allowance can be set
        a.setOwner(address(0));
        vm.prank(owner);
        vm.expectRevert(M.NotCollectionOwner.selector);
        m.setCreatorAllowance(address(a), 1);
    }

    /// For any later owner(): only the wallet the allowance was granted to, while it is owner(), can spend it.
    function testFuzz_allowanceOnlyForItsHolder(address later, bool backToHolder, uint256 amount) public {
        vm.assume(later != address(0) && later != creator && later != owner && later.code.length == 0);
        vm.assume(uint160(later) > 0x10000 && later != address(m));
        a.setOwner(creator);
        _sellOne(a, 6);
        vm.prank(owner);
        m.setCreatorAllowance(address(a), 0.02 ether);
        a.setOwner(later);
        if (backToHolder) a.setOwner(creator);
        amount = bound(amount, 1, 0.02 ether);
        vm.prank(later);
        (bool okLater,) = address(m).call(abi.encodeCall(M.withdrawRoyaltyFund, (address(a), later, amount)));
        vm.prank(creator);
        (bool okHolder,) = address(m).call(abi.encodeCall(M.withdrawRoyaltyFund, (address(a), creator, amount)));
        assertFalse(okLater, "a wallet the allowance was not granted to spent it");
        assertEq(okHolder, backToHolder, "the holder can spend it only while it is owner()");
    }

    /// R2 (b7a1443): a listing of a collection that is no longer allowed is not live, so anyone can clear it,
    /// and it does not come back at its old price when the collection is allowed again.
    function test_disallowedCollectionListingIsStaleAndClearable() public {
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 1 days);
        assertTrue(m.isListingLive(address(a), 1));
        vm.prank(owner);
        m.setCollectionAllowed(address(a), false);
        assertFalse(m.isListingLive(address(a), 1), "not live while the collection is disallowed");
        m.clearStale(address(a), _one(1));
        (address s_,,,,,) = m.listings(address(a), 1);
        assertEq(s_, address(0), "cleared");
        vm.prank(owner);
        m.setCollectionAllowed(address(a), true);
        assertFalse(m.isListingLive(address(a), 1), "does not come back");
    }

    /// F-5 (fixed): renounceOwnership is disabled, so the marketplace can never become ownerless.
    function test_F5_renounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(M.RenounceDisabled.selector);
        m.renounceOwnership();
        assertEq(m.owner(), owner);
    }
}

/// Property harness for Medusa / Echidna: the same Handler, deployed by its own constructor, with the
/// invariants exposed as boolean properties (Medusa prefix property_, Echidna prefix echidna_).
/// Commands and configs are in docs/AUDIT-SELF-REVIEW.md.
contract MarketplaceV3PropertyHarness is Handler {
    function _solvent() internal view returns (bool) {
        uint256 esc;
        uint256 n = m.offerCount();
        for (uint256 i = 1; i <= n; ++i) {
            (address bidder, uint96 price,,, uint16 fee,, uint16 remaining,) = m.offers(i);
            if (bidder != address(0)) esc += (uint256(price) + (uint256(price) * fee) / 10_000) * remaining;
        }
        uint256 pend;
        for (uint256 i; i < tracked.length; ++i) {
            pend += m.pendingPayouts(tracked[i]);
        }
        for (uint256 c; c < 3; ++c) {
            pend += m.floorFundOf(address(nfts[c])) + m.royaltyFundOf(address(nfts[c]));
            if (m.floorFundOf(address(nfts[c])) != gFloorFund[address(nfts[c])]) return false;
            if (m.royaltyFundOf(address(nfts[c])) != gRoyFund[address(nfts[c])]) return false;
        }
        return address(m).balance == esc + pend && esc == ghostEscrow;
    }

    function _capsOk() internal view returns (bool) {
        return m.feeBps() <= m.MAX_FEE_BPS() && m.defaultRoyaltyBps() <= m.MAX_ROYALTY_BPS();
    }

    function property_balanceEqualsEscrowPlusPending() external view returns (bool) {
        return _solvent();
    }

    function property_noHandlerViolations() external view returns (bool) {
        return violations.length == 0;
    }

    function property_capsHold() external view returns (bool) {
        return _capsOk();
    }

    function _allowanceOk() internal view returns (bool) {
        if (badAllowanceSpends != 0) return false;
        for (uint256 c; c < 3; ++c) {
            address col = address(nfts[c]);
            if (m.creatorAllowance(col) != gAllowance[col]) return false;
            if (m.creatorAllowanceHolder(col) != gHolder[col]) return false;
            if (gAllowanceSet[col] != type(uint256).max && gCreatorTaken[col] > gAllowanceSet[col]) return false;
        }
        return true;
    }

    function property_creatorAllowanceNeverExceeded() external view returns (bool) {
        return _allowanceOk();
    }

    function echidna_creatorAllowanceNeverExceeded() external view returns (bool) {
        return _allowanceOk();
    }

    function echidna_balanceEqualsEscrowPlusPending() external view returns (bool) {
        return _solvent();
    }

    function echidna_noHandlerViolations() external view returns (bool) {
        return violations.length == 0;
    }

    function echidna_capsHold() external view returns (bool) {
        return _capsOk();
    }

    function property_signedStateMatchesModel() external view returns (bool) {
        return bytes(signedStateMismatch()).length == 0;
    }

    function echidna_signedStateMatchesModel() external view returns (bool) {
        return bytes(signedStateMismatch()).length == 0;
    }
}

/// Halmos symbolic-execution cheatcodes (https://github.com/a16z/halmos-cheatcodes), declared inline.
interface ISVM {
    function createCalldata(string memory contractName) external pure returns (bytes memory);
    function createAddress(string memory name) external pure returns (address);
}

/// Symbolic checks, run with Halmos (`halmos --contract MarketplaceV3SymbolicTest`). Named check_ so
/// `forge test` skips them. Each proves its property for ALL values of the symbolic inputs (within Halmos's
/// loop / array-length bounds), not just sampled ones.
contract MarketplaceV3SymbolicTest is Test {
    ISVM internal constant svm = ISVM(address(uint160(uint256(keccak256("svm cheat code")))));
    M m;
    InvNFT a;
    InvNFT b;
    address owner = address(0x1000);
    address tipJar = address(0x2000);
    address seller = address(0x4000);
    address bidder = address(0x5000);
    address creator = address(0x6000);

    function setUp() public {
        m = new M(owner, tipJar, 250, 250);
        a = new InvNFT("A");
        b = new InvNFT("B");
        vm.startPrank(owner);
        m.setCollectionAllowed(address(a), true);
        m.setCollectionAllowed(address(b), true);
        vm.stopPrank();
        a.mint(seller, 1);
        a.mint(seller, 2);
        b.mint(seller, 1);
        vm.startPrank(seller);
        a.setApprovalForAll(address(m), true);
        b.setApprovalForAll(address(m), true);
        vm.stopPrank();
    }

    function _one(uint256 x) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = x;
    }

    /// For every price, at the launch rates (2.5% / 2.5%) and at the caps (5% / 10%), registered or not: the
    /// buyer pays exactly price + fee, everything is paid out or held as the floor fund, and the split
    /// respects the caps. (Rates are concrete because symbolic price * symbolic bps is too slow for the
    /// solver; the stateful fuzzers cover random rates.)
    function check_buySplitConservesAndRespectsCaps(uint96 price, uint64 over, bool caps, bool registered) public {
        vm.assume(price > 0);
        uint16 feeBps = caps ? 500 : 250;
        uint16 royBps = caps ? 1000 : 250;
        vm.startPrank(owner);
        m.setFee(feeBps);
        if (registered) m.registerRoyalty(address(a), creator, royBps);
        else m.setDefaultRoyalty(royBps);
        vm.stopPrank();
        vm.deal(creator, 0);
        vm.deal(seller, 0);
        vm.prank(seller);
        m.list(address(a), _one(1), _one(price), block.timestamp + 1 days);
        uint256 fee = (uint256(price) * feeBps) / 10_000;
        uint256 value = uint256(price) + fee + over;
        address buyer = address(0x7000);
        vm.deal(buyer, value);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, price);
        vm.prank(buyer);
        m.buy{value: value}(items, 0);
        uint256 floor = m.floorFundOf(address(a)) + m.royaltyFundOf(address(a));
        assert(m.floorFundOf(address(a)) == fee); // the fee, and only the fee, in the floor fund
        assert(a.ownerOf(1) == buyer);
        assert(buyer.balance == over);
        // seller + royalty receiver + floor fund + royalty fund == everything the buyer paid
        assert(seller.balance + creator.balance + floor == uint256(price) + fee);
        // the seller loses at most the 10% royalty cap
        assert((uint256(price) - seller.balance) * 10_000 <= uint256(price) * 1000);
        assert(address(m).balance == floor);
    }

    /// For every price, an offer for 2 NFTs: fill 0 or 1, cancel the rest -> the contract keeps only the floor
    /// fund, and the bidder got back exactly the unfilled escrow. (Quantity is concrete: symbolic price *
    /// symbolic quantity times out the solver.)
    function check_offerFillAndCancelLeavesNothing(uint96 price, bool fillOne) public {
        vm.assume(price > 0);
        uint256 qty = 2;
        uint256 unit = uint256(price) + (uint256(price) * 250) / 10_000;
        vm.deal(bidder, unit * qty);
        vm.prank(bidder);
        uint256 oid = m.placeOffer{value: unit * qty}(address(a), price, qty, block.timestamp + 1 days, bytes32(0));
        uint256 filled;
        if (fillOne) {
            vm.prank(seller);
            m.acceptOffer(oid, _one(1), new bytes32[][](0));
            filled = 1;
        }
        if (filled < qty) {
            vm.prank(bidder);
            m.cancelOffer(oid);
        }
        assert(address(m).balance == m.floorFundOf(address(a)) + m.royaltyFundOf(address(a)));
        assert(bidder.balance == unit * (qty - filled));
    }

    /// An offer on collection B can never move a token of collection A, whatever token id the seller passes.
    function check_offerOnlyTakesItsOwnCollection(uint256 id) public {
        vm.deal(bidder, 2 ether);
        vm.prank(bidder);
        uint256 oid = m.placeOffer{value: 1.025 ether}(address(b), 1 ether, 1, block.timestamp + 1 days, bytes32(0));
        vm.prank(seller);
        (bool ok,) = address(m).call(abi.encodeCall(M.acceptOffer, (oid, _one(id), new bytes32[][](0))));
        assert(a.ownerOf(1) == seller && a.ownerOf(2) == seller);
        if (ok) assert(id == 1 && b.ownerOf(1) == bidder);
    }

    /// ANY single call, by ANY sender other than the bidder / seller (our owner included), with any calldata
    /// and value: the bidder's money (balance + pending + live escrow) never drops unless they got an NFT for
    /// it at their price, an unlisted NFT never leaves the seller, and a listed one only with the seller paid.
    function check_anySingleCallCannotTakeBidderOrSellerAssets(uint256 value) public {
        vm.deal(bidder, 10 ether);
        vm.deal(seller, 0);
        vm.prank(bidder);
        uint256 oid = m.placeOffer{value: 2.05 ether}(address(a), 1 ether, 2, block.timestamp + 1 days, bytes32(0));
        vm.prank(seller);
        m.list(address(a), _one(1), _one(3 ether), block.timestamp + 1 days);

        address sender = svm.createAddress("sender");
        vm.assume(sender != bidder && sender != seller && sender != address(m) && sender != address(0));
        vm.assume(value <= 100 ether);
        vm.deal(sender, value);
        bytes memory data = svm.createCalldata("PentagonMarketplaceV3");

        uint256 bidderWorthBefore = bidder.balance + m.pendingPayouts(bidder) + _escrow(oid);
        uint256 sellerEthBefore = seller.balance + m.pendingPayouts(seller);
        vm.prank(sender);
        (bool ok,) = address(m).call{value: value}(data);
        ok;

        uint256 bidderWorthAfter = bidder.balance + m.pendingPayouts(bidder) + _escrow(oid);
        uint256 bidderNfts = (a.ownerOf(1) == bidder ? 1 : 0) + (a.ownerOf(2) == bidder ? 1 : 0);
        assert(
            bidderWorthAfter >= bidderWorthBefore || bidderWorthBefore - bidderWorthAfter == bidderNfts * 1.025 ether
        );
        assert(a.ownerOf(2) == seller); // not listed: only the seller can sell it
        if (a.ownerOf(1) != seller) {
            assert(seller.balance + m.pendingPayouts(seller) - sellerEthBefore == 3 ether - (3 ether * 250) / 10_000);
        }
    }

    /// ANY single call by ANY sender, with any calldata and value: the floor fund (fees) only decreases when our
    /// owner calls; the royalty fund only decreases when our owner calls, or the collection's owner() within its
    /// allowance, and then the whole decrease reaches our owner or the collection's owner().
    function check_floorFundOnlyLeavesToAllowed(uint256 value, bool allow) public {
        a.setOwner(creator);
        vm.deal(owner, 0);
        vm.deal(creator, 0);
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 1 days);
        address buyer = address(0x7000);
        vm.deal(buyer, 2 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
        if (allow) {
            vm.prank(owner);
            m.setCreatorAllowance(address(a), 0.01 ether);
        }
        uint256 floorBefore = m.floorFundOf(address(a));
        uint256 royBefore = m.royaltyFundOf(address(a));

        address sender = svm.createAddress("sender");
        vm.assume(sender != address(0) && sender != address(m));
        vm.assume(value <= 100 ether);
        vm.deal(sender, value);
        uint256 before = owner.balance + creator.balance;
        bytes memory data = svm.createCalldata("PentagonMarketplaceV3");
        vm.prank(sender);
        (bool ok,) = address(m).call{value: value}(data);
        ok;

        uint256 floorAfter = m.floorFundOf(address(a));
        uint256 royAfter = m.royaltyFundOf(address(a));
        assert(floorAfter <= floorBefore && royAfter <= royBefore); // no sale of collection a is possible
        if (floorAfter < floorBefore) assert(sender == owner);
        if (royAfter < royBefore) {
            assert(sender == owner || (allow && sender == creator && royBefore - royAfter <= 0.01 ether));
            // withdrawRoyaltyFund is not payable, so the whole decrease must reach our owner / the creator
            if (floorAfter == floorBefore) assert(owner.balance + creator.balance - before == royBefore - royAfter);
        }
    }

    function _escrow(uint256 oid) internal view returns (uint256) {
        (address bd, uint96 p,,, uint16 f,, uint16 rem,) = m.offers(oid);
        return bd == address(0) ? 0 : (uint256(p) + (uint256(p) * f) / 10_000) * rem;
    }

    /// For ANY caller: a private listing can only be bought by its named buyer.
    function check_privateListingOnlyItsBuyer(address caller) public {
        vm.assume(caller != address(0) && caller != seller && caller != address(m));
        vm.prank(seller);
        m.listPrivate(address(a), 1, 1 ether, bidder, block.timestamp + 1 days);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        (bool ok,) = address(m).call{value: 1 ether}(abi.encodeCall(M.buy, (items, 0)));
        if (ok) assert(caller == bidder && a.ownerOf(1) == bidder);
        else assert(a.ownerOf(1) == seller);
    }

    /// Nobody but the owner can use an owner power.
    function check_nonOwnerCannotUseOwnerPowers(address caller) public {
        vm.assume(caller != owner && caller != address(0)); // no tx has msg.sender 0; guardian 0 = none
        vm.startPrank(caller);
        (bool ok1,) = address(m).call(abi.encodeCall(M.renounceOwnership, ()));
        (bool ok2,) = address(m).call(abi.encodeCall(M.setGuardian, (caller)));
        (bool ok3,) = address(m).call(abi.encodeCall(M.registerRoyalty, (address(a), caller, 1000)));
        (bool ok4,) = address(m).call(abi.encodeCall(M.setFee, (500)));
        (bool ok5,) = address(m).call(abi.encodeCall(M.pause, ()));
        (bool ok6,) = address(m).call(abi.encodeCall(M.refundOffers, (_one(1))));
        (bool ok7,) = address(m).call(abi.encodeCall(M.setCollectionAllowed, (address(a), false)));
        (bool ok8,) = address(m).call(abi.encodeCall(M.setTipJar, (caller)));
        (bool ok9,) = address(m).call(abi.encodeCall(M.setCreatorAllowance, (address(a), type(uint256).max)));
        vm.stopPrank();
        assert(!ok1 && !ok2 && !ok3 && !ok4 && !ok5 && !ok6 && !ok7 && !ok8 && !ok9);
    }
}

interface I721 {
    function ownerOf(uint256) external view returns (address);
    function transferFrom(address, address, uint256) external;
    function setApprovalForAll(address, bool) external;
    function isApprovedForAll(address, address) external view returns (bool);
    function getApproved(uint256) external view returns (address);
}

/// Read-only mainnet-fork check (skipped unless ETH_RPC is set):
///   ETH_RPC=<mainnet rpc> forge test --match-contract LaunchCollectionsForkTest -vv
/// Checks of the 31 launch collections against what MarketplaceV3 relies on:
/// transferFrom reverts for an unapproved operator and for a wrong `from`, moves ownership when approved,
/// and a full list -> buy and offer -> accept round trip works and pays out.
contract LaunchCollectionsForkTest is Test {
    // docs/LAUNCH-COLLECTIONS-ETH.md, 6c34b7c
    address[31] cs = [
        0x524cAB2ec69124574082676e6F654a18df49A048,
        0xc3f733ca98E0daD0386979Eb96fb1722A1A05E69,
        0x7Bd29408f11D2bFC23c34f18275bBf23bB716Bc7,
        0x306b1ea3ecdf94aB739F1910bbda052Ed4A9f949,
        0x49cF6f5d44E70224e2E23fDcdd2C053F30aDA28B,
        0x60E4d786628Fea6478F785A6d7e704777c86a7c6,
        0xB6a37b5d14D502c3Ab0Ae6f3a0E058BC9517786e,
        0x1D20A51F088492A0f1C57f047A9e30c9aB5C07Ea,
        0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D,
        0xe785E82358879F061BC3dcAC6f0444462D4b5330,
        0xED5AF388653567Af2F388E6224dC7C4b3241C544,
        0x8a90CAb2b38dba80c64b7734e58Ee1dB38B8992e,
        0x23581767a106ae21c074b2276D25e5C3e136a68b,
        0x5Af0D9827E0c53E4799BB226655A1de152A425a5,
        0x099689220846644F87D1137665CDED7BF3422747,
        0xF75140376D246D8B1E5B8a48E3f00772468b3c0c,
        0xba30E5F9Bb24caa003E9f2f0497Ad287FDF95623,
        0xBd3531dA5CF5857e7CfAA92426877b022e612cf8,
        0x6bE69b2A9B153737887CfcdCa7781eD1511C7e36,
        0x80336Ad7A747236ef41F47ed2C7641828a480BAA,
        0x10D2d273cb8F6179F1dDd2EE5689cdcE363B9A01,
        0x28cD2990F34db387D011D7cC693A2Bcedd8dc654,
        0x67abaDDb1258077F7900abD8AdE0EcC6CdC38ac2,
        0x2094e4F1ad01438eCA93092e87033F87d8f76f63,
        0xD3D9ddd0CF0A5F0BFB8f7fcEAe075DF687eAEBaB,
        0x9f4564b85Cb77cE76Cc725F29758cbfe20213aAE,
        0x5D00d312e171Be5342067c09BaE883f9Bcb2003B,
        0xfA69031b8f84ADE91d1faC52148363842637699a,
        0x2A2Ad5A2eacF35194d39AFE1d727C39710ff0379,
        0x4fe99deb8f0be517C31fAAAD49b4b054Ed28c267,
        0x3CD41EC039c1F2DD1f76144bb3722E7b503f50ab

    ];

    function _owned(I721 c) internal view returns (bool, uint256, address) {
        for (uint256 id; id < 60; ++id) {
            try c.ownerOf(id) returns (address o) {
                if (o != address(0) && o.code.length == 0) return (true, id, o);
            } catch {}
        }
        for (uint256 k; k < 40; ++k) {
            (bool ok, bytes memory r) = address(c).staticcall(abi.encodeWithSignature("tokenByIndex(uint256)", k));
            if (!ok || r.length < 32) break;
            uint256 id = abi.decode(r, (uint256));
            try c.ownerOf(id) returns (address o) {
                if (o != address(0) && o.code.length == 0) return (true, id, o);
            } catch {}
        }
        for (uint256 id = 60; id < 3000; id += 7) {
            try c.ownerOf(id) returns (address o) {
                if (o != address(0) && o.code.length == 0) return (true, id, o);
            } catch {}
        }
        return (false, 0, address(0));
    }

    M m;
    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");

    function test_launchCollections() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        m = new M(owner, makeAddr("tipJar"), 250, 250);
        uint256 bad;
        for (uint256 i; i < cs.length; ++i) {
            if (vm.envOr("ONLY", address(0)) != address(0) && cs[i] != vm.envOr("ONLY", address(0))) continue;
            try this.one(cs[i]) returns (bool allOk) {
                if (!allOk) ++bad;
            } catch (bytes memory err) {
                ++bad;
                console2.log("FAIL (reverted)", cs[i]);
                console2.logBytes(err);
            }
        }
        console2.log("collections failing a check:", bad);
        console2.log("fork block:", block.number);
    }

    function one(address ca) external returns (bool allOk) {
        I721 c = I721(ca);
        (bool found, uint256 id, address holder) = _owned(c);
        if (!found) {
            console2.log("SKIP (no EOA-held token in ids 0..59)", ca);
            return true;
        }
        vm.prank(owner);
        m.setCollectionAllowed(ca, true);
        vm.prank(address(m));
        (bool ok,) = ca.call(abi.encodeCall(I721.transferFrom, (holder, stranger, id)));
        bool unapprovedBlocked = !ok || c.ownerOf(id) == holder;
        vm.prank(holder);
        c.setApprovalForAll(address(m), true);
        vm.prank(address(m));
        (ok,) = ca.call(abi.encodeCall(I721.transferFrom, (stranger, buyer, id)));
        bool wrongFromBlocked = !ok || c.ownerOf(id) == holder;
        uint256[] memory ids = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        ids[0] = id;
        prices[0] = 1 ether;
        vm.prank(holder);
        m.list(ca, ids, prices, block.timestamp + 1 days);
        bool live = m.isListingLive(ca, id);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(ca, id, 1 ether);
        vm.deal(buyer, 2 ether);
        uint256 before = holder.balance;
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
        bool bought = c.ownerOf(id) == buyer && holder.balance - before == 0.975 ether;
        vm.deal(stranger, 2 ether);
        vm.prank(stranger);
        uint256 oid = m.placeOffer{value: 1.025 ether}(ca, 1 ether, 1, block.timestamp + 1 days, bytes32(0));
        vm.prank(holder);
        (ok,) = address(m).call(abi.encodeCall(M.acceptOffer, (oid, ids, new bytes32[][](0))));
        bool exHolderBlocked = !ok && c.ownerOf(id) == buyer;
        vm.prank(buyer);
        c.setApprovalForAll(address(m), true);
        vm.prank(buyer);
        m.acceptOffer(oid, ids, new bytes32[][](0));
        bool filled = c.ownerOf(id) == stranger;
        allOk = unapprovedBlocked && wrongFromBlocked && live && bought && exHolderBlocked && filled;
        console2.log(string.concat(allOk ? "OK   " : "FAIL ", vm.toString(ca), " id ", vm.toString(id)));
        if (!allOk) {
            console2.log(unapprovedBlocked, wrongFromBlocked, live);
            console2.log(bought, exHolderBlocked, filled);
        }
    }
}
