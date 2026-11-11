// BitForge — Cloudflare Worker: X OAuth proxy + mint-signature issuer (free tier, $0 API cost)
// Job: exchange authorization code -> access token, then sign a mint
// authorization for the connected wallet. The contract (BitForge.mintFree)
// requires that signature, so a bot calling the contract directly (no X
// login, no signature) reverts. Signing is done by this Worker ONLY —
// the private key never leaves Cloudflare (secret MINT_SIGNER_KEY).
//
// No X data API calls at all, so there is NO pay-per-use X API cost
// ($0.01/user-read). Login OAuth proves the user owns an X account that can
// log in; username + account age are NOT verified via API (X removed the
// free tier Feb 2026). This mode does NOT enforce 1 X = 1 wallet and does
// NOT check account age. The anti-bot weight is the signature itself:
// one real X OAuth flow per wallet, in a browser.
//
// Why a Worker is needed: X API sends no CORS headers, so the browser
// cannot call api.x.com directly. The Worker (server) has no CORS limit.
// Signing uses secp256k1 (Ethereum) via @noble/curves + @noble/hashes,
// bundled into this single file (no remote imports — Cloudflare Workers
// cannot import from URLs).
//
// DEPLOY (free, Cloudflare Workers free tier):
//   1. Cloudflare account (free) -> Workers & Pages -> Create Worker.
//   2. Paste the BUNDLED file (worker.js), Deploy.
//   3. Settings -> Variables, add secrets (NOT plain variables):
//        X_CLIENT_ID    = Client ID of the X app BitForgeHQ
//                         (developer.x.com -> app BitForge -> OAuth 2.0,
//                          type: Public client / PKCE).
//        MINT_SIGNER_KEY = private key of the mint-signer wallet
//                         (0x... — the user holds it in Bitget; never commit it).
//      The redirect URI registered in the X app MUST be:
//        https://nftarchive.github.io/bitforge/
//   4. Copy the Worker URL (e.g. https://bitforge-x.<subdomain>.workers.dev)
//      -> CONFIG.X_WORKER_URL in the mint site index.html.
//   5. Set CONFIG.X_CLIENT_ID to the same Client ID.
//
// What is returned to the site:
//   { connected: true, signature: "0x...", deadline: 1234567890 }
// The access token is NEVER sent to the browser. The signature is valid for
// 1 hour and bound to (wallet, deadline, contract, chainId) — it cannot be
// replayed for another wallet, contract, or chain. After the wallet mints
// once, the signature is useless anyway (1 mint/wallet onchain).

import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";

const SIG_TTL_SECONDS = 3600; // signature valid for 1 hour

function hexToBytes(hex) {
  const h = hex.replace(/^0x/, "");
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function bytesToHex(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, "0");
  return "0x" + s;
}

function u256ToBytes(n) {
  const out = new Uint8Array(32);
  let v = BigInt(n);
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

function concatBytes(...parts) {
  let len = 0;
  for (const p of parts) len += p.length;
  const out = new Uint8Array(len);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

// Ethereum signed message: keccak256("\x19Ethereum Signed Message:\n32" + digest)
function ethSignedHash(digest) {
  const prefix = new TextEncoder().encode("\x19Ethereum Signed Message:\n32");
  return keccak_256(concatBytes(prefix, digest));
}

// Sign (wallet, deadline, contract, chainId) exactly like
// BitForge.mintDigest: keccak256(abi.encodePacked(wallet, deadline, contract, chainId)).
// noble v2 sign() returns 64 compact bytes (r||s) with no recovery id, so the
// recovery bit is found by trial against the signer's public key.
function signMint(wallet, deadline, contract, chainId, privKeyHex) {
  const packed = concatBytes(
    hexToBytes(wallet),
    u256ToBytes(deadline),
    hexToBytes(contract),
    u256ToBytes(chainId)
  );
  const digest = keccak_256(packed);
  const msgHash = ethSignedHash(digest);
  const privKey = hexToBytes(privKeyHex);
  const sigBytes = secp256k1.sign(msgHash, privKey, { prehash: false });
  const pubKey = secp256k1.getPublicKey(privKey);
  let recovery = -1;
  for (const bit of [0, 1]) {
    const sig = secp256k1.Signature.fromBytes(sigBytes, "compact").addRecoveryBit(bit);
    const recovered = sig.recoverPublicKey(msgHash).toBytes(true);
    let same = recovered.length === pubKey.length;
    if (same) for (let i = 0; i < recovered.length; i++) if (recovered[i] !== pubKey[i]) { same = false; break; }
    if (same) { recovery = bit; break; }
  }
  if (recovery < 0) throw new Error("recovery failed");
  const r = bytesToHex(sigBytes.slice(0, 32)).slice(2);
  const s = bytesToHex(sigBytes.slice(32)).slice(2);
  const v = (recovery + 27).toString(16).padStart(2, "0");
  return "0x" + r + s + v;
}

export default {
  async fetch(request, env) {
    const ORIGIN = "https://nftarchive.github.io";
    const cors = {
      "Access-Control-Allow-Origin": ORIGIN,
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    if (request.method !== "POST") {
      return new Response(JSON.stringify({ error: "method_not_allowed" }), {
        status: 405, headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    let body;
    try { body = await request.json(); } catch {
      return new Response(JSON.stringify({ error: "bad_json" }), {
        status: 400, headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    const { code, code_verifier, redirect_uri, wallet, contract, chain_id } = body;
    if (!code || !code_verifier || !redirect_uri) {
      return new Response(JSON.stringify({ error: "missing_params" }), {
        status: 400, headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    if (!wallet || !/^0x[0-9a-fA-F]{40}$/.test(wallet)) {
      return new Response(JSON.stringify({ error: "missing_wallet" }), {
        status: 400, headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    if (!contract || !/^0x[0-9a-fA-F]{40}$/.test(contract)) {
      return new Response(JSON.stringify({ error: "missing_contract" }), {
        status: 400, headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    const chainId = Number(chain_id);
    if (!Number.isInteger(chainId) || chainId <= 0) {
      return new Response(JSON.stringify({ error: "missing_chain_id" }), {
        status: 400, headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    if (!env.MINT_SIGNER_KEY) {
      return new Response(JSON.stringify({ error: "signer_not_configured" }), {
        status: 500, headers: { ...cors, "Content-Type": "application/json" },
      });
    }

    // Exchange authorization code -> access token (public client + PKCE, no secret).
    // This is an OAuth auth endpoint — not a data call — so it costs nothing
    // on the X API. A successful exchange proves a real X login happened.
    const tokenRes = await fetch("https://api.x.com/2/oauth2/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        grant_type: "authorization_code",
        client_id: env.X_CLIENT_ID,
        redirect_uri,
        code_verifier,
      }),
    });
    const token = await tokenRes.json();
    if (!token.access_token) {
      return new Response(JSON.stringify({ error: token.error || "token_exchange_failed" }), {
        status: 400, headers: { ...cors, "Content-Type": "application/json" },
      });
    }

    // X login verified. Sign the mint authorization for this wallet.
    const deadline = Math.floor(Date.now() / 1000) + SIG_TTL_SECONDS;
    let signature;
    try {
      signature = signMint(wallet, deadline, contract, chainId, env.MINT_SIGNER_KEY);
    } catch (e) {
      return new Response(JSON.stringify({ error: "sign_failed" }), {
        status: 500, headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ connected: true, signature, deadline }), {
      headers: { ...cors, "Content-Type": "application/json" },
    });
  },
};
