/* ===================== SHARED HELPERS (every page) ===================== */

/* the signed-in session, or null for a visitor */
async function getSession() {
  var result = await sb.auth.getSession();
  return result.data.session;
}

/* send visitors who are not signed in to the sign-in page, then back here */
async function requireSignIn() {
  var session = await getSession();
  if (!session) {
    var here = location.pathname.split("/").pop() + location.search + location.hash;
    location.href = "signin.htm?next=" + encodeURIComponent(here || "index.html");
    return null;
  }
  return session;
}

/* is the signed-in user the clinic administrator (Pamela)? */
async function isAdmin() {
  var result = await sb.rpc("is_admin");
  return result.data === true;
}

/* header button: "Sign in" for visitors, "My Account" for clients, "Admin" for Pamela */
async function updateNavAccount() {
  var cta = document.querySelector("#nav-menu .nav-cta");
  if (!cta) return;
  var session = await getSession();
  if (!session) return;

  if (await isAdmin()) {
    cta.textContent = "Admin";
    cta.href = "admin.htm";
  } else {
    cta.textContent = "My Account";
    cta.href = "account.htm";
  }
}

/* "test version" banner on every page while TEST_MODE = 'Y' in system_settings */
async function showTestBanner() {
  var result = await sb.rpc("site_test_mode");
  if (result.data !== true || document.getElementById("test-banner")) return;

  var banner = document.createElement("div");
  banner.id = "test-banner";
  banner.className = "test-banner";
  banner.textContent = "Student project · This is a test version: bookings are not real appointments.";
  document.body.prepend(banner);
}

showTestBanner();

/* hamburger menu on the pages other than index.html */
function initMenu() {
  var menuToggle = document.getElementById("menu-toggle");
  var navMenu = document.getElementById("nav-menu");
  if (!menuToggle || !navMenu) return;

  menuToggle.addEventListener("click", function () {
    navMenu.classList.toggle("open");
    menuToggle.classList.toggle("open");
    menuToggle.setAttribute("aria-expanded", navMenu.classList.contains("open"));
  });

  var header = document.getElementById("header");
  window.addEventListener("scroll", function () {
    header.classList.toggle("scrolled", window.scrollY > 40);
  });
}

/* only allow going back to a page of this site after signing in */
function safeNext(value, fallback) {
  if (value && /^[\w\-]+\.html?([?#].*)?$/.test(value)) return value;
  return fallback;
}

/* text from the database is always inserted as text, never as HTML */
function escapeHtml(value) {
  var div = document.createElement("div");
  div.textContent = value == null ? "" : String(value);
  return div.innerHTML;
}

/* "2026-11-10" → Date at local midnight (no time zone shift) */
function parseDate(iso) {
  var p = iso.split("-");
  return new Date(+p[0], +p[1] - 1, +p[2]);
}

/* Date → "2026-11-10" */
function toIsoDate(date) {
  return date.getFullYear() + "-" +
    String(date.getMonth() + 1).padStart(2, "0") + "-" +
    String(date.getDate()).padStart(2, "0");
}

/* "2026-11-10" → "Tuesday, 10 November 2026" */
function formatDate(iso) {
  return parseDate(iso).toLocaleDateString("en-GB", {
    weekday: "long", day: "numeric", month: "long", year: "numeric"
  });
}

/* "14:30:00" → "2:30 PM" */
function formatTime(time) {
  var p = time.split(":");
  var h = +p[0];
  return (h % 12 || 12) + ":" + p[1] + (h < 12 ? " AM" : " PM");
}

/* a readable message from a Supabase error */
function errorMessage(error) {
  if (!error) return "Something went wrong. Please try again.";
  return error.message || String(error);
}
