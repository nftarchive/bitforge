// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BitForge — ERC-721 collection (3,131), ALL-FREE, Robinhood Chain (4663)
/// @notice 3,000 public free mints (PoW-gated, 1/wallet) + 131 team pre-minted
///         BY THE CONTRACT ITSELF in the constructor (100 treasury, 31 personal
///         across 3-5 wallets). NO paid mint, NO token, NO pool, NO burn, NO
///         market contract — secondary trading is on OpenSea only.
///         Rarity = COLOR COUNT (decided 2026-11-10): every robot is mixed-color;
///         higher rarity = more colors. Common 2 colors, Rare 3, Epic 4,
///         Legendary 6 (all). Totals: Common 2,035 / Rare 730 / Epic 313 /
///         Legendary 53. Team split (deterministic, guaranteed): treasury
///         C67/R22/E10/L1, personal C18/R8/E3/L2 — the 2 personal Legendary
///         are GUARANTEED (Cinder's personal 31 got 0 Legendary; never again).
///         Instant reveal, PoW-gated free mint. No VRF, no transfer tax,
///         no owner fund-moving function, no upgrades, no hidden allocation.
///         Mint cap never re-opens after burns (totalMinted is monotonic).
/// @dev CHAIN FACTS (verified 2026-11-10, NOT assumed): Robinhood Chain is an
///      Arbitrum Orbit L2, chain ID 4663, native gas token ETH (18 decimals).
///      There is NO BNB, NO USDT, NO PancakeSwap on this chain — the v1 Cinder
///      USDT-decimals bug class cannot occur here (no payment token at all).
///      Sourcify supports chain 4663 (verified: /v2/contract/4663/<addr>
///      returns chainId 4663). RPC: https://rpc.mainnet.chain.robinhood.com.
///      ORBIT QUIRK: on Orbit chains block.number does NOT return the L2 block
///      height (it tracks the parent chain). This contract NEVER uses
///      block.number for timing (mint window uses block.timestamp, which is
///      correct on Orbit). blockhash(block.number - 1) is used ONLY as entropy
///      mixed with minter + tokenId + drawNonce for the rarity draw and the
///      deploy seed — even if it returned 0, draws stay unique per mint.
///      Puzzle preimage matches the website solver exactly:
///      SHA-256(hex(seed) + ":" + decimal(nonce)), leading-zero-bit target.
///      Seed is wallet-bound: seedFor(wallet) = keccak256(wallet, puzzleSeed).
///      Difficulty is FLAT (PUZZLE_BITS = 20) for all 3,000 free mints — no
///      tiers, no rotation. puzzleSeed is set once at deploy and never changes.
///      baseURI is set ONCE in the constructor (immutable after deploy, no
///      setBaseURI by design) — it MUST be the real repo Pages URL at deploy.
///      CREATOR FEE 5% ENFORCED (decided 2026-11-11): ERC-2981 declares 5%
///      to the treasury, and an operator allowlist blocks transfers by
///      non-allowlisted marketplace contracts, so sales can only go through
///      royalty-respecting venues (OpenSea Seaport). Direct wallet-to-wallet
///      transfers (owner moving their own NFT) and transfers by EOAs are
///      always allowed. The 5% rate is set once in the constructor and has
///      NO setter, so it can never be lowered or turned off. The allowlist
///      itself IS owner-updatable (to add new marketplaces / rotate Seaport
///      addresses) — the enforcement check cannot be disabled, only the
///      list can grow.
contract BitForge is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using Strings for uint256;

    // ---- supply ----
    uint256 public constant MAX_SUPPLY = 3131;
    uint256 public constant FREE_SUPPLY = 3000;
    uint256 public constant TEAM_SUPPLY = 131;
    uint256 public constant TEAM_TREASURY = 100;
    uint256 public constant TEAM_PERSONAL = 31;

    // ---- rarity quotas (collection totals) ----
    uint256 public constant COMMON_MAX = 2035;
    uint256 public constant RARE_MAX = 730;
    uint256 public constant EPIC_MAX = 313;
    uint256 public constant LEGENDARY_MAX = 53;

    // ---- team rarity split (deterministic, guaranteed) ----
    // Treasury 100: C67 / R22 / E10 / L1. Personal 31: C18 / R8 / E3 / L2.
    uint256 public constant TREASURY_COMMON = 67;
    uint256 public constant TREASURY_RARE = 22;
    uint256 public constant TREASURY_EPIC = 10;
    uint256 public constant TREASURY_LEGENDARY = 1;
    uint256 public constant PERSONAL_COMMON = 18;
    uint256 public constant PERSONAL_RARE = 8;
    uint256 public constant PERSONAL_EPIC = 3;
    uint256 public constant PERSONAL_LEGENDARY = 2;

    // ---- puzzle difficulty (leading zero bits), FLAT for all 3,000 free mints ----
    // BitForge is NOT an agent project: users mint manually from the browser,
    // so the puzzle must be solvable in seconds on a phone. 20 bits ≈ 1M
    // hashes ≈ 16 s on a slow device, ~3 s on a good phone. One difficulty
    // for every mint — no tiers, no rotation, no surprises.
    uint256 public constant PUZZLE_BITS = 20;

    uint256 public constant MINT_WINDOW = 7 days;

    // ---- creator fee (ERC-2981, 5% = 500 bps, denominator 10000) ----
    // Set once in the constructor to the treasury. NO setter exists, so the
    // rate and recipient can never change after deploy.
    uint96 public constant ROYALTY_BPS = 500;

    // ---- operator allowlist (royalty enforcement) ----
    // Marketplace contracts that may move NFTs on owners' behalf (e.g.
    // OpenSea Seaport). The owner can add/remove operators, but the
    // enforcement check itself cannot be disabled.
    mapping(address => bool) public operatorAllowed;

    error OperatorNotAllowed(address operator);

    // Set ONCE in the constructor; no setter exists, so it can never change
    // after deploy. (Solidity forbids `immutable` on strings.)
    string public baseURI;

    address public immutable treasury;
    address[] public personalWallets;

    uint256 public immutable mintStart;
    uint256 public immutable mintEnd;

    uint256 public totalMinted;
    uint256 public freeMinted;
    uint256 public drawNonce;

    uint256 public commonRemaining = COMMON_MAX;
    uint256 public rareRemaining = RARE_MAX;
    uint256 public epicRemaining = EPIC_MAX;
    uint256 public legendaryRemaining = LEGENDARY_MAX;

    uint256 public commonMinted;
    uint256 public rareMinted;
    uint256 public epicMinted;
    uint256 public legendaryMinted;

    mapping(uint256 => uint8) public tokenRarity; // 0 common, 1 rare, 2 epic, 3 legendary
    mapping(uint256 => uint256) public tokenSerial; // in-tier serial
    mapping(address => bool) public freeMintedBy;

    bytes32 public puzzleSeed;
    bool public finalized;

    event Minted(address indexed minter, uint256 indexed tokenId, uint8 rarity, uint256 serial, bool isFree);
    event Finalized();
    event OperatorAllowed(address indexed operator, bool allowed);

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address treasury_,
        address[] memory personalWallets_,
        bytes32 puzzleSeed_
    ) ERC721(name_, symbol_) Ownable(msg.sender) {
        require(bytes(baseURI_).length > 0, "empty baseURI");
        require(treasury_ != address(0), "zero treasury");
        require(personalWallets_.length >= 3 && personalWallets_.length <= 5, "need 3-5 personal wallets");
        for (uint256 i = 0; i < personalWallets_.length; i++) {
            require(personalWallets_[i] != address(0), "zero personal wallet");
            require(personalWallets_[i] != treasury_, "personal == treasury");
            for (uint256 j = 0; j < i; j++) {
                require(personalWallets_[i] != personalWallets_[j], "dup personal wallet");
            }
        }
        baseURI = baseURI_;
        treasury = treasury_;
        // Creator fee 5% to the treasury, locked forever (no setter).
        _setDefaultRoyalty(treasury_, ROYALTY_BPS);
        personalWallets = personalWallets_;
        mintStart = block.timestamp;
        mintEnd = block.timestamp + MINT_WINDOW;
        puzzleSeed = puzzleSeed_ == bytes32(0)
            ? keccak256(abi.encodePacked(_prevBlockhash(), msg.sender, block.timestamp))
            : puzzleSeed_;
        // Team pre-mints BY THE CONTRACT ITSELF, deterministic rarities.
        // Treasury 100: C67 / R22 / E10 / L1 (in order).
        _mintTeamBatch(treasury_, TREASURY_COMMON, TREASURY_RARE, TREASURY_EPIC, TREASURY_LEGENDARY);
        // Personal 31: C18 / R8 / E3 / L2, dealt round-robin across the
        // personal wallets from the ordered multiset [L,L,E,E,E,R*8,C*18],
        // so the 2 Legendary land on the first 2 wallets and every wallet
        // gets at least one Epic or Legendary.
        uint8[31] memory personalRarities = _personalRarityOrder();
        for (uint256 i = 0; i < TEAM_PERSONAL; i++) {
            address to = personalWallets_[i % personalWallets_.length];
            _mintWithRarity(to, personalRarities[i]);
        }
    }

    /// @notice The personal 31 rarities in deal order: [L,L,E,E,E,R*8,C*18].
    function _personalRarityOrder() internal pure returns (uint8[31] memory rarities) {
        rarities[0] = 3;
        rarities[1] = 3;
        rarities[2] = 2;
        rarities[3] = 2;
        rarities[4] = 2;
        for (uint256 i = 5; i < 13; i++) rarities[i] = 1;
        for (uint256 i = 13; i < 31; i++) rarities[i] = 0;
    }

    /// @notice Mint `c` Common, `r` Rare, `e` Epic, `l` Legendary to `to`, in order.
    function _mintTeamBatch(address to, uint256 c, uint256 r, uint256 e, uint256 l) internal {
        for (uint256 i = 0; i < c; i++) _mintWithRarity(to, 0);
        for (uint256 i = 0; i < r; i++) _mintWithRarity(to, 1);
        for (uint256 i = 0; i < e; i++) _mintWithRarity(to, 2);
        for (uint256 i = 0; i < l; i++) _mintWithRarity(to, 3);
    }

    // ============ views ============

    /// @notice Total NFTs minted (team pre-mints + user mints).
    function totalSupply() public view returns (uint256) {
        return totalMinted;
    }

    function freeRemaining() public view returns (uint256) {
        return FREE_SUPPLY - freeMinted;
    }

    /// @notice Wallet-bound puzzle seed. Public by design: solvers need it to mine.
    function seedFor(address wallet) public view returns (bytes32) {
        return keccak256(abi.encodePacked(wallet, puzzleSeed));
    }

    /// @notice Leading-zero-bit target for the NEXT free mint. Flat: the same
    ///         PUZZLE_BITS for every mint. Kept (same selector) for the mint
    ///         site, which reads it to show the difficulty.
    function tierBits() public pure returns (uint256) {
        return PUZZLE_BITS;
    }

    /// @notice Offchain check: does `nonce` solve `wallet`'s current puzzle?
    function verifyProof(address wallet, uint256 nonce) public view returns (bool) {
        return _leadingZeroBits(_proofDigest(wallet, nonce)) >= tierBits();
    }

    // ============ free mint (PoW-gated, 1/wallet) ============

    function mintFree(uint256 nonce) external nonReentrant {
        require(!finalized, "mint closed");
        require(block.timestamp >= mintStart && block.timestamp <= mintEnd, "mint window closed");
        require(freeMinted < FREE_SUPPLY, "free sold out");
        require(!freeMintedBy[msg.sender], "free already claimed");
        require(verifyProof(msg.sender, nonce), "bad proof");
        freeMintedBy[msg.sender] = true;
        _mintNext(msg.sender, msg.sender);
        freeMinted++;
    }

    // ============ finalize (owner-only; closes the mint, no payouts — all free) ============

    /// @notice Close the mint permanently. No proceeds exist (all mints are free),
    ///         so finalize only closes minting. Time-locked like Cinder.
    function finalize() external onlyOwner nonReentrant {
        require(!finalized, "already finalized");
        require(totalMinted == MAX_SUPPLY || block.timestamp >= mintEnd, "not ready");
        finalized = true;
        emit Finalized();
    }

    /// @notice Previous block's hash (0 on a genesis block, where it doesn't exist).
    /// @dev On Robinhood Chain (Arbitrum Orbit) block.number tracks the parent
    ///      chain, so this reads a parent-block hash — fine as entropy only.
    function _prevBlockhash() internal view returns (bytes32) {
        return block.number == 0 ? bytes32(0) : blockhash(block.number - 1);
    }

    // ============ creator fee enforcement (operator allowlist) ============

    /// @notice Add or remove a marketplace operator (e.g. OpenSea Seaport).
    ///         Only the owner can change the list. The enforcement check
    ///         itself cannot be disabled — only the list can grow/shrink.
    function setOperatorAllowed(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), "zero operator");
        operatorAllowed[operator] = allowed;
        emit OperatorAllowed(operator, allowed);
    }

    /// @notice Transfer restriction: a marketplace contract may only move
    ///         NFTs if it is allowlisted. Mints (from == 0), burns
    ///         (to == 0), owner self-transfers, and transfers by EOAs
    ///         (code.length == 0) are always allowed. This forces sales
    ///         through royalty-respecting venues, so the 5% ERC-2981 fee
    ///         cannot be bypassed by selling on a zero-fee marketplace.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            address operator = msg.sender;
            if (operator != from && operator.code.length > 0 && !operatorAllowed[operator]) {
                revert OperatorNotAllowed(operator);
            }
        }
        return super._update(to, tokenId, auth);
    }

    /// @notice ERC-165: declare ERC721 + ERC-2981 (royalty) support.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ============ metadata ============

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "nonexistent token");
        return
            string(
                abi.encodePacked(
                    baseURI,
                    _rarityName(tokenRarity[tokenId]),
                    "_",
                    tokenSerial[tokenId].toString(),
                    ".json"
                )
            );
    }

    function _rarityName(uint8 rarity) internal pure returns (string memory) {
        if (rarity == 0) return "common";
        if (rarity == 1) return "rare";
        if (rarity == 2) return "epic";
        return "legendary";
    }

    // ============ internals ============

    /// @notice Mint the next public free NFT: instant reveal from the urn over
    ///         the REMAINING quotas (team pre-mints already took their share).
    function _mintNext(address minter, address to) internal returns (uint256 tokenId) {
        require(totalMinted < MAX_SUPPLY, "sold out");
        tokenId = totalMinted + 1;
        bytes32 rnd = keccak256(abi.encodePacked(_prevBlockhash(), minter, tokenId, drawNonce));
        drawNonce++;
        (uint8 rarity, uint256 serial) = _drawRarity(rnd);
        tokenRarity[tokenId] = rarity;
        tokenSerial[tokenId] = serial;
        totalMinted++;
        _mint(to, tokenId);
        emit Minted(to, tokenId, rarity, serial, true);
    }

    /// @notice Mint one NFT of an EXPLICIT rarity (team pre-mints only).
    /// @dev Decrements that rarity's remaining quota and assigns the next
    ///      in-tier serial. Reverts if that rarity is exhausted.
    function _mintWithRarity(address to, uint8 rarity) internal returns (uint256 tokenId) {
        require(totalMinted < MAX_SUPPLY, "sold out");
        tokenId = totalMinted + 1;
        uint256 serial;
        if (rarity == 0) {
            require(commonRemaining > 0, "no common left");
            commonRemaining--;
            commonMinted++;
            serial = commonMinted;
        } else if (rarity == 1) {
            require(rareRemaining > 0, "no rare left");
            rareRemaining--;
            rareMinted++;
            serial = rareMinted;
        } else if (rarity == 2) {
            require(epicRemaining > 0, "no epic left");
            epicRemaining--;
            epicMinted++;
            serial = epicMinted;
        } else {
            require(legendaryRemaining > 0, "no legendary left");
            legendaryRemaining--;
            legendaryMinted++;
            serial = legendaryMinted;
        }
        tokenRarity[tokenId] = rarity;
        tokenSerial[tokenId] = serial;
        totalMinted++;
        _mint(to, tokenId);
        emit Minted(to, tokenId, rarity, serial, false);
    }

    /// @notice Instant reveal: hash mapped to remaining-quota tiers.
    /// @dev Single urn over all remaining quotas. If Common/Rare/Epic are
    ///      exhausted, the draw falls through to Legendary naturally, so a
    ///      free mint can never brick.
    function _drawRarity(bytes32 rnd) internal returns (uint8 rarity, uint256 serial) {
        uint256 total = commonRemaining + rareRemaining + epicRemaining + legendaryRemaining;
        require(total > 0, "sold out");
        uint256 r = uint256(rnd) % total;
        if (r < commonRemaining) {
            commonRemaining--;
            commonMinted++;
            return (0, commonMinted);
        } else if (r < commonRemaining + rareRemaining) {
            rareRemaining--;
            rareMinted++;
            return (1, rareMinted);
        } else if (r < commonRemaining + rareRemaining + epicRemaining) {
            epicRemaining--;
            epicMinted++;
            return (2, epicMinted);
        } else {
            legendaryRemaining--;
            legendaryMinted++;
            return (3, legendaryMinted);
        }
    }

    // ---- PoW proof: SHA-256(hex(seed) + ":" + decimal(nonce)) ----

    function _proofDigest(address wallet, uint256 nonce) internal view returns (bytes32) {
        bytes memory preimage = abi.encodePacked(_toHex(seedFor(wallet)), ":", nonce.toString());
        return _sha256(preimage);
    }

    function _sha256(bytes memory data) internal view returns (bytes32 digest) {
        (bool ok, bytes memory ret) = address(2).staticcall(data);
        require(ok && ret.length == 32, "SHA256 failed");
        digest = abi.decode(ret, (bytes32));
    }

    function _toHex(bytes32 v) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory out = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(v[i]);
            out[i * 2] = hexChars[b >> 4];
            out[i * 2 + 1] = hexChars[b & 0x0f];
        }
        return string(out);
    }

    function _leadingZeroBits(bytes32 digest) internal pure returns (uint256 bits) {
        uint256 x = uint256(digest);
        if (x == 0) return 256;
        if (x < (1 << 128)) {
            bits += 128;
            x <<= 128;
        }
        if (x < (1 << 192)) {
            bits += 64;
            x <<= 64;
        }
        if (x < (1 << 224)) {
            bits += 32;
            x <<= 32;
        }
        if (x < (1 << 240)) {
            bits += 16;
            x <<= 16;
        }
        if (x < (1 << 248)) {
            bits += 8;
            x <<= 8;
        }
        if (x < (1 << 252)) {
            bits += 4;
            x <<= 4;
        }
        if (x < (1 << 254)) {
            bits += 2;
            x <<= 2;
        }
        if (x < (1 << 255)) {
            bits += 1;
        }
        return bits;
    }
}
