/* ===================== VISITOR TRACKING =====================
   Records every visit for the Power BI dashboard:
     - a VISIT (web_sessions)   : total, active and idle seconds, pages, clicks, device, source
     - each PAGE (page_views)   : the same timings for every page opened
     - EVENTS (website_interactions): page visits, clicks on links/buttons, bookings ...

   Active = the tab is visible AND the visitor moved, scrolled, typed or clicked in the
   last 30 seconds. Idle = everything else. The page reports its running totals every
   15 seconds and once more when it is hidden or closed. */

var GGTrack = (function () {
  var IDLE_AFTER = 30 * 1000;
  var PING_EVERY = 15 * 1000;

  var view = null;          // { id, token } once the database has registered this page
  var queue = [];           // events that happen before that
  var accessToken = null;   // the signed-in user's token, so visits are linked to them

  var total = 0;            // seconds on this page
  var active = 0;           // of which active
  var clicks = 0;
  var lastTick = Date.now();
  var lastActivity = Date.now();

  /* "/my-repo/index.html" → "/",  "/my-repo/dermalytics.htm" → "/dermalytics" */
  function pageUrl() {
    var file = location.pathname.split("/").pop().replace(/\.html?$/, "");
    return file === "" || file === "index" ? "/" : "/" + file;
  }

  function deviceType() {
    var touch = navigator.maxTouchPoints > 0;
    var width = Math.min(screen.width, screen.height);
    if (touch && width < 600) return "Mobile";
    if (touch && width < 1100) return "Tablet";
    return "Desktop";
  }

  /* where the visitor came from: ?utm_source=... first, then the referring website */
  function trafficSource() {
    var source = (new URLSearchParams(location.search).get("utm_source") || document.referrer).toLowerCase();
    if (!source || source.indexOf(location.hostname) !== -1) return "Direct";
    if (source.indexOf("instagram") !== -1) return "Instagram";
    if (source.indexOf("google") !== -1) return "Google Search";
    if (source.indexOf("whatsapp") !== -1 || source.indexOf("wa.me") !== -1) return "WhatsApp";
    if (source.indexOf("facebook") !== -1 || source.indexOf("fb.") !== -1) return "Facebook";
    if (source.indexOf("tiktok") !== -1) return "TikTok";
    return "Other";
  }

  /* call a database function directly; keepalive lets the last update finish while the page closes */
  function send(name, body, keepalive) {
    var headers = { "Content-Type": "application/json", "apikey": SUPABASE_ANON_KEY };
    if (accessToken) headers["Authorization"] = "Bearer " + accessToken;   /* signed in: link the visit to the account */

    return fetch(SUPABASE_URL + "/rest/v1/rpc/" + name, {
      method: "POST",
      keepalive: !!keepalive,
      headers: headers,
      body: JSON.stringify(body)
    }).then(function (response) {
      return response.ok ? response.json().catch(function () { return null; }) : null;
    }).catch(function () { return null; });
  }

  /* add the time since the last tick to the totals */
  function tick() {
    var now = Date.now();
    var seconds = (now - lastTick) / 1000;
    lastTick = now;
    total += seconds;
    if (!document.hidden && now - lastActivity < IDLE_AFTER) active += seconds;
  }

  function ping(keepalive) {
    tick();
    if (!view) return;
    send("track_page_ping", {
      p_page_view_id: view.id,
      p_view_token: view.token,
      p_total_seconds: Math.round(total),
      p_active_seconds: Math.round(active),
      p_click_count: clicks
    }, keepalive);
  }

  /* public: record an event, e.g. GGTrack.event("Appointment Action", { element: "confirm", pageUrl: "/book/confirm", appointmentId: 12 }) */
  function event(type, details) {
    details = details || {};
    var body = {
      p_page_view_id: null,
      p_view_token: null,
      p_interaction_type: type,
      p_element: details.element || null,
      p_page_url: details.pageUrl || null,
      p_service_id: details.serviceId || null,
      p_appointment_id: details.appointmentId || null,
      p_classification_id: details.classificationId || null
    };
    if (!view) { queue.push(body); return; }
    body.p_page_view_id = view.id;
    body.p_view_token = view.token;
    send("track_event", body);
  }

  /* a short readable name for what was clicked */
  function describe(el) {
    if (el.dataset.track) return el.dataset.track;
    var text = (el.textContent || el.getAttribute("aria-label") || el.getAttribute("alt") || "").replace(/\s+/g, " ").trim();
    return text.slice(0, 80) || el.tagName.toLowerCase();
  }

  function onClick(e) {
    clicks++;
    var el = e.target.closest("a, button, [data-track]");
    if (!el) return;

    if (el.dataset.serviceId) {
      var name = el.closest(".card").querySelector(".card-title").textContent.trim();
      event("Service Click", {
        element: "Book Now · " + name,
        pageUrl: "/services/" + name.toLowerCase().replace(/\s+/g, "-"),
        serviceId: +el.dataset.serviceId
      });
    } else if (el.href && /wa\.me|whatsapp/i.test(el.href)) {
      event("WhatsApp Redirect", { element: describe(el), pageUrl: "/contact/whatsapp" });
    } else {
      event("Click", { element: describe(el) });
    }
  }

  async function start() {
    if (!window.fetch || SUPABASE_URL.indexOf("PASTE_") === 0) return;

    try {
      var session = (await sb.auth.getSession()).data.session;
      accessToken = session ? session.access_token : null;
      sb.auth.onAuthStateChange(function (_event, newSession) {
        accessToken = newSession ? newSession.access_token : null;
      });
    } catch (e) { /* tracking works without an account */ }

    /* the clinic's own visits are not customer behaviour */
    if (accessToken) {
      try { if (await isAdmin()) return; } catch (e) {}
    }

    var sessionId = null;
    try { sessionId = sessionStorage.getItem("gg_session"); } catch (e) {}

    var rows = await send("track_page_open", {
      p_session_id: sessionId,
      p_page_url: pageUrl(),
      p_device_type: deviceType(),
      p_traffic_source: trafficSource()
    });
    if (!rows || !rows.length) return;

    try { sessionStorage.setItem("gg_session", rows[0].session_id); } catch (e) {}
    view = { id: rows[0].page_view_id, token: rows[0].view_token };

    queue.forEach(function (body) {
      body.p_page_view_id = view.id;
      body.p_view_token = view.token;
      send("track_event", body);
    });
    queue = [];
  }

  ["mousemove", "keydown", "scroll", "touchstart", "click"].forEach(function (name) {
    window.addEventListener(name, function () { lastActivity = Date.now(); }, { passive: true, capture: true });
  });
  document.addEventListener("click", onClick, true);
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) ping(true);
    else { tick(); lastActivity = Date.now(); }
  });
  window.addEventListener("pagehide", function () { ping(true); });
  setInterval(function () { ping(false); }, PING_EVERY);

  start();

  return { event: event };
})();
