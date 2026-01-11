import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/excuse_request_service.dart';

class RequestExcuseDialog extends StatefulWidget {
  const RequestExcuseDialog({super.key, required this.excuseService});

  final ExcuseRequestService excuseService;

  @override
  State<RequestExcuseDialog> createState() => _RequestExcuseDialogState();
}

class _RequestExcuseDialogState extends State<RequestExcuseDialog> {
  final TextEditingController _reasonController = TextEditingController();

  final List<DateTime> _selectedFullDates = <DateTime>[];
  DateTime? _timeRangeDate;
  TimeOfDay? _timeRangeStart;
  TimeOfDay? _timeRangeEnd;

  PlatformFile? _pickedFile;
  Uint8List? _pickedBytes;

  bool _submitting = false;
  String? _submitError;

  String _dateKey(DateTime d) {
    final String mm = d.month.toString().padLeft(2, '0');
    final String dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  String? _validate() {
    final String reason = _reasonController.text.trim();
    if (reason.isEmpty) return 'Reason is required.';
    if (reason.length > 600) return 'Reason is too long.';

    final bool hasFullDates = _selectedFullDates.isNotEmpty;
    final bool hasTimeRange =
        _timeRangeDate != null && _timeRangeStart != null && _timeRangeEnd != null;
    if (!hasFullDates && !hasTimeRange) {
      return 'Select at least one full date or one time range.';
    }
    if (!hasTimeRange &&
        (_timeRangeDate != null || _timeRangeStart != null || _timeRangeEnd != null)) {
      return 'Complete the time range or clear it.';
    }
    if (hasTimeRange) {
      final int startMinutes = _timeRangeStart!.hour * 60 + _timeRangeStart!.minute;
      final int endMinutes = _timeRangeEnd!.hour * 60 + _timeRangeEnd!.minute;
      if (endMinutes <= startMinutes) {
        return 'End time must be after start time.';
      }
    }

    if (_pickedBytes == null || _pickedBytes!.isEmpty) {
      return 'Attach a PDF file.';
    }
    if (_pickedBytes!.lengthInBytes > 10 * 1024 * 1024) {
      return 'PDF must be under 10 MB.';
    }

    return null;
  }

  Future<void> _pickFullDate() async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
    );
    if (!mounted) return;
    if (picked == null) return;

    final DateTime key = DateTime(picked.year, picked.month, picked.day);
    setState(() {
      if (!_selectedFullDates.any((d) =>
          d.year == key.year && d.month == key.month && d.day == key.day)) {
        _selectedFullDates.add(key);
        _selectedFullDates.sort((a, b) => a.compareTo(b));
      }
    });
  }

  Future<void> _pickTimeRangeDate() async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _timeRangeDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
    );
    if (!mounted) return;
    if (picked == null) return;

    setState(() {
      _timeRangeDate = DateTime(picked.year, picked.month, picked.day);
    });
  }

  Future<void> _pickTimeRangeStart() async {
    final TimeOfDay initial = _timeRangeStart ?? const TimeOfDay(hour: 8, minute: 0);
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (!mounted) return;
    if (picked == null) return;

    setState(() {
      _timeRangeStart = picked;
    });
  }

  Future<void> _pickTimeRangeEnd() async {
    final TimeOfDay initial = _timeRangeEnd ?? const TimeOfDay(hour: 9, minute: 0);
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (!mounted) return;
    if (picked == null) return;

    setState(() {
      _timeRangeEnd = picked;
    });
  }

  Future<void> _pickPdf() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['pdf'],
      withData: true,
    );

    if (!mounted) return;

    if (result == null || result.files.isEmpty) {
      return;
    }

    final PlatformFile file = result.files.first;
    final Uint8List? bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      setState(() {
        _submitError = 'Unable to read selected PDF.';
      });
      return;
    }

    setState(() {
      _pickedFile = file;
      _pickedBytes = bytes;
    });
  }

  Future<void> _submit() async {
    final String? validationError = _validate();
    if (validationError != null) {
      setState(() {
        _submitError = validationError;
      });
      return;
    }

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      final String reason = _reasonController.text.trim();

      final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
      for (final DateTime d in _selectedFullDates) {
        entries.add(<String, Object?>{
          'dateKey': _dateKey(d),
          'isFullDay': true,
        });
      }

      if (_timeRangeDate != null && _timeRangeStart != null && _timeRangeEnd != null) {
        entries.add(<String, Object?>{
          'dateKey': _dateKey(_timeRangeDate!),
          'isFullDay': false,
          'startTime':
              '${_timeRangeStart!.hour.toString().padLeft(2, '0')}:${_timeRangeStart!.minute.toString().padLeft(2, '0')}',
          'endTime':
              '${_timeRangeEnd!.hour.toString().padLeft(2, '0')}:${_timeRangeEnd!.minute.toString().padLeft(2, '0')}',
        });
      }

      final CreateExcuseRequestResult created = await widget.excuseService.create(
        reason: reason,
        entries: entries,
      );
      await widget.excuseService.uploadPdf(
        uploadPath: created.uploadPath,
        fileName: _pickedFile!.name,
        bytes: _pickedBytes!,
      );
      await widget.excuseService.attachMetadata(
        requestId: created.requestId,
        path: created.uploadPath,
        fileName: _pickedFile!.name,
        size: _pickedBytes!.lengthInBytes,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = error.toString();
      });

      debugPrint('Excuse submit failed: $error');
      debugPrint(stackTrace.toString());
    }
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Request excuse'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_submitError != null) ...<Widget>[
                Text(
                  'Submit failed',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Colors.red,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _submitError!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.red),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _reasonController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'Describe why you were absent',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Full dates',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ..._selectedFullDates.map((DateTime d) {
                    return Chip(
                      label: Text(MaterialLocalizations.of(context).formatMediumDate(d)),
                      onDeleted: _submitting
                          ? null
                          : () {
                              setState(() {
                                _selectedFullDates.removeWhere((x) =>
                                    x.year == d.year &&
                                    x.month == d.month &&
                                    x.day == d.day);
                              });
                            },
                    );
                  }),
                  OutlinedButton.icon(
                    onPressed: _submitting ? null : _pickFullDate,
                    icon: const Icon(Icons.add),
                    label: const Text('Add date'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Date + time range (optional)',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: _submitting ? null : _pickTimeRangeDate,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: Text(
                      _timeRangeDate == null
                          ? 'Pick date'
                          : MaterialLocalizations.of(context)
                              .formatMediumDate(_timeRangeDate!),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _submitting ? null : _pickTimeRangeStart,
                    icon: const Icon(Icons.access_time_outlined),
                    label: Text(
                      _timeRangeStart == null ? 'Start' : _timeRangeStart!.format(context),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _submitting ? null : _pickTimeRangeEnd,
                    icon: const Icon(Icons.access_time_outlined),
                    label: Text(
                      _timeRangeEnd == null ? 'End' : _timeRangeEnd!.format(context),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _submitting
                        ? null
                        : () {
                            setState(() {
                              _timeRangeDate = null;
                              _timeRangeStart = null;
                              _timeRangeEnd = null;
                            });
                          },
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Attachment (PDF)',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _pickedFile?.name ?? 'No PDF selected',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _submitting ? null : _pickPdf,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Choose PDF'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (_submitError != null)
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _submitError ?? ''));
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy error'),
          ),
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}
