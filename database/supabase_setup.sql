-- =====================================================================================
-- DERMALYTICS — SUPABASE SETUP
--
-- Run this ONCE, after the full local database (dermalytics_full.sql) has been restored
-- into Supabase. It connects the existing database to the website:
--
--   1. Time zone           all business times are Beirut time
--   2. Booking fixes       two bugs in the original booking logic
--   3. Accounts            Supabase sign-up  ->  USERS + CUSTOMERS rows
--   4. Booking functions   book / cancel / reschedule, called from the website
--   5. Website tracking    visits, page views, active vs idle time, clicks
--   6. Dermalytics         predicted class + saving a skin analysis
--   7. Security            who may read / call what (grants + row level security)
--
-- Every function that the website calls is SECURITY DEFINER: it runs with the owner's
-- rights, so the website itself never gets direct write access to any table.
-- =====================================================================================


-- =====================================================================================
-- 1. TIME ZONE
-- Supabase servers run in UTC. Every function below also pins its own time zone, so
-- now(), CURRENT_DATE and LOCALTIMESTAMP always mean "now in Beirut".
-- =====================================================================================

DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'Asia/Beirut');
END $$;

SET timezone = 'Asia/Beirut';


-- =====================================================================================
-- 2. BOOKING FIXES
--
-- Bug 1: a rescheduled appointment (status 2) kept blocking its old time forever,
--        because status 2 was treated as "busy". Only Scheduled (1) and Completed (5)
--        appointments occupy the specialist now.
-- Bug 2: the UNIQUE (staff, date, time) constraint also counted cancelled and
--        rescheduled rows, so a cancelled 10:00 could never be booked again at 10:00.
--        Uniqueness now only applies to active appointments.
-- =====================================================================================

ALTER TABLE appointments DROP CONSTRAINT uq_appointments_staff_id_appointment_date_appointment_time;

CREATE UNIQUE INDEX uq_appointments_active_slot
    ON appointments (staff_id, appointment_date, appointment_time)
    WHERE status_id IN (1, 5);


CREATE OR REPLACE FUNCTION public.get_available_slots(p_service_id integer, p_appointment_date date)
RETURNS TABLE(start_time time without time zone, end_time time without time zone)
LANGUAGE plpgsql STABLE
SECURITY DEFINER                       -- visitors may see free times, never other people's appointments
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_open     TIME;
    v_close    TIME;
    v_duration INTERVAL;
    v_buffer   INTERVAL := make_interval(mins => setting_num('BUFFER_MINUTES', 15)::INT);
    v_step     INTERVAL := make_interval(mins => setting_num('SLOT_STEP_MINUTES', 15)::INT);
    v_lead     INTERVAL := INTERVAL '1 hour';   -- no same-day booking inside the next hour
BEGIN
    -- never offer a day in the past
    IF p_appointment_date < CURRENT_DATE THEN
        RETURN;
    END IF;

    -- closed weekday? (ISO: 1 = Monday .. 7 = Sunday)
    SELECT wh.open_time, wh.close_time
      INTO v_open, v_close
      FROM working_hours wh
     WHERE wh.day_of_week = EXTRACT(ISODOW FROM p_appointment_date)
       AND wh.is_open = 'Y';

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- public holiday or annual break?
    IF EXISTS (SELECT 1 FROM clinic_closures c WHERE c.closure_date = p_appointment_date) THEN
        RETURN;
    END IF;

    SELECT make_interval(mins => s.duration_min)
      INTO v_duration
      FROM services s
     WHERE s.service_id = p_service_id
       AND s.is_active = 'Y';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Service % is not available for booking', p_service_id
            USING ERRCODE = 'DRM03';
    END IF;

    RETURN QUERY
    WITH candidate AS (
        SELECT g::TIME                 AS s_time,
               (g + v_duration)::TIME  AS e_time,
               g                       AS s_stamp
          FROM generate_series(p_appointment_date + v_open,
                               p_appointment_date + v_close - v_duration,
                               v_step) AS g
    )
    SELECT c.s_time, c.e_time
      FROM candidate c
     WHERE c.s_stamp > LOCALTIMESTAMP + v_lead        -- not in the past, not imminent
       AND NOT EXISTS (
             SELECT 1
               FROM appointments a
              WHERE a.appointment_date = p_appointment_date
                AND a.status_id IN (1, 5)             -- Scheduled, Completed
                AND a.appointment_time < c.e_time + v_buffer
                AND a.end_time         > c.s_time - v_buffer)
     ORDER BY c.s_time;
END;
$$;


CREATE OR REPLACE FUNCTION public.create_booking(p_service_id integer, p_appointment_date date, p_appointment_time time without time zone, p_first_name character varying, p_last_name character varying, p_email character varying, p_phone character varying, p_classification_id integer DEFAULT NULL::integer, p_is_priority character DEFAULT 'N'::bpchar, p_user_id integer DEFAULT NULL::integer)
RETURNS TABLE(appointment_id bigint, booking_reference character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_duration INTEGER;
    v_price    NUMERIC(8,2);
    v_end      TIME;
    v_buffer   INTERVAL := make_interval(mins => setting_num('BUFFER_MINUTES', 15)::INT);
    v_customer BIGINT;
    v_staff    SMALLINT;
    v_appt     BIGINT;
    v_ref      VARCHAR(40);
    v_seq      INTEGER;
BEGIN
    SELECT s.duration_min, s.current_price
      INTO v_duration, v_price
      FROM services s
     WHERE s.service_id = p_service_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown service %', p_service_id USING ERRCODE = 'DRM03';
    END IF;

    v_end := p_appointment_time + make_interval(mins => v_duration);

    -- the owner-specialist: one person, one lane
    SELECT MIN(st.staff_id) INTO v_staff FROM staff st;

    ------------------------------------------------------------------------
    -- Hold the day, then re-check.
    --
    -- Between the page listing its free slots and the customer pressing book,
    -- somebody else may have taken the same time. This advisory lock is held
    -- until the transaction ends and serialises bookings for THIS DAY only, so
    -- two people booking different days never wait on each other. It works even
    -- when the day has no rows yet, which a SELECT ... FOR UPDATE would not.
    ------------------------------------------------------------------------
    PERFORM pg_advisory_xact_lock(hashtext('dermalytics_day_' || p_appointment_date::TEXT));

    IF EXISTS (SELECT 1
                 FROM appointments a
                WHERE a.appointment_date = p_appointment_date
                  AND a.status_id IN (1, 5)
                  AND a.appointment_time < v_end + v_buffer
                  AND a.end_time         > p_appointment_time - v_buffer) THEN
        RAISE EXCEPTION 'That time has just been taken. Please choose another slot.'
            USING ERRCODE = 'DRM01';
    END IF;

    IF EXISTS (SELECT 1 FROM clinic_closures c WHERE c.closure_date = p_appointment_date) THEN
        RAISE EXCEPTION 'The clinic is closed on %', p_appointment_date
            USING ERRCODE = 'DRM02';
    END IF;

    ------------------------------------------------------------------------
    -- The customer: the signed-in account's own customer row first, otherwise
    -- match an existing one on email or phone, else create (BR-001, BR-003).
    ------------------------------------------------------------------------
    IF p_user_id IS NOT NULL THEN
        SELECT c.customer_id INTO v_customer FROM customers c WHERE c.user_id = p_user_id;
    END IF;

    IF v_customer IS NULL THEN
        SELECT MIN(c.customer_id) INTO v_customer
          FROM customers c
         WHERE LOWER(c.email) = LOWER(p_email)
            OR c.phone_number = p_phone;
    END IF;

    IF v_customer IS NULL THEN
        INSERT INTO customers (customer_id, first_name, last_name, email, phone_number,
                               user_id, registration_date, acquisition_channel, customer_status)
        VALUES (nextval('seq_customer'), p_first_name, p_last_name, p_email, p_phone,
                p_user_id, CURRENT_DATE, 'Website', 'Active')
        RETURNING customers.customer_id INTO v_customer;
    END IF;

    ------------------------------------------------------------------------
    -- The appointment
    ------------------------------------------------------------------------
    v_appt := nextval('seq_appointment');

    SELECT COALESCE(MAX(SUBSTRING(a.booking_reference FROM 10)::INTEGER), 0) + 1
      INTO v_seq
      FROM appointments a
     WHERE a.booking_reference LIKE 'DRM-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-%';

    v_ref := 'DRM-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-' || LPAD(v_seq::TEXT, 5, '0');

    INSERT INTO appointments (
        appointment_id, customer_id, service_id, staff_id,
        appointment_date, appointment_time, end_time, duration_min,
        price_charged, status_id, booking_datetime, booking_channel,
        booking_reference, is_priority, classification_id, notes)
    VALUES (
        v_appt, v_customer, p_service_id, v_staff,
        p_appointment_date, p_appointment_time, v_end, v_duration,
        v_price, 1, now(), 'Website',
        v_ref, COALESCE(p_is_priority, 'N'), p_classification_id,
        CASE WHEN p_classification_id IS NOT NULL
             THEN 'Booked after ML skin analysis (recommendation only, not a diagnosis)'
        END);

    -- BR-029: every status change is logged
    INSERT INTO appointment_status_history (history_id, appointment_id, status_id,
                                            changed_at, changed_by_user_id)
    VALUES (nextval('seq_status_history'), v_appt, 1, now(), p_user_id);

    -- record the first visit once it is known
    UPDATE customers c
       SET first_visit_date = LEAST(COALESCE(c.first_visit_date, p_appointment_date),
                                    p_appointment_date)
     WHERE c.customer_id = v_customer;

    RETURN QUERY SELECT v_appt, v_ref;
END;
$$;

ALTER FUNCTION public.setting_num(character varying, numeric) SET search_path = public;


-- =====================================================================================
-- 3. ACCOUNTS
--
-- Supabase keeps logins (email + password) in its own table auth.users.
-- USERS.AUTH_ID links our USERS row to that login. Passwords are no longer stored by us,
-- so PASSWORD_HASH becomes optional (old generated rows keep theirs).
--
-- When someone signs up, the trigger below creates their USERS row (role Customer) and
-- their CUSTOMERS row from the name and phone typed on the sign-up form. If the email
-- already exists in the data, that existing row is linked instead of duplicated.
-- =====================================================================================

ALTER TABLE users ADD COLUMN auth_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_first VARCHAR(50) := LEFT(COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'first_name'), ''), SPLIT_PART(NEW.email, '@', 1)), 50);
    v_last  VARCHAR(50) := LEFT(COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'last_name'),  ''), '-'), 50);
    v_phone VARCHAR(20) := LEFT(COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'phone'),      ''), '-'), 20);
    v_user  BIGINT;
BEGIN
    -- the USERS row: reuse one with the same email, otherwise create it
    SELECT u.user_id INTO v_user FROM users u WHERE LOWER(u.email) = LOWER(NEW.email);

    IF v_user IS NULL THEN
        v_user := nextval('seq_user');
        INSERT INTO users (user_id, role_id, username, email, password_hash, is_active, created_at)
        VALUES (v_user, 3, LEFT(SPLIT_PART(NEW.email, '@', 1), 45) || '_' || v_user,
                NEW.email, NULL, 'Y', LOCALTIMESTAMP);
    END IF;

    UPDATE users SET auth_id = NEW.id WHERE user_id = v_user;

    -- the CUSTOMERS row: link one with the same email, otherwise create it
    IF NOT EXISTS (SELECT 1 FROM customers c WHERE c.user_id = v_user) THEN
        UPDATE customers c SET user_id = v_user
         WHERE LOWER(c.email) = LOWER(NEW.email) AND c.user_id IS NULL;

        IF NOT FOUND THEN
            INSERT INTO customers (customer_id, first_name, last_name, email, phone_number,
                                   user_id, registration_date, acquisition_channel, customer_status)
            VALUES (nextval('seq_customer'), v_first, v_last, NEW.email, v_phone,
                    v_user, CURRENT_DATE, 'Website', 'Active');
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();


-- The signed-in visitor's own USER_ID / CUSTOMER_ID (NULL for anonymous visitors).
-- Used by the security rules and by the functions below.
CREATE OR REPLACE FUNCTION public.my_user_id()
RETURNS bigint
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.user_id FROM users u WHERE u.auth_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.my_customer_id()
RETURNS bigint
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.customer_id
      FROM customers c
      JOIN users u ON u.user_id = c.user_id
     WHERE u.auth_id = auth.uid();
$$;


-- =====================================================================================
-- 4. BOOKING FUNCTIONS (called from the website)
--
-- Rules: one specialist, working hours + closures, 15-min buffer, 15-min slot steps,
-- nothing inside the next hour, booking requires an account, auto-confirmed.
-- Cancelling or rescheduling is always allowed before the start time; inside
-- LATE_CANCEL_HOURS (24 h) a cancellation is recorded as a Late Cancellation.
-- =====================================================================================

CREATE OR REPLACE FUNCTION public.book_appointment(p_service_id integer, p_date date, p_time time without time zone, p_classification_id bigint DEFAULT NULL)
RETURNS TABLE(appointment_id bigint, booking_reference character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_cust customers%ROWTYPE;
BEGIN
    SELECT c.* INTO v_cust FROM customers c WHERE c.customer_id = my_customer_id();

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Please sign in to book an appointment.' USING ERRCODE = 'DRM04';
    END IF;

    -- the time must be one the calendar actually offers (hours, steps, lead time, free)
    IF NOT EXISTS (SELECT 1 FROM get_available_slots(p_service_id, p_date) s
                    WHERE s.start_time = p_time) THEN
        RAISE EXCEPTION 'That time is not available. Please choose another slot.'
            USING ERRCODE = 'DRM01';
    END IF;

    -- a skin analysis may only be attached by its own customer
    IF p_classification_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM ml_classifications m
              JOIN image_uploads i ON i.image_id = m.image_id
             WHERE m.classification_id = p_classification_id
               AND i.customer_id = v_cust.customer_id) THEN
        p_classification_id := NULL;
    END IF;

    RETURN QUERY
    SELECT b.appointment_id, b.booking_reference
      FROM create_booking(p_service_id, p_date, p_time,
                          v_cust.first_name, v_cust.last_name, v_cust.email, v_cust.phone_number,
                          p_classification_id::INT, 'N', v_cust.user_id::INT) b;
END;
$$;


CREATE OR REPLACE FUNCTION public.cancel_appointment(p_appointment_id bigint)
RETURNS character varying
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_appt   appointments%ROWTYPE;
    v_status SMALLINT;
BEGIN
    SELECT a.* INTO v_appt
      FROM appointments a
     WHERE a.appointment_id = p_appointment_id
       AND a.customer_id = my_customer_id()
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found.' USING ERRCODE = 'DRM05';
    END IF;

    IF v_appt.status_id <> 1 THEN
        RAISE EXCEPTION 'Only scheduled appointments can be cancelled.' USING ERRCODE = 'DRM06';
    END IF;

    IF v_appt.appointment_date + v_appt.appointment_time <= LOCALTIMESTAMP THEN
        RAISE EXCEPTION 'This appointment has already started.' USING ERRCODE = 'DRM06';
    END IF;

    -- BR-006: inside the late window it is a Late Cancellation (4), otherwise Cancelled (3)
    IF v_appt.appointment_date + v_appt.appointment_time - LOCALTIMESTAMP
         < make_interval(hours => setting_num('LATE_CANCEL_HOURS', 24)::INT) THEN
        v_status := 4;
    ELSE
        v_status := 3;
    END IF;

    UPDATE appointments
       SET status_id = v_status, cancellation_datetime = LOCALTIMESTAMP
     WHERE appointment_id = v_appt.appointment_id;

    INSERT INTO appointment_status_history (history_id, appointment_id, status_id, changed_at, changed_by_user_id)
    VALUES (nextval('seq_status_history'), v_appt.appointment_id, v_status, LOCALTIMESTAMP, my_user_id());

    RETURN (SELECT s.status_name FROM appointment_status s WHERE s.status_id = v_status);
END;
$$;


-- Rescheduling follows the existing design (BR-028): the old row becomes Rescheduled (2)
-- and a NEW appointment row points back to it through RESCHEDULED_FROM_ID.
CREATE OR REPLACE FUNCTION public.reschedule_appointment(p_appointment_id bigint, p_new_date date, p_new_time time without time zone)
RETURNS TABLE(appointment_id bigint, booking_reference character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_old  appointments%ROWTYPE;
    v_cust customers%ROWTYPE;
    v_new  BIGINT;
    v_ref  VARCHAR(40);
BEGIN
    SELECT a.* INTO v_old
      FROM appointments a
     WHERE a.appointment_id = p_appointment_id
       AND a.customer_id = my_customer_id()
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found.' USING ERRCODE = 'DRM05';
    END IF;

    IF v_old.status_id <> 1 THEN
        RAISE EXCEPTION 'Only scheduled appointments can be rescheduled.' USING ERRCODE = 'DRM06';
    END IF;

    IF v_old.appointment_date + v_old.appointment_time <= LOCALTIMESTAMP THEN
        RAISE EXCEPTION 'This appointment has already started.' USING ERRCODE = 'DRM06';
    END IF;

    IF v_old.appointment_date = p_new_date AND v_old.appointment_time = p_new_time THEN
        RAISE EXCEPTION 'That is already your appointment time.' USING ERRCODE = 'DRM06';
    END IF;

    SELECT c.* INTO v_cust FROM customers c WHERE c.customer_id = v_old.customer_id;

    -- free the old time first, so moving by a few minutes on the same day also works
    UPDATE appointments
       SET status_id = 2,
           notes = CASE
                     WHEN v_old.appointment_date + v_old.appointment_time - LOCALTIMESTAMP
                          < make_interval(hours => setting_num('LATE_CANCEL_HOURS', 24)::INT)
                     THEN LEFT(COALESCE(notes || ' | ', '') || 'Late reschedule (less than 24 hours before)', 200)
                     ELSE notes
                   END
     WHERE appointments.appointment_id = v_old.appointment_id;

    INSERT INTO appointment_status_history (history_id, appointment_id, status_id, changed_at, changed_by_user_id)
    VALUES (nextval('seq_status_history'), v_old.appointment_id, 2, LOCALTIMESTAMP, my_user_id());

    -- the new time must be one the calendar offers (if not, everything above is undone)
    IF NOT EXISTS (SELECT 1 FROM get_available_slots(v_old.service_id, p_new_date) s
                    WHERE s.start_time = p_new_time) THEN
        RAISE EXCEPTION 'That time is not available. Please choose another slot.'
            USING ERRCODE = 'DRM01';
    END IF;

    SELECT b.appointment_id, b.booking_reference INTO v_new, v_ref
      FROM create_booking(v_old.service_id, p_new_date, p_new_time,
                          v_cust.first_name, v_cust.last_name, v_cust.email, v_cust.phone_number,
                          v_old.classification_id::INT, v_old.is_priority, v_cust.user_id::INT) b;

    UPDATE appointments SET rescheduled_from_id = v_old.appointment_id
     WHERE appointments.appointment_id = v_new;

    RETURN QUERY SELECT v_new, v_ref;
END;
$$;


-- =====================================================================================
-- 5. WEBSITE TRACKING
--
-- WEBSITE_INTERACTIONS (existing)  one row per event: Page Visit, Click, Service Click,
--                                  Appointment Action, Image Upload ...
-- WEB_SESSIONS (new)               one row per visit: total / active / idle seconds,
--                                  pages, clicks, device, traffic source
-- PAGE_VIEWS (new)                 one row per page opened during a visit, same timings
--
-- "Active" = the tab is visible AND the visitor moved, scrolled, typed or clicked in the
-- last 30 seconds. "Idle" = total - active. A visit ends after 30 minutes without activity.
--
-- Session ids continue the existing format (SES0017614, SES0017615, ...).
-- Each page view gets a random token, so a visitor can only update their own page views.
-- =====================================================================================

CREATE SEQUENCE seq_session;
SELECT setval('seq_session',
              GREATEST(COALESCE((SELECT MAX(SUBSTRING(session_id FROM 4)::INT)
                                   FROM website_interactions
                                  WHERE session_id ~ '^SES[0-9]+$'), 0), 1));

CREATE SEQUENCE seq_page_view;

CREATE TABLE web_sessions (
    session_id      VARCHAR(12)  NOT NULL,
    customer_id     BIGINT,
    started_at      TIMESTAMP    NOT NULL,
    last_seen_at    TIMESTAMP    NOT NULL,
    total_seconds   INTEGER      NOT NULL DEFAULT 0,
    active_seconds  INTEGER      NOT NULL DEFAULT 0,
    idle_seconds    INTEGER      NOT NULL DEFAULT 0,
    page_count      SMALLINT     NOT NULL DEFAULT 0,
    click_count     INTEGER      NOT NULL DEFAULT 0,
    device_type     VARCHAR(10)  NOT NULL,
    traffic_source  VARCHAR(20)  NOT NULL,
    landing_page    VARCHAR(120) NOT NULL,
    CONSTRAINT pk_web_sessions PRIMARY KEY (session_id),
    CONSTRAINT fk_web_sessions_customer_id FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT ck_web_sessions_1 CHECK (active_seconds + idle_seconds = total_seconds)
);

CREATE TABLE page_views (
    page_view_id    BIGINT       NOT NULL,
    session_id      VARCHAR(12)  NOT NULL,
    view_token      UUID         NOT NULL DEFAULT gen_random_uuid(),
    page_url        VARCHAR(120) NOT NULL,
    started_at      TIMESTAMP    NOT NULL,
    last_seen_at    TIMESTAMP    NOT NULL,
    total_seconds   INTEGER      NOT NULL DEFAULT 0,
    active_seconds  INTEGER      NOT NULL DEFAULT 0,
    idle_seconds    INTEGER      NOT NULL DEFAULT 0,
    click_count     INTEGER      NOT NULL DEFAULT 0,
    CONSTRAINT pk_page_views PRIMARY KEY (page_view_id),
    CONSTRAINT fk_page_views_session_id FOREIGN KEY (session_id) REFERENCES web_sessions(session_id),
    CONSTRAINT ck_page_views_1 CHECK (active_seconds + idle_seconds = total_seconds)
);

CREATE INDEX ix_page_views_session ON page_views (session_id);
CREATE INDEX ix_web_sessions_started ON web_sessions (started_at);

-- what exactly was clicked ("Book Now · HydraFacial", "Sign in" ...)
ALTER TABLE website_interactions ADD COLUMN element VARCHAR(80);


-- Called when a page opens. Starts a new visit if needed, records the page view and a
-- 'Page Visit' event. Returns the ids the page needs for its later updates.
CREATE OR REPLACE FUNCTION public.track_page_open(p_session_id varchar, p_page_url varchar, p_device_type varchar, p_traffic_source varchar)
RETURNS TABLE(session_id varchar, page_view_id bigint, view_token uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_session VARCHAR(12) := p_session_id;
    v_url     VARCHAR(120) := LEFT(COALESCE(NULLIF(p_page_url, ''), '/'), 120);
    v_device  VARCHAR(10) := CASE WHEN p_device_type IN ('Mobile', 'Tablet', 'Desktop') THEN p_device_type ELSE 'Desktop' END;
    v_source  VARCHAR(20) := CASE WHEN p_traffic_source IN ('Direct', 'Instagram', 'Google Search', 'WhatsApp', 'Facebook', 'TikTok', 'Other')
                                  THEN p_traffic_source ELSE 'Other' END;
    v_view    BIGINT := nextval('seq_page_view');
    v_token   UUID := gen_random_uuid();
BEGIN
    -- continue the visit only if it exists and was active in the last 30 minutes
    IF v_session IS NULL OR NOT EXISTS (
            SELECT 1 FROM web_sessions w
             WHERE w.session_id = v_session
               AND w.last_seen_at > LOCALTIMESTAMP - INTERVAL '30 minutes') THEN
        v_session := 'SES' || LPAD(nextval('seq_session')::TEXT, 7, '0');
        INSERT INTO web_sessions (session_id, customer_id, started_at, last_seen_at,
                                  device_type, traffic_source, landing_page)
        VALUES (v_session, my_customer_id(), LOCALTIMESTAMP, LOCALTIMESTAMP, v_device, v_source, v_url);
    END IF;

    INSERT INTO page_views (page_view_id, session_id, view_token, page_url, started_at, last_seen_at)
    VALUES (v_view, v_session, v_token, v_url, LOCALTIMESTAMP, LOCALTIMESTAMP);

    UPDATE web_sessions w
       SET page_count   = w.page_count + 1,
           last_seen_at = LOCALTIMESTAMP,
           customer_id  = COALESCE(w.customer_id, my_customer_id())
     WHERE w.session_id = v_session;

    INSERT INTO website_interactions (interaction_id, session_id, customer_id, interaction_datetime,
                                      interaction_type, page_url, device_type, traffic_source)
    SELECT nextval('seq_interaction'), w.session_id, w.customer_id, LOCALTIMESTAMP,
           'Page Visit', v_url, w.device_type, w.traffic_source
      FROM web_sessions w WHERE w.session_id = v_session;

    RETURN QUERY SELECT v_session, v_view, v_token;
END;
$$;


-- Called every 15 seconds and when the page is left. The page sends its running totals;
-- they can only grow and can never exceed the real time since the page opened.
CREATE OR REPLACE FUNCTION public.track_page_ping(p_page_view_id bigint, p_view_token uuid, p_total_seconds integer, p_active_seconds integer, p_click_count integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_view   page_views%ROWTYPE;
    v_max    INTEGER;
    v_total  INTEGER;
    v_active INTEGER;
BEGIN
    SELECT p.* INTO v_view FROM page_views p
     WHERE p.page_view_id = p_page_view_id AND p.view_token = p_view_token;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_max    := CEIL(EXTRACT(EPOCH FROM LOCALTIMESTAMP - v_view.started_at))::INT + 5;
    v_total  := LEAST(GREATEST(COALESCE(p_total_seconds, 0), v_view.total_seconds), v_max);
    v_active := LEAST(GREATEST(COALESCE(p_active_seconds, 0), v_view.active_seconds), v_total);

    UPDATE page_views p
       SET total_seconds  = v_total,
           active_seconds = v_active,
           idle_seconds   = v_total - v_active,
           click_count    = GREATEST(COALESCE(p_click_count, 0), p.click_count),
           last_seen_at   = LOCALTIMESTAMP
     WHERE p.page_view_id = v_view.page_view_id;

    -- the visit's totals are the sum of its pages
    UPDATE web_sessions w
       SET total_seconds  = t.total,
           active_seconds = t.active,
           idle_seconds   = t.total - t.active,
           click_count    = t.clicks,
           last_seen_at   = LOCALTIMESTAMP,
           customer_id    = COALESCE(w.customer_id, my_customer_id())
      FROM (SELECT SUM(p.total_seconds) AS total, SUM(p.active_seconds) AS active, SUM(p.click_count) AS clicks
              FROM page_views p WHERE p.session_id = v_view.session_id) t
     WHERE w.session_id = v_view.session_id;
END;
$$;


-- Called for each event worth keeping: a click on a link/button, a service "Book Now",
-- a booking / cancel / reschedule, a skin image upload.
CREATE OR REPLACE FUNCTION public.track_event(p_page_view_id bigint, p_view_token uuid, p_interaction_type varchar, p_element varchar DEFAULT NULL, p_page_url varchar DEFAULT NULL, p_service_id integer DEFAULT NULL, p_appointment_id bigint DEFAULT NULL, p_classification_id bigint DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
BEGIN
    IF p_interaction_type NOT IN ('Click', 'Service Click', 'Appointment Action', 'Image Upload', 'WhatsApp Redirect') THEN
        RETURN;
    END IF;

    INSERT INTO website_interactions (interaction_id, session_id, customer_id, interaction_datetime,
                                      interaction_type, page_url, service_id, appointment_id,
                                      classification_id, device_type, traffic_source, element)
    SELECT nextval('seq_interaction'), w.session_id, COALESCE(my_customer_id(), w.customer_id), LOCALTIMESTAMP,
           p_interaction_type, LEFT(COALESCE(NULLIF(p_page_url, ''), p.page_url), 120),
           (SELECT s.service_id FROM services s WHERE s.service_id = p_service_id),
           (SELECT a.appointment_id FROM appointments a WHERE a.appointment_id = p_appointment_id AND a.customer_id = my_customer_id()),
           (SELECT m.classification_id FROM ml_classifications m
              JOIN image_uploads i ON i.image_id = m.image_id
             WHERE m.classification_id = p_classification_id AND i.customer_id = my_customer_id()),
           w.device_type, w.traffic_source, LEFT(p_element, 80)
      FROM page_views p
      JOIN web_sessions w ON w.session_id = p.session_id
     WHERE p.page_view_id = p_page_view_id AND p.view_token = p_view_token;
END;
$$;


-- =====================================================================================
-- 6. DERMALYTICS
--
-- The model returns a disease class + confidence, so PREDICTED_CLASS is added and the
-- old urgency columns become optional (no longer filled). Below ML_CONFIDENCE_THRESHOLD
-- (0.60) the result is flagged REVIEW_REQUIRED, as before (BR-025).
--
-- save_skin_analysis is called ONLY by the Python model API (with the service key),
-- never by the browser, so nobody can store a fake prediction.
-- =====================================================================================

ALTER TABLE ml_classifications ADD COLUMN predicted_class VARCHAR(60);
ALTER TABLE ml_classifications ALTER COLUMN urgency_level DROP NOT NULL;
ALTER TABLE ml_classifications ALTER COLUMN recommended_action DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.save_skin_analysis(p_auth_id uuid, p_file_path varchar, p_file_format varchar, p_predicted_class varchar, p_confidence numeric, p_model_version varchar)
RETURNS TABLE(image_id bigint, classification_id bigint, review_required character)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_customer BIGINT;
    v_image    BIGINT := nextval('seq_image');
    v_class    BIGINT := nextval('seq_classification');
    v_conf     NUMERIC(3,2) := ROUND(p_confidence, 2);
    v_review   CHAR(1);
BEGIN
    SELECT c.customer_id INTO v_customer
      FROM customers c JOIN users u ON u.user_id = c.user_id
     WHERE u.auth_id = p_auth_id;

    IF v_customer IS NULL THEN
        RAISE EXCEPTION 'No customer for this account.' USING ERRCODE = 'DRM04';
    END IF;

    v_review := CASE WHEN v_conf < setting_num('ML_CONFIDENCE_THRESHOLD', 0.60) THEN 'Y' ELSE 'N' END;

    INSERT INTO image_uploads (image_id, customer_id, upload_datetime, file_path, file_format)
    VALUES (v_image, v_customer, LOCALTIMESTAMP, LEFT(p_file_path, 200), UPPER(LEFT(p_file_format, 10)));

    INSERT INTO ml_classifications (classification_id, image_id, classified_at, confidence_score,
                                    model_version, review_required, predicted_class)
    VALUES (v_class, v_image, LOCALTIMESTAMP, v_conf, LEFT(p_model_version, 30), v_review,
            LEFT(p_predicted_class, 60));

    RETURN QUERY SELECT v_image, v_class, v_review;
END;
$$;


-- Private storage bucket for the uploaded skin photos: skin-images/<account id>/<file>.
-- A signed-in customer can view only the photos inside their own folder.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'storage') THEN
        INSERT INTO storage.buckets (id, name, public)
        VALUES ('skin-images', 'skin-images', false)
        ON CONFLICT (id) DO NOTHING;

        EXECUTE $p$
            CREATE POLICY "customers read own skin images" ON storage.objects
                FOR SELECT TO authenticated
                USING (bucket_id = 'skin-images' AND (storage.foldername(name))[1] = auth.uid()::text)
        $p$;
    END IF;
END $$;


-- =====================================================================================
-- 7. SECURITY
--
-- Two locks on every table:
--   GRANTS              which tables / functions the website may touch at all
--   ROW LEVEL SECURITY  which ROWS of those tables (a customer sees only their own)
--
-- anon          = any visitor          authenticated = a signed-in customer
-- Everything else (payments, expenses, medical history, staff, audit, settings ...)
-- stays invisible to the website and is only reachable from Supabase / Power BI.
-- =====================================================================================

-- start from nothing
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t RECORD;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.tablename);
    END LOOP;
END $$;

-- public information: anyone may read it
GRANT SELECT ON services, working_hours, clinic_closures, appointment_status TO anon, authenticated;

CREATE POLICY "anyone reads active services"   ON services           FOR SELECT TO anon, authenticated USING (is_active = 'Y');
CREATE POLICY "anyone reads working hours"     ON working_hours      FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "anyone reads closures"          ON clinic_closures    FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "anyone reads statuses"          ON appointment_status FOR SELECT TO anon, authenticated USING (true);

-- a signed-in customer: their own profile, appointments and skin analyses
GRANT SELECT ON customers, appointments, image_uploads, ml_classifications TO authenticated;
GRANT UPDATE (first_name, last_name, phone_number) ON customers TO authenticated;

CREATE POLICY "customer reads own profile"     ON customers FOR SELECT TO authenticated USING (customer_id = my_customer_id());
CREATE POLICY "customer updates own profile"   ON customers FOR UPDATE TO authenticated USING (customer_id = my_customer_id()) WITH CHECK (customer_id = my_customer_id());
CREATE POLICY "customer reads own appointments" ON appointments FOR SELECT TO authenticated USING (customer_id = my_customer_id());
CREATE POLICY "customer reads own images"      ON image_uploads FOR SELECT TO authenticated USING (customer_id = my_customer_id());
CREATE POLICY "customer reads own analyses"    ON ml_classifications FOR SELECT TO authenticated
    USING (image_id IN (SELECT i.image_id FROM image_uploads i WHERE i.customer_id = my_customer_id()));

-- functions the website may call
GRANT EXECUTE ON FUNCTION my_user_id(), my_customer_id()                                   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_available_slots(integer, date)                               TO anon, authenticated;
GRANT EXECUTE ON FUNCTION track_page_open(varchar, varchar, varchar, varchar)              TO anon, authenticated;
GRANT EXECUTE ON FUNCTION track_page_ping(bigint, uuid, integer, integer, integer)         TO anon, authenticated;
GRANT EXECUTE ON FUNCTION track_event(bigint, uuid, varchar, varchar, varchar, integer, bigint, bigint) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION book_appointment(integer, date, time, bigint)                    TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_appointment(bigint)                                       TO authenticated;
GRANT EXECUTE ON FUNCTION reschedule_appointment(bigint, date, time)                       TO authenticated;

-- only the model API (service key) may store analyses
GRANT EXECUTE ON FUNCTION save_skin_analysis(uuid, varchar, varchar, varchar, numeric, varchar) TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
