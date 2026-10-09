-- Split Facebook like Instagram: ManyChat links (utm_medium=manychat) count as
-- "Facebook DMs (ManyChat)", every other Facebook link as "Facebook bio".
-- Same signature, so the views and report functions pick it up as is.
CREATE OR REPLACE FUNCTION enm_source_group(p_source TEXT, p_medium TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(trim(p_source), '') = '' THEN 'Direct / unknown'
    WHEN lower(p_source) IN ('kit', 'convertkit') OR lower(p_medium) = 'email' THEN 'Email'
    WHEN lower(p_source) = 'blog' THEN 'Blog'
    WHEN lower(p_source) = 'instagram' AND lower(coalesce(p_medium, '')) = 'manychat' THEN 'Instagram DMs (ManyChat)'
    WHEN lower(p_source) = 'instagram' THEN 'Instagram bio'
    WHEN lower(p_source) = 'facebook' AND lower(coalesce(p_medium, '')) = 'manychat' THEN 'Facebook DMs (ManyChat)'
    WHEN lower(p_source) = 'facebook' THEN 'Facebook bio'
    WHEN lower(p_source) = 'tiktok' THEN 'TikTok'
    WHEN lower(p_source) = 'website' THEN 'Website'
    ELSE 'Other'
  END;
$$;
