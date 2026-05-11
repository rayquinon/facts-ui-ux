import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:csv/csv.dart' as csv;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'services/auth_diagnostic_service.dart';
import 'services/student_account_creation_service.dart';

enum _ImportRole { student, instructor }

extension _ImportRoleX on _ImportRole {
  String get idHeader => this == _ImportRole.student ? 'Student ID' : 'Instructor ID';
}

/// Admin CSV import panel for both students and instructors.
///
/// For Students:
/// - Required CSV headers (case-insensitive): displayName, studentID
/// - Optional headers: Contact, email
/// 
/// For Instructors:
/// - Required CSV headers (case-insensitive): displayName, instructorID
/// - Optional headers: Contact, email, department
class AccountImportPanel extends StatefulWidget {
  const AccountImportPanel({super.key});

  @override
  State<AccountImportPanel> createState() => _AccountImportPanelState();
}

class _AccountCsvRow {
  _AccountCsvRow({
    required this.displayName,
    required this.accountId,
    required this.role,
    this.phoneNumber,
    this.email,
    this.department,
  });

  final String displayName;
  final String accountId;
  final String role; // 'student' or 'instructor'
  final String? phoneNumber;
  final String? email;
  final String? department;
}

class _RowResult {
  _RowResult({
    required this.rowIndex,
    required this.accountId,
    required this.status,
    this.error,
    this.uid,
    this.email,
    this.accountStatus,
  });

  final int rowIndex;
  final String accountId;
  final String status;
  final String? error;
  final String? uid;
  final String? email;
  final String? accountStatus;
}

class _AccountImportPanelState extends State<AccountImportPanel> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final StudentAccountCreationService _accountService =
      StudentAccountCreationService();
  final AuthDiagnosticService _diagService = AuthDiagnosticService();

  bool _loadingSections = true;
  bool _importing = false;
  String _importPhase = '';
  
  bool _adminCheckDone = false;
  bool _isAdmin = false;
  String? _adminCheckError;

  _ImportRole _selectedRole = _ImportRole.student;

  List<String> _sections = <String>[];
  String? _selectedSection;

  Uint8List? _fileBytes;
  String? _fileName;
  String? _parseError;

  List<_AccountCsvRow> _parsed = <_AccountCsvRow>[];
  List<Map<String, String>> _preview = <Map<String, String>>[];
  int _parsedCount = 0;

  List<_RowResult> _results = <_RowResult>[];

  String _normalizePhone(String input) {
    final String value = input
        .trim()
        .replaceAll(' ', '')
        .replaceAll('-', '')
        .replaceAll('(', '')
        .replaceAll(')', '');

    if (value.isEmpty) return '';
    if (value.startsWith('+63') && value.length == 13) return value;
    if (value.startsWith('09') && value.length == 11) {
      return '+63${value.substring(1)}';
    }
    if (value.startsWith('9') && value.length == 10) {
      return '+63$value';
    }
    if (RegExp(r'^63\d{10}$').hasMatch(value)) {
      return '+$value';
    }

    return value;
  }

  @override
  void initState() {
    super.initState();
    _loadSections();
    _checkAdminStatus();
  }

  Future<void> _checkAdminStatus() async {
    try {
      final Map<String, dynamic> status = await _diagService.checkAdminStatus();
      final bool isAdmin = status['isAdmin'] == true;
      
      if (!mounted) return;
      setState(() {
        _adminCheckDone = true;
        _isAdmin = isAdmin;
        _adminCheckError = status['error'] as String?;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _adminCheckDone = true;
        _isAdmin = false;
        _adminCheckError = e.toString();
      });
    }
  }

  Future<void> _loadSections() async {
    setState(() => _loadingSections = true);
    try {
      final QuerySnapshot<Map<String, dynamic>> snap = await _firestore
          .collection('subjects')
          .get(const GetOptions(source: Source.server));

      final Set<String> uniqueSections = <String>{};
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in snap.docs) {
        final List<dynamic> sections =
            (doc.data()['sections'] as List<dynamic>? ?? <dynamic>[]);
        for (final dynamic s in sections) {
          final String v = s.toString().trim();
          if (v.isNotEmpty) uniqueSections.add(v);
        }
      }

      final List<String> sorted = uniqueSections.toList()..sort();
      if (!mounted) return;
      setState(() {
        _sections = sorted;
        _selectedSection = null;
        _loadingSections = false;
      });
    } catch (e, st) {
      debugPrint('Failed to load sections: $e\n$st');
      if (!mounted) return;
      setState(() {
        _sections = <String>[];
        _selectedSection = null;
        _parseError = 'Failed to load sections: $e';
        _loadingSections = false;
      });
    }
  }

  static String _trimOrEmpty(dynamic v) => v?.toString().trim() ?? '';

  static String _normHeader(String h) =>
      h.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  int _findIndex(List<String> headers, Set<String> candidates) {
    for (int i = 0; i < headers.length; i++) {
      final String nh = _normHeader(headers[i]);
      if (candidates.contains(nh)) return i;
    }
    return -1;
  }

  Map<String, int> _mapHeaderIndices(List<String> headers) {
    final int displayNameIdx = _findIndex(headers, <String>{
      'full name',
      'fullname',
      'fullnames',
      'full name#',
      'full name no',
      'displayname',
      'display name',
      'name',
      'student name',
      'studentname',
      'instructor name',
      'instructorname',
    });

    final int accountIdIdx = _selectedRole == _ImportRole.student
        ? _findIndex(headers, <String>{
            'student no',
            'student no.',
            'student number',
            'student no#',
            'student number#',
            'studentid',
            'student id',
            'studentid#',
            'student id#',
            'studentid #',
          })
        : _findIndex(headers, <String>{
            'instructor no',
            'instructor no.',
            'instructor number',
            'instructor no#',
            'instructor number#',
            'instructorid',
            'instructor id',
            'instructorid#',
            'instructor id#',
            'instructorid #',
          });

    final int phoneIdx = _findIndex(headers, <String>{
      'contact',
      'contact number',
      'phone',
      'phone number',
      'phonenumber',
    });

    final int emailIdx = _findIndex(headers, <String>{
      'email',
      'e mail',
      'e-mail',
    });

    final int departmentIdx = _findIndex(headers, <String>{
      'department',
      'dept',
      'department name',
    });

    return <String, int>{
      'displayName': displayNameIdx,
      'accountId': accountIdIdx,
      'phoneNumber': phoneIdx,
      'email': emailIdx,
      'department': departmentIdx,
    };
  }

  Future<void> _pickAndParseCsv() async {
    setState(() {
      _parseError = null;
      _fileBytes = null;
      _fileName = null;
      _parsed = <_AccountCsvRow>[];
      _preview = <Map<String, String>>[];
      _parsedCount = 0;
      _results = <_RowResult>[];
    });

    final FilePickerResult? picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['csv'],
      withData: true,
    );

    if (picked == null) return;

    final PlatformFile f = picked.files.single;
    final Uint8List? bytes = f.bytes;
    if (bytes == null) {
      setState(() => _parseError = 'Could not read selected file bytes.');
      return;
    }

    setState(() {
      _fileBytes = bytes;
      _fileName = f.name;
    });

    await _parseCsvBytes(bytes);
  }

  Future<void> _parseCsvBytes(Uint8List bytes) async {
    try {
      final String csvText = utf8.decode(bytes, allowMalformed: true);

      final List<List<dynamic>> rows = csv.CsvDecoder(
        skipEmptyLines: true,
        dynamicTyping: false,
      ).convert(csvText);

      if (rows.isEmpty) {
        setState(() => _parseError = 'CSV appears to be empty.');
        return;
      }

      final List<String> headers = rows.first
          .map((dynamic h) => _trimOrEmpty(h).replaceAll('\ufeff', ''))
          .toList();

      if (headers.every((String h) => h.isEmpty)) {
        setState(() => _parseError = 'CSV header row is missing.');
        return;
      }

      final Map<String, int> idx = _mapHeaderIndices(headers);
      final int displayNameIdx = idx['displayName'] ?? -1;
      final int accountIdIdx = idx['accountId'] ?? -1;

      if (displayNameIdx < 0 || accountIdIdx < 0) {
        setState(() {
          _parseError =
              'CSV must include headers for display name and ${_selectedRole.idHeader}. Found headers: ${headers.join(', ')}';
        });
        return;
      }

      final int phoneIdx = idx['phoneNumber'] ?? -1;
      final int emailIdx = idx['email'] ?? -1;
      final int departmentIdx = idx['department'] ?? -1;

      final String section = (_selectedSection ?? '').trim();
      if (_selectedRole == _ImportRole.student && section.isEmpty) {
        setState(() => _parseError = 'Select a section first.');
        return;
      }

      final List<_AccountCsvRow> parsed = <_AccountCsvRow>[];
      final List<Map<String, String>> preview = <Map<String, String>>[];

      for (int r = 1; r < rows.length; r++) {
        final List<dynamic> row = rows[r];
        if (row.isEmpty) continue;
        if (row.every((dynamic v) => _trimOrEmpty(v).isEmpty)) continue;

        final String displayName = _trimOrEmpty(
          displayNameIdx < row.length ? row[displayNameIdx] : null,
        ).replaceAll(RegExp(r'\s+'), ' ');

        final String accountId = _trimOrEmpty(
          accountIdIdx < row.length ? row[accountIdIdx] : null,
        );

        final String? phoneNumber = phoneIdx >= 0
            ? _trimOrEmpty(phoneIdx < row.length ? row[phoneIdx] : null)
            : null;

        final String? email = emailIdx >= 0
            ? _trimOrEmpty(emailIdx < row.length ? row[emailIdx] : null)
            : null;

        final String? department = departmentIdx >= 0
            ? _trimOrEmpty(departmentIdx < row.length ? row[departmentIdx] : null)
            : null;

        if (displayName.isEmpty || accountId.isEmpty) continue;

        final String? phoneClean = phoneNumber != null && phoneNumber.isNotEmpty
            ? _normalizePhone(phoneNumber)
            : null;
        final String? emailClean = email != null && email.isNotEmpty ? email : null;
        final String? deptClean = department != null && department.isNotEmpty ? department : null;

        parsed.add(
          _AccountCsvRow(
            displayName: displayName,
            accountId: accountId,
            role: _selectedRole.name,
            phoneNumber: phoneClean,
            email: emailClean,
            department: deptClean,
          ),
        );

        preview.add(<String, String>{
          'row': r.toString(),
          'displayName': displayName,
          'accountId': accountId,
          'phoneNumber': phoneClean ?? '',
          'email': emailClean ?? '',
          'department': deptClean ?? '',
        });
      }

      if (!mounted) return;
      setState(() {
        _parseError = null;
        _parsed = parsed;
        _preview = preview;
        _parsedCount = parsed.length;
      });
    } catch (e, st) {
      debugPrint('CSV parse failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _parseError = 'Failed to parse CSV: $e';
        _parsed = <_AccountCsvRow>[];
        _preview = <Map<String, String>>[];
        _parsedCount = 0;
      });
    }
  }

  Future<void> _import() async {
    if (_selectedRole == _ImportRole.student) {
      final String section = (_selectedSection ?? '').trim();
      if (section.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select a section first.')),
        );
        return;
      }
    }

    if (_fileBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a CSV file first.')),
      );
      return;
    }

    if (_parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No valid rows found in CSV.')),
      );
      return;
    }

    if (_importing) return;

    setState(() {
      _importing = true;
      _importPhase = _selectedRole == _ImportRole.student
          ? 'Creating student accounts...'
          : 'Creating instructor accounts...';
      _results = <_RowResult>[];
    });

    try {
      final List<_RowResult> results = <_RowResult>[];

      if (_parsed.isNotEmpty && _parsed.any((row) => row.email != null)) {
        try {
          if (_selectedRole == _ImportRole.student) {
            await _importStudents(results);
          } else {
            await _importInstructors(results);
          }

          if (!mounted) return;
          setState(() => _results = List<_RowResult>.from(results));
        } catch (accountError, st) {
          debugPrint('Account creation failed: $accountError\n$st');
          
          String errorMsg = 'Account creation failed';
          if (accountError is Exception) {
            errorMsg = accountError.toString();
            if (errorMsg.contains('Exception:')) {
              errorMsg = errorMsg.split('Exception:')[1].trim();
            }
          } else {
            errorMsg = accountError.toString();
          }
          
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: $errorMsg'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _importPhase = 'completed';
      });

      final String roleLabel = _selectedRole == _ImportRole.student ? 'Student' : 'Instructor';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$roleLabel import and account creation completed.')),
      );
    } catch (e, st) {
      debugPrint('Import failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _importStudents(List<_RowResult> results) async {
    final List<StudentAccountCreationRequest> accountRequests =
        <StudentAccountCreationRequest>[];
    final String section = (_selectedSection ?? '').trim();

    for (final _AccountCsvRow row in _parsed) {
      final String? email = row.email;
      if (email != null && email.isNotEmpty) {
        accountRequests.add(
          StudentAccountCreationRequest(
            email: email,
            displayName: row.displayName,
            studentId: row.accountId,
            section: section,
            password: row.accountId,
            phoneNumber: row.phoneNumber,
          ),
        );
      }
    }

    if (accountRequests.isNotEmpty) {
      final BulkAccountCreationResponse response =
          await _accountService.bulkCreateStudentAccounts(
        students: accountRequests,
      );

      if (response.ok) {
        for (final CreatedStudentAccount created in response.created) {
          results.add(
            _RowResult(
              rowIndex: _parsed.indexWhere((r) => r.accountId == created.studentId) + 2,
              accountId: created.studentId,
              status: 'account-created',
              uid: created.uid,
              email: created.email,
              accountStatus: created.status,
            ),
          );
        }

        for (final FailedStudentAccount failed in response.failed) {
          results.add(
            _RowResult(
              rowIndex: _parsed.indexWhere((r) => r.accountId == failed.studentId) + 2,
              accountId: failed.studentId,
              status: 'failed',
              email: failed.email,
              accountStatus: failed.error,
              error: failed.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _importInstructors(List<_RowResult> results) async {
    final HttpsCallable callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable('adminBulkCreateInstructorAccounts');

    final List<Map<String, dynamic>> instructors = <Map<String, dynamic>>[];

    for (final _AccountCsvRow row in _parsed) {
      final String? email = row.email;
      if (email != null && email.isNotEmpty) {
        instructors.add({
          'email': email,
          'displayName': row.displayName,
          'instructorId': row.accountId,
          'password': row.accountId,
          'phoneNumber': row.phoneNumber ?? '',
          'department': row.department ?? '',
        });
      }
    }

    if (instructors.isNotEmpty) {
      try {
        final HttpsCallableResult<dynamic> response = await callable.call({
          'instructors': instructors,
        });

        final dynamic data = response.data;
        if (data is Map<String, dynamic>) {
          final List<dynamic> createdList = data['created'] as List<dynamic>? ?? [];
          final List<dynamic> failedList = data['failed'] as List<dynamic>? ?? [];

          for (final dynamic createdDyn in createdList) {
            if (createdDyn is Map<String, dynamic>) {
              results.add(
                _RowResult(
                  rowIndex: _parsed.indexWhere((r) => r.accountId == createdDyn['instructorId']) + 2,
                  accountId: createdDyn['instructorId'] as String? ?? '',
                  status: 'account-created',
                  uid: createdDyn['uid'] as String?,
                  email: createdDyn['email'] as String?,
                  accountStatus: createdDyn['status'] as String?,
                ),
              );
            }
          }

          for (final dynamic failedDyn in failedList) {
            if (failedDyn is Map<String, dynamic>) {
              results.add(
                _RowResult(
                  rowIndex: _parsed.indexWhere((r) => r.accountId == failedDyn['instructorId']) + 2,
                  accountId: failedDyn['instructorId'] as String? ?? '',
                  status: 'failed',
                  email: failedDyn['email'] as String?,
                  error: failedDyn['error'] as String?,
                ),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('Instructor import error: $e');
        rethrow;
      }
    }
  }

  int get _successCount => _results.where((r) => r.status == 'success' || r.status == 'account-created').length;
  int get _failedCount => _results.where((r) => r.status == 'failed').length;
  int get _accountsCreatedCount => _results.where((r) => r.accountStatus == 'created').length;
  int get _accountsExistCount => _results.where((r) => r.accountStatus == 'already-exists').length;

  @override
  Widget build(BuildContext context) {
    final String description = _selectedRole == _ImportRole.student
        ? 'Upload a CSV with headers: Full Name and Student No (case-insensitive). Optional: Contact, email. Password = Student No.'
        : 'Upload a CSV with headers: Full Name and Instructor ID (case-insensitive). Optional: Contact, email, department. Password = Instructor ID.';
    final String importButtonLabel = _selectedRole == _ImportRole.student
        ? 'Import Students'
        : 'Import Instructors';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 16),
            
            // Role selector
            SegmentedButton<_ImportRole>(
              segments: <ButtonSegment<_ImportRole>>[
                ButtonSegment<_ImportRole>(
                  value: _ImportRole.student,
                  label: const Text('Students'),
                  icon: const Icon(Icons.person),
                ),
                ButtonSegment<_ImportRole>(
                  value: _ImportRole.instructor,
                  label: const Text('Instructors'),
                  icon: const Icon(Icons.school),
                ),
              ],
              selected: <_ImportRole>{_selectedRole},
              onSelectionChanged: _importing ? null : (Set<_ImportRole> newSelection) {
                setState(() {
                  _selectedRole = newSelection.first;
                  _fileBytes = null;
                  _fileName = null;
                  _parseError = null;
                  _parsed = <_AccountCsvRow>[];
                  _preview = <Map<String, String>>[];
                  _parsedCount = 0;
                  _results = <_RowResult>[];
                  if (_selectedRole == _ImportRole.instructor) {
                    _selectedSection = null;
                  }
                });
              },
            ),

            const SizedBox(height: 16),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            
            if (_adminCheckDone && !_isAdmin) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.warning_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Admin Access Required',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _adminCheckError ?? 'Your account does not have admin privileges.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            
            if (!_adminCheckDone) ...<Widget>[
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ],
            
            const SizedBox(height: 16),

            if (_selectedRole == _ImportRole.student) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _selectedSection,
                      decoration: const InputDecoration(
                        labelText: 'Section',
                        hintText: 'Select section',
                      ),
                      items: _sections
                          .map(
                            (String s) => DropdownMenuItem<String>(
                              value: s,
                              child: Text(s),
                            ),
                          )
                          .toList(),
                      onChanged: (_loadingSections || _importing)
                          ? null
                          : (String? v) => setState(() {
                                _selectedSection = v;
                                _fileBytes = null;
                                _fileName = null;
                                _parseError = null;
                                _parsed = <_AccountCsvRow>[];
                                _preview = <Map<String, String>>[];
                                _parsedCount = 0;
                                _results = <_RowResult>[];
                              }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: (_loadingSections || _importing || !_isAdmin || _selectedSection == null) ? null : _pickAndParseCsv,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('Choose CSV'),
                  ),
                ],
              ),
            ] else ...<Widget>[
              FilledButton.icon(
                onPressed: (_loadingSections || _importing || !_isAdmin) ? null : _pickAndParseCsv,
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('Choose CSV'),
              ),
            ],

            if (_fileName != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                'Selected: $_fileName',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],

            if (_parseError != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _parseError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],

            const SizedBox(height: 12),

            if (_preview.isNotEmpty) ...<Widget>[
              Text(
                'Preview (${_preview.length} rows)',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: <DataColumn>[
                    const DataColumn(label: Text('row')),
                    const DataColumn(label: Text('displayName')),
                    DataColumn(label: Text(_selectedRole.idHeader)),
                    const DataColumn(label: Text('Contact')),
                    const DataColumn(label: Text('email')),
                    if (_selectedRole == _ImportRole.student)
                      const DataColumn(label: Text('section'))
                    else
                      const DataColumn(label: Text('department')),
                  ],
                  rows: _preview.map((Map<String, String> r) {
                    return DataRow(
                      cells: <DataCell>[
                        DataCell(Text(r['row'] ?? '')),
                        DataCell(Text(r['displayName'] ?? '')),
                        DataCell(Text(r['accountId'] ?? '')),
                        DataCell(Text(r['phoneNumber'] ?? '')),
                        DataCell(Text(r['email'] ?? '')),
                        DataCell(Text(r['department'] ?? '')),
                      ],
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),
            ],

            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _parsedCount > 0
                            ? 'Parsed $_parsedCount valid row(s).'
                            : 'No CSV parsed yet.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_importPhase.isNotEmpty && _importing) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          _importPhase,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: (_importing || _preview.isEmpty || !_isAdmin) ? null : _import,
                  icon: _importing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(_importing ? 'Importing…' : importButtonLabel),
                ),
              ],
            ),

            if (_results.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text(
                            'Results',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const Spacer(),
                          Chip(label: Text('Records: $_successCount')),
                          const SizedBox(width: 8),
                          if (_accountsCreatedCount > 0)
                            Chip(label: Text('New: $_accountsCreatedCount'))
                          else if (_accountsExistCount > 0)
                            Chip(label: Text('Existing: $_accountsExistCount')),
                          const SizedBox(width: 8),
                          if (_failedCount > 0)
                            Chip(label: Text('Failed: $_failedCount')),
                        ],
                      ),
                      if (_accountsCreatedCount > 0 || _accountsExistCount > 0) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          'Account Status: $_accountsCreatedCount new, $_accountsExistCount existing',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (BuildContext context, int index) {
                            final _RowResult r = _results[index];
                            final bool isSuccess =
                                r.status == 'success' || r.status == 'account-created';
                            final Color color = isSuccess
                                ? Colors.green
                                : Theme.of(context).colorScheme.error;

                            String statusText = r.status;
                            if (r.accountStatus != null) {
                              if (r.accountStatus == 'created') {
                                statusText = '${r.status} (account created)';
                              } else if (r.accountStatus == 'already-exists') {
                                statusText = 'success (account exists)';
                              } else {
                                statusText = '${r.status} (${r.accountStatus})';
                              }
                            }

                            return ListTile(
                              dense: true,
                              title: Text(
                                r.accountId,
                                style: TextStyle(
                                  color: color,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                'Row ${r.rowIndex}: $statusText${r.error != null && r.error!.isNotEmpty ? ' — ${r.error}' : ''}${r.email != null && r.email!.isNotEmpty ? ' (${r.email})' : ''}',
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
