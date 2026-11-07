# MarketplaceV3: signed listings

nftprof, 2026-11-03: listing should not need a transaction. Go for build and test 2026-11-06. Rulings on the four open questions came on 2026-11-07. **Not deployed, not audited.**

Spec: products-pfpvault-v13-frontend PR #10, `docs/LISTING-PRICE.md` (price rules) and `docs/PATRONS.md` §3 (audience).

## What's in `src/MarketplaceV3.sol`
**On-chain listings, offers and `listPrivate` work as before,** except that they now refuse flagged and held tokens (see "Flagged tokens"). Signed listings sit alongside them.

### Orders and fills
- **`Order` (EIP-712, domain `PentagonMarketplaceV3` v1).** The seller signs:
  - collection and token;
  - a price rule;
  - an audience (`audience` + `audienceKind`);
  - the fee and royalty rates shown when signing, and `acceptFeeChanges`;
  - the nonce, start and expiry (at most 180 days), and a salt.
  The seller pays no gas to list.
- **`buySigned(SignedBuy[], tip)`.** Each item carries:
  - the order and the seller's signature;
  - the co-signer's `FillAuth`: the order hash, the buyer, the clean floor F, a deadline at most 5 minutes ahead, `flagAck` and `clearFlag`;
  - the buyer's `maxPrice`;
  - a Merkle proof, for named-wallet orders.
  Signatures go through `SignatureChecker`, so EOAs and ERC-1271 wallets both work.
- **The price rule:** `price = clamp(schedule(t) × floorFactor(F' / F0), priceMin, priceMax)`. F' is the co-signer's F after the on-chain floor clamp (below).
  - `priceAt(order, floor, t)` is a public view.
  - A fuzz test checks that the result always lies within `[priceMin, priceMax]`.
- **Cancel:**
  - `cancelOrders(bytes32[] orderHashes)` cancels individual orders and works while paused. `orderStatus[seller][hash]` is keyed by seller, so a hash can only cancel the caller's own order.
  - `incrementNonce()` cancels every listing at once, signed or on-chain.
  - A filled order can never be filled again.
- **A fill also removes any on-chain listing of the same token.**

### 1. Fee and royalty changes (ruling: listings stay live by default)
- **`acceptFeeChanges = true` (the default in the listing form):** the order pays **today's** fee and royalty, even if raised after signing. The only limits are the contract's hard caps: a 5% fee and a 10% royalty.
- **`acceptFeeChanges = false`:** the order is refused (`RateAboveSigned`) while today's fee or royalty is above what was signed. The seller re-signs (free) or lets it lapse.
- **Either way,** an order never pays less than today's rates. Signing a 0% fee doesn't skip it.
- **The flag covers royalty raises too.** That was the coordinator's call (flagged for nftprof): a creator raising their royalty is treated like a platform fee raise.
- **Disclaimer text for the listing form:**

> **If fees change.** If KeepMine raises its fee, or the collection's creator raises their royalty, while your listing is up, the listing stays live and the sale pays the new rate. The fee is never more than 5% (paid by the buyer); the royalty is never more than 10%. Prefer not? Untick "Keep my listing live if fees change", and your listing pauses instead until you relist (free).

### 2. On-chain floor reference (ruling: softens crashes, never gets stuck)
- **State:** per collection, `floorRefs[c] = {ref, updatedAt}`.
- **Parameters** (owner-set, global; defaults in brackets):
  - `floorFallBpsPerDay`: 5–50% a day (20%);
  - `floorRiseBpsPerDay`: 5–1000% a day (50%);
  - `floorBackstopBps`: at most 50% (10%).
- **The band,** with `dt` = the time since `ref` last moved:
  - `low = ref × (1 − fall × dt)`, never below 0;
  - `high = ref × (1 + rise × dt)`.
- **On each signed fill:**
  1. F' = clamp(F, low, high).
  2. The price is computed with F'.
  3. The fill is refused if `price < low × backstopBps` (`BelowFloorBackstop`).
  4. `ref` becomes F' and `updatedAt` becomes now.
- **Seeding:** `seedFloorRef` is owner-only, one time, while `ref == 0`. Otherwise the first signed fill seeds `ref` from F. That first F is trusted as given, so seed the 14 collections before launch.
- **`floorBand(c, F)`** (public view) returns F' and `low`, so the site and co-signer can quote exactly.
- **Why it works:**
  - **A one-shot crash is softened.** A misbehaving co-signer reporting −90% an hour after the last fill moves F' by only 0.83%.
  - **A real, sustained drop gets through in days, not weeks.** −70% is fully reflected after 6 daily fills, or after 6.5 days of fills every 6 hours (both tested). Frequent fills can't slow tracking, because the band scales with elapsed time.
  - **It never gets stuck.** With no fills, the band keeps widening, and the backstop (a share of the decaying `low`) relaxes with it. After `1 / fall` days (5 at the default) the band is fully open.
- **Changed from the suggested design (EMA on top of the clamp):** I dropped the EMA. Combined with a band proportional to elapsed time, an EMA makes tracking quadratically slow under frequent fills: about 0.8% a day with hourly fills. The rate-limited clamp alone already acts as the smoother, and it keeps the "through within days" guarantee.
- **Backstop note:** a genuine sale priced under 10% of `low` can't go through the signed path, named-wallet gifts included. Such a sale can use an on-chain listing or `listPrivate`, unless the token is flagged.
- **Limit:** on a collection with no signed fill for more than `1 / fall` days, the band is fully open. A compromised co-signer could then set any F on the next fill. The seller's `priceMin`/`priceMax` and the buyer's `maxPrice` still bind.

### 3. Flagged tokens (ruling: sellable with a warning, resale locked until cleared)
- **`flagger` role** (owner-set) calls `setFlag(collection, tokenId, flagged, claimant)`:
  - it flags a token, or updates the claimant;
  - it can't lift a hold, except by clearing (`flagged = false`).
  Every change emits `FlagSet`.
- **Enforced in `_beforeSale`** on all three sale paths:
  - **Flagged:** sellable **only** through `buySigned` with `FillAuth.flagAck`. The co-signer sets `flagAck` only after the buyer accepted the warning. On-chain listings and offers refuse the token (`TokenFlagged`).
  - **Bought while flagged:** the token becomes **held**, and the price paid is recorded. Resale is refused on every path (`TokenHeld`). If the co-signer set `FillAuth.clearFlag` (a VIP / high-reputation buyer), the purchase **clears** the flag instead.
  - **Clearing:** the flagger, or a `clearFlag` purchase.
  - **The claimant** (the original owner, recorded by the flagger) may buy the token back at any time, on any path, even while held, at no more than **max(price paid, current floor ref)**. That clears it.
- **Why the higher of the two:** the claimant can always recover the piece at what the holder paid. The holder isn't forced below today's floor if they paid less, for example a cheap risk-taking purchase.
- **Limit:** **a flag binds this marketplace only.** The token can still move by direct transfer and trade elsewhere, and a hold follows the token, not the wallet. The buyer warning must say this plainly.
- **Warning text for the buyer (draft):**

> **This piece has been reported** (for example as stolen). You can still buy it here, but it will be **held**: you won't be able to resell it on KeepMine until the report is resolved, and the original owner may buy it back from you at what you paid (or the floor, if higher). Other marketplaces may refuse it too.

### 4. Named-wallet orders are free (ruling)
- **`audienceKind = AUDIENCE_NAMED (1)`:** `audience` is an OpenZeppelin StandardMerkleTree root over `["address"]` of the wallets that may buy. The buyer supplies a proof, verified on-chain (`NotPrivateBuyer` otherwise).
- **These orders pay no fee and no royalty,** exactly like `listPrivate`. The signed fee and royalty rates are ignored for them.
- **Any other kind** (collectors only, holders of X…) stays enforced by the co-signer, with its hash opaque to the contract, and pays the fee and royalty.
- **The co-signer is still required** for named orders, for the floor and the flag checks.

## Size
24,438 bytes of runtime code at `optimizer_runs = 200`, against the 24,576 limit: **138 bytes of headroom.** To make room I took two steps:
- I made the typehash and window constants private;
- I switched `cancelOrders` to hashes.
If audit fixes need more, building MarketplaceV3 with `optimizer_runs = 50` gives 23,830 bytes (746 of headroom), at slightly higher gas per call. That's a deploy-config decision, and it shouldn't change `foundry.toml` for the contracts already deployed.

## What the co-signer must refuse (the server side, for the CI/CD session)
It signs a `FillAuth` only when **all** of these hold:
- **Audience:**
  - for co-signer-enforced kinds, the buyer is in the order's audience;
  - for named-wallet orders, our server still checks that the list matches what the seller entered.
- **Floor:** F is our clean floor index, never the cheapest listing, and at most 5 minutes old.
- **Phishing and fat-finger:** refuse when the price is under 10% of F, unless our server recorded the seller's double confirmation. Refuse orders that never came through our listing API. The on-chain backstop is the last line, not the first.
- **Flags:**
  - set `flagAck` only after the buyer accepted the warning (above) in the UI;
  - set `clearFlag` only for a VIP / high-reputation buyer, per the policy nftprof sets.
- **Re-listing after a sale:** refuse orders signed before the seller's latest acquisition of the token.
- The **co-signer key** (KMS) is not created yet. It needs nftprof's confirmation in AWS Admin.

## Audit re-run must cover
- **New functions:**
  - `buySigned` / `_fillSigned`, `cancelOrders` (by hash, keyed by seller), `priceAt`, `hashOrder`, `fillAuthDigest`;
  - `floorBand` / `_floor`, `setFloorParams`, `seedFloorRef`;
  - `setFlag`, `setFlagger`, `setCosigner`;
  - `_beforeSale` on all three paths;
  - the `_finishPurchase` refactor of `buy()`.
- **EIP-712:**
  - the typehash strings match the structs field for field (including `audienceKind`, `acceptFeeChanges`, `flagAck`, `clearFlag`);
  - `abi.encode(TYPEHASH, order)` equals per-field encoding (all fields are static).
- **Signatures:** ERC-1271 sellers, malleability, and replay across orders, buyers, floors, deadlines and flag bits.
- **Rates:**
  - no path pays less than today's fee or royalty, except named-wallet orders, which pay none;
  - `acceptFeeChanges` stays bounded by the caps.
- **The floor band:**
  - overflow (`rise × dt` over long gaps; `ref` capped at uint128);
  - rounding;
  - first-fill seeding trust;
  - griefing: a malicious co-signer walking `ref` at the maximum rate;
  - the backstop when `low = 0`;
  - interplay with `priceAt` when F' = 0.
- **Flags:**
  - a held token can't be sold by any path except to the claimant;
  - the claimant cap uses the current ref (after a signed fill updates it, in the signed path);
  - clearing semantics;
  - re-flagging a held token keeps its hold;
  - offers and on-chain listings of flagged tokens.
- **Named-wallet orders:** the Merkle leaf format (double-hashed `abi.encode(address)`), proof malleability, and fee/royalty exemption only for kind 1.
- **Interplay:**
  - an on-chain listing and a signed order on the same token;
  - `clearStale`;
  - nonce shared between both listing kinds.
- **Reentrancy:** the guard on `buySigned`, and payouts deferred to `withdraw`.
- **The invariant suite:** extend `test/MarketplaceV3.invariant.t.sol`'s handler with `buySigned` (all kinds, flags), `cancelOrders`, fee/royalty changes, floor seeding and flags. Solvency (the funds plus pending payouts) must hold.

## Tests
- `test/MarketplaceV3Signed.t.sol`: 72 tests, including a fuzz test of the price bounds.
- Full suite: 264 passed, 0 failed, 1 skipped (that test was already skipped before this change).

## Open questions for nftprof
1. Should `acceptFeeChanges` also cover royalty raises? The coordinator's call was yes; please confirm.
2. Floor defaults (−20% / +50% a day, backstop 10%): are they right for the 14 collections, or should they be set per collection?
3. Who holds the flagger role (the Hallmark desk's key?), and what's the VIP / high-reputation bar for `clearFlag`?
4. A named-wallet sale priced under the backstop (a gift) has to use `listPrivate`. Is that acceptable?
5. If audit fixes overflow the 138 bytes of headroom, may MarketplaceV3 be built with `optimizer_runs = 50`?
