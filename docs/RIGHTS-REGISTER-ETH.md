# Creative-rights register: Ethereum launch collections (MarketplaceV3)

**Checked:** 2026-11-02 (every row; "date checked" below means this date unless a row says otherwise).
**Input:** the 31 contracts in `docs/LAUNCH-COLLECTIONS-ETH.md` as first issued (6c34b7c). Since then 76c495c moved POW Bull Badge to "Not allowed" (audit F-9, it blocks transfers). It is kept here so the register covers all 31.
**Baseline:** the nft-data licensing research of 2026-07-10 (`D:\NFT Data API\nft-data-api\migrations\2026-07-10_collection_licensing.sql`, then `2026-07-10_licensing_complete.sql`, which overrides it), and the live API `GET https://nft-data.pentagon.games/api/v1/collections?chain_id=1&active=all` read on 2026-11-02. The API exposes `license.type/name/url/notes` but not `license_confidence`, so the prior confidence below is taken from the migrations. Nothing in the nft-data repo or database was changed; corrections are listed in the [final section](#corrections-to-send-back-to-nft-data).

## Policy and how verdicts are set

nftprof: "like Coinbase, not a small exchange listing anything; no innovation zone". Launch ONLY with established blue chips where an identifiable entity grants holders creative or commercial rights. CC0 and the Viral Public License (VPL) count as rights granted.

- **LAUNCH**: established blue chip, and a primary-source licence (or CC0/VPL) that grants holder rights was loaded on 2026-11-02.
- **VERIFY**: a blue chip or near-blue chip whose terms could not be found, do not clearly cover this contract, or depend on a grantor that may no longer exist. It also covers one owner call on blue-chip status. Do not list until resolved.
- **EXCLUDE**: the current terms grant holders personal use only, or the collection is not an established blue chip (dormant, dead infrastructure, no rights-granting entity, or a utility/game token).

### Owner decisions (nftprof, 2026-11-02)

- **uwucrew and Killer GF: LAUNCH.** Both are Kusari (same team). Pentagon Games is a top holder in both and knows the founders, so it can help establish the floor. The rights were already clear (CC BY 4.0 for holders).
- **Remilio Babies: LAUNCH.** It is Milady's (Remilia's) second collection under the same VPL. Sub-collections of a launch collection are acceptable when their licence covers them.
- **Robotos:** not discussed; stays EXCLUDE.

Primary sources are the project's own licence or terms page, docs, or announcement. Secondary sources (press, wikis, OpenSea, Wayback copies of dead sites) are marked as such. "Unclear" always lists what was searched.

## ERC-721L tiers and what they unlock

Tiers follow the canonical ladder in *ERC-721L: Licensing-Aware NFTs* (`D:\Chrome DL\ERC721L_master_3_pass_refinement.pdf`, §1.2 and §3.1): 0 UNSET, 1 PERSONAL_USE, 2 COMMERCIAL_NO_DERIVS, 3 NONCOMMERCIAL_DERIVS, 4 COMMERCIAL_DERIVS_NONEXCLUSIVE, 5 COMMERCIAL_DERIVS_EXCLUSIVE, 6 COMMERCIAL_DERIVS_SHAREALIKE, 7 CC0. Revenue caps are not a tier: they appear as "capped" in the notes.

**The ladder is not monotonic at tier 3.** The PDF's action matrix (§3.4) allows commercial use without modification for tiers **2, 4, 5, 6, 7**, and derivatives for tiers **3–7** (commercial derivatives only for 4–7). Tier 3 permits derivatives but no commercial use, so "tier ≥ 2 unlocks merch" is wrong for tier 3. The feature gates used here:

| Feature | Unlocked at tiers | Code |
|---|---|---|
| Holder merch lines (commercial use) | 2, 4, 5, 6, 7 | **M** |
| Holder-commissioned derivative art minted as a soulbound token, not sold | 3–7. If Pentagon charges for the commission it is commercial: needs 4–7 | **S** |
| Resale of derivatives | 4–7. Tier 6 derivatives must carry the same licence | **R** |

Two cross-cutting findings for the soulbound-derivative feature:
- **Most commercial licences end when the holder sells the original NFT** (Meebits, Pudgy, Azuki, Moonbirds Illustrated, MoonCats, uwucrew/Killer GF character rights, CLONE X). A derivative soulbound token stays with the seller, so the feature needs a rule for what happens to it after the sale (burn, freeze, or display-only).
- **Doodles bans new NFTs outright, even for personal use.** The VPL collections forbid adding "further restrictions of ANY kind" to derivatives. Whether a soulbound wrapper counts as a restriction is a question for legal review.

"src" says whether the tier comes from the licence **text** or is **inferred**.

## Summary

Prior → current compares with nft-data 2026-07-10. **CHANGED** means the type, URL, coverage or confidence differs. **NEW** means nft-data had no licence for that contract.

| # | Collection | Entity granting rights | Licence (current) | Holder commercial | Derivs / resale | ERC-721L (src) | Unlocks | Medium | Artist / studio credit | Prior → current | Conf. | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Lil Pudgys | LSLTTT Holdings? (not confirmed) | unclear: Pudgy agreement names only "Pudgy Penguin NFT" | unclear (OverpassIP deals only) | unclear / unspecified | 0 (text) | none | unverified | not publicly credited | limited_commercial, verified → unknown. **CHANGED** | low | **VERIFY** |
| 2 | MoonCats (Acclimated) | MoonCatRescue LLC | commercial-to-holder (MoonCatLicense v1.0) | yes, no cap | yes, but MoonCatRescue owns them / allowed | 4 (text) | M S R | generative/algorithmic (pixel) | ponderware (studio) | custom, verified → same. unchanged | high | **LAUNCH** |
| 3 | Meebits | The Meebit Company (MeebCo) | commercial-to-holder | yes, "No Revenue Cap" | yes / allowed | 4 (text) | M S R | 3D (voxel) | Larva Labs (studio) | commercial, verified → same. unchanged | high | **LAUNCH** |
| 4 | Beanz | Chiru Labs (site now Azuki Labs, Inc.) | commercial-to-holder (Azuki licence, names Beanz) | yes, no cap (not Final 50 collab tokens) | yes / allowed, no Azuki marks | 4 (text) | M S R | generative/algorithmic (partly inferred) | not publicly credited | commercial, verified → same. unchanged | high | **LAUNCH** |
| 5 | CLONE X | RTFKT, Inc. (sold 17 Dec 2025 to undisclosed buyer) | personal by default; limited commercial after registration | only if registered (registration site down) | de-branded only / restricted | 1 base, 4 if registered (text, archived) | none today | 3D | RTFKT × Takashi Murakami | limited_commercial, verified → needs_legal. **CHANGED** | low | **VERIFY** |
| 6 | MAYC | Yuga Labs LLC | commercial-to-holder | yes, no cap | yes / allowed (merch named) | 4 (text) | M S R | generative/algorithmic | not publicly credited (Yuga Labs) | commercial, verified → same. unchanged | high | **LAUNCH** |
| 7 | Azuki Elementals | Chiru Labs (site now Azuki Labs, Inc.) | commercial-to-holder (by the licence's definition, not named) | yes, no cap | yes / allowed, no Azuki marks | 4 (inferred coverage) | M S R | generative/algorithmic (hand-drawn traits) | Azuki art team: Arnold Tsang, Njoo, Tenn, Tomugi, Crow (artist's account) | commercial, verified → likely. **CHANGED** (confidence) | medium | **LAUNCH** |
| 8 | ByWassies | unclear (Loomlock Ltd → announced trust) | unclear: "Wassie Vault" trust announced Feb 2022; 100 treasury Wassies CC0 | unclear (yes if trust exists) | unclear | 0 (7 for the CC0 set) | none | generative/algorithmic | tukinowagamo | custom, likely → same. unchanged | low | **VERIFY** |
| 9 | BAYC | Yuga Labs LLC | commercial-to-holder | yes, no cap | yes / allowed (merch named) | 4 (text) | M S R | generative/algorithmic (hand-drawn traits) | Seneca, lead artist by her own account (Yuga does not credit) | commercial, verified → same. unchanged | high | **LAUNCH** |
| 10 | World of Women | WoW Studio Limited (UK) | commercial-to-holder: exclusive copyright assignment (V3) | yes, no cap | yes, not single Attributes / allowed | 5 (text) | M S R | generative/algorithmic (hand-drawn traits) | Yam Karkai (artist's account) | commercial, verified → URL superseded by V3. **CHANGED** | medium | **LAUNCH** |
| 11 | Azuki | Chiru Labs (site now Azuki Labs, Inc.) | commercial-to-holder | yes, no cap | yes, new NFTs allowed / allowed, no Azuki marks | 4 (text) | M S R | generative/algorithmic (hand-drawn traits) | Arnold Tsang, co-creator (artist's account) | commercial, verified → same. unchanged | high | **LAUNCH** |
| 12 | Doodles | Doodles, LLC | personal-only | **no** | **no** (no new NFTs at all) / not | 1 (text) | none | generative/algorithmic (hand-drawn traits) | Burnt Toast (Scott Martin) | limited_commercial ~USD 100k, verified → personal. **CHANGED** | high | **EXCLUDE** |
| 13 | Moonbirds | Pixel art: CC0 (PROOF, 2022). Terms name Yuga Labs; Orange Cap Games says it owns the IP | **CC0** (pixel art) + holder licence (Illustrated art) | yes for anyone (pixel); holder, no cap (Illustrated) | yes / allowed | 7 pixel; 4 Illustrated (text) | M S R | generative/algorithmic (pixel traits) | Justin Mezzell (pixel); Illustrated not credited | commercial "do NOT label CC0" → CC0 still current. **CHANGED** | high (pixel CC0) | **LAUNCH** |
| 14 | Milady Maker | Remilia | VPL | yes (anyone), share-alike | yes, must stay VPL / allowed | 6 (text) | M S R(VPL) | generative/algorithmic (illustrated layers) | Yuyu, Sprite, Charlotte Fang (+ Ika, Worm) | copyleft, verified → same. unchanged | high | **LAUNCH** |
| 15 | Robotos | Pablo Stanley (individual) | commercial-to-holder | yes, no cap | yes / unspecified (sell right in Scope) | 4 (text) | M S R | generative/algorithmic (illustrated traits) | Pablo Stanley | commercial, verified → same. unchanged | high (text) | **EXCLUDE** |
| 16 | uwucrew | Kusari (uwu Labs) | commercial-to-holder: CC BY 4.0 for holders | yes, no cap, attribution | yes / allowed | 4 (text); 7 for "The Crew" | M S R | generative/algorithmic (hand-drawn traits) | Laur | commercial, verified → URL wrong. **CHANGED** | high | **LAUNCH** (owner decision) |
| 17 | BAKC | Yuga Labs (presumed) | unclear: no BAKC licence text; Yuga's link is 404 | unclear | unclear | 0 (4 if Yuga terms apply: inferred) | none | unverified | not publicly credited | commercial, likely → unknown. **CHANGED** | low | **VERIFY** |
| 18 | Pudgy Penguins | LSLTTT Holdings Inc. | commercial-to-holder, **capped** | capped: USD 500k gross / 12 months | not expressly granted / goods with the image allowed | 2 (text), capped | M | generative/algorithmic | Antoine Mingo (artist's account) | limited_commercial, verified → same. unchanged | high | **LAUNCH** |
| 19 | Killer GF | Kusari | commercial-to-holder (CC BY 4.0 model) | yes, no cap, attribution | yes / allowed | 4 (text); 7 for KGF Army (inferred IDs) | M S R | generative/algorithmic (hand-drawn traits) + 7 hand-made 1/1s | Zeronis | commercial, verified → same. unchanged | high | **LAUNCH** (owner decision) |
| 20 | Chimpers | unclear (Timpers LTD?) | unclear: terms URL 404 | unclear | unclear | 0 | none | generative/algorithmic (pixel traits) | Timpers | commercial, verified → unverifiable. **CHANGED** | low | **VERIFY** |
| 21 | Zombunnies | none found (ChainBoost / ChainGuardians) | none or unclear | no grant found | no grant found | 0 | none | generative/algorithmic | not publicly credited | unknown → same. unchanged (metadata wrong) | low | **EXCLUDE** |
| 22 | Hexagon City Estates | none found (CVERSE LTD → Pentagon Games) | none or unclear | no grant found | no grant found | 0 | none | unverified | not publicly credited | no row → none. **NEW** | medium | **EXCLUDE** |
| 23 | BCSH ETH (ours) | Pentagon Games | none published | no grant published | no grant published | 0 | none | unverified | not publicly credited | no row → none. **NEW** | high | **EXCLUDE** |
| 24 | POW Bull Badge | Pentagon Games | none (soulbound badge) | no grant | no grant | 0 | none | unverified | not publicly credited | no row → none. **NEW** | high | **EXCLUDE** |
| 25 | Remilio Babies | Remilia | VPL | yes (anyone), share-alike | yes, must stay VPL / allowed | 6 (text) | M S R(VPL) | unverified | Ula (illustration); Surfy, Ika, Charlotte Fang | no row → copyleft. **NEW** | high | **LAUNCH** (owner decision) |
| 26 | Chain Bunnies | none found (ChainBoost / ChainGuardians) | none or unclear | no grant found | no grant found | 0 | none | generative/algorithmic | not publicly credited | no row → unknown. **NEW** | low | **EXCLUDE** |
| 27 | Etheremon | none (project closed 2019) | none or unclear | no grant found | no grant found | 0 | none | unverified | not publicly credited | unknown → same. unchanged | low | **EXCLUDE** |
| 28 | CryptoMorph CG | none found (CryptoMorph, defunct) | none or unclear | no grant found | no grant found | 0 | none | unverified | CryptoMorph (partner project) | no row → unknown. **NEW** | low | **EXCLUDE** |
| 29 | Zorare | ChainGuardians (archived terms) | personal-only | no | no / not | 1 (inferred applicability) | none | unverified | not publicly credited for this series | no row → personal. **NEW** | medium | **EXCLUDE** |
| 30 | Chainguardians LE | ChainGuardians (archived terms) | personal-only | no | no / not | 1 (inferred applicability) | none | 2D hand-drawn | Noi Sackda, Lead Artist (project-level) | no row → personal. **NEW** | medium | **EXCLUDE** |
| 31 | Chainguardians | ChainGuardians (archived terms) | personal-only | no | no / not | 1 (inferred applicability) | none | 2D hand-drawn | Noi Sackda, Lead Artist (project-level) | no row → personal. **NEW** | medium | **EXCLUDE** |

**Totals:** LAUNCH 14, VERIFY 5, EXCLUDE 12 (after nftprof's decisions; the research verdicts were LAUNCH 11, VERIFY 6, EXCLUDE 14).

---

## Per-collection detail

Each section gives the fields asked for, then the citations. "Loaded" means the page was fetched on 2026-11-02 and read. Short quotes come from the primary source.

### 1. Lil Pudgys: VERIFY
`0x524cab2ec69124574082676e6f654a18df49a048`
- **Entity:** presumably LSLTTT Holdings Inc. / Igloo Inc. Not confirmed for this collection.
- **Licence:** unclear. The Pudgy Penguins IP Rights agreement speaks only of the "Pudgy Penguin NFT" and never mentions Lil Pudgys. A text search of the live page for "LIL" finds nothing.
- **Commercial / derivatives / resale:** unclear. Lil Pudgys are licensed case by case through OverpassIP deals, e.g. deal 50: "Open to all Lil Pudgy holders", 11 assets at USD 150 each, licence expiring 10 Feb 2026.
- **Restrictions:** unknown.
- **ERC-721L:** 0 (text: no grant found). It would be 2, capped, if Igloo confirms the Pudgy agreement applies.
- **Unlocks:** none.
- **Medium:** unverified. "Randomly generated" appears only in an OpenSea search snippet.
- **Artist:** not publicly credited. Do not assume Antoine Mingo.
- **Prior → current:** limited_commercial / "Pudgy Penguins IP Rights Agreement" / verified → unknown / needs_legal. **CHANGED**: the prior row applied the Pudgy agreement to Lil Pudgys, but its text does not cover them.
- **Searched:** claim.pudgypenguins.com/ip-rights (loaded); overpassip.com/terms (loaded, the Aug 2023 copy of the same agreement); pudgypenguins.com /terms, /license, /pages/license, /pages/nft-license, /pages/ip, /pages/ip-license, /pages/nft-terms (all 404); brand.pudgypenguins.com (password-protected); lilpudgys.com (domain for sale); web searches for a Lil Pudgys licence.
- **Confidence:** low. **Reason:** no licence text covers this contract; ask Igloo for the canonical terms.
- Sources: https://claim.pudgypenguins.com/ip-rights · https://www.overpassip.com/deal/50 · https://www.overpassip.com/deals · https://opensea.io/collection/lilpudgys/overview

### 2. MoonCats (Acclimated): LAUNCH
`0xc3f733ca98e0dad0386979eb96fb1722a1a05e69`
- **Entity:** MoonCatRescue LLC (Wyoming).
- **Licence:** commercial-to-holder, "MoonCatLicense Version 1.0, Last Revised: September 10th, 2021" (loaded). It names the Acclimator contract `0xc3f733ca…` as a place where licence changes are posted. It defines "MoonCat" by the original rescue contract `0x60cd862c…`, so acclimated cats are covered by inference: high confidence, but not stated in so many words.
- **Commercial use:** yes, no cap (§3.6: licence "for the purpose of commercialization").
- **Derivatives:** yes (§3.5). However, "MoonCat​Rescue LLC retains ownership of all such derivative works", which then become MoonCatArt that travels with the cat.
- **Resale of derivatives:** allowed as commercialisation of MoonCatArt (§3.6). The derivative's rights pass with the cat, not with a derivative token.
- **Restrictions:**
  - licence expires for the seller on transfer (§3.4);
  - no trademark or copyright registration (§3.7);
  - no hate content; no implied endorsement (§3.8);
  - third-party IP pass-through restrictions.
- **ERC-721L:** 4 (text: commercial plus derivatives, "non-exclusive").
- **Unlocks:** M S R. Caveat for S: the derivative belongs to MoonCatRescue LLC, and the holder's rights end on sale.
- **Medium:** generative/algorithmic (pixel art): "25,440 generative pixel art cats" (mooncat.community).
- **Artist:** ponderware (studio; "the development team"). No individuals named.
- **Prior → current:** custom / MoonCatLicense / verified → same, re-checked live. Unchanged.
- **Confidence:** high. **Reason:** a vintage (2017) blue chip with an identifiable LLC and a live holder commercial licence.
- Quote: "worldwide, non-exclusive, transferable, royalty-free license to use, copy, and display".
- Sources: https://mooncatrescue.com/license · https://mooncat.community/mooncatlicense · https://mooncat.community/legal · https://mooncat.community/

### 3. Meebits: LAUNCH
`0x7bd29408f11d2bfc23c34f18275bbf23bb716bc7`
- **Entity:** The Meebit Company ("MeebCo").
- **History:**
  - 2021: Larva Labs launched the collection.
  - March 2022: Yuga Labs acquired the IP.
  - August 2022: Yuga granted Meebits holders commercial rights under CryptoPunks-style terms.
  - February 2025: MeebCo acquired the IP. The buyer and date come from press reports only (The Block, Decrypt).
  - Correction to the brief: the Infinite Node Foundation bought only CryptoPunks.
- **Licence:** commercial-to-holder, "Meebits NFT License Terms", last updated 3 Dec 2025 (loaded). The 3 Dec 2025 Terms of Use say this licence exclusively governs art rights.
- **Commercial use:** yes. §3.2.1 is headed "No Revenue Cap": "Your commercial activities may generate unlimited revenue."
- **Derivatives:** yes; "Derivative Works belong to you", while MeebCo keeps the underlying IP.
- **Resale of derivatives:** allowed. §3.2 lists "selling merchandise or products featuring your Meebit".
- **Restrictions:**
  - no "Meebits"/"MeebCo" names or logos, beyond factual statements such as "based on my Meebit #1234" (§4.3);
  - no implied endorsement;
  - **on transfer, rights end immediately, including use of the art inside derivatives already made**;
  - rights arise "solely from onchain ownership" (staked or wrapped tokens are not addressed).
- **Conflict:** a May 2025 MeebCo PDF, still live at licenseterms.meebits.app, calls the licence "exclusive" and allows selling off existing stock after a sale. Neither document says which prevails; the December text is newer and is the one the Terms of Use reference.
- **ERC-721L:** 4 (text, December 2025 version). It would be 5 under the May 2025 PDF's "exclusive" wording.
- **Unlocks:** M S R. Rights end on sale.
- **Medium:** 3D (voxel "digital sculptures" from Larva Labs' generator; the generator description is a search snippet only).
- **Artist:** Larva Labs (studio), per meebits.com.
- **Prior → current:** commercial / MeebCo / verified → same. Unchanged; adds the conflicting May 2025 document.
- **Confidence:** high on the grant, medium on which document controls. **Reason:** blue chip, identifiable licensor, uncapped commercial rights.
- Sources: https://meebits.com/legal/license · https://meebits.com/legal/terms · https://licenseterms.meebits.app · https://meebits.com/

### 4. Beanz: LAUNCH
`0x306b1ea3ecdf94ab739f1910bbda052ed4a9f949`
- **Entity:** Chiru Labs, Inc. (the licence's licensor). The azuki.com Terms & Conditions, updated 15 March 2026, and the site footer now name Azuki Labs, Inc.
- **Licence:** commercial-to-holder, the Azuki NFT License Agreement, "LAST REVISED ON 5/5/22" (loaded 2026-11-02). It names Beanz explicitly through the "Final 50 Beanz" (token IDs 19950–19999, "reserved … for future collabs").
- **Commercial use:** yes, no cap. "Commercial Use" includes "creating and selling merchandise".
- **Derivatives:** yes, including minting new NFTs "based on your Azuki NFT Art", without Azuki Trademarks.
- **Resale of derivatives:** allowed: "Yes, you can even sell the derivatives, just as long as you don't use the Azuki Trademarks."
- **Restrictions:**
  - no Azuki Trademarks (including "Bobu" and character names), no domains or handles using them;
  - collab tokens containing third-party content (possibly the Final 50) are excluded from commercial use;
  - the licence ends when you sell the NFT and passes to the buyer;
  - covenant not to sue; Chiru Labs may amend the terms.
- **ERC-721L:** 4 (text).
- **Unlocks:** M S R (not for collab tokens with third-party content).
- **Medium:** generative/algorithmic. Partly inferred: OpenSea says "distinct traits"; "hand-drawn" appears only in an nft now snippet (403).
- **Artist:** not publicly credited (Chiru Labs studio).
- **Prior → current:** commercial / verified → same. Unchanged.
- **Confidence:** high. **Reason:** an Azuki-family blue chip named in the live licence.
- Sources: https://www.azuki.com/en/license · https://www.azuki.com/terms-conditions · https://opensea.io/collection/beanzofficial/overview

### 5. CLONE X: VERIFY
`0x49cf6f5d44e70224e2e23fdcdd2c053f30ada28b`
- **Entity:** RTFKT, Inc.
  - Nike bought RTFKT in 2021 and announced the wind-down in December 2024.
  - A Nike spokesperson says "RTFKT transitioned to a new owner on December 17" (2025), as quoted by Bloomberg Law (paywalled excerpt). The buyer is undisclosed.
  - No statement from the new owner, no CC0 release and no licence transfer was found.
- **Licence:** two documents, both read only from Wayback copies, because rtfkt.com and /legal-2C returned HTTP 503 on 2026-11-02:
  - "End User License Agreement (Clone X 3D Models)" (legal-2E): personal, non-commercial.
  - "Digital Collectible Limited Commercial Use License Terms" (legal-2C): commercial use only after registering an account on RTFKT's site, as an individual or an entity with fewer than 1,500 employees and under USD 40M in revenue.
- **Commercial use:** only if registered. No revenue cap. Registration is currently impossible because the site is down.
- **Derivatives:** "De-Branded Modified" versions only. No altering the "RTFKT Traits" (they may be removed entirely).
- **Resale of derivatives:** permitted in products and media. A derivative NFT is allowed only if substantially altered, licensed to its buyer for personal use only, and labelled "Modified Clone [#]".
- **Restrictions:**
  - no RTFKT branding;
  - no footwear, firearms, tobacco or drugs, and no use with RTFKT competitors;
  - the licence is revocable and ends when you sell;
  - Murakami-trait exclusions are reported only by secondary sources and were not seen in the text.
- **ERC-721L:** base 1 / upgraded 4 (text, archived): a base-plus-upgrade model in ERC-721L §2.2 terms. The effective tier today is 1, since the upgrade cannot be obtained.
- **Unlocks:** none today.
- **Medium:** 3D (Sotheby's lot page: "3D visual style").
- **Artist:** RTFKT × Takashi Murakami (OpenSea collection description: "in collaboration with Takashi Murakami"). Which traits Murakami drew is secondary only, and sources conflict.
- **Prior → current:** limited_commercial / legal-2C / verified → needs_legal. **CHANGED**: URL dead, owner changed, upgrade path unavailable.
- **Confidence:** medium on the archived text, low on anyone standing behind it now. **Reason:** blue chip, but the grantor is unknown and the commercial licence cannot be obtained.
- Sources: https://web.archive.org/web/20260710083607/https://rtfkt.com/legal-2C (text from https://web.archive.org/web/20260710083607js_/https://rtfkt.com/assets/legal-2c-1860fd46.js) · https://web.archive.org/web/20250913084041/https://rtfkt.com/legal-2E · https://news.bloomberglaw.com/mergers-and-acquisitions/nike-sells-nft-subsidiary-rtfkt-one-year-after-shuttering-unit (secondary) · https://opensea.io/collection/clonex/overview · https://www.sothebys.com/en/buy/auction/2022/natively-digital-relics/clonex-8871

### 6. MAYC: LAUNCH
`0x60e4d786628fea6478f785a6d7e704777c86a7c6`
- **Entity:** Yuga Labs LLC (licence page). Yuga's site Terms of Use say Yuga Labs, Inc.
- **Licence:** commercial-to-holder, MAYC licence (loaded, undated).
- **Commercial use:** yes, uncapped. Same grant wording as BAYC.
- **Derivatives:** yes, "for the purpose of creating derivative works based upon the Art".
- **Resale of derivatives:** allowed: "the use of the Art to produce and sell merchandise products (T-Shirts etc.)".
- **Restrictions:**
  - §1D: no rights to the names or logos "Bored Ape Yacht Club, BAYC, Bored Ape Kennel Club, BAKC, Mutant Ape Yacht Club, MAYC";
  - prohibited uses in §2;
  - Yuga may change the terms (§8);
  - the page does not say whether rights end on sale.
- **ERC-721L:** 4 (text; exclusivity not stated, Yuga keeps the IP).
- **Unlocks:** M S R, with no Yuga marks.
- **Medium:** generative/algorithmic ("born through a special 'mutation' process" of existing apes; OpenSea, method not stated).
- **Artist:** not publicly credited (Yuga Labs).
- **Prior → current:** commercial / verified → same. Unchanged.
- **Confidence:** high. **Reason:** blue chip, live licence.
- Sources: https://boredapeyachtclub.com/mayc-license · https://yuga.com/terms · https://opensea.io/collection/mutant-ape-yacht-club/overview

### 7. Azuki Elementals: LAUNCH
`0xb6a37b5d14d502c3ab0ae6f3a0e058bc9517786e`
- **Entity:** Chiru Labs (now Azuki Labs, Inc. on the site).
- **Licence:** commercial-to-holder under the Azuki NFT License Agreement. It defines "Azuki NFT" as "any Azuki branded or themed NFT created by or on behalf of Chiru Labs", and Elementals were minted by Chiru Labs in June 2023. The licence does not name Elementals ("Elemental" not found in the text).
- **Commercial use, derivatives, resale, restrictions:** as for Azuki.
- **ERC-721L:** 4 (inferred coverage).
- **Unlocks:** M S R.
- **Medium:** generative/algorithmic (hand-drawn traits combined by code): "randomized attributes of varying rarity" (Decrypt).
- **Artist:** "the product of the entire Azuki art team": Arnold Tsang (art director), Njoo, Tenn, Tomugi, Crow. This is Tsang's own account in a community Substack interview; the names are handles only.
- **Prior → current:** commercial / verified → likely. **CHANGED** (confidence only): coverage rests on the definition.
- **Searched:** azuki.com /elementals/license, /license/elementals, /elementals-license (404); /elementals (no licence text).
- **Confidence:** medium. **Reason:** an Azuki-family blue chip that falls within the licence's own definition. Ask Azuki Labs for a one-line confirmation.
- Sources: https://www.azuki.com/en/license · https://decrypt.co/146153/azuki-expands-new-20k-ethereum-nft-collection-elementals (secondary) · https://thebeangazette.substack.com/p/sitdown-with-co-creator-of-azuki (artist's account)

### 8. ByWassies: VERIFY
`0x1d20a51f088492a0f1c57f047a9e30c9ab5c07ea`
- **Entity:** unclear.
  - The IP was held by Loomlock Ltd.
  - On 19 Feb 2022 the project announced its "intention to revoke all licenses Loomlock Ltd has granted" and to move each Wassie's IP into a trust, with an independent, regulated trustee, that "recognize[s] the holder of each NFT as the owner".
  - The post was a pre-release announcement. No trustee, trust deed, or confirmation that it happened was found.
- **Licence:** unclear. If the Vault exists, holders own the art outright: "create artwork, sell merchandise and enter into collabs". About 100 treasury Wassies are offered as CC0 on bywassies.com/cco.
- **Commercial / derivatives / resale:** unclear (yes if the trust is live).
- **Restrictions:** unknown.
- **ERC-721L:** 0 (5 if the trust is confirmed; 7 for the CC0 treasury set).
- **Unlocks:** none until confirmed.
- **Medium:** generative/algorithmic: "12345 generative NFTs … based on artwork from tukinowagamo" (archived bywassies.com/about). Supply figures conflict.
- **Artist:** tukinowagamo ("the original Wassie artist"), per the archived project page and the Medium post ("tukino").
- **Prior → current:** custom / "Wassie Vault ownership trust" / likely → same. Unchanged; adds the Medium URL.
- **Searched:** bywassies.com and /cco (loaded; no licence text, "© BY WASSIES 2023"); the Medium announcement (loaded); searches for "Wassie Vault" trust, trustee and terms (only the announcement).
- **Confidence:** low. **Reason:** rights depend on a trust that was announced, not evidenced.
- Sources: https://medium.com/@bywassies/the-wassie-vault-3793d8c9e53d · https://bywassies.com/ · https://www.bywassies.com/cco · https://web.archive.org/web/20230204000531/https://www.bywassies.com/about (medium, artist)

### 9. BAYC: LAUNCH
`0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d`
- **Entity:** Yuga Labs LLC.
- **Licence:** commercial-to-holder, BAYC licence (loaded, undated). The old /terms URL is 404.
- **Commercial use:** yes, uncapped: "grants you an unlimited, worldwide license to use, copy, and display the purchased Art".
- **Derivatives:** yes ("for the purpose of creating derivative works").
- **Resale of derivatives:** allowed; merchandise is named.
- **Restrictions:**
  - the Made By Apes FAQ says Yuga keeps the IP and the BAYC skull and logo are not licensed;
  - the page does not say whether rights end on sale (it refers to "continued compliance with these Terms");
  - a separate BAYC 3D Avatar License covers Yuga-made 2D/3D avatar files. It is exclusive and sublicensable, ends on transfer, and reserves trademarks. It does not clearly cover the original 2D ape.
- **ERC-721L:** 4 (text).
- **Unlocks:** M S R, without BAYC marks.
- **Medium:** generative/algorithmic (hand-drawn traits combined by code): "procedurally generated" (Wikipedia, secondary).
- **Artist:** Yuga's pages name no artist.
  - Seneca says she was the lead artist ("Not a ton of people know that I did these drawings", Vice; "character design collaboration", OpenSea blog), and that she did not draw every trait.
  - Other contributors were reportedly named by a Yuga co-founder in Rolling Stone (paywalled, not loaded), so they are not credited here.
- **Prior → current:** commercial / verified → same. Unchanged.
- **Confidence:** high. **Reason:** the reference blue chip, with a live licence.
- Sources: https://boredapeyachtclub.com/bayc-license · https://madeby.boredapeyachtclub.com/faq · https://yuga.com/3d-avatar-terms · https://opensea.io/blog/articles/in-conversation-with-all-seeing-seneca · https://vice.com/en/article/y3vn5b/bored-ape-yacht-club-artist-says-compensation-definitely-not-ideal · https://en.wikipedia.org/wiki/Bored_Ape (secondary)

### 10. World of Women: LAUNCH
`0xe785e82358879f061bc3dcac6f0444462d4b5330`
- **Entity:** WoW Studio Limited (UK, company 13821148).
- **Licence:** commercial-to-holder, in the form of an **exclusive copyright assignment**: "World of Women terms of assignment, Updated on 22 March 2024, V3" (PDF on WoW's own IPFS gateway, loaded and text-extracted).
  - It assigns "on an exclusive basis … all exploitation, reproduction, representation and adaptation rights … for all modes of exploitation, including commercial ones".
  - The rights pass to the next buyer on resale.
- **Commercial use:** yes, no cap.
- **Derivatives:** yes ("integrate all or part of the Art into another work and create derivative work thereof"), but not by using individual **Attributes** (background, clothes, eyes …) apart from the Art as a whole. This restriction is new in V3.
- **Resale of derivatives:** allowed. Holders are asked to resell on royalty-paying marketplaces.
- **Restrictions:**
  - no WoW trademarks or references to WoW without written approval (§7);
  - moral rights (attribution, integrity) stay with the creator;
  - French law.
- **Live site:** worldofwomen.art/terms and /license return 404 today; the V3 PDF was linked from the 25 May 2024 capture of /terms.
- **ERC-721L:** 5 (text: an exclusive assignment).
- **Unlocks:** M S R.
- **Medium:** generative/algorithmic (hand-drawn traits combined by code): about 180 assets she drew, broken into traits (The Defiant interview). Asset counts conflict across sources.
- **Artist:** Yam Karkai, co-founder (artist's own interview). The worldofwomen.art pages loaded today do not name her.
- **Prior → current:** commercial / CID `QmYccLQN…` (the January 2022 "digital ownership assignment") / verified → V3 CID `QmPrxnFq…`. **CHANGED**: the URL is superseded, and V3 adds the Attribute restriction.
- **Confidence:** medium. **Reason:** blue chip with an irrevocable assignment, but the live site no longer links its terms; ask WoW to restore the link.
- Sources: https://worldofwomen.mypinata.cloud/ipfs/QmPrxnFqMJDox5tpd2KhH28gtzu7xPyeFNDwpnm5RKvwv6 (V3) · https://worldofwomen.mypinata.cloud/ipfs/QmYccLQNUyDD4p7tqdQ9iCcJgiejxUKqWt2FypkVygorLu (Jan 2022 version) · https://web.archive.org/web/20240525075832id_/https://www.worldofwomen.art/terms · https://thedefiant.io/-nfts-gave-me-a-sense-of-security

### 11. Azuki: LAUNCH
`0xed5af388653567af2f388e6224dc7c4b3241c544`
- **Entity:** Chiru Labs, Inc. "and/or its affiliates". The site is operated by Azuki Labs, Inc. (T&C updated 15 March 2026); the licence itself was not updated.
- **Licence:** commercial-to-holder, "AZUKI NFT LICENSE AGREEMENT, LAST REVISED ON 5/5/22" (loaded 2026-11-02 at /en/license).
- **Commercial use:** yes. **No revenue cap**: none in the text, and no "100,000" anywhere.
- **Derivatives:** non-commercial derivatives are allowed freely. Commercially, the legal text allows only adapting the art "in or on the goods or media", but it expressly permits holders to "mint and create new NFTs and NFT projects based on your Azuki NFT Art" without Azuki Trademarks.
- **Resale of derivatives:** allowed (plain-English gloss: "you can even sell the derivatives"). The gloss reads broader than the legal text, so note it.
- **Restrictions:**
  - no Azuki Trademarks, which must be removed or obscured in commercial use;
  - no domains or handles using them;
  - collab tokens with third-party content are excluded;
  - the licence ends when you sell the NFT;
  - covenant not to sue; it terminates on breach; Chiru Labs may amend it;
  - the 2026 T&C reserve Azuki Labs' TCG and product art: consent is needed to exploit that.
- **ERC-721L:** 4 (text).
- **Unlocks:** M S R.
- **Medium:** generative/algorithmic (hand-drawn traits combined by code): "10,000 hand-drawn NFTs" (project text on OpenSea).
- **Artist:** Arnold Tsang ("Steamboy"), co-creator and art director. Self-described in a community Substack interview; OpenSea's team list shows "Steamboy (Art Director)".
- **Prior → current:** commercial / verified → same. Unchanged.
- **Confidence:** high. **Reason:** blue chip, live uncapped licence.
- Sources: https://www.azuki.com/en/license · https://www.azuki.com/terms-conditions · https://opensea.io/collection/azuki/overview · https://thebeangazette.substack.com/p/sitdown-with-co-creator-of-azuki

### 12. Doodles: EXCLUDE
`0x8a90cab2b38dba80c64b7734e58ee1db38b8992e`
- **Entity:** Doodles, LLC (Florida law).
- **Licence:** **personal-only.**
  - The Terms of Service ("Last Revised: August 16, 2023", loaded at doodles.app/legal/terms) define "Doodles' Original Collection" by contract `0x8a90CAb2…`.
  - They make the "Digital Collectibles Media License Agreement" the default licence for every Doodles collectible "unless overridden by any Additional Terms".
  - The Additional Terms page lists only the Crocs and Rubik's licences and a giveaway, nothing for the original collection.
  - The Media License ("LAST REVISED: August 15, 2023", loaded at stoodio.doodles.app) grants use "for personal, non-commercial uses" and "does not include the right to commercialize, create derivative works from, or modify the Collectibles Media".
- **Commercial use:** no. **No USD 100k cap exists in the current text**: "100,000" does not appear on the Terms page, and the licence grants no commercial use at all.
- **Derivatives:** no. "You may not use the Collectibles Media … in connection with the creation of a new NFT (for clarity, even if such new NFT is solely for personal, non-commercial use)."
- **Resale of derivatives:** not allowed.
- **Restrictions:**
  - no trademarks (Doodles, Stoodio, Golden Wolf);
  - content rules apply "in Doodles' sole discretion";
  - fractionalised NFTs get no rights;
  - the licence passes on transfer.
- **History:** secondary sources (Blockworks, the MEXC blog) describe the 2021 terms as allowing holder merchandise up to USD 100,000. That is the likely origin of the prior row. No announcement of the downgrade was found. Whether the 2023 terms bind 2021 buyers is a legal question; the licence says it supersedes earlier agreements.
- **ERC-721L:** 1 (text).
- **Unlocks:** none. The soulbound-derivative feature is expressly barred (no new NFTs).
- **Medium:** generative/algorithmic (hand-drawn traits combined by code): "algorithmically generated characters" (OpenSea).
- **Artist:** Burnt Toast (Scott Martin), co-founder and artist: OpenSea collection page (possibly OpenSea-written) and the artist's own Fortune interview. Do not cite burnttoastcreative.com; it now redirects elsewhere.
- **Prior → current:** limited_commercial / "Doodles Holder License" / "capped (~USD 100k) … no derivatives" / verified → personal. **CHANGED.**
- **Confidence:** high. **Reason:** the current primary terms grant personal use only, which fails the policy.
- Sources: https://www.doodles.app/legal/terms · https://stoodio.doodles.app/digital-collectibles-media-license-agreement · https://stoodio.doodles.app/additional-terms · https://opensea.io/collection/doodles-official/overview · https://fortune.com/2022/01/29/artist-burnt-toast-created-nft-art-collection-166-million-sales

### 13. Moonbirds: LAUNCH
`0x23581767a106ae21c074b2276d25e5c3e136a68b`
- **Entity:** the art terms at proof.xyz/terms/moonbirds ("Last updated: June 11, 2024", loaded 2026-11-02) are from **Yuga Labs, Inc.** Orange Cap Games' site says it "owns the Moonbirds, Mythics, & oddities IP". moonbirds.com/terms (Birb Holdings, 28 Jan 2026) cover the website only. **No new art licence and no reversal of CC0 was found.**
- **Licence:**
  - **CC0 still applies to the Pixel Moonbirds art**, which the tokens show by default: the copyrights "have been waived via Creative Commons Zero (CC0) designation". CC0 cannot be withdrawn for works already released.
  - The optional **Illustrated** art (June 2024) is under a holder licence: "commercial and non-commercial uses", universe-wide, royalty-free, sublicensable, no cap, covering the whole composite (not single traits).
- **Commercial use:** yes for anyone (pixel). Holder only, no cap (Illustrated).
- **Derivatives:** yes.
- **Resale of derivatives:** allowed. For Illustrated art, after a sale you may sell off existing stock, but new merchandise "would require a license from the new Holder".
- **Restrictions:**
  - all trademarks, including "Moonbirds", are "expressly reserved to Yuga Labs";
  - the Illustrated licence ends on transfer;
  - no hate or unlawful uses.
- **ERC-721L:** 7 for pixel art (text); 4 for Illustrated (text).
- **Unlocks:** M S R. Use the pixel art for the CC0 path, and no Moonbirds marks.
- **Medium:** generative/algorithmic (pixel traits, rendered on-chain): "fully on-chain" (proof.xyz). Illustrated: unverified.
- **Artist:** Justin Mezzell ("Moonbirds artist, Justin Mezzell", proof.xyz project page). Not Gremplin, who is credited (secondary) for the separate Oddities collection. The Illustrated art is not publicly credited.
- **Prior → current:** commercial / "Formerly CC0 … relicensed — do NOT label CC0" / verified → **CC0 (pixel) + holder licence (Illustrated)**. **CHANGED**: the prior note is contradicted by the live terms.
- **Confidence:** high for the pixel CC0, medium on who is the current grantor. **Reason:** blue chip, CC0 counts under the policy.
- Sources: https://www.proof.xyz/terms/moonbirds · https://www.proof.xyz/moonbirds · https://moonbirds.com/terms · https://www.orangecapgames.com

### 14. Milady Maker: LAUNCH
`0x5af0d9827e0c53e4799bb226655a1de152a425a5`
- **Entity:** Remilia.
- **Licence:** VPL. "All Milady Maker branding, assets and NFT's are copylefted under the Viral Public License" (miladymaker.net, loaded).
- **Commercial use:** yes, for anyone (holders get nothing extra).
- **Derivatives:** yes. Every derivative must "retain the ENTIRETY of this license", and "No further restrictions of ANY kind may be applied".
- **Resale of derivatives:** allowed ("use of any kind"), under the VPL.
- **Restrictions:**
  - share-alike, which conflicts with any proprietary terms on derivative tokens;
  - attribution is waived;
  - trademarks are not mentioned, and the branding itself is copylefted;
  - the site credits the base character as a remix of "Hororo" from *Bottle Fairy* (2003), so third-party character IP is a residual risk.
- **ERC-721L:** 6 (text).
- **Unlocks:** M S R. Derivatives must carry the VPL; check whether a soulbound wrapper is a "further restriction".
- **Medium:** generative/algorithmic: "10,000 generative pfpNFT's", "designed as separate asset layers" (project page).
- **Artist:** asset illustration and rendering by Yuyu, Sprite (@milady_sonora) and Charlotte Fang; conception and direction by Charlotte Fang; image composing by Ika; overlay graphics by Worm (miladymaker.net credits, which say they are "not an assignment of rights"). OpenSea's "Emma-Claire" credit conflicts with this; do not use it.
- **Prior → current:** copyleft / VPL / verified → same. Unchanged.
- **Confidence:** high. **Reason:** an established blue chip under VPL.
- Sources: https://miladymaker.net/ · https://viralpubliclicense.org

### 15. Robotos: EXCLUDE
`0x099689220846644f87d1137665cded7bf3422747`
- **Entity:** Pablo Stanley personally ("Acknowledged and agreed upon by Pablo Stanley, August 2021").
- **Licence:** commercial-to-holder, "Robotos NFT LICENSING AGREEMENT". The page is JavaScript-rendered; the text was read from its bundle. **It is not CC0.** Stanley's CC0 work is in other projects.
- **Commercial use:** yes, no cap: "a non-exclusive license to use the Permissible Work in the course of personal and commercial use".
- **Derivatives:** yes.
- **Resale of derivatives:** unspecified. The Scope clause grants "the non-exclusive right to reproduce, sell and distribute the Permissible Work".
- **Restrictions:**
  - the licence passes to a new purchaser;
  - no trademark, cap or termination clauses;
  - amateur drafting.
- **ERC-721L:** 4 (text).
- **Unlocks:** M S R.
- **Medium:** generative/algorithmic: "algorithmically generated by combining 170+ unique traits" (archived robotos.art).
- **Artist:** Pablo Stanley: "created Robotos, including all the art and story" (archived project page). Zackboto built the generator.
- **Prior → current:** commercial / verified → same. Unchanged.
- **Confidence:** high on the text. **Reason:** not an established blue chip. The project's X account logged off on 2024-02-14 ("it was a good run!"), and a secondary source reports accusations of a rug pull.
- Sources: https://www.robotos.art/license · https://web.archive.org/web/20221226044959/https://www.robotos.art/ (medium, artist) · https://www.web3isgoinggreat.com/single/creator-of-robotos-nft-project-once-collaborating-on-a-tv-series-with-time-studios-accused-of-rug-pull (secondary)

### 16. uwucrew: LAUNCH (owner decision; research verdict EXCLUDE)
`0xf75140376d246d8b1e5b8a48e3f00772468b3c0c`
- **Entity:** Kusari ("uwucrew is part of the kusari family"; uwu Labs).
- **Licence:** "The uwu Art License" (Mirror post, 3 May 2022). Holders get CC BY 4.0, non-holders CC BY-NC 4.0, and 25 team-picked "The Crew" tokens are CC0 (IDs not listed in the captured text). uwucrew.art (loaded) links it: "uwucrew uses the uwu art license".
- **Commercial use:** yes, uncapped, with attribution: "Make derivatives, remix, or transform in any medium, even commercially".
- **Derivatives:** yes.
- **Resale of derivatives:** allowed for holders. Non-holders need the current owner's permission.
- **Restrictions:**
  - attribution required;
  - the team keeps promotional rights over all art and derivatives;
  - permission for third parties to commercialise a holder's character lasts only while that holder owns the NFT.
- **ERC-721L:** 4 (text; CC BY is not share-alike); 7 for The Crew.
- **Unlocks:** M S R.
- **Medium:** generative/algorithmic (hand-drawn traits combined by code): "over 30 layers of hand-drawn art" (archived uwucrew.art).
- **Artist:** Laur, "the sole artist of uwucrew". The live uwucrew.art lists "Laur — Artist"; Kiwi is the developer.
- **Prior → current:** commercial / uwucrew.art/license / verified → licence is the Mirror post. **CHANGED** (URL): /license serves the home page.
- **Confidence:** high. **Reason:** clear rights and active, but mid-tier, not an established blue chip. Revisit after launch.
- Sources: https://mirror.xyz/uwucrew.eth/DwrrmMYgsUT0mXsMEvbWBoLtnKcW0TRKOpwUWjDbZXg · https://uwucrew.art · https://web.archive.org/web/20230117213857/https://uwucrew.art/ (medium, artist)

### 17. BAKC: VERIFY
`0xba30e5f9bb24caa003e9f2f0497ad287fdf95623`
- **Entity:** presumably Yuga Labs.
- **Licence:** unclear. No BAKC licence text was found.
  - The Made By Apes FAQ links "BAKC license terms" to boredapeyachtclub.com/licenses/bakc, which is **404**. /bakc-license and /kennel-club-license are also 404.
  - The BAYC licence never mentions BAKC. The MAYC licence only reserves BAKC trademarks.
  - The MBA licence counts BAKC art as "Club Artwork" but says holders must separately "obtain the rights".
  - The only "same as BAYC" claim found is secondary (Kraken Learn).
- **Commercial / derivatives / resale:** unclear.
- **Restrictions:** Yuga trademarks reserved.
- **ERC-721L:** 0 (4 if Yuga confirms the BAYC/MAYC terms apply; inferred).
- **Unlocks:** none until confirmed.
- **Medium:** unverified (only a secondary snippet that reads like it was copied from BAYC).
- **Artist:** not publicly credited.
- **Prior → current:** commercial / "Yuga holder-IP policy" / likely → unknown. **CHANGED.**
- **Confidence:** low. **Reason:** a Yuga blue chip, but its own licence link is dead; ask Yuga.
- Sources: https://madeby.boredapeyachtclub.com/faq · https://boredapeyachtclub.com/mba-license · https://boredapeyachtclub.com/licenses/bakc (404)

### 18. Pudgy Penguins: LAUNCH
`0xbd3531da5cf5857e7cfaa92426877b022e612cf8`
- **Entity:** LSLTTT Holdings Inc. (Lewes, Delaware), the "Creator". Secondary sources put it under Igloo Inc., which also runs OverpassIP.
- **Licence:** commercial-to-holder, **capped**: "IP RIGHTS, Last Updated: December, 2022" (claim.pudgypenguins.com/ip-rights, loaded 2026-11-02; an identical Aug 2023 copy is on overpassip.com/terms).
- **Commercial use:** capped. Holders may commercialise their own goods and services, "including the right to produce and sell goods", unless it results in "more than five hundred thousand dollars ($500,000) … in gross revenue in any twelve month period", counting related entities and family. Third-party products are under the same cap per sublicensee per project, but promotion of any third-party good or service must be "expressly approved by the Creator". Holders must contact Pudgy within 15 days of expecting to exceed the cap, and the Creator has audit rights.
- **Derivatives:** **not expressly granted.** The grant is to "copy, access, use and otherwise exploit" the art and to sell goods "that includes, contains, or consists of the graphical image". Modification is only restricted on content grounds, and the agreement mentions "modified" and "derivative" Pudgy Penguins.
- **Resale of derivatives:** goods showing the image may be sold (within the cap). Derivative works as such are unspecified.
- **Restrictions:**
  - no "Pudgy Penguin(s)" name, logos, character names or Creator content;
  - no combining with penguins you don't own;
  - no IP registration;
  - **the licence ends when you sell, and rights in "any derivative Pudgy Penguins" end too.**
- **ERC-721L:** 2 (text), "commercial, capped". It would be 4 if Igloo confirms that modification is allowed (inferred).
- **Unlocks:** M (within USD 500k / 12 months). S and R need confirmation.
- **Medium:** generative/algorithmic: "computer-generated images" (OpenSea, creator TheIglooCompany).
- **Artist:** Antoine Mingo, by his own account (Decrypt): the original artist, hired via Upwork in 2021, who left in early 2023. The project itself does not credit him.
- **Prior → current:** limited_commercial / verified → same. Unchanged. The earlier `custom` / pudgypenguins.com/terms row (now 404) had already been replaced on 2026-07-10.
- **Confidence:** high. **Reason:** blue chip with a live capped commercial licence. Note the cap for merch lines.
- Sources: https://claim.pudgypenguins.com/ip-rights · https://www.overpassip.com/terms · https://opensea.io/collection/pudgypenguins/overview · https://decrypt.co/307098/pudgy-penguins-artist-new-berachain-nft-collection (artist's account)

### 19. Killer GF: LAUNCH (owner decision; research verdict EXCLUDE)
`0x6be69b2a9b153737887cfcdca7781ed1511c7e36`
- **Entity:** Kusari. Same `owner()` as uwucrew: `0x59A722b3…5Cf66`.
- **Licence:** "Killer GF Art License", "Based on the uwu Art License" (text read from the site's JS bundle). Commercial for holders, personal only for non-holders ("commercial use is strictly prohibited for non-holders"). A CC0 "KGF Army" mascot subset, apparently token IDs 3–6 (inferred from site code).
- **Commercial use:** yes, uncapped, with credit: "free to copy, share, and remix even for commercial projects".
- **Derivatives:** yes.
- **Resale of derivatives:** allowed for holders. "Permission for commercial derivatives persists only as long as you own the NFT."
- **Restrictions:** credit required; third-party permissions end on sale.
- **ERC-721L:** 4 (text); 7 for the KGF Army (inferred IDs).
- **Unlocks:** M S R.
- **Medium:** generative/algorithmic: "uniquely generated from over 240 hand-drawn traits … 7 hand-crafted 1/1 pieces" (killergf.com).
- **Artist:** Zeronis ("former Riot Games artist"), per killergf.com.
- **Prior → current:** commercial / verified → same. Unchanged.
- **Confidence:** high. **Reason:** clear rights and active, but mid-tier, not an established blue chip.
- Sources: https://killergf.com/license (text in https://killergf.com/static/js/9.95a5a550.chunk.js) · https://killergf.com/ (medium/artist text in https://killergf.com/static/js/main.a7e8b606.chunk.js) · https://mirror.xyz/uwucrew.eth/DwrrmMYgsUT0mXsMEvbWBoLtnKcW0TRKOpwUWjDbZXg

### 20. Chimpers: VERIFY
`0x80336ad7a747236ef41f47ed2c7641828a480baa`
- **Entity:** unclear. Timpers LTD publishes terms for the separate Base card game only.
- **Licence:** unclear.
  - chimpers.com/terms, the prior URL, loads the shop's "404 Page Not Found" (checked in a browser 2026-11-02). chimpers.xyz fails TLS.
  - The GitBook terms (Timpers LTD, Aug 2024) are personal and non-commercial, but cover the Base collectible cards only.
  - The only description of the PFP licence is a third-party Fat Cats DAO report (Dec 2022): an uncapped commercial licence while you hold. It links a Google Drive "Chimpers terms" that needs a login.
- **Commercial / derivatives / resale:** unclear.
- **Restrictions:** the prior row's notes (no layer extraction or new collections) could not be re-verified.
- **Also check:** the contract may be legacy.
  - The Bored Ape Gazette reports a migration to a royalty-enforcing contract.
  - Per a research agent, the OpenSea description of this contract (read through Alchemy's API mirror) calls it "Chimpers [Legacy]" and points to migrate.chimpers.com. Not verified first-hand.
  - Sampled tokens return one placeholder image.
- **ERC-721L:** 0.
- **Unlocks:** none.
- **Medium:** generative/algorithmic: "Generative mint of the 5,555 Timpers pixels" (world.chimpers.com, loaded). In March 2026 all 5,555 received a "fully redrawn Kawaii artwork" with an AI-generated backstory (text, not art, per the project). The redraw artist is uncredited.
- **Artist:** Timpers, for the 2022 pixel mint (world.chimpers.com; token metadata `created_by: "Timpers"`).
- **Prior → current:** commercial / chimpers.com/terms / verified → unverifiable. **CHANGED**: the prior row recorded a 404 URL as verified.
- **Confidence:** low. **Reason:** no reachable licence, and this may be the wrong contract.
- Sources: https://chimpers.com/terms (404) · https://world.chimpers.com/about/character-history · https://chimpers.gitbook.io/chimpers-collectible-cards/useful-links/terms-of-service · https://assets-global.website-files.com/6230bd207ad3817a8efd7cf8/63abc48b41b0ca622eeaecc0_Chimpers%20Report.pdf (third-party) · https://www.theboredapegazette.com/post/royalties-will-be-enforced-in-this-dojo-chimpers-announces-plans-to-migrate-the-collection-to-a-roy (secondary)

### 21. Zombunnies: EXCLUDE
`0x10d2d273cb8f6179f1ddd2ee5689cdce363b9a01`
- **What it is:** a ChainBoost / ChainGuardians spin-off. 1,225 minted, made by burning two ChainBunnies; launched around October 2022 (year inferred).
- **Entity:** none found.
- **Licence:** none or unclear. Etherscan licence field "-NA-".
- **Commercial / derivatives / resale:** no grant found.
- **Restrictions:** n/a.
- **Status:** metadata host api.zombunnies.io does not resolve; zombunnies.io is behind a Cloudflare challenge (403).
- **Searched:** zombunnies.io and /terms (403); api.zombunnies.io (no DNS); ChainBoost and ChainGuardians Medium posts (403 directly, read via Wayback); chainguardians.io (TLS failure); web searches.
- **ERC-721L:** 0.
- **Unlocks:** none.
- **Medium:** generative/algorithmic: "five traits and as many as eight traits" (archived ChainBoost Medium post).
- **Artist:** not publicly credited.
- **Prior → current:** unknown → unknown. Unchanged, but the prior row's official_url (chainbunnies.io) belongs to a different collection and its confidence value `unknown` is outside the enum.
- **Confidence:** low. **Reason:** not a blue chip, no rights-granting entity, dead infrastructure.
- Sources: https://etherscan.io/address/0x10d2d273cb8f6179f1ddd2ee5689cdce363b9a01#code · https://web.archive.org/web/20221210124101/https://medium.com/chainboost/zombunnies-the-story-so-far-f28e517be93b (medium) · https://web.archive.org/web/20221114160100/https://www.zombunnies.io/

### 22. Hexagon City Estates: EXCLUDE
`0x28cd2990f34db387d011d7cc693a2bcedd8dc654`
- **What it is:** on-chain name and symbol `CVIP_ESTATE`, verified as `LandsaleNFT_ESTATE`, 729 supply. Estates from the 2022 Cryptoverse land sale, deployed by "ChainGuardians: Deployer". hexagon.city says it "has entered its legacy phase" and is "A Pentagon Games project".
- **Entity:** none named for rights. The archived 2023 cryptoverse.vip privacy policy names CVERSE LTD; its terms link is broken.
- **Licence:** none or unclear.
- **Commercial / derivatives / resale:** no grant found.
- **Restrictions:** n/a.
- **Status:** metadata host api.cryptoverse.biz does not resolve.
- **ERC-721L:** 0.
- **Unlocks:** none.
- **Medium:** unverified (nft-data's app.py describes it as procedurally rendered land; no public source).
- **Artist:** not publicly credited.
- **Prior → current:** no licence row → none found. **NEW.**
- **Confidence:** medium. **Reason:** not a blue chip; land utility token from a project in its legacy phase.
- Sources: https://hexagon.city · http://web.archive.org/web/20230208134353id_/https://www.cryptoverse.vip/privacy-policy · https://etherscan.io/address/0x28cd2990f34db387d011d7cc693a2bcedd8dc654

### 23. BCSH ETH (ours): EXCLUDE
`0x67abaddb1258077f7900abd8ade0ecc6cdc38ac2`
- **Entity:** Pentagon Games ("Blockchain Superheroes™ is a registered IP of Pentagon Games", in the local site source).
- **Licence:** **none published.**
  - bcsh.xyz has no terms; bcsh.xyz/legal is 404.
  - The draft legal page in `C:\Users\ADMIN\Desktop\BCSH\fe-website\app\app\legal\page.tsx` covers site text only (CC BY-NC 4.0). It says hero art is "under the studio's legacy terms" and may not be used to train models.
  - pentagon.games/terms-of-use (updated 29 Sep 2026) reserves all IP and allows "personal, lawful, non-commercial use only", without mentioning NFTs.
  - pentagon.games/where-value-goes says redeemed NFTs carry "whatever creative rights the collection's own license gives its holders", and BCSH has no such licence yet.
- **Commercial / derivatives / resale:** no grant published.
- **Restrictions:** n/a.
- **ERC-721L:** 0.
- **Unlocks:** none until Pentagon Games publishes a holder licence; it could then set any tier, and the contract could expose ERC-721L natively.
- **Medium:** unverified (sampled tokens show a "New Hero Coming Soon" placeholder).
- **Artist:** **not publicly credited.** The draft legal page names "Noi" as artist of record, but it is not published. Do not credit Noi publicly until it is.
- **Prior → current:** no licence row → none. **NEW.**
- **Confidence:** high. **Reason:** our own collection; no holder licence and not a blue chip under the policy as written. This is nftprof's call.
- Sources: https://pentagon.games/terms-of-use · https://pentagon.games/where-value-goes

### 24. POW Bull Badge: EXCLUDE
`0x2094e4f1ad01438eca93092e87033f87d8f76f63`
- **What it is:** on-chain `POW_SBT_2025` / `POW_25`, a 2025 Pentagon Games / BCSH engagement badge.
- **Soulbound:** `isTransferable()` (selector `0x2121dc75`) returns `false` on mainnet (eth_call on 2026-11-02, raw result `0x00…00`). This matches audit F-9; the badge is already off the launch list (76c495c).
- **Entity:** Pentagon Games.
- **Licence:** none. Metadata api.bcsh.xyz/metadata/1 returns `{}`.
- **Commercial / derivatives / resale:** no grant.
- **Restrictions:** n/a.
- **ERC-721L:** 0.
- **Unlocks:** none.
- **Medium:** unverified.
- **Artist:** not publicly credited.
- **Prior → current:** no licence row → none. **NEW.**
- **Confidence:** high. **Reason:** a non-transferable utility badge, not a collectible.
- Sources: https://etherscan.io/address/0x2094e4f1ad01438eca93092e87033f87d8f76f63

### 25. Remilio Babies: LAUNCH (owner decision; research verdict VERIFY)
`0xD3D9ddD0CF0A5F0BFB8f7fcEAe075DF687eAEBaB`
- **Entity:** Remilia (same `owner()` as Milady: `0x54F8E4E9…D728cB`).
- **Licence:** VPL. remilio.org (loaded) uses the same copyleft statement as miladymaker.net.
- **Commercial use:** yes, for anyone, share-alike.
- **Derivatives:** yes, must remain VPL.
- **Resale of derivatives:** allowed under the VPL.
- **Restrictions:** as for Milady. The site calls it a remix of Fodkorp's "C.FANG Milady" character.
- **ERC-721L:** 6 (text).
- **Unlocks:** M S R, under the VPL.
- **Medium:** unverified ("10,000 neochibi pfpNFT's"; the site does not say generative).
- **Artist:** asset illustration by Ula; image compiling by Surfy and Ika; concept by Charlotte Fang (remilio.org credits).
- **Prior → current:** no licence row → copyleft / VPL / verified. **NEW.**
- **Confidence:** high on the licence. **Reason:** rights are clear; whether Remilio counts as an "established blue chip" (Milady's second collection) is an owner decision. LAUNCH if yes.
- Sources: https://remilio.org/ · https://viralpubliclicense.org

### 26. Chain Bunnies: EXCLUDE
`0x9f4564b85cb77ce76cc725f29758cbfe20213aae`
- **What it is:** the verified contract is named **"CrazyBunny"** (symbol CBP), deployed by "ChainGuardians: Deployer", with baseURI `https://api.chainbunnies.io/token/`. 6,052 supply. This is ChainBoost / ChainGuardians' ChainBunnies under a different on-chain name.
- **Entity:** none found.
- **Licence:** none or unclear. Etherscan source licence "MIT" refers to the code only.
- **Commercial / derivatives / resale:** no grant found.
- **Restrictions:** n/a.
- **Status:** api.chainbunnies.io does not resolve. chainbunnies.io is behind a Cloudflare challenge; the 2026-07-10 research found it redirecting to gambling spam.
- **Searched:** chainbunnies.io, www, /terms (403); chainguardians.io and terms paths (TLS failure); chainboost.io (no response); web searches.
- **ERC-721L:** 0.
- **Unlocks:** none.
- **Medium:** generative/algorithmic: "Over 1 Billion Permutations" (2021 Wayback of chainbunnies.io).
- **Artist:** not publicly credited.
- **Prior → current:** no licence row → unknown. **NEW** (the chainbunnies.io note was wrongly attached to Zombunnies).
- **Confidence:** low. **Reason:** not a blue chip; dead or hijacked infrastructure.
- Sources: https://etherscan.io/address/0x9f4564b85cb77ce76cc725f29758cbfe20213aae#code · https://web.archive.org/web/20211221093727/https://chainbunnies.io/ (medium)

### 27. Etheremon: EXCLUDE
`0x5d00d312e171be5342067c09bae883f9bcb2003b`
- **What it is:** `EtheremonMonsterToken` (EMONA), about 2018, 56,537 supply. A 2017–18 on-chain monster game. Secondary snippets say it ran out of funds in 2019 and was relaunched by the community as "Ethermon".
- **Entity:** none reachable.
- **Licence:** none or unclear. Etherscan licence "-NA-".
- **Commercial / derivatives / resale:** no grant found.
- **Restrictions:** n/a.
- **Status:**
  - **etheremon.com is now an Ethereum-casino affiliate site; do not link it.**
  - ethermon.io does not resolve; the gitbook redirects.
  - `tokenURI()` returns an empty string.
- **ERC-721L:** 0.
- **Unlocks:** none.
- **Medium:** unverified.
- **Artist:** not publicly credited (an ArtStation snippet about outsourced 3D monsters is unconfirmed).
- **Prior → current:** unknown → unknown. Unchanged; the confidence value `unknown` is outside the enum.
- **Confidence:** low that any licence exists, high that no grantor is reachable. **Reason:** abandoned 2018 game.
- Sources: https://etherscan.io/address/0x5d00d312e171be5342067c09bae883f9bcb2003b#code · https://www.blockchaingamer.biz/?p=11984 (snippet only)

### 28. CryptoMorph CG: EXCLUDE
`0xfa69031b8f84ade91d1fac52148363842637699a`
- **What it is:** "CryptoMorph - ChainGuardians Series" (CMCG) on OpenSea's shared storefront contract, deployed 2019-11-08 by "CryptoMorph: Deployer", 616 supply. These are elemental buff tokens from a partnership; the CG blog calls CryptoMorph's work "psychedelic crypto-art".
- **Entity:** none found. cryptomorph.io has no DNS, and Wayback holds only a 2017 homepage. ChainGuardians IP is also involved, with no co-licence found.
- **Licence:** none or unclear.
- **Commercial / derivatives / resale:** no grant found.
- **Restrictions:** n/a.
- **Status:** metadata points to OpenSea's v1 API (410 Gone).
- **ERC-721L:** 0.
- **Unlocks:** none.
- **Medium:** unverified.
- **Artist:** CryptoMorph (partner project, per the archived ChainGuardians blog). No individual named.
- **Prior → current:** no licence row → unknown. **NEW.**
- **Confidence:** low. **Reason:** not a blue chip; defunct third-party project.
- Sources: https://etherscan.io/address/0xfa69031b8f84ade91d1fac52148363842637699a · https://web.archive.org/web/20210301004438/https://chainguardians.io/blog/chainguardians-partner-with-cryptomorph-to-release-elemental-buff-for-nfts/ (credit)

### 29. Zorare: EXCLUDE
`0x2a2ad5a2eacf35194d39afe1d727c39710ff0379`
- **What it is:** on-chain `ChainGuardiansToken` (CGT), verified as `ChainGuardiansToken900`, deployed about April 2021 by "ChainGuardians: Deployer". 169 supply, token IDs from 900. "Zorare" is the item name on OpenSea: a single-character series, 1 of 16 colourways assigned by Chainlink VRF.
- **Entity:** ChainGuardians.
- **Licence:** personal-only, by inference from ChainGuardians' archived terms:
  - **2020** (Hong Kong law): "The Terms shall not entitle You to any intellectual property rights"; guardians are "virtual game characters".
  - **Oct 2024 – Aug 2025:** entity left as a placeholder "[Entity name]"; personal, non-commercial use only; no selling or modifying derived materials.
- **Commercial use:** no.
- **Derivatives:** no.
- **Resale of derivatives:** not allowed.
- **Restrictions:** all IP retained.
- **Status:** metadata host api.chainguardians.com does not resolve.
- **ERC-721L:** 1 (inferred applicability of the archived terms).
- **Unlocks:** none.
- **Medium:** unverified.
- **Artist:** not publicly credited for this series. The project names Noi Sackda as its lead artist, but not for Zorare.
- **Prior → current:** no licence row → personal. **NEW.**
- **Confidence:** medium. **Reason:** holders get no creative rights; not a blue chip.
- Sources: http://web.archive.org/web/20200804135401id_/https://chainguardians.io/terms · http://web.archive.org/web/20250818164011id_/https://chainguardians.io/terms-of-use · https://etherscan.io/address/0x2a2ad5a2eacf35194d39afe1d727c39710ff0379 · https://web.archive.org/web/20211229172034/https://chainguardians.io/ (VRF colourways) · https://crypto-economy.com/blockchain-gaming-platform-chainguardians-implements-chainlink-vrf/ (secondary)

### 30. Chainguardians LE: EXCLUDE
`0x4fe99deb8f0be517c31faaad49b4b054ed28c267`
- **What it is:** "ChainGuardians LE" (CGT) on OpenSea's storefront contract, deployed 2019-11-17, 1,162 supply. Metadata is dead (OpenSea v1 API, 410).
- **Entity:** ChainGuardians.
- **Licence:** personal-only (archived ChainGuardians terms, as for Zorare).
- **Commercial / derivatives / resale:** no / no / not.
- **Restrictions:** all IP retained.
- **ERC-721L:** 1 (inferred applicability).
- **Unlocks:** none.
- **Medium:** 2D hand-drawn: illustrated characters, with the art page showing the in-house artist's work and "personal pencil works". Medium confidence: the site does not use the words "hand-drawn".
- **Artist:** Noi Sackda, "LEAD ARTIST. A veteran artist with a portfolio that includes work for DC Comics, Nintendo and Disney" (archived about page). The art page says partner Guardians were made with partners, so not every LE piece is necessarily his.
- **Prior → current:** no licence row → personal. **NEW.**
- **Confidence:** medium. **Reason:** holders get no creative rights; abandoned 2019 game.
- Sources: same archived terms as Zorare · https://web.archive.org/web/20210307055420/https://chainguardians.io/art/ (medium) · https://web.archive.org/web/20210212053221/https://chainguardians.io/about-cg/ (artist) · https://etherscan.io/address/0x4fe99deb8f0be517c31faaad49b4b054ed28c267

### 31. Chainguardians: EXCLUDE
`0x3cd41ec039c1f2dd1f76144bb3722e7b503f50ab`
- **What it is:** `ChainGuardiansToken` (CGT), source unverified, Etherscan tag "ChainGuardians: CGT Token", deployed about July 2019, 1,287 supply. The main 2019 game collection; metadata host api.live.chainguardians.io does not resolve.
- **Entity:** ChainGuardians.
- **Licence:** personal-only (archived terms).
- **Commercial / derivatives / resale:** no / no / not.
- **Restrictions:** all IP retained.
- **ERC-721L:** 1 (inferred applicability).
- **Unlocks:** none.
- **Medium:** 2D hand-drawn (illustrated character cards issued as numbered editions, not trait generation). Medium confidence, as for LE.
- **Artist:** Noi Sackda, Lead Artist (archived project page).
- **Prior → current:** no licence row → personal. **NEW.**
- **Confidence:** medium. **Reason:** holders get no creative rights; abandoned.
- Sources: same archived terms as Zorare · https://web.archive.org/web/20210307055420/https://chainguardians.io/art/ (medium) · https://web.archive.org/web/20210212053221/https://chainguardians.io/about-cg/ (artist) · https://etherscan.io/address/0x3cd41ec039c1f2dd1f76144bb3722e7b503f50ab

---

## Not in scope, but noted

- **Nakamigos:** nft-data's collection entry carries the Nakamigos licence on `0x96c4241d26b63b20d007adfc9a0e1d0a9f7b6c55`, which has no contract on Ethereum. The licence row was seeded on contract id 123, the real address `0xd774557b647330c91bf44cfeab205095f7e6c367`. The launch list excludes Nakamigos for this reason. Fix the address in nft-data, then research Nakamigos as a candidate.
- **CG DAFA:** ERC-1155, so out of scope for MarketplaceV3.

## LAUNCH contracts

Rights-qualified only. Per the note now at the top of `LAUNCH-COLLECTIONS-ETH.md`, the final allowlist is these AND nft-data `supported = true`. The order and spelling are copied from `LAUNCH-COLLECTIONS-ETH.md`.

MoonCats (Acclimated), Meebits, Beanz, MAYC, Azuki Elementals, BAYC, World of Women, Azuki, Moonbirds, Milady Maker, Pudgy Penguins, then the owner decisions uwucrew, Killer GF, Remilio Babies:

```
0xc3f733ca98e0dad0386979eb96fb1722a1a05e69,0x7bd29408f11d2bfc23c34f18275bbf23bb716bc7,0x306b1ea3ecdf94ab739f1910bbda052ed4a9f949,0x60e4d786628fea6478f785a6d7e704777c86a7c6,0xb6a37b5d14d502c3ab0ae6f3a0e058bc9517786e,0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d,0xe785e82358879f061bc3dcac6f0444462d4b5330,0xed5af388653567af2f388e6224dc7c4b3241c544,0x23581767a106ae21c074b2276d25e5c3e136a68b,0x5af0d9827e0c53e4799bb226655a1de152a425a5,0xbd3531da5cf5857e7cfaa92426877b022e612cf8,0xf75140376d246d8b1e5b8a48e3f00772468b3c0c,0x6be69b2a9b153737887cfcdca7781ed1511c7e36,0xD3D9ddD0CF0A5F0BFB8f7fcEAe075DF687eAEBaB
```

## Corrections to send back to nft-data

Proposed only; nothing was written to the nft-data repo or database. The contract ids are those used in `2026-07-10_licensing_complete.sql` where known.

| # | Contract | Field(s) | Current nft-data value | Proposed value |
|---|---|---|---|---|
| 1 | Doodles `0x8a90…992e` | type, name, url, notes | limited_commercial; "Doodles Holder License"; doodles.app/legal/terms; "capped (~USD 100k)" | `personal`; "Doodles Digital Collectibles Media License Agreement (15 Aug 2023)"; https://stoodio.doodles.app/digital-collectibles-media-license-agreement; "Personal, non-commercial only; no modification or derivatives; no new NFTs even for personal use; the 2021 USD 100k merch allowance is not in current terms". Confidence: verified |
| 2 | Moonbirds `0x2358…8b` | type, notes | commercial; "do NOT label CC0" | `cc0`; "Pixel Moonbirds art CC0 (proof.xyz/terms/moonbirds, 11 Jun 2024, still current). Optional Illustrated art is under a holder commercial licence that ends on transfer. Terms name Yuga Labs; Orange Cap Games claims the IP; marks reserved" |
| 3 | Lil Pudgys (id 119) | type, confidence, notes | limited_commercial; verified | `unknown`; `needs_legal`; "Pudgy IP Rights agreement names only Pudgy Penguin NFTs; Lil Pudgys are licensed per deal via OverpassIP" |
| 4 | CLONE X (id 82) | url, confidence, notes | rtfkt.com/legal-2C; verified | https://web.archive.org/web/20260710083607/https://rtfkt.com/legal-2C; `needs_legal`; "rtfkt.com 503 since at least 2026-11-02; RTFKT sold to an undisclosed owner 17 Dec 2025 (Nike via Bloomberg Law); commercial licence needs registration that is unavailable" |
| 5 | World of Women (id 124) | url, notes | ipfs QmYccLQN… (Jan 2022) | https://worldofwomen.mypinata.cloud/ipfs/QmPrxnFqMJDox5tpd2KhH28gtzu7xPyeFNDwpnm5RKvwv6 (V3, 22 Mar 2024); add "no independent use of Attributes; worldofwomen.art/terms is 404" |
| 6 | uwucrew (id 120) | url, notes | uwucrew.art/license | https://mirror.xyz/uwucrew.eth/DwrrmMYgsUT0mXsMEvbWBoLtnKcW0TRKOpwUWjDbZXg; add "25 'The Crew' tokens are CC0; non-holders CC BY-NC" |
| 7 | BAKC (id 121) | type, confidence, notes | commercial; likely | `unknown`; `needs_legal`; "No BAKC licence text; Yuga's 'BAKC license terms' link (/licenses/bakc) is 404" |
| 8 | Chimpers (id 95) | url, confidence, notes | chimpers.com/terms; verified | url NULL; `needs_legal`; "chimpers.com/terms 404; contract may be legacy after migration to a royalty-enforcing contract; confirm the live contract and licence" |
| 9 | Azuki Elementals (id 60) | confidence, notes | verified | `likely`; "Covered by the licence's 'any Azuki branded … NFT created by Chiru Labs' definition; not named" |
| 10 | Azuki, Elementals, Beanz (ids 54, 60, 122) | notes | — | add "Licence (5/5/22) names Chiru Labs; site now operated by Azuki Labs, Inc. (T&C 15 Mar 2026)" |
| 11 | Pudgy Penguins (id 118) | notes | cap only | add "No express derivative grant; third-party promotion needs Creator approval; rights incl. derivative penguins end on sale; text dated Dec 2022" |
| 12 | Meebits (id 94) | notes | "license transfers with NFT" | add "Seller loses all rights on transfer, incl. inside existing derivatives; a conflicting May 2025 MeebCo PDF (licenseterms.meebits.app, 'exclusive', sell-off allowed) is still live" |
| 13 | Zombunnies (id 30) | official_url, notes, confidence | chainbunnies.io; chainbunnies spam note; `unknown` | official_url NULL or zombunnies.io (Cloudflare-blocked); notes "api.zombunnies.io no DNS; no licence found"; confidence must be a documented value (`unknown` is not one of verified/likely/needs_legal/unresearched) |
| 14 | Etheremon (id 27) | confidence, notes | `unknown` | a documented confidence value; add "etheremon.com is now casino spam — never link" |
| 15 | Nakamigos | collection address | 0x96c4241d… (no contract) | 0xd774557b647330c91bf44cfeab205095f7e6c367 (where the licence row already sits, id 123) |
| 16 | MoonCats (Acclimated) | notes | — | add "Licence v1.0 names the Acclimator 0xc3f7… as a notice location; derivatives are owned by MoonCatRescue LLC; rights expire for the seller on transfer" |
| 17 | New rows | all | none | Remilio Babies `copyleft` VPL https://remilio.org (verified); Chain Bunnies `unknown` (on-chain "CrazyBunny", dead API); Hexagon City Estates `unknown`; BCSH ETH `proprietary`, no holder licence published; POW Bull Badge `proprietary`, soulbound (`isTransferable() = false`); CryptoMorph CG `unknown`; Zorare, Chainguardians LE, Chainguardians `personal` per archived ChainGuardians terms (likely) |
| 18 | Schema / API | — | — | Expose `license_confidence` in the API (it is stored but not returned). Consider adding `erc721l_tier`, `derivatives`, `derivative_resale`, `revenue_cap`, `medium` and `artist_credit` columns so this register can live in nft-data |
