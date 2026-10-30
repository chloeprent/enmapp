-- Safety net for purchases: every 5 minutes, reload Stripe checkouts from the
-- last 2 days, so a missed or failed webhook never leaves a purchase out.
-- The webhook stays the main, instant path. "sync" needs no key (counts only).
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'quiz-stripe-sync';
SELECT cron.schedule('quiz-stripe-sync', '*/5 * * * *', $$
  SELECT net.http_post(
    url     := 'https://ohcdjvbveokyyilceenf.supabase.co/functions/v1/quiz-stripe-webhook',
    body    := '{"action":"sync"}'::jsonb,
    headers := '{"Content-Type":"application/json"}'::jsonb);
$$);
