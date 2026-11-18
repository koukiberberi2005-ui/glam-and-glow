-- =====================================================================================
-- DERMALYTICS — READ-ONLY LOGIN FOR POWER BI
--
-- Run in Supabase (SQL Editor). Replace CHOOSE_A_PASSWORD first (keep the quotes).
--
-- powerbi_reader can only READ the tables of the public schema:
--   - no INSERT / UPDATE / DELETE anywhere
--   - not the USERS.PASSWORD_HASH column, not Supabase's own auth tables
-- Row level security stays on; this login simply gets a "may read every row" rule.
--
-- Power BI → PostgreSQL database
--   Server:   aws-0-ap-south-1.pooler.supabase.com:5432
--   Database: postgres
--   User:     powerbi_reader.xkqxlibjerttzwcwapqh
-- =====================================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'powerbi_reader') THEN
        CREATE ROLE powerbi_reader LOGIN;
    END IF;
END $$;

ALTER ROLE powerbi_reader WITH LOGIN PASSWORD 'CHOOSE_A_PASSWORD';
ALTER ROLE powerbi_reader SET default_transaction_read_only = on;   -- belt and braces: read-only sessions
ALTER ROLE powerbi_reader SET timezone = 'Asia/Beirut';

GRANT USAGE ON SCHEMA public TO powerbi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO powerbi_reader;

-- passwords stay private (old generated hashes)
REVOKE SELECT ON users FROM powerbi_reader;
GRANT SELECT (user_id, role_id, username, email, is_active, created_at, auth_id, is_test) ON users TO powerbi_reader;

-- every table: this login may read all rows
DO $$
DECLARE t RECORD;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('DROP POLICY IF EXISTS "power bi reads all" ON public.%I', t.tablename);
        EXECUTE format('CREATE POLICY "power bi reads all" ON public.%I FOR SELECT TO powerbi_reader USING (true)', t.tablename);
    END LOOP;
END $$;

SELECT 'powerbi_reader ready' AS result;
