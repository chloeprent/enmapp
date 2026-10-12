-- Read-only look before Phase 2 (Stripe purchases). Structure only.

-- == 1. Tables that could already hold Stripe or purchase data
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' AND (table_name ILIKE '%stripe%' OR table_name ILIKE '%purchase%' OR table_name ILIKE '%order%' OR table_name ILIKE '%payment%')
ORDER BY 1;

-- == 2. Stripe settings row present (no secrets printed)
SELECT count(*) AS stripe_config_rows FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'stripe_config';
