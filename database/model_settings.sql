-- =====================================================================================
-- DERMALYTICS — SETTINGS OF THE TRAINED MODEL (EfficientNetV2-B3, run 3)
--
-- Run in Supabase (SQL Editor) after testing_phases.sql. Safe to run again.
--
-- The model's calibrated review threshold (chosen on the validation set in Colab) is 0.67:
-- below it a result is flagged "review required". The database used 0.60.
-- =====================================================================================

UPDATE system_settings SET setting_value = '0.67',
       description = 'Below this calibrated confidence the result needs a specialist review (from the Colab validation set)'
 WHERE setting_key = 'ML_CONFIDENCE_THRESHOLD';

UPDATE system_settings SET setting_value = 'derma-effnetv2b3-v3',
       description = 'Dermalytics model in production: EfficientNetV2-B3, 300 px, 11 classes (DermNet)'
 WHERE setting_key = 'ML_MODEL_VERSION';

-- the old rule had 0.60 written into it; it now follows the same 0.67
ALTER TABLE ml_classifications DROP CONSTRAINT IF EXISTS ck_ml_classifications_3;
ALTER TABLE ml_classifications ADD CONSTRAINT ck_ml_classifications_3
    CHECK ((confidence_score < 0.67) = (review_required = 'Y'));

-- predicted names like "Actinic keratosis / skin cancer (BCC)" fit comfortably
ALTER TABLE ml_classifications ALTER COLUMN predicted_class TYPE VARCHAR(60);

SELECT setting_key, setting_value FROM system_settings
 WHERE setting_key IN ('ML_CONFIDENCE_THRESHOLD', 'ML_MODEL_VERSION') ORDER BY 1;
