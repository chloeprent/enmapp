-- Quiz dashboard v2 (phase 1): UTM capture plus server-side reporting.
--
-- Additive only: three nullable columns on enm_quiz_leads, one view and a few
-- read-only functions. Nothing existing is renamed or dropped, so the current
-- quiz and dashboard keep working while the new dashboard is rolled out.
--
-- Every function checks enm_is_quiz_admin() and runs as the caller, so the
-- existing row level security on the quiz tables still decides who sees what.

-- ── UTM tags, saved with each quiz submission ──────────────────────────────
ALTER TABLE enm_quiz_leads
  ADD COLUMN IF NOT EXISTS utm_source   TEXT,
  ADD COLUMN IF NOT EXISTS utm_medium   TEXT,
  ADD COLUMN IF NOT EXISTS utm_campaign TEXT;

-- ── Helpers ────────────────────────────────────────────────────────────────

-- Internal and test addresses, hidden by the dashboard's "Exclude tests" toggle.
CREATE OR REPLACE FUNCTION enm_is_test_email(p_email TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
  SELECT p_email IS NOT NULL AND (
       lower(p_email) LIKE '%chloeprent%'
    OR lower(p_email) LIKE '%cristinemata25%'
    OR lower(p_email) LIKE '%+test%'
    OR lower(p_email) LIKE '%test+%'
    OR lower(p_email) LIKE '%@swoon.coach'
  );
$$;

-- utm_source / utm_medium to the source groups shown on the dashboard.
CREATE OR REPLACE FUNCTION enm_source_group(p_source TEXT, p_medium TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(trim(p_source), '') = '' THEN 'Direct / unknown'
    WHEN lower(p_source) IN ('kit', 'convertkit') OR lower(p_medium) = 'email' THEN 'Email'
    WHEN lower(p_source) = 'blog' THEN 'Blog'
    WHEN lower(p_source) = 'instagram' AND lower(coalesce(p_medium, '')) = 'manychat' THEN 'Instagram DMs (ManyChat)'
    WHEN lower(p_source) = 'instagram' THEN 'Instagram bio'
    WHEN lower(p_source) = 'facebook' THEN 'Facebook'
    WHEN lower(p_source) = 'tiktok' THEN 'TikTok'
    WHEN lower(p_source) = 'website' THEN 'Website'
    ELSE 'Other'
  END;
$$;

-- ── One row per quiz visit (run) ───────────────────────────────────────────
-- A run starts when the quiz page loads. Finished runs join to their result
-- (session) and the person (lead). Source comes from the submission when it
-- has UTMs, otherwise from the first tracked event of the run.
CREATE OR REPLACE VIEW enm_quiz_runs_v WITH (security_invoker = true) AS
WITH ev AS (
  SELECT
    run_id,
    min(created_at)                                                        AS first_at,
    bool_or(event = 'page_view')                                           AS visited,
    bool_or(event = 'start')                                               AS started,
    max(question_number) FILTER (WHERE event = 'question_answered')        AS max_q,
    count(*) FILTER (WHERE event = 'save_pdf')                             AS pdf_clicks,
    count(*) FILTER (WHERE event = 'roadmap_click')                        AS roadmap_clicks,
    count(*) FILTER (WHERE event = 'book_call_click')                      AS call_clicks,
    count(*) FILTER (WHERE event = 'partner_invite_sent')                  AS invite_events,
    bool_or(event = 'result_rating')                                       AS rated,
    (array_agg(meta -> 'utm' ORDER BY created_at) FILTER (WHERE meta ? 'utm'))[1]           AS utm,
    (array_agg(user_agent ORDER BY created_at) FILTER (WHERE user_agent IS NOT NULL))[1]    AS user_agent
  FROM enm_quiz_events
  GROUP BY run_id
)
SELECT
  ev.run_id, ev.first_at, ev.visited, ev.started, ev.max_q, ev.pdf_clicks,
  ev.roadmap_clicks, ev.call_clicks, ev.invite_events, ev.rated,
  s.id            AS session_id,
  s.result_uid,
  s.result_title,
  s.top_results,
  s.completed_at,
  l.id            AS lead_id,
  lower(l.email)  AS email,
  l.first_name,
  l.invite_sent_at,
  coalesce(nullif(l.utm_source, ''),   ev.utm ->> 'source')   AS utm_source,
  coalesce(nullif(l.utm_medium, ''),   ev.utm ->> 'medium')   AS utm_medium,
  coalesce(nullif(l.utm_campaign, ''), ev.utm ->> 'campaign') AS utm_campaign,
  CASE
    WHEN ev.user_agent IS NULL THEN 'Unknown'
    WHEN ev.user_agent ~* '(ipad|tablet)' THEN 'Tablet'
    WHEN ev.user_agent ~* '(iphone|ipod|android|mobile|windows phone)' THEN 'Mobile'
    ELSE 'Desktop'
  END AS device
FROM ev
LEFT JOIN enm_quiz_sessions s ON s.run_id = ev.run_id
LEFT JOIN enm_quiz_leads    l ON l.id = s.lead_id;

-- ── Overview tab ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION enm_dash_overview(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  WITH runs AS (
    SELECT *, enm_source_group(utm_source, utm_medium) AS source
    FROM enm_quiz_runs_v
    WHERE first_at >= p_from AND first_at < p_to
      AND NOT (p_exclude_tests AND enm_is_test_email(email))
  ),
  done AS (SELECT * FROM runs WHERE session_id IS NOT NULL),
  q AS (SELECT generate_series(1, 15) AS n)
  SELECT jsonb_build_object(
    'funnel', (SELECT jsonb_build_object(
        'visited',  count(*) FILTER (WHERE visited OR started),
        'started',  count(*) FILTER (WHERE started),
        'finished', count(*) FILTER (WHERE session_id IS NOT NULL)) FROM runs),
    'completions',   (SELECT count(*) FROM done),
    'unique_people', (SELECT count(DISTINCT email) FROM done),
    'sources', coalesce((SELECT jsonb_agg(x ORDER BY x.completions DESC) FROM (
        SELECT source, count(*) FILTER (WHERE session_id IS NOT NULL) AS completions, count(*) AS visits
        FROM runs GROUP BY source) x), '[]'),
    'campaigns', coalesce((SELECT jsonb_agg(x ORDER BY x.completions DESC) FROM (
        SELECT source, utm_campaign AS campaign, count(*) AS completions
        FROM done WHERE coalesce(utm_campaign, '') <> ''
        GROUP BY source, utm_campaign) x), '[]'),
    'results', coalesce((SELECT jsonb_object_agg(result_uid, n) FROM (
        SELECT result_uid, count(*) AS n FROM done GROUP BY result_uid) x), '{}'),
    'second', coalesce((SELECT jsonb_object_agg(uid, n) FROM (
        SELECT top_results -> 1 ->> 'uid' AS uid, count(*) AS n FROM done
        WHERE jsonb_array_length(top_results) >= 2 GROUP BY 1) x), '{}'),
    'third', coalesce((SELECT jsonb_object_agg(uid, n) FROM (
        SELECT top_results -> 2 ->> 'uid' AS uid, count(*) AS n FROM done
        WHERE jsonb_array_length(top_results) >= 3 GROUP BY 1) x), '{}'),
    -- People who answered at least question n (only runs that pressed start).
    'questions', (SELECT jsonb_agg(jsonb_build_object('n', q.n,
        'answered', (SELECT count(*) FROM runs WHERE started AND coalesce(max_q, 0) >= q.n)) ORDER BY q.n) FROM q),
    'actions', (SELECT jsonb_build_object(
        'pdf_people',     count(DISTINCT coalesce(email, run_id::text)) FILTER (WHERE pdf_clicks > 0),
        'pdf_clicks',     coalesce(sum(pdf_clicks), 0),
        'roadmap_people', count(DISTINCT coalesce(email, run_id::text)) FILTER (WHERE roadmap_clicks > 0),
        'roadmap_clicks', coalesce(sum(roadmap_clicks), 0),
        'call_people',    count(DISTINCT coalesce(email, run_id::text)) FILTER (WHERE call_clicks > 0),
        'call_clicks',    coalesce(sum(call_clicks), 0),
        'invites',        count(*) FILTER (WHERE invite_sent_at IS NOT NULL OR invite_events > 0),
        'rated',          count(*) FILTER (WHERE rated)) FROM done),
    'devices', coalesce((SELECT jsonb_agg(x ORDER BY x.visits DESC) FROM (
        SELECT device, count(*) AS visits, count(*) FILTER (WHERE session_id IS NOT NULL) AS completions
        FROM runs GROUP BY device) x), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- ── People tab ─────────────────────────────────────────────────────────────
-- One row per email. Stage is the furthest point reached; for now everyone is
-- "Took the quiz" until purchases (phase 2) and Kit and calls (phase 3) land.
CREATE OR REPLACE VIEW enm_quiz_people_v WITH (security_invoker = true) AS
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
  bool_or(call_clicks > 0)                                       AS clicked_call,
  'Took the quiz'::TEXT                                          AS stage
FROM enm_quiz_runs_v
WHERE session_id IS NOT NULL AND email IS NOT NULL
GROUP BY email;

CREATE OR REPLACE FUNCTION enm_dash_people(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true,
  p_search TEXT DEFAULT NULL, p_stage TEXT DEFAULT NULL, p_style TEXT DEFAULT NULL,
  p_source TEXT DEFAULT NULL, p_limit INT DEFAULT 50, p_offset INT DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  WITH base AS (
    SELECT * FROM enm_quiz_people_v
    WHERE last_quiz_at >= p_from AND last_quiz_at < p_to
      AND NOT (p_exclude_tests AND enm_is_test_email(email))
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (coalesce(p_search, '') = ''
           OR email ILIKE '%' || p_search || '%' OR name ILIKE '%' || p_search || '%')
      AND (coalesce(p_stage, '')  = '' OR stage  = p_stage)
      AND (coalesce(p_style, '')  = '' OR top_uid = p_style)
      AND (coalesce(p_source, '') = '' OR source = p_source)
  )
  SELECT jsonb_build_object(
    'people_total', (SELECT count(*) FROM base),
    'stages', coalesce((SELECT jsonb_object_agg(stage, n) FROM (
        SELECT stage, count(*) AS n FROM base GROUP BY stage) x), '{}'),
    'total', (SELECT count(*) FROM filtered),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(r) - 'top_uid' ORDER BY r.last_quiz_at DESC) FROM (
        SELECT * FROM filtered ORDER BY last_quiz_at DESC
        LIMIT greatest(1, least(p_limit, 5000)) OFFSET greatest(0, p_offset)) r), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- One person's timeline, newest first.
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
       -- answers can change before Send, so only the final rating per run
       OR e.id IN (SELECT DISTINCT ON (x.run_id) x.id FROM enm_quiz_events x
                   JOIN runs rr ON rr.run_id = x.run_id
                   WHERE x.event = 'result_rating' ORDER BY x.run_id, x.created_at DESC)
  )
  SELECT jsonb_build_object(
    'person', (SELECT to_jsonb(p) - 'top_uid' FROM enm_quiz_people_v p WHERE p.email = v_email),
    'items', coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.at DESC) FROM items i), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- ── Feedback tab (the rating card) ─────────────────────────────────────────
-- Answers can be changed before sending, so the latest rating per run counts.
CREATE OR REPLACE FUNCTION enm_dash_feedback(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true,
  p_search TEXT DEFAULT NULL, p_answer TEXT DEFAULT NULL,
  p_limit INT DEFAULT 50, p_offset INT DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  WITH latest AS (
    SELECT DISTINCT ON (run_id) run_id, created_at, meta
    FROM enm_quiz_events WHERE event = 'result_rating'
    ORDER BY run_id, created_at DESC
  ),
  notes AS (
    SELECT run_id, string_agg(meta ->> 'comment', ' / ' ORDER BY created_at) AS note
    FROM enm_quiz_events WHERE event = 'result_rating_comment' GROUP BY run_id
  ),
  base AS (
    SELECT l.created_at AS at, l.meta ->> 'rating' AS answer,
           nullif(l.meta ->> 'stars', '')::INT AS stars,
           n.note, r.email, r.first_name AS name,
           coalesce(r.result_title, l.meta ->> 'result_title') AS style
    FROM latest l
    JOIN enm_quiz_runs_v r ON r.run_id = l.run_id
    LEFT JOIN notes n ON n.run_id = l.run_id
    WHERE l.created_at >= p_from AND l.created_at < p_to
      AND NOT (p_exclude_tests AND enm_is_test_email(r.email))
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (coalesce(p_answer, '') = '' OR answer = p_answer)
      AND (coalesce(p_search, '') = '' OR email ILIKE '%' || p_search || '%'
           OR name ILIKE '%' || p_search || '%' OR note ILIKE '%' || p_search || '%')
  )
  SELECT jsonb_build_object(
    'summary', (SELECT jsonb_build_object(
        'responses',  count(*),
        'spot_on',    count(*) FILTER (WHERE answer = 'spot_on'),
        'partly',     count(*) FILTER (WHERE answer = 'partly'),
        'not_really', count(*) FILTER (WHERE answer = 'not_really'),
        'avg_stars',  round(avg(stars)::NUMERIC, 2),
        'with_note',  count(*) FILTER (WHERE coalesce(note, '') <> '')) FROM base),
    'total', (SELECT count(*) FROM filtered),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.at DESC) FROM (
        SELECT * FROM filtered ORDER BY at DESC
        LIMIT greatest(1, least(p_limit, 5000)) OFFSET greatest(0, p_offset)) f), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- Signed-out visitors get nothing (Supabase grants new objects to anon by default).
REVOKE ALL ON enm_quiz_runs_v, enm_quiz_people_v FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION enm_dash_overview(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN),
  enm_dash_people(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, TEXT, TEXT, INT, INT),
  enm_dash_person(TEXT), enm_dash_feedback(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, INT, INT)
  FROM anon, PUBLIC;
GRANT SELECT ON enm_quiz_runs_v, enm_quiz_people_v TO authenticated;
GRANT EXECUTE ON FUNCTION enm_is_test_email(TEXT), enm_source_group(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION enm_dash_overview(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION enm_dash_people(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, TEXT, TEXT, INT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION enm_dash_person(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION enm_dash_feedback(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, INT, INT) TO authenticated;
