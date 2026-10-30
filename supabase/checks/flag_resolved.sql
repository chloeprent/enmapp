-- Read-only: the "No results email" flag (no emails printed).
-- == R1. Flagged now, tests left out
SELECT count(*) FILTER (WHERE needs_attention) AS flagged_now,
       count(*) FILTER (WHERE results_sent_at IS NULL AND first_quiz_at >= '2026-10-13T00:00:00Z'
                         AND first_quiz_at < now() - interval '1 hour' AND purchases > 0) AS flagged_buyers,
       count(*) FILTER (WHERE attention_resolved_at IS NOT NULL) AS resolved_by_hand
FROM enm_quiz_people_v WHERE NOT enm_is_test_email(email);

-- == R2. Flagged people by quiz day (Philippines time) and whether they unsubscribed
SELECT (first_quiz_at AT TIME ZONE 'Asia/Manila')::date AS quiz_day, count(*) AS flagged,
       count(*) FILTER (WHERE unsubscribed_at IS NOT NULL) AS unsubscribed
FROM enm_quiz_people_v WHERE needs_attention AND NOT enm_is_test_email(email) GROUP BY 1 ORDER BY 1;
