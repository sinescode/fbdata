import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const FBDataManagerApp());
}

class FBDataManagerApp extends StatelessWidget {
  const FBDataManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FB Data Manager',
      theme: ThemeData(
        primaryColor: const Color(0xFF467731),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF467731),
          primary: const Color(0xFF467731),
          secondary: const Color(0xFF598745),
          surface: const Color(0xFFB2D4A3),
          background: const Color(0xFFF5F9F3),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF467731),
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF467731),
            foregroundColor: Colors.white,
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF467731),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        tabBarTheme: TabBarThemeData(
          labelColor: const Color(0xFF467731),
          unselectedLabelColor: Colors.grey,
          indicator: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: const Color(0xFF467731),
                width: 2,
              ),
            ),
          ),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FB Data Manager'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'JSON Processor'),
            Tab(text: 'JSON to Excel'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          JSONProcessorTab(),
          JSONToExcelTab(),
        ],
      ),
    );
  }
}

/* ---------------------------------------------------------------------------
   Permission helper (shared)
   --------------------------------------------------------------------------- */

/// Ensures storage permission for Android devices.
/// Tries MANAGE_EXTERNAL_STORAGE first, falls back to legacy storage permission.
/// If denied, prompts the user to open app settings.
///
/// Returns true if permission is available to write to external storage.
Future<bool> _ensureStoragePermission(BuildContext context) async {
  if (!Platform.isAndroid) return true;

  try {
    // Try managed "All files access" (Android 11+)
    final manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) return true;

    final manageResult = await Permission.manageExternalStorage.request();
    if (manageResult.isGranted) return true;

    // Legacy storage permission fallback
    final storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) return true;

    final storageResult = await Permission.storage.request();
    if (storageResult.isGranted) return true;

    // If still not granted, offer to open app settings
    if (context.mounted) {
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Storage permission required'),
          content: const Text(
            'This app needs permission to save files. You can grant "All files access" in Settings '
            'for full functionality, or grant storage permission for limited access.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Open Settings')),
          ],
        ),
      );

      if (open == true) {
        await openAppSettings();
      }
    }

    return false;
  } catch (e) {
    // Unexpected error; treat as denied
    return false;
  }
}

/* ---------------------------------------------------------------------------
   JSON Processor Tab
   --------------------------------------------------------------------------- */

class JSONProcessorTab extends StatefulWidget {
  const JSONProcessorTab({super.key});

  @override
  State<JSONProcessorTab> createState() => _JSONProcessorTabState();
}

class _JSONProcessorTabState extends State<JSONProcessorTab> with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _data = [];
  List<Map<String, dynamic>> _processedData = [];
  List<LogEntry> _logs = [];
  String? _fileName;
  bool _isProcessing = false;
  bool _isProcessed = false;
  late AnimationController _animationController;
  late Animation<Color?> _buttonColorAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    _buttonColorAnimation = ColorTween(
      begin: const Color(0xFF91B880),
      end: const Color(0xFF467731),
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _startButtonAnimation() {
    _animationController.repeat(reverse: true);
  }

  void _stopButtonAnimation() {
    _animationController.reset();
  }

  void _addLog(String message, {LogType type = LogType.info}) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, LogEntry(
        message: message,
        timestamp: DateTime.now(),
        type: type,
      ));

      if (_logs.length > 100) {
        _logs = _logs.sublist(0, 100);
      }
    });
  }

  Color _getLogColor(LogType type) {
    switch (type) {
      case LogType.success:
        return const Color(0xFF467731);
      case LogType.error:
        return const Color(0xFFD32F2F);
      case LogType.warning:
        return const Color(0xFFFFA000);
      case LogType.info:
      default:
        return const Color(0xFF2196F3);
    }
  }

  IconData _getLogIcon(LogType type) {
    switch (type) {
      case LogType.success:
        return Icons.check_circle;
      case LogType.error:
        return Icons.error;
      case LogType.warning:
        return Icons.warning;
      case LogType.info:
      default:
        return Icons.info;
    }
  }

  Future<String?> _extractUidSingleAttempt(String link) async {
    if (link.isEmpty) return null;

    // Case 1: profile.php?id=NUMBER
    final profileRegex = RegExp(r'profile\.php\?id=(\d+)');
    final profileMatch = profileRegex.firstMatch(link);
    if (profileMatch != null) {
      return profileMatch.group(1);
    }

    // Case 2: numeric in path
    final numericRegex = RegExp(r'facebook\.com/(\d+)');
    final numericMatch = numericRegex.firstMatch(link);
    if (numericMatch != null) {
      return numericMatch.group(1);
    }

    // Case 3: share link -> fetch and parse
    try {
      final response = await http.get(
        Uri.parse(link),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final document = html.parse(response.body);

        // A: fb://profile/
        final metaTags = document.querySelectorAll('meta');
        for (var meta in metaTags) {
          final content = meta.attributes['content'];
          if (content != null && content.contains('fb://profile/')) {
            final fbProfileRegex = RegExp(r'fb://profile/(\d+)');
            final match = fbProfileRegex.firstMatch(content);
            if (match != null) {
              return match.group(1);
            }
          }
        }

        // B: "userID":"123..."
        final userIDRegex = RegExp(r'"userID":"(\d+)"');
        final userIDMatch = userIDRegex.firstMatch(response.body);
        if (userIDMatch != null) {
          return userIDMatch.group(1);
        }
      }
    } catch (e) {
      _addLog('Error fetching UID for $link: $e', type: LogType.warning);
    }

    return null;
  }

  Future<Map<String, dynamic>?> _processRecordConcurrently(int index, Map<String, dynamic> record) async {
    final username = record['username']?.toString() ?? '';

    if (!username.contains('facebook.com')) {
      _addLog('Record ${index + 1}: Not a Facebook link, keeping original', type: LogType.info);
      return record;
    }

    _addLog('Record ${index + 1}: Starting UID extraction for $username', type: LogType.info);
    final uid = await _extractUidSingleAttempt(username);

    if (uid != null) {
      final updatedRecord = Map<String, dynamic>.from(record);
      updatedRecord['username'] = uid;
      _addLog('✓ Record ${index + 1}: Successfully replaced with UID: $uid', type: LogType.success);
      return updatedRecord;
    } else {
      _addLog('✗ Record ${index + 1}: Removing from final data (UID not found)', type: LogType.error);
      return null; // Mark for removal
    }
  }

  Future<void> _importJSON() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        _addLog('File selected: ${result.files.single.name}', type: LogType.info);
        _fileName = result.files.single.name;

        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        final List<dynamic> jsonData = json.decode(content);

        setState(() {
          _data = jsonData.map((item) => item as Map<String, dynamic>).toList();
          _processedData = [];
          _isProcessed = false;
        });

        _addLog('Imported ${_data.length} records', type: LogType.success);
        _stopButtonAnimation();
      }
    } catch (e) {
      _addLog('Error importing JSON: $e', type: LogType.error);
    }
  }

  Future<void> _processData() async {
    if (_data.isEmpty) {
      _addLog('No data to process', type: LogType.warning);
      return;
    }

    setState(() {
      _isProcessing = true;
      _isProcessed = false;
    });

    _addLog('Starting concurrent data processing...', type: LogType.info);
    _addLog('Processing ${_data.length} records with 5 concurrent workers', type: LogType.info);

    final List<Map<String, dynamic>> successfulRecords = [];
    int successCount = 0;
    int failCount = 0;

    // Process records in batches of 5 for concurrency
    for (int i = 0; i < _data.length; i += 5) {
      final batchEnd = (i + 5) < _data.length ? i + 5 : _data.length;
      _addLog('Processing batch ${(i ~/ 5) + 1}: records ${i + 1}-$batchEnd', type: LogType.info);

      final batchFutures = <Future<Map<String, dynamic>?>>[];
      for (int j = i; j < batchEnd; j++) {
        batchFutures.add(_processRecordConcurrently(j, _data[j]));
      }

      try {
        final batchResults = await Future.wait(batchFutures);

        for (final result in batchResults) {
          if (result != null) {
            successfulRecords.add(result);
            successCount++;
          } else {
            failCount++;
          }
        }

        _addLog('Batch ${(i ~/ 5) + 1} completed: $successCount successes, $failCount failures so far',
            type: LogType.info);
      } catch (e) {
        _addLog('Batch ${(i ~/ 5) + 1} error: $e', type: LogType.error);
      }
    }

    setState(() {
      _processedData = successfulRecords;
      _isProcessing = false;
      _isProcessed = true;
    });

    _addLog('Data processing completed!', type: LogType.success);
    _addLog('Successfully processed: $successCount records', type: LogType.success);
    _addLog('Failed/removed: $failCount records', type: failCount > 0 ? LogType.warning : LogType.info);
    _addLog('Final dataset: ${_processedData.length} records', type: LogType.success);

    if (successCount > 0) {
      _startButtonAnimation();
    }
  }

  Future<void> _downloadJSON() async {
    if (_processedData.isEmpty) {
      _addLog('No processed data to download', type: LogType.warning);
      return;
    }

    try {
      // Ensure storage permission (Android)
      if (Platform.isAndroid) {
        final ok = await _ensureStoragePermission(context);
        if (!ok) {
          _addLog('Storage permission denied. Cannot save file.', type: LogType.error);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✗ Storage permission is required to save files.'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      }

      // Let the user pick the save location
      final String? outputDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Please select where to save the file',
      );

      if (outputDirectory == null) {
        _addLog('Save operation cancelled by user.', type: LogType.warning);
        return;
      }

      final String fileName = _fileName ?? 'processed_data';
      final String baseName = path.basenameWithoutExtension(fileName);
      final String newFileName = 'uid_$baseName.json';

      final filePath = path.join(outputDirectory, newFileName);
      final file = File(filePath);

      await file.writeAsString(json.encode(_processedData));

      // Verify file was created
      if (await file.exists()) {
        _addLog('File saved successfully: $filePath', type: LogType.success);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✓ File saved to: $filePath'),
              backgroundColor: const Color(0xFF467731),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        _stopButtonAnimation();
      } else {
        _addLog('Error: File was not created', type: LogType.error);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✗ Error: File was not saved'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      _addLog('Error saving file: $e', type: LogType.error);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✗ Save error: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Stats Card
          Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem('Total Records', _data.length.toString(), Icons.list_alt),
                  _buildStatItem('Processed', _processedData.length.toString(),
                      _isProcessed ? Icons.check_circle : Icons.schedule),
                  _buildStatItem('Success Rate',
                      _data.isEmpty ? '0%' : '${((_processedData.length / _data.length) * 100).toStringAsFixed(0)}%',
                      Icons.analytics),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Action Buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _importJSON,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF598745),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.file_upload, size: 20),
                  label: const Text('Import JSON'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _processData,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF719F5D),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : const Icon(Icons.settings, size: 20),
                  label: _isProcessing ? const Text('Processing...') : const Text('Process Data'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Download Button with Animation
          AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              return ElevatedButton.icon(
                onPressed: _processedData.isEmpty ? null : _downloadJSON,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isProcessed
                      ? _buttonColorAnimation.value
                      : const Color(0xFF91B880),
                  elevation: _isProcessed ? 4 : 2,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.download, size: 20),
                label: Text('Download (${_processedData.length} records)'),
              );
            },
          ),

          const SizedBox(height: 16),

          // Logs Section
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logs Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Processing Logs',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF467731),
                      ),
                    ),
                    if (_logs.isNotEmpty)
                      TextButton.icon(
                        onPressed: _clearLogs,
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF719F5D),
                        ),
                        icon: const Icon(Icons.clear_all, size: 16),
                        label: const Text('Clear All'),
                      ),
                  ],
                ),

                const SizedBox(height: 8),

                // Logs Container
                Expanded(
                  child: Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _logs.isEmpty
                        ? const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.analytics, size: 48, color: Colors.grey),
                                SizedBox(height: 8),
                                Text(
                                  'No logs yet',
                                  style: TextStyle(color: Colors.grey),
                                ),
                                Text(
                                  'Import and process data to see logs',
                                  style: TextStyle(color: Colors.grey, fontSize: 12),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            reverse: true,
                            itemCount: _logs.length,
                            itemBuilder: (context, index) {
                              final log = _logs[index];
                              return _buildLogCard(log);
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String title, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 24, color: const Color(0xFF467731)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFF467731),
          ),
        ),
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.grey,
          ),
        ),
      ],
    );
  }

  Widget _buildLogCard(LogEntry log) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getLogColor(log.type).withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _getLogColor(log.type).withOpacity(0.3),
          width: 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Icon(
          _getLogIcon(log.type),
          color: _getLogColor(log.type),
          size: 20,
        ),
        title: Text(
          log.message,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[800],
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}',
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey[600],
          ),
        ),
        dense: true,
      ),
    );
  }
}

enum LogType { info, success, error, warning }

class LogEntry {
  final String message;
  final DateTime timestamp;
  final LogType type;

  LogEntry({
    required this.message,
    required this.timestamp,
    required this.type,
  });
}

/* ---------------------------------------------------------------------------
   JSON to Excel Tab
   --------------------------------------------------------------------------- */

class JSONToExcelTab extends StatefulWidget {
  const JSONToExcelTab({super.key});

  @override
  State<JSONToExcelTab> createState() => _JSONToExcelTabState();
}

class _JSONToExcelTabState extends State<JSONToExcelTab> {
  PlatformFile? _selectedJsonFile;
  bool _isConverting = false;

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF467731),
      ),
    );
  }

  Future<void> _selectJsonFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _selectedJsonFile = result.files.first;
        });
      }
    } catch (e) {
      _showError('Error selecting file: $e');
    }
  }

  Future<void> _convertJsonToExcel() async {
    if (_selectedJsonFile == null) {
      _showError('Please select a JSON file first');
      return;
    }

    setState(() {
      _isConverting = true;
    });

    try {
      // Read file bytes
      Uint8List? bytes;
      if (_selectedJsonFile!.bytes != null) {
        bytes = _selectedJsonFile!.bytes!;
      } else if (_selectedJsonFile!.path != null) {
        bytes = await File(_selectedJsonFile!.path!).readAsBytes();
      } else {
        _showError('Cannot read JSON file data');
        return;
      }

      final content = utf8.decode(bytes);
      final List<dynamic> data = jsonDecode(content);

      // Create Excel workbook
      var excelFile = Excel.createExcel();
      Sheet sheet = excelFile['Sheet1'];

      // Add headers
      sheet.appendRow([
        TextCellValue('Username'),
        TextCellValue('Password'),
        TextCellValue('Authcode'),
        TextCellValue('Email'),
      ]);

      // Add data rows
      for (var row in data) {
        final map = row as Map<String, dynamic>;
        sheet.appendRow([
          TextCellValue(map['username']?.toString() ?? ''),
          TextCellValue(map['password']?.toString() ?? ''),
          TextCellValue(map['tfa']?.toString() ?? ''),
          TextCellValue(map['email']?.toString() ?? ''),
        ]);
      }

      // Ensure storage permission for Android
      if (Platform.isAndroid) {
        final ok = await _ensureStoragePermission(context);
        if (!ok) {
          _showError('Storage permission denied. Cannot save file.');
          return;
        }
      }

      // Let user choose save directory
      final String? outputDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Please select where to save the Excel file',
      );

      if (outputDirectory == null) {
        _showError('Save operation cancelled by user.');
        return; // User cancelled the picker
      }

      final baseName = path.basenameWithoutExtension(_selectedJsonFile!.name);
      final fileName = '$baseName.xlsx';
      final filePath = path.join(outputDirectory, fileName);
      final file = File(filePath);

      final excelBytes = excelFile.encode();
      if (excelBytes != null) {
        await file.writeAsBytes(excelBytes);

        if (await file.exists()) {
          _showSuccess('Converted and saved to $filePath');
        } else {
          _showError('File was not created successfully');
        }
      } else {
        _showError('Failed to encode Excel file');
      }
    } catch (e) {
      _showError('Failed to convert: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isConverting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'JSON to Excel Converter',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF467731),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Convert JSON files containing Facebook data to Excel format',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _selectJsonFile,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF598745),
                    ),
                    child: const Text('Select JSON File'),
                  ),
                  const SizedBox(height: 16),
                  if (_selectedJsonFile != null) ...[
                    Text(
                      'Selected file: ${_selectedJsonFile!.name}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF467731),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Size: ${(_selectedJsonFile!.size / 1024).toStringAsFixed(2)} KB',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _isConverting ? null : _convertJsonToExcel,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF719F5D),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: _isConverting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Text(
                    'Convert to Excel',
                    style: TextStyle(fontSize: 16),
                  ),
          ),
          const SizedBox(height: 16),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Expected JSON Format:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF467731),
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '[\n'
                    '  {\n'
                    '    "email": "example@email.com",\n'
                    '    "username": "facebook_link_or_uid",\n'
                    '    "password": "password",\n'
                    '    "tfa": "2fa_code"\n'
                    '  }\n'
                    ']',
                    style: TextStyle(fontFamily: 'Monospace', fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}