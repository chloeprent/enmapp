-- Quiz dashboard phase 2: Stripe purchases.
--
-- quiz_purchases holds one row per paid product bought (free $0 checkouts
-- are skipped: they were test purchases), written only by the
-- quiz-stripe-webhook function (service role). quiz_products maps Stripe
-- products to the dashboard's names (Solo, Bundle, 7 Conversations) and, for
-- roadmaps, to the quiz result they belong to. Admins can read both; nobody
-- else can read or write.

CREATE TABLE IF NOT EXISTS quiz_products (
  product_id   TEXT PRIMARY KEY,          -- Stripe product id (prod_...)
  name         TEXT NOT NULL,             -- name in Stripe, for reference
  kind         TEXT NOT NULL DEFAULT 'other'
               CHECK (kind IN ('solo', 'bundle', 'conversations', 'other', 'ignore')),
  result_uid   TEXT,                      -- quiz result this roadmap is for, if any
  label        TEXT,                      -- short name shown on the dashboard
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quiz_purchases (
  id              TEXT PRIMARY KEY,       -- checkout session id + line item id
  session_id      TEXT,                   -- Stripe checkout session (cs_...)
  payment_intent  TEXT,
  email           TEXT,                   -- lowercased
  name            TEXT,
  product_id      TEXT,
  product_name    TEXT,
  quantity        INT NOT NULL DEFAULT 1,
  amount_cents    INT NOT NULL DEFAULT 0, -- what they paid for this line, after discounts
  currency        TEXT,
  refunded        BOOLEAN NOT NULL DEFAULT false,
  purchased_at    TIMESTAMPTZ NOT NULL,
  source          TEXT NOT NULL DEFAULT 'webhook' CHECK (source IN ('webhook', 'backfill')),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS quiz_purchases_email_idx ON quiz_purchases (email);
CREATE INDEX IF NOT EXISTS quiz_purchases_at_idx ON quiz_purchases (purchased_at);
CREATE INDEX IF NOT EXISTS quiz_purchases_pi_idx ON quiz_purchases (payment_intent);

ALTER TABLE quiz_products  ENABLE ROW LEVEL SECURITY;
ALTER TABLE quiz_purchases ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS quiz_products_admin_read ON quiz_products;
CREATE POLICY quiz_products_admin_read ON quiz_products FOR SELECT TO authenticated USING (enm_is_quiz_admin());
DROP POLICY IF EXISTS quiz_purchases_admin_read ON quiz_purchases;
CREATE POLICY quiz_purchases_admin_read ON quiz_purchases FOR SELECT TO authenticated USING (enm_is_quiz_admin());

REVOKE ALL ON quiz_products, quiz_purchases FROM anon, PUBLIC;
GRANT SELECT ON quiz_products, quiz_purchases TO authenticated;

-- ── One row per paid product, with its dashboard type ──────────────────────
-- Refunded purchases are kept in the table but left out of every count.
CREATE OR REPLACE VIEW enm_quiz_purchases_v WITH (security_invoker = true) AS
SELECT
  p.id, p.session_id, p.payment_intent, p.email, p.name, p.product_id,
  coalesce(nullif(pr.label, ''), p.product_name)                 AS product,
  coalesce(pr.kind, 'other')                                     AS kind,
  pr.result_uid,
  p.quantity, p.amount_cents, p.currency, p.purchased_at
FROM quiz_purchases p
LEFT JOIN quiz_products pr ON pr.product_id = p.product_id
WHERE NOT p.refunded AND coalesce(pr.kind, 'other') <> 'ignore';

-- ── People: stage now follows what they bought ─────────────────────────────
-- New columns go at the end (CREATE OR REPLACE VIEW rule).
CREATE OR REPLACE VIEW enm_quiz_people_v WITH (security_invoker = true) AS
WITH q AS (
  SELECT
    email,
    (array_agg(first_name ORDER BY completed_at DESC) FILTER (WHERE first_name IS NOT NULL))[1] AS name,
    min(completed_at)                                              AS first_quiz_at,
    max(completed_at)                                              AS last_quiz_at,
    count(*)                                                       AS quizzes,
    (array_agg(result_uid   ORDER BY completed_at DESC))[1]        AS top_uid,
    (array_agg(result_title ORDER BY completed_at DESC))[1]        AS top_style,
    (array_agg(enm_source_group(utm_source, utm_medium) ORDER BY completed_at))[1] AS source,
    (array_agg(utm_campaign ORDER BY completed_at) FILTER (WHERE coalesce(utm_campaign, '') <> ''))[1] AS campaign,
    bool_or(pdf_clicks > 0)                                        AS saved_pdf,
    bool_or(rated)                                                 AS gave_feedback,
    bool_or(call_clicks > 0)                                       AS clicked_call
  FROM enm_quiz_runs_v
  WHERE session_id IS NOT NULL AND email IS NOT NULL
  GROUP BY email
),
b AS (
  SELECT email,
         count(*)                                AS purchases,
         sum(amount_cents)                       AS spent_cents,
         bool_or(kind = 'solo')                  AS has_solo,
         bool_or(kind = 'bundle')                AS has_bundle,
         bool_or(kind = 'conversations')         AS has_conv,
         min(purchased_at)                       AS first_purchase_at
  FROM enm_quiz_purchases_v
  GROUP BY email
)
SELECT
  q.email, q.name, q.first_quiz_at, q.last_quiz_at, q.quizzes, q.top_uid, q.top_style,
  q.source, q.campaign, q.saved_pdf, q.gave_feedback, q.clicked_call,
  CASE
    WHEN b.has_bundle AND b.has_conv THEN 'Bought Bundle + 7 Conversations'
    WHEN b.has_bundle                THEN 'Bought Bundle'
    WHEN b.has_solo AND b.has_conv   THEN 'Bought Solo + 7 Conversations'
    WHEN b.has_solo                  THEN 'Bought Solo'
    WHEN b.has_conv                  THEN 'Bought 7 Conversations only'
    ELSE 'Took the quiz'
  END                                            AS stage,
  coalesce(b.purchases, 0)                       AS purchases,
  coalesce(b.spent_cents, 0)                     AS spent_cents,
  b.first_purchase_at,
  CASE WHEN b.has_bundle THEN 'bundle' WHEN b.has_solo THEN 'solo'
       WHEN b.has_conv THEN 'conversations' END  AS top_purchase
FROM q LEFT JOIN b ON b.email = q.email;

-- ── Overview: purchases block and the "Bought" funnel step ─────────────────
CREATE OR REPLACE FUNCTION enm_dash_purchases(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  WITH buys AS (
    SELECT * FROM enm_quiz_purchases_v
    WHERE purchased_at >= p_from AND purchased_at < p_to
      AND NOT (p_exclude_tests AND enm_is_test_email(email))
  ),
  takers AS (   -- first quiz per person, any time
    SELECT email, min(completed_at) AS first_quiz_at FROM enm_quiz_runs_v
    WHERE session_id IS NOT NULL AND email IS NOT NULL GROUP BY email
  ),
  finished AS ( -- people who finished the quiz in the period
    SELECT DISTINCT email FROM enm_quiz_runs_v
    WHERE session_id IS NOT NULL AND email IS NOT NULL
      AND first_at >= p_from AND first_at < p_to
      AND NOT (p_exclude_tests AND enm_is_test_email(email))
  )
  SELECT jsonb_build_object(
    'orders',        (SELECT count(DISTINCT session_id) FROM buys),
    'items',         (SELECT coalesce(sum(quantity), 0) FROM buys),
    'revenue_cents', (SELECT coalesce(sum(amount_cents), 0) FROM buys),
    'buyers',        (SELECT count(DISTINCT email) FROM buys),
    -- buyers who had taken the quiz before buying
    'quiz_buyers',   (SELECT count(DISTINCT b.email) FROM buys b JOIN takers t ON t.email = b.email
                      WHERE b.purchased_at >= t.first_quiz_at),
    'quiz_revenue_cents', (SELECT coalesce(sum(b.amount_cents), 0) FROM buys b JOIN takers t ON t.email = b.email
                      WHERE b.purchased_at >= t.first_quiz_at),
    -- funnel: people who finished in the period and bought after their quiz (any time since)
    'funnel_bought', (SELECT count(DISTINCT f.email) FROM finished f
                      JOIN takers t ON t.email = f.email
                      JOIN enm_quiz_purchases_v p ON p.email = f.email AND p.purchased_at >= t.first_quiz_at),
    'by_kind', coalesce((SELECT jsonb_agg(x ORDER BY x.revenue_cents DESC) FROM (
        SELECT kind, sum(quantity) AS count, sum(amount_cents) AS revenue_cents
        FROM buys GROUP BY kind) x), '[]'),
    'roadmaps', coalesce((SELECT jsonb_agg(x ORDER BY x.total DESC) FROM (
        SELECT result_uid,
               sum(quantity) FILTER (WHERE kind = 'solo')   AS solo,
               sum(quantity) FILTER (WHERE kind = 'bundle') AS bundle,
               sum(quantity) AS total, sum(amount_cents) AS revenue_cents
        FROM buys WHERE result_uid IS NOT NULL GROUP BY result_uid) x), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- ── People list: adds a purchase filter (signature changes, so drop first) ─
DROP FUNCTION IF EXISTS enm_dash_people(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, TEXT, TEXT, INT, INT);
CREATE OR REPLACE FUNCTION enm_dash_people(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_exclude_tests BOOLEAN DEFAULT true,
  p_search TEXT DEFAULT NULL, p_stage TEXT DEFAULT NULL, p_style TEXT DEFAULT NULL,
  p_source TEXT DEFAULT NULL, p_limit INT DEFAULT 50, p_offset INT DEFAULT 0,
  p_purchase TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  -- Everyone who took the quiz in the period (same rule as the Overview counts).
  WITH in_range AS (
    SELECT DISTINCT email FROM enm_quiz_runs_v
    WHERE session_id IS NOT NULL AND email IS NOT NULL
      AND first_at >= p_from AND first_at < p_to
  ),
  base AS (
    SELECT p.* FROM enm_quiz_people_v p JOIN in_range USING (email)
    WHERE NOT (p_exclude_tests AND enm_is_test_email(p.email))
  ),
  filtered AS (
    SELECT * FROM base
    WHERE (coalesce(p_search, '') = ''
           OR email ILIKE '%' || p_search || '%' OR name ILIKE '%' || p_search || '%')
      AND (coalesce(p_stage, '')  = '' OR stage  = p_stage)
      AND (coalesce(p_style, '')  = '' OR top_uid = p_style)
      AND (coalesce(p_source, '') = '' OR source = p_source)
      AND (coalesce(p_purchase, '') = ''
           OR (p_purchase = 'any'  AND purchases > 0)
           OR (p_purchase = 'none' AND purchases = 0)
           OR stage ILIKE CASE p_purchase WHEN 'solo' THEN '%Solo%' WHEN 'bundle' THEN '%Bundle%'
                                          WHEN 'conversations' THEN '%Conversations%' ELSE '-' END)
  )
  SELECT jsonb_build_object(
    'people_total', (SELECT count(*) FROM base),
    'stages', coalesce((SELECT jsonb_object_agg(stage, n) FROM (
        SELECT stage, count(*) AS n FROM base GROUP BY stage) x), '{}'),
    'total', (SELECT count(*) FROM filtered),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(r) - 'top_uid' ORDER BY r.last_quiz_at DESC) FROM (
        SELECT * FROM filtered ORDER BY last_quiz_at DESC
        LIMIT greatest(1, least(p_limit, 5000)) OFFSET greatest(0, p_offset)) r), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

-- ── Person timeline: adds purchases ────────────────────────────────────────
CREATE OR REPLACE FUNCTION enm_dash_person(p_email TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
  v_email TEXT := lower(trim(p_email));
BEGIN
  IF NOT enm_is_quiz_admin() THEN
    RAISE EXCEPTION 'Not on the quiz admin allowlist';
  END IF;

  WITH runs AS (
    SELECT * FROM enm_quiz_runs_v WHERE email = v_email AND session_id IS NOT NULL
  ),
  items AS (
    SELECT r.completed_at AS at,
           CASE WHEN row_number() OVER (ORDER BY r.completed_at) = 1 THEN 'Took the quiz' ELSE 'Retook the quiz' END AS what,
           r.result_title || coalesce(' (source: ' || enm_source_group(r.utm_source, r.utm_medium)
             || coalesce(', ' || nullif(r.utm_campaign, ''), '') || ')', '') AS detail
    FROM runs r
    UNION ALL
    SELECT e.created_at,
           CASE e.event
             WHEN 'save_pdf'          THEN 'Saved results as PDF'
             WHEN 'roadmap_click'     THEN 'Clicked their roadmap'
             WHEN 'book_call_click'   THEN 'Clicked Schedule a call'
             WHEN 'partner_invite_sent' THEN 'Invited a partner'
             WHEN 'result_rating'     THEN 'Rated their result'
             WHEN 'result_rating_comment' THEN 'Left a note'
           END,
           CASE e.event
             WHEN 'result_rating' THEN
               CASE e.meta ->> 'rating' WHEN 'spot_on' THEN 'Spot on' WHEN 'partly' THEN 'Partly'
                 WHEN 'not_really' THEN 'Not really' ELSE coalesce(e.meta ->> 'rating', '') END
               || coalesce(' (' || (e.meta ->> 'stars') || CASE WHEN e.meta ->> 'stars' = '1' THEN ' star)' ELSE ' stars)' END, '')
             WHEN 'result_rating_comment' THEN e.meta ->> 'comment'
             WHEN 'roadmap_click' THEN e.meta ->> 'result_title'
             ELSE NULL
           END
    FROM enm_quiz_events e
    JOIN runs r ON r.run_id = e.run_id
    WHERE e.event IN ('save_pdf', 'roadmap_click', 'book_call_click', 'partner_invite_sent',
                      'result_rating_comment')
       -- answers can change before Send, so only the final rating per run
       OR e.id IN (SELECT DISTINCT ON (x.run_id) x.id FROM enm_quiz_events x
                   JOIN runs rr ON rr.run_id = x.run_id
                   WHERE x.event = 'result_rating' ORDER BY x.run_id, x.created_at DESC)
    UNION ALL
    SELECT p.purchased_at, 'Bought ' || p.product,
           to_char(p.amount_cents / 100.0, 'FM999990.00') || ' ' || upper(coalesce(p.currency, ''))
    FROM enm_quiz_purchases_v p WHERE p.email = v_email
  )
  SELECT jsonb_build_object(
    'person', (SELECT to_jsonb(p) - 'top_uid' FROM enm_quiz_people_v p WHERE p.email = v_email),
    'items', coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.at DESC) FROM items i), '[]')
  ) INTO v_out;

  RETURN v_out;
END;
$$;

REVOKE ALL ON enm_quiz_purchases_v, enm_quiz_people_v FROM anon, PUBLIC;
GRANT SELECT ON enm_quiz_purchases_v, enm_quiz_people_v TO authenticated;
REVOKE EXECUTE ON FUNCTION enm_dash_purchases(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN),
  enm_dash_people(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, TEXT, TEXT, INT, INT, TEXT),
  enm_dash_person(TEXT) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION enm_dash_purchases(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN),
  enm_dash_people(TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN, TEXT, TEXT, TEXT, TEXT, INT, INT, TEXT),
  enm_dash_person(TEXT) TO authenticated;
