-- Quiz dashboard phase 3: Kit email steps, unsubscribes and poll answers.
--
-- quiz_kit_events gets one row per person and event, written only by the
-- quiz-kit function when Kit notifies it (webhooks), or when it loads poll
-- tags. The first time counts; repeats are ignored.
--   results_sent   finished "ENM Quiz Result" (one email)
--   nb_started     started  "ENM Quiz - Non Buyer Follow Up"
--   nb_finished    finished "ENM Quiz - Non Buyer Follow Up"
--   unsubscribed   unsubscribed in Kit
--   poll           a poll tag was added (detail = tag name)

CREATE TABLE IF NOT EXISTS quiz_kit_events (
  email   TEXT NOT NULL,
  event   TEXT NOT NULL CHECK (event IN ('results_sent', 'nb_started', 'nb_finished', 'unsubscribed', 'poll')),
  detail  TEXT NOT NULL DEFAULT '',
  at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (email, event, detail)
);
CREATE INDEX IF NOT EXISTS quiz_kit_events_at_idx ON quiz_kit_events (at);

ALTER TABLE quiz_kit_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS quiz_kit_events_admin_read ON quiz_kit_events;
CREATE POLICY quiz_kit_events_admin_read ON quiz_kit_events FOR SELECT TO authenticated USING (enm_is_quiz_admin());
REVOKE ALL ON quiz_kit_events FROM anon, PUBLIC;
GRANT SELECT ON quiz_kit_events TO authenticated;

-- ── People: email steps, unsubscribes and the "Needs attention" flag ───────
-- Needs attention: took the quiz (from launch on) over an hour ago and Kit has
-- not reported the results email as sent. Earlier quiz takers are not flagged,
-- because Kit only started reporting at launch.
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
         min(at) FILTER (WHERE event = 'results_sent') AS results_sent_at,
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
    WHEN k.nb_finished_at IS NOT NULL THEN 'Finished non-buyer emails (no purchase)'
    WHEN k.nb_started_at IS NOT NULL  THEN 'In non-buyer emails'
    WHEN k.results_sent_at IS NOT NULL THEN 'Results email sent'
    ELSE 'Took the quiz'
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
   AND q.first_quiz_at < now() - interval '1 hour') AS needs_attention
FROM q
LEFT JOIN b ON b.email = q.email
LEFT JOIN c ON c.email = q.email
LEFT JOIN k ON k.email = q.email;

-- ── People list: adds a flag filter (signature changes, so drop first) ─────
DROP FUNCTION IF EXISTS enm_dash_people(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, TEXT, TEXT, INT, INT, TEXT);
CREATE OR REPLACE FUNCTION enm_dash_people(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true,
  p_search TEXT DEFAULT NULL, p_stage TEXT DEFAULT NULL, p_style TEXT DEFAULT NULL,
  p_source TEXT DEFAULT NULL, p_limit INT DEFAULT 50, p_offset INT DEFAULT 0,
  p_purchase TEXT DEFAULT NULL, p_flag TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  WITH in_range AS (
    SELECT DISTINCT email FROM enm_quiz_runs_v
    WHERE session_id IS NOT NULL AND email IS NOT NULL
      AND first_at >= p_from AND first_at < p_to
  ),
  base AS (
    SELECT p.* FROM enm_quiz_people_v p JOIN in_range USING (email)
    WHERE NOT (p_exclude_tests AND enm_is_test_email(p.email))
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (coalesce(p_search, '') = ''
           OR email ILIKE '%' || p_search || '%' OR name ILIKE '%' || p_search || '%')
      AND (coalesce(p_stage, '')  = '' OR stage  = p_stage)
      AND (coalesce(p_style, '')  = '' OR top_uid = p_style)
      AND (coalesce(p_source, '') = '' OR source = p_source)
      AND (coalesce(p_purchase, '') = ''
           OR (p_purchase = 'any'  AND purchases > 0)
           OR (p_purchase = 'none' AND purchases = 0)
           OR p_purchase = ANY (bought_kinds))
      AND (coalesce(p_flag, '') = ''
           OR (p_flag = 'attention'    AND needs_attention)
           OR (p_flag = 'unsubscribed' AND unsubscribed_at IS NOT NULL))
  )
  SELECT jsonb_build_object(
    'people_total', (SELECT count(*) FROM base),
    'stages', coalesce((SELECT jsonb_object_agg(stage, n) FROM (
        SELECT stage, count(*) AS n FROM base GROUP BY stage) x), '{}'),
    'needs_attention', (SELECT count(*) FROM base WHERE needs_attention),
    'unsubscribed',    (SELECT count(*) FROM base WHERE unsubscribed_at IS NOT NULL),
    'total', (SELECT count(*) FROM filtered),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(r) - 'top_uid' - 'bought_kinds' ORDER BY r.last_quiz_at DESC) FROM (
        SELECT * FROM filtered ORDER BY last_quiz_at DESC
        LIMIT greatest(1, least(p_limit, 5000)) OFFSET greatest(0, p_offset)) r), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- ── Polls: answers by tag, in the period ───────────────────────────────────
CREATE OR REPLACE FUNCTION enm_dash_polls(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;
  SELECT coalesce(jsonb_object_agg(detail, n), '{}') INTO v_out FROM (
    SELECT detail, count(*) AS n FROM quiz_kit_events
    WHERE event = 'poll' AND at >= p_from AND at < p_to
      AND NOT (p_exclude_tests AND enm_is_test_email(email))
    GROUP BY detail) x;
  RETURN v_out;
END;
$$;

-- ── Person timeline: adds Kit steps and poll answers ───────────────────────
CREATE OR REPLACE FUNCTION enm_dash_person(p_email TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
  v_email TEXT := lower(trim(p_email));
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  WITH runs AS (
    SELECT * FROM enm_quiz_runs_v WHERE email = v_email AND session_id IS NOT NULL
  ),
  items AS (
    SELECT r.completed_at AS at,
           CASE WHEN row_number() OVER (ORDER BY r.completed_at) = 1 THEN 'Took the quiz' ELSE 'Retook the quiz' END AS what,
           r.result_title || coalesce(' (source: ' || enm_source_group(r.utm_source, r.utm_medium)
             || coalesce(', ' || nullif(r.utm_campaign, ''), '') || ')', '') AS detail
    FROM runs r
    UNION ALL
    SELECT e.created_at,
           CASE e.event
             WHEN 'save_pdf'          THEN 'Saved results as PDF'
             WHEN 'roadmap_click'     THEN 'Clicked their roadmap'
             WHEN 'book_call_click'   THEN 'Clicked Schedule a call'
             WHEN 'partner_invite_sent' THEN 'Invited a partner'
             WHEN 'result_rating'     THEN 'Rated their result'
             WHEN 'result_rating_comment' THEN 'Left a note'
           END,
           CASE e.event
             WHEN 'result_rating' THEN
               CASE e.meta ->> 'rating' WHEN 'spot_on' THEN 'Spot on' WHEN 'partly' THEN 'Partly'
                 WHEN 'not_really' THEN 'Not really' ELSE coalesce(e.meta ->> 'rating', '') END
               || coalesce(' (' || (e.meta ->> 'stars') || CASE WHEN e.meta ->> 'stars' = '1' THEN ' star)' ELSE ' stars)' END, '')
             WHEN 'result_rating_comment' THEN e.meta ->> 'comment'
             WHEN 'roadmap_click' THEN e.meta ->> 'result_title'
             ELSE NULL
           END
    FROM enm_quiz_events e
    JOIN runs r ON r.run_id = e.run_id
    WHERE e.event IN ('save_pdf', 'roadmap_click', 'book_call_click', 'partner_invite_sent',
                      'result_rating_comment')
       OR e.id IN (SELECT DISTINCT ON (x.run_id) x.id FROM enm_quiz_events x
                   JOIN runs rr ON rr.run_id = x.run_id
                   WHERE x.event = 'result_rating' ORDER BY x.run_id, x.created_at DESC)
    UNION ALL
    SELECT p.purchased_at, 'Bought ' || p.product,
           to_char(p.amount_cents / 100.0, 'FM999990.00') || ' ' || upper(coalesce(p.currency, ''))
    FROM enm_quiz_purchases_v p WHERE p.email = v_email
    UNION ALL
    SELECT c.booked_at, 'Booked a call',
           coalesce(c.booking_type, 'Call') || coalesce(', for ' || to_char(c.starts_at AT TIME ZONE 'UTC', 'Mon DD HH24:MI') || ' UTC', '')
    FROM quiz_calls c WHERE c.email = v_email AND c.booking_type ILIKE '%curiosity%'
    UNION ALL
    SELECT c.cancelled_at, 'Cancelled a call', c.booking_type
    FROM quiz_calls c WHERE c.email = v_email AND c.cancelled_at IS NOT NULL AND c.booking_type ILIKE '%curiosity%'
    UNION ALL
    SELECT k.at,
           CASE k.event
             WHEN 'results_sent' THEN 'Results email sent'
             WHEN 'nb_started'   THEN 'Started the non-buyer emails'
             WHEN 'nb_finished'  THEN 'Finished the non-buyer emails'
             WHEN 'unsubscribed' THEN 'Unsubscribed from emails'
             WHEN 'poll'         THEN 'Answered a poll'
           END,
           nullif(k.detail, '')
    FROM quiz_kit_events k WHERE k.email = v_email
  )
  SELECT jsonb_build_object(
    'person', (SELECT to_jsonb(p) - 'top_uid' - 'bought_kinds' FROM enm_quiz_people_v p WHERE p.email = v_email),
    'items', coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.at DESC) FROM items i), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

REVOKE ALL ON enm_quiz_people_v FROM anon, PUBLIC;
GRANT SELECT ON enm_quiz_people_v TO authenticated;
REVOKE EXECUTE ON FUNCTION
  enm_dash_people(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, TEXT, TEXT, INT, INT, TEXT, TEXT),
  enm_dash_polls(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN), enm_dash_person(TEXT) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION
  enm_dash_people(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, TEXT, TEXT, INT, INT, TEXT, TEXT),
  enm_dash_polls(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN), enm_dash_person(TEXT) TO authenticated;
