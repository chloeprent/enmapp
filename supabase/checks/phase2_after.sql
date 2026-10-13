-- Read-only checks after the Phase 2 purchases load. Totals only, no personal data.

-- == P1. Product mapping
SELECT kind, count(*) AS products, count(result_uid) AS linked_to_a_result FROM quiz_products GROUP BY kind ORDER BY 1;

-- == P2. Stored purchases (since launch; $0 discounted checkouts included)
SELECT count(*) AS rows, count(DISTINCT session_id) AS checkouts, count(DISTINCT email) AS buyers,
       sum(amount_cents) / 100.0 AS total, count(*) FILTER (WHERE refunded) AS refunded,
       min(purchased_at)::date AS first, max(purchased_at)::date AS last
FROM quiz_purchases;

-- == P3. Purchases by type
SELECT kind, count(*) AS items, sum(amount_cents) / 100.0 AS total FROM enm_quiz_purchases_v GROUP BY kind ORDER BY 1;

-- == P4. People stages (quiz takers)
SELECT stage, count(*) FROM enm_quiz_people_v GROUP BY stage ORDER BY 2 DESC;

-- == P5. Purchases since launch, by how they arrived (webhook = instant)
SELECT source, count(*) AS rows, count(*) FILTER (WHERE amount_cents = 0) AS free_rows, max(purchased_at) AS latest
FROM quiz_purchases GROUP BY source ORDER BY 1;

-- == P6. Safety-net schedule
SELECT jobname, schedule, active FROM cron.job WHERE jobname IN ('quiz-stripe-sync', 'quiz-calls-sync') ORDER BY 1;
