import 'package:supabase_flutter/supabase_flutter.dart';

/// True when Supabase was initialized (i.e. the app was built with
/// --dart-define SUPABASE_URL + SUPABASE_ANON_KEY). When false the app runs in
/// local-only mode against the Node dev server.
bool cloudReady() {
  try {
    Supabase.instance.client;
    return true;
  } catch (_) {
    return false;
  }
}

SupabaseClient get _c => Supabase.instance.client;

/// True when a live Supabase session exists (the auth source of truth — the
/// local `signedIn` flag is only a UI hint and must never grant access alone).
bool hasSession() {
  if (!cloudReady()) return false;
  return _c.auth.currentSession != null;
}

/// True when the current user is a guest (anonymous) — not a real account yet.
bool isGuest() {
  if (!cloudReady()) return true;
  final u = _c.auth.currentUser;
  return u == null || u.isAnonymous || (u.email == null || u.email!.isEmpty);
}

/// The signed-in account email, or null for guests.
String? currentEmail() {
  if (!cloudReady()) return null;
  final e = _c.auth.currentUser?.email;
  return (e == null || e.isEmpty) ? null : e;
}

/// Upgrade the current anonymous guest into a permanent email account — keeps
/// all their data (same user id). Email autoconfirm is on, so it's immediate.
Future<void> createAccount(String email, String password) async {
  await _c.auth.updateUser(UserAttributes(email: email, password: password));
}

/// Sign in to an existing email account (replaces the current session/user).
Future<void> signIn(String email, String password) async {
  await _c.auth.signInWithPassword(email: email, password: password);
}

/// Register a brand-new email account (autoconfirm is on → session lands
/// immediately). Never touches whatever session existed before.
Future<void> signUp(String email, String password) async {
  await _c.auth.signUp(email: email, password: password);
}

/// Sign out. A fresh anonymous session can be re-established via [ensureSession].
Future<void> signOut() async {
  if (cloudReady()) await _c.auth.signOut();
}

/// DUMMY LOGIN (interim, SDD §14.2): establish an ANONYMOUS Supabase session —
/// a real JWT with no email/Google/OAuth — so the cloud backend (Edge Functions
/// + RLS + server-authoritative quota) works end to end. The signup trigger
/// provisions the user's `profiles` + `entitlements` rows.
/// No-op if cloud is off or a session already exists (sessions persist across
/// launches). Real email/Google auth replaces this later.
// DEV HARDCODE: the owner's permanent unlimited account. Every fresh install
// signs straight into it (after onboarding), instead of minting an anonymous
// user. Replace with real auth before any external release.
const _devEmail = 'petrov.cpay@gmail.com';
const _devPassword = 'Looktok-Dev-2026';

Future<void> ensureSession() async {
  if (!cloudReady()) return;
  final auth = Supabase.instance.client.auth;
  if (auth.currentSession != null) return;
  try {
    await auth.signInWithPassword(email: _devEmail, password: _devPassword);
  } catch (_) {
    // Account missing on this project (e.g. fresh env) → fall back to anonymous
    // so the app still works; entitlement then follows that user's row.
    await auth.signInAnonymously();
  }
}
