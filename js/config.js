/* ===================== CONNECTION SETTINGS =====================
   Supabase → Project Settings → API.
   The project URL and the anon (publishable) key are public by design: what a visitor
   may read or do is decided by the database's security rules, not by hiding this key.
   NEVER put the service_role key here. */
var SUPABASE_URL = "https://xkqxlibjerttzwcwapqh.supabase.co";
var SUPABASE_ANON_KEY = "sb_publishable_aFtdltbGZkES0mkP2srr-g_qQUH860B";

/* The Dermalytics model API on Railway, e.g. "https://dermalytics-api.up.railway.app" */
var DERMALYTICS_API_URL = "PASTE_RAILWAY_API_URL";


/* ===================== SUPABASE CLIENT =====================
   "Remember me": a remembered sign-in is kept in localStorage (survives closing the
   browser), otherwise in sessionStorage (forgotten when the tab is closed). */
function rememberSignIn() {
  try { return localStorage.getItem("gg_remember") !== "0"; }
  catch (e) { return true; }
}

function makeClient() {
  return supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { storage: rememberSignIn() ? window.localStorage : window.sessionStorage }
  });
}

if (SUPABASE_URL.indexOf("PASTE_") === 0) {
  console.error("js/config.js: paste the Supabase project URL and anon key first.");
}

var sb = makeClient();
