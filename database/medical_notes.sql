-- =====================================================================================
-- DERMALYTICS — MEDICAL NOTES FROM THE ADMIN PAGE
--
-- Run in Supabase (SQL Editor) after test_mode.sql. Safe to run again.
--
-- Pamela searches a client on admin.htm, sees her earlier notes and adds a new one
-- (skin type, conditions, allergies, notes) → MEDICAL_HISTORY, shown in Power BI's
-- Client Profile page. Only the administrator can use these functions.
-- =====================================================================================

SET timezone = 'Asia/Beirut';

-- tag notes written during the public test like everything else
ALTER TABLE medical_history ADD COLUMN IF NOT EXISTS is_test CHAR(1) NOT NULL DEFAULT 'N';
ALTER TABLE medical_history ALTER COLUMN is_test SET DEFAULT test_mode();


-- find clients by name, phone or email
CREATE OR REPLACE FUNCTION public.admin_search_clients(p_query varchar)
RETURNS TABLE(customer_id bigint, client_name text, phone_number varchar, email varchar, notes_count bigint)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_q TEXT := '%' || LOWER(TRIM(COALESCE(p_query, ''))) || '%';
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;
    IF LENGTH(TRIM(COALESCE(p_query, ''))) < 2 THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT c.customer_id, c.first_name || ' ' || c.last_name, c.phone_number, c.email,
           (SELECT count(*) FROM medical_history m WHERE m.customer_id = c.customer_id)
      FROM customers c
     WHERE LOWER(c.first_name || ' ' || c.last_name) LIKE v_q
        OR REPLACE(c.phone_number, ' ', '') LIKE REPLACE(v_q, ' ', '')
        OR LOWER(c.email) LIKE v_q
     ORDER BY c.first_name, c.last_name
     LIMIT 15;
END;
$$;


-- a client's notes, newest first
CREATE OR REPLACE FUNCTION public.admin_client_notes(p_customer_id bigint)
RETURNS TABLE(record_id bigint, record_date date, skin_type varchar, conditions varchar, allergies varchar, notes varchar)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;

    RETURN QUERY
    SELECT m.record_id, m.record_date, m.skin_type, m.conditions, m.allergies, m.notes
      FROM medical_history m
     WHERE m.customer_id = p_customer_id
     ORDER BY m.record_date DESC, m.record_id DESC;
END;
$$;


-- add a note after a session (recorded by the specialist, staff 1 = Pamela)
CREATE OR REPLACE FUNCTION public.admin_add_medical_note(p_customer_id bigint, p_skin_type varchar, p_conditions varchar, p_allergies varchar, p_notes varchar)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_id BIGINT := nextval('seq_medical');
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'Client not found.' USING ERRCODE = 'DRM05';
    END IF;
    IF p_skin_type NOT IN ('Normal', 'Dry', 'Oily', 'Combination', 'Sensitive') THEN
        RAISE EXCEPTION 'Choose a skin type.' USING ERRCODE = 'DRM06';
    END IF;

    INSERT INTO medical_history (record_id, customer_id, record_date, skin_type, conditions, allergies, notes, recorded_by_staff_id)
    VALUES (v_id, p_customer_id, CURRENT_DATE, p_skin_type,
            LEFT(COALESCE(NULLIF(TRIM(p_conditions), ''), 'No skin concerns reported'), 200),
            LEFT(COALESCE(NULLIF(TRIM(p_allergies), ''), 'None known'), 100),
            LEFT(COALESCE(NULLIF(TRIM(p_notes), ''), '-'), 300),
            (SELECT MIN(st.staff_id) FROM staff st));

    RETURN v_id;
END;
$$;


REVOKE EXECUTE ON FUNCTION admin_search_clients(varchar), admin_client_notes(bigint),
                           admin_add_medical_note(bigint, varchar, varchar, varchar, varchar)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_search_clients(varchar), admin_client_notes(bigint),
                          admin_add_medical_note(bigint, varchar, varchar, varchar, varchar)
    TO authenticated;

SELECT 'medical notes ready' AS result;
