import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  static const String routeName = '/admin';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<_AdminStat> stats = const <_AdminStat>[
      _AdminStat(
        label: 'Instructors',
        value: '24',
        icon: Icons.school_outlined,
      ),
      _AdminStat(label: 'Students', value: '640', icon: Icons.people_outline),
      _AdminStat(
        label: 'Alerts',
        value: '3',
        icon: Icons.warning_amber_rounded,
      ),
    ];
    final List<_AdminAction> actions = const <_AdminAction>[
      _AdminAction('Review Attendance Reports', Icons.insights_outlined),
      _AdminAction('Manage Departments', Icons.account_tree_outlined),
      _AdminAction('Approve Instructor Accounts', Icons.verified_user_outlined),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
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
                Navigator.of(context).pushNamedAndRemoveUntil(
                  '/login',
                  (Route<dynamic> route) => false,
                );
              }
            },
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool isWide = constraints.maxWidth >= 900;
          final EdgeInsets padding = EdgeInsets.symmetric(
            horizontal: isWide ? 48 : 24,
            vertical: 32,
          );
          return SingleChildScrollView(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'System overview',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: stats
                      .map(
                        (_AdminStat stat) =>
                            _AdminStatCard(stat: stat, isWide: isWide),
                      )
                      .toList(),
                ),
                const SizedBox(height: 32),
                Text(
                  'Quick actions',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                ...actions.map(
                  (_AdminAction action) => _AdminActionTile(action: action),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AdminStat {
  const _AdminStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;
}

class _AdminAction {
  const _AdminAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _AdminStatCard extends StatelessWidget {
  const _AdminStatCard({required this.stat, required this.isWide});

  final _AdminStat stat;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double width = isWide ? 240 : double.infinity;
    return SizedBox(
      width: width,
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(stat.icon, color: colors.primary),
              const SizedBox(height: 12),
              Text(
                stat.value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(stat.label, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminActionTile extends StatelessWidget {
  const _AdminActionTile({required this.action});

  final _AdminAction action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: Icon(action.icon),
        title: Text(action.label),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {},
      ),
    );
  }
}
