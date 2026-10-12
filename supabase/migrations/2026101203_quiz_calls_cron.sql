-- Keep quiz_calls fresh: ask quiz-calls to copy TidyCal bookings every 15 minutes.
-- The function needs no key for "sync" (it returns counts only).
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'quiz-calls-sync';
SELECT cron.schedule('quiz-calls-sync', '*/15 * * * *', $$
  SELECT net.http_post(
    url     := 'https://ohcdjvbveokyyilceenf.supabase.co/functions/v1/quiz-calls',
    body    := '{"action":"sync"}'::jsonb,
    headers := '{"Content-Type":"application/json"}'::jsonb);
$$);
