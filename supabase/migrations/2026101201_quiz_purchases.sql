-- Quiz dashboard phase 2: Stripe purchases.
--
-- quiz_purchases holds one row per product bought, written only by the
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
