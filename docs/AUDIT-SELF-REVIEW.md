# MarketplaceV3: self-run automated security review

**This is a stopgap, not an audit.** It records what free tools, fuzzing, and symbolic checks found in `src/MarketplaceV3.sol`, and what they cannot see. A professional audit is still needed before third-party collections go live (see "Premise check" below: the launch list already includes them).

- **Version reviewed:** `src/MarketplaceV3.sol` at commit `9ac7a41` (sha256 `32fd56b395c19d103f6cf9b37548f43b6d86c53dcc7f8e3bbaaf7baf9ce68608`).
  - In this version the buyer fee goes to the collection's floor fund, there is no treasury, and `renounceOwnership` is disabled. HEAD `3ddb177` only adds docs.
  - The contract changed five times during the review: `29968c5` plus uncommitted self-serve royalties, then `b7a1443` (R1–R4), then `1049d1f` (floor fund held in the contract), then `cf247b3` (private listings, tips), then `9ac7a41`.
  - **On `9ac7a41`** the Foundry invariant and fuzz suite, Medusa, Echidna and the fast Halmos checks were re-run, at a 10-minute budget each.
  - **On `cf247b3`**, the version before, the static tools, the mutation test, the mainnet-fork check and the long (1M-call / 30-minute) campaigns were run. The change since then is small (the fee's destination and the treasury's removal), but those results are one version old.
- **Date:** 2026-11-01 to 2026-11-02.
- **New test file:** `test/MarketplaceV3.invariant.t.sol`. It contains the handler, the invariants, the fuzz tests, the Medusa/Echidna harness, the Halmos checks, the finding tests (`test_F*`), and the mainnet-fork check of the launch collections.

## Bottom line

- **No code bug was found.** No tool, invariant, symbolic check, or manual pass found a way to take anyone's NFT or money, to break escrow accounting, or to exceed the caps.
- **The harness is shown to work.** 31 hand-made bugs were planted in copies of the contract (mutation testing); see the results below.
- **The findings are design and operational points.**
  - Two of them (F-6, F-8) matter much more now that the launch list contains third-party collections.
  - One (F-12) is a hard requirement on the rebate service, which is not built yet.
  - **New with `9ac7a41`, F-14:** a registered creator can wash-trade their own collection for free, because the fee now lands in a fund they can withdraw. With the rebate as designed, that is a money pump. It needs a decision before the rebate ships.

## Premise check: the launch list is not "our own NFTs only"

`docs/DEPLOY-V3.md` says "only our own NFTs are allowed" and "a professional audit comes before third-party collections are allowed". `docs/LAUNCH-COLLECTIONS-ETH.md` (6c34b7c) allows 31 collections: BAYC, MAYC, Azuki, Pudgy Penguins, Doodles, and others. One of them (BCSH ETH) is ours.

For 24 of the 31, `owner()` is a third-party wallet. Under the current contract, that wallet can:
- register the collection's royalty, at up to 10%, to any receiver (self-serve);
- after registering, withdraw the collection's entire floor fund to itself (F-8);
- raise the royalty just before a seller's `list()` lands (F-6).

The "risk is low because they are our NFTs" argument therefore does not hold for this launch list. nftprof needs to choose one of:
- (a) launch with `setSelfServeBlocked(c, true)` for every collection we don't control;
- (b) launch with our own collections only, as DEPLOY-V3.md says;
- (c) accept F-6 and F-8 knowingly.

## Findings

Severity is for the launch as currently configured (31 collections).

| ID | Severity | Finding | Classification | Test |
|---|---|---|---|---|
| F-14 | **High for the rebate; Medium otherwise** (new in `9ac7a41`) | Since `9ac7a41` the buyer fee goes to `floorFundOf[collection]`, and a **registered creator** (self-serve, not blocked) can withdraw that whole fund to themselves. A creator self-dealing in their own collection, with two fresh wallets and the royalty paid to a third, gets the royalty back as receiver and the fee back from the floor fund: **the round trip costs 0 ETH**. Yet `Sale.fee` shows a full 2.5%, so the rebate as now designed (80% of `Sale.fee`, REBATE-DESIGN.md) pays them 2% of the price in PC for free, repeatable at any size. The REBATE-DESIGN mitigation "no rebate when the royalty receiver is the buyer or the seller" does not catch it, because wallets are free. Even without wash trading, every buyer's fee in a registered collection becomes creator revenue (up to 5% fee + 10% royalty), and the floor fund stops being a floor-buy fund. | Real (economic / design). Options: (a) pay no rebate on sales in collections whose floor fund the creator can withdraw (registered and not blocked), or pay it only on fees that stay in a fund only we can withdraw; (b) keep fees in a separate balance creators can't withdraw (e.g. `feeFundOf`), so creators withdraw only royalties; (c) block self-serve. | `test_F14_registeredCreatorWashTradesForFree` |
| F-12 | **Medium for the rebate**, addressed in REBATE-DESIGN (`76c495c`); see F-14 | Private sales (`listPrivate`) charge no fee and no royalty, and emit `Sale(price, fee 0, royalty 0)`. Two colluding wallets can trade any NFT back and forth at zero cost. REBATE-DESIGN.md defines the rebate as "2% of the price"; the contract header calls it "a share of the fee". If the rebate service pays 2% of `Sale.price`, private wash trades become a free money pump. Separately, any pre-arranged sale can go private and skip the creator royalty and the floor fund. | Contract behaves as designed. **The rebate must be computed from `Sale.fee` (or skip `fee == 0` sales)**; settle the "share of price" vs "share of fee" wording before the rebate is built. | `test_F12_privateSaleIsFreeSoRebateMustUseFeePaid` |
| F-8 | **Medium** (Low if self-serve is blocked) | A collection's `owner()` can self-register a royalty (even 0%), then `withdrawFloorFund` the **whole** floor fund to itself, including everything accrued before it registered. Since `9ac7a41` that includes the 2.5% buyer fee on **every** sale of the collection, so there is much more at stake. The fund is only as safe as each collection's `owner()` key. | By design per the header ("once registered, its owner() may withdraw it too"), but the launch list makes it a live decision. Options: block self-serve at deploy, or only let a creator withdraw what accrued after registration. | `test_F8_collectionOwnerCanSelfRegisterAndTakeTheFloorFund` |
| F-6 | **Low → Medium** with third-party collections | A collection's `owner()` can raise its royalty to 10% just before a seller's `list()` lands. `list()` has no max-royalty argument, so the listing freezes the higher rate. R1's min(frozen, current) doesn't help, because the creator simply keeps 10%. The seller nets up to 10% less than the UI showed. Offers are not affected: the seller sees the frozen rate before accepting. | Real (design gap). Fix options: add a `maxRoyaltyBps` argument to `list()`, or block self-serve. | `test_F6_creatorCanFrontRunListingRoyalty` |
| F-1 | Low, mitigated (keeper also watches approvals, DEPLOY-V3 `76c495c`) | A listing that went stale because the seller **revoked approval** comes back to life at its old price when they approve again (for example, to list something else), unless `clearStale` or `incrementNonce` ran in between. The same happens if the NFT leaves and returns before the keeper clears it. DEPLOY-V3.md's keeper watches only `Transfer`, so revocations are never cleared. | Real (the header's "can never come back" guarantee depends on the keeper). Fix: have the keeper also watch `ApprovalForAll` / `Approval` revocations, and make the UI's "cancel" call `delist` / `incrementNonce`, never "revoke approval". | `test_F1_staleListingRevivesOnReapproval` |
| F-9 | Low (operational), fixed (removed from the launch list, `76c495c`) | **POW Bull Badge** (`0x2094e4…6f63`) rejects transfers to normal addresses ("Cannot transfer to the provided address"). Its listings report `isListingLive == true`, but every buy and every offer fill reverts. | Real (launch list). Remove it from `COLLECTIONS`. | `LaunchCollectionsForkTest` (mainnet fork) |
| F-5 | Low, **fixed** (`renounceOwnership` reverts `RenounceDisabled`) | `renounceOwnership()` used to be callable. Renouncing would have lost `unpause` and `refundOffers` for good, stranded floor funds, and let `withdrawFloorFund` accept `to == address(0)`. | Fixed. The handler now also checks that the owner's and strangers' attempts always revert. | `test_F5_renounceOwnershipDisabled` |
| F-3 | Info | `maxPrice` bounds the price but not the fee. If the owner raises the fee and the seller re-lists at the same price, a buyer who sent extra ETH pays the new fee, capped at 5%. | Design gap. Fix: have the UI send the exact value, or add a max-fee field. | `test_F3_feeNotCoveredByMaxPrice` |
| F-4 | Info | If the tip jar or a registered receiver is set to a contract that can't receive (including the marketplace itself), its payouts are parked in `pendingPayouts` forever. `royaltyFor()` returns `address(this)` for unregistered collections, so a script that copies that receiver into `registerRoyalty` would strand royalties. | Owner misconfiguration only. Fix: reject `address(this)` in `setTipJar` / `_registerRoyalty`. | `test_F4_tipJarThatCannotReceiveStrandsTips` |
| F-2 | Info | The royalty **receiver** is read at sale time. Re-registering a collection redirects the royalty of every open listing and offer to the new receiver. Since R1 the rate is min(frozen, current), so it can never go up. | By design (header, R1). | `test_F2_openOrdersPayTheCurrentReceiver` |
| F-7 | Info | The doc for `collectionOwner()` says it returns "0 if it has none", but it **reverts** for an address with no code (and for a malformed `owner()` return), because a failed ABI decode inside try/catch is not caught. The callers end up reverting either way. Only frontends calling it on an EOA notice. | Doc/behaviour mismatch. | `test_F7_collectionOwnerRevertsForNonContract` |
| F-13 | Info, done (the header lists the tip jar since `9ac7a41`) | `setTipJar` is an owner power that sends buyers' tips to any address. Tips are capped at 5% of price + fee and are voluntary. | By design. | `testFuzz_tipCappedAndPaidToTipJar` |
| F-10 | Info | A compromised guardian can re-pause as often as it likes (a denial of service on trading only; exits keep working). The owner must `setGuardian(0)` before unpausing. | By design (R4). | handler `guardianPause` |
| F-11 | Info | Fee and royalty round down, so prices under about 40 wei pay no 2.5% fee. A registered receiver (now settable by collection owners) can burn up to the 50k push gas on every sale; the payout is then deferred. Self-trade is blocked per address only; wash trading through two wallets is handled off-chain (REBATE-DESIGN.md). | By design / bounded. | — |

Each `test_F*` test **passes**: it pins the current behaviour (F-5 now pins the fix). No test was written to fail, because none of these is a code bug. They are design and economic points for nftprof to rule on. If a fix lands, the matching test should be flipped.

## Tools (researched 2026-11-01; versions from the official GitHub releases)

| Tool | Version | Ran? | Why (one line) |
|---|---|---|---|
| Foundry invariant + fuzz | forge 1.8.5 (Windows), 1.8.7 (WSL) | yes, the main effort | The only tool here that checks *our* rules (escrow, payouts, caps, who may do what) end to end. |
| Slither | 0.11.6 (2026-07) | yes | The standard Solidity static analyser, about 100 detectors, seconds to run. |
| Aderyn (Cyfrin) | 0.6.8 (2026-01) | yes | An independent Rust/AST detector set that catches some patterns Slither misses. |
| Semgrep + Decurity smart-contract rules | semgrep 1.183.0, rules v1.2.1 (2025-06, last update) | yes | Cheap pattern rules taken from real DeFi exploits. Solidity support is "experimental" and the rules are a year old. |
| Wake (Ackee) | 4.22.2 | yes | A third, IR-based detector set (reentrancy, unsafe calls). |
| Solhint | 6.2.5 (2026-10) | yes | A linter: style and gas, with little security value. Run for completeness. |
| Halmos (a16z) | 0.3.3 | yes | Symbolic proofs of Foundry-style properties for **all** inputs, within bounds. |
| Medusa (Trail of Bits) | 1.5.1 (2026-03) | yes | A parallel, coverage-guided stateful fuzzer that reuses the same handler. |
| Echidna (Trail of Bits) | 2.3.3 (2026-07) | yes | A property fuzzer with a different input strategy from Medusa and Foundry. |
| Mythril (Consensys) | 0.24.8 (last release 2024-03) | yes, bytecode only | Effectively unmaintained: it needs `setuptools` on Python 3.12, and could not fetch solc from WSL. Run on runtime bytecode for completeness; low value. |
| AI-assisted auditors | — | **no** | Every hosted "AI auditor" means uploading the source to a third party; that is nftprof's call. This review's manual pass was itself AI-assisted (Claude). |

Installs: Python tools in venvs under `~/audit` in WSL Ubuntu-24.04 (pip); Aderyn, Medusa and Echidna from their GitHub release tarballs; Foundry in WSL via the official `foundryup`; Solhint via npm into a scratch folder. Nothing was installed into the repo.

## Tool findings, triaged

All static tools were run on `cf247b3`. They were not re-run on `9ac7a41`, which only removes the treasury, sends the fee to `floorFundOf`, and disables `renounceOwnership`.

| Tool | Raw | Triage |
|---|---|---|
| Slither | 27 results / 13 detectors | **0 real.** `arbitrary-send-erc20` (buy's `transferFrom(l.seller, …)`): **false positive**. `from` is the seller who listed and approved, the collection checks ownership, and the invariants plus the fork check confirm it. `msg-value-loop`: **by design**; `spent` (plus the tip) is accumulated and checked against `msg.value`, the buyer pays exactly the sum and the rest is refunded (fuzzed). `reentrancy-no-eth` ×2 (buy, acceptOffer): **false positive**; both are `nonReentrant`, and re-entry through payout receivers is fuzzed (TrickyWallet mode 3). `missing-zero-check` (constructor `tipJar = treasury_`; `setGuardian`): FP, since `_setTreasury` rejects 0 one line earlier, and by design, since 0 = no guardian. `uninitialized-local` (`spent`): FP. `calls-loop` / `costly-loop`: by design (an atomic batch). `timestamp`: by design (expiries). `cyclomatic-complexity` (buy, 14), `low-level-calls`, `assembly` (the gas-limited `_pay`), `unindexed-event-address`: informational. |
| Aderyn | 4 High, 11 Low (52 instances) | **0 real.** H-1 "ETH transferred without address checks" (withdraw / withdrawFor): FP, it pays the payee its own pending balance. H-2 msg.value in a loop: as Slither. H-3 "state change after external call": FP; the calls in `_list` are view calls (STATICCALL) and `buy` is `nonReentrant`. H-4 unsafe integer casts (`uint96(price)`, `uint40(expiry)`, `uint16(quantity)`, `uint16(tokenIds.length)`): FP, each is bounds-checked first. L-1 centralization: by design (the header lists the owner powers). L-2…L-11 are gas/style: costly loop, literals, struct field `feeBps` shadowing, `nonReentrant` not the first modifier (harmless here), PUSH0 (fine on mainnet), require in a loop, address set without a check, uninitialized local, and floating pragma (the build pins 0.8.24; consider `pragma solidity 0.8.24` for Etherscan verification). |
| Semgrep (Decurity, 57 rules) | 30 | **0 real.** `basic-arithmetic-underflow` ×3 (`msg.value - spent`, `o.remaining -=`, `floorFundOf -=`): FP, each is guarded right before. The other 27 are gas hints (state var read in a loop, unchecked `++i`, nested ifs, non-payable constructor). |
| Wake | 6 | **0 real.** `unsafe-erc20-call` ×2: FP, these are ERC-721 `transferFrom` calls, and the fork check shows all tradeable launch collections revert on bad transfers. Reentrancy in buy / acceptOffer (high impact, low confidence): FP (`nonReentrant`). `withdrawFloorFund` / `_withdraw` warnings: CEI + `nonReentrant`; FP. |
| Solhint (recommended) | 189 warnings | **0 security.** 161 natspec, 14 indexed events, 5 import paths, 4 `l`/`O` identifiers, 3 strict inequalities, 1 inline assembly, 1 constructor visibility. |
| Mythril (runtime bytecode) | 34 | **0 real.** 30 "integer arithmetic" (High), mostly on getters such as `feeBps()` and `paused()`: FP, from 0.8 checked math and ABI decoding misread by a pre-Cancun tool. 3 "state access after external call" plus 1 "external call to user-supplied address" in `buy` (selector 0x1d4b73cd): FP (`nonReentrant`, allowlisted collection). |

## Invariant and fuzz results

The handler drives 5 actors (3 EOAs and 2 smart wallets that can reject payments, run out of gas under the 50k push limit, or try to re-enter), 3 collections × 6 tokens, and every external function, including private listings, tips, and all owner, guardian, self-serve, tip-jar and floor-fund powers.

It also simulates the environment: NFT transfers outside the marketplace, approval changes, wallet behaviour changes, a change of the collection's `owner()`, and time warps.

After **every** marketplace call it checks the following against an independent model:
- every tracked address's `balance + pendingPayouts` moved by exactly the amount the rules say, and nobody else gained (the owner included);
- every NFT that moved was part of an expected sale: from the seller, to the buyer or bidder, in the listing's or offer's own collection;
- `floorFundOf` changed by exactly what was expected (fee + unregistered royalty on each sale), and only `withdrawFloorFund` can lower it;
- the call was allowed: not paused, a live order, an allowed collection, not a self-trade, a token in the Merkle set, the right caller.

The invariants:

| Invariant (as asked) | Where |
|---|---|
| `balance == Σ live offers (price + frozen fee) × remaining + Σ pendingPayouts + Σ floorFundOf` | `invariant_balanceEqualsEscrowPlusPending` (exact equality, plus on-chain escrow == model) |
| No NFT leaves a wallet except through a sale where that wallet was the seller and received price − royalty (or pending) | handler `_end` (NFT moves) + per-address value deltas |
| Fee and royalty never exceed the caps; the buyer never pays more than maxPrice + frozen fee | `invariant_capsHold`, handler `buy` (paid ≤ Σ maxPrice + frozen fee), `testFuzz_buySplitIsExact` |
| The seller never pays more royalty than the rate frozen into their order | handler `_checkSellerFloors`: the seller nets ≥ price − price × frozenBps on every sale, independent of the exact model |
| An offer is filled only with its own collection's tokens; self-trade is impossible | handler `acceptOffer` (cross-collection and self-trade attempts must revert, and any NFT move outside the offer's collection is flagged), `buy` self-trade attempts |
| The owner can never send funds anywhere except the tip jar, the floor fund (to itself or the collection owner), sellers, royalty receivers, or back to bidders | per-call deltas over all tracked addresses (the owner included); `ownerRefundOffers` pays only bidders; `testFuzz_ownerCannotMoveEscrow`; Halmos `check_anySingleCallCannotTakeBidderOrSellerAssets` (inconclusive, see Runs) |
| Only `privateBuyer` can buy a private listing | handler `buy` (others must be refused; a success by anyone else is flagged), `testFuzz_privateListingOnlyItsBuyer`, Halmos `check_privateListingOnlyItsBuyer` |
| A private sale pays the seller the full price, with no fee and no royalty | handler `buy` (exact deltas: seller +price, floor fund and royalty receiver +0; frozen bps must be 0), `testFuzz_privateListingOnlyItsBuyer`, `test_F12_…` |
| A tip never exceeds 5% of the items' cost and only ever goes to `tipJar` | handler `buy` (random tips, including over-cap ones that must revert; exact delta for `tipJar` and nobody else), `testFuzz_tipCappedAndPaidToTipJar`; `privateBuyer` and `tipJar` are also compared with the model after every call |
| `withdrawFor` never pays anyone but the payee | handler `withdrawFor`: the payee is paid exactly its pending and every other tracked address is unchanged |
| Floor funds leave only via `withdrawFloorFund`, to an allowed recipient; a stranger can never withdraw | handler `_end` + `withdrawFloorFund` (random callers and recipients) + `strangerAdmin`; `testFuzz_floorFundOnlyToAllowed`; Halmos `check_floorFundOnlyLeavesToAllowed` |
| Storage matches the model (frozen rates, prices, expiries, nonces, private buyers, remaining, roots, tip jar, guardian, royalty registry, floor funds) | `invariant_storageMatchesModel` |
| No receive() hook ever re-entered a guarded function | `invariant_noReentry` |

### Runs on `9ac7a41` (current; 10-minute budget)

| Campaign | Size | Result |
|---|---|---|
| Foundry invariant | 2,000 runs × depth 200 = **400,000 calls**, 11 min. Successful: 14,507 list, 8,426 listPrivate, 5,686 buy, 9,193 acceptOffer, 963 withdrawFloorFund, 217 withdrawFor; 0 renounce or stranger-admin calls got through | **5/5 invariants pass, 0 violations** |
| Foundry stateless fuzz | 6 tests × 20,000 runs (plus 10 fixed finding tests) | pass |
| Medusa | 10 min, 12 workers, **2.56 M calls**, 4,212 branches | 3/3 properties pass |
| Echidna | 10 min, 8 workers, **385 k calls** | 3/3 properties pass |
| Halmos (fast checks) | 4 checks | **4/4 proved**: `nonOwnerCannotUseOwnerPowers` (now including `renounceOwnership`), `privateListingOnlyItsBuyer`, `offerOnlyTakesItsOwnCollection`, `offerFillAndCancelLeavesNothing`. The split check (now seller + royalty receiver + floor fund) is updated but was not re-run, because it timed out before. |

### Runs on `cf247b3` (the version before; long budget)

| Campaign | Size | Result |
|---|---|---|
| Foundry invariant | **5,000 runs × depth 200 = 1,000,000 calls**, 24 min | **5/5 invariants pass, 0 violations** |
| Foundry stateless fuzz | 6 tests × **20,000 runs** (plus 9 fixed finding tests) | pass |
| Medusa | 30 min, 12 workers, **10.5 M calls**, 4,334 branches | 3/3 properties pass |
| Echidna | 30 min, 8 workers, **1.41 M calls**, seqLen 200 | 3/3 properties pass |
| Halmos (yices, loop 3, 300 s per query) | 7 checks | **Proved for all inputs on `cf247b3`:**<br>• `check_nonOwnerCannotUseOwnerPowers` (any caller ≠ owner; 8 owner powers)<br>• `check_privateListingOnlyItsBuyer` (any caller)<br>• `check_offerOnlyTakesItsOwnCollection` (any token id)<br>• `check_offerFillAndCancelLeavesNothing` (any price, qty 2)<br>**Proved on `1049d1f`, did not finish on `cf247b3`:** `check_floorFundOnlyLeavesToAllowed` (any sender, any calldata, any value; 475 paths in 10 s on 1049d1f; with `listPrivate` and the tip argument added it ran > 3 h and was stopped).<br>**Inconclusive (solver TIMEOUT):** `check_buySplitConservesAndRespectsCaps` (symbolic price × bps division) and `check_anySingleCallCannotTakeBidderOrSellerAssets` (never finished on either version). These properties are covered by the fuzzers instead (`testFuzz_buySplitIsExact` 20 k runs, the handler's exact per-call deltas), **not proved**. |
| Mutation test (harness self-check) | 31 planted bugs, each in its own copy, 64 runs × depth 200 + all fuzz tests | **30/31 caught on the first pass.** M23 (a creator can withdraw while self-serve is blocked) survived: random fuzzing rarely reached "registered + blocked + creator calls". `testFuzz_floorFundOnlyToAllowed` now always tries owner / creator / stranger as caller and recipient; re-run on M23, it is caught by that test **and** by the invariant. **31/31.** |
| Mainnet fork, 31 launch collections (block 26 325 860) | real `transferFrom` semantics, then list → buy and offer → accept through the marketplace | 29 OK; **1 untradeable (F-9)**; 1 not exercised (BCSH ETH: no EOA-held token among the ids tried) |

Successful marketplace calls in the 1M-call Foundry campaign (calls − rejected):

| Action | OK | Action | OK |
|---|---|---|---|
| list | 36,845 | listPrivate | 20,888 |
| buy (incl. private, with tips) | 14,306 | acceptOffer | 22,888 |
| placeOffer | 19,173 | cancelOffer | 21,692 |
| ownerRefundOffers | 11,406 | withdraw | 1,153 |
| withdrawFor | 576 | withdrawFloorFund | 1,606 |
| creatorRegisterRoyalty | 10,026 | guardianPause | 2,447 |
| strangerAdmin | 0 (all 24,023 rejected, as they must be) | | |

Planted bugs (each caught by at least one invariant or test):

- **Pricing:** refund at the current fee; buy at the current fee; royalty ignoring min(); royalty at max(); seller paid the full price.
- **Who may act:** no self-trade check; Merkle check skipped; allowlist ignored on fill; self-serve without the owner() check; anyone can pause; guardian can unpause; refundOffers while live.
- **Where money goes:** royalty to the treasury; refund to the owner; deferred payout not recorded; withdrawFor pays the caller.
- **Listing state:** nonce ignored; offer not deleted; clearStale removes live listings; `_isLive` ignores the allowlist.
- **Floor fund:** paid to any recipient; creator withdraws while unregistered; creator withdraws while blocked; not debited; unregistered royalty pushed to the treasury.
- **Private listings and tips:** anyone can buy a private listing; a private listing charges the fee; a public relist keeps the private buyer; removal keeps the private buyer; tip not capped; tip paid to the treasury instead of the tip jar.

## Limits: what this does NOT cover

- **Tools check the code against the rules we wrote down.** If a rule itself is wrong (as with F-6 and F-8, which are behaving as designed), only a human reading the design catches it.
- **Mock collections.** The invariant harness uses OpenZeppelin ERC-721. Real collections can differ. The fork check covers the 31 launch collections' basic semantics at one block; upgradeable collections can change later, and a new collection needs re-checking before `setCollectionAllowed`.
- **Bounded state.** The model has 3 collections × 6 tokens, 5 actors, prices ≤ 50 ETH, ≤ 3 items per buy, ≤ 2 per fill, and Merkle sets of ≤ 2 leaves. It does not cover gas limits of large batches, ETH force-sent by selfdestruct (the balance invariant would become ≥), ERC-1155, or exotic tokens.
- **Halmos is bounded, and partly inconclusive:** loops are unrolled 3×, symbolic arrays have length ≤ 2, and the "any call" proofs cover a **single** call from a fixed starting state.
  - The payment-split proof and the "any call can't take bidder / seller assets" proof timed out in the solver.
  - The "any call" floor-fund proof passed on `1049d1f` but did not finish on `cf247b3`.
  - Treat those three as fuzzed, not proved.
- **Not in scope:** the frontend, the keeper, the off-chain rebate (beyond F-12 / F-14), the deploy script and ownership handover, MEV beyond F-3 and F-6, and Etherscan verification.
- **The fork check covers the 6c34b7c launch list.** LAUNCH-COLLECTIONS-ETH.md now says the final allowlist comes from a rights register plus nft-data `supported`. Any collection on that list that was not fork-checked here needs the same check before `setCollectionAllowed`.
- **Mutation testing ran on `cf247b3`.** Mutants M4, M13, M25 and M28 used the treasury, which no longer exists. The fee's new path (`floorFundOf += fee`) is covered by the exact per-call floor-fund checks, but it was not mutation-tested.
- **The target moved during the review.** A new contract change invalidates these results until the commands below are re-run.

## Reproduce

```bash
# Foundry (repo root). Default settings run in ~3–4 min; the numbers above used:
FOUNDRY_INVARIANT_RUNS=5000 FOUNDRY_INVARIANT_DEPTH=200 FOUNDRY_FUZZ_RUNS=20000 \
  forge test --match-path test/MarketplaceV3.invariant.t.sol
# Mainnet-fork check of the launch collections (skipped without ETH_RPC)
ETH_RPC=<mainnet rpc> forge test --match-contract LaunchCollectionsForkTest -vv

# Static (WSL, in a copy of the repo)
slither . --filter-paths "lib/|test/" --exclude-dependencies
aderyn . --src src --path-includes src/MarketplaceV3.sol
semgrep --metrics=off --config <Decurity/semgrep-smart-contracts@v1.2.1>/solidity src/MarketplaceV3.sol
wake detect all --paths src/MarketplaceV3.sol     # after `wake up config`
solhint -c '{"extends":"solhint:recommended"}' src/MarketplaceV3.sol
myth analyze --bin-runtime -f runtime.hex --execution-timeout 2400 -t 2   # runtime from `forge inspect … deployedBytecode`

# Symbolic / other fuzzers. Medusa, Echidna and Halmos need FOUNDRY_DYNAMIC_TEST_LINKING=false
# (forge 1.8 links tests dynamically via deployCode, which they don't support).
halmos --contract MarketplaceV3SymbolicTest --function <check_name> --solver-timeout-assertion 300000 --loop 3
medusa fuzz --config medusa.json      # targetContracts [MarketplaceV3PropertyHarness], prefix property_,
                                      # codeSizeCheckDisabled, platformConfig.args [--foundry-compile-all]
echidna . --contract MarketplaceV3PropertyHarness --config echidna.yaml
                                      # testMode property, prefix echidna_, seqLen 200, codeSize 0xffffffff,
                                      # cryticArgs [--foundry-compile-all]
```
