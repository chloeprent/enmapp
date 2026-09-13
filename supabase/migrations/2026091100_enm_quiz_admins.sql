-- Page-scoped admin allowlist for the ENM quiz.
--
-- This project has no app_users/site-wide-role system (unlike the property-
-- management template this quiz was ported from), so the quiz's own admin
-- check is just this allowlist: an email on it can read quiz results and use
-- the review panel. Keyed on email rather than a user id so someone can be
-- added before they have ever signed in; it starts working the moment they
-- authenticate.

CREATE TABLE IF NOT EXISTS enm_quiz_admins (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email      TEXT NOT NULL,
  note       TEXT,
  added_by   UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_enm_quiz_admins_email
  ON enm_quiz_admins (lower(email));

/*
 * True for anyone on the quiz allowlist.
 *
 * SECURITY DEFINER so it can read the allowlist without that table having to
 * be world-readable, and so the policies that call it cannot recurse into it.
 */
CREATE OR REPLACE FUNCTION enm_is_quiz_admin() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM enm_quiz_admins
    WHERE lower(email) = lower(NULLIF(auth.jwt() ->> 'email', ''))
  );
$$;

GRANT EXECUTE ON FUNCTION enm_is_quiz_admin() TO authenticated, anon;

ALTER TABLE enm_quiz_admins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "enm_quiz_admins_self_select" ON enm_quiz_admins;
CREATE POLICY "enm_quiz_admins_self_select" ON enm_quiz_admins
  FOR SELECT USING (enm_is_quiz_admin());

INSERT INTO enm_quiz_admins (email, note) VALUES
  ('chloeprent@gmail.com', 'Quiz design review.'),
  ('chloe@swoon.coach', 'Quiz design review.'),
  ('rahulioson@gmail.com', 'Quiz design review.')
ON CONFLICT (lower(email)) DO NOTHING;
