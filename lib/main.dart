import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    _tabController = TabController(length: 3, vsync: this);
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
            Tab(text: 'Settings'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          JSONProcessorTab(),
          JSONToExcelTab(),
          SettingsTab(),
        ],
      ),
    );
  }
}

/* ---------------------------------------------------------------------------
   Permission helper (shared)
   --------------------------------------------------------------------------- */

Future<bool> _ensureStoragePermission(BuildContext context) async {
  if (!Platform.isAndroid) return true;

  try {
    final manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) return true;

    final manageResult = await Permission.manageExternalStorage.request();
    if (manageResult.isGranted) return true;

    final storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) return true;

    final storageResult = await Permission.storage.request();
    if (storageResult.isGranted) return true;

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
    return false;
  }
}

/* ---------------------------------------------------------------------------
   Enhanced Concurrent Processing with Better Error Handling & Accuracy
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
  
  // Enhanced performance tracking
  int _successCount = 0;
  int _failCount = 0;
  int _skippedCount = 0;
  Stopwatch _stopwatch = Stopwatch();
  int _maxConcurrentIsolates = Platform.numberOfProcessors * 2; // Double the CPU cores
  int _recordsPerBatch = 50; // Default batch size

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
    if (!mounted) return;
    setState(() {
      _logs.insert(0, LogEntry(
        message: message,
        timestamp: DateTime.now(),
        type: type,
      ));

      // Keep only last 200 logs for performance
      if (_logs.length > 200) {
        _logs = _logs.sublist(0, 200);
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

  // Enhanced UID extraction with better patterns and fallbacks
  static Future<String?> _extractUid(String link) async {
    if (link.isEmpty) return null;

    try {
      // Clean the URL first
      String cleanLink = link.trim();
      if (!cleanLink.startsWith('http')) {
        cleanLink = 'https://$cleanLink';
      }

      // Pattern 1: profile.php?id=NUMBER (highest priority)
      final profileRegex = RegExp(r'profile\.php\?id=(\d+)');
      final profileMatch = profileRegex.firstMatch(cleanLink);
      if (profileMatch != null) {
        return profileMatch.group(1);
      }

      // Pattern 2: Direct numeric ID in path
      final numericRegex = RegExp(r'facebook\.com/(\d+)(?:/|$)');
      final numericMatch = numericRegex.firstMatch(cleanLink);
      if (numericMatch != null) {
        return numericMatch.group(1);
      }

      // Pattern 3: Check for mobile URLs
      final mobileRegex = RegExp(r'm\.facebook\.com/(\d+)');
      final mobileMatch = mobileRegex.firstMatch(cleanLink);
      if (mobileMatch != null) {
        return mobileMatch.group(1);
      }

      // Pattern 4: Check for fb://profile/ in the URL itself
      final fbProfileRegex = RegExp(r'fb://profile/(\d+)');
      final fbProfileMatch = fbProfileRegex.firstMatch(cleanLink);
      if (fbProfileMatch != null) {
        return fbProfileMatch.group(1);
      }

      // Pattern 5: For share links, fetch and parse with multiple strategies
      if (cleanLink.contains('facebook.com') && 
          (cleanLink.contains('/posts/') || 
           cleanLink.contains('/story.php') ||
           cleanLink.contains('/photo.php') ||
           cleanLink.contains('/permalink.php'))) {
        
        final response = await http.get(
          Uri.parse(cleanLink),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.5',
            'Connection': 'keep-alive',
            'Upgrade-Insecure-Requests': '1',
          },
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final document = html.parse(response.body);

          // Strategy A: Look for fb://profile/ in meta tags
          final metaTags = document.querySelectorAll('meta');
          for (var meta in metaTags) {
            final content = meta.attributes['content'] ?? '';
            if (content.contains('fb://profile/')) {
              final match = RegExp(r'fb://profile/(\d+)').firstMatch(content);
              if (match != null) return match.group(1);
            }
          }

          // Strategy B: Look for userID in JSON-LD or script tags
          final scriptTags = document.querySelectorAll('script');
          for (var script in scriptTags) {
            final content = script.innerHtml;
            
            // Look for "userID":"123..."
            final userIDRegex = RegExp(r'"userID"\s*:\s*"(\d+)"');
            final userIDMatch = userIDRegex.firstMatch(content);
            if (userIDMatch != null) return userIDMatch.group(1);

            // Look for "actor_id":"123..."
            final actorIdRegex = RegExp(r'"actor_id"\s*:\s*"(\d+)"');
            final actorIdMatch = actorIdRegex.firstMatch(content);
            if (actorIdMatch != null) return actorIdMatch.group(1);

            // Look for profile/123 patterns
            final profileIdRegex = RegExp(r'profile/(\d+)');
            final profileIdMatch = profileIdRegex.firstMatch(content);
            if (profileIdMatch != null) return profileIdMatch.group(1);
          }

          // Strategy C: Look for canonical URL with numeric ID
          final canonicalLink = document.querySelector('link[rel="canonical"]');
          if (canonicalLink != null) {
            final href = canonicalLink.attributes['href'] ?? '';
            final canonicalMatch = RegExp(r'facebook\.com/(\d+)').firstMatch(href);
            if (canonicalMatch != null) return canonicalMatch.group(1);
          }
        }
      }

      return null;
    } catch (e) {
      // Silent fail - errors are handled in main isolate
      return null;
    }
  }

  // Worker function for isolates with enhanced error handling
  static Future<void> _processRecordsIsolate(SendPort sendPort) async {
    final port = ReceivePort();
    sendPort.send(port.sendPort);

    await for (final message in port) {
      if (message is List) {
        final int batchId = message[0];
        final List<Map<String, dynamic>> records = message[1];
        final SendPort replyTo = message[2];

        final List<Map<String, dynamic>?> results = [];
        final List<String> errors = [];

        // Process records in this batch
        for (int i = 0; i < records.length; i++) {
          try {
            final record = records[i];
            final username = record['username']?.toString() ?? '';

            // Skip if not a Facebook URL or already numeric
            if (!username.contains('facebook.com') || RegExp(r'^\d+$').hasMatch(username)) {
              results.add(record);
            } else {
              final uid = await _extractUid(username);
              if (uid != null) {
                final updatedRecord = Map<String, dynamic>.from(record);
                updatedRecord['username'] = uid;
                results.add(updatedRecord);
              } else {
                // Keep original record if UID extraction fails
                results.add(record);
                errors.add('Failed to extract UID from: ${username.substring(0, math.min(50, username.length))}...');
              }
            }
          } catch (e) {
            // Keep original record on error
            results.add(records[i]);
            errors.add('Error processing record $i: $e');
          }
        }

        replyTo.send([batchId, results, errors]);
      }
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
          _successCount = 0;
          _failCount = 0;
          _skippedCount = 0;
        });

        _addLog('📁 Imported ${_data.length} records', type: LogType.success);
        _stopButtonAnimation();
      }
    } catch (e) {
      _addLog('❌ Error importing JSON: $e', type: LogType.error);
    }
  }

  Future<void> _processData() async {
    if (_data.isEmpty) {
      _addLog('⚠️ No data to process', type: LogType.warning);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final concurrentEnabled = prefs.getBool('concurrent_enabled') ?? true;
    _recordsPerBatch = prefs.getInt('batch_size') ?? 50;

    setState(() {
      _isProcessing = true;
      _isProcessed = false;
      _successCount = 0;
      _failCount = 0;
      _skippedCount = 0;
    });

    _stopwatch.reset();
    _stopwatch.start();

    _addLog('🚀 Starting processing...', type: LogType.info);
    _addLog('🎯 Processing ${_data.length} records${concurrentEnabled ? ' concurrently with $_maxConcurrentIsolates workers' : ' sequentially'}', type: LogType.info);

    try {
      final results = concurrentEnabled 
          ? await _processDataWithEnhancedConcurrency()
          : await _processDataSequentially();
      
      _stopwatch.stop();
      
      setState(() {
        _processedData = results;
        _isProcessing = false;
        _isProcessed = true;
      });

      final totalProcessed = _successCount + _failCount + _skippedCount;
      final successRate = totalProcessed == 0 ? 0 : ((_successCount / totalProcessed) * 100);
      
      _addLog('✅ PROCESSING COMPLETED!', type: LogType.success);
      _addLog('⏱️  Processing time: ${_stopwatch.elapsed}', type: LogType.success);
      _addLog('📊 Records processed: $totalProcessed', type: LogType.info);
      _addLog('🎯 UIDs extracted: $_successCount', type: LogType.success);
      _addLog('⚠️  Extraction failed: $_failCount', type: _failCount > 0 ? LogType.warning : LogType.info);
      _addLog('➡️  Skipped (already numeric): $_skippedCount', type: LogType.info);
      _addLog('📈 Success rate: ${successRate.toStringAsFixed(1)}%', type: LogType.success);
      _addLog('💾 Final dataset: ${_processedData.length} records', type: LogType.success);

      if (_successCount > 0) {
        _startButtonAnimation();
      }
    } catch (e) {
      _stopwatch.stop();
      _addLog('❌ Error during processing: $e', type: LogType.error);
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _processDataSequentially() async {
    final List<Map<String, dynamic>> results = [];
    int index = 0;

    for (var record in _data) {
      index++;
      try {
        final username = record['username']?.toString() ?? '';

        if (!username.contains('facebook.com') || RegExp(r'^\d+$').hasMatch(username)) {
          results.add(record);
          _skippedCount++;
        } else {
          final uid = await _extractUid(username);
          if (uid != null) {
            final updatedRecord = Map<String, dynamic>.from(record);
            updatedRecord['username'] = uid;
            results.add(updatedRecord);
            _successCount++;
          } else {
            results.add(record);
            _failCount++;
          }
        }
      } catch (e) {
        results.add(record);
        _failCount++;
        _addLog('Error processing record $index: $e', type: LogType.error);
      }

      if (index % 10 == 0 && mounted) {
        setState(() {});
        _addLog('📦 Processed $index / ${_data.length} records', type: LogType.info);
      }
    }

    if (mounted) {
      setState(() {});
    }

    return results;
  }

  Future<List<Map<String, dynamic>>> _processDataWithEnhancedConcurrency() async {
    final int totalRecords = _data.length;
    final int batchSize = _recordsPerBatch;
    final int totalBatches = (totalRecords / batchSize).ceil();
    
    _addLog('🔧 Using $totalBatches batches with $batchSize records each', type: LogType.info);

    final List<Map<String, dynamic>> allResults = [];
    final List<String> allErrors = [];

    // Create isolate pool
    final List<Isolate> isolates = [];
    final List<ReceivePort> receivePorts = [];
    final List<SendPort> sendPorts = [];

    try {
      // Initialize isolate pool
      for (int i = 0; i < min(_maxConcurrentIsolates, totalBatches); i++) {
        final receivePort = ReceivePort();
        receivePorts.add(receivePort);

        final isolate = await Isolate.spawn(
          _processRecordsIsolate,
          receivePort.sendPort,
        );
        isolates.add(isolate);

        // Wait for isolate to be ready and get its send port
        final SendPort isolateSendPort = await receivePort.first as SendPort;
        sendPorts.add(isolateSendPort);
      }

      _addLog('🎯 Isolate pool ready: ${isolates.length} workers', type: LogType.success);

      // Process batches using worker pool
      final List<Completer<List<Map<String, dynamic>>>> completers = [];
      int completedBatches = 0;

      for (int batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
        final startIndex = batchIndex * batchSize;
        final endIndex = min((batchIndex + 1) * batchSize, totalRecords);
        final batch = _data.sublist(startIndex, endIndex);

        final completer = Completer<List<Map<String, dynamic>>>();
        completers.add(completer);

        // Assign batch to next available worker (round-robin)
        final workerIndex = batchIndex % sendPorts.length;
        final workerSendPort = sendPorts[workerIndex];

        final batchReceivePort = ReceivePort();
        batchReceivePort.listen((message) {
          if (message is List) {
            final int receivedBatchId = message[0];
            final List<Map<String, dynamic>?> batchResults = message[1];
            final List<String> batchErrors = message[2] ?? [];

            // Update counters
            for (var record in batchResults) {
              if (record != null) {
                final originalUsername = _data[startIndex + batchResults.indexOf(record)]?['username']?.toString() ?? '';
                final newUsername = record['username']?.toString() ?? '';
                
                if (originalUsername != newUsername) {
                  _successCount++;
                } else if (RegExp(r'^\d+$').hasMatch(originalUsername)) {
                  _skippedCount++;
                } else {
                  _failCount++;
                }
              }
            }

            allErrors.addAll(batchErrors);
            
            // Filter out null results and complete
            final successfulRecords = batchResults.whereType<Map<String, dynamic>>().toList();
            completer.complete(successfulRecords);
            
            completedBatches++;
            final progress = ((completedBatches / totalBatches) * 100).toInt();
            
            _addLog('📦 Batch ${receivedBatchId + 1}/$totalBatches completed ($progress%) - ${successfulRecords.length} records', 
              type: LogType.info);
            
            batchReceivePort.close();
          }
        });

        // Send batch to worker
        workerSendPort.send([batchIndex, batch, batchReceivePort.sendPort]);
      }

      // Wait for all batches to complete
      final List<List<Map<String, dynamic>>> batchResults = await Future.wait(
        completers.map((c) => c.future)
      );

      // Combine all results
      for (var batch in batchResults) {
        allResults.addAll(batch);
      }

      // Log any errors that occurred
      if (allErrors.isNotEmpty) {
        _addLog('⚠️  ${allErrors.length} errors occurred during processing', type: LogType.warning);
        for (int i = 0; i < min(5, allErrors.length); i++) {
          _addLog('   ${allErrors[i]}', type: LogType.warning);
        }
        if (allErrors.length > 5) {
          _addLog('   ... and ${allErrors.length - 5} more errors', type: LogType.warning);
        }
      }

      return allResults;
    } finally {
      // Clean up all isolates and ports
      for (var isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
      for (var port in receivePorts) {
        port.close();
      }
    }
  }

  Future<void> _downloadJSON() async {
    if (_processedData.isEmpty) {
      _addLog('⚠️ No processed data to download', type: LogType.warning);
      return;
    }

    try {
      if (Platform.isAndroid) {
        final ok = await _ensureStoragePermission(context);
        if (!ok) {
          _addLog('❌ Storage permission denied. Cannot save file.', type: LogType.error);
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

      final String? outputDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select where to save the processed file',
      );

      if (outputDirectory == null) {
        _addLog('💡 Save operation cancelled by user.', type: LogType.warning);
        return;
      }

      final String fileName = _fileName ?? 'processed_data';
      final String baseName = path.basenameWithoutExtension(fileName);
      final String newFileName = 'uid_$baseName.json';

      final filePath = path.join(outputDirectory, newFileName);
      final file = File(filePath);

      // Pretty print JSON for better readability
      const encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString(encoder.convert(_processedData));

      if (await file.exists()) {
        _addLog('💾 File saved successfully: $filePath', type: LogType.success);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ File saved to: ${path.basename(filePath)}'),
              backgroundColor: const Color(0xFF467731),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        _stopButtonAnimation();
      } else {
        _addLog('❌ Error: File was not created', type: LogType.error);
      }
    } catch (e) {
      _addLog('❌ Error saving file: $e', type: LogType.error);
    }
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  int min(int a, int b) => a < b ? a : b;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Enhanced Stats Card
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
                  _buildStatItem('Workers', '$_maxConcurrentIsolates', Icons.memory),
                  if (_stopwatch.elapsed.inSeconds > 0)
                    _buildStatItem('Time', '${_stopwatch.elapsed.inSeconds}s', Icons.timer),
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
                      : const Icon(Icons.bolt, size: 20),
                  label: _isProcessing ? const Text('Processing...') : const Text('Process Data'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Enhanced Download Button
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

          // Real-time Progress Card
          if (_isProcessing)
            Card(
              elevation: 2,
              color: const Color(0xFFE8F5E8),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildProgressStat('Success', '$_successCount', Icons.check_circle, Colors.green),
                    _buildProgressStat('Failed', '$_failCount', Icons.error, Colors.orange),
                    _buildProgressStat('Skipped', '$_skippedCount', Icons.skip_next, Colors.blue),
                    _buildProgressStat('Progress', 
                        '${_data.isEmpty ? 0 : (((_successCount + _failCount + _skippedCount) / _data.length) * 100).toStringAsFixed(1)}%', 
                        Icons.trending_up, const Color(0xFF467731)),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 16),

          // Enhanced Logs Section
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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

  Widget _buildProgressStat(String title, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          title,
          style: const TextStyle(
            fontSize: 10,
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

  String _keyToDisplay(String key) {
    return key
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '')
        .join(' ');
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

      final prefs = await SharedPreferences.getInstance();
      final orderJson = prefs.getString('excel_column_order');
      List<String> columnOrder = ['username', 'password', 'auth_code', 'email'];
      if (orderJson != null) {
        columnOrder = (json.decode(orderJson) as List).cast<String>();
      }

      var excelFile = Excel.createExcel();
      Sheet sheet = excelFile['Sheet1'];

      sheet.appendRow(
        columnOrder.map((key) => TextCellValue(_keyToDisplay(key))).toList(),
      );

      for (var row in data) {
        final map = row as Map<String, dynamic>;
        sheet.appendRow(
          columnOrder.map((key) => TextCellValue(map[key]?.toString() ?? '')).toList(),
        );
      }

      if (Platform.isAndroid) {
        final ok = await _ensureStoragePermission(context);
        if (!ok) {
          _showError('Storage permission denied. Cannot save file.');
          return;
        }
      }

      final String? outputDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Please select where to save the Excel file',
      );

      if (outputDirectory == null) {
        _showError('Save operation cancelled by user.');
        return;
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
                    '    "auth_code": "2fa_code"\n'
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

/* ---------------------------------------------------------------------------
   Settings Tab
   --------------------------------------------------------------------------- */

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _concurrentEnabled = true;
  TextEditingController _batchSizeController = TextEditingController();
  List<String> _columnOrder = ['username', 'password', 'auth_code', 'email'];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _concurrentEnabled = prefs.getBool('concurrent_enabled') ?? true;
      int batchSize = prefs.getInt('batch_size') ?? 50;
      _batchSizeController.text = batchSize.toString();
      String? orderJson = prefs.getString('excel_column_order');
      if (orderJson != null) {
        _columnOrder = (json.decode(orderJson) as List).cast<String>();
      }
      _isLoading = false;
    });
  }

  Future<void> _saveConcurrentSettings() async {
    final prefs = await SharedPreferences.getInstance();
    int? batchSize = int.tryParse(_batchSizeController.text);
    if (batchSize == null || batchSize <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid batch size')),
      );
      return;
    }
    await prefs.setBool('concurrent_enabled', _concurrentEnabled);
    await prefs.setInt('batch_size', batchSize);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Concurrent settings saved')),
    );
  }

  Future<void> _saveColumnOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('excel_column_order', json.encode(_columnOrder));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Column order saved')),
    );
  }

  String _keyToDisplay(String key) {
    return key
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '')
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: ListView(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Concurrent Processing',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  SwitchListTile(
                    title: const Text('Enable Concurrent Processing'),
                    value: _concurrentEnabled,
                    onChanged: (val) {
                      setState(() {
                        _concurrentEnabled = val;
                      });
                    },
                  ),
                  TextField(
                    controller: _batchSizeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Batch Size'),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _saveConcurrentSettings,
                    child: const Text('Save Concurrent Settings'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Excel Column Order',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text('Drag to reorder columns'),
                  ReorderableListView(
                    shrinkWrap: true,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex--;
                        final item = _columnOrder.removeAt(oldIndex);
                        _columnOrder.insert(newIndex, item);
                      });
                    },
                    children: _columnOrder
                        .map((key) => ListTile(
                              key: ValueKey(key),
                              title: Text(_keyToDisplay(key)),
                              leading: const Icon(Icons.drag_handle),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _saveColumnOrder,
                    child: const Text('Save Column Order'),
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