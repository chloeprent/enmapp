-- Read-only health check for the quiz dashboard work. Run by
-- .github/workflows/db-readonly-check.yml inside a read-only transaction.
-- Prints structure and counts only, no personal data.
\pset pager off
\echo '== 1. Quiz tables and their columns'
SELECT table_name, string_agg(column_name || ':' || data_type, ', ' ORDER BY ordinal_position) AS columns
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name LIKE 'enm_quiz_%'
GROUP BY table_name ORDER BY table_name;

\echo '== 2. Row level security and policies on quiz tables'
SELECT c.relname AS table_name, c.relrowsecurity AS rls_on,
       COALESCE(string_agg(p.polname || '(' || p.polcmd || ')', ', ' ORDER BY p.polname), '') AS policies
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
LEFT JOIN pg_policy p ON p.polrelid = c.oid
WHERE c.relkind = 'r' AND c.relname LIKE 'enm_quiz_%'
GROUP BY c.relname, c.relrowsecurity ORDER BY c.relname;

\echo '== 3. Admin check function and admin count'
SELECT proname, prosecdef AS security_definer FROM pg_proc WHERE proname = 'enm_is_quiz_admin';
SELECT count(*) AS admin_emails FROM enm_quiz_admins;

\echo '== 4. Row counts'
SELECT 'leads' AS what, count(*) FROM enm_quiz_leads
UNION ALL SELECT 'unique lead emails', count(DISTINCT lower(email)) FROM enm_quiz_leads
UNION ALL SELECT 'sessions (results)', count(*) FROM enm_quiz_sessions
UNION ALL SELECT 'answers', count(*) FROM enm_quiz_answers
UNION ALL SELECT 'events', count(*) FROM enm_quiz_events
UNION ALL SELECT 'question feedback', count(*) FROM enm_quiz_question_feedback;

\echo '== 5. Events by type, with first and last date'
SELECT event, count(*) AS n, count(DISTINCT run_id) AS runs, min(created_at)::date AS first, max(created_at)::date AS last
FROM enm_quiz_events GROUP BY event ORDER BY n DESC;

\echo '== 6. Sessions with 2nd/3rd matches stored'
SELECT count(*) FILTER (WHERE jsonb_array_length(top_results) >= 2) AS with_2nd,
       count(*) FILTER (WHERE jsonb_array_length(top_results) >= 3) AS with_3rd,
       count(*) FILTER (WHERE run_id IS NOT NULL) AS with_run_id
FROM enm_quiz_sessions;

\echo '== 7. Other quiz-related objects (views, functions)'
SELECT table_name AS view_name FROM information_schema.views WHERE table_schema='public' AND table_name LIKE 'enm_%';
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace AND n.nspname='public' WHERE proname LIKE 'enm_%' ORDER BY 1;

\echo '== 8. TidyCal sync: scheduled jobs'
SELECT jobid, jobname, schedule, active, left(command, 120) AS command FROM cron.job WHERE command ILIKE '%tidycal%' OR jobname ILIKE '%tidycal%';
\echo '== 9. TidyCal sync: last 5 runs'
SELECT d.status, d.start_time, left(coalesce(d.return_message,''), 80) AS message
FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
WHERE j.command ILIKE '%tidycal%' OR j.jobname ILIKE '%tidycal%'
ORDER BY d.start_time DESC LIMIT 5;
\echo '== 10. TidyCal data in the CRM'
SELECT count(*) AS contacts, count(*) FILTER (WHERE call_scheduled_at IS NOT NULL) AS with_call, max(call_scheduled_at) AS latest_call FROM swoon_crm_contacts;
SELECT activity_type, count(*), max(created_at) AS latest FROM swoon_crm_activity WHERE activity_type ILIKE '%call%' OR activity_type ILIKE '%book%' OR activity_type ILIKE '%tidycal%' GROUP BY 1 ORDER BY 3 DESC LIMIT 10;
\echo '== 11. Tables this project would add (should not exist yet)'
SELECT to_regclass('public.quiz_purchases') AS quiz_purchases, to_regclass('public.purchases') AS purchases;
