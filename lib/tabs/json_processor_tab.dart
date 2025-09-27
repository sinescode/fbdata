import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html;

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
      duration: const Duration(milliseconds: 1000),
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
      // Silent fail for single attempt
    }

    return null;
  }

  Future<String?> _extractUidWithRetry(String link, int recordIndex) async {
    const maxRetries = 5;
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      _addLog('Record ${recordIndex + 1}: Attempt $attempt/$maxRetries', type: LogType.info);
      
      try {
        final uid = await _extractUidSingleAttempt(link);
        if (uid != null) {
          _addLog('✓ Record ${recordIndex + 1}: UID found on attempt $attempt: $uid', type: LogType.success);
          return uid;
        }
        
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: attempt * 1)); // Progressive delay
        }
      } catch (e) {
        _addLog('Record ${recordIndex + 1}: Attempt $attempt failed: $e', type: LogType.warning);
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: attempt * 1));
        }
      }
    }
    
    _addLog('✗ Record ${recordIndex + 1}: Failed to extract UID after $maxRetries attempts', type: LogType.error);
    return null;
  }

  Future<void> _processRecordConcurrently(int index, Map<String, dynamic> record) async {
    final username = record['username']?.toString() ?? '';
    
    if (!username.contains('facebook.com')) {
      _addLog('Record ${index + 1}: Not a Facebook link, keeping original', type: LogType.info);
      return record;
    }

    _addLog('Record ${index + 1}: Starting UID extraction', type: LogType.info);
    final uid = await _extractUidWithRetry(username, index);
    
    if (uid != null) {
      final updatedRecord = Map<String, dynamic>.from(record);
      updatedRecord['username'] = uid;
      _addLog('✓ Record ${index + 1}: Successfully replaced with UID', type: LogType.success);
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

      final batchFutures = <Future>[];
      for (int j = i; j < batchEnd; j++) {
        batchFutures.add(_processRecordConcurrently(j, _data[j]));
      }

      try {
        final batchResults = await Future.wait(batchFutures);
        
        for (final result in batchResults) {
          if (result != null) {
            successfulRecords.add(result as Map<String, dynamic>);
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
      final String fileName = _fileName ?? 'processed_data';
      final String baseName = path.basenameWithoutExtension(fileName);
      final String newFileName = 'uid_$baseName.json';

      Directory? downloadsDir;
      if (Platform.isAndroid) {
        downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          downloadsDir = await getExternalStorageDirectory();
        }
      } else {
        downloadsDir = await getDownloadsDirectory();
      }

      if (downloadsDir != null) {
        final saveDir = Directory('${downloadsDir.path}/fb_saver');
        if (!await saveDir.exists()) {
          await saveDir.create(recursive: true);
        }

        final file = File('${saveDir.path}/$newFileName');
        await file.writeAsString(json.encode(_processedData));

        _addLog('File saved successfully: ${file.path}', type: LogType.success);
        
        if (await file.exists()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✓ File saved to: ${file.path}'),
              backgroundColor: const Color(0xFF467731),
              behavior: SnackBarBehavior.floating,
            ),
          );
          _stopButtonAnimation();
        } else {
          _addLog('Error: File was not created', type: LogType.error);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✗ Error: File was not saved'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        _addLog('Could not access downloads directory', type: LogType.error);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✗ Error: Could not access storage'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      _addLog('Error saving file: $e', type: LogType.error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✗ Save error: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
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