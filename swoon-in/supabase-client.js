// Supabase client for the SWOON admin pages (in.swoon.coach).
//
// Mirrors enm-quiz/supabase-client.js — same project, same exported surface,
// so any admin page in this folder can `import { supabase } from
// '../supabase-client.js'` or `./supabase-client.js` interchangeably.
//
// The anon key is a public, RLS-gated key — it is safe in client code.
const SUPABASE_URL = 'https://ohcdjvbveokyyilceenf.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9oY2RqdmJ2ZW9reXlpbGNlZW5mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTQ5OTEsImV4cCI6MjA5MDk5MDk5MX0.UlboaX6cVgJwmjxo0e30CgmCtbz9ByHmawclKKShlQ0';

// Namespaces the stored session. This host is admin-only, but the quiz lives
// on a different origin already using 'swoon-quiz-auth', so keep them apart
// anyway in case the two ever share an origin.
const AUTH_STORAGE_KEY = 'swoon-admin-auth';

const AUTH_OPTIONS = {
  autoRefreshToken: true,
  persistSession: true,
  detectSessionInUrl: true,
  storage: window.localStorage,
  storageKey: AUTH_STORAGE_KEY,
  flowType: 'pkce',
};

// The vendor bundle is a plain <script> and this is a module, so on a cold load
// the module can evaluate first. Poll briefly rather than failing outright.
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
  try {
    await waitForSupabase();
  } catch (err) {
    console.error(
      '[supabase] Vendor bundle not found on window.supabase — the page is missing ' +
      '<script src="../vendor/supabase-js-2.39.3.min.js"></script> (or ./vendor/… for ' +
      'top-level pages) before its module script, or that file failed to load.'
    );
    throw err;
  }
}

const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: AUTH_OPTIONS });

// Mobile browsers suspend backgrounded tabs, so the auto-refresh timer doesn't
// fire and the JWT can expire while the page is hidden. Exchange the refresh
// token as soon as the user comes back.
if (typeof document !== 'undefined') {
  let lastVisibleAt = Date.now();
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && Date.now() - lastVisibleAt > 5 * 60 * 1000) {
      supabase.auth.getSession().then(({ data }) => {
        if (data?.session) supabase.auth.refreshSession();
      });
    }
    lastVisibleAt = Date.now();
  });
}

/**
 * Resolves once the auth layer has settled — i.e. supabase-js has restored a
 * persisted session, or consumed the tokens in a PKCE redirect URL, or decided
 * there is no session at all. Mirrors the export of the same name in the quiz
 * client: pages call this before getSession() + the enm_is_quiz_admin RPC so an
 * admin arriving from a sign-in redirect isn't checked against a session that
 * hasn't landed yet.
 */
function waitForAuthReady(timeoutMs = 5000) {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      sub?.data?.subscription?.unsubscribe();
      resolve();
    };
    // Never hang the admin check on an auth event that never arrives.
    const timer = setTimeout(finish, timeoutMs);
    const sub = supabase.auth.onAuthStateChange((event) => {
      if (event === 'INITIAL_SESSION' || event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') finish();
    });
    // Covers the case where the session was already restored before we subscribed.
    supabase.auth.getSession().then(({ data }) => { if (data?.session) finish(); });
  });
}

export { supabase, SUPABASE_URL, SUPABASE_ANON_KEY, waitForAuthReady };