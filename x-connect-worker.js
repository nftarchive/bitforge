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
// Signing also needs secp256k1 (Ethereum), which the Web Crypto API does
// not provide — so ethers v6 is imported from esm.sh.
//
// DEPLOY (free, Cloudflare Workers free tier):
//   1. Cloudflare account (free) -> Workers & Pages -> Create Worker.
//   2. Paste this file, Deploy.
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

import { Wallet, solidityPackedKeccak256, getBytes } from "https://esm.sh/ethers@6.13.0";

const SIG_TTL_SECONDS = 3600; // signature valid for 1 hour

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
    // Digest must match BitForge.mintDigest(wallet, deadline):
    // keccak256(abi.encodePacked(wallet, deadline, contract, chainId)).
    const deadline = Math.floor(Date.now() / 1000) + SIG_TTL_SECONDS;
    const digest = solidityPackedKeccak256(
      ["address", "uint256", "address", "uint256"],
      [wallet, deadline, contract, chainId]
    );
    const signer = new Wallet(env.MINT_SIGNER_KEY);
    const signature = await signer.signMessage(getBytes(digest));
    return new Response(JSON.stringify({ connected: true, signature, deadline }), {
      headers: { ...cors, "Content-Type": "application/json" },
    });
  },
};
