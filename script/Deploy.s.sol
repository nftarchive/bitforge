// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/BitForge.sol";

/// @notice Deploy script — Robinhood Chain mainnet (4663), gas ETH.
///         Run with real addresses via env vars. Treasury + personal wallets
///         MUST be fresh wallets (never 0x3cDa / vernalta / yamato).
///
///         REQUIRED env vars (no defaults — deploy cannot run nameless or
///         wallet-less):
///           PROJECT_NAME, PROJECT_SYMBOL, BASE_URI (repo Pages metadata URL,
///           e.g. https://nftarchive.github.io/bitforge/metadata/),
///           TREASURY, PERSONAL_WALLET_1, PERSONAL_WALLET_2,
///           PERSONAL_WALLET_3, PUZZLE_SEED (bytes32(0) = random at deploy),
///           MINT_SIGNER (X-gate signer address — the Worker key, public part).
///         OPTIONAL: PERSONAL_WALLET_4, PERSONAL_WALLET_5 (3-5 personal
///         wallets total; the 31 personal NFTs split round-robin across them).
///
///         CHAIN GUARDS (run BEFORE any broadcast — the Cinder lesson: never
///         deploy on an assumption):
///           - block.chainid MUST be 4663 (Robinhood mainnet). No other chain.
///           - Gas is ETH on this chain. There is no BNB / USDT / router here
///             and this contract needs none of them — nothing to check.
///           - Treasury + personal wallets: nonzero, distinct, 3-5 personal.
contract DeployBitForge is Script {
    function run() external {
        string memory projectName = vm.envString("PROJECT_NAME");
        string memory projectSymbol = vm.envString("PROJECT_SYMBOL");
        string memory baseURI = vm.envString("BASE_URI");
        address treasury = vm.envAddress("TREASURY");
        bytes32 puzzleSeed = vm.envBytes32("PUZZLE_SEED");
        address mintSigner = vm.envAddress("MINT_SIGNER");

        address[] memory personal = new address[](5);
        uint256 nPersonal = 0;
        personal[nPersonal++] = vm.envAddress("PERSONAL_WALLET_1");
        personal[nPersonal++] = vm.envAddress("PERSONAL_WALLET_2");
        personal[nPersonal++] = vm.envAddress("PERSONAL_WALLET_3");
        address w4 = vm.envOr("PERSONAL_WALLET_4", address(0));
        if (w4 != address(0)) personal[nPersonal++] = w4;
        address w5 = vm.envOr("PERSONAL_WALLET_5", address(0));
        if (w5 != address(0)) personal[nPersonal++] = w5;

        // --- pre-deploy guards ---
        require(block.chainid == 4663, "ABORT: not Robinhood mainnet (4663)");
        console.log("Chain ID:", block.chainid);
        console.log("Gas token: ETH (Robinhood Chain native)");
        // baseURI MUST end with "/" — tokenURI() concatenates it directly
        // with "{rarity}_{serial}.json". Without the slash every tokenURI
        // breaks (e.g. ".../metadatacommon_1.json"). Enforced here because
        // the contract cannot change baseURI after deploy (no setter).
        bytes memory baseURIBytes = bytes(baseURI);
        require(baseURIBytes.length > 0, "ABORT: empty baseURI");
        require(baseURIBytes[baseURIBytes.length - 1] == bytes1("/"), "ABORT: baseURI must end with '/'");
        require(treasury != address(0), "ABORT: zero treasury");
        require(mintSigner != address(0), "ABORT: zero mint signer");
        require(nPersonal >= 3 && nPersonal <= 5, "ABORT: need 3-5 personal wallets");
        for (uint256 i = 0; i < nPersonal; i++) {
            require(personal[i] != address(0), "ABORT: zero personal wallet");
            require(personal[i] != treasury, "ABORT: personal == treasury");
            for (uint256 j = 0; j < i; j++) {
                require(personal[i] != personal[j], "ABORT: dup personal wallet");
            }
        }
        // shrink to the real count
        address[] memory personalWallets = new address[](nPersonal);
        for (uint256 i = 0; i < nPersonal; i++) personalWallets[i] = personal[i];

        vm.startBroadcast();
        BitForge nft = new BitForge(
            projectName, projectSymbol, baseURI, treasury, personalWallets, puzzleSeed, mintSigner
        );
        vm.stopBroadcast();

        console.log("BitForge:", address(nft));
        console.log("mintSigner (X-gate):", nft.mintSigner());
        console.log("mintStart:", nft.mintStart());
        console.log("mintEnd:", nft.mintEnd());
        console.log("totalSupply (team pre-mints):", nft.totalSupply());
        console.log("commonMinted:", nft.commonMinted());
        console.log("rareMinted:", nft.rareMinted());
        console.log("epicMinted:", nft.epicMinted());
        console.log("legendaryMinted:", nft.legendaryMinted());
        console.log("ROYALTY: 5% (500 bps) to treasury, ERC-2981, locked (no setter)");
        console.log("SEAPORT (verified onchain 2026-11-11, v1.6):");
        console.log("0x0000000000000068F116a894984e2DB1123eB395");
        console.log("POST-DEPLOY (before trading opens): call");
        console.log("setOperatorAllowed(0x0000000000000068F116a894984e2DB1123eB395, true)");
        console.log("or no marketplace sale can execute. No conduit needed on");
        console.log("Robinhood Chain (canonical conduit has no code; orders go");
        console.log("through Seaport directly).");
    }
}
