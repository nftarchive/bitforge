// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BitForge.sol";

contract BitForgeTest is Test {
    BitForge nft;

    address treasury = address(0x1001);
    address personal1 = address(0x2001);
    address personal2 = address(0x2002);
    address personal3 = address(0x2003);
    address minter = address(0x3001);

    // Fixed puzzle seed for the tests (deterministic nonces, computed offchain).
    bytes32 constant SEED = 0x1111111111111111111111111111111111111111111111111111111111111111;
    // Valid flat (20-bit) nonce for `minter` against SEED — computed offchain
    // (20 leading zero bits).
    uint256 constant MINTER_NONCE = 833880;

    // X-gate signer for the tests (fixed test key — NEVER a real key).
    uint256 constant SIGNER_PK = 0x4242424242424242424242424242424242424242424242424242424242424242;
    address signer;

    string constant BASE = "https://nftarchive.github.io/bitforge/metadata/";

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        address[] memory personal = new address[](3);
        personal[0] = personal1;
        personal[1] = personal2;
        personal[2] = personal3;
        nft = new BitForge("BitForge", "BTFG", BASE, treasury, personal, SEED, signer);
    }

    // Sign (wallet, deadline) the way the Worker does: eth-signed message
    // over mintDigest(wallet, deadline).
    function _signFor(address wallet, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = nft.mintDigest(wallet, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, _toEthSigned(digest));
        return abi.encodePacked(r, s, v);
    }

    function _toEthSigned(bytes32 digest) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
    }

    // A valid signature for `minter` with a 1-hour deadline.
    function _sig() internal view returns (uint256 deadline, bytes memory sig) {
        deadline = block.timestamp + 1 hours;
        sig = _signFor(minter, deadline);
    }

    // ---- team pre-mints (deterministic split) ----

    function testTeamPreMints() public view {
        assertEq(nft.totalSupply(), 131);
        assertEq(nft.balanceOf(treasury), 100);
        assertEq(nft.balanceOf(personal1), 11);
        assertEq(nft.balanceOf(personal2), 10);
        assertEq(nft.balanceOf(personal3), 10);
        assertEq(nft.commonMinted(), 85);
        assertEq(nft.rareMinted(), 30);
        assertEq(nft.epicMinted(), 13);
        assertEq(nft.legendaryMinted(), 3);
        // Public pool left after team pre-mints: exactly the public counts.
        assertEq(nft.commonRemaining(), 1950);
        assertEq(nft.rareRemaining(), 700);
        assertEq(nft.epicRemaining(), 300);
        assertEq(nft.legendaryRemaining(), 50);
    }

    function testTeamLegendarySplit() public view {
        // Treasury's Legendary is token 100 (C67/R22/E10 then L1).
        assertEq(nft.ownerOf(100), treasury);
        assertEq(nft.tokenRarity(100), 3);
        // Personal Legendary #1 -> token 101 (personal1), #2 -> token 102 (personal2).
        assertEq(nft.ownerOf(101), personal1);
        assertEq(nft.tokenRarity(101), 3);
        assertEq(nft.ownerOf(102), personal2);
        assertEq(nft.tokenRarity(102), 3);
        // No other personal wallet holds a Legendary at deploy.
        assertEq(nft.tokenRarity(103), 2); // personal3's first token is Epic
    }

    // ---- free mint (open to ANY wallet, PoW-gated, 1/wallet) ----

    function testFreeMintOpenToAnyWallet() public {
        assertTrue(nft.verifyProof(minter, MINTER_NONCE), "nonce must verify");
        (uint256 deadline, bytes memory sig) = _sig();
        vm.prank(minter);
        nft.mintFree(MINTER_NONCE, deadline, sig);
        assertEq(nft.balanceOf(minter), 1);
        assertEq(nft.freeMinted(), 1);
        assertTrue(nft.freeMintedBy(minter));
    }

    function testFreeMintOnePerWallet() public {
        (uint256 deadline, bytes memory sig) = _sig();
        vm.prank(minter);
        nft.mintFree(MINTER_NONCE, deadline, sig);
        vm.prank(minter);
        vm.expectRevert("free already claimed");
        nft.mintFree(MINTER_NONCE, deadline, sig);
    }

    function testBadProofReverts() public {
        (uint256 deadline, bytes memory sig) = _sig();
        vm.prank(minter);
        vm.expectRevert("bad proof");
        nft.mintFree(MINTER_NONCE + 1, deadline, sig);
    }

    // ---- X-signature gate ("cap") ----

    function testMintWithoutSignatureReverts() public {
        // A bot calling mintFree directly with no signature (empty bytes).
        vm.prank(minter);
        vm.expectRevert();
        nft.mintFree(MINTER_NONCE, block.timestamp + 1 hours, "");
    }

    function testBadSignatureReverts() public {
        // Signature from the WRONG key (not the mintSigner).
        uint256 wrongPk = 0x9999999999999999999999999999999999999999999999999999999999999999;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = nft.mintDigest(minter, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, _toEthSigned(digest));
        vm.prank(minter);
        vm.expectRevert("bad signature");
        nft.mintFree(MINTER_NONCE, deadline, abi.encodePacked(r, s, v));
    }

    function testExpiredSignatureReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signFor(minter, deadline);
        vm.warp(deadline + 1);
        vm.prank(minter);
        vm.expectRevert("signature expired");
        nft.mintFree(MINTER_NONCE, deadline, sig);
    }

    function testSignatureBoundToWallet() public {
        // A signature issued for `minter` cannot be used by another wallet.
        // `other` has its own valid proof (nonce 236314, 20 bits) so the
        // proof passes and the failure must come from the signature check.
        (uint256 deadline, bytes memory sig) = _sig();
        address other = address(0x4001);
        assertTrue(nft.verifyProof(other, 236314), "other nonce must verify");
        vm.prank(other);
        vm.expectRevert("bad signature");
        nft.mintFree(236314, deadline, sig);
    }

    function testSetMintSignerOwnerOnly() public {
        address newSigner = address(0x5001);
        vm.prank(minter);
        vm.expectRevert();
        nft.setMintSigner(newSigner);
        nft.setMintSigner(newSigner);
        assertEq(nft.mintSigner(), newSigner);
    }

    // ---- puzzle difficulty is FLAT (PUZZLE_BITS for every mint) ----

    function testPuzzleBitsFlat() public view {
        assertEq(nft.tierBits(), 20);
        assertEq(nft.tierBits(), nft.PUZZLE_BITS());
    }

    // ---- mint window + finalize ----

    function testMintWindowClosedAfterEnd() public {
        vm.warp(nft.mintEnd() + 1);
        (uint256 deadline, bytes memory sig) = _sig();
        vm.prank(minter);
        vm.expectRevert("mint window closed");
        nft.mintFree(MINTER_NONCE, deadline, sig);
    }

    function testFinalizeTimeLocked() public {
        vm.expectRevert("not ready");
        nft.finalize();
        vm.warp(nft.mintEnd() + 1);
        nft.finalize();
        assertTrue(nft.finalized());
        (uint256 deadline, bytes memory sig) = _sig();
        vm.prank(minter);
        vm.expectRevert("mint closed");
        nft.mintFree(MINTER_NONCE, deadline, sig);
    }

    // ---- metadata ----

    function testTokenURI() public view {
        assertEq(nft.tokenURI(1), string.concat(BASE, "common_1.json"));
        assertEq(nft.tokenURI(100), string.concat(BASE, "legendary_1.json"));
        assertEq(nft.tokenURI(101), string.concat(BASE, "legendary_2.json"));
    }

    // ---- owner powers ----

    function testFinalizeOwnerOnly() public {
        vm.warp(nft.mintEnd() + 1);
        vm.prank(minter);
        vm.expectRevert();
        nft.finalize();
    }

    // ---- constructor guards ----

    function testConstructorRejectsBadWallets() public {
        address[] memory personal = new address[](3);
        personal[0] = personal1;
        personal[1] = personal2;
        personal[2] = personal3;
        // zero treasury
        vm.expectRevert("zero treasury");
        new BitForge("BitForge", "BTFG", BASE, address(0), personal, SEED, signer);
        // zero mint signer
        vm.expectRevert("zero mint signer");
        new BitForge("BitForge", "BTFG", BASE, treasury, personal, SEED, address(0));
        // dup personal wallet
        personal[2] = personal1;
        vm.expectRevert("dup personal wallet");
        new BitForge("BitForge", "BTFG", BASE, treasury, personal, SEED, signer);
        // personal == treasury
        personal[2] = treasury;
        vm.expectRevert("personal == treasury");
        new BitForge("BitForge", "BTFG", BASE, treasury, personal, SEED, signer);
        // too few personal wallets
        address[] memory two = new address[](2);
        two[0] = personal1;
        two[1] = personal2;
        vm.expectRevert("need 3-5 personal wallets");
        new BitForge("BitForge", "BTFG", BASE, treasury, two, SEED, signer);
    }

    // ---- creator fee 5% enforced (ERC-2981 + operator allowlist) ----

    function testRoyaltyInfo() public view {
        assertEq(nft.ROYALTY_BPS(), 500);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, treasury);
        assertEq(amount, 0.05 ether);
        (receiver, amount) = nft.royaltyInfo(1, 0.01 ether);
        assertEq(receiver, treasury);
        assertEq(amount, 0.0005 ether);
    }

    function testRoyaltyInterfaceSupported() public view {
        // ERC-2981 interface id
        assertTrue(nft.supportsInterface(0x2a55205a));
        // ERC-721 interface id still supported
        assertTrue(nft.supportsInterface(0x80ac58cd));
    }

    function testSetOperatorAllowedOwnerOnly() public {
        address market = address(new MockMarketplace());
        nft.setOperatorAllowed(market, true);
        assertTrue(nft.operatorAllowed(market));
        vm.prank(minter);
        vm.expectRevert();
        nft.setOperatorAllowed(market, false);
    }

    function testOperatorBlocked() public {
        // Treasury owns token 1. Approve a mock marketplace (a contract).
        MockMarketplace market = new MockMarketplace();
        vm.prank(treasury);
        nft.approve(address(market), 1);
        // Non-allowlisted contract operator must revert.
        vm.expectRevert(abi.encodeWithSelector(BitForge.OperatorNotAllowed.selector, address(market)));
        market.move(address(nft), treasury, minter, 1);
        assertEq(nft.ownerOf(1), treasury);
    }

    function testOperatorAllowed() public {
        MockMarketplace market = new MockMarketplace();
        nft.setOperatorAllowed(address(market), true);
        vm.prank(treasury);
        nft.approve(address(market), 1);
        market.move(address(nft), treasury, minter, 1);
        assertEq(nft.ownerOf(1), minter);
    }

    function testOwnerSelfTransfer() public {
        // Owner moves their own NFT directly — always allowed.
        vm.prank(treasury);
        nft.transferFrom(treasury, minter, 1);
        assertEq(nft.ownerOf(1), minter);
    }

    function testEoaTransfer() public {
        // An approved EOA (not a contract) can move the NFT — always allowed.
        address helper = address(0x4001);
        vm.prank(treasury);
        nft.approve(helper, 1);
        vm.prank(helper);
        nft.transferFrom(treasury, minter, 1);
        assertEq(nft.ownerOf(1), minter);
    }
}

/// @notice Minimal mock marketplace contract (an operator) for allowlist tests.
contract MockMarketplace {
    function move(address nft, address from, address to, uint256 tokenId) external {
        BitForge(nft).transferFrom(from, to, tokenId);
    }
}
