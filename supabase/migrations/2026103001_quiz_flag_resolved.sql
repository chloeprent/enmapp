-- "No results email" flag: an admin can mark a person as resolved by hand.
-- Adds one small admin-only table and one column at the end of the people view.

CREATE TABLE IF NOT EXISTS quiz_flag_resolved (
  email       TEXT PRIMARY KEY,
  resolved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_by TEXT DEFAULT (auth.jwt() ->> 'email')
);
ALTER TABLE quiz_flag_resolved ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON quiz_flag_resolved FROM anon, PUBLIC;
GRANT SELECT, INSERT, DELETE ON quiz_flag_resolved TO authenticated;
DROP POLICY IF EXISTS quiz_flag_resolved_admin_read ON quiz_flag_resolved;
CREATE POLICY quiz_flag_resolved_admin_read ON quiz_flag_resolved FOR SELECT TO authenticated USING (enm_is_quiz_admin());
DROP POLICY IF EXISTS quiz_flag_resolved_admin_add ON quiz_flag_resolved;
CREATE POLICY quiz_flag_resolved_admin_add ON quiz_flag_resolved FOR INSERT TO authenticated WITH CHECK (enm_is_quiz_admin());
DROP POLICY IF EXISTS quiz_flag_resolved_admin_remove ON quiz_flag_resolved;
CREATE POLICY quiz_flag_resolved_admin_remove ON quiz_flag_resolved FOR DELETE TO authenticated USING (enm_is_quiz_admin());

CREATE OR REPLACE VIEW enm_quiz_people_v WITH (security_invoker = true) AS
WITH q AS (
  SELECT
    email,
    (array_agg(first_name ORDER BY completed_at DESC) FILTER (WHERE first_name IS NOT NULL))[1] AS name,
    min(completed_at)                                              AS first_quiz_at,
    max(completed_at)                                              AS last_quiz_at,
    count(*)                                                       AS quizzes,
    (array_agg(result_uid   ORDER BY completed_at DESC))[1]        AS top_uid,
    (array_agg(result_title ORDER BY completed_at DESC))[1]        AS top_style,
    (array_agg(enm_source_group(utm_source, utm_medium) ORDER BY completed_at))[1] AS source,
    (array_agg(utm_campaign ORDER BY completed_at) FILTER (WHERE coalesce(utm_campaign, '') <> ''))[1] AS campaign,
    bool_or(pdf_clicks > 0)                                        AS saved_pdf,
    bool_or(rated)                                                 AS gave_feedback,
    bool_or(call_clicks > 0)                                       AS clicked_call
  FROM enm_quiz_runs_v
  WHERE session_id IS NOT NULL AND email IS NOT NULL
  GROUP BY email
),
b AS (
  SELECT email,
         count(*)                                AS purchases,
         sum(amount_cents)                       AS spent_cents,
         bool_or(kind = 'solo')                  AS has_solo,
         bool_or(kind = 'bundle')                AS has_bundle,
         bool_or(kind = 'conversations')         AS has_conv,
         min(purchased_at)                       AS first_purchase_at,
         array_agg(DISTINCT kind)                AS kinds
  FROM enm_quiz_purchases_v
  GROUP BY email
),
c AS (
  SELECT email, count(*) AS calls, min(booked_at) AS first_call_booked_at
  FROM enm_quiz_calls_v GROUP BY email
),
k AS (
  SELECT email,
         -- Kit only starts the non-buyer emails after the results email, so a
         -- later step also means the results email went out.
         min(at) FILTER (WHERE event IN ('results_sent', 'nb_started', 'nb_finished')) AS results_sent_at,
         min(at) FILTER (WHERE event = 'nb_started')   AS nb_started_at,
         min(at) FILTER (WHERE event = 'nb_finished')  AS nb_finished_at,
         min(at) FILTER (WHERE event = 'unsubscribed') AS unsubscribed_at
  FROM quiz_kit_events GROUP BY email
)
SELECT
  q.email, q.name, q.first_quiz_at, q.last_quiz_at, q.quizzes, q.top_uid, q.top_style,
  q.source, q.campaign, q.saved_pdf, q.gave_feedback, q.clicked_call,
  CASE
    WHEN c.calls > 0                 THEN 'Booked a call'
    WHEN b.has_bundle AND b.has_conv THEN 'Bought Bundle + 7 Conversations'
    WHEN b.has_bundle                THEN 'Bought Bundle'
    WHEN b.has_solo AND b.has_conv   THEN 'Bought Solo + 7 Conversations'
    WHEN b.has_solo                  THEN 'Bought Solo'
    WHEN b.has_conv                  THEN 'Bought 7 Conversations only'
    WHEN k.nb_finished_at IS NOT NULL THEN 'Non-buyer sequence completed'
    WHEN k.nb_started_at IS NOT NULL  THEN 'Non-buyer sequence started'
    WHEN k.results_sent_at IS NOT NULL THEN 'Results Email Sent'
    ELSE 'Quiz Completed'
  END                                            AS stage,
  coalesce(b.purchases, 0)                       AS purchases,
  coalesce(b.spent_cents, 0)                     AS spent_cents,
  b.first_purchase_at,
  CASE WHEN b.has_bundle THEN 'bundle' WHEN b.has_solo THEN 'solo'
       WHEN b.has_conv THEN 'conversations' END  AS top_purchase,
  coalesce(c.calls, 0)                           AS calls,
  c.first_call_booked_at,
  coalesce(b.kinds, '{}')                        AS bought_kinds,
  k.results_sent_at, k.nb_started_at, k.nb_finished_at, k.unsubscribed_at,
  (k.results_sent_at IS NULL AND q.first_quiz_at >= '2026-10-13T00:00:00Z'
   AND q.first_quiz_at < now() - interval '1 hour'
   AND r.email IS NULL) AS needs_attention,   -- not marked resolved by hand
  r.resolved_at AS attention_resolved_at
FROM q
LEFT JOIN b ON b.email = q.email
LEFT JOIN c ON c.email = q.email
LEFT JOIN k ON k.email = q.email
LEFT JOIN quiz_flag_resolved r ON r.email = q.email;

REVOKE ALL ON enm_quiz_people_v FROM anon, PUBLIC;
GRANT SELECT ON enm_quiz_people_v TO authenticated;

-- Mark (or un-mark) one person's flag as resolved. Admins only.
CREATE OR REPLACE FUNCTION enm_dash_resolve_flag(p_email TEXT, p_resolved BOOLEAN DEFAULT true) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;
  IF p_resolved THEN
    INSERT INTO quiz_flag_resolved (email) VALUES (lower(trim(p_email))) ON CONFLICT (email) DO NOTHING;
  ELSE
    DELETE FROM quiz_flag_resolved WHERE email = lower(trim(p_email));
  END IF;
  RETURN p_resolved;
END;
$$;
REVOKE EXECUTE ON FUNCTION enm_dash_resolve_flag(TEXT, BOOLEAN) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION enm_dash_resolve_flag(TEXT, BOOLEAN) TO authenticated;
