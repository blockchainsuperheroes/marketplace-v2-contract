# MarketplaceV3 vs industry marketplace contracts

Reviewed: `src/MarketplaceV3.sol` at `075e392` on `feat/marketplace-v3`. That commit includes `cbc2d8f`, which added self-serve creator royalties. Line numbers below refer to that commit.

Scope: this is a structural, function-by-function comparison with audited production designs. It is **not** a bug hunt. Static analysis and fuzzing are being run separately, and this report does not repeat them. Every claim about another protocol cites the file and line read (see [Sources](#sources)).

---

## 1. Summary verdict

**V3 is a sound, deliberately narrow simplification, not a bad reinvention.** For a low-volume early release it is a reasonable design. Every major mechanism has a direct counterpart in an audited contract:

| V3 mechanism | Closest audited precedent |
|---|---|
| Seller nonce for cancel-all | Seaport counter, Blur `nonces` |
| Mandatory expiry | Seaport `endTime`, Blur `expirationTime` |
| Criteria Merkle root over token ids | Seaport criteria items |
| Push with a gas cap and a fallback | LooksRare v2 `_transferETHAndWrapIfFailWithGasLimit` (byte-for-byte the same `call`) |
| `transferFrom` for ERC-721 | Seaport and LooksRare v2 |
| Pausable, Ownable, non-upgradeable | Blur is pausable and upgradeable. Seaport is ownerless and immutable. |

On-chain listings with escrowed native-coin offers remove whole classes of past incidents:
- signature phishing (OpenSea Feb 2022, Blur bulk-listing "Root" signatures);
- order-hash encoding collisions (Wyvern 2.2);
- ERC-20 allowance draining (Quixotic 2022, the Payment Processor "reverse" WETH route in 2026);
- fraction truncation (Seaport C4 H-01);
- "refund the whole balance" bugs (Blur C4 Nov 2022 H-01).

V3 is also **less admin-powerful** than Blur. Blur has a UUPS-upgradeable exchange and an owner-extensible execution delegate, and both were flagged in its audits. V3 has neither. The only way NFTs move is `buy` and `acceptOffer`, and both are `whenNotPaused`, so `pause()` is a complete kill-switch for NFT movement. The 2026 Payment Processor V2 incident shows why that matters: V2 could not be paused, while V3 of the same processor could.

No structural flaw that loses user funds was found. **Four small changes are recommended** (section 4, items R1–R4). None is a fund-loss bug. They close two "old state comes back" edges, one stuck-funds edge and one incident-response gap.

The largest residual risk is the same one Seaport and Blur carry. On-chain, a listing whose NFT leaves the wallet and comes back before anyone clears it is live again. V3 bounds this better than either reference (mandatory expiry ≤180 days, a seller-keyed listing slot that a new owner's listing overwrites, and permissionless `clearStale`). It cannot close it on-chain, so the remaining defence is operational (section 3.2).

---

## 2. Feature comparison

Concern levels:
- **none**: no action needed.
- **note**: understood trade-off, or an operational or front-end point.
- **change recommended**: a contract change is suggested in section 4.

| Feature | Seaport 1.6 | Blur Exchange (C4 2022 versions) | MarketplaceV3 | Concern |
|---|---|---|---|---|
| Order model | Signed EIP-712 orders off-chain, filled on-chain | Signed EIP-712 orders. An optional oracle co-signature (`blockRange`) gives off-chain cancellation. | On-chain `Listing` per (collection, tokenId); on-chain escrowed `Offer` | none |
| Cancel-all | `incrementCounter()` adds a quasi-random amount, `notEntered` ([ReferenceCounterManager.sol:34-49], [ReferenceConsideration.sol:566-574]) | `incrementNonce()` adds 1 ([BlurExchange.sol:207-210]) | `incrementNonce()` adds 1; the nonce is stored in each listing (L172-175, L200) | none (no pre-signed orders to activate) |
| Expiry | `startTime ≤ now < endTime`, no maximum ([ReferenceVerifiers.sol:44-53]) | `listingTime < now` and (`expirationTime == 0` **or** `now < expirationTime`) ([BlurExchange.sol:278-284]). 0 means "never, oracle-gated". | Mandatory, `now < expiry ≤ now+180d` at creation; valid while `expiry ≥ now` (L149, L200) | note (inclusive vs Seaport's exclusive end; length) |
| Ownership or approval check | None at validation; only the transfer reverts | None at validation; only the transfer reverts | Checked at `list`; `clearStale`/`isListingLive` check it again (L365-374) | note: out-and-back gap (3.2) |
| Stale-order clearing | Off-chain (OpenSea API) plus optional restricted orders (zones) | Optional oracle co-sign, so orders are default-deny unless freshly signed ([BlurExchange.sol:316-329]) | Permissionless `clearStale` by a keeper (L179-184) | note |
| Disallowed collection | n/a (permissionless) | n/a (policy allowlist is per matching policy) | `buy`/`acceptOffer` revert, but `_isLive` ignores the allowlist, so listings come back when the collection is re-allowed | **change recommended (R2)** |
| Fee/royalty path | Arbitrary consideration items signed by the offerer; Seaport adds nothing | `Fee[]` signed in the order, each `price*rate/10000` and taken from the seller side ([BlurExchange.sol:469-487]) | Fixed split: buyer fee + registry royalty, rates frozen per listing/offer (L382-401) | note |
| Royalty receiver | Fixed in the signed order | Fixed in the signed order | **Resolved at settlement** (`royaltyFor`, L392) while the **rate is frozen** at listing | **change recommended (R1)** |
| Rounding / dust | Floor/ceil by role; fractions must be exact, otherwise `InexactFraction` ([ReferenceAmountDeriver.sol:104-106]) | Floor per fee; seller gets the remainder | Floor; seller gets `price - royalty`; buyer pays `price + fee`. Inputs equal outputs exactly, with no dust. | none |
| Native-coin payout | Full-gas `call`; reverts on failure ([ReferenceExecutor.sol:124-141]) | Oct-22: `transfer` (2300 gas, reverts) ([BlurExchange.sol:508]). Nov-22: full-gas `call` + `require` ([Exchange.sol:631-632]). | 50k-gas `call`; on failure credits `pendingPayouts` (L412-421) | note |
| Pull fallback | none (no balance is held) | none | `withdraw()` only by the payee itself (L286-293) | **change recommended (R3)** |
| Excess-value refund | Refunds `address(this).balance`, safe because Seaport holds nothing ([ReferenceOrderCombiner.sol:811-812]) | `_returnDust` sent `selfbalance()`; with reentrancy this was C4 Nov-22 **H-01** ([Exchange.sol:212-226]) | Refunds `msg.value - spent` (L210); never the balance | none (correct for a contract that holds escrow) |
| Bids / offers | WETH (ERC-20) allowance to the conduit; offers can be unfunded at fill time | WETH allowance, or Blur Pool (pre-deposited ETH, moved only by the exchange) ([Pool.sol:58-68]) | ETH escrowed per offer: exact `msg.value` (L228), refunded on cancel | none (note: idle escrow) |
| Criteria / trait offers | `identifierOrCriteria` root; 0 = any id; a proof supplied for root 0 **reverts** ([ReferenceCriteriaResolution.sol:143-153]) | Standard policy: exact tokenId only ([StandardPolicyERC721.sol:24-61]) | `tokensRoot`; 0 = any id; proofs ignored when the root is 0 (L249, L261) | note |
| Merkle leaf | `keccak256(abi.encodePacked(uint256 id))`, sorted pairs ([ReferenceCriteriaResolution.sol:400-430]). The hash was added after C4 M-01. | n/a (Merkle used only for bulk signatures) | `keccak256(bytes.concat(keccak256(abi.encode(id))))` (OZ StandardMerkleTree), sorted pairs (L424-426) | none |
| Partial fills | `numerator/denominator` fractions, GCD scaling to uint120 ([ReferenceOrderValidator.sol:164-276]); history: C4 **H-01** truncation | ERC-721 whole; the ERC-1155 policy hard-coded amount 1 (C4 Oct-22 **H-01**) | ERC-721 listings are whole; offers use an integer `remaining` (uint16) (L248-257) | none |
| ERC-721 transfer | `transferFrom` + code-length check ([ReferenceTokenTransferrer.sol:74-86]) | `safeTransferFrom` via ExecutionDelegate ([ExecutionDelegate.sol:88-94], [BlurExchange.sol:537-538]) | `transferFrom` (L207, L264); no code-length check (allowlist instead) | none |
| Reentrancy | Global guard on fulfils; `cancel`/`incrementCounter` are `notEntered` | Global guard on `_execute`; Nov-22 `bulkExecute` with an empty array bypassed it (H-01) | `nonReentrant` on buy/acceptOffer/cancelOffer/refundOffers/withdraw. list/delist/incrementNonce/placeOffer are unguarded. | note |
| Batch buy | `fulfillAvailable*` skips invalid orders (`revertOnInvalid = false`, [ReferenceOrderCombiner.sol:156]); transfer failures still revert | `bulkExecute` delegatecalls each `_execute` and ignores failures ([Exchange.sol:168-210]) | All-or-nothing (L192-211) | note (UX) |
| Price protection | Fulfiller supplies the exact signed order; its price is bound into the hash | Match policy requires `makerAsk.price == takerBid.price` | `maxPrice` per item (L201) bounds the **price** only; the fee is frozen per listing | note |
| Upgradeability | None (immutable) | UUPS `_authorizeUpgrade onlyOwner` ([BlurExchange.sol:53]); C4 Nov-22 **M-02** | None (immutable) | none |
| Owner / admin | No owner on Seaport. Conduit owners can open channels ([ReferenceConduitController.sol:129-138]). | Owner sets the delegate, policies and oracle; delegate owner can `approveContract` any address ([ExecutionDelegate.sol:36-39]); C4 Oct-22 **M-01** | Owner: allowlist, fee ≤5%, royalty ≤10%, treasury/floor fund, pause, refunds to bidders while paused, block self-serve. Cannot move NFTs or escrow. | none (see R4 for pause latency) |
| Emergency stop | None | `close()` ([BlurExchange.sol:47-50]) | `pause()` (owner only) | **change recommended (R4)** |
| ERC-1155 | Yes | Yes (policy) | No | note: scope, not a bug |
| Signatures / replay | EIP-712 with chainId; ERC-1271; bulk-order trees | EIP-712 with chainId; single and bulk | No signatures, so no replay or cross-chain surface | none |

Line references in the "MarketplaceV3" column (`L…`) are to `src/MarketplaceV3.sol` at `075e392`.

---

## 3. Topic-by-topic analysis

### 3.1 Order model: signed orders vs on-chain listings

**Seaport and Blur:** makers sign EIP-712 orders. Listing is free. A cancel costs a transaction (`cancel`, `cancelOrder`), or the maker invalidates everything with the counter/nonce. Liveness is decided off-chain by the venue's API until someone fills on-chain.

**V3:** every listing is an SSTORE (two packed slots per `Listing`, L44-51). Offers are a transaction plus escrow.

| | Signed orders | V3 on-chain |
|---|---|---|
| Gas to list | 0 | ~2 cold SSTOREs per token (paid by the seller) |
| Gas to cancel one | 1 tx | 1 tx (`delist`, with an SSTORE refund) |
| Cancel-all | 1 tx (counter/nonce) | 1 tx (nonce) |
| Signature phishing | **Exposed.** OpenSea Feb 2022, Blur bulk "Root" signatures (section 5) | **Not exposed.** No signature authorises anything. |
| Replay / chain-id / encoding | Needs EIP-712 care, ERC-1271, bulk-tree depth checks | n/a |
| Off-chain dependency | Order book API; the off-chain view of "stale" can be wrong (OpenSea Jan 2022) | State is on-chain and authoritative; the keeper is only a cleaner |

**Verdict: sound for a low-volume early release.** The gas cost of listing on Ethereum mainnet is the real price paid. It is acceptable at early volumes and negligible on Pentagon chain.

One residual: **transaction-based phishing.** A malicious front-end could get a user to send `list(collection, [id], [1 wei], expiry)`. Wallet simulations would show *no asset movement* for that transaction, which resembles blind signing. This is far harder to pull off than a signature request, because the user must send a transaction to our verified contract, and wallets decode its calldata. It is still worth a line in the security FAQ: "a listing transaction at a price you didn't type is a phishing attempt."

### 3.2 Stale or zombie listings

How each design decides that an order is dead:

- **Seaport:** cancelled or filled status, counter, and time ([ReferenceOrderValidator.sol:117-204]). Ownership is never consulted. A sale that would fail only reverts at transfer time.
- **Blur:** `cancelledOrFilled[hash]`, `nonces`, and time ([BlurExchange.sol:258-284]). Orders with `expirationTime == 0` also need an oracle co-signature from the last `blockRange` blocks ([BlurExchange.sol:316-329]), so for those the default is **deny** unless the oracle keeps signing.
- **V3:** in `buy`, the nonce and expiry checks (L200); then `transferFrom` reverts if the seller no longer owns the NFT or has revoked approval. `clearStale` deletes listings that fail the full `_isLive` check (L365-374).

**V3 is stronger than both references in three ways:**
1. Expiry is mandatory and capped at 180 days. Blur allows "never expires"; Seaport has no cap.
2. There is one listing slot per (collection, tokenId). When a new owner lists, the previous owner's listing is **overwritten**. With signed orders, every previous holder's orders coexist and each one can come back.
3. Anyone can permanently delete a dead listing, and a sale through V3 always deletes it, including `acceptOffer` (L262).

**The gap (shared with Seaport and Blur):**

Seller A lists token T with `setApprovalForAll`. T then leaves A's wallet (sold elsewhere, moved to a cold wallet, staked, or lent) and **returns before `clearStale` runs**. A's listing is live again at the old price. This is exactly the OpenSea Jan 2022 pattern: a transfer to another wallet and back made the listing disappear from OpenSea's UI, but the order stayed fillable on-chain.

Facts that bound the gap:
- A one-transaction round trip (lend and repay, stake and unstake, a flash-style flow) can never be caught by any keeper.
- If the seller used **per-token** approval (`approve`) instead of `setApprovalForAll`, the ERC-721 transfer clears `getApproved`. The listing then stays dead even after T returns, until it is re-approved.
- The nonce and the 180-day cap are the only on-chain limits. ERC-721 offers no transfer counter that a listing could snapshot, so this **cannot be closed on-chain** without collection cooperation.

Recommendations (operational, no contract change):
- The keeper must be **event-driven**, as DEPLOY-V3.md step 5 already says. It should clear on the *outbound* `Transfer` in the next block, not on a polling schedule. The existing test `test_zombieListing_isClearedAndCannotComeBack` assumes the keeper wins that race; add a test that documents the race loss (T returns before the clear, and the listing revives) so the behaviour is explicit.
- The front-end and indexer should, on any **inbound** `Transfer` to a wallet that holds a V3 listing for that token, show "your listing from <date> at <price> is live again", with a one-click delist.
- Product decision: consider a shorter **default** expiry in the UI (e.g. 30 days) while keeping the 180-day contract cap. After Jan 2022, OpenSea cut its default listing duration from six months to one month.

### 3.3 Fee and royalty payment paths

**Seaport** has no fee logic. Fees and royalties are just consideration items in the signed order, so the recipient and amount are fixed at signing. **Blur** has a signed `Fee[]` taken from the seller side ([BlurExchange.sol:469-487]).

**V3** hard-codes a single split (L382-401):
- buyer pays `price + fee`;
- treasury receives `fee`;
- royalty receiver receives `royalty = price*royaltyBps/10000`;
- seller receives `price - royalty`.

Both rates are frozen per listing or offer. Arithmetic is exact: inputs equal outputs with no dust in either the listing or the offer path. Offer escrow is `(price + floor(price*feeBps/1e4)) * qty`, and each fill pays exactly one unit of that. This is simpler than either reference and correct.

**The structural difference:** the royalty *receiver* is resolved live in `_settle` (`royaltyFor(collection)`, L392), while the *rate* is frozen at listing. Before `cbc2d8f` only our owner could change the receiver. Now the collection's `owner()` can also change it (`registerRoyaltyAsCreator`, L322-327). Consequences:
- A creator registered at 10% is later removed (by us, or by the creator sending receiver = 0). Every listing still open at 10% then pays **10% to the floor fund**, not the 2.5% default.
- A registration overridden from creator X to Y redirects the frozen royalty on all of X's open listings and offers to Y.

Nobody's *seller proceeds* change, so this is not theft. But the rate and the receiver come from two different registry states. That breaks the header's "both rates are frozen" mental model, and it qualifies "the owner can never move anyone's ... money elsewhere" (L37) for the royalty slice. See **R1**.

**Push vs pull.** V3's `_pay` (L412-421) is the same instruction LooksRare v2 uses: `call(gasLimit, to, amount, 0, 0, 0, 0)` in `_transferETHAndWrapIfFailWithGasLimit` (LooksRare/contracts-libs `LowLevelWETH.sol`). LooksRare's default is 2,300 gas, owner-adjustable but never below 2,300 ([LooksRareProtocol.sol:102, 313-321]). On failure LooksRare wraps the amount to WETH and pushes that; V3 credits a pull balance. Seaport and Blur (Nov-22) instead forward all gas and **revert** on failure, so a recipient that rejects payment blocks the trade but nothing is ever held.

V3's choice is the more robust of the two for trade completion, and the 50k cap is sensible: it is enough for a Safe proxy's `receive`, while bounding gas griefing per recipient. Two side-effects:
- (a) A caller can supply just enough gas that the 63/64 rule leaves a payee less than 50k, forcing deferral. That is griefing into a `withdraw` transaction, not a loss.
- (b) Deferred money can only be pulled by the payee calling `withdraw()` itself. See **R3**.

### 3.4 Offers: escrow vs Blur Pool vs Seaport criteria

- **Seaport** offers are WETH allowances to a conduit. **Blur** bids use WETH or Blur Pool. Blur Pool is a deposit ledger whose balances only the Exchange or Swap contract can move ([Pool.sol:58-68]); one deposit backs any number of signed bids. Both are capital-efficient, but a bid can be **unfunded** at fill time (spoofed depth), and the allowance or deposit is a standing authority. That authority is the surface used in Quixotic 2022 and in the 2026 Payment Processor "reverse" exploit, where about 660 WETH was lost.
- **V3** escrows exactly `(price+fee)*qty` per offer (L228). That is capital-inefficient but always funded, and it creates no ERC-20 approvals at all. The cost: the contract now holds pooled ETH (all offer escrow plus `pendingPayouts`), so it is a honeypot to the same degree as Blur Pool. V3 correctly never refunds "the balance" (contrast Blur Nov-22 H-01).
- **Idle escrow:** an expired offer keeps its ETH until the bidder calls `cancelOffer`. There is no permissionless expired-offer refund (compare `clearStale` for listings). See N3.

**Criteria.** V3's `tokensRoot` matches Seaport's semantics: a root of 0 means "any token of the collection" ([ReferenceCriteriaResolution.sol:143-153]). Differences:
- Leaf: V3 uses the OZ StandardMerkleTree double hash; Seaport uses a single `keccak256(id)`. Both resist the C4 Seaport M-01 attack, where an intermediate node is passed as a token id, because the leaf preimage length differs from an inner node's. The two formats are not interchangeable, which is fine: V3 has its own tooling and a JS-library test (`test_traitOffer_acceptsProofFromTheJsLibrary`).
- Stray proofs for root 0: Seaport **reverts**; V3 ignores them. This is harmless. The real risk is a front-end that fails to build a root and sends `0x0`, which silently turns a trait offer into a floor (collection-wide) offer. Seaport carries the same risk. See N4.

### 3.5 Partial fills and quantity

Seaport's fraction machinery (`numerator/denominator`, GCD rescaling into uint120, [ReferenceOrderValidator.sol:164-276]) is the most intricate part of Seaport. It produced C4 **H-01** (uint120 truncation reset fills; fixed in 1.1). V3 needs none of it. Listings are single ERC-721s, offers use an integer `remaining` that is decremented before any external call (L250), and an offer is deleted when it reaches 0 (L257). Zero-quantity paths are rejected: `quantity == 0` (L225) and `tokenIds.length == 0` (L248). That is the exact class behind the TreasureDAO incident, where an ERC-721 sold for `price * 0`.

### 3.6 Reentrancy and the ERC-721 transfer choice

- **Seaport uses `transferFrom`** for ERC-721 ([ReferenceTokenTransferrer.sol:85]), behind a code-length check. It uses `safeTransferFrom` only for ERC-1155, where it is mandatory. LooksRare v2 also uses `transferFrom` ([TransferManager.sol:72] → `LowLevelERC721Transfer`). Blur uses **`safeTransferFrom`** ([ExecutionDelegate.sol:93]), which gives the buyer an `onERC721Received` callback mid-trade.
- **V3 uses `transferFrom`** (L207, L264). The buyer or bidder gets no callback. The external-call surface during a trade is therefore: the allowlisted collection contract, plus three or four 50k-gas payouts.
- Guards: every value-moving entry point is `nonReentrant`. `list`, `delist`, `incrementNonce`, `clearStale`, `placeOffer` and `registerRoyaltyAsCreator` are not. A payee could call these from inside its 50k payout callback. I traced the effects: re-listing a later item in the same batch is stopped by `maxPrice`, and a nonce bump or delist makes the batch revert. That is griefing the payee could already do by front-running, with no theft. Seaport, by contrast, marks `cancel` and `incrementCounter` `notEntered` ([ReferenceConsideration.sol:536, 569]). See N5.
- The NFT Trader incident (Dec 2023: reentrancy plus old approvals in a deprecated contract) is the lesson here. V3 deliberately avoids callbacks to counterparties, and should keep doing so.

### 3.7 Admin powers and upgradeability

| | Seaport | Blur | V3 |
|---|---|---|---|
| Owner on the exchange | none | yes | yes (Ownable2Step) |
| Upgradeable | no | UUPS, owner-only, no timelock ([BlurExchange.sol:53]) | no |
| Who can move approved NFTs | Seaport itself, plus any channel the conduit owner opens ([ReferenceConduitController.sol:129-138]) | Any contract the ExecutionDelegate owner approves ([ExecutionDelegate.sol:36-39]) | Only V3's own `buy`/`acceptOffer` code |
| Audit flags | n/a | C4 Oct-22 M-01 "Contract Owner Possesses Too Many Privileges"; Nov-22 M-02 "Hacked owner or malicious owner can immediately steal all assets" | n/a |
| Emergency stop | none | `close()` | `pause()` |

V3 sits at the safe end. User approvals point at immutable code, the owner cannot add transfer callers, and escrow can only flow back to its bidder (`refundOffers`, paused-only, L277-282).

**Over-powered?** One residual: the owner, and since `cbc2d8f` a collection's `owner()`, can redirect the royalty slice of open listings and offers (R1).
- Allowlisting a malicious or upgradeable collection would let that collection's admin fake transfers and drain **offers on that collection only**. Seaport WETH offers carry the same trust in the collection, so this is an inherent trust assumption, not a defect (N6).

**Under-powered?**
- Pausing needs the owner (the 0xB2e3 multisig per DEPLOY-V3.md). Incidents are time-critical: in the Sept 2026 Payment Processor case the rescuer reported learning of it more than 12 hours late. See **R4**.
- There is no per-token block for reported-stolen items. OpenSea does this off-chain; for V3, front-end blocking is enough (N7).

### 3.8 Batch buys, failure semantics, front-running

- **Seaport** `fulfillAvailableOrders` validates with `revertOnInvalid = false` ([ReferenceOrderCombiner.sol:156]): expired, cancelled or filled orders are skipped, but a transfer failure still reverts.
- **Blur** `bulkExecute` delegatecalls each `_execute` and ignores failures ([Exchange.sol:168-210]). Its dust refund then caused H-01.
- **LooksRare v2** offers an `isAtomic` flag: try/catch per order when false ([LooksRareProtocol.sol:188-262]).
- **V3** is all-or-nothing (L192-211). This is correct and simple, but one sniped item reverts a whole sweep. If a skip mode is added later, pre-check each item with the `_isLive` logic and `continue`, and refund `msg.value - spent`, never a balance-based amount. That arithmetic is exactly where Blur failed (N2).
- **Price protection:** `maxPrice` (L72, L201) is required, because V3 listings are mutable in place, unlike hash-bound signed orders. It bounds the *price* but not the *fee*. If the owner raises `feeBps` and the seller then re-lists at the same price, a buyer who over-sends (the NatSpec at L191 says "send at least") pays the higher fee, up to the 5% cap. The amount is small, the seller gains nothing, and a front-end that sends the exact total is protected by `InsufficientPayment` (L205). See N1.

### 3.9 Checks mature contracts make that V3 doesn't (and whether it matters)

| Check | Who does it | V3 | Matters? |
|---|---|---|---|
| Collection has code | Seaport `NoContract` ([ReferenceTokenTransferrer.sol:81-83]); Blur `_exists` ([BlurExchange.sol:534]) | Allowlist. An EOA would fail anyway: `ownerOf` decoding reverts, and a no-return `transferFrom` gets Solidity's extcodesize check. | no |
| `supportsInterface(721)` | Not in Seaport's or Blur's transfer path | none | no (allowlist) |
| Zero price | Seaport rejects zero native amounts ([ReferenceExecutor.sol:129]) | `BadPrice` (L158, L224) | covered |
| ERC-721 amount == 1 | Seaport ([ReferenceExecutor.sol:225-226]) | Implicit | covered |
| collection == this | none | Allowlist | no |
| Chain-id / replay | EIP-712 domains | No signatures | n/a |
| Fee-on-transfer tokens | n/a for native | Native only | n/a |
| Post-transfer `ownerOf` check | None of the three | none | no (a lying collection can lie in `ownerOf` too) |
| Start time | Seaport `startTime`, Blur `listingTime` | none | no (scope) |

---

## 4. Should write differently

### Change recommended

**R1. Make the royalty receiver and rate come from one consistent snapshot.**
*Where:* `_settle` L392-393 (`royaltyFor(collection)` returns the live receiver; `royaltyBps` is the frozen rate).
*Why:* After `cbc2d8f`, both our owner and the collection's `owner()` can change the receiver. Changing or removing a registration retroactively redirects the royalty on every open listing and offer, and a removed 10% creator rate gets paid to the floor fund at 10%. Seaport and Blur bind the recipient into the signed order.
*Code (preferred, no extra storage):* at settlement, use the live receiver but never more than the frozen rate.
```solidity
(address receiver, uint256 currentBps, bool registered) = royaltyFor(collection);
uint256 bps = royaltyBps < currentBps ? royaltyBps : currentBps; // seller never pays more than agreed
uint256 royalty = (price * bps) / 10_000;
```
This keeps "the seller never pays more than at listing time" and makes deregistration fall back to the default rate. *Alternative:* snapshot `receiver` into `Listing`/`Offer`. That is a third storage slot for `Listing` (about +20k gas per listing), and it would pay a creator who has since been removed in a dispute. Either way, update the header (L20-22, L37) to say exactly which part is frozen.

**R2. Treat a disallowed collection as "not live", so its listings can be cleared.**
*Where:* `_isLive` L365-374. `buy` (L199) and `acceptOffer` (L247) already revert for a disallowed collection.
*Why:* Today `setCollectionAllowed(c, false)` freezes listings without killing them. `clearStale` skips them and `isListingLive` reports them as live. Re-allowing the collection weeks later revives every old price at once. That is the "old listing comes back" failure (OpenSea Jan 2022), triggered by an admin action.
*Code:* add `if (!collectionAllowed[collection]) return false;` as the first line of `_isLive`. If a temporary per-collection halt without clearing is wanted, keep that as a separate flag rather than overloading the allowlist.

**R3. Let anyone trigger a pending payout to its owner.**
*Where:* `withdraw()` L286-293, which only lets `msg.sender` pull their own balance.
*Why:* Deferral happens precisely when the payee is a contract whose `receive` needs more than 50k gas, for example an auto-forwarding royalty splitter. Since `cbc2d8f` creators choose arbitrary receivers, so this is more likely. Such contracts often cannot make arbitrary calls, so they can never call `withdraw()`, and their money is stuck. OpenZeppelin's audited `PullPayment` (v4.9) uses exactly this pattern: `withdrawPayments(address payable payee)` is callable by anyone and forwards all gas, and the money can only go to `payee`.
*Code:*
```solidity
function withdrawFor(address payee) external nonReentrant {
    uint256 amount = pendingPayouts[payee];
    if (amount == 0) revert NothingToWithdraw();
    pendingPayouts[payee] = 0;
    (bool ok,) = payee.call{value: amount}("");
    if (!ok) revert WithdrawFailed();
    emit Withdrawn(payee, amount);
}
```
Keep `withdraw()` as `withdrawFor(msg.sender)`. Optionally add `withdrawTo(address to)` so a payee can redirect its own balance.

**R4. Add a pause-only guardian.**
*Where:* `pause()` L355-357 (owner only).
*Why:* `pause()` is V3's one complete kill-switch, because both NFT-moving paths are `whenNotPaused`. It is gated on the multisig quorum. In Sept 2026 the unpausable Payment Processor V2 was drained through stale approvals while the pausable V3 of the same processor was stopped, and the rescuer said they learned of it more than 12 hours late. Lending protocols commonly use a guardian that can pause and nothing else.
*Code:* `address public guardian;` with `setGuardian(address) onlyOwner`. `pause()` requires `msg.sender == owner() || msg.sender == guardian`. `unpause()` stays owner-only. The guardian can be a hot key held by monitoring. Its worst abuse is a pause, which still lets every user delist, cancel and withdraw.

### Notes (no contract change required; optional improvements)

- **N1. `maxPrice` excludes the fee.** Either rename it to `maxTotal` and check `price + fee` (L201), or document that front-ends must send the exact total. Tiny exposure (≤2.5 percentage points, only after an owner fee change plus a re-list).
- **N2. All-or-nothing batch buy.** Acceptable. If a skip mode is added, follow the Blur H-01 lesson in 3.8.
- **N3. Expired offers keep their escrow.** Consider `closeExpiredOffers(uint256[] ids)`, permissionless and refunding only to `o.bidder`, mirroring `clearStale`. Also consider a batch `cancelOffers`. Add `royaltyBps` to `OfferPlaced` (L95) so indexers can show sellers their proceeds without a storage read.
- **N4. `tokensRoot == 0` means any token** (same as Seaport). The front-end must refuse to submit a trait or single-item offer whose computed root is zero. Optionally revert in `acceptOffer` when `root == 0 && proofs.length != 0`, to match Seaport.
- **N5. Unguarded state-changers reachable from payout callbacks.** Analysed as harmless. For parity with Seaport's `notEntered`, add `if (_reentrancyGuardEntered()) revert` (OZ v5) to `list`, `delist`, `incrementNonce` and `placeOffer`. It costs little and removes a reasoning burden for future changes.
- **N6. Allowlist = trust in the collection.** Prefer immutable collections, or note the upgrade admin of any upgradeable collection that is allowlisted. A malicious upgrade could drain open offers on that collection only.
- **N7. Self-serve royalties at 0%.** A collection's `owner()` can register `bps = 0`, which removes the 2.5% floor-fund royalty for that collection. With the rebate, wash-trade margin then rests on the fee alone (2.5% > 2%). REBATE-DESIGN.md already covers creator self-washing. Decide whether self-serve should have a floor (e.g. `bps >= defaultRoyaltyBps`). LooksRare's 2022 rewards, which CryptoSlam estimated drove the large majority of its volume through wash trading, are the cautionary precedent.
- **N8. Out-and-back revival** (section 3.2): event-driven keeper, an inbound-transfer warning in the UI, and a shorter default expiry in the UI.
- **N9. Payout starvation:** a caller can force deferrals through the 63/64 gas rule. This is griefing only; no change needed.
- **N10. Expiry is inclusive** (`expiry < block.timestamp` is dead, L200) while Seaport's end is exclusive. This is a cosmetic difference; keep the off-chain code consistent with it.
- **N11. ERC-1155 is out of scope.** Seaport and Blur support it; V3 is ERC-721 only by design.
- **N12. Transaction phishing** (section 3.1): add the FAQ line about listing transactions at a price the user didn't type.

---

## 5. Past exploits and V3's exposure

| Incident | Mechanism | V3 exposure |
|---|---|---|
| **OpenSea inactive listings, Jan 2022** (Wyvern) | Old listings had no expiry and were never cancelled on-chain. Moving an NFT out and back hid the listing in the UI but left it fillable. Buyers filled them at old prices; OpenSea reimbursed about 750 ETH and cut default listing duration from 6 months to 1 month. | **Partially.** The out-and-back revival exists until a keeper clears it (3.2). It is bounded by the mandatory ≤180-day expiry, the one-slot-per-token overwrite and permissionless `clearStale`. The UI cannot hide a live listing, because state is on-chain. **R2** closes the admin-triggered variant. |
| **Wyvern 2.2 order-encoding flaw, disclosed Q1 2022** | Per OpenSea's disclosure, variable-length order parameters were concatenated without proper domain separation (packed encoding). That allowed taking WETH from users with active signed offers. It was neutralised before any user was affected. | **Not exposed.** No order hashes or signatures. The only hash is the Merkle leaf, built with `abi.encode` of a single `uint256`. |
| **OpenSea phishing, Feb 2022** (Wyvern migration period) | Victims signed half of a Wyvern order presented by a phishing email; the attacker completed it. About $1.7M in NFTs reportedly sold. | **Not exposed** to signature-based theft. Generic `setApprovalForAll` phishing to an attacker's address is outside any marketplace's control. |
| **Blur bulk-listing "Root" signature phishing, 2023 onwards** | Bulk listings sign one Merkle root of many orders. Phishing sites got users to sign roots that listed all approved NFTs at about 0 (reported losses include a ~$240k case). | **Not exposed** (no signatures). The residual transaction-phishing variant is far harder (N12). |
| **Seaport C4 May 2022: H-01 fraction truncation, M-01 Merkle intermediate node** | uint120 truncation reset fill status; criteria proofs accepted inner nodes as token ids. Both fixed in 1.1. | **Not exposed.** Integer `remaining`; double-hashed leaves. |
| **Blur C4 Oct 2022: H-01 ERC-1155 amount = 1; M-01 owner privileges** | The policy hard-coded the amount; the delegate owner could approve any transfer caller. | **Not exposed.** No ERC-1155; no delegate; immutable code. |
| **Blur C4 Nov 2022: H-01 dust refund + reentrancy; M-02 instant upgrade** | `_returnDust` sent `selfbalance()`, and an empty `bulkExecute` bypassed the guard; UUPS without a timelock. | **Not exposed.** Refund is `msg.value - spent` and every value path is guarded. Not upgradeable. |
| **TreasureDAO, Mar 2022** (Arbitrum) | `buyItem` accepted `_quantity = 0`, so an ERC-721 was bought for `price*0`. | **Not exposed.** Zero quantity and zero price are rejected (L225, L248, L158). |
| **Quixotic, Jul 2022** (Optimism) | After a contract update, a flaw in order verification let the attacker spend victims' approved ERC-20s. About $100k+ reported. | **Not exposed.** No ERC-20 allowances; money moves only from `msg.value` or escrow. |
| **NFT Trader, Dec 2023** | Reentrancy combined with old approvals in deprecated contracts drained about $3M in NFTs. | **Low.** No counterparty callbacks (`transferFrom`); value paths are guarded. Old-approval risk remains, and is mitigated by `pause()`. |
| **Limit Break Payment Processor V2 (used by Magic Eden 2024), Sept 2026** | A bug plus never-revoked approvals to a retired, **unpausable** contract. Whitehats moved about 23k NFTs; about 660 WETH was lost through a "reverse" route. V3 of the processor had the same flaw but was paused. | **Mitigated.** `pause()` stops every NFT-moving path. **R4** speeds it up. Operationally: when V3 is retired, pause it permanently and run a revoke campaign. |
| **LooksRare rewards wash trading, 2022** | Volume-based token rewards were farmed by self-trades. | **Economic, not contract.** This bears on the PC rebate. `SelfTrade` (L198, L246) is cosmetic against two wallets. See N7 and REBATE-DESIGN.md. |
| **X2Y2** | My search found no verified contract exploit of X2Y2's exchange, only phishing that also targeted X2Y2 approvals. | n/a |

---

## 6. Sources

**Code read (exact revisions):**
- Seaport 1.6, tag `1.6`, commit `e9c5a9f17cb5ee658ccc9cb1a8eeab02c1f5a4cd`, `reference/` (`_VERSION = "1.6-reference"`): https://github.com/ProjectOpenSea/seaport/tree/1.6/reference
  - `[ReferenceTokenTransferrer.sol]`, `[ReferenceExecutor.sol]`, `[ReferenceCounterManager.sol]`, `[ReferenceCriteriaResolution.sol]`, `[ReferenceVerifiers.sol]`, `[ReferenceOrderValidator.sol]`, `[ReferenceAmountDeriver.sol]`, `[ReferenceOrderCombiner.sol]` under `reference/lib/`; `[ReferenceConsideration.sol]` under `reference/`; `[ReferenceConduitController.sol]` under `reference/conduit/`.
- Blur Exchange as audited by Code4rena, Oct 2022: `code-423n4/2022-10-blur` @ `e29f20b4ece9d17ac33f38559c58bd3ce046f34d` (`contracts/BlurExchange.sol`, `ExecutionDelegate.sol`, `matchingPolicies/StandardPolicyERC721.sol`, `lib/MerkleVerifier.sol`): https://github.com/code-423n4/2022-10-blur
- Blur Exchange with `bulkExecute` and Blur Pool, Code4rena Nov 2022: `code-423n4/2022-11-non-fungible` @ `2bcfb8b923b9b27925e6227971659f3c020aeee9` (`contracts/Exchange.sol`, `contracts/Pool.sol`): https://github.com/code-423n4/2022-11-non-fungible
  - Blur's own `blur-io/blur-exchange` repository is no longer public (GitHub 404). Blur's currently deployed Exchange V2 and Blend were **not** reviewed; they are verified only on Etherscan. The Blur claims above are about the audited 2022 code.
- LooksRare v2: `LooksRare/contracts-exchange-v2` @ `7fca5650da653a2a0680e18e60164e639c18f830` (`contracts/LooksRareProtocol.sol`, `contracts/TransferManager.sol`): https://github.com/LooksRare/contracts-exchange-v2
  - and `LooksRare/contracts-libs` @ `622b6e42ca411a724a5b53259d1cb2cb40802fed` (`lowLevelCallers/LowLevelWETH.sol`, `LowLevelERC721Transfer.sol`): https://github.com/LooksRare/contracts-libs
- OpenZeppelin `PullPayment` v4.9.0 (`withdrawPayments(address payable payee)`): https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/security/PullPayment.sol
- Magic Eden M2: no official public source was found, so it is not compared.

**Audit reports:**
- Trail of Bits, Seaport (Apr–May 2022): https://github.com/trailofbits/publications/blob/master/reviews/SeaportProtocol.pdf
- Code4rena, OpenSea Seaport (May 2022): https://code4rena.com/reports/2022-05-opensea-seaport
- Code4rena, Blur (Oct 2022): https://code4rena.com/reports/2022-10-blur
- Code4rena, Non Fungible Trading / Blur Exchange + Pool (Nov 2022): https://code4rena.com/reports/2022-11-non-fungible
- I found no Seaport 1.6-specific audit report in the repository. The README links only the Trail of Bits review, and Spearbit review tags (`spearbit-audit-2022-12`) exist for earlier versions.

**Incidents:**
- OpenSea inactive listings, Jan 2022: https://decrypt.co/91513/opensea-refunds-ethereum-users-lost-nfts-inactive-listing-exploit and https://forklog.com/en/opensea-reimbursed-users-affected-by-a-vulnerability-to-more-than-1-9-million/
- Wyvern 2.2 disclosure (OpenSea): https://nft.mirror.xyz/VdF3BYwuzXgLrJglw5xF6CHcQfAVbqeJVtueCr4BUzs (summarised from search; the page returned 403 to my fetcher)
- OpenSea phishing, Feb 2022: https://decrypt.co/93371/opensea-ceo-devin-finzer-responds-1-7-million-phishing-attack and https://www.certik.com/blog/opensea-phishing-incident-analysis
- Blur bulk-listing signature phishing: https://support.metamask.io/stay-safe/protect-yourself/wallet-and-hardware/signature-phishing and https://decrypt.co/238281/user-lost-240000-nfts-blur-marketplace
- TreasureDAO, Mar 2022: https://rekt.news/treasure-dao-rekt and https://slowmist.medium.com/analysis-of-the-treasuredao-zero-fee-exploit-73791f4b9c14
- Quixotic, Jul 2022: https://cryptoslate.com/optimism-nft-marketplace-quixotic-suffers-exploit-following-contract-update/
- NFT Trader, Dec 2023: https://www.theblock.co/news/web3/2023-12-16-hackers-steal-nfts-worth-millions-from-apes-to-art-blocks-in-nft-trader-exploit-267963 and https://revoke.cash/exploits/nfttrader
- Payment Processor V2 / Magic Eden approvals, Sept 2026: https://decrypt.co/379342/magic-eden-old-ethereum-nft-listings-exposed-exploit and https://theblock.co/news/web3/2026-09-25-magic-eden-legacy-approvals-leave-5-7-million-in-nfts-exposed-to-exploit-before-rescue-416874 (reporting was still developing; figures vary by outlet)
- LooksRare wash trading, 2022: https://decrypt.co/91510/looksrare-has-reportedly-generated-8b-ethereum-nft-wash-trading
