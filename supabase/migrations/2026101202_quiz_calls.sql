-- Quiz dashboard phase 3: call bookings from TidyCal.
--
-- quiz_calls keeps one row per TidyCal booking, written only by the quiz-calls
-- function (service role), which runs every 15 minutes. The CRM's own
-- tidycal-sync and its tables are not touched.
--
-- A call counts for the quiz when it is a curiosity call (not a paid coaching
-- session), was not cancelled, and the person took the quiz or bought a
-- roadmap before booking it.

CREATE TABLE IF NOT EXISTS quiz_calls (
  booking_id    TEXT PRIMARY KEY,
  email         TEXT,                 -- lowercased
  name          TEXT,
  booking_type  TEXT,
  booked_at     TIMESTAMPTZ NOT NULL, -- when they booked
  starts_at     TIMESTAMPTZ,          -- when the call is
  cancelled_at  TIMESTAMPTZ,
  synced_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS quiz_calls_email_idx ON quiz_calls (email);
CREATE INDEX IF NOT EXISTS quiz_calls_booked_idx ON quiz_calls (booked_at);

ALTER TABLE quiz_calls ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS quiz_calls_admin_read ON quiz_calls;
CREATE POLICY quiz_calls_admin_read ON quiz_calls FOR SELECT TO authenticated USING (enm_is_quiz_admin());
REVOKE ALL ON quiz_calls FROM anon, PUBLIC;
GRANT SELECT ON quiz_calls TO authenticated;

-- Calls that count: curiosity calls, not cancelled, booked after the person's
-- first quiz or first purchase.
CREATE OR REPLACE VIEW enm_quiz_calls_v WITH (security_invoker = true) AS
WITH firsts AS (
  SELECT email, min(at) AS first_at FROM (
    SELECT email, completed_at AS at FROM enm_quiz_runs_v WHERE session_id IS NOT NULL AND email IS NOT NULL
    UNION ALL
    SELECT email, purchased_at FROM enm_quiz_purchases_v WHERE email IS NOT NULL
  ) x GROUP BY email
)
SELECT c.booking_id, c.email, c.name, c.booking_type, c.booked_at, c.starts_at
FROM quiz_calls c
JOIN firsts f ON f.email = c.email AND c.booked_at >= f.first_at
WHERE c.cancelled_at IS NULL AND c.booking_type ILIKE '%curiosity%';

-- ── People: "Booked a call" is the furthest stage ──────────────────────────
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
    ELSE 'Took the quiz'
  END                                            AS stage,
  coalesce(b.purchases, 0)                       AS purchases,
  coalesce(b.spent_cents, 0)                     AS spent_cents,
  b.first_purchase_at,
  CASE WHEN b.has_bundle THEN 'bundle' WHEN b.has_solo THEN 'solo'
       WHEN b.has_conv THEN 'conversations' END  AS top_purchase,
  coalesce(c.calls, 0)                           AS calls,
  c.first_call_booked_at,
  coalesce(b.kinds, '{}')                        AS bought_kinds
FROM q
LEFT JOIN b ON b.email = q.email
LEFT JOIN c ON c.email = q.email;

-- ── People list: the purchase filter looks at what they bought, not the stage
-- (a buyer who later books a call is still a buyer).
CREATE OR REPLACE FUNCTION enm_dash_people(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true,
  p_search TEXT DEFAULT NULL, p_stage TEXT DEFAULT NULL, p_style TEXT DEFAULT NULL,
  p_source TEXT DEFAULT NULL, p_limit INT DEFAULT 50, p_offset INT DEFAULT 0,
  p_purchase TEXT DEFAULT NULL
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
  )
  SELECT jsonb_build_object(
    'people_total', (SELECT count(*) FROM base),
    'stages', coalesce((SELECT jsonb_object_agg(stage, n) FROM (
        SELECT stage, count(*) AS n FROM base GROUP BY stage) x), '{}'),
    'total', (SELECT count(*) FROM filtered),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(r) - 'top_uid' - 'bought_kinds' ORDER BY r.last_quiz_at DESC) FROM (
        SELECT * FROM filtered ORDER BY last_quiz_at DESC
        LIMIT greatest(1, least(p_limit, 5000)) OFFSET greatest(0, p_offset)) r), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- ── Overview: calls block ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION enm_dash_calls(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  WITH calls AS (
    SELECT * FROM enm_quiz_calls_v
    WHERE booked_at >= p_from AND booked_at < p_to
      AND NOT (p_exclude_tests AND enm_is_test_email(email))
  ),
  takers AS (
    SELECT email, min(completed_at) AS first_quiz_at FROM enm_quiz_runs_v
    WHERE session_id IS NOT NULL AND email IS NOT NULL GROUP BY email
  ),
  finished AS (
    SELECT DISTINCT email FROM enm_quiz_runs_v
    WHERE session_id IS NOT NULL AND email IS NOT NULL
      AND first_at >= p_from AND first_at < p_to
      AND NOT (p_exclude_tests AND enm_is_test_email(email))
  )
  SELECT jsonb_build_object(
    'calls',     (SELECT count(*) FROM calls),
    'people',    (SELECT count(DISTINCT email) FROM calls),
    'from_quiz', (SELECT count(DISTINCT c.email) FROM calls c JOIN takers t ON t.email = c.email
                  WHERE c.booked_at >= t.first_quiz_at),
    'upcoming',  (SELECT count(*) FROM calls WHERE starts_at > now()),
    -- funnel: people who finished in the period and booked after their quiz (any time since)
    'funnel_booked', (SELECT count(DISTINCT f.email) FROM finished f
                      JOIN takers t ON t.email = f.email
                      JOIN enm_quiz_calls_v c ON c.email = f.email AND c.booked_at >= t.first_quiz_at)
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- ── Person timeline: adds calls (cancelled ones too, so the story is complete)
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
  )
  SELECT jsonb_build_object(
    'person', (SELECT to_jsonb(p) - 'top_uid' FROM enm_quiz_people_v p WHERE p.email = v_email),
    'items', coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.at DESC) FROM items i), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

REVOKE ALL ON enm_quiz_calls_v, enm_quiz_people_v FROM anon, PUBLIC;
GRANT SELECT ON enm_quiz_calls_v, enm_quiz_people_v TO authenticated;
REVOKE EXECUTE ON FUNCTION enm_dash_calls(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN), enm_dash_person(TEXT) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION enm_dash_calls(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN), enm_dash_person(TEXT) TO authenticated;
