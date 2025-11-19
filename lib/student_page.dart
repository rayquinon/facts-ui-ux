import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class StudentPage extends StatelessWidget {
  const StudentPage({super.key});

  static const String routeName = '/student';

  Future<void> _handleSignOut(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to sign out. Please try again.'),
          ),
        );
      }
      return;
    }

    if (context.mounted) {
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Student Dashboard'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () => _handleSignOut(context),
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
