/* ===================== BOOKING PICKER =====================
   A month calendar + the free times of the chosen day, for one service.
   Used by the booking section (index.html) and by "Reschedule" (account.htm).

   The calendar greys out days the clinic is closed (working_hours, clinic_closures).
   The free times come from the database function get_available_slots, which applies
   every rule: opening hours, 15-minute steps, 15-minute buffer, nothing within the
   next hour, and appointments already booked. */

var GGBooking = (function () {
  var WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  var openDays = null;   // { 1: true, 2: true ... } ISO weekday → open?
  var closures = null;   // { "2026-12-25": "Christmas" }

  async function loadClinicCalendar() {
    if (openDays) return;
    var hours = await sb.from("working_hours").select("day_of_week, is_open");
    var closed = await sb.from("clinic_closures").select("closure_date, reason").gte("closure_date", toIsoDate(new Date()));

    openDays = {};
    (hours.data || []).forEach(function (row) { openDays[row.day_of_week] = row.is_open === "Y"; });
    closures = {};
    (closed.data || []).forEach(function (row) { closures[row.closure_date] = row.reason; });
  }

  function isoWeekday(date) {
    var day = date.getDay();
    return day === 0 ? 7 : day;
  }

  /* options: { serviceId, onPick(dateIso, slot), onClear() } */
  function createPicker(root, options) {
    var today = new Date();
    today.setHours(0, 0, 0, 0);

    var month = new Date(today.getFullYear(), today.getMonth(), 1);
    var serviceId = options.serviceId || null;
    var selectedDate = null;
    var request = 0;   // ignores slow answers for a day that is no longer selected

    root.innerHTML =
      '<div class="picker">' +
        '<div class="cal">' +
          '<div class="cal-head">' +
            '<button type="button" class="cal-nav" data-dir="-1" aria-label="Previous month">&#8249;</button>' +
            '<h4 class="cal-title"></h4>' +
            '<button type="button" class="cal-nav" data-dir="1" aria-label="Next month">&#8250;</button>' +
          '</div>' +
          '<div class="cal-grid"></div>' +
        '</div>' +
        '<div class="slots">' +
          '<h4 class="slots-title">Choose a day</h4>' +
          '<div class="slots-grid"></div>' +
        '</div>' +
      '</div>';

    var title = root.querySelector(".cal-title");
    var grid = root.querySelector(".cal-grid");
    var slotsTitle = root.querySelector(".slots-title");
    var slotsGrid = root.querySelector(".slots-grid");
    var prevBtn = root.querySelector('.cal-nav[data-dir="-1"]');

    root.querySelectorAll(".cal-nav").forEach(function (btn) {
      btn.addEventListener("click", function () {
        month = new Date(month.getFullYear(), month.getMonth() + (+btn.dataset.dir), 1);
        renderCalendar();
      });
    });

    function dayState(date) {
      var iso = toIsoDate(date);
      if (date < today) return { open: false, reason: "Past" };
      if (closures[iso]) return { open: false, reason: closures[iso] };
      if (!openDays[isoWeekday(date)]) return { open: false, reason: "Closed" };
      return { open: true };
    }

    function renderCalendar() {
      title.textContent = month.toLocaleDateString("en-GB", { month: "long", year: "numeric" });
      prevBtn.disabled = month <= new Date(today.getFullYear(), today.getMonth(), 1);

      var html = WEEKDAYS.map(function (d) { return '<span class="cal-weekday">' + d + "</span>"; }).join("");

      var blanks = isoWeekday(month) - 1;
      for (var b = 0; b < blanks; b++) html += "<span></span>";

      var days = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
      for (var d = 1; d <= days; d++) {
        var date = new Date(month.getFullYear(), month.getMonth(), d);
        var iso = toIsoDate(date);
        var state = dayState(date);
        var classes = "cal-day" + (iso === selectedDate ? " selected" : "") + (iso === toIsoDate(today) ? " today" : "");
        html += '<button type="button" class="' + classes + '" data-date="' + iso + '"' +
          (state.open && serviceId ? "" : " disabled") +
          (state.reason ? ' title="' + escapeHtml(state.reason) + '"' : "") + ">" + d + "</button>";
      }
      grid.innerHTML = html;

      grid.querySelectorAll(".cal-day:not([disabled])").forEach(function (btn) {
        btn.addEventListener("click", function () { selectDate(btn.dataset.date); });
      });
    }

    async function selectDate(iso) {
      selectedDate = iso;
      renderCalendar();
      if (options.onClear) options.onClear();

      var mine = ++request;
      slotsTitle.textContent = formatDate(iso);
      slotsGrid.innerHTML = '<p class="slots-note">Loading free times…</p>';

      var result = await sb.rpc("get_available_slots", { p_service_id: serviceId, p_appointment_date: iso });
      if (mine !== request) return;

      if (result.error) {
        slotsGrid.innerHTML = '<p class="slots-note">' + escapeHtml(errorMessage(result.error)) + "</p>";
        return;
      }
      if (!result.data.length) {
        slotsGrid.innerHTML = '<p class="slots-note">No free times left on this day. Please choose another day.</p>';
        return;
      }

      slotsGrid.innerHTML = result.data.map(function (slot, i) {
        return '<button type="button" class="slot" data-i="' + i + '">' + formatTime(slot.start_time) + "</button>";
      }).join("");

      slotsGrid.querySelectorAll(".slot").forEach(function (btn) {
        btn.addEventListener("click", function () {
          slotsGrid.querySelectorAll(".slot").forEach(function (s) { s.classList.remove("selected"); });
          btn.classList.add("selected");
          options.onPick(iso, result.data[+btn.dataset.i]);
        });
      });
    }

    function reset() {
      selectedDate = null;
      slotsTitle.textContent = serviceId ? "Choose a day" : "Choose a treatment first";
      slotsGrid.innerHTML = "";
      renderCalendar();
    }

    var ready = loadClinicCalendar().then(reset);

    return {
      /* switch to another treatment: the chosen day stays, its times are reloaded */
      setService: function (id) {
        return ready.then(function () {
          serviceId = id;
          if (selectedDate) selectDate(selectedDate);
          else reset();
        });
      },
      /* reopen a day (e.g. after signing in to finish a booking) */
      selectDate: function (iso) {
        return ready.then(function () {
          var date = parseDate(iso);
          month = new Date(date.getFullYear(), date.getMonth(), 1);
          return selectDate(iso);
        });
      },
      /* reload the times of the selected day (after a booking took one) */
      refresh: function () {
        if (selectedDate) return selectDate(selectedDate);
      }
    };
  }

  return { createPicker: createPicker };
})();
