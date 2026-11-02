# Ethereum launch collections (MarketplaceV3)

**Superseded by the rights register and the art gate:** the final allowlist is the collections with holder rights (docs/RIGHTS-REGISTER-ETH.md) AND nft-data `supported = true`.

**Rule (nftprof, 2026-11-01):** allow the Ethereum collections that the NFT data API supports, i.e. `https://nft-data.pentagon.games/api/v1/collections?chain_id=1`.

**Checked on-chain 2026-11-01:**
- every allowed contract reports ERC-721 support (`supportsInterface(0x80ac58cd)`);
- none exposes an ERC721-C `getTransferValidator()` or `operatorFilterRegistry()`.

`owner()` is the wallet that can self-register royalties, and later withdraw that collection's floor fund. "none" or `0x0` means no self-serve: only 0xB2e3 can act for that collection.

| Collection | Contract | owner() |
|---|---|---|
| Lil Pudgys | 0x524cab2ec69124574082676e6f654a18df49a048 | 0xf54c9A0E44a5F5aFd27C7aC8a176A843b9114F1d |
| MoonCats (Acclimated) | 0xc3f733ca98e0dad0386979eb96fb1722a1a05e69 | 0xdf2E60Af57C411F848B1eA12B10a404d194bce27 |
| Meebits | 0x7bd29408f11d2bfc23c34f18275bbf23bb716bc7 | none |
| Beanz | 0x306b1ea3ecdf94ab739f1910bbda052ed4a9f949 | 0x2aE6B0630EBb4D155C6e04fCB16840FFA77760AA |
| CLONE X | 0x49cf6f5d44e70224e2e23fdcdd2c053f30ada28b | 0x12eA19217C65F36385bB030D00525c1034E2F0Af |
| MAYC | 0x60e4d786628fea6478f785a6d7e704777c86a7c6 | 0xA858DDc0445d8131daC4d1DE01f834ffcbA52Ef1 |
| Azuki Elementals | 0xb6a37b5d14d502c3ab0ae6f3a0e058bc9517786e | 0x2aE6B0630EBb4D155C6e04fCB16840FFA77760AA |
| ByWassies | 0x1d20a51f088492a0f1c57f047a9e30c9ab5c07ea | 0xc73477ce3Ee165316FD456a4B5051ad497c41d4a |
| BAYC | 0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d | 0x0 (renounced) |
| World of Women | 0xe785e82358879f061bc3dcac6f0444462d4b5330 | 0xc9b6321dc216D91E626E9BAA61b06B0E4d55bdb1 |
| Azuki | 0xed5af388653567af2f388e6224dc7c4b3241c544 | 0x2aE6B0630EBb4D155C6e04fCB16840FFA77760AA |
| Doodles | 0x8a90cab2b38dba80c64b7734e58ee1db38b8992e | 0x9d863eD039D61B9313fdc06a9e5aB4B6c2F63ba8 |
| Moonbirds | 0x23581767a106ae21c074b2276d25e5c3e136a68b | 0x80d154D71F2e1400311c539ef5d08710bd37D044 |
| Milady Maker | 0x5af0d9827e0c53e4799bb226655a1de152a425a5 | 0x54F8E4E9842c93EF0E8F5A83374db0C521D728cB |
| Robotos | 0x099689220846644f87d1137665cded7bf3422747 | 0x63989a803b61581683B54AB6188ffa0F4bAAdf28 |
| uwucrew | 0xf75140376d246d8b1e5b8a48e3f00772468b3c0c | 0x59A722b367259D99Da35b63962B18258Bce5Cf66 |
| BAKC | 0xba30e5f9bb24caa003e9f2f0497ad287fdf95623 | 0xA858DDc0445d8131daC4d1DE01f834ffcbA52Ef1 |
| Pudgy Penguins | 0xbd3531da5cf5857e7cfaa92426877b022e612cf8 | 0xf54c9A0E44a5F5aFd27C7aC8a176A843b9114F1d |
| Killer GF | 0x6be69b2a9b153737887cfcdca7781ed1511c7e36 | 0x59A722b367259D99Da35b63962B18258Bce5Cf66 |
| Chimpers | 0x80336ad7a747236ef41f47ed2c7641828a480baa | 0x6Cc435F69fbac8cCdDc8757E46A9D4376FDB16b5 |
| Zombunnies | 0x10d2d273cb8f6179f1ddd2ee5689cdce363b9a01 | none |
| Hexagon City Estates | 0x28cd2990f34db387d011d7cc693a2bcedd8dc654 | none |
| BCSH ETH (ours) | 0x67abaddb1258077f7900abd8ade0ecc6cdc38ac2 | 0xB2e3e82a95f5c4c47E30A5b420Ac4f99d32EF61f |
| Remilio Babies | 0xD3D9ddD0CF0A5F0BFB8f7fcEAe075DF687eAEBaB | 0x54F8E4E9842c93EF0E8F5A83374db0C521D728cB |
| Chain Bunnies | 0x9f4564b85cb77ce76cc725f29758cbfe20213aae | 0x19668A890dD6b734093d8F8a304fa4795EBf9799 |
| Etheremon | 0x5d00d312e171be5342067c09bae883f9bcb2003b | 0x7BAE63C4Dbd39eC66669A1ef6E1CF6f747B71bdd |
| CryptoMorph CG | 0xfa69031b8f84ade91d1fac52148363842637699a | 0x4595ff64328Faf80a8cf0D52355639984b6Af23C |
| Zorare | 0x2a2ad5a2eacf35194d39afe1d727c39710ff0379 | none |
| Chainguardians LE | 0x4fe99deb8f0be517c31faaad49b4b054ed28c267 | 0x011E1Af0ba01E9d0919B0c152d49af28883B74a8 |
| Chainguardians | 0x3cd41ec039c1f2dd1f76144bb3722e7b503f50ab | 0xA3398CF357C154B6abB5460427f6DC37aB36Cb76 |

## Not allowed

| Collection | Data API address | Why |
|---|---|---|
| Nakamigos | 0x96c4241d26b63b20d007adfc9a0e1d0a9f7b6c55 | No contract at that address on Ethereum. The data API has a wrong address; ask nft-data to fix it, then re-check. |
| CG DAFA | 0x2f5a79a9979f37f0c15b521e2527c2a29199e833 | ERC-1155 (`supportsInterface(0xd9b67a26)` = true). MarketplaceV3 trades ERC-721 only. |
| POW Bull Badge | 0x2094e4f1ad01438eca93092e87033f87d8f76f63 | Blocks ordinary transfers (audit F-9, mainnet fork): listings would look live but every buy reverts. |

## COLLECTIONS for the deploy script

```
0x524cab2ec69124574082676e6f654a18df49a048,0xc3f733ca98e0dad0386979eb96fb1722a1a05e69,0x7bd29408f11d2bfc23c34f18275bbf23bb716bc7,0x306b1ea3ecdf94ab739f1910bbda052ed4a9f949,0x49cf6f5d44e70224e2e23fdcdd2c053f30ada28b,0x60e4d786628fea6478f785a6d7e704777c86a7c6,0xb6a37b5d14d502c3ab0ae6f3a0e058bc9517786e,0x1d20a51f088492a0f1c57f047a9e30c9ab5c07ea,0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d,0xe785e82358879f061bc3dcac6f0444462d4b5330,0xed5af388653567af2f388e6224dc7c4b3241c544,0x8a90cab2b38dba80c64b7734e58ee1db38b8992e,0x23581767a106ae21c074b2276d25e5c3e136a68b,0x5af0d9827e0c53e4799bb226655a1de152a425a5,0x099689220846644f87d1137665cded7bf3422747,0xf75140376d246d8b1e5b8a48e3f00772468b3c0c,0xba30e5f9bb24caa003e9f2f0497ad287fdf95623,0xbd3531da5cf5857e7cfaa92426877b022e612cf8,0x6be69b2a9b153737887cfcdca7781ed1511c7e36,0x80336ad7a747236ef41f47ed2c7641828a480baa,0x10d2d273cb8f6179f1ddd2ee5689cdce363b9a01,0x28cd2990f34db387d011d7cc693a2bcedd8dc654,0x67abaddb1258077f7900abd8ade0ecc6cdc38ac2,0xD3D9ddD0CF0A5F0BFB8f7fcEAe075DF687eAEBaB,0x9f4564b85cb77ce76cc725f29758cbfe20213aae,0x5d00d312e171be5342067c09bae883f9bcb2003b,0xfa69031b8f84ade91d1fac52148363842637699a,0x2a2ad5a2eacf35194d39afe1d727c39710ff0379,0x4fe99deb8f0be517c31faaad49b4b054ed28c267,0x3cd41ec039c1f2dd1f76144bb3722e7b503f50ab
```
