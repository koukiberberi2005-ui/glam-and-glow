-- =====================================================================================
-- DERMALYTICS — TWO TESTING PHASES
--
-- Run in Supabase (SQL Editor) after website_launch.sql. Safe to run again.
--
--   20 Oct 2026  internal testing: the team tests every feature (first tracked visit,
--                sign-up and booking happened that day)
--   24 Nov 2026  external testing: the link is shared with selected people on WhatsApp
--
-- Dermalytics has no launch date until the model API is online.
-- =====================================================================================

UPDATE system_settings
   SET setting_value = '2026-10-20',
       description   = 'Website live for internal testing by the team (online booking + visit tracking start)'
 WHERE setting_key = 'WEBSITE_LAUNCH_DATE';

INSERT INTO system_settings (setting_key, setting_value, description)
VALUES ('EXTERNAL_TEST_START', '2026-11-24', 'Website link shared with selected external testers')
ON CONFLICT (setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value, description = EXCLUDED.description;

UPDATE system_settings
   SET setting_value = 'Pending',
       description   = 'Dermalytics skin analysis: set to the date the model API goes online'
 WHERE setting_key = 'ML_FEATURE_LAUNCH_DATE';

SELECT setting_key, setting_value FROM system_settings
 WHERE setting_key IN ('WEBSITE_LAUNCH_DATE', 'EXTERNAL_TEST_START', 'ML_FEATURE_LAUNCH_DATE')
 ORDER BY setting_key;
