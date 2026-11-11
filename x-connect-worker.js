// BitForge — Cloudflare Worker: X OAuth proxy (free tier, $0 API cost)
// Tugas: tukar authorization code -> access token. SELESAI — tidak ada panggilan
// data X sama sekali, jadi TIDAK kena biaya pay-per-use X API ($0.01/user-read).
// Login OAuth membuktikan user punya akun X yang bisa login; username + umur akun
// TIDAK diverifikasi via API (X hapus free tier Feb 2026). Username diisi user
// sendiri di situs (honor system). Gate anti-bot utama tetap puzzle PoW.
//
// Kenapa perlu Worker: X API tidak mengirim header CORS, jadi browser tidak bisa
// memanggil api.x.com langsung. Worker (server) tidak kena batasan CORS.
//
// DEPLOY (gratis, Cloudflare Workers free tier):
//   1. Buat akun Cloudflare (gratis) -> Workers & Pages -> Create Worker.
//   2. Paste file ini, Deploy.
//   3. Settings -> Variables: tambah X_CLIENT_ID = Client ID aplikasi X
//      (developer.x.com -> aplikasi BitForge -> OAuth 2.0, tipe: Public client / PKCE).
//      Redirect URI yang didaftarkan di aplikasi X HARUS:
//      https://nftarchive.github.io/bitforge/
//      (Membuat aplikasi X gratis; yang bayar hanya panggilan data API — dan
//      Worker ini TIDAK memanggil data API sama sekali.)
//   4. Copy URL Worker (mis. https://bitforge-x.<subdomain>.workers.dev)
//      -> isi ke CONFIG.X_WORKER_URL di index.html situs mint.
//   5. Isi juga CONFIG.X_CLIENT_ID dengan Client ID yang sama.
//
// Yang dikembalikan ke situs: { connected: true }.
// Token akses TIDAK pernah dikirim ke browser — Worker hanya mengonfirmasi
// bahwa login X berhasil.

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
    const { code, code_verifier, redirect_uri } = body;
    if (!code || !code_verifier || !redirect_uri) {
      return new Response(JSON.stringify({ error: "missing_params" }), {
        status: 400, headers: { ...cors, "Content-Type": "application/json" },
      });
    }

    // Tukar authorization code -> access token (public client + PKCE, tanpa secret).
    // Ini endpoint auth OAuth — bukan panggilan data — jadi tidak kena biaya
    // pay-per-use X API. Kalau tukar berhasil, login X terbukti sah.
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
    return new Response(JSON.stringify({ connected: true }), {
      headers: { ...cors, "Content-Type": "application/json" },
    });
  },
};
