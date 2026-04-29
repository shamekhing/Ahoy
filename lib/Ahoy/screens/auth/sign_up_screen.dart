import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../core/enums.dart';
import '../../widgets/auth/password_field.dart';

class SignUpScreen extends StatefulWidget {
  final VoidCallback onSignIn;
  final Future<void> Function() onSignedUp;

  const SignUpScreen({super.key, required this.onSignIn, required this.onSignedUp});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  Gender _gender = Gender.unspecified;
  final List<String> _interests = [];
  bool _loading = false;

  static const _interestOptions = [
    'Music', 'Tech', 'Sports', 'Food', 'Travel', 'Art', 'Gaming', 'Reading', 'Fitness', 'Nature'
  ];

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final auth = context.read<AuthProvider>();
    final ok = await auth.signUp(
      username: _usernameCtrl.text.trim(),
      password: _passwordCtrl.text,
      gender: _gender,
      interests: _interests,
      bio: _bioCtrl.text.trim().isEmpty ? null : _bioCtrl.text.trim(),
    );
    if (mounted) setState(() => _loading = false);
    if (ok && mounted) {
      await widget.onSignedUp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Column(
                  children: [
                    SvgPicture.asset('assets/app_icon.svg', width: 64, height: 64),
                    const SizedBox(height: 12),
                    Text('Create your Ahoy profile', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
              TextFormField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Display Name',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Name cannot be empty' : null,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              PasswordField(
                controller: _passwordCtrl,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _bioCtrl,
                decoration: const InputDecoration(
                  labelText: 'Bio (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
                maxLength: 200,
              ),
              const SizedBox(height: 8),
              Text('I am:', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              SegmentedButton<Gender>(
                segments: const [
                  ButtonSegment(value: Gender.male, label: Text('Male')),
                  ButtonSegment(value: Gender.female, label: Text('Female')),
                  ButtonSegment(value: Gender.unspecified, label: Text('Other')),
                ],
                selected: {_gender},
                onSelectionChanged: (s) {
                  if (s.isNotEmpty) {
                    setState(() => _gender = s.first);
                  }
                },
              ),
              const SizedBox(height: 16),
              Text('Interests (optional):', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _interestOptions.map((interest) {
                  final selected = _interests.contains(interest);
                  return FilterChip(
                    label: Text(interest),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _interests.add(interest);
                      } else {
                        _interests.remove(interest);
                      }
                    }),
                  );
                }).toList(),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 12),
                Text(auth.error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading ? null : _signUp,
                  child: _loading
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Create Account'),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: () {
                    auth.clearError();
                    widget.onSignIn();
                  },
                  child: const Text('Already have an account? Sign In'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
