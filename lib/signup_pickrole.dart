import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'instructor_page.dart';
import 'student_page.dart';
import 'verify_email_page.dart';
import 'services/user_role_service.dart';
import 'widgets/clay_surface.dart';

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
                      label: Flexible(
                        child: Text(
                          _selectedRole == null
                              ? 'Select a role to continue'
                              : 'Continue as ${_selectedRole!.label}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
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

    final BoxDecoration baseDecoration = ClaySurface.decoration(
      context,
      borderRadius: BorderRadius.circular(24),
      color: isSelected
          ? colors.primaryContainer.withValues(alpha: 0.42)
          : colors.surfaceContainerHighest.withValues(alpha: 0.40),
    );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Ink(
        padding: const EdgeInsets.all(24),
        decoration: baseDecoration.copyWith(
          border: Border.all(
            color: isSelected ? colors.primary : colors.outlineVariant,
            width: 2,
          ),
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
  final TextEditingController _sectionSearchController =
      TextEditingController();
  final MenuController _sectionMenuController = MenuController();
  static const List<String> _departments = <String>[
    'Department of Information Technology',
    'Department of Technology Livelihood and Education',
    'Department of Food Processing Technology',
  ];
  String? _selectedDepartment;
  List<String> _availableSections = <String>[];
  bool _isLoadingSections = false;
  String? _sectionsError;
  String? _selectedStudentSection;
  bool _studentPrivacyConsent = false;
  bool _obscurePassword = true;
  bool _isSubmitting = false;

  static const String _privacyHeader =
      'F.A.C.T.S. Student Data Privacy Notice and Consent\n'
      'Personal Information Controller: University of Science and Technology of Southern Philippines (USTP) – Oroquieta Campus\n\n'
      'This notice explains how F.A.C.T.S. processes your personal data for account creation and attendance verification. By consenting, you provide your informed consent for the processing described below, consistent with the Data Privacy Act of 2012 (Republic Act No. 10173) and its Implementing Rules and Regulations.';

  static const List<Map<String, String>> _privacyParts = <Map<String, String>>[
    <String, String>{'title': 'Part 1: Overview', 'body': _privacyHeader},
    <String, String>{
      'title': 'Part 2: Data We Collect',
      'body':
          '1) Personal data we collect\n'
          '• Identifying and account data: full name, email address, student ID, section.\n'
          '• Attendance data: date/time of attendance, subject/class, attendance history.\n'
          '• Face verification data (embeddings only): during enrollment/verification, the app scans your face using your device camera and generates a face embedding/template (a numeric representation) used for matching.',
    },
    <String, String>{
      'title': 'Part 3: What We Do Not Store',
      'body':
          '2) What we do NOT store\n'
          '• We do not store raw face photos as the primary identifier for matching. We store face embeddings/templates for verification.',
    },
    <String, String>{
      'title': 'Part 4: How Embeddings Are Used',
      'body':
          '3) How face embeddings are used\n'
          '• Used to confirm your identity during attendance sessions and reduce impersonation/fraud.\n'
          '• Used only for attendance and account-related verification within F.A.C.T.S.',
    },
    <String, String>{
      'title': 'Part 5: Purpose and Legal Basis',
      'body':
          '4) Purpose of processing\n'
          '• Create and manage your student account.\n'
          '• Record, validate, and summarize class attendance.\n'
          '• Support academic reporting by authorized personnel.\n\n'
          '5) Legal basis\n'
          '• Consent: you voluntarily consent to face scanning and the generation/storage/use of your face embedding/template for attendance verification.',
    },
    <String, String>{
      'title': 'Part 6: Access and Disclosures',
      'body':
          '6) Access and disclosures\n'
          '• Access is restricted to authorized roles (e.g., you, your instructor, and designated administrators) as needed for attendance operations and support.\n'
          '• We do not sell your personal data. Data may be processed using cloud services required to operate the system under security and access controls.\n'
          '• Disclosure may occur if required by law or lawful orders.',
    },
    <String, String>{
      'title': 'Part 7: Retention and Deletion',
      'body':
          '7) Retention and deletion\n'
          '• We retain your data and face embeddings only while you are enrolled/affiliated with the school.\n'
          '• Once you graduate, transfer, or are no longer attached to USTP, your data (including face embeddings) will be deleted in accordance with institutional policy and applicable requirements.',
    },
    <String, String>{
      'title': 'Part 8: Your Rights',
      'body':
          '8) Your rights as a data subject\n'
          'You may request access, correction, deletion/blocking where applicable, and withdraw consent subject to applicable rules.',
    },
    <String, String>{
      'title': 'Part 9: Alternative Attendance',
      'body':
          '9) Alternative attendance method\n'
          'If you do not consent to face scanning/embeddings, an alternative method of taking attendance will be used by your instructor/class procedure.\n'
          'Note: Creating a student account in this app requires consent because face-based verification is part of the system design.',
    },
    <String, String>{
      'title': 'Part 10: Ethics and Contact',
      'body':
          '10) Ethical considerations\n'
          '• Face recognition may be affected by lighting, camera quality, or changes in appearance. Attendance disputes should allow human review.\n'
          '• Face embeddings will be used only for attendance verification and related academic purposes stated here, not for surveillance or unrelated profiling.\n\n'
          'Contact for privacy concerns/requests:\n'
          'Academic Head Office (USTP Oroquieta Campus)',
    },
  ];

  @override
  void initState() {
    super.initState();
    if (widget.role == UserRole.student) {
      _loadSections();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _studentIdController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _sectionSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadSections() async {
    setState(() {
      _isLoadingSections = true;
      _sectionsError = null;
    });
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot =
          await FirebaseFirestore.instance.collection('subjects').get();
      final Set<String> uniqueSections = <String>{};
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in snapshot.docs) {
        final List<dynamic> sections =
            (doc.data()['sections'] as List<dynamic>? ?? <dynamic>[]);
        for (final dynamic entry in sections) {
          final String normalized = entry.toString().trim();
          if (normalized.isNotEmpty) {
            uniqueSections.add(normalized);
          }
        }
      }
      final List<String> sorted = uniqueSections.toList()..sort();
      if (!mounted) return;
      setState(() {
        _availableSections = sorted;
        if (_selectedStudentSection != null &&
            !_availableSections.contains(_selectedStudentSection)) {
          _selectedStudentSection = null;
          _sectionSearchController.clear();
        } else if (_selectedStudentSection != null) {
          _sectionSearchController.text = _selectedStudentSection!;
        }
        if (_availableSections.isEmpty) {
          _sectionsError =
              'No sections found. Ask an admin to add sections first.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _sectionsError = 'Failed to load sections. $error');
    } finally {
      if (mounted) {
        setState(() => _isLoadingSections = false);
      }
    }
  }

  Future<void> _handleSignUp() async {
    final bool isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid || _isSubmitting) return;

    final bool isInstructor = widget.role == UserRole.instructor;
    final String email = _emailController.text.trim();
    final String password = _passwordController.text.trim();
    final String fullName = _nameController.text.trim();
    final String? department = _selectedDepartment;
    final String? studentId = isInstructor
        ? null
        : _studentIdController.text.trim();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (!isInstructor) {
      if (!_studentPrivacyConsent) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'You must agree to the Data Privacy Notice to create a student account.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }

    FocusScope.of(context).unfocus();
    setState(() => _isSubmitting = true);

    try {
      final UserCredential credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      final User? user = credential.user;
      if (user != null) {
        // Best-effort: profile data lives in Firestore; don't block signup if
        // updating Auth displayName fails.
        try {
          await user.updateDisplayName(fullName);
        } catch (error, stackTrace) {
          debugPrint('updateDisplayName failed: $error\n$stackTrace');
        }
        final Map<String, dynamic> profile = <String, dynamic>{
          'displayName': fullName,
          'Full Name': fullName,
          'Email': email,
          'role': widget.role.name,
          'createdAt': FieldValue.serverTimestamp(),
        };
        if (isInstructor) {
          profile['Department'] = department;
          profile['approved'] = false;
        } else {
          profile['Student ID'] = studentId;
          profile['section'] = _selectedStudentSection;
        }
        profile.removeWhere((_, Object? value) => value == null);
        if (isInstructor) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .set(profile, SetOptions(merge: true));
        } else {
          await UserRoleService.upsertStudentProfileWithUniqueStudentId(
            uid: user.uid,
            studentId: studentId ?? '',
            profile: profile,
          );
        }

        messenger.showSnackBar(
          SnackBar(
            content: Text('Welcome aboard, $fullName!'),
            behavior: SnackBarBehavior.floating,
          ),
        );

        if (!mounted) return;

        final String destinationRoute = isInstructor
            ? InstructorPage.routeName
            : StudentPage.routeName;

        // Refresh before checking to avoid stale `emailVerified` state.
        try {
          await user.reload();
        } catch (_) {
          // Best-effort; continue.
        }

        if (!mounted) return;

        final bool isVerified =
            FirebaseAuth.instance.currentUser?.emailVerified ??
            user.emailVerified;

        if (!isVerified) {
          bool sent = false;
          FirebaseAuthException? sendError;
          try {
            await FirebaseAuth.instance.currentUser?.sendEmailVerification();
            sent = true;
          } on FirebaseAuthException catch (error) {
            debugPrint(
              'sendEmailVerification failed: ${error.code} -> ${error.message}',
            );
            sendError = error;
          }

          if (!mounted) return;

          if (sendError != null) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  'Could not send verification email (${sendError.code}). You can retry from the verification screen.',
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }

          if (sent) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  'Verification email sent to ${user.email ?? email}. Please verify to continue.',
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          Navigator.of(context).pushNamedAndRemoveUntil(
            VerifyEmailPage.routeName,
            (Route<dynamic> route) => false,
            arguments: VerifyEmailPageArgs(destinationRoute: destinationRoute),
          );
          return;
        }

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
      debugPrint(
        'Firestore write failed: ${error.code} -> ${error.message}\n$stackTrace',
      );

      // Prevent "auth-only" accounts (created in Firebase Auth but missing a
      // Firestore profile). If the profile write failed, roll back the newly
      // created Auth user so the person can retry signup cleanly.
      try {
        await FirebaseAuth.instance.currentUser?.delete();
      } catch (deleteError, deleteStack) {
        debugPrint('Rollback delete() failed: $deleteError\n$deleteStack');
      } finally {
        await FirebaseAuth.instance.signOut();
      }

      final String message = error.code == 'student-id-already-in-use'
          ? 'That Student ID is already registered. Please check your ID or contact support.'
          : 'Sign-up failed. ${error.message ?? error.code}';
      messenger.showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    } catch (error, stackTrace) {
      debugPrint('Unexpected signup error: $error\n$stackTrace');

      // Same rollback logic for unknown failures after Auth user creation.
      try {
        await FirebaseAuth.instance.currentUser?.delete();
      } catch (deleteError, deleteStack) {
        debugPrint('Rollback delete() failed: $deleteError\n$deleteStack');
      } finally {
        await FirebaseAuth.instance.signOut();
      }

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

  Future<void> _showStudentPrivacyNotice() async {
    final bool? agreed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        int stepIndex = 0;
        return StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) set) {
            final int totalSteps = _privacyParts.length;
            final Map<String, String> step = _privacyParts[stepIndex];
            final bool isLast = stepIndex == totalSteps - 1;

            return AlertDialog(
              title: Text('${step['title']} (${stepIndex + 1} of $totalSteps)'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: SelectableText(
                    step['body'] ?? '',
                    textAlign: TextAlign.left,
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Close'),
                ),
                if (stepIndex > 0)
                  TextButton(
                    onPressed: () => set(() => stepIndex -= 1),
                    child: const Text('Back'),
                  ),
                FilledButton(
                  onPressed: () {
                    if (isLast) {
                      Navigator.of(context).pop(true);
                      return;
                    }
                    set(() => stepIndex += 1);
                  },
                  child: Text(isLast ? 'Finish (I Agree)' : 'I Agree'),
                ),
              ],
            );
          },
        );
      },
    );

    if (!mounted) return;
    if (agreed == true) {
      setState(() => _studentPrivacyConsent = true);
    }
  }

  Widget _buildSectionSelector() {
    final bool hasError = _sectionsError != null;
    final bool hasSections = _availableSections.isNotEmpty;
    final bool isDisabled = _isLoadingSections || !hasSections;
    final String searchText = _sectionSearchController.text
        .trim()
        .toLowerCase();
    final List<String> visibleSections = searchText.isEmpty
        ? _availableSections
        : _availableSections
              .where(
                (String section) => section.toLowerCase().contains(searchText),
              )
              .toList(growable: false);

    final List<Widget> children = <Widget>[
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double fieldWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;

          return MenuAnchor(
            controller: _sectionMenuController,
            alignmentOffset: const Offset(0, 6),
            style: MenuStyle(
              minimumSize: WidgetStatePropertyAll<Size>(Size(fieldWidth, 0)),
              maximumSize: WidgetStatePropertyAll<Size>(Size(fieldWidth, 260)),
            ),
            menuChildren: visibleSections
                .map(
                  (String section) => MenuItemButton(
                    onPressed: isDisabled
                        ? null
                        : () {
                            setState(() {
                              _selectedStudentSection = section;
                              _sectionSearchController.text = section;
                            });
                            _sectionMenuController.close();
                            FocusScope.of(context).unfocus();
                          },
                    child: Text(section),
                  ),
                )
                .toList(growable: false),
            builder:
                (BuildContext context, MenuController controller, Widget? _) {
                  return TextFormField(
                    controller: _sectionSearchController,
                    enabled: !isDisabled,
                    decoration: InputDecoration(
                      labelText: 'Section',
                      hintText: _isLoadingSections
                          ? 'Loading sections…'
                          : (hasSections
                                ? 'Search or pick your section'
                                : 'No sections available'),
                      prefixIcon: const Icon(Icons.group_work_outlined),
                      suffixIcon: _isLoadingSections
                          ? const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : IconButton(
                              tooltip: controller.isOpen
                                  ? 'Close sections'
                                  : 'Open sections',
                              onPressed: isDisabled
                                  ? null
                                  : () {
                                      if (controller.isOpen) {
                                        controller.close();
                                      } else {
                                        controller.open();
                                      }
                                    },
                              icon: Icon(
                                controller.isOpen
                                    ? Icons.arrow_drop_up
                                    : Icons.arrow_drop_down,
                              ),
                            ),
                    ),
                    validator: (String? value) {
                      final String trimmed = (value ?? '').trim();
                      if (trimmed.isEmpty) {
                        return 'Please select your section';
                      }
                      // If sections haven't loaded, don't block with a
                      // "must match" error.
                      if (_availableSections.isEmpty) {
                        return null;
                      }
                      final bool exactMatch = _availableSections.contains(
                        trimmed,
                      );
                      if (!exactMatch) {
                        return 'Please select a valid section';
                      }
                      return null;
                    },
                    onTap: isDisabled
                        ? null
                        : () {
                            if (!controller.isOpen) {
                              controller.open();
                            }
                          },
                    onChanged: (String value) {
                      setState(() {
                        final String trimmed = value.trim();
                        if (_availableSections.contains(trimmed)) {
                          _selectedStudentSection = trimmed;
                        }
                        if (_selectedStudentSection != null &&
                            value.trim() != _selectedStudentSection) {
                          _selectedStudentSection = null;
                        }
                      });
                      if (!controller.isOpen && !isDisabled) {
                        controller.open();
                      }
                    },
                  );
                },
          );
        },
      ),
    ];

    if (hasError) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _sectionsError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _isLoadingSections ? null : _loadSections,
                icon: const Icon(Icons.refresh_outlined),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else if (!hasSections && !_isLoadingSections) {
      children.add(
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'No sections yet. Please contact an administrator.',
            style: TextStyle(fontSize: 13),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
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
                            labelText: 'Lastname, Firstname Middleinitial.',
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
                          const SizedBox(height: 16),
                          _buildSectionSelector(),
                          const SizedBox(height: 16),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: IgnorePointer(
                                  ignoring: true,
                                  child: Checkbox(
                                    value: _studentPrivacyConsent,
                                    onChanged: null,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: InkWell(
                                    onTap: _showStudentPrivacyNotice,
                                    child: Text(
                                      'I agree to the Data Privacy Notice and consent to face embedding processing for attendance.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            decoration:
                                                TextDecoration.underline,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
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
                          autofillHints: const <String>[
                            AutofillHints.newPassword,
                          ],
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
                          autofillHints: const <String>[
                            AutofillHints.newPassword,
                          ],
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
                          onPressed:
                              _isSubmitting ||
                                  (!isInstructor && !_studentPrivacyConsent)
                              ? null
                              : _handleSignUp,
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
