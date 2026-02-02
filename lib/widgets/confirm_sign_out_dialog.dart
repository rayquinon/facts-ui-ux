import 'package:flutter/material.dart';

Future<bool> showConfirmSignOutDialog(BuildContext context) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: const Text('Sign out'),
        content: const Text('Do you want to sign out?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign-out'),
          ),
        ],
      );
    },
  );

  return result ?? false;
}
