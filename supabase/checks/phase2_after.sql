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

-- == P7. Webhook calls from Stripe (latest first)
SELECT received_at, type, result FROM quiz_stripe_events ORDER BY received_at DESC LIMIT 20;

-- == P8. Each purchase since launch: product, how it is counted, buyer's quiz result (no emails)
SELECT p.purchased_at, p.product, p.kind, pr.label AS mapped_label, p.result_uid AS mapped_style_uid,
       p.amount_cents, (t.email IS NOT NULL) AS took_quiz, t.top_style AS buyer_quiz_result,
       enm_is_test_email(p.email) AS test
FROM enm_quiz_purchases_v p
LEFT JOIN quiz_products pr ON pr.product_id = p.product_id
LEFT JOIN enm_quiz_people_v t ON t.email = lower(p.email)
WHERE p.purchased_at >= '2026-10-13T00:00:00Z' ORDER BY p.purchased_at;
