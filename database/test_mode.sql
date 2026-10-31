-- =====================================================================================
-- DERMALYTICS — TEST MODE (public testing via WhatsApp)
--
-- Run in Supabase (SQL Editor) after contact.sql. Safe to run again.
--
-- One switch, SYSTEM_SETTINGS.TEST_MODE:
--   'Y'  the website shows a "test version" banner, and every new row created by the
--        website (sign-ups, bookings, visits, clicks, messages, skin analyses) gets
--        IS_TEST = 'Y'
--   'N'  no banner, new rows get IS_TEST = 'N'
--
-- To end the test:   UPDATE system_settings SET setting_value = 'N' WHERE setting_key = 'TEST_MODE';
--
-- In Power BI: filter IS_TEST = 'N' for real data, 'Y' for the testers.
-- Payments and status history have no own tag: use their appointment's IS_TEST.
-- =====================================================================================

SET timezone = 'Asia/Beirut';

-- is the website in test mode right now?
CREATE OR REPLACE FUNCTION public.test_mode()
RETURNS character
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COALESCE((SELECT CASE WHEN s.setting_value = 'Y' THEN 'Y' ELSE 'N' END
                       FROM system_settings s WHERE s.setting_key = 'TEST_MODE'), 'N')::character;
$$;

-- for the banner (any visitor may ask)
CREATE OR REPLACE FUNCTION public.site_test_mode()
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT test_mode() = 'Y';
$$;


-- -------------------------------------------------------------------------------------
-- The tag: existing rows get 'N' (TEST_MODE is still off at this point), new rows take
-- the current mode automatically.
-- -------------------------------------------------------------------------------------
ALTER TABLE users                ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE customers            ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE appointments         ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE web_sessions         ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE page_views           ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE website_interactions ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE contact_messages     ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE image_uploads        ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE ml_classifications   ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';

ALTER TABLE users                ALTER COLUMN is_test SET DEFAULT test_mode();
ALTER TABLE customers            ALTER COLUMN is_test SET DEFAULT test_mode();
ALTER TABLE appointments         ALTER COLUMN is_test SET DEFAULT test_mode();
ALTER TABLE web_sessions         ALTER COLUMN is_test SET DEFAULT test_mode();
ALTER TABLE page_views           ALTER COLUMN is_test SET DEFAULT test_mode();
ALTER TABLE website_interactions ALTER COLUMN is_test SET DEFAULT test_mode();
ALTER TABLE contact_messages     ALTER COLUMN is_test SET DEFAULT test_mode();
ALTER TABLE image_uploads        ALTER COLUMN is_test SET DEFAULT test_mode();
ALTER TABLE ml_classifications   ALTER COLUMN is_test SET DEFAULT test_mode();


-- -------------------------------------------------------------------------------------
-- Everything the website created before today was our own testing: tag it too.
-- (The generated data ends at USERS 467, CUSTOMERS 635, APPOINTMENTS 2139,
--  WEBSITE_INTERACTIONS 2000, IMAGE_UPLOADS / ML_CLASSIFICATIONS 252.)
-- Pamela's administrator account (USERS 1) stays real.
-- -------------------------------------------------------------------------------------
UPDATE users                SET is_test = 'Y' WHERE user_id > 467;
UPDATE customers            SET is_test = 'Y' WHERE customer_id > 635;
UPDATE appointments         SET is_test = 'Y' WHERE appointment_id > 2139 AND booking_channel = 'Website';
UPDATE web_sessions         SET is_test = 'Y';
UPDATE page_views           SET is_test = 'Y';
UPDATE website_interactions SET is_test = 'Y' WHERE interaction_id > 2000;
UPDATE contact_messages     SET is_test = 'Y';
UPDATE image_uploads        SET is_test = 'Y' WHERE image_id > 252;
UPDATE ml_classifications   SET is_test = 'Y' WHERE classification_id > 252;


-- -------------------------------------------------------------------------------------
-- The switch: ON for the WhatsApp test period
-- -------------------------------------------------------------------------------------
INSERT INTO system_settings (setting_key, setting_value, description)
VALUES ('TEST_MODE', 'Y', 'Y = public test: banner on the website, new rows get IS_TEST = Y')
ON CONFLICT (setting_key) DO UPDATE SET setting_value = 'Y';


-- Pamela's admin page shows which appointments are tests
DROP FUNCTION IF EXISTS public.admin_day(date);

CREATE FUNCTION public.admin_day(p_date date)
RETURNS TABLE(appointment_id bigint, appointment_time time, end_time time, booking_reference varchar,
              booking_channel varchar, status_id smallint, status_name varchar, service_name varchar,
              client_name text, client_phone varchar, client_email varchar, price_charged numeric,
              payment_id bigint, payment_status varchar, payment_method varchar, amount_paid numeric,
              is_validated character, skin_analysis varchar, is_test character)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;

    RETURN QUERY
    SELECT a.appointment_id, a.appointment_time, a.end_time, a.booking_reference, a.booking_channel,
           a.status_id, st.status_name, s.service_name,
           c.first_name || ' ' || c.last_name, c.phone_number, c.email, a.price_charged,
           p.payment_id, p.payment_status, p.payment_method, p.amount_paid, p.is_validated,
           m.predicted_class, a.is_test
      FROM appointments a
      JOIN appointment_status st ON st.status_id = a.status_id
      JOIN services s            ON s.service_id = a.service_id
      JOIN customers c           ON c.customer_id = a.customer_id
      LEFT JOIN payments p       ON p.appointment_id = a.appointment_id AND p.payment_type = 'Service'
      LEFT JOIN ml_classifications m ON m.classification_id = a.classification_id
     WHERE a.appointment_date = p_date
       AND a.status_id <> 2
     ORDER BY a.appointment_time;
END;
$$;


REVOKE EXECUTE ON FUNCTION test_mode(), site_test_mode(), admin_day(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION site_test_mode() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_day(date) TO authenticated;

SELECT 'test mode on' AS result;
