import 'package:flutter/material.dart';

import 'services/offline_mode_service.dart';
import 'services/offline_mode_service_types.dart';

class OfflineModeChecklistPage extends StatefulWidget {
  const OfflineModeChecklistPage({
    super.key,
    required this.sectionLabels,
  });

  static const String routeName = '/offline-mode';

  final List<String> sectionLabels;

  @override
  State<OfflineModeChecklistPage> createState() => _OfflineModeChecklistPageState();
}

class _OfflineModeChecklistPageState extends State<OfflineModeChecklistPage> {
  final OfflineModeService _service = OfflineModeService();

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
    _refresh();
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

  Future<void> _prepareAll() async {
    if (_preparingAll) return;
    setState(() {
      _preparingAll = true;
      _error = null;
    });

    try {
      await _service.warmUpModel();
      for (final String section in _normalizedSections) {
        await _service.prepareSectionCache(section);
      }
      await _refresh();
      if (!mounted) return;
      final bool ready = _status?.isReady == true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ready
                ? 'Offline mode is ready.'
                : 'Prepared, but some items are still not ready.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _preparingAll = false);
      // Refresh already happens above on success; do it here for failures.
      if (_error != null) {
        await _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final OfflineModeStatus? status = _status;

    final bool modelOk = status?.modelAvailable == true;
    final bool ready = status?.isReady == true;

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
                            color: ready ? Colors.green : Colors.red,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              ready
                                  ? 'Offline face scanning is ready'
                                  : 'Offline face scanning is NOT ready',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          FilledButton(
                            onPressed: _preparingAll ? null : _prepareAll,
                            child: _preparingAll
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Prepare'),
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
                                child: CircularProgressIndicator(strokeWidth: 2),
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
                    'Note: Preparing requires internet (it fetches from Firestore server). Scanning can run offline after preparation.',
                  ),
                ],
              ),
      ),
    );
  }

  List<Widget> _buildSectionTiles(OfflineModeStatus? status) {
    final Map<String, OfflineModeSectionStatus> byLabel = <String, OfflineModeSectionStatus>{
      for (final OfflineModeSectionStatus s in status?.sectionStatuses ?? <OfflineModeSectionStatus>[]) s.sectionLabel: s,
    };

    return _normalizedSections.map((String sectionLabel) {
      final OfflineModeSectionStatus? s = byLabel[sectionLabel];
      final bool ok = s?.isCached == true;
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ListTile(
          leading: Icon(
            ok ? Icons.check : Icons.close,
            color: ok ? Colors.green : Colors.red,
          ),
          title: Text(sectionLabel),
          subtitle: _buildSectionSubtitle(ok, s),
          trailing: TextButton(
            onPressed: ok ? null : () => _prepareSection(sectionLabel),
            child: const Text('Cache'),
          ),
        ),
      );
    }).toList(growable: false);
  }

  Widget _buildSectionSubtitle(bool ok, OfflineModeSectionStatus? s) {
    if (s?.error != null) {
      return Text('Not prepared: ${s!.error}');
    }
    if (!ok) {
      return const Text('Not prepared yet');
    }
    final int? count = s?.studentCount;
    if (count == null) {
      return const Text('Prepared (available offline)');
    }
    return Text('Prepared (available offline) • $count students');
  }
}
