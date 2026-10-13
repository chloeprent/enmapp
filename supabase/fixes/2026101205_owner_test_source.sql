-- One-off correction requested by the owner: their test visit with
-- chloeprent+testenm90@gmail.com came through the landing page, so record it
-- as Website / landing. Only this test email is touched; safe to re-run.
UPDATE enm_quiz_leads
SET utm_source = 'website', utm_medium = 'landing', utm_campaign = NULL
WHERE lower(email) = 'chloeprent+testenm90@gmail.com';

UPDATE enm_quiz_events e
SET meta = jsonb_set(coalesce(e.meta, '{}'), '{utm}', '{"source": "website", "medium": "landing"}')
WHERE e.run_id IN (
  SELECT s.run_id FROM enm_quiz_sessions s JOIN enm_quiz_leads l ON l.id = s.lead_id
  WHERE lower(l.email) = 'chloeprent+testenm90@gmail.com');
