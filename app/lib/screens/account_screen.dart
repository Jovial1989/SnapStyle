import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import '../services/auth.dart' as auth;
import '../theme.dart';

/// Create a real account (upgrades the anonymous guest, keeping their data) or
/// sign in to an existing one. Email only for now — Google lands later (SDD §14.2b).
/// Pops `true` on success.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key, this.signIn = false});
  final bool signIn;
  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  late bool _signIn = widget.signIn;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pass = _pass.text;
    if (!email.contains('@') || pass.length < 6) {
      setState(() => _error = 'Enter a valid email and a password of at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signIn) {
        await auth.signIn(email, pass);
      } else {
        await auth.createAccount(email, pass);
      }
      // New/changed identity → refresh user-scoped data.
      ref.invalidate(bodyProfileProvider);
      ref.invalidate(entitlementProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() { _busy = false; _error = e.message; });
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = 'Something went wrong. Try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_signIn ? 'Sign in' : 'Create account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
            Text(_signIn ? 'Welcome back.' : 'Save your looks.', style: AppType.display),
            const SizedBox(height: 10),
            Text(
              _signIn
                  ? 'Sign in to sync your profile, wardrobe and looks.'
                  : 'Create an account to keep your profile, wardrobe and looks — on any device.',
              style: AppType.body,
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: AppColors.flag, fontSize: 13)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(_signIn ? 'Sign in' : 'Create account'),
            ),
            const SizedBox(height: 14),
            Center(
              child: TextButton(
                onPressed: _busy ? null : () => setState(() { _signIn = !_signIn; _error = null; }),
                child: Text(_signIn ? 'New here? Create an account' : 'Already have an account? Sign in'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
