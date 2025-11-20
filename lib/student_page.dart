import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'face_enrollment_page.dart';

class StudentPage extends StatefulWidget {
  const StudentPage({super.key});

  static const String routeName = '/student';

  @override
  State<StudentPage> createState() => _StudentPageState();
}

class _StudentPageState extends State<StudentPage> {
  Future<void> _handleSignOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to sign out. Please try again.'),
          ),
        );
      }
      return;
    }

    if (mounted) {
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
    }
  }

  Future<void> _launchEnrollment() async {
    await Navigator.of(context).pushNamed(FaceEnrollmentPage.routeName);
  }

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('No authenticated user found.')),
      );
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (BuildContext context,
          AsyncSnapshot<DocumentSnapshot<Map<String, dynamic>>> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Unable to load your profile: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        final Map<String, dynamic>? data = snapshot.data?.data();
        final List<dynamic>? faceEmbed = data?['faceEmbed'] as List<dynamic>?;
        final bool hasEnrollment = faceEmbed != null && faceEmbed.isNotEmpty;

        if (!hasEnrollment) {
          return _FaceEnrollmentRequiredView(
            onSignOut: () => _handleSignOut(),
            onStartEnrollment: () => _launchEnrollment(),
          );
        }

        return _StudentDashboard(onSignOut: () => _handleSignOut());
      },
    );
  }
}

class _FaceEnrollmentRequiredView extends StatelessWidget {
  const _FaceEnrollmentRequiredView({
    required this.onStartEnrollment,
    required this.onSignOut,
  });

  final VoidCallback onStartEnrollment;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complete enrollment')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.face_retouching_natural, size: 72),
            const SizedBox(height: 16),
            Text(
              'Before accessing the dashboard we need to capture your facial embedding for secure attendance.',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onStartEnrollment,
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Start face enrollment'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: onSignOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudentDashboard extends StatelessWidget {
  const _StudentDashboard({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Student Dashboard'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: onSignOut,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Today\'s Attendance Snapshot',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: const ListTile(
                leading: Icon(Icons.check_circle_outline, color: Colors.green),
                title: Text('Attendance recorded for 3 subjects'),
                subtitle: Text('Keep up the streak!'),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Upcoming classes',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: const <Widget>[
                  _StudentScheduleTile(
                    course: 'IT 101 - Fundamentals',
                    time: '08:00 AM',
                    room: 'Lab 3',
                  ),
                  _StudentScheduleTile(
                    course: 'TLE 202 - Food Safety',
                    time: '11:00 AM',
                    room: 'Kitchen 1',
                  ),
                  _StudentScheduleTile(
                    course: 'IT 205 - Data Analytics',
                    time: '02:00 PM',
                    room: 'Lecture A',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudentScheduleTile extends StatelessWidget {
  const _StudentScheduleTile({
    required this.course,
    required this.time,
    required this.room,
  });

  final String course;
  final String time;
  final String room;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: const Icon(Icons.calendar_today_outlined),
        title: Text(course),
        subtitle: Text('$time  •  $room'),
      ),
    );
  }
}
