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
