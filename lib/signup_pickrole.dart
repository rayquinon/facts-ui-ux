import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'instructor_page.dart';
import 'student_page.dart';

enum UserRole { instructor, student }

extension UserRoleX on UserRole {
  String get label => this == UserRole.instructor ? 'Instructor' : 'Student';
  IconData get icon => this == UserRole.instructor
      ? Icons.school_outlined
      : Icons.person_outline;
  String get subtitle => this == UserRole.instructor
      ? 'Manage classes, monitor attendance, and review analytics.'
      : 'View your personal attendance history and stay informed.';
}

class SignupPickRolePage extends StatefulWidget {
  const SignupPickRolePage({super.key});

  static const String routeName = '/signup/role';

  @override
  State<SignupPickRolePage> createState() => _SignupPickRolePageState();
}

class _SignupPickRolePageState extends State<SignupPickRolePage> {
  UserRole? _selectedRole;

  void _handleContinue() {
    final UserRole? role = _selectedRole;
    if (role == null) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SignUpPage(role: role),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Choose your role')),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool isWide = constraints.maxWidth >= 900;
          final Widget roleCards = isWide
              ? Row(
                  children: UserRole.values
                      .map(
                        (UserRole role) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _RoleSelectionCard(
                              role: role,
                              isSelected: _selectedRole == role,
                              onTap: () => setState(() => _selectedRole = role),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                )
              : Column(
                  children: UserRole.values
                      .map(
                        (UserRole role) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: _RoleSelectionCard(
                            role: role,
                            isSelected: _selectedRole == role,
                            onTap: () => setState(() => _selectedRole = role),
                          ),
                        ),
                      )
                      .toList(),
                );

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Create your F.A.C.T.S. account',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Choose the role that best matches how you will use the platform.',
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 32),
                    roleCards,
                    const SizedBox(height: 32),
                    FilledButton.icon(
                      onPressed: _selectedRole == null ? null : _handleContinue,
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: Text(
                        _selectedRole == null
                            ? 'Select a role to continue'
                            : 'Continue as ${_selectedRole!.label}',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RoleSelectionCard extends StatelessWidget {
  const _RoleSelectionCard({
    required this.role,
    required this.isSelected,
    required this.onTap,
  });

  final UserRole role;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Ink(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isSelected ? colors.primary : colors.outlineVariant,
            width: 2,
          ),
          color: isSelected
              ? colors.primaryContainer.withValues(alpha: 0.4)
              : colors.surfaceContainerHighest.withValues(alpha: 0.4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(role.icon, size: 36, color: colors.primary),
            const SizedBox(height: 16),
            Text(
              role.label,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(role.subtitle, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key, required this.role});

  final UserRole role;

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _studentIdController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  static const List<String> _departments = <String>[
    'Department of Information Technology',
    'Department of Technology Livelihood and Education',
    'Department of Food Processing Technology',
  ];
  String? _selectedDepartment;
  bool _obscurePassword = true;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _studentIdController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleSignUp() async {
    final bool isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid || _isSubmitting) return;

    FocusScope.of(context).unfocus();
    setState(() => _isSubmitting = true);

    final bool isInstructor = widget.role == UserRole.instructor;
    final String email = _emailController.text.trim();
    final String password = _passwordController.text.trim();
    final String fullName = _nameController.text.trim();
    final String? department = _selectedDepartment;
    final String? studentId = isInstructor
        ? null
        : _studentIdController.text.trim();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    try {
      final UserCredential credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      final User? user = credential.user;
      if (user != null) {
        await user.updateDisplayName(fullName);
        final Map<String, dynamic> profile = <String, dynamic>{
          'Full Name': fullName,
          'Email': email,
          'role': widget.role.name,
          'createdAt': FieldValue.serverTimestamp(),
        };
        if (isInstructor) {
          profile['Department'] = department;
        } else {
          profile['Student ID'] = studentId;
        }
        profile.removeWhere((_, Object? value) => value == null);
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set(profile, SetOptions(merge: true));
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text('Welcome aboard, $fullName!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (mounted) {
        final String destinationRoute = isInstructor
            ? InstructorPage.routeName
            : StudentPage.routeName;
        Navigator.of(context).pushNamedAndRemoveUntil(
          destinationRoute,
          (Route<dynamic> route) => false,
        );
      }
    } on FirebaseAuthException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(_mapSignUpError(error)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FirebaseException catch (error, stackTrace) {
      debugPrint('Firestore write failed: ${error.code} -> ${error.message}\n$stackTrace');
      messenger.showSnackBar(
        SnackBar(
          content: Text('Firestore write failed (${error.code}).'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unexpected signup error: $error\n$stackTrace');
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String roleLabel = widget.role.label;
    final bool isInstructor = widget.role == UserRole.instructor;
    return Scaffold(
      appBar: AppBar(title: Text('Sign up as $roleLabel')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          'Create a $roleLabel account',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 24),
                        TextFormField(
                          controller: _nameController,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          validator: (String? value) {
                            if ((value ?? '').trim().isEmpty) {
                              return 'Please enter your full name';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const <String>[AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'Email address',
                            prefixIcon: Icon(Icons.mail_outline),
                          ),
                          validator: (String? value) {
                            final String email = (value ?? '').trim();
                            if (email.isEmpty) {
                              return 'Please enter your email';
                            }
                            final RegExp emailRegex = RegExp(
                              r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                            );
                            if (!emailRegex.hasMatch(email)) {
                              return 'Enter a valid email address';
                            }
                            return null;
                          },
                        ),
                        if (!isInstructor) ...<Widget>[
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _studentIdController,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.next,
                            inputFormatters: <TextInputFormatter>[
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Student ID',
                              prefixIcon: Icon(
                                Icons.confirmation_number_outlined,
                              ),
                            ),
                            validator: (String? value) {
                              final String trimmed = (value ?? '').trim();
                              if (trimmed.isEmpty) {
                                return 'Please enter your student ID';
                              }
                              if (int.tryParse(trimmed) == null) {
                                return 'Student ID must contain digits only';
                              }
                              return null;
                            },
                          ),
                        ],
                        if (isInstructor) ...<Widget>[
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            initialValue: _selectedDepartment,
                            isExpanded: true,
                            items: _departments
                                .map(
                                  (String dept) => DropdownMenuItem<String>(
                                    value: dept,
                                    child: Text(
                                      dept,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            selectedItemBuilder: (BuildContext context) =>
                                _departments
                                    .map(
                                      (String dept) => Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          dept,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                            decoration: const InputDecoration(
                              labelText: 'Department',
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                            onChanged: (String? value) =>
                                setState(() => _selectedDepartment = value),
                            validator: (String? value) {
                              if (value == null || value.isEmpty) {
                                return 'Please select a department';
                              }
                              return null;
                            },
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordController,
                          textInputAction: TextInputAction.next,
                          autofillHints: const <String>[AutofillHints.newPassword],
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          obscureText: _obscurePassword,
                          validator: (String? value) {
                            if ((value ?? '').length < 6) {
                              return 'Password must be at least 6 characters';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirmPasswordController,
                          textInputAction: TextInputAction.done,
                          autofillHints: const <String>[AutofillHints.newPassword],
                          decoration: const InputDecoration(
                            labelText: 'Confirm password',
                            prefixIcon: Icon(Icons.lock_person_outlined),
                          ),
                          obscureText: true,
                          validator: (String? value) {
                            if (value != _passwordController.text) {
                              return 'Passwords do not match';
                            }
                            return null;
                          },
                          onFieldSubmitted: (_) => _handleSignUp(),
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _isSubmitting ? null : _handleSignUp,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          child: _isSubmitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : const Text('Sign up'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _mapSignUpError(FirebaseAuthException error) {
  switch (error.code) {
    case 'email-already-in-use':
      return 'An account already exists for that email.';
    case 'weak-password':
      return 'Password is too weak. Try a stronger one.';
    case 'invalid-email':
      return 'That email address looks invalid.';
    case 'operation-not-allowed':
      return 'Email/password sign-up is disabled for this project.';
    default:
      return 'Sign up failed (${error.code}). Please try again.';
  }
}
