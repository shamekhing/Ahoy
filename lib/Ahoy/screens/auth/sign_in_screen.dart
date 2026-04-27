import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/auth/password_field.dart';

class SignInScreen extends StatefulWidget {
  final VoidCallback onSignUp;
  final Future<void> Function() onSignedIn;

  const SignInScreen({super.key, required this.onSignUp, required this.onSignedIn});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _checkBiometric = true;

  @override
  void initState() {
    super.initState();
    _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    if (!_checkBiometric) return;
    _checkBiometric = false;
    final auth = context.read<AuthProvider>();
    final available = await auth.isBiometricAvailable;
    final enabled = await auth.isBiometricEnabled;
    if (available && enabled) {
      final ok = await auth.signInWithBiometric();
      if (ok && mounted) widget.onSignedIn();
    }
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final auth = context.read<AuthProvider>();
    final ok = await auth.signIn(password: _passwordCtrl.text);
    if (mounted) setState(() => _loading = false);
    if (ok && mounted) widget.onSignedIn();
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/app_icon.png', width: 64, height: 64),
                  const SizedBox(height: 12),
                  Text('Ahoy', style: Theme.of(context).textTheme.headlineLarge),
                  const SizedBox(height: 4),
                  Text('Offline P2P Messaging',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
                  const SizedBox(height: 32),
                  PasswordField(controller: _passwordCtrl),
                  if (auth.error != null) ...[
                    const SizedBox(height: 8),
                    Text(auth.error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : _signIn,
                      child: _loading
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Sign In'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _BiometricButton(onSignedIn: widget.onSignedIn),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: () {
                      auth.clearError();
                      widget.onSignUp();
                    },
                    child: const Text("Don't have an account? Sign Up"),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BiometricButton extends StatefulWidget {
  final Future<void> Function() onSignedIn;
  const _BiometricButton({required this.onSignedIn});

  @override
  State<_BiometricButton> createState() => _BiometricButtonState();
}

class _BiometricButtonState extends State<_BiometricButton> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final auth = context.read<AuthProvider>();
    final available = await auth.isBiometricAvailable;
    final enabled = await auth.isBiometricEnabled;
    if (mounted && available && enabled) setState(() => _show = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    return OutlinedButton.icon(
      icon: const Icon(Icons.fingerprint),
      label: const Text('Use Biometric'),
      onPressed: () async {
        final auth = context.read<AuthProvider>();
        final ok = await auth.signInWithBiometric();
        if (ok && mounted) widget.onSignedIn();
      },
    );
  }
}
