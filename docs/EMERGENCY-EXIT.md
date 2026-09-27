# Emergency exit: getting NFTs and funds out without the website

Use this if pentagon.games/redeem, market13, the server or the keeper is down.

**Taking an NFT back out needs neither the website nor the keeper.** It needs only:
- **the depositor wallet**, the one that checked the NFT in, which sends the transaction;
- **the lock admin, 0xB2e3e82a95f5c4c47E30A5b420Ac4f99d32EF61f**, which signs a free approval.

The lock only ever returns an NFT to its depositor.

## Contracts

| What | Chain | Address | Source |
|---|---|---|---|
| **Seller lock** `PentagonPrizeLockerOpen` (holders' own check-ins) | Ethereum mainnet (1) | `0x1AFc17a1B64Cb7095d68CD360e4766f951983aB9` | `src/PrizeLockerOpen.sol` · [Sourcify](https://repo.sourcify.dev/1/0x1AFc17a1B64Cb7095d68CD360e4766f951983aB9) |
| **Pentagon lock** `PentagonPrizeLocker` (pieces Pentagon Games lists) | Ethereum mainnet (1) | `0x7c0faC2561471A9810a5609e6FeD86af0A6d0924` | `src/PrizeLocker.sol` · [Sourcify](https://repo.sourcify.dev/1/0x7c0faC2561471A9810a5609e6FeD86af0A6d0924) |
| **Points Store** `PentagonVaultDrops` (proxy; listings, escrow, payouts) | Pentagon Chain (3344) | `0x1AFc17a1B64Cb7095d68CD360e4766f951983aB9` | `src/VaultDrops.sol` (v5 impl `0x24cc4068be87c78394bb4e480e01fc668584d2c5`) |

- The seller lock and the store share an address only by deploy-nonce coincidence; they are different contracts on different chains.
- ABIs are in [`docs/abi/`](abi/). The code is on branch `feat/nft-prize-vault` of `blockchainsuperheroes/marketplace-v2-contract`.
- The website, keeper and indexer code is in `blockchainsuperheroes/products-pfpvault-v13-frontend`, under `indexer/src/keeper.js`.

**RPCs:**
- Ethereum: `https://ethereum-rpc.publicnode.com`
- Pentagon: `https://rpc.pentagon.games`. It needs **legacy** transactions with an explicit gas price: `--legacy --gas-price 2gwei`.

## Option A: the offline tool (easiest)

Open [`tools/emergency-exit.html`](../tools/emergency-exit.html) in a browser with MetaMask. It's a single file with no server and no libraries. If MetaMask ignores `file://` pages, run `npx serve tools` and open the local URL.
1. Pick the lock, enter the NFT's collection and token ID, and press **Look it up**. It shows the lock ID, status, depositor, admin and nonce.
2. Connect **0xB2e3** and press **Sign withdraw approval**. It's free, valid for 24 h, and produces an approval text to copy.
3. Connect the **depositor** and press **Withdraw**. It dry-runs first, then sends. The NFT goes back to the depositor.

## Option B: command line (Foundry `cast`)

```bash
LOCK=0x1AFc17a1B64Cb7095d68CD360e4766f951983aB9      # or the Pentagon lock 0x7c0f…0924
ETH=https://ethereum-rpc.publicnode.com
# 1. find the lock entry for an NFT (0 = not in this lock)
cast call $LOCK "lockOf(address,uint256)(uint256)" <COLLECTION> <TOKEN_ID> --rpc-url $ETH
# 2. check it: seller lock returns (collection, tokenId, depositor, status, payout); status 1 = Locked
cast call $LOCK "locks(uint256)(address,uint256,address,uint8,address)" <LOCK_ID> --rpc-url $ETH
#    (Pentagon lock returns 4 fields: no payout)
cast call $LOCK "nonce()(uint256)" --rpc-url $ETH
```

**Admin approval** (EIP-712 `Withdraw`). Copy [`tools/withdraw-typed-data.example.json`](../tools/withdraw-typed-data.example.json) and fill in:
- `lockId`, `collection`, `tokenId`;
- `to` = the **depositor** from step 2;
- `nonce` = from `nonce()`;
- `deadline` = a unix time within 30 days, e.g. now + 24 h;
- domain `name` = `PentagonPrizeLockerOpen` for the seller lock, or `PentagonPrizeLocker` for the Pentagon lock, plus `verifyingContract` = the lock.

```bash
cast wallet sign --data --from-file withdraw.json --ledger        # signed by 0xB2e3 (hardware wallet)
# sanity check: this must equal the digest of what you signed
cast call $LOCK "withdrawDigest(uint256,uint256)(bytes32)" <LOCK_ID> <DEADLINE> --rpc-url $ETH
```

**Withdraw**, sent by the depositor wallet:
```bash
cast send $LOCK "withdraw(uint256,uint256,bytes)" <LOCK_ID> <DEADLINE> <ADMIN_SIG> --rpc-url $ETH --ledger   # or --private-key / --account
```

Without Foundry, use Remix: load `docs/abi/PentagonPrizeLockerOpen.json`, then **At Address** → the lock → `withdraw`. You still need the admin signature from Option A or `cast`.

## Before withdrawing a listed piece: delist it (Pentagon Chain)

The Ethereum lock doesn't know about Pentagon listings. Delist first, so nobody can claim a piece that's leaving.
```bash
PC=https://rpc.pentagon.games; STORE=0x1AFc17a1B64Cb7095d68CD360e4766f951983aB9
cast call $STORE "dropCounter()(uint256)" --rpc-url $PC                     # listings are 1..dropCounter
cast call $STORE "drops(uint256)(uint64,address,uint256,uint64,uint64,uint256,uint256,uint256,address,uint64,bool,bool)" <DROP_ID> --rpc-url $PC
cast call $STORE "sellerOf(uint256)(address)" <DROP_ID> --rpc-url $PC       # 0x0 = Pentagon listing
cast send $STORE "sellerDelist(uint256)" <DROP_ID> --legacy --gas-price 2gwei --rpc-url $PC   # by the seller
cast send $STORE "cancelDrop(uint256)" <DROP_ID> --legacy --gas-price 2gwei --rpc-url $PC     # or by the owner 0xB2e3
```
A piece that has been **claimed** shouldn't be withdrawn. Release it to the buyer, or refund them with `refundUndelivered(dropId)` (owner) first.

## Money exits (Pentagon Chain)

| Who | What | Call |
|---|---|---|
| Buyer, if not delivered in 7 days | Reclaim 100% (anyone may trigger; it always pays the buyer) | `reclaimFor(uint256 dropId)` |
| Owner | Refund an undelivered claim immediately | `refundUndelivered(uint256 dropId)` |
| Seller | Withdraw credited earnings (90% of delivered sales) | `withdrawPending()` from the seller wallet, or `withdrawPendingFor(address)` by anyone for them |
| Owner | Withdraw store proceeds (10% fees, project sales) | `withdrawProceeds(address to, uint256 amount)` |

Each is `cast send $STORE "<sig>" <args> --legacy --gas-price 2gwei --rpc-url $PC`.

## If the keeper is down

- **Withdrawals** (above) **don't need the keeper.**
- **Releases to buyers do:** the lock accepts `release` only from the keeper address. To replace the keeper:
  1. 0xB2e3 signs a `ProposeRoles(admin, keeper, nonce, deadline)` approval, and anyone calls `proposeRoles(admin, newKeeper, deadline, sig)`;
  2. wait **48 hours** (public);
  3. anyone calls `executeRoles(0x)`, or with a new admin's `AcceptAdmin` signature if the admin changes.

  While a claim waits, its buyer is protected: after 7 days they reclaim 100%.
- The keeper key lives only on the server, at `/etc/pfpvault/keeper.json`.

## What can't be recovered

- **If the admin key 0xB2e3 were lost,** nothing could leave the locks: withdraw, release and role changes all need its signature. Keep it on a hardware wallet. Don't convert it to a MetaMask smart account on Ethereum (the locks would then check signatures through ERC-1271); switching back restores it.
- **An NFT sent to a lock address with a plain wallet "Send"** instead of Check in can't be registered in the seller lock and can't come back. The Pentagon lock can adopt it through `checkIn` by its depositor.
- **An Ethereum NFT delivered to an AA2 (smart-account) address** has no key on Ethereum. Treat it as unrecoverable. It's prevented by three independent "no code at the recipient" checks.
