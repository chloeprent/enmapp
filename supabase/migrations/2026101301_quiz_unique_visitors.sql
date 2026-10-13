-- Quiz dashboard: count visitors, not page loads.
-- The quiz now sends a random browser id (meta.vid, no personal data) with each
-- event. The runs view gets a "visitor" column (the browser id, or the run id
-- for visits from before this change), and the Overview counts distinct
-- visitors for the Journey, Where they come from and Devices.
-- Only adds a column at the end of the view and replaces one read-only function.

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
    (array_agg(user_agent ORDER BY created_at) FILTER (WHERE user_agent IS NOT NULL))[1]    AS user_agent,
    (array_agg(meta ->> 'vid' ORDER BY created_at) FILTER (WHERE meta ? 'vid'))[1]           AS vid
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
  END AS device,
  -- Same browser = same visitor. Visits from before this existed count one each.
  coalesce(ev.vid, ev.run_id::text) AS visitor
FROM ev
LEFT JOIN enm_quiz_sessions s ON s.run_id = ev.run_id
LEFT JOIN enm_quiz_leads    l ON l.id = s.lead_id;

GRANT SELECT ON enm_quiz_runs_v TO authenticated;

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
        'visited',  count(DISTINCT visitor) FILTER (WHERE visited OR started),
        'started',  count(DISTINCT visitor) FILTER (WHERE started),
        'finished', count(DISTINCT visitor) FILTER (WHERE session_id IS NOT NULL)) FROM runs),
    'completions',   (SELECT count(*) FROM done),
    'unique_people', (SELECT count(DISTINCT email) FROM done),
    'sources', coalesce((SELECT jsonb_agg(x ORDER BY x.completions DESC) FROM (
        SELECT source, count(*) FILTER (WHERE session_id IS NOT NULL) AS completions, count(DISTINCT visitor) AS visits
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
        SELECT device, count(DISTINCT visitor) AS visits, count(DISTINCT visitor) FILTER (WHERE session_id IS NOT NULL) AS completions
        FROM runs GROUP BY device) x), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;
