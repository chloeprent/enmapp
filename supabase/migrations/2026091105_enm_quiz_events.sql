-- Funnel analytics for the ENM quiz.
--
-- Until now the quiz wrote nothing until the email gate at the very end, so
-- there was no way to see hits or where people stopped. The page now emits one
-- small row per step from its client (same anon insert pattern as the feedback
-- table): page_view, start, question_answered (1..N), gate, result.
--
-- No personal info: run_id is the random UUID the page already generates, and
-- nothing here identifies a person.

CREATE TABLE IF NOT EXISTS enm_quiz_events (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id          UUID NOT NULL,
  event           TEXT NOT NULL,
  question_number INTEGER,
  meta            JSONB NOT NULL DEFAULT '{}'::jsonb,
  referrer        TEXT,
  user_agent      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_enm_events_run      ON enm_quiz_events(run_id);
CREATE INDEX IF NOT EXISTS idx_enm_events_event    ON enm_quiz_events(event);
CREATE INDEX IF NOT EXISTS idx_enm_events_question ON enm_quiz_events(question_number) WHERE question_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_enm_events_created  ON enm_quiz_events(created_at DESC);

ALTER TABLE enm_quiz_events ENABLE ROW LEVEL SECURITY;

-- Anyone mid-quiz can emit an event; only quiz admins can read them.
DROP POLICY IF EXISTS "enm_events_anon_insert" ON enm_quiz_events;
CREATE POLICY "enm_events_anon_insert" ON enm_quiz_events
  FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "enm_events_staff_select" ON enm_quiz_events;
CREATE POLICY "enm_events_staff_select" ON enm_quiz_events
  FOR SELECT USING (enm_is_quiz_admin());