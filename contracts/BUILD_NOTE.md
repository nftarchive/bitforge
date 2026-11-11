# BitForge — contracts (Robinhood Chain 4663, ETH gas, ALL-FREE)

## What this is
Single NFT contract (`src/BitForge.sol`). No token, no pool, no burn, no
market contract, no paid mint. Secondary trading is on OpenSea only.

## Design (all decided by juragan 2026-11-10)
- Supply 3,131 = 3,000 public free + 131 team.
- Free mint: PoW puzzle, 1/wallet, open to ANY wallet (no Agent ID gate).
- Rarity = COLOR COUNT: Common 2 colors, Rare 3, Epic 4, Legendary 6.
  Totals: Common 2,035 / Rare 730 / Epic 313 / Legendary 53.
  Public 3,000: C1,950 / R700 / E300 / L50.
  Team 131: C85 / R30 / E13 / L3 — treasury 100 (C67/R22/E10/L1),
  personal 31 (C18/R8/E3/L2, dealt round-robin so the 2 personal
  Legendary land on the first 2 wallets; every personal wallet gets
  at least one Epic or Legendary). Team rarities are DETERMINISTIC
  (assigned in the constructor), never random — Cinder's personal 31
  got 0 Legendary; that cannot recur here.
- Puzzle difficulty FLAT (2026-11-12, user decision — BitForge is NOT an
  agent project, users mint manually): PUZZLE_BITS = 20 for ALL 3,000 free
  mints. No tiers, no rotation. ~16 s on a slow device, ~3 s on a good phone.
- X-SIGNATURE GATE ("cap", 2026-11-12, user decision — public mint = bot race):
  mintFree(uint256 nonce, uint256 deadline, bytes signature) requires a
  signature from mintSigner (Cloudflare Worker key), issued only after a real
  X OAuth login. Signature covers (wallet, deadline, contract, chainId),
  valid 1 hour. Bots calling the contract directly revert ("bad signature").
  mintSigner is owner-rotatable via setMintSigner. Signer address:
  0x47Bd98c8326168A0747DaE856A2A952ebD100E9a (private key held ONLY by the
  user in Bitget + as a Cloudflare Worker secret — NEVER in the repo).
- Mint window: 7 days (DEFAULT — confirm before deploy).
- Owner powers ONLY: finalize() (time-locked, closes mint, no payouts —
  all free). No pause, no setPrice, no setBaseURI, no upgrade, no withdraw,
  no rotatePuzzle (removed 2026-11-12).
- CREATOR FEE 5% ENFORCED (decided 2026-11-11, final): ERC-2981 declares
  5% (500 bps) to the treasury, set once in the constructor — NO setter,
  so the rate/recipient can never change. An operator allowlist blocks
  transfers by non-allowlisted marketplace contracts, so sales can only
  go through royalty-respecting venues (OpenSea Seaport). Direct
  wallet-to-wallet transfers and transfers by EOAs are always allowed.
  The allowlist IS owner-updatable (setOperatorAllowed) — the check
  cannot be disabled, only the list can grow.
- SEAPORT ON ROBINHOOD CHAIN — CONFIRMED 2026-11-11 (verified onchain,
  NOT assumed): **Seaport 1.6 = 0x0000000000000068F116a894984e2DB1123eB395**.
  Verified 3 ways: (1) information() returns version "1.6" + conduit
  controller 0x00000000f9490004c11cef243f5400493c00ad63; (2) bytecode
  23,981 bytes, EXACT match to Seaport 1.6 on Ethereum; (3) actively
  used — 3,222 events in 50,000 blocks, real NFT sales through it
  (sample tx 0x43b05bb9... moved 5 NFTs). Envio's RH Chain ecosystem
  index lists this exact address as OpenSea/Seaport. ADD via
  setOperatorAllowed(seaport, true) BEFORE trading opens.
  CONDUIT: the canonical Seaport conduit (0x1E0049783F008A0085193E00003D00cd54003c71)
  has NO code on RH Chain, getConduit(OpenSea key) returns 0x0, and the
  OpenSea conduit key does NOT appear in real sale calldata — orders on
  RH Chain go through Seaport DIRECTLY (conduitKey 0x0). No conduit
  allowlist needed. If a conduit ever appears, add it via
  setOperatorAllowed (no redeploy needed).
- baseURI set ONCE in the constructor (no setter). PLACEHOLDER now:
  `https://nftarchive.github.io/bitforge/metadata/` — MUST be the real
  repo Pages URL at deploy. tokenURI = baseURI + rarity_serial + ".json".
- Name/symbol set at deploy via env (no defaults). Symbol used in
  tests/dry run: "BTFG" — CONFIRM with juragan before deploy.

## Chain facts — VERIFIED 2026-11-10, not assumed (the Cinder lesson)
- Robinhood Chain mainnet = chain ID 4663. RPC
  `https://rpc.mainnet.chain.robinhood.com` answered `eth_chainId`
  `0x1237` (= 4663) live.
- Native gas token = ETH (18 decimals). Verified via QuickNode /
  Chainstack / hood.dev docs. There is NO BNB, NO USDT, NO PancakeSwap
  on this chain — the Cinder USDT-decimals bug class cannot occur here
  (no payment token exists in this contract at all).
- Sourcify SUPPORTS chain 4663 (verified: GET
  /v2/contract/4663/<Veil addr> returns chainId "4663").
- Orbit quirk: on Arbitrum Orbit chains block.number does NOT return the
  L2 block height (it tracks the parent chain). This contract never uses
  block.number for timing (mint window uses block.timestamp). blockhash()
  is used ONLY as entropy mixed with minter + tokenId + drawNonce.
- WETH on Robinhood Chain: 0x0bd7d308f8e1639fab988df18a8011f41eacad73
  (not used by this contract — no ETH payments).

## Verification (no gas spent, no real deploy)
- `forge test`: **19/19 PASS** (12 original + 7 royalty: royaltyInfo 5% to
  treasury, ERC-2981 interface, operator blocked/allowed, owner self-transfer,
  EOA transfer, setOperatorAllowed owner-only).
- Mainnet-fork dry run (`forge script --fork-url
  https://rpc.mainnet.chain.robinhood.com`): **clean**. Guards printed
  "Chain ID: 4663" + "Gas token: ETH". Simulated deploy:
  BitForge 0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519 (FORK ARTIFACT —
  NOT a real deploy), mintStart 1794353337, mintEnd 1794958137 (7d),
  totalSupply 131, C85/R30/E13/L3. Estimated gas ~14,251,347,
  ~0.00057 ETH.
- Free-mint PoW nonce for tests computed offchain (ethers + SHA-256):
  wallet 0x3001, seed 0x1111…1111, nonce 251724 (19 leading zero bits).

## Open before deploy (needs juragan)
1. Symbol: "BTFG" is the draft — confirm or change.
2. Mint window: 7 days is the draft default — confirm or change.
3. Repo + BASE_URI: repo `nftarchive/bitforge` EXISTS, Pages live at
   `https://nftarchive.github.io/bitforge/`; BASE_URI is
   `https://nftarchive.github.io/bitforge/metadata/` (set at deploy).
4. Wallet addresses: treasury + 3–5 fresh personal wallets (deferred
   by juragan — "wallet nanti aja").
5. Deployer: needs ETH on Robinhood Chain for gas (~0.0006 ETH est.)
   + key transiently at deploy.
6. Deploy script REQUIRES env: PROJECT_NAME, PROJECT_SYMBOL, BASE_URI,
   TREASURY, PERSONAL_WALLET_1/2/3 (+4/5 optional), PUZZLE_SEED
   (bytes32(0) = random). It aborts unless chainid == 4663.

## Files
- `src/BitForge.sol` — the only contract.
- `script/Deploy.s.sol` — deploy (Robinhood 4663, chain guard, no
  external-token checks needed — there is no external token).
- `test/BitForge.t.sol` — 19 tests (12 original + 7 royalty).
- `broadcast/Deploy.s.sol/4663/dry-run/` — fork dry-run record.
- Art set: `~/workspace/bitforge-nft/` (3,131 images + metadata).
- Base draft this was reworked from:
  `~/workspace/cinder-concept/contracts-open/` (BSC, paid/token/pool
  model — all of that was REMOVED here).
