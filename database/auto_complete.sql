-- =====================================================================================
-- DERMALYTICS — AUTOMATIC COMPLETION + ASSUMED CASH PAYMENTS
--
-- Run in Supabase (SQL Editor) after supabase_setup.sql. Safe to run again.
--
--   Every hour, appointments that are still "Scheduled" after their end time become
--   "Completed" (5), and each gets a payment that ASSUMES the usual case:
--       payment_status = Completed, payment_method = Cash, amount_paid = full price,
--       is_validated   = 'N'   ← "assumed, not yet confirmed by Pamela"
--
--   Pamela then (Supabase Table Editor):
--     - paid in cash as assumed:   set is_validated = Y   (or leave it)
--     - paid another way:          change payment_method  → becomes validated
--     - paid part / not paid:      change payment_status (Partial / Pending / Failed),
--                                  and for Partial type the amount_paid
--     - client never came:         set the appointment's status_id = 6 (No Show)
--                                  → its unconfirmed payment is removed
--
--   In Power BI: is_validated = 'N' means "assumed cash payment, not confirmed".
-- =====================================================================================

SET timezone = 'Asia/Beirut';

ALTER TABLE payments ALTER COLUMN payment_method DROP NOT NULL;


-- =====================================================================================
-- 1. COMPLETE PAST APPOINTMENTS
-- =====================================================================================

CREATE OR REPLACE FUNCTION public.complete_past_appointments()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_appt  RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_appt IN
        SELECT a.appointment_id, a.customer_id, a.appointment_date, a.price_charged
          FROM appointments a
         WHERE a.status_id = 1                                         -- Scheduled
           AND a.appointment_date + a.end_time <= LOCALTIMESTAMP       -- and already over
         FOR UPDATE
    LOOP
        UPDATE appointments SET status_id = 5 WHERE appointment_id = v_appt.appointment_id;

        -- BR-029: every status change is logged (NULL user = done by the system)
        INSERT INTO appointment_status_history (history_id, appointment_id, status_id, changed_at, changed_by_user_id)
        VALUES (nextval('seq_status_history'), v_appt.appointment_id, 5, LOCALTIMESTAMP, NULL);

        -- assume the usual case (paid in full, in cash) until Pamela confirms or corrects it
        IF NOT EXISTS (SELECT 1 FROM payments p
                        WHERE p.appointment_id = v_appt.appointment_id
                          AND p.payment_type = 'Service') THEN
            INSERT INTO payments (payment_id, appointment_id, customer_id, payment_type, payment_date,
                                  amount_due, discount_amount, amount_paid, payment_method,
                                  payment_status, is_validated)
            VALUES (nextval('seq_payment'), v_appt.appointment_id, v_appt.customer_id, 'Service',
                    v_appt.appointment_date, v_appt.price_charged, 0, v_appt.price_charged, 'Cash',
                    'Completed', 'N');
        END IF;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;


-- =====================================================================================
-- 2. PAMELA'S CORRECTIONS (Supabase Table Editor) KEEP THE ROW CONSISTENT
-- =====================================================================================

CREATE OR REPLACE FUNCTION public.payment_changed()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- not paid (any more): nothing was received and there is nothing to confirm
    IF NEW.payment_status IN ('Pending', 'Failed') AND OLD.payment_status IS DISTINCT FROM NEW.payment_status THEN
        NEW.amount_paid  := 0;
        NEW.is_validated := 'N';
        RETURN NEW;
    END IF;

    IF NEW.payment_status = 'Completed' THEN
        IF NEW.payment_method IS NULL THEN
            RAISE EXCEPTION 'Choose the payment method (Cash, Card, Whish, OMT, Bank Transfer) first.';
        END IF;

        -- (re)marked as paid: the full amount, unless an amount was typed
        IF OLD.payment_status IS DISTINCT FROM 'Completed' AND NEW.amount_paid = 0 THEN
            NEW.amount_paid := NEW.amount_due - NEW.discount_amount;
        END IF;

        -- Pamela touched the payment (status, method or amount): it is now confirmed
        IF OLD.payment_status IS DISTINCT FROM NEW.payment_status
           OR OLD.payment_method IS DISTINCT FROM NEW.payment_method
           OR OLD.amount_paid IS DISTINCT FROM NEW.amount_paid THEN
            NEW.is_validated := 'Y';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payment_completed ON payments;
DROP FUNCTION IF EXISTS public.payment_completed();

CREATE OR REPLACE TRIGGER trg_payment_changed
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION public.payment_changed();


-- No Show (6): log it, and remove the automatic payment if Pamela never confirmed it.
CREATE OR REPLACE FUNCTION public.appointment_no_show()
RETURNS trigger
LANGUAGE plpgsql
SET timezone = 'Asia/Beirut'
AS $$
BEGIN
    IF NEW.status_id = 6 AND OLD.status_id IS DISTINCT FROM 6 THEN
        INSERT INTO appointment_status_history (history_id, appointment_id, status_id, changed_at, changed_by_user_id)
        VALUES (nextval('seq_status_history'), NEW.appointment_id, 6, LOCALTIMESTAMP, NULL);

        DELETE FROM payments p
         WHERE p.appointment_id = NEW.appointment_id
           AND p.payment_type = 'Service'
           AND p.is_validated = 'N';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_appointment_no_show
    AFTER UPDATE OF status_id ON appointments
    FOR EACH ROW EXECUTE FUNCTION public.appointment_no_show();


-- none of this may be called from the website
REVOKE EXECUTE ON FUNCTION complete_past_appointments(), payment_changed(), appointment_no_show()
    FROM PUBLIC, anon, authenticated;


-- =====================================================================================
-- 3. PAYMENTS CREATED BY THE FIRST VERSION (Pending, no method) → assumed cash
-- =====================================================================================

ALTER TABLE payments DISABLE TRIGGER trg_payment_changed;

UPDATE payments
   SET payment_status = 'Completed',
       payment_method = 'Cash',
       amount_paid    = amount_due - discount_amount,
       is_validated   = 'N'
 WHERE payment_type = 'Service'
   AND payment_status = 'Pending'
   AND payment_method IS NULL
   AND amount_paid = 0;

ALTER TABLE payments ENABLE TRIGGER trg_payment_changed;


-- =====================================================================================
-- 4. RUN IT EVERY HOUR (pg_cron, Supabase's built-in scheduler)
-- =====================================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule('complete-past-appointments', '5 * * * *', 'SELECT public.complete_past_appointments()');

-- and once right now
SELECT public.complete_past_appointments() AS appointments_completed_now;
