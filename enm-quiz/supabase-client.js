// Supabase client for the ENM quiz.
//
// Standalone replacement for the AlpacApps-wide /shared/supabase.js — same
// exported surface (`supabase`), trimmed to what the quiz pages actually use.
//
// ---------------------------------------------------------------------------
// CONFIG — point these at your project.
// Leave them as-is to keep using the existing AlpacApps Supabase project (the
// tables, edge functions and auth users are already live there). Swap them if
// you stand up your own project from /migrations + /supabase/functions.
// The anon key is a public, RLS-gated key — it is safe in client code.
// ---------------------------------------------------------------------------
const SUPABASE_URL = 'https://ohcdjvbveokyyilceenf.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9oY2RqdmJ2ZW9reXlpbGNlZW5mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU0MTQ5OTEsImV4cCI6MjA5MDk5MDk5MX0.UlboaX6cVgJwmjxo0e30CgmCtbz9ByHmawclKKShlQ0';

// Namespaces the stored session. Change it if this deploy shares an origin with
// another Supabase app, so the two don't clobber each other's tokens.
const AUTH_STORAGE_KEY = 'swoon-quiz-auth';

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

// Without this the module throws during evaluation, every importer is skipped
// silently, and the page sits on its spinner forever with no message. Say what
// is actually wrong instead.
function reportSupabaseLoadFailure() {
  console.error(
    '[supabase] Vendor bundle not found on window.supabase — the page is missing ' +
    '<script src="./vendor/supabase-js-2.39.3.min.js"></script> before its module ' +
    'script, or that file failed to load.'
  );
  if (typeof document === 'undefined') return;
  const overlay = document.getElementById('loadingOverlay');
  if (!overlay) return;
  overlay.classList.remove('hidden');
  overlay.style.display = 'flex';
  overlay.innerHTML =
    '<div style="max-width:26rem;padding:1.5rem;text-align:center;' +
    'font:400 0.95rem/1.55 system-ui,sans-serif;color:#4a423f;">' +
    "<p style=\"margin:0 0 0.75rem;font-weight:600;\">This page didn't finish loading.</p>" +
    '<p style="margin:0;">Please reload the page.</p></div>';
}

if (!window.supabase?.createClient) {
  try {
    await waitForSupabase();
  } catch (err) {
    reportSupabaseLoadFailure();
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
        if (!data?.session) supabase.auth.refreshSession();
      });
    }
    lastVisibleAt = Date.now();
  });
}

/**
 * Resolves once the auth layer has settled — i.e. supabase-js has restored a
 * persisted session, or consumed the tokens in a PKCE redirect URL, or decided
 * there is no session at all.
 *
 * The quiz page calls this before `getSession()` + the `enm_is_quiz_admin` RPC,
 * so an admin arriving straight from a sign-in redirect isn't checked against a
 * session that hasn't landed yet. Upstream this was AlpacApps' site-wide
 * `/shared/auth.js` initAuth(), which also loads roles and permissions from
 * `app_users`; the quiz used none of that — only the settling — so this export
 * keeps just the settling and drops the dependency.
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
