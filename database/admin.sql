-- =====================================================================================
-- DERMALYTICS — ADMIN PAGE (admin.htm) FOR PAMELA
--
-- Run in Supabase (SQL Editor) after auto_complete.sql. Safe to run again.
--
-- Pamela is USERS row 1 with ROLE_ID = 1 (Administrator). When she signs up on the
-- website with the email stored in that row, the sign-up trigger links her login to it.
-- Every admin function first checks is_admin(), so the page is useless to anyone else.
-- =====================================================================================

SET timezone = 'Asia/Beirut';


-- =====================================================================================
-- 1. WHO IS THE ADMINISTRATOR?
-- =====================================================================================

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (SELECT 1 FROM users u
                    WHERE u.auth_id = auth.uid()
                      AND u.role_id = 1
                      AND u.is_active = 'Y');
$$;


-- Sign-up trigger, updated: staff accounts (role 1 Administrator, 2 Specialist) are not
-- clients, so they get no CUSTOMERS row.
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
    v_role  SMALLINT;
BEGIN
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


-- No Show trigger, updated: the history now records WHO made the change
-- (Pamela's user id from the admin page; NULL when changed in the Table Editor).
CREATE OR REPLACE FUNCTION public.appointment_no_show()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
BEGIN
    IF NEW.status_id = 6 AND OLD.status_id IS DISTINCT FROM 6 THEN
        INSERT INTO appointment_status_history (history_id, appointment_id, status_id, changed_at, changed_by_user_id)
        VALUES (nextval('seq_status_history'), NEW.appointment_id, 6, LOCALTIMESTAMP, my_user_id());

        DELETE FROM payments p
         WHERE p.appointment_id = NEW.appointment_id
           AND p.payment_type = 'Service'
           AND p.is_validated = 'N';
    END IF;
    RETURN NEW;
END;
$$;


-- =====================================================================================
-- 2. ONE DAY OF APPOINTMENTS, WITH CLIENT AND PAYMENT
-- =====================================================================================

CREATE OR REPLACE FUNCTION public.admin_day(p_date date)
RETURNS TABLE(appointment_id bigint, appointment_time time, end_time time, booking_reference varchar,
              booking_channel varchar, status_id smallint, status_name varchar, service_name varchar,
              client_name text, client_phone varchar, client_email varchar, price_charged numeric,
              payment_id bigint, payment_status varchar, payment_method varchar, amount_paid numeric,
              is_validated character, skin_analysis varchar)
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
           m.predicted_class
      FROM appointments a
      JOIN appointment_status st ON st.status_id = a.status_id
      JOIN services s            ON s.service_id = a.service_id
      JOIN customers c           ON c.customer_id = a.customer_id
      LEFT JOIN payments p       ON p.appointment_id = a.appointment_id AND p.payment_type = 'Service'
      LEFT JOIN ml_classifications m ON m.classification_id = a.classification_id
     WHERE a.appointment_date = p_date
       AND a.status_id <> 2                       -- the moved-away copy of a rescheduled booking
     ORDER BY a.appointment_time;
END;
$$;


-- =====================================================================================
-- 3. ATTENDANCE: Completed (5) or No Show (6)
-- =====================================================================================

CREATE OR REPLACE FUNCTION public.admin_set_attendance(p_appointment_id bigint, p_status_id smallint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_appt appointments%ROWTYPE;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;

    IF p_status_id NOT IN (5, 6) THEN
        RAISE EXCEPTION 'Attendance can only be Completed or No Show.' USING ERRCODE = 'DRM06';
    END IF;

    SELECT a.* INTO v_appt FROM appointments a WHERE a.appointment_id = p_appointment_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found.' USING ERRCODE = 'DRM05';
    END IF;
    IF v_appt.status_id NOT IN (1, 5, 6) THEN
        RAISE EXCEPTION 'Cancelled or rescheduled appointments cannot be changed here.' USING ERRCODE = 'DRM06';
    END IF;
    IF v_appt.appointment_date + v_appt.appointment_time > LOCALTIMESTAMP THEN
        RAISE EXCEPTION 'This appointment has not started yet.' USING ERRCODE = 'DRM06';
    END IF;
    IF v_appt.status_id = p_status_id THEN
        RETURN;
    END IF;

    -- No Show: the trigger logs it and removes the unconfirmed payment
    UPDATE appointments SET status_id = p_status_id WHERE appointment_id = v_appt.appointment_id;

    IF p_status_id = 5 THEN
        INSERT INTO appointment_status_history (history_id, appointment_id, status_id, changed_at, changed_by_user_id)
        VALUES (nextval('seq_status_history'), v_appt.appointment_id, 5, LOCALTIMESTAMP, my_user_id());

        -- same assumption as the hourly job: paid in full, in cash, not yet confirmed
        IF NOT EXISTS (SELECT 1 FROM payments p
                        WHERE p.appointment_id = v_appt.appointment_id AND p.payment_type = 'Service') THEN
            INSERT INTO payments (payment_id, appointment_id, customer_id, payment_type, payment_date,
                                  amount_due, discount_amount, amount_paid, payment_method,
                                  payment_status, is_validated)
            VALUES (nextval('seq_payment'), v_appt.appointment_id, v_appt.customer_id, 'Service',
                    v_appt.appointment_date, v_appt.price_charged, 0, v_appt.price_charged, 'Cash',
                    'Completed', 'N');
        END IF;
    END IF;
END;
$$;


-- =====================================================================================
-- 4. PAYMENT: Paid (Completed) / Partial / Not paid (Pending)
-- =====================================================================================

CREATE OR REPLACE FUNCTION public.admin_set_payment(p_appointment_id bigint, p_payment_status varchar, p_payment_method varchar, p_amount_paid numeric DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_appt    appointments%ROWTYPE;
    v_payment BIGINT;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;

    IF p_payment_status NOT IN ('Completed', 'Partial', 'Pending') THEN
        RAISE EXCEPTION 'Unknown payment status.' USING ERRCODE = 'DRM06';
    END IF;
    IF p_payment_status <> 'Pending' AND p_payment_method NOT IN ('Cash', 'Card', 'Whish', 'OMT', 'Bank Transfer') THEN
        RAISE EXCEPTION 'Choose how the client paid.' USING ERRCODE = 'DRM06';
    END IF;

    SELECT a.* INTO v_appt FROM appointments a WHERE a.appointment_id = p_appointment_id;
    IF NOT FOUND OR v_appt.status_id <> 5 THEN
        RAISE EXCEPTION 'Payments can only be recorded for completed appointments.' USING ERRCODE = 'DRM06';
    END IF;

    IF p_payment_status = 'Partial' AND (p_amount_paid IS NULL OR p_amount_paid <= 0 OR p_amount_paid >= v_appt.price_charged) THEN
        RAISE EXCEPTION 'For a partial payment, enter an amount between 0 and %.', v_appt.price_charged USING ERRCODE = 'DRM06';
    END IF;

    SELECT p.payment_id INTO v_payment FROM payments p
     WHERE p.appointment_id = v_appt.appointment_id AND p.payment_type = 'Service';

    IF v_payment IS NULL THEN
        v_payment := nextval('seq_payment');
        INSERT INTO payments (payment_id, appointment_id, customer_id, payment_type, payment_date,
                              amount_due, discount_amount, amount_paid, payment_method,
                              payment_status, is_validated)
        VALUES (v_payment, v_appt.appointment_id, v_appt.customer_id, 'Service', v_appt.appointment_date,
                v_appt.price_charged, 0, 0, NULL, 'Pending', 'N');
    END IF;

    UPDATE payments
       SET payment_status = p_payment_status,
           payment_method = CASE WHEN p_payment_status = 'Pending' THEN payment_method ELSE p_payment_method END,
           amount_paid    = CASE p_payment_status
                              WHEN 'Completed' THEN amount_due - discount_amount
                              WHEN 'Partial'   THEN p_amount_paid
                              ELSE 0 END,
           is_validated   = CASE WHEN p_payment_status = 'Pending' THEN 'N' ELSE 'Y' END
     WHERE payment_id = v_payment;
END;
$$;


-- =====================================================================================
-- 5. SECURITY
-- =====================================================================================

REVOKE EXECUTE ON FUNCTION is_admin(), admin_day(date), admin_set_attendance(bigint, smallint),
                           admin_set_payment(bigint, varchar, varchar, numeric),
                           handle_new_auth_user(), appointment_no_show()
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION is_admin(), admin_day(date), admin_set_attendance(bigint, smallint),
                          admin_set_payment(bigint, varchar, varchar, numeric)
    TO authenticated;
