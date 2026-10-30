-- Read-only: how fresh each data source is, and whether the background jobs run.
-- == F1. Latest record per source
SELECT 'quiz events' AS source, max(created_at) AS latest FROM enm_quiz_events
UNION ALL SELECT 'quiz completions', max(completed_at) FROM enm_quiz_sessions
UNION ALL SELECT 'stripe purchases', max(purchased_at) FROM quiz_purchases
UNION ALL SELECT 'stripe webhook calls', max(received_at) FROM quiz_stripe_events
UNION ALL SELECT 'kit events', max(at) FROM quiz_kit_events
UNION ALL SELECT 'tidycal sync', max(synced_at) FROM quiz_calls;

-- == F2. Background jobs: last run and result
SELECT j.jobname, j.schedule, j.active, d.status, d.start_time, left(coalesce(d.return_message, ''), 80) AS message
FROM cron.job j
LEFT JOIN LATERAL (SELECT * FROM cron.job_run_details r WHERE r.jobid = j.jobid ORDER BY start_time DESC LIMIT 1) d ON true
WHERE j.jobname LIKE 'quiz-%' ORDER BY 1;

-- == F3. What the background jobs got back (latest 6 calls)
SELECT r.created, r.status_code, left(r.content::text, 160) AS reply
FROM net._http_response r ORDER BY r.created DESC LIMIT 6;
