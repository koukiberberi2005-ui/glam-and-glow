-- =====================================================================================
-- DERMALYTICS — CLIENT PHOTOS ON THE ADMIN PAGE
--
-- Run in Supabase (SQL Editor) after model_settings.sql. Safe to run again.
--
-- When Pamela opens a client on admin.htm she also sees the photos the client analysed
-- on the Dermalytics page, with the model's result. The photos stay in the private
-- "skin-images" bucket: only the client herself and the administrator can open them.
-- =====================================================================================

-- a client's Dermalytics analyses, newest first
CREATE OR REPLACE FUNCTION public.admin_client_analyses(p_customer_id bigint)
RETURNS TABLE(classification_id bigint, uploaded_at timestamp, file_path varchar,
              predicted_class varchar, confidence numeric, review_required character)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only the clinic administrator can do this.' USING ERRCODE = 'DRM07';
    END IF;

    RETURN QUERY
    SELECT m.classification_id, i.upload_datetime, i.file_path,
           m.predicted_class, m.confidence_score, m.review_required
      FROM image_uploads i
      JOIN ml_classifications m ON m.image_id = i.image_id
     WHERE i.customer_id = p_customer_id
     ORDER BY i.upload_datetime DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_client_analyses(bigint) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION admin_client_analyses(bigint) TO authenticated;


-- the administrator may view every photo in the private bucket (clients: only their own)
DROP POLICY IF EXISTS "admin reads all skin images" ON storage.objects;
CREATE POLICY "admin reads all skin images" ON storage.objects
    FOR SELECT TO authenticated
    USING (bucket_id = 'skin-images' AND public.is_admin());

SELECT 'admin photos ready' AS result;
