-- =====================================================================================
-- DERMALYTICS — GENDER + DATE OF BIRTH, AND A LONGER CALENDAR
--
-- Run in Supabase (SQL Editor) after medical_notes.sql. Safe to run again.
--
-- 1. Clients may give their gender and date of birth (both optional) when signing up
--    or later on "My Account". AGE is kept up to date from the date of birth.
-- 2. DIM_DATE is extended to the end of 2028 (it stopped on 31 Oct 2026, so newer
--    visits and bookings showed as "(Blank)" in Power BI).
-- =====================================================================================

SET timezone = 'Asia/Beirut';

-- =====================================================================================
-- 1. GENDER + DATE OF BIRTH
-- =====================================================================================

ALTER TABLE customers ADD COLUMN IF NOT EXISTS date_of_birth DATE;

-- Gender is 'Female', 'Male' or empty ("prefer not to say"). The date of birth must be
-- realistic, and AGE always follows it.
CREATE OR REPLACE FUNCTION public.customer_profile_check()
RETURNS trigger
LANGUAGE plpgsql
SET timezone = 'Asia/Beirut'
AS $$
BEGIN
    NEW.gender := NULLIF(TRIM(NEW.gender), '');
    IF NEW.gender IS NOT NULL AND NEW.gender NOT IN ('Female', 'Male') THEN
        NEW.gender := NULL;
    END IF;

    IF NEW.date_of_birth IS NOT NULL THEN
        IF NEW.date_of_birth > CURRENT_DATE - INTERVAL '10 years' OR NEW.date_of_birth < DATE '1900-01-01' THEN
            RAISE EXCEPTION 'Please enter a valid date of birth.' USING ERRCODE = 'DRM09';
        END IF;
        NEW.age := EXTRACT(YEAR FROM age(CURRENT_DATE, NEW.date_of_birth))::SMALLINT;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_profile_check ON customers;
CREATE TRIGGER trg_customer_profile_check
    BEFORE INSERT OR UPDATE OF gender, date_of_birth ON customers
    FOR EACH ROW EXECUTE FUNCTION public.customer_profile_check();

-- a signed-in client may change these two on "My Account"
GRANT UPDATE (gender, date_of_birth) ON customers TO authenticated;


-- Sign-up trigger, updated: also takes gender + date of birth from the sign-up form.
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_first  VARCHAR(50) := LEFT(COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'first_name'), ''), SPLIT_PART(NEW.email, '@', 1)), 50);
    v_last   VARCHAR(50) := LEFT(COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'last_name'),  ''), '-'), 50);
    v_phone  VARCHAR(20) := LEFT(COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'phone'),      ''), '-'), 20);
    v_gender VARCHAR(10) := NULLIF(TRIM(NEW.raw_user_meta_data->>'gender'), '');
    v_dob    DATE;
    v_user   BIGINT;
    v_role   SMALLINT;
BEGIN
    -- an unreadable or unrealistic date is simply ignored (the client can fix it later)
    BEGIN
        v_dob := NULLIF(NEW.raw_user_meta_data->>'date_of_birth', '')::DATE;
        IF v_dob > CURRENT_DATE - INTERVAL '10 years' OR v_dob < DATE '1900-01-01' THEN
            v_dob := NULL;
        END IF;
    EXCEPTION WHEN others THEN
        v_dob := NULL;
    END;

    -- the USERS row: reuse one with the same email, otherwise create it
    SELECT u.user_id, u.role_id INTO v_user, v_role FROM users u WHERE LOWER(u.email) = LOWER(NEW.email);

    IF v_user IS NULL THEN
        v_user := nextval('seq_user');
        v_role := 3;
        INSERT INTO users (user_id, role_id, username, email, password_hash, is_active, created_at)
        VALUES (v_user, 3, LEFT(SPLIT_PART(NEW.email, '@', 1), 45) || '_' || v_user,
                NEW.email, NULL, 'Y', LOCALTIMESTAMP);
    END IF;

    UPDATE users SET auth_id = NEW.id WHERE user_id = v_user;

    -- the CUSTOMERS row (clients only): link one with the same email, otherwise create it
    IF v_role = 3 AND NOT EXISTS (SELECT 1 FROM customers c WHERE c.user_id = v_user) THEN
        UPDATE customers c
           SET user_id       = v_user,
               gender        = COALESCE(c.gender, v_gender),
               date_of_birth = COALESCE(c.date_of_birth, v_dob)
         WHERE LOWER(c.email) = LOWER(NEW.email) AND c.user_id IS NULL;

        IF NOT FOUND THEN
            INSERT INTO customers (customer_id, first_name, last_name, email, phone_number, gender, date_of_birth,
                                   user_id, registration_date, acquisition_channel, customer_status)
            VALUES (nextval('seq_customer'), v_first, v_last, NEW.email, v_phone, v_gender, v_dob,
                    v_user, CURRENT_DATE, 'Website', 'Active');
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION handle_new_auth_user(), customer_profile_check() FROM PUBLIC, anon, authenticated;


-- Ages move on every birthday: refresh them every night (pg_cron, 03:10 Beirut ≈ 00:10 UTC)
CREATE OR REPLACE FUNCTION public.refresh_customer_ages()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
    WITH changed AS (
        UPDATE customers c
           SET age = EXTRACT(YEAR FROM age(CURRENT_DATE, c.date_of_birth))::SMALLINT
         WHERE c.date_of_birth IS NOT NULL
           AND c.age IS DISTINCT FROM EXTRACT(YEAR FROM age(CURRENT_DATE, c.date_of_birth))::SMALLINT
        RETURNING 1)
    SELECT count(*)::INT FROM changed;
$$;

REVOKE EXECUTE ON FUNCTION refresh_customer_ages() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
        PERFORM cron.schedule('refresh-customer-ages', '10 0 * * *', 'SELECT public.refresh_customer_ages()');
    END IF;
END $$;


-- =====================================================================================
-- 2. CALENDAR TO THE END OF 2028 (same conventions as the existing rows: ISO weekday
--    1 = Monday, ISO week, open days from WORKING_HOURS, closures marked)
-- =====================================================================================

INSERT INTO dim_date (date_key, full_date, day_name, day_of_week, week_of_year, month_num,
                      month_name, quarter, year_num, is_open_day, is_closure)
SELECT TO_CHAR(d, 'YYYYMMDD')::INT,
       d::DATE,
       TRIM(TO_CHAR(d, 'Day')),
       EXTRACT(ISODOW FROM d)::SMALLINT,
       EXTRACT(WEEK FROM d)::SMALLINT,
       EXTRACT(MONTH FROM d)::SMALLINT,
       TRIM(TO_CHAR(d, 'Month')),
       EXTRACT(QUARTER FROM d)::SMALLINT,
       EXTRACT(YEAR FROM d)::SMALLINT,
       CASE WHEN EXISTS (SELECT 1 FROM clinic_closures cc WHERE cc.closure_date = d::DATE) THEN 'N'
            WHEN EXISTS (SELECT 1 FROM working_hours wh WHERE wh.day_of_week = EXTRACT(ISODOW FROM d) AND wh.is_open = 'Y') THEN 'Y'
            ELSE 'N' END,
       CASE WHEN EXISTS (SELECT 1 FROM clinic_closures cc WHERE cc.closure_date = d::DATE) THEN 'Y' ELSE 'N' END
  FROM (SELECT (SELECT MAX(full_date) FROM dim_date) + n AS d
          FROM generate_series(1, DATE '2028-12-31' - (SELECT MAX(full_date) FROM dim_date)) AS n) AS days
ON CONFLICT DO NOTHING;

SELECT 'profile fields ready, calendar until ' || MAX(full_date) AS result FROM dim_date;
