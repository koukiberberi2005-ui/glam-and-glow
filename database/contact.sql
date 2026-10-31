-- =====================================================================================
-- DERMALYTICS — CONTACT FORM
--
-- Run in Supabase (SQL Editor) after admin.sql. Safe to run again.
--
-- Visitors send a message from the Contact section of index.html (send_contact_message).
-- Pamela reads them on admin.htm (admin_messages / admin_mark_message_read).
-- Nobody else can read the table.
-- =====================================================================================

SET timezone = 'Asia/Beirut';

CREATE SEQUENCE IF NOT EXISTS seq_contact_message;

CREATE TABLE IF NOT EXISTS contact_messages (
    message_id   BIGINT        NOT NULL DEFAULT nextval('seq_contact_message'),
    sent_at      TIMESTAMP     NOT NULL,
    full_name    VARCHAR(100)  NOT NULL,
    email        VARCHAR(120)  NOT NULL,
    phone        VARCHAR(20),
    message      VARCHAR(1000) NOT NULL,
    customer_id  BIGINT,
    is_read      CHAR(1)       NOT NULL DEFAULT 'N',
    CONSTRAINT pk_contact_messages PRIMARY KEY (message_id),
    CONSTRAINT fk_contact_messages_customer_id FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT ck_contact_messages_1 CHECK (is_read IN ('Y', 'N'))
);

CREATE INDEX IF NOT EXISTS ix_contact_messages_sent ON contact_messages (sent_at);

ALTER TABLE contact_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON contact_messages FROM anon, authenticated;
REVOKE ALL ON SEQUENCE seq_contact_message FROM anon, authenticated;


-- A visitor sends a message (linked to their customer row when signed in).
CREATE OR REPLACE FUNCTION public.send_contact_message(p_full_name varchar, p_email varchar, p_phone varchar, p_message varchar)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'Asia/Beirut'
AS $$
DECLARE
    v_name    VARCHAR(100) := LEFT(TRIM(p_full_name), 100);
    v_email   VARCHAR(120) := LOWER(LEFT(TRIM(p_email), 120));
    v_message VARCHAR(1000) := LEFT(TRIM(p_message), 1000);
BEGIN
    IF COALESCE(v_name, '') = '' OR COALESCE(v_message, '') = '' THEN
        RAISE EXCEPTION 'Please enter your name and a message.' USING ERRCODE = 'DRM08';
    END IF;
    IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'Please enter a valid email address.' USING ERRCODE = 'DRM08';
    END IF;

    -- protection against flooding: at most 5 messages per email per hour
    IF (SELECT count(*) FROM contact_messages m
         WHERE m.email = v_email AND m.sent_at > LOCALTIMESTAMP - INTERVAL '1 hour') >= 5 THEN
        RAISE EXCEPTION 'You have sent several messages already. Please wait a little or call us.' USING ERRCODE = 'DRM08';
    END IF;

    INSERT INTO contact_messages (sent_at, full_name, email, phone, message, customer_id)
    VALUES (LOCALTIMESTAMP, v_name, v_email, NULLIF(LEFT(TRIM(p_phone), 20), ''), v_message, my_customer_id());
END;
$$;


-- Pamela: the latest messages, unread first.
CREATE OR REPLACE FUNCTION public.admin_messages()
RETURNS TABLE(message_id bigint, sent_at timestamp, full_name varchar, email varchar, phone varchar, message varchar, is_read character)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;

    RETURN QUERY
    SELECT m.message_id, m.sent_at, m.full_name, m.email, m.phone, m.message, m.is_read
      FROM contact_messages m
     ORDER BY m.is_read, m.sent_at DESC
     LIMIT 50;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_mark_message_read(p_message_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;
    UPDATE contact_messages SET is_read = 'Y' WHERE message_id = p_message_id;
END;
$$;


REVOKE EXECUTE ON FUNCTION send_contact_message(varchar, varchar, varchar, varchar), admin_messages(), admin_mark_message_read(bigint)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION send_contact_message(varchar, varchar, varchar, varchar) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_messages(), admin_mark_message_read(bigint) TO authenticated;

SELECT 'contact form ready' AS result;
