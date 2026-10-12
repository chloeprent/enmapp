-- Read-only checks for calls. Totals only, no personal data.

-- == C1. Bookings copied from TidyCal
SELECT booking_type, count(*) AS bookings, count(*) FILTER (WHERE cancelled_at IS NOT NULL) AS cancelled,
       min(booked_at)::date AS first, max(booked_at)::date AS last
FROM quiz_calls GROUP BY booking_type ORDER BY 2 DESC;

-- == C2. Calls that count for the quiz (curiosity, not cancelled, after quiz or purchase)
SELECT count(*) AS calls, count(DISTINCT email) AS people,
       count(*) FILTER (WHERE booked_at >= '2026-10-13') AS since_launch
FROM enm_quiz_calls_v;

-- == C3. Calls that count, tests excluded
SELECT count(*) AS calls_excluding_tests FROM enm_quiz_calls_v WHERE NOT enm_is_test_email(email);

-- == C4. Sync schedule
SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'quiz-calls-sync';

-- == C5. People stages
SELECT stage, count(*) FROM enm_quiz_people_v GROUP BY stage ORDER BY 2 DESC;
