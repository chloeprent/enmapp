// Supabase client for in.swoon.coach.
//
// Standalone replacement for the AlpacApps-wide /shared/supabase.js — same
// exported surface (`supabase`), trimmed to what this page actually uses.
// Same Supabase project as the rest of the app (tables, edge functions and
// auth users are already live there).
const SUPABASE_URL = 'https://aphrrfprbixmhissnjfn.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFwaHJyZnByYml4bWhpc3NuamZuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk5MzA0MjUsImV4cCI6MjA4NTUwNjQyNX0.yYkdQIq97GQgxK7yT2OQEPi5Tt-a7gM45aF8xjSD6wk';

// Namespaces the stored session so it doesn't clobber other AlpacApps deploys
// sharing the browser (each origin has its own localStorage anyway, but this
// keeps the key self-descriptive if that ever changes).
const AUTH_STORAGE_KEY = 'swoon-in-auth';

function waitForSupabase(maxAttempts = 50) {
  return new Promise((resolve, reject) => {
    let attempts = 0;
    const check = () => {
      if (window.supabase?.createClient) resolve(window.supabase);
      else if (attempts >= maxAttempts) reject(new Error('Supabase library failed to load'));
      else { attempts++; setTimeout(check, 100); }
    };
    check();
  });
}

if (!window.supabase?.createClient) {
  await waitForSupabase();
}

const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
    storage: window.localStorage,
    storageKey: AUTH_STORAGE_KEY,
    flowType: 'pkce',
  },
});

export { supabase };
