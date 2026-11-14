# MarketplaceV3 on Ethereum: early release checklist

This is the early release: **only our own NFTs are allowed**, which keeps the risk low.
A professional audit comes before third-party collections are allowed.

## Decide before deploying (nftprof)

- [x] **No treasury** (nftprof, 2026-11-02): the 1% buyer fee goes to the collection’s fee fund; the default royalty is 0.5%. **Tip jar** (optional buyer tips, the only NFTC liquidity source at launch; no fixed fee share): 0xB2e3 for now.
- [x] Two funds per collection, held in the contract (nftprof, 2026-11-02; closes audit F-14 / F-8):
  - `floorFundOf` = the buyer fee. Only 0xB2e3 withdraws it (`withdrawFloorFund`, to any wallet) to buy
    that collection's floor, here or on other marketplaces. The creator can never withdraw it.
  - `royaltyFundOf` = unregistered collections' default royalty. 0xB2e3 withdraws it to itself or the
    collection's owner() (`withdrawRoyaltyFund`). The collection's owner() can withdraw only what 0xB2e3
    has approved (`setCreatorAllowance(collection, amount)`; `type(uint256).max` = open for an active
    creator, `0` = revoke), after agreeing with us what it is for.
- [ ] **Launch collections**: our own Ethereum collections only. List the contract addresses.
- [ ] **Creator royalties for those collections**: receiver and bps (≤ 1000).
  - Or leave them unregistered, so their royalty goes to the floor fund.
- [ ] **Deployer**: a fresh throwaway wallet with about 0.01 ETH.
  - It owns the contract only during the script, then hands ownership to 0xB2e3 (two-step).

## Added by signed listings (c491f88, not deployed, not audited)

The checklist above was written for the on-chain-listing version. The signed-listing version (`docs/SIGNED-LISTINGS.md`) adds these, all still open:

- [ ] **The launch list** is no longer "our own NFTs only". It is the 14 LAUNCH collections in `docs/RIGHTS-REGISTER-ETH.md` that nft-data also marks `supported`. So the audit comes **before** this deploy, not after it.
- [ ] **Audit re-run** on the signed version. `docs/AUDIT-SELF-REVIEW.md` still describes `66ef13d`. The invariant handler now covers signed listings (see "Tests" in `SIGNED-LISTINGS.md`). Medusa, Echidna, Halmos and the full-size runs are not redone yet. Then the external audit.
- [ ] **Co-signer key** (`COSIGNER`): a KMS key, created through AWS Admin on nftprof's confirmation. Re-derive its address from `GetPublicKey`. Until it is set, signed orders can't be filled; on-chain listings and offers work.
- [ ] **Co-signer service** (CI/CD session): the checks in "What the co-signer must refuse".
- [ ] **Flagger** (`FLAGGER`): who holds it is open question 3.
- [ ] **Floor seeds** (`FLOOR_COLLECTIONS`, `FLOOR_REFS_WEI`): the clean floor of each launch collection, taken on deploy day. Seeding is one-time per collection. An unseeded collection takes the co-signer's first number as given.
- [ ] **Size:** 24,438 of 24,576 bytes at `optimizer_runs = 200`. An audit fix that adds code needs open question 5 answered first.

The deploy script takes the three settings as optional env vars and applies them before the handover. Anything left out is set later by 0xB2e3 (`setCosigner`, `setFlagger`, `seedFloorRef`). A local dry run of the script uses about 5.9M gas.

**Extra checks right after:**
- `cosigner()` and `flagger()` are right;
- `floorFallBpsPerDay()` is 2000, `floorRiseBpsPerDay()` is 5000 and `floorBackstopBps()` is 1000;
- `floorRefs(c)` is set for each seeded collection.

**Extra smoke test:** sign an order, fill it with a FillAuth, and cancel a second one by its hash.

**Extra emergency lever:** `setCosigner(address(0))` stops every signed fill at once. On-chain listings, offers, cancels and withdrawals keep working.

## Deploy

```bash
TIP_JAR=0x… COLLECTIONS=0x…,0x… \
ROYALTY_COLLECTIONS=0x… ROYALTY_RECEIVERS=0x… ROYALTY_BPS_LIST=500 \
COSIGNER=0x… FLAGGER=0x… FLOOR_COLLECTIONS=0x…,0x… FLOOR_REFS_WEI=…,… \
forge script script/DeployMarketplaceV3.s.sol --rpc-url $ETH_RPC --broadcast --verify \
  --private-key-file <throwaway key file>   # or --ledger
```

- Compile with the repo settings: solc 0.8.24, cancun, via_ir, 200 runs.
- `--verify` needs `ETHERSCAN_API_KEY`. The source must be verified on Etherscan, unlike V2 on Pentagon.

## Right after

1. 0xB2e3 calls `acceptOwnership()`. Until then the deployer is still the owner, so do it immediately.
2. Check on Etherscan:
   - `owner()` is 0xB2e3 and `pendingOwner()` is 0;
   - `feeBps()` is 100 (1% buyer fee) and `defaultRoyaltyBps()` is 50 (0.5%), per nftprof 2026-11-02;
   - `tipJar()` is right and `guardian()` is 0 (the role exists, unassigned);
   - `collectionAllowed()` is true for each launch collection;
   - `royaltyFor()` is right for each.
3. Smoke test with one cheap NFT of ours:
   - list, buy from a second wallet, check the payouts (seller gets price − royalty; the fee lands in `floorFundOf`, an unregistered royalty in `royaltyFundOf`);
   - place an offer, accept it, cancel a second offer.
4. Put the address into the frontend's `lib/marketV3.ts` (chain 1). The V3 UI turns on per chain.
5. Keeper job: watch `Transfer` AND `ApprovalForAll` / `Approval` events of the allowed collections, and call `clearStale` for listings that are no longer live. A listing made stale by revoking approval would otherwise come back at its old price when the seller approves again (audit F-1).

## Emergency

- `pause()` stops list, buy, placeOffer and acceptOffer. Cancels, delists and withdrawals keep working.
- `setCollectionAllowed(c, false)` stops one collection.
- Retiring: `pause()`, then `refundOffers(ids)` returns escrow to bidders (owner only, while paused).

## Before allowing third-party collections

- External audit. The self-run tool results are in `docs/AUDIT-SELF-REVIEW.md`.
- The creator royalty claim page and the floor-fund dashboard are live.
- The rebate rules are settled. See docs/REBATE-DESIGN.md: fee + royalty must stay above the 2% rebate.
