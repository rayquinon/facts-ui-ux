import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class InstructorPage extends StatelessWidget {
  const InstructorPage({super.key});

  static const String routeName = '/instructor';

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
    final List<_InstructorAction> actions = const <_InstructorAction>[
      _InstructorAction('Start recognition session', Icons.play_circle_outline),
      _InstructorAction('Review attendance logs', Icons.article_outlined),
      _InstructorAction('Share analytics with admin', Icons.share_outlined),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Instructor Workspace'),
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
              'Quick overview',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: const <Widget>[
                _InstructorStatCard(label: 'Classes Today', value: '4'),
                _InstructorStatCard(label: 'Students Scanned', value: '92'),
                _InstructorStatCard(label: 'Alerts', value: '1'),
              ],
            ),
            const SizedBox(height: 32),
            Text(
              'Next up',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: const ListTile(
                leading: Icon(Icons.class_outlined),
                title: Text('IT 205 - Data Analytics'),
                subtitle: Text('2:00 PM • Lab 2'),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Actions',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...actions.map(
              (_InstructorAction action) => Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  leading: Icon(action.icon),
                  title: Text(action.label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstructorStatCard extends StatelessWidget {
  const _InstructorStatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstructorAction {
  const _InstructorAction(this.label, this.icon);

  final String label;
  final IconData icon;
}
