# MarketplaceV3: signed listings

nftprof, 2026-11-03: listing should not need a transaction. Go for build and test 2026-11-06. **Not deployed, not audited.**

Spec: products-pfpvault-v13-frontend PR #10, `docs/LISTING-PRICE.md` (price rules) and `docs/PATRONS.md` §3 (audience).

## What changed in `src/MarketplaceV3.sol`
- **On-chain listings, offers and private sales are unchanged.** Signed listings sit alongside them.
- **`Order` (EIP-712, domain `PentagonMarketplaceV3` v1).** The seller signs:
  - collection and token;
  - a price rule;
  - an audience;
  - the fee and royalty rates shown when signing;
  - the nonce, start and expiry (at most 180 days), and a salt.
  The seller pays no gas to list.
- **`buySigned(SignedBuy[], tip)`.** Each item carries the order, the seller's signature, the co-signer's `FillAuth` (order hash, buyer, clean floor F, a deadline at most 5 minutes ahead) and the buyer's `maxPrice`. Signatures are checked with `SignatureChecker`, so EOAs and ERC-1271 wallets both work.
- **The price rule:** `price = clamp(schedule(t) × floorFactor(F / F0), priceMin, priceMax)`.
  - schedule: `startPrice` until `rampStart`, a straight line to `endPrice` at `rampEnd`, then held.
  - floorFactor: `1 + up × (r − 1)` when r ≥ 1, else `1 − down × (1 − r)`, with up and down in basis points (0–10000).
  - `floorRef = 0` means the floor is ignored, and up and down must then be 0.
  - Fixed-point maths uses `Math.mulDiv`. A fuzz test checks that the result always lies within `[priceMin, priceMax]`.
  - `priceAt(order, floor, t)` is a public view, so the site can chart exactly what the contract will charge.
- **Cancel:**
  - `cancelOrders(Order[])` cancels individual orders; it costs gas and works while paused.
  - `incrementNonce()` cancels every listing at once, signed or on-chain.
  - A filled order is marked filled, so it can never be replayed, even if the NFT comes back to the seller.
- **A fill also removes any on-chain listing of the same token.**
- **Fee and royalty:** a signed order pays **today's** fee and royalty, settled exactly as on-chain sales are:
  - the fee goes to `floorFundOf`;
  - an unregistered royalty goes to `royaltyFundOf`;
  - a registered royalty goes to its receiver.
  The order is **refused (`RateAboveSigned`) while either rate is above what the seller signed.**
- **New owner power:** `setCosigner` (onlyOwner, the same style as `setGuardian`); 0 stops all signed fills. The co-signer can only allow or refuse a fill: it can't change a price, buyer limit or audience the seller signed.
- **Hold hook:** `_beforeSale(collection, tokenId, seller, buyer)` is called before every sale (listings, signed orders, offers). It's empty for now, as the hook for a per-NFT hold.
- **Refactor:** the tip and refund tail of `buy()` moved into `_finishPurchase`, with no change in behaviour.
- **Size:** 21,032 bytes of runtime code, against the 24,576 limit.

## Ambiguities resolved (please confirm)
1. **Fee and royalty "frozen at signing".** The contract can't prove which rates applied when a signature was made. A seller could sign `feeBps = 0` and skip the fee, so a signed rate can't simply be trusted. So the signed rates are treated as a **ceiling**:
   - the order pays today's rate;
   - it's refused while today's rate is above the signed one.
   For royalties this matches on-chain listings, which already pay the lower of the frozen and current rates. For the fee it differs:
   - a fee **raise** pauses open signed orders until they're re-signed (free);
   - a fee **cut** applies to them at once.
   A creator raising their royalty also pauses their collection's signed orders.
2. **No fat-finger floor in the contract.** The spec puts the "under 10% of floor" guard in the listing form ("blocked unless typed twice"). On-chain, `priceMin > 0` is enforced and the seller's min/max always hold. The phishing and fat-finger guard is the **co-signer's** job (below).
3. **Signed orders always pay the fee and royalty.** The free person-to-person sale stays `listPrivate`. A "named wallets" audience on a signed order is a private *offer*, not a free transfer.
4. **Currency:** native coin only (ETH on Ethereum), as in the rest of V3. The order has no currency field.
5. **The co-signer role** is set directly by the owner, like the guardian. V3 has no timelock pattern to copy.

## What the co-signer must refuse (the server side, for the CI/CD session)
It signs a `FillAuth` only when **all** of these hold:
- **Audience:** the buyer is in the order's audience (collectors only = Baron+, holders of X, named wallets). The audience hash's format is defined off-chain; it's opaque to the contract.
- **Floor:** F is our clean floor index, never the cheapest listing, and at most 5 minutes old. F moves no faster than its rate cap.
- **Phishing and fat-finger:** refuse when the computed price is under 10% of F, unless our server recorded the seller's double confirmation when the order was submitted. Refuse orders that never came through our listing API.
- **Re-listing after a sale:** an order from a previous holder stays valid on-chain if the NFT returns to them (the same as Seaport). Refuse orders signed before the seller's latest acquisition of the token.
- **Rates:** refuse an order whose fee or royalty differs from the rates in force when our API accepted it.
- The **co-signer key** is a KMS key; it isn't created yet, and needs nftprof's confirmation in AWS Admin. Losing it stops signed fills, but it can't take funds or NFTs.

## Audit re-run must cover
- **New functions:**
  - `buySigned`, `cancelOrders`, `priceAt`, `hashOrder`, `fillAuthDigest`, `_checkOrder`, `setCosigner`;
  - the `_beforeSale` call sites and the `_finishPurchase` refactor of `buy()`.
- **EIP-712:**
  - the typehash strings match the structs field for field;
  - `abi.encode(TYPEHASH, order)` equals per-field encoding (all fields are static);
  - the domain separator after a chain fork.
- **Signatures:**
  - ERC-1271 sellers, including a wallet that answers yes to everything (it can only sell its own NFTs);
  - malleability (OZ ECDSA rejects high-s);
  - replay across orders, buyers, floors and deadlines.
- **Price maths:**
  - overflow with extreme F / F0 (uint128) and prices (uint96);
  - rounding direction;
  - the step schedule when `rampStart == rampEnd`;
  - Dutch auctions.
- **Rate checks:** the `RateAboveSigned` ceiling, so no path pays less than today's fee or royalty.
- **Interplay:**
  - an on-chain listing and a signed order on the same token;
  - `clearStale`;
  - offers accepting a token that has a signed order;
  - nonce shared between both listing kinds.
- **Reentrancy:** the guard on `buySigned`, plus payouts deferred to `withdraw`.
- **The invariant suite:** extend `test/MarketplaceV3.invariant.t.sol`'s handler with `buySigned`, `cancelOrders` and fee/royalty changes. The existing invariants (solvency equals the funds plus pending payouts) must hold with signed fills.

## Tests
`test/MarketplaceV3Signed.t.sol`: 45 tests, including a fuzz test of the price bounds. Full suite: 237 passed, 0 failed, 1 skipped (that test was already skipped before this change).

## Open questions for nftprof
1. Rates as a ceiling (Ambiguity 1): is a fee raise pausing signed orders acceptable?
2. Should the contract itself refuse prices under X% of F, as a hard backstop if the co-signer misbehaves? The cost: an honest cheap sale needs the order's priceMin set accordingly.
3. Per-NFT hold: the `_beforeSale` hook is ready. Should a flagged token be blocked from all three sale paths?
4. Should a "named wallets" signed order be free, like `listPrivate`, or keep the fee?
