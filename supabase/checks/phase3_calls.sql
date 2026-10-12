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

-- == C6. Cross-check: quiz takers or buyers who have any booking at all (counts only)
WITH people AS (
  SELECT email, min(completed_at) AS first_at FROM enm_quiz_runs_v
  WHERE session_id IS NOT NULL AND email IS NOT NULL GROUP BY email
)
SELECT count(DISTINCT c.email) AS quiz_takers_with_any_booking,
       count(*) FILTER (WHERE c.booking_type ILIKE '%curiosity%') AS curiosity_bookings,
       count(*) FILTER (WHERE c.booking_type ILIKE '%curiosity%' AND c.cancelled_at IS NULL) AS curiosity_not_cancelled,
       count(*) FILTER (WHERE c.booking_type ILIKE '%curiosity%' AND c.cancelled_at IS NULL AND c.booked_at < p.first_at) AS booked_before_their_quiz,
       count(*) FILTER (WHERE c.booking_type ILIKE '%curiosity%' AND c.cancelled_at IS NULL AND c.booked_at >= p.first_at) AS booked_after_their_quiz,
       count(DISTINCT c.email) FILTER (WHERE enm_is_test_email(c.email)) AS test_emails
FROM quiz_calls c JOIN people p ON p.email = c.email;

-- == C7. Emails in bookings vs quiz takers (all lowercased)
SELECT (SELECT count(DISTINCT email) FROM quiz_calls) AS booking_emails,
       (SELECT count(DISTINCT email) FROM enm_quiz_runs_v WHERE session_id IS NOT NULL) AS quiz_emails;
