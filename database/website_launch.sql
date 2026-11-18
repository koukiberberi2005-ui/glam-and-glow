-- =====================================================================================
-- DERMALYTICS — THE WEBSITE STARTS ON 25 NOVEMBER 2026
--
-- Run ONCE in Supabase (SQL Editor) after profile_fields.sql.
--
-- Story of the data: until 25 Nov 2026 the clinic worked without a website (phone,
-- WhatsApp, Instagram, walk-ins). On 25 Nov 2026 the website opens for a testing phase
-- with selected people. So the historical rows must not contain website activity:
--   - historical "Website" bookings move to the clinic's other channels
--   - historical "Website" client acquisitions move to the other channels
--   - historical website accounts, website events and skin analyses are removed
-- Rows created by our own tests / testers (IS_TEST = 'Y') and real logins are kept.
--
-- Everything changed is first copied into the schema backup_20261118.
-- =====================================================================================

BEGIN;

SET LOCAL timezone = 'Asia/Beirut';

-- -------------------------------------------------------------------------------------
-- 0. BACKUP (not reachable from the website)
-- -------------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS backup_20261118;
REVOKE ALL ON SCHEMA backup_20261118 FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS backup_20261118.appointments               AS SELECT * FROM appointments;
CREATE TABLE IF NOT EXISTS backup_20261118.customers                  AS SELECT * FROM customers;
CREATE TABLE IF NOT EXISTS backup_20261118.users                      AS SELECT * FROM users;
CREATE TABLE IF NOT EXISTS backup_20261118.appointment_status_history AS SELECT * FROM appointment_status_history;
CREATE TABLE IF NOT EXISTS backup_20261118.website_interactions       AS SELECT * FROM website_interactions;
CREATE TABLE IF NOT EXISTS backup_20261118.ml_classifications         AS SELECT * FROM ml_classifications;
CREATE TABLE IF NOT EXISTS backup_20261118.image_uploads              AS SELECT * FROM image_uploads;
CREATE TABLE IF NOT EXISTS backup_20261118.system_settings            AS SELECT * FROM system_settings;

-- -------------------------------------------------------------------------------------
-- 1. Historical bookings: no website, no skin analysis
--    "Website" bookings get the channel mix of the other historical bookings
--    (WhatsApp 365 · Phone 212 · Instagram DM 165 · Walk-in 65 out of 807)
-- -------------------------------------------------------------------------------------
UPDATE appointments
   SET booking_channel = CASE
                           WHEN (appointment_id * 7919) % 807 < 365 THEN 'WhatsApp'
                           WHEN (appointment_id * 7919) % 807 < 577 THEN 'Phone'
                           WHEN (appointment_id * 7919) % 807 < 742 THEN 'Instagram DM'
                           ELSE 'Walk-in'
                         END,
       booking_reference = NULL                    -- references exist only for online bookings
 WHERE booking_channel = 'Website' AND is_test = 'N';

UPDATE appointments
   SET classification_id = NULL,
       notes = CASE WHEN notes LIKE 'Booked after ML skin analysis%' THEN NULL ELSE notes END
 WHERE classification_id IS NOT NULL AND is_test = 'N';

-- -------------------------------------------------------------------------------------
-- 2. Historical clients: not acquired through the website
--    (Instagram 183 · Referral 132 · Google Search 87 · WhatsApp 58 · TikTok 39 ·
--     Facebook 23 · Walk-in 16 out of 538)
-- -------------------------------------------------------------------------------------
UPDATE customers
   SET acquisition_channel = CASE
                               WHEN (customer_id * 7919) % 538 < 183 THEN 'Instagram'
                               WHEN (customer_id * 7919) % 538 < 315 THEN 'Referral'
                               WHEN (customer_id * 7919) % 538 < 402 THEN 'Google Search'
                               WHEN (customer_id * 7919) % 538 < 460 THEN 'WhatsApp'
                               WHEN (customer_id * 7919) % 538 < 499 THEN 'TikTok'
                               WHEN (customer_id * 7919) % 538 < 522 THEN 'Facebook'
                               ELSE 'Walk-in'
                             END
 WHERE acquisition_channel = 'Website' AND is_test = 'N';

-- -------------------------------------------------------------------------------------
-- 3. Historical website accounts: removed
--    (client accounts that never logged in; staff and real logins are kept)
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE old_accounts ON COMMIT DROP AS
SELECT u.user_id FROM users u
 WHERE u.role_id = 3 AND u.is_test = 'N' AND u.auth_id IS NULL;

UPDATE customers                  SET user_id = NULL            WHERE user_id IN (SELECT user_id FROM old_accounts);
UPDATE appointment_status_history SET changed_by_user_id = NULL WHERE changed_by_user_id IN (SELECT user_id FROM old_accounts);
DELETE FROM users WHERE user_id IN (SELECT user_id FROM old_accounts);

-- -------------------------------------------------------------------------------------
-- 4. Historical website events and skin analyses: removed
-- -------------------------------------------------------------------------------------
DELETE FROM website_interactions WHERE is_test = 'N';
DELETE FROM ml_classifications   WHERE is_test = 'N';
DELETE FROM image_uploads        WHERE is_test = 'N'
   AND image_id NOT IN (SELECT image_id FROM ml_classifications);

-- -------------------------------------------------------------------------------------
-- 5. Launch dates
-- -------------------------------------------------------------------------------------
UPDATE system_settings SET setting_value = '2026-11-25',
       description = 'Website opens for a testing phase with selected people (online booking + visit tracking start)'
 WHERE setting_key = 'WEBSITE_LAUNCH_DATE';
UPDATE system_settings SET setting_value = '2026-11-25',
       description = 'Dermalytics skin analysis available on the website'
 WHERE setting_key = 'ML_FEATURE_LAUNCH_DATE';

COMMIT;

-- -------------------------------------------------------------------------------------
-- Result
-- -------------------------------------------------------------------------------------
SELECT 'historical Website bookings left' AS check_item, count(*)::text AS n FROM appointments WHERE booking_channel = 'Website' AND is_test = 'N'
UNION ALL SELECT 'test bookings via Website (kept)', count(*)::text FROM appointments WHERE booking_channel = 'Website' AND is_test = 'Y'
UNION ALL SELECT 'historical clients acquired via Website left', count(*)::text FROM customers WHERE acquisition_channel = 'Website' AND is_test = 'N'
UNION ALL SELECT 'client accounts left (real logins)', count(*)::text FROM users WHERE role_id = 3
UNION ALL SELECT 'website events left (tests)', count(*)::text FROM website_interactions
UNION ALL SELECT 'skin analyses left (tests)', count(*)::text FROM ml_classifications
UNION ALL SELECT 'appointments in total (unchanged)', count(*)::text FROM appointments
UNION ALL SELECT 'payments in total (unchanged)', count(*)::text FROM payments
UNION ALL SELECT 'website launch date', setting_value FROM system_settings WHERE setting_key = 'WEBSITE_LAUNCH_DATE';
