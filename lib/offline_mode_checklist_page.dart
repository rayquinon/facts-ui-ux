import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';
import 'services/offline_mode_service.dart';
import 'services/offline_mode_service_types.dart';

class OfflineModeChecklistPage extends StatefulWidget {
  const OfflineModeChecklistPage({super.key, required this.sectionLabels});

  static const String routeName = '/offline-mode';

  final List<String> sectionLabels;

  @override
  State<OfflineModeChecklistPage> createState() =>
      _OfflineModeChecklistPageState();
}

class _OfflineModeChecklistPageState extends State<OfflineModeChecklistPage> {
  final OfflineModeService _service = OfflineModeService();

  late final TextEditingController _apiKeyController;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _uidController = TextEditingController();
  bool _showPassword = false;
  bool _checkingEnrollment = false;
  String? _enrollmentResult;

  bool _loading = true;
  bool _preparingAll = false;
  bool _warmingModel = false;
  OfflineModeStatus? _status;
  String? _error;

  List<String> get _normalizedSections {
    final List<String> labels = widget.sectionLabels
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    labels.sort();
    return labels;
  }

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(
      text: DefaultFirebaseOptions.currentPlatform.apiKey,
    );
    _refresh();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _uidController.dispose();
    super.dispose();
  }

  Future<void> _checkEmbeddingsEnrollment() async {
    if (_checkingEnrollment) return;

    final String apiKey = _apiKeyController.text.trim();
    final String email = _emailController.text.trim();
    final String password = _passwordController.text;
    final String uid = _uidController.text.trim();

    if (apiKey.isEmpty || email.isEmpty || password.isEmpty || uid.isEmpty) {
      setState(() {
        _enrollmentResult = 'Enter apiKey, email, password, and student UID.';
      });
      return;
    }

    setState(() {
      _checkingEnrollment = true;
      _enrollmentResult = null;
    });

    try {
      final Uri signInUri = Uri.parse(
        'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$apiKey',
      );
      final Map<String, Object?> signInBody = <String, Object?>{
        'email': email,
        'password': password,
        'returnSecureToken': true,
      };

      final http.Response signInResponse = await http.post(
        signInUri,
        headers: const <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(signInBody),
      );

      if (signInResponse.statusCode != 200) {
        String message = 'Sign-in failed (${signInResponse.statusCode}).';
        try {
          final Object? decoded = jsonDecode(signInResponse.body);
          if (decoded is Map) {
            final Object? err = decoded['error'];
            if (err is Map && err['message'] != null) {
              message = 'Sign-in failed: ${err['message']}';
            }
          }
        } catch (_) {
          // Ignore parse errors.
        }
        setState(() {
          _enrollmentResult = message;
        });
        return;
      }

      final Object? signInDecoded = jsonDecode(signInResponse.body);
      if (signInDecoded is! Map) {
        setState(() {
          _enrollmentResult = 'Sign-in response was not valid JSON.';
        });
        return;
      }
      final String token = (signInDecoded['idToken'] ?? '').toString().trim();
      if (token.isEmpty) {
        setState(() {
          _enrollmentResult = 'Sign-in succeeded but no idToken was returned.';
        });
        return;
      }

      final Uri checkUri = Uri.parse(
        'https://embeddings.shiro.codes/v1/embeddings/$uid',
      );
      final http.Response checkResponse = await http.get(
        checkUri,
        headers: <String, String>{
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );

      if (checkResponse.statusCode == 200) {
        setState(() {
          _enrollmentResult = 'Enrolled: VPS returned 200 for this UID.';
        });
        return;
      }
      if (checkResponse.statusCode == 404) {
        setState(() {
          _enrollmentResult = 'Not enrolled: VPS returned 404 (no embeddings record).';
        });
        return;
      }
      if (checkResponse.statusCode == 401 || checkResponse.statusCode == 403) {
        setState(() {
          _enrollmentResult =
              'Permission denied: VPS returned ${checkResponse.statusCode}. Use an instructor/admin account.';
        });
        return;
      }

      setState(() {
        _enrollmentResult =
            'Unexpected VPS response: ${checkResponse.statusCode}. Try again while online.';
      });
    } catch (e) {
      setState(() {
        _enrollmentResult = 'Check failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _checkingEnrollment = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final OfflineModeStatus status = await _service.getStatusForSections(
        _normalizedSections,
      );
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _warmUpModel() async {
    if (_warmingModel) return;
    setState(() {
      _warmingModel = true;
      _error = null;
    });
    try {
      await _service.warmUpModel();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _warmingModel = false);
      await _refresh();
    }
  }

  Future<void> _prepareSection(String sectionLabel) async {
    setState(() {
      _error = null;
    });
    try {
      await _service.prepareSectionCache(sectionLabel);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Prepared roster for $sectionLabel')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to cache $sectionLabel: $e')),
      );
    } finally {
      await _refresh();
    }
  }

  Future<void> _confirmResetAndPrepare() async {
    if (_preparingAll) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Reset offline mode?'),
          content: const Text(
            'This will delete all offline caches (roster embeddings, markers, and the downloaded face model). '
            'You will need internet to prepare again.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reset & prepare'),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      await _resetAndPrepareAll();
    }
  }

  Future<void> _resetAndPrepareAll() async {
    if (_preparingAll) return;
    setState(() {
      _preparingAll = true;
      _error = null;
    });

    try {
      await _service.resetOfflineMode();
      await _service.warmUpModel();

      final Map<String, String> failures = <String, String>{};
      for (final String section in _normalizedSections) {
        try {
          await _service.prepareSectionCache(section);
        } catch (e) {
          failures[section] = e.toString();
        }
      }

      await _refresh();
      if (!mounted) return;

      final bool ready = _status?.isReady == true;
      final int total = _normalizedSections.length;
      final int failedCount = failures.length;
      final int okCount = total - failedCount;
      final String baseMessage = ready
          ? 'Offline mode is ready.'
          : 'Prepared $okCount/$total section(s).';

      if (failedCount > 0) {
        final String failedLabels = failures.keys.join(', ');
        setState(() {
          _error = 'Failed to prepare: $failedLabels';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$baseMessage Failed: $failedLabels')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(baseMessage)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      await _refresh();
    } finally {
      if (mounted) setState(() => _preparingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final OfflineModeStatus? status = _status;

    final bool modelOk = status?.modelAvailable == true;
    final bool ready = status?.isReady == true;
    final bool allCached = status?.allSectionsCached == true;
    final int sectionsTotal = _normalizedSections.length;
    final int sectionsMissingEmbeddings = (status?.sectionStatuses ??
            const <OfflineModeSectionStatus>[])
        .where((OfflineModeSectionStatus s) => s.isCached && !s.hasEmbeddings)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline mode'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            ready ? Icons.check_circle : Icons.cancel,
                            color: ready
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  ready
                                      ? 'Offline face scanning is ready'
                                      : 'Offline face scanning is NOT ready',
                                  style: theme.textTheme.titleMedium,
                                ),
                                if (!ready)
                                  Text(
                                    _buildNotReadyReason(
                                      modelOk: modelOk,
                                      allCached: allCached,
                                      sectionsTotal: sectionsTotal,
                                      sectionsMissingEmbeddings:
                                          sectionsMissingEmbeddings,
                                    ),
                                    style: theme.textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                          FilledButton(
                            onPressed:
                                _preparingAll ? null : _confirmResetAndPrepare,
                            child: _preparingAll
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Reset & Prepare'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ListTile(
                      leading: Icon(
                        modelOk ? Icons.check : Icons.close,
                        color: modelOk ? Colors.green : Colors.red,
                      ),
                      title: const Text('Face model available'),
                      subtitle: const Text(
                        'Required for embedding generation. This is bundled with the app.',
                      ),
                      trailing: TextButton(
                        onPressed: _warmingModel ? null : _warmUpModel,
                        child: _warmingModel
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Warm up'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Roster cache (per section)',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_normalizedSections.isEmpty)
                    const Text(
                      'No sections found. Make sure your classes have a section label.',
                    )
                  else
                    ..._buildSectionTiles(status),
                  const SizedBox(height: 12),
                  const Text(
                    'Note: Preparing requires internet and may take a few minutes (it downloads the roster + face embeddings). After preparation, scanning can run offline for the prepared sections.',
                  ),
                  const SizedBox(height: 16),
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Verify embeddings enrollment',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Uses Firebase Auth REST to get an ID token, then calls the embeddings server. Use your instructor/admin account and the student UID.',
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _apiKeyController,
                            decoration: const InputDecoration(
                              labelText: 'Firebase Web API key (apiKey)',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _emailController,
                            decoration: const InputDecoration(
                              labelText: 'Instructor/admin email',
                            ),
                            keyboardType: TextInputType.emailAddress,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _passwordController,
                            obscureText: !_showPassword,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              suffixIcon: IconButton(
                                tooltip:
                                    _showPassword ? 'Hide' : 'Show',
                                onPressed: () {
                                  setState(() {
                                    _showPassword = !_showPassword;
                                  });
                                },
                                icon: Icon(
                                  _showPassword
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _uidController,
                            decoration: const InputDecoration(
                              labelText: 'Student UID to check',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: <Widget>[
                              FilledButton(
                                onPressed: _checkingEnrollment
                                    ? null
                                    : _checkEmbeddingsEnrollment,
                                child: _checkingEnrollment
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('Check'),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _enrollmentResult ?? '',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  List<Widget> _buildSectionTiles(OfflineModeStatus? status) {
    final Map<String, OfflineModeSectionStatus> byLabel =
        <String, OfflineModeSectionStatus>{
          for (final OfflineModeSectionStatus s
              in status?.sectionStatuses ?? <OfflineModeSectionStatus>[])
            s.sectionLabel: s,
        };

    return _normalizedSections
        .map((String sectionLabel) {
          final OfflineModeSectionStatus? s = byLabel[sectionLabel];
          final bool prepared = s?.isCached == true;
          final bool embeddingsOk = s?.hasEmbeddings == true;
          final bool ok = prepared && embeddingsOk;

          final IconData leadingIcon;
          final Color leadingColor;
          if (!prepared) {
            leadingIcon = Icons.close;
            leadingColor = Theme.of(context).colorScheme.error;
          } else if (!embeddingsOk) {
            leadingIcon = Icons.warning_amber;
            leadingColor = Theme.of(context).colorScheme.tertiary;
          } else {
            leadingIcon = Icons.check;
            leadingColor = Theme.of(context).colorScheme.primary;
          }

          return Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: ListTile(
              leading: Icon(
                leadingIcon,
                color: leadingColor,
              ),
              title: Text(sectionLabel),
              subtitle: _buildSectionSubtitle(prepared, s),
              trailing: TextButton(
                onPressed: ok ? null : () => _prepareSection(sectionLabel),
                child: const Text('Cache'),
              ),
            ),
          );
        })
        .toList(growable: false);
  }

  Widget _buildSectionSubtitle(bool prepared, OfflineModeSectionStatus? s) {
    if (s?.error != null) {
      return Text('Not prepared: ${s!.error}');
    }
    if (!prepared) {
      return const Text('Not prepared yet');
    }
    final int? students = s?.studentCount;
    final int? embeddings = s?.embeddingsCount;

    if (students == null) {
      return const Text('Prepared (available offline)');
    }

    final bool embeddingsOk = s?.hasEmbeddings == true;
    if (embeddingsOk) {
      return Text('Prepared (available offline) • $students students');
    }

    final int embeddingsSafe = embeddings ?? 0;
    return Text(
      'Prepared, but $embeddingsSafe/$students student(s) have embeddings. Enroll students to enable offline recognition.',
    );
  }

  String _buildNotReadyReason({
    required bool modelOk,
    required bool allCached,
    required int sectionsTotal,
    required int sectionsMissingEmbeddings,
  }) {
    if (!modelOk) {
      return 'Reason: face model is not available.';
    }

    if (sectionsTotal > 0 && !allCached) {
      return 'Reason: roster cache is not prepared for all sections.';
    }

    if (sectionsMissingEmbeddings > 0) {
      final String plural = sectionsMissingEmbeddings == 1 ? '' : 's';
      return 'Reason: missing offline embeddings in $sectionsMissingEmbeddings section$plural.';
    }

    return 'Reason: preparation is incomplete.';
  }
}
