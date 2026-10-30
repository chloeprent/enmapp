-- Read-only funnel analysis since launch (13 Oct, Philippines time). Test emails
-- are left out; anonymous visits cannot be checked for tests. Counts only.

-- == A. Whole funnel (one count per visitor)
WITH r AS (
  SELECT v.*, (SELECT bool_or(e.event = 'gate') FROM enm_quiz_events e WHERE e.run_id = v.run_id) AS gated
  FROM enm_quiz_runs_v v
  WHERE v.first_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(v.email)
)
SELECT count(DISTINCT visitor) AS visitors,
       count(DISTINCT visitor) FILTER (WHERE started) AS started,
       count(DISTINCT visitor) FILTER (WHERE max_q >= 1) AS answered_q1,
       count(DISTINCT visitor) FILTER (WHERE max_q >= 8) AS reached_q8,
       count(DISTINCT visitor) FILTER (WHERE gated) AS reached_email_gate,
       count(DISTINCT visitor) FILTER (WHERE session_id IS NOT NULL) AS completed,
       count(DISTINCT visitor) FILTER (WHERE roadmap_clicks > 0) AS clicked_roadmap,
       count(DISTINCT visitor) FILTER (WHERE pdf_clicks > 0) AS saved_pdf,
       count(DISTINCT visitor) FILTER (WHERE call_clicks > 0) AS clicked_call
FROM r;

-- == B. Answers per question (people who answered at least question n)
SELECT q.n, count(DISTINCT v.visitor) AS people
FROM generate_series(1, 15) q(n)
LEFT JOIN enm_quiz_runs_v v ON v.started AND coalesce(v.max_q, 0) >= q.n
  AND v.first_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(v.email)
GROUP BY q.n ORDER BY q.n;

-- == C. By source
SELECT enm_source_group(utm_source, utm_medium) AS source, utm_campaign AS campaign,
       count(DISTINCT visitor) AS visitors, count(DISTINCT visitor) FILTER (WHERE started) AS started,
       count(DISTINCT visitor) FILTER (WHERE session_id IS NOT NULL) AS completed,
       count(DISTINCT visitor) FILTER (WHERE roadmap_clicks > 0) AS roadmap_clicks
FROM enm_quiz_runs_v
WHERE first_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(email)
GROUP BY 1, 2 ORDER BY visitors DESC;

-- == D. By device
SELECT device, count(DISTINCT visitor) AS visitors, count(DISTINCT visitor) FILTER (WHERE started) AS started,
       count(DISTINCT visitor) FILTER (WHERE session_id IS NOT NULL) AS completed
FROM enm_quiz_runs_v
WHERE first_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(email)
GROUP BY 1 ORDER BY 2 DESC;

-- == E. Per day (Philippines time)
SELECT (first_at AT TIME ZONE 'Asia/Manila')::date AS day, count(DISTINCT visitor) AS visitors,
       count(DISTINCT visitor) FILTER (WHERE started) AS started,
       count(DISTINCT visitor) FILTER (WHERE session_id IS NOT NULL) AS completed
FROM enm_quiz_runs_v
WHERE first_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(email)
GROUP BY 1 ORDER BY 1;

-- == F. After the quiz: people (one per email), emails, buying, calls
SELECT count(*) AS quiz_takers,
       count(*) FILTER (WHERE results_sent_at IS NOT NULL) AS got_results_email,
       count(*) FILTER (WHERE nb_started_at IS NOT NULL) AS in_non_buyer_emails,
       count(*) FILTER (WHERE nb_finished_at IS NOT NULL) AS finished_non_buyer_emails,
       count(*) FILTER (WHERE unsubscribed_at IS NOT NULL) AS unsubscribed,
       count(*) FILTER (WHERE purchases > 0) AS bought,
       count(*) FILTER (WHERE calls > 0) AS booked_call,
       count(*) FILTER (WHERE saved_pdf) AS saved_pdf,
       count(*) FILTER (WHERE clicked_call) AS clicked_call
FROM enm_quiz_people_v
WHERE first_quiz_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(email);

-- == G. Paid purchases since launch (real buyers)
SELECT p.purchased_at, p.product, p.kind, p.amount_cents, (t.email IS NOT NULL) AS took_quiz,
       round(extract(epoch FROM p.purchased_at - t.first_quiz_at) / 3600.0, 1) AS hours_after_quiz
FROM enm_quiz_purchases_v p LEFT JOIN enm_quiz_people_v t ON t.email = lower(p.email)
WHERE p.purchased_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(p.email) ORDER BY 1;

-- == H. Poll answers since launch (real people)
SELECT detail, count(*) FROM quiz_kit_events
WHERE event = 'poll' AND at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(email) GROUP BY 1 ORDER BY 2 DESC;

-- == I. Result shown vs roadmap clicks, by style
SELECT result_title, count(*) AS completed, count(*) FILTER (WHERE roadmap_clicks > 0) AS clicked_roadmap
FROM enm_quiz_runs_v
WHERE session_id IS NOT NULL AND first_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(email)
GROUP BY 1 ORDER BY 2 DESC;

-- == J. Calls booked since launch (curiosity, not cancelled)
SELECT count(*) AS bookings, count(*) FILTER (WHERE took_quiz_first) AS after_quiz FROM (
  SELECT c.*, EXISTS (SELECT 1 FROM enm_quiz_people_v t WHERE t.email = lower(c.email) AND t.first_quiz_at < c.booked_at) AS took_quiz_first
  FROM enm_quiz_calls_v c WHERE c.booked_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(c.email)) x;

-- == K. All TidyCal curiosity bookings since launch (before the quiz rule)
SELECT count(*) AS bookings, count(*) FILTER (WHERE cancelled_at IS NOT NULL) AS cancelled
FROM quiz_calls WHERE booking_type ILIKE '%curiosity%' AND booked_at >= '2026-10-12T16:00:00Z' AND NOT enm_is_test_email(email);
