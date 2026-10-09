-- Read-only checks run right after the dashboard migration is applied.
-- Prints structure and totals only (no personal data). Safe to re-run.

-- == A. New UTM columns on enm_quiz_leads
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'enm_quiz_leads' AND column_name LIKE 'utm_%' ORDER BY 1;

-- == B. New views and functions
SELECT table_name AS view_name FROM information_schema.views
WHERE table_schema = 'public' AND table_name IN ('enm_quiz_runs_v', 'enm_quiz_people_v') ORDER BY 1;
SELECT proname, prosecdef AS runs_as_owner FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
WHERE proname IN ('enm_is_test_email', 'enm_source_group', 'enm_dash_overview', 'enm_dash_people', 'enm_dash_person', 'enm_dash_feedback') ORDER BY 1;

-- == C. Who can call the report functions (should be authenticated, not anon)
SELECT routine_name, grantee FROM information_schema.routine_privileges
WHERE routine_schema = 'public' AND routine_name LIKE 'enm_dash_%' AND grantee IN ('anon', 'authenticated') ORDER BY 1, 2;

-- == D. Overview totals, all time, tests excluded (as an admin)
WITH c AS MATERIALIZED (SELECT set_config('request.jwt.claims', '{"email":"chloeprent@gmail.com"}', true) AS x)
SELECT o -> 'funnel' AS funnel, o -> 'completions' AS completions, o -> 'unique_people' AS unique_people, o -> 'actions' AS actions
FROM c, LATERAL (SELECT enm_dash_overview('2020-01-01', now() + interval '1 day', true) AS o) s;

-- == E. Feedback and people totals (as an admin)
WITH c AS MATERIALIZED (SELECT set_config('request.jwt.claims', '{"email":"chloeprent@gmail.com"}', true) AS x)
SELECT f -> 'summary' AS feedback_summary, p -> 'people_total' AS people_total
FROM c, LATERAL (SELECT enm_dash_feedback('2020-01-01', now() + interval '1 day', true, NULL, NULL, 1, 0) AS f,
                        enm_dash_people('2020-01-01', now() + interval '1 day', true, NULL, NULL, NULL, NULL, 1, 0) AS p) s;

-- == F. Non-admin is refused (expect an error line below)
SELECT enm_dash_overview('2020-01-01', now(), true) IS NOT NULL AS should_not_print;

-- == G. Source groups (Facebook split like Instagram)
SELECT enm_source_group('facebook', 'manychat') AS fb_manychat, enm_source_group('facebook', 'bio') AS fb_bio,
       enm_source_group('instagram', 'manychat') AS ig_manychat, enm_source_group('instagram', 'bio') AS ig_bio, enm_source_group('instagram', 'dm') AS ig_dm,
       enm_source_group('kit', 'email') AS email, enm_source_group('blog', 'blog') AS blog;
