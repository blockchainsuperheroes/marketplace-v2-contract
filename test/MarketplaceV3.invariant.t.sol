// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {PentagonMarketplaceV3 as M} from "../src/MarketplaceV3.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

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
        }
    }
}

contract Handler is Test {
    M public m;
    address public owner;
    InvNFT[3] internal nfts; // 0 and 1 allowed at start, 2 not
    address[] internal actors;
    TrickyWallet[] internal wallets;
    address[] internal treasuries;
    address[] internal receivers;
    address[] public tracked;
    uint256 internal constant TOKENS = 6;

    // ── independent model of owner settings ──
    uint16 public gFee = 250;
    uint16 public gDefRoy = 250;
    address public gTreasury;
    mapping(address => uint256) public gFloorFund; // model of floorFundOf
    address public gTipJar;
    mapping(address => mapping(uint256 => address)) internal gPriv; // model of privateBuyer
    bool public gPaused;
    mapping(address => bool) public gAllowed;
    mapping(address => address) public gRegRecv;
    mapping(address => uint16) public gRegBps;
    mapping(address => bool) public gBlocked;
    bool public selfServe;
    address public gGuardian;

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

    constructor() {
        owner = makeAddr("owner");
        address t1 = makeAddr("treasury1");
        m = new M(owner, t1, 250, 250);
        gTreasury = t1;
        gTipJar = t1; // the constructor sets the tip jar to the treasury
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
        treasuries.push(t1);
        treasuries.push(makeAddr("treasury2"));
        treasuries.push(address(wallets[2]));
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
        for (uint256 i; i < treasuries.length; ++i) tracked.push(treasuries[i]);
        tracked.push(address(wallets[3])); // a spare smart wallet (was the floor-fund wallet before 1049d1f)
        for (uint256 i; i < receivers.length; ++i) tracked.push(receivers[i]);
        tracked.push(owner);
        tracked.push(makeAddr("stranger"));
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

    /// Expect a royalty: pushed to the registered receiver, or (unregistered) held in floorFundOf[c].
    function _expRoy(address c, uint256 roy) internal {
        if (gRegRecv[c] != address(0)) {
            _exp(gRegRecv[c], int256(roy));
        } else {
            _eFloor[_ci(c)] += int256(roy);
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
            _exp(gTreasury, int256(fee));
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
            _exp(gTreasury, int256(fee));
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

    function ownerSetTreasury(uint256 seed) external {
        address t = treasuries[seed % treasuries.length];
        _begin();
        vm.prank(owner);
        m.setTreasury(t);
        gTreasury = t;
        _end(true, "ownerSetTreasury");
    }

    /// Someone (our owner, the collection's owner(), or a stranger) withdraws a collection's floor fund to
    /// someone. Allowed: caller = our owner, or the collection's owner() once registered and not blocked;
    /// recipient = our owner or the collection's owner(). Anything else succeeding is a violation.
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
        bool callerOk = caller == owner
            || (cOwner != address(0) && caller == cOwner && gRegRecv[c] != address(0) && !gBlocked[c]);
        bool toOk = to == owner || (cOwner != address(0) && to == cOwner);
        _begin();
        _exp(to, int256(amount));
        _eFloor[_ci(c)] = -int256(amount);
        bool ok;
        vm.prank(caller);
        try m.withdrawFloorFund(c, to, amount) {
            ok = true;
        } catch {}
        if (ok) {
            if (!callerOk) _v("withdrawFloorFund: a caller who may not withdraw did");
            if (!toOk) _v("withdrawFloorFund: paid a recipient other than our owner / the collection owner");
            if (amount > bal) _v("withdrawFloorFund: withdrew more than the fund held");
        }
        _end(ok, "withdrawFloorFund");
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
        address t = seed % 4 == 3 ? address(wallets[3]) : treasuries[seed % treasuries.length];
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
        uint8 w = which % 12;
        if (w == 0) try m.setFee(1) { ok = true; } catch {}
        if (w == 1) try m.setDefaultRoyalty(0) { ok = true; } catch {}
        if (w == 2) try m.registerRoyalty(address(nfts[0]), who, 1000) { ok = true; } catch {}
        if (w == 3) try m.setTreasury(who) { ok = true; } catch {}
        if (w == 4 && who != nfts[0].owner()) {
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
        vm.stopPrank();
        if (ok) _v("strangerAdmin: a non-owner used an owner power");
        _end(ok, "strangerAdmin");
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
        bytes4[] memory s = new bytes4[](42);
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
        s[17] = Handler.ownerSetTreasury.selector;
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
        for (uint256 c; c < 3; ++c) {
            floors += m.floorFundOf(h.nft(c));
            assertEq(m.floorFundOf(h.nft(c)), h.gFloorFund(h.nft(c)), "floorFundOf != model");
        }
        assertEq(address(m).balance, esc + pend + floors, "balance != escrow + pending + floor funds");
        assertEq(esc, h.ghostEscrow(), "on-chain escrow != model escrow");
    }

    /// Every per-call check in the handler (payment splits, NFT moves, who may do what) held.
    function invariant_noHandlerViolations() public view {
        if (h.violationCount() > 0) {
            assertTrue(false, h.violations(0));
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
        assertEq(m.treasury(), h.gTreasury());
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

    function afterInvariant() public view {
        uint256 k = h.callKeyCount();
        string[30] memory names = [
            "list", "delist", "incrementNonce", "clearStale", "buy", "placeOffer", "acceptOffer", "cancelOffer",
            "withdraw", "ownerSetFee", "ownerSetDefaultRoyalty", "ownerRegisterRoyalty", "ownerSetTreasury",
            "withdrawFloorFund", "ownerSetAllowed", "ownerPause", "ownerRefundOffers", "strangerAdmin",
            "creatorRegisterRoyalty", "ownerSetSelfServeBlocked", "withdrawFor", "ownerSetGuardian", "guardianPause",
            "listPrivate", "ownerSetTipJar",
            "", "", "", "", ""
        ];
        k;
        console2.log("self-serve royalties present in this build", h.selfServe());
        for (uint256 i; i < 25; ++i) {
            console2.log(
                names[i],
                h.calls(keccak256(abi.encodePacked(names[i], ".ok"))),
                h.calls(keccak256(abi.encodePacked(names[i], ".revert")))
            );
        }
        console2.log("pending total wallets / escrow", address(m).balance, h.ghostEscrow());
    }
}

/// Stateless fuzz tests on the payment maths.
contract MarketplaceV3FuzzTest is Test {
    M m;
    InvNFT a;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address creator = makeAddr("creator");

    function setUp() public {
        m = new M(owner, treasury, 250, 250);
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
        assertEq(treasury.balance, fee);
        if (registered) assertEq(creator.balance, roy);
        else assertEq(m.floorFundOf(address(a)), roy, "unregistered royalty held as the floor fund");
        assertEq(seller.balance, price - roy);
        assertLe(fee, (price * 500) / 10_000);
        assertLe(roy, (price * 1000) / 10_000);
        assertEq(address(m).balance, registered ? 0 : roy);
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
        assertEq(address(m).balance, roy * fill, "only the floor fund is left");
        assertEq(buyer.balance, (price + fee) * (qty - fill), "unfilled part refunded");
        assertEq(treasury.balance, fee * fill);
        assertEq(m.floorFundOf(address(a)), roy * fill);
        assertEq(seller.balance, (price - roy) * fill);
    }

    /// Whatever the owner does while offers and pending payouts exist, the escrow stays put; the only owner
    /// path that moves escrow (refundOffers) pays the bidder.
    function testFuzz_ownerCannotMoveEscrow(uint256 seed, address newTreasury, address newRecv) public {
        vm.assume(newTreasury != address(0) && newRecv != address(0));
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
            if (r == 3) m.setTreasury(newTreasury);
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
        assertEq(m.floorFundOf(address(a)), 0.025 ether, "min(frozen 10%, current 2.5%) into the floor fund");
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

    /// F-4: setting the treasury (or floor fund / a royalty receiver) to a contract that cannot receive,
    /// e.g. the marketplace itself, strands fees in pendingPayouts forever. Only owner misconfiguration.
    function test_F4_treasuryThatCannotWithdrawStrandsFees() public {
        vm.prank(owner);
        m.setTreasury(address(m));
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 30 days);
        vm.deal(buyer, 2 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
        assertEq(m.pendingPayouts(address(m)), 0.025 ether, "fee parked under the marketplace's own address");
        assertEq(address(m).balance, 0.025 ether + m.floorFundOf(address(a)));
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

    /// Floor fund: whoever calls, to whomever, it only ever leaves to our owner or the collection's owner(),
    /// and only our owner or a registered, unblocked collection owner() can take it out.
    function testFuzz_floorFundOnlyToAllowed(
        address caller,
        address to,
        uint256 amount,
        bool reg,
        bool blocked,
        uint8 pick
    ) public {
        vm.assume(caller != address(0) && to != address(0) && to.code.length == 0 && uint160(to) > 0x10000);
        vm.assume(caller != address(m) && to != address(m));
        // bias caller / recipient towards the interesting parties: our owner, the creator, a stranger
        if (pick % 3 == 0) caller = owner;
        else if (pick % 3 == 1) caller = creator;
        if ((pick / 3) % 3 == 0) to = owner;
        else if ((pick / 3) % 3 == 1) to = creator;
        a.setOwner(creator);
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 1 days);
        vm.deal(buyer, 2 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
        uint256 held = m.floorFundOf(address(a));
        assertEq(held, 0.025 ether);
        if (reg) {
            vm.prank(creator);
            m.registerRoyaltyAsCreator(address(a), creator, 500);
        }
        if (blocked) {
            vm.prank(owner);
            m.setSelfServeBlocked(address(a), true);
        }
        amount = bound(amount, 1, held);
        uint256 toBefore = to.balance;
        vm.prank(caller);
        (bool ok,) = address(m).call(abi.encodeCall(M.withdrawFloorFund, (address(a), to, amount)));
        bool callerOk = caller == owner || (caller == creator && reg && !blocked);
        bool toOk = to == owner || to == creator;
        assertEq(ok, callerOk && toOk, "withdraw allowed iff caller and recipient are allowed");
        if (ok) {
            assertEq(to.balance - toBefore, amount);
            assertEq(m.floorFundOf(address(a)), held - amount);
        } else {
            assertEq(m.floorFundOf(address(a)), held);
        }
    }

    /// F-8: the floor fund of an unregistered collection, including everything accrued BEFORE any
    /// registration, can be taken by whoever the collection contract names as owner(), in two transactions:
    /// self-register a royalty, then withdrawFloorFund to themselves. Per the header this is intended; it
    /// means the floor fund is only as safe as each collection's owner() key, unless self-serve is blocked.
    function test_F8_collectionOwnerCanSelfRegisterAndTakeTheFloorFund() public {
        a.setOwner(creator);
        vm.prank(seller);
        m.list(address(a), _one(1), _one(1 ether), block.timestamp + 1 days);
        vm.deal(buyer, 2 ether);
        M.BuyItem[] memory items = new M.BuyItem[](1);
        items[0] = M.BuyItem(address(a), 1, 1 ether);
        vm.prank(buyer);
        m.buy{value: 1.025 ether}(items, 0);
        assertEq(m.floorFundOf(address(a)), 0.025 ether); // accrued while unregistered, for our floor buys
        vm.startPrank(creator);
        m.registerRoyaltyAsCreator(address(a), creator, 0); // even a 0% registration is enough
        m.withdrawFloorFund(address(a), creator, 0.025 ether);
        vm.stopPrank();
        assertEq(creator.balance, 0.025 ether);
        assertEq(m.floorFundOf(address(a)), 0);
    }

    /// Tips: accepted up to 5% of the items' cost (price + fee), refused above, and paid only to tipJar.
    function testFuzz_tipCappedAndPaidToTipJar(uint256 price, uint256 tip, bool otherJar) public {
        price = bound(price, 1, type(uint96).max);
        address jar = makeAddr("tipJar");
        if (otherJar) {
            vm.prank(owner);
            m.setTipJar(jar);
        }
        address to = otherJar ? jar : treasury;
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
            uint256 feeToTreasury = otherJar ? 0 : (price * 250) / 10_000;
            assertEq(to.balance - before, tip + feeToTreasury, "tip went to the tip jar");
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
            assertEq(treasury.balance, 0, "no fee");
            assertEq(m.floorFundOf(address(a)), 0, "no royalty");
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

    /// F-5: renounceOwnership (inherited) is callable. Renouncing while paused freezes trading for good;
    /// exits (cancelOffer, withdraw, delist) still work, so no funds are lost.
    function test_F5_renounceWhilePausedLeavesExitsWorking() public {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        uint256 oid = m.placeOffer{value: 1.025 ether}(address(a), 1 ether, 1, block.timestamp + 1 days, bytes32(0));
        vm.startPrank(owner);
        m.pause();
        m.renounceOwnership();
        vm.stopPrank();
        assertEq(m.owner(), address(0));
        vm.prank(buyer);
        m.cancelOffer(oid);
        assertEq(buyer.balance, 2 ether);
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
            pend += m.floorFundOf(address(nfts[c]));
            if (m.floorFundOf(address(nfts[c])) != gFloorFund[address(nfts[c])]) return false;
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

    function echidna_balanceEqualsEscrowPlusPending() external view returns (bool) {
        return _solvent();
    }

    function echidna_noHandlerViolations() external view returns (bool) {
        return violations.length == 0;
    }

    function echidna_capsHold() external view returns (bool) {
        return _capsOk();
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
    address treasury = address(0x2000);
    address seller = address(0x4000);
    address bidder = address(0x5000);
    address creator = address(0x6000);

    function setUp() public {
        m = new M(owner, treasury, 250, 250);
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
        vm.deal(treasury, 0);
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
        uint256 roy = registered ? creator.balance : m.floorFundOf(address(a));
        assert(a.ownerOf(1) == buyer);
        assert(buyer.balance == over);
        assert(treasury.balance + roy + seller.balance == uint256(price) + fee);
        assert(treasury.balance * 10_000 <= uint256(price) * 500);
        assert(roy * 10_000 <= uint256(price) * 1000);
        assert(address(m).balance == (registered ? 0 : roy));
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
        assert(address(m).balance == m.floorFundOf(address(a)));
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

    /// ANY single call by ANY sender, with any calldata and value: a collection's floor fund only decreases
    /// by an amount that our owner or the collection's owner() received, and only our owner or the
    /// (registered) collection owner can make it decrease.
    function check_floorFundOnlyLeavesToAllowed(uint256 value, bool reg) public {
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
        if (reg) {
            vm.prank(creator);
            m.registerRoyaltyAsCreator(address(a), creator, 500);
        }
        uint256 held = m.floorFundOf(address(a));

        address sender = svm.createAddress("sender");
        vm.assume(sender != address(0) && sender != address(m));
        vm.assume(value <= 100 ether);
        vm.deal(sender, value);
        uint256 before = owner.balance + creator.balance;
        bytes memory data = svm.createCalldata("PentagonMarketplaceV3");
        vm.prank(sender);
        (bool ok,) = address(m).call{value: value}(data);
        ok;

        uint256 after_ = m.floorFundOf(address(a));
        assert(after_ <= held); // nothing in a single call can add to it (no sale of collection a is possible)
        if (after_ < held) {
            assert(sender == owner || (reg && sender == creator));
            // withdrawFloorFund is not payable, so the whole decrease must have reached owner / creator
            assert(owner.balance + creator.balance - before == held - after_);
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
        (bool ok1,) = address(m).call(abi.encodeCall(M.setTreasury, (caller)));
        (bool ok2,) = address(m).call(abi.encodeCall(M.setGuardian, (caller)));
        (bool ok3,) = address(m).call(abi.encodeCall(M.registerRoyalty, (address(a), caller, 1000)));
        (bool ok4,) = address(m).call(abi.encodeCall(M.setFee, (500)));
        (bool ok5,) = address(m).call(abi.encodeCall(M.pause, ()));
        (bool ok6,) = address(m).call(abi.encodeCall(M.refundOffers, (_one(1))));
        (bool ok7,) = address(m).call(abi.encodeCall(M.setCollectionAllowed, (address(a), false)));
        (bool ok8,) = address(m).call(abi.encodeCall(M.setTipJar, (caller)));
        vm.stopPrank();
        assert(!ok1 && !ok2 && !ok3 && !ok4 && !ok5 && !ok6 && !ok7 && !ok8);
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
        m = new M(owner, makeAddr("treasury"), 250, 250);
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
