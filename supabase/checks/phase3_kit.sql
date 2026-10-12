-- Read-only checks for Kit steps and polls. Totals only, no personal data.

-- == K1. Kit events stored
SELECT event, count(*) AS rows, count(DISTINCT email) AS people, min(at)::date AS first, max(at)::date AS last
FROM quiz_kit_events GROUP BY event ORDER BY 1;

-- == K2. Poll answers
SELECT detail AS tag, count(*) FROM quiz_kit_events WHERE event = 'poll' GROUP BY 1 ORDER BY 1;

-- == K3. People stages and flags
SELECT stage, count(*), count(*) FILTER (WHERE needs_attention) AS needs_attention,
       count(*) FILTER (WHERE unsubscribed_at IS NOT NULL) AS unsubscribed
FROM enm_quiz_people_v GROUP BY stage ORDER BY 2 DESC;

-- == K4. Owner's test email (chloeprent+testenm90): quiz, Kit steps, stage
SELECT 'quiz' AS what, completed_at AS at, result_title AS detail FROM enm_quiz_runs_v
WHERE email = 'chloeprent+testenm90@gmail.com' AND session_id IS NOT NULL
UNION ALL
SELECT 'kit ' || event, at, detail FROM quiz_kit_events WHERE email = 'chloeprent+testenm90@gmail.com'
UNION ALL
SELECT 'stage', NULL, stage || CASE WHEN needs_attention THEN ' (needs attention)' ELSE '' END
FROM enm_quiz_people_v WHERE email = 'chloeprent+testenm90@gmail.com'
ORDER BY 2 NULLS LAST;

-- == K5. Owner's test email: tags and referrer recorded for the visit
SELECT l.created_at, l.utm_source, l.utm_medium, l.utm_campaign, l.referrer
FROM enm_quiz_leads l WHERE lower(l.email) = 'chloeprent+testenm90@gmail.com';
SELECT e.event, e.created_at, e.meta -> 'utm' AS utm, e.referrer
FROM enm_quiz_events e
WHERE e.run_id IN (SELECT run_id FROM enm_quiz_runs_v WHERE email = 'chloeprent+testenm90@gmail.com')
  AND e.event IN ('page_view', 'start', 'gate')
ORDER BY e.created_at;

-- == K6. Today's visits: tags at first page view, tags saved with the email (no personal data)
SELECT r.first_at, pv.meta -> 'utm' AS tags_at_first_view, l.utm_source AS saved_source, l.utm_medium AS saved_medium,
       pv.referrer, (r.session_id IS NOT NULL) AS finished, r.email LIKE 'chloeprent%' AS owner_test
FROM enm_quiz_runs_v r
LEFT JOIN LATERAL (SELECT meta, referrer FROM enm_quiz_events e WHERE e.run_id = r.run_id ORDER BY created_at LIMIT 1) pv ON true
LEFT JOIN enm_quiz_sessions s ON s.run_id = r.run_id
LEFT JOIN enm_quiz_leads l ON l.id = s.lead_id
WHERE r.first_at >= now() - interval '30 hours'
ORDER BY r.first_at;

-- == K7. Quiz takers still without a results email (no personal data)
SELECT p.first_quiz_at::date AS first_quiz, p.quizzes, enm_is_test_email(p.email) AS test_email,
       (p.email LIKE 'chloeprent%') AS owner_test
FROM enm_quiz_people_v p WHERE p.results_sent_at IS NULL ORDER BY 1;
