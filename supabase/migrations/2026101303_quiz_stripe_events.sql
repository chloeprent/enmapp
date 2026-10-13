-- Every call Stripe makes to quiz-stripe-webhook is noted here (event type and
-- what was done), so we can prove purchases arrive instantly. No card or
-- personal data. Admin read only, written by the function (service role).
CREATE TABLE IF NOT EXISTS quiz_stripe_events (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_id    TEXT,
  type        TEXT,
  result      TEXT,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS quiz_stripe_events_at_idx ON quiz_stripe_events (received_at);
ALTER TABLE quiz_stripe_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON quiz_stripe_events FROM anon, PUBLIC;
GRANT SELECT ON quiz_stripe_events TO authenticated;
DROP POLICY IF EXISTS quiz_stripe_events_admin_read ON quiz_stripe_events;
CREATE POLICY quiz_stripe_events_admin_read ON quiz_stripe_events FOR SELECT TO authenticated USING (enm_is_quiz_admin());
