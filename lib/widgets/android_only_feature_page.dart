import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

bool isAndroidFaceScanningSupported() {
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}

class AndroidOnlyFeaturePage extends StatelessWidget {
  const AndroidOnlyFeaturePage({super.key, required this.featureName});

  final String featureName;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(featureName)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.android,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Android app required',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '$featureName uses on-device face scanning and is only available in the Android app.\n\nOther features (admin/instructor tools, reports, excuse requests) remain available on both web and Android.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () {
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      } else {
                        Navigator.of(context).pushNamedAndRemoveUntil(
                          '/login',
                          (Route<dynamic> route) => false,
                        );
                      }
                    },
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Go back'),
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
