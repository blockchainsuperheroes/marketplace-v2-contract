# MarketplaceV3 on Ethereum: early release checklist

This is the early release: **only our own NFTs are allowed**, which keeps the risk low.
A professional audit comes before third-party collections are allowed.

## Decide before deploying (nftprof)

- [x] **No treasury** (nftprof, 2026-11-02): the 2.5% buyer fee goes to the collection’s floor fund. **Tip jar** (buyer tips, NFTC liquidity): 0xB2e3 for now.
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

## Deploy

```bash
TIP_JAR=0x… COLLECTIONS=0x…,0x… \
ROYALTY_COLLECTIONS=0x… ROYALTY_RECEIVERS=0x… ROYALTY_BPS_LIST=500 \
forge script script/DeployMarketplaceV3.s.sol --rpc-url $ETH_RPC --broadcast --verify \
  --private-key-file <throwaway key file>   # or --ledger
```

- Compile with the repo settings: solc 0.8.24, cancun, via_ir, 200 runs.
- `--verify` needs `ETHERSCAN_API_KEY`. The source must be verified on Etherscan, unlike V2 on Pentagon.

## Right after

1. 0xB2e3 calls `acceptOwnership()`. Until then the deployer is still the owner, so do it immediately.
2. Check on Etherscan:
   - `owner()` is 0xB2e3 and `pendingOwner()` is 0;
   - `feeBps()` is 250 and `defaultRoyaltyBps()` is 250;
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
