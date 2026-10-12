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
