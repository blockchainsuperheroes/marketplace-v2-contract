# MarketplaceV3: self-run automated security review

**This is a stopgap, not an audit.** It records what free tools, fuzzing, and symbolic checks found in `src/MarketplaceV3.sol`, and what they cannot see. A professional audit is still needed before third-party collections go live (see "Premise check" below: the launch list already includes them).

- **Version reviewed:** `src/MarketplaceV3.sol` at commit `66ef13d` (sha256 `f09c5b9c751b8f17f2cfc09f658548664ebbfafc2dd11a06f3112ded111243e9`). It adds the F-15 fix on top of `52655e7`: a creator allowance stays with the `owner()` wallet it was granted to.
  - Each collection's money is now split in two:
    - `floorFundOf` holds only the fees; our owner withdraws it, to any wallet.
    - `royaltyFundOf` holds unregistered royalties; our owner, or the collection's `owner()` up to `creatorAllowance`, withdraws it.
  - There is no treasury, and `renounceOwnership` is disabled.
  - The contract changed seven times during the review: `29968c5` plus uncommitted self-serve royalties, then `b7a1443` (R1–R4), then `1049d1f` (floor fund in the contract), then `cf247b3` (private listings, tips), then `9ac7a41` (fee to the floor fund, no treasury), then `52655e7` (fee / royalty funds, creator allowance), then `66ef13d` (F-15 fix).
  - **Re-run on `66ef13d` at full size:** the 1M-call Foundry invariant, 20k-run fuzz, Medusa and Echidna at 30 min each, the mutation test, and the quick static tools (Slither, Aderyn, Semgrep, Wake, Solhint).
  - **Last run on `52655e7`**, the version before: Halmos, Mythril and the mainnet-fork check. `66ef13d` only touches `setCreatorAllowance` / `withdrawRoyaltyFund`.
- **Date:** 2026-11-01 to 2026-11-02.
- **New test file:** `test/MarketplaceV3.invariant.t.sol`. It contains the handler, the invariants, the fuzz tests, the Medusa/Echidna harness, the Halmos checks, the finding tests (`test_F*`), and the mainnet-fork check of the launch collections.

## Bottom line

- **No code bug was found.** No tool, invariant, symbolic check, or manual pass found a way to take anyone's NFT or money, to break escrow accounting, or to exceed the caps.
- **The harness is shown to work.** 37 hand-made bugs were planted in copies of the contract (mutation testing), including the fee's new path and the new allowance rules; see the results below.
- **F-14 and F-8 are fixed in `52655e7`.**
  - Fees sit in a fund only our owner can withdraw, so a creator wash-trading their own collection pays the full 2.5% fee. The rebate is 80% of that fee, so the trade costs them 0.5% net. That is the trade-off REBATE-DESIGN.md already accepts (PC at a discount), not a free pump.
  - Creators can take royalties only up to an allowance our owner sets.
- **The remaining findings are design and operational points.**
  - F-6 matters more now that the launch list contains third-party collections.
  - F-12 is a hard requirement on the rebate service, which is not built yet; REBATE-DESIGN.md now follows it.
  - F-15 (the allowance followed the collection's `owner()`) was found on `52655e7` and is fixed in `66ef13d`.

## Premise check: the launch list is not "our own NFTs only"

`docs/DEPLOY-V3.md` says "only our own NFTs are allowed" and "a professional audit comes before third-party collections are allowed". `docs/LAUNCH-COLLECTIONS-ETH.md` (6c34b7c) allows 31 collections: BAYC, MAYC, Azuki, Pudgy Penguins, Doodles, and others. One of them (BCSH ETH) is ours.

For 24 of the 31, `owner()` is a third-party wallet. Under the current contract, that wallet can:
- register the collection's royalty, at up to 10%, to any receiver (self-serve);
- raise the royalty just before a seller's `list()` lands (F-6).

Since `52655e7` it can **no longer** take the fee fund. It can take the royalty fund only up to an allowance our owner grants (F-8 fixed; see F-15).

The "risk is low because they are our NFTs" argument still does not hold for this launch list. nftprof needs to choose one of:
- (a) launch with `setSelfServeBlocked(c, true)` for every collection we don't control;
- (b) launch with our own collections only, as DEPLOY-V3.md says;
- (c) accept F-6 knowingly.

Since then, LAUNCH-COLLECTIONS-ETH.md says the final allowlist comes from a rights register plus nft-data `supported`.

## Findings

Severity is for the launch as currently configured (31 collections).

| ID | Severity | Finding | Classification | Test |
|---|---|---|---|---|
| F-14 | **Fixed in `52655e7`** (was High for the rebate) | In `9ac7a41` the fee went to a floor fund a registered creator could withdraw, so a creator's self-dealt sale cost 0 ETH yet earned the full fee-based rebate. Now `floorFundOf` holds only fees, and only our owner can withdraw it (`onlyOwner`). The round trip costs the creator exactly the 2.5% fee, against a rebate of 80% of it (2%). What remains is the trade-off REBATE-DESIGN.md already records: a creator can buy PC at about a 75% discount by wash trading. | Fixed. The handler checks that only our owner ever lowers `floorFundOf`, and mutants M33/M34 prove that check bites. | `test_F14_fixed_creatorWashTradeStillPaysTheFee`, `testFuzz_floorFundOnlyOwner` |
| F-12 | **Medium for the rebate**, addressed in REBATE-DESIGN (`76c495c`) | Private sales (`listPrivate`) charge no fee and no royalty, and emit `Sale(price, fee 0, royalty 0)`. Two colluding wallets can trade any NFT back and forth at zero cost. REBATE-DESIGN.md defines the rebate as "2% of the price"; the contract header calls it "a share of the fee". If the rebate service pays 2% of `Sale.price`, private wash trades become a free money pump. Separately, any pre-arranged sale can go private and skip the creator royalty and the floor fund. | Contract behaves as designed. **The rebate must be computed from `Sale.fee` (or skip `fee == 0` sales)**; settle the "share of price" vs "share of fee" wording before the rebate is built. | `test_F12_privateSaleIsFreeSoRebateMustUseFeePaid` |
| F-8 | **Fixed in `52655e7`** (was Medium) | A collection's `owner()` could self-register and withdraw the whole floor fund (fees and royalties). Now the fees are owner-only. The royalty fund can be taken by the collection's `owner()` only up to `creatorAllowance` (set by our owner, reduced by each withdrawal, `type(uint256).max` = open), only while self-serve isn't blocked, and only to our owner or itself. | Fixed. Invariant `invariant_creatorAllowanceNeverExceeded`; handler `withdrawRoyaltyFund` with random callers and recipients; mutants M35–M38. See F-15. | `test_F8_fixed_creatorCannotTakeTheFunds`, `testFuzz_royaltyFundRules` |
| F-15 | **Fixed in `66ef13d`** (was Low) | `creatorAllowance` used to be keyed by collection only, so when the collection contract's `owner()` changed, the new `owner()` inherited what was left, an open allowance included. Now `setCreatorAllowance` records `creatorAllowanceHolder = owner()` at grant time, and reverts `NotCollectionOwner` for a non-zero grant to a collection with no `owner()`. Only that holder, while it is still `owner()`, can spend it. | Fixed. The handler grants allowances, changes `owner()` at random (so stale holders try to spend), and flags any spend by someone other than the holder-while-`owner()`. Mutants M42–M45 cover the holder check. | `test_F15_fixed_allowanceStaysWithTheWalletItWasGranted`, `testFuzz_allowanceOnlyForItsHolder` |
| F-16 | Info (new in `52655e7`, by design) | `withdrawFloorFund` sends the fees to **any** non-zero wallet our owner names (nftprof: to buy floor NFTs on other marketplaces). The fees are therefore trusted to the owner key, like revenue. The header's "the owner can never move anyone's money elsewhere" holds for users' escrow and payouts, not for these fees. | By design. Keep the owner a multisig, and publish floor-fund withdrawals. | `testFuzz_floorFundOnlyOwner` |
| F-6 | **Low → Medium** with third-party collections | A collection's `owner()` can raise its royalty to 10% just before a seller's `list()` lands. `list()` has no max-royalty argument, so the listing freezes the higher rate. R1's min(frozen, current) doesn't help, because the creator simply keeps 10%. The seller nets up to 10% less than the UI showed. Offers are not affected: the seller sees the frozen rate before accepting. | Real (design gap). Fix options: add a `maxRoyaltyBps` argument to `list()`, or block self-serve. | `test_F6_creatorCanFrontRunListingRoyalty` |
| F-1 | Low, mitigated (keeper also watches approvals, DEPLOY-V3 `76c495c`) | A listing that went stale because the seller **revoked approval** comes back to life at its old price when they approve again (for example, to list something else), unless `clearStale` or `incrementNonce` ran in between. The same happens if the NFT leaves and returns before the keeper clears it. DEPLOY-V3.md's keeper watches only `Transfer`, so revocations are never cleared. | Real (the header's "can never come back" guarantee depends on the keeper). Fix: have the keeper also watch `ApprovalForAll` / `Approval` revocations, and make the UI's "cancel" call `delist` / `incrementNonce`, never "revoke approval". | `test_F1_staleListingRevivesOnReapproval` |
| F-9 | Low (operational), fixed (removed from the launch list, `76c495c`) | **POW Bull Badge** (`0x2094e4…6f63`) rejects transfers to normal addresses ("Cannot transfer to the provided address"). Its listings report `isListingLive == true`, but every buy and every offer fill reverts. | Real (launch list). Remove it from `COLLECTIONS`. | `LaunchCollectionsForkTest` (mainnet fork) |
| F-5 | Low, **fixed** (`renounceOwnership` reverts `RenounceDisabled`) | `renounceOwnership()` used to be callable. Renouncing would have lost `unpause` and `refundOffers` for good and stranded the floor and royalty funds. | Fixed. The handler now also checks that the owner's and strangers' attempts always revert. | `test_F5_renounceOwnershipDisabled` |
| F-3 | Info | `maxPrice` bounds the price but not the fee. If the owner raises the fee and the seller re-lists at the same price, a buyer who sent extra ETH pays the new fee, capped at 5%. | Design gap. Fix: have the UI send the exact value, or add a max-fee field. | `test_F3_feeNotCoveredByMaxPrice` |
| F-4 | Info | If the tip jar or a registered receiver is set to a contract that can't receive (including the marketplace itself), its payouts are parked in `pendingPayouts` forever. `royaltyFor()` returns `address(this)` for unregistered collections, so a script that copies that receiver into `registerRoyalty` would strand royalties. | Owner misconfiguration only. Fix: reject `address(this)` in `setTipJar` / `_registerRoyalty`. | `test_F4_tipJarThatCannotReceiveStrandsTips` |
| F-2 | Info | The royalty **receiver** is read at sale time. Re-registering a collection redirects the royalty of every open listing and offer to the new receiver. Since R1 the rate is min(frozen, current), so it can never go up. | By design (header, R1). | `test_F2_openOrdersPayTheCurrentReceiver` |
| F-7 | Info | The doc for `collectionOwner()` says it returns "0 if it has none", but it **reverts** for an address with no code (and for a malformed `owner()` return), because a failed ABI decode inside try/catch is not caught. The callers end up reverting either way. Only frontends calling it on an EOA notice. | Doc/behaviour mismatch. | `test_F7_collectionOwnerRevertsForNonContract` |
| F-13 | Info, done (the header lists the tip jar since `9ac7a41`) | `setTipJar` is an owner power that sends buyers' tips to any address. Tips are capped at 5% of price + fee and are voluntary. | By design. | `testFuzz_tipCappedAndPaidToTipJar` |
| F-10 | Info | A compromised guardian can re-pause as often as it likes (a denial of service on trading only; exits keep working). The owner must `setGuardian(0)` before unpausing. | By design (R4). | handler `guardianPause` |
| F-11 | Info | Fee and royalty round down, so prices under about 40 wei pay no 2.5% fee. A registered receiver (now settable by collection owners) can burn up to the 50k push gas on every sale; the payout is then deferred. Self-trade is blocked per address only; wash trading through two wallets is handled off-chain (REBATE-DESIGN.md). | By design / bounded. | — |

Each `test_F*` test **passes**: it pins the current behaviour (F-5, F-8 and F-14 now pin their fixes). No test was written to fail, because none of these is a code bug. They are design and economic points for nftprof to rule on. If a fix lands, the matching test should be flipped.

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

Slither, Aderyn, Semgrep, Wake and Solhint were re-run on `66ef13d`. Mythril was last run on `52655e7`.

| Tool | Raw | Triage |
|---|---|---|
| Slither | 26 results / 12 detectors | **0 real.** `arbitrary-send-erc20` (buy's `transferFrom(l.seller, …)`): **false positive**. `from` is the seller who listed and approved, the collection checks ownership, and the invariants plus the fork check confirm it. `msg-value-loop`: **by design**; `spent` (plus the tip) is accumulated and checked against `msg.value`, the buyer pays exactly the sum and the rest is refunded (fuzzed). `reentrancy-no-eth` ×2 (buy, acceptOffer): **false positive**; both are `nonReentrant`, and re-entry through payout receivers is fuzzed (TrickyWallet mode 3). `missing-zero-check` (`setGuardian`): by design, since 0 = no guardian. `uninitialized-local` (`spent`): FP. `calls-loop` / `costly-loop`: by design (an atomic batch). `timestamp`: by design (expiries). `cyclomatic-complexity` (buy, 14), `low-level-calls`, `assembly` (the gas-limited `_pay`), `unindexed-event-address`: informational. |
| Aderyn | 4 High, 11 Low (54 instances) | **0 real.** H-1 "ETH transferred without address checks" (withdraw / withdrawFor): FP, it pays the payee its own pending balance. H-2 msg.value in a loop: as Slither. H-3 "state change after external call": FP; the calls in `_list` are view calls (STATICCALL) and `buy` is `nonReentrant`. H-4 unsafe integer casts (`uint96(price)`, `uint40(expiry)`, `uint16(quantity)`, `uint16(tokenIds.length)`): FP, each is bounds-checked first. L-1 centralization: by design (the header lists the owner powers). L-2…L-11 are gas/style: costly loop, literals, struct field `feeBps` shadowing, `nonReentrant` not the first modifier (harmless here), PUSH0 (fine on mainnet), require in a loop, address set without a check, uninitialized local, and floating pragma (the build pins 0.8.24; consider `pragma solidity 0.8.24` for Etherscan verification). |
| Semgrep (Decurity, 57 rules) | 32 | **0 real.** `basic-arithmetic-underflow` ×5 (`msg.value - spent`, `o.remaining -=`, `floorFundOf -=`, `allowance - amount`, `royaltyFundOf -=`): FP, each is guarded right before. The other 27 are gas hints (state var read in a loop, unchecked `++i`, nested ifs, non-payable constructor). |
| Wake | 7 | **0 real.** `unsafe-erc20-call` ×2: FP, these are ERC-721 `transferFrom` calls, and the fork check shows all tradeable launch collections revert on bad transfers. Reentrancy in buy / acceptOffer (high impact, low confidence): FP (`nonReentrant`). `withdrawFloorFund` / `withdrawRoyaltyFund` / `_withdraw` warnings: CEI + `nonReentrant`; FP. |
| Solhint (recommended) | 200 warnings | **0 security.** Natspec, indexed events, import paths, `l`/`O` identifiers, strict inequalities, inline assembly, max-states-count, constructor visibility. |
| Mythril (runtime bytecode, `52655e7`) | 35 | **0 real.** 31 "integer arithmetic" (High), mostly on getters such as `feeBps()` and `paused()`: FP, from 0.8 checked math and ABI decoding misread by a pre-Cancun tool. 3 "state access after external call" plus 1 "external call to user-supplied address" in `buy` (selector 0x1d4b73cd): FP (`nonReentrant`, allowlisted collection). |

## Invariant and fuzz results

The handler drives 5 actors (3 EOAs and 2 smart wallets that can reject payments, run out of gas under the 50k push limit, or try to re-enter), 3 collections × 6 tokens, and every external function. That includes private listings, tips, and every owner, guardian, self-serve, tip-jar, floor-fund, royalty-fund and creator-allowance power, called by random callers to random recipients.

It also simulates the environment: NFT transfers outside the marketplace, approval changes, wallet behaviour changes, a change of the collection's `owner()`, and time warps.

After **every** marketplace call it checks the following against an independent model:
- every tracked address's `balance + pendingPayouts` moved by exactly the amount the rules say, and nobody else gained (the owner included);
- every NFT that moved was part of an expected sale: from the seller, to the buyer or bidder, in the listing's or offer's own collection;
- `floorFundOf` changed by exactly the fees of the call's sales, `royaltyFundOf` by exactly its unregistered royalties, and only `withdrawFloorFund` / `withdrawRoyaltyFund` respectively can lower them;
- the call was allowed: not paused, a live order, an allowed collection, not a self-trade, a token in the Merkle set, the right caller.

The invariants:

| Invariant (as asked) | Where |
|---|---|
| `balance == Σ live offers (price + frozen fee) × remaining + Σ pendingPayouts + Σ floorFundOf + Σ royaltyFundOf` | `invariant_balanceEqualsEscrowPlusPending` (exact equality; on-chain escrow and both funds == model) |
| No NFT leaves a wallet except through a sale where that wallet was the seller and received price − royalty (or pending) | handler `_end` (NFT moves) + per-address value deltas |
| Fee and royalty never exceed the caps; the buyer never pays more than maxPrice + frozen fee | `invariant_capsHold`, handler `buy` (paid ≤ Σ maxPrice + frozen fee), `testFuzz_buySplitIsExact` |
| The seller never pays more royalty than the rate frozen into their order | handler `_checkSellerFloors`: the seller nets ≥ price − price × frozenBps on every sale, independent of the exact model |
| An offer is filled only with its own collection's tokens; self-trade is impossible | handler `acceptOffer` (cross-collection and self-trade attempts must revert, and any NFT move outside the offer's collection is flagged), `buy` self-trade attempts |
| The owner can never send funds anywhere except the tip jar, the fee fund (any wallet, F-16), the royalty fund (to itself or the collection owner), sellers, royalty receivers, or back to bidders | per-call deltas over all tracked addresses (the owner included); `ownerRefundOffers` pays only bidders; `testFuzz_ownerCannotMoveEscrow`; Halmos `check_anySingleCallCannotTakeBidderOrSellerAssets` (see Runs) |
| **The floor fund (fees) is only ever lowered by our owner; a creator never reduces `floorFundOf`** | handler `withdrawFloorFund` (owner, collection owner and strangers try, to random recipients; any success by a non-owner is a violation) and `_end` (only that action may lower it); `strangerAdmin`; `testFuzz_floorFundOnlyOwner`; Halmos `check_floorFundOnlyLeavesToAllowed` |
| **The royalty fund leaves only via `withdrawRoyaltyFund`, to our owner or the collection's `owner()`; the creator only while unblocked and within its allowance** | handler `withdrawRoyaltyFund` (random callers, recipients and amounts, including over-allowance and over-balance ones); `testFuzz_royaltyFundRules`; Halmos `check_floorFundOnlyLeavesToAllowed` |
| **The creator allowance is never exceeded** (Σ creator withdrawals since the last `setCreatorAllowance` ≤ that value unless open, and the on-chain allowance is what is left) | `invariant_creatorAllowanceNeverExceeded`, Medusa / Echidna `*_creatorAllowanceNeverExceeded`; handler `ownerSetCreatorAllowance` (0 / finite / open) and stranger attempts |
| **Only the wallet the allowance was granted to, while it is still `owner()`, ever spends it** (F-15) | handler `withdrawRoyaltyFund` (callers include the stale holder after a random `owner()` change) counts any other spend in `badAllowanceSpends`; `invariant_creatorAllowanceNeverExceeded` asserts it is 0 and that `creatorAllowanceHolder` == model; Medusa / Echidna `*_creatorAllowanceNeverExceeded`; `testFuzz_allowanceOnlyForItsHolder` |
| Only `privateBuyer` can buy a private listing | handler `buy` (others must be refused; a success by anyone else is flagged), `testFuzz_privateListingOnlyItsBuyer`, Halmos `check_privateListingOnlyItsBuyer` |
| A private sale pays the seller the full price, with no fee and no royalty | handler `buy` (exact deltas: seller +price, both funds and royalty receiver +0; frozen bps must be 0), `testFuzz_privateListingOnlyItsBuyer`, `test_F12_…` |
| A tip never exceeds 5% of the items' cost and only ever goes to `tipJar` | handler `buy` (random tips, including over-cap ones that must revert; exact delta for `tipJar` and nobody else), `testFuzz_tipCappedAndPaidToTipJar` |
| `withdrawFor` never pays anyone but the payee | handler `withdrawFor`: the payee is paid exactly its pending and every other tracked address is unchanged |
| Storage matches the model (frozen rates, prices, expiries, nonces, private buyers, remaining, roots, tip jar, guardian, royalty registry, both funds, allowances) | `invariant_storageMatchesModel`, `invariant_creatorAllowanceNeverExceeded` |
| No receive() hook ever re-entered a guarded function | `invariant_noReentry` |

### Runs on `66ef13d` (current; same sizes as before)

| Campaign | Size | Result |
|---|---|---|
| Foundry invariant | **5,000 runs × depth 200 = 1,000,000 calls**, 30 min; `owner()` changed 43,302 times, 19,885 allowances granted, 2,706 royalty-fund withdrawals | **6/6 invariants pass, 0 violations** (incl. `invariant_creatorAllowanceNeverExceeded` with the holder-while-`owner()` check) |
| Foundry stateless fuzz | 8 tests × **20,000 runs** (incl. `testFuzz_allowanceOnlyForItsHolder`), plus 12 fixed tests | pass |
| Medusa | 30 min, 12 workers, **7.63 M calls**, 4,656 branches | 4/4 properties pass |
| Echidna | 30 min, 8 workers, **1.09 M calls**, seqLen 200 | 4/4 properties pass |
| Halmos (yices, loop 3, 300 s per query, 15 min per check; run on `52655e7`) | 7 checks | **Proved for all inputs:** `check_nonOwnerCannotUseOwnerPowers` (any caller ≠ owner; 9 owner powers incl. `setCreatorAllowance`, `renounceOwnership`), `check_privateListingOnlyItsBuyer`, `check_offerOnlyTakesItsOwnCollection`, `check_offerFillAndCancelLeavesNothing`.<br>**Not proved:** `check_buySplitConservesAndRespectsCaps` (solver TIMEOUT on the price × bps division); `check_floorFundOnlyLeavesToAllowed` and `check_anySingleCallCannotTakeBidderOrSellerAssets` (any sender, any calldata: did not finish in 15 min and were killed; the floor-fund one last passed on `1049d1f`). These are covered by the fuzzers (`testFuzz_buySplitIsExact`, `testFuzz_floorFundOnlyOwner`, `testFuzz_royaltyFundRules` at 20 k runs each; the handler's exact per-call deltas), **not proved**. |
| Mutation test (harness self-check) | **41 planted bugs**, each in its own copy, 64 runs × depth 200 + all fuzz tests | **40/41 caught on the first pass**, including M42–M45 on the holder check. M19 (`_isLive` ignores the allowlist) survived this seed; it was caught on every earlier run, but only by chance. The deterministic `test_disallowedCollectionListingIsStaleAndClearable` now kills it. **41/41.** |
| Mainnet fork, the 6c34b7c launch list (block 26 328 430; run on `52655e7`) | real `transferFrom` semantics, then list → buy and offer → accept through the marketplace | 29 OK; POW Bull Badge untradeable (F-9, now off the list); BCSH ETH not exercised (no EOA-held token among the ids tried) |

Successful marketplace calls in the 1M-call Foundry campaign (calls − rejected):

| Action | OK | Action | OK |
|---|---|---|---|
| list | 33,498 | listPrivate | 18,626 |
| buy (incl. private, with tips) | 13,189 | acceptOffer | 22,874 |
| placeOffer | 17,523 | cancelOffer | 21,067 |
| ownerRefundOffers | 10,824 | withdraw | 893 |
| withdrawFor | 460 | withdrawFloorFund (owner only) | 2,140 |
| withdrawRoyaltyFund | 2,706 | ownerSetCreatorAllowance | 19,885 |
| setCollectionOwner (random `owner()` changes) | 43,302 | guardianPause | 2,230 |
| strangerAdmin / ownerTriesRenounce | 0 (all 21,700 / 21,897 rejected, as they must be) | | |

Planted bugs (each caught by at least one invariant or test, unless noted):

- **Pricing:** refund at the current fee; buy at the current fee; royalty ignoring min(); royalty at max(); seller paid the full price.
- **Who may act:** no self-trade check; Merkle check skipped; allowlist ignored on fill; self-serve without the owner() check; anyone can pause; guardian can unpause; refundOffers while live.
- **Where money goes:** registered royalty paid to the tip jar; refund to the owner; deferred payout not recorded; withdrawFor pays the caller; tip paid to our owner.
- **Listing state:** nonce ignored; offer not deleted; clearStale removes live listings; `_isLive` ignores the allowlist.
- **The fee's path and the two funds (new):** fee into the royalty fund; fee pushed to the seller; anyone can withdraw the floor fund; floor withdraw not debited; unregistered royalty into the floor fund; royalty fund paid to any recipient; royalty withdraw not debited.
- **Creator allowance:** not reduced; not checked; creator withdraws while blocked; anyone can set an allowance; holder not checked; holder not recorded; granted with no `owner()`; holder recorded as our owner.
- **Private listings and tips:** anyone can buy a private listing; a private listing charges the fee; a public relist keeps the private buyer; removal keeps the private buyer; tip not capped.

Earlier versions were run at the same sizes, with the same outcome (no violations):
- `52655e7`: 1M calls, Medusa 4.9M, Echidna 1.0M, 37/37 mutants, Halmos 4 proved / 3 not proved;
- `cf247b3`: 1M calls, Medusa 10.5M, Echidna 1.4M, 31/31 mutants;
- `9ac7a41`: 400k calls, Medusa 2.6M, Echidna 385k.

## Limits: what this does NOT cover

- **Tools check the code against the rules we wrote down.** If a rule itself is wrong (as with F-6, F-8 and F-14, which were behaving as designed), only a human reading the design catches it.
- **Mock collections.** The invariant harness uses OpenZeppelin ERC-721. Real collections can differ. The fork check covers the 31 launch collections' basic semantics at one block; upgradeable collections can change later, and a new collection needs re-checking before `setCollectionAllowed`.
- **Bounded state.** The model has 3 collections × 6 tokens, 5 actors, prices ≤ 50 ETH, ≤ 3 items per buy, ≤ 2 per fill, and Merkle sets of ≤ 2 leaves. It does not cover gas limits of large batches, ETH force-sent by selfdestruct (the balance invariant would become ≥), ERC-1155, or exotic tokens.
- **Halmos is bounded, and partly inconclusive:** loops are unrolled 3×, symbolic arrays have length ≤ 2, and the "any call" proofs cover a **single** call from a fixed starting state. Any check marked TIMEOUT in the Runs table counts as fuzzed, not proved.
- **Not in scope:** the frontend, the keeper, the off-chain rebate (beyond F-12 / F-14), the creator-allowance agreements made off-chain, the deploy script and ownership handover, MEV beyond F-3 and F-6, and Etherscan verification.
- **The fork check covers the 6c34b7c launch list.** LAUNCH-COLLECTIONS-ETH.md now says the final allowlist comes from a rights register plus nft-data `supported`. Any collection on that list that was not fork-checked here needs the same check before `setCollectionAllowed`.
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
