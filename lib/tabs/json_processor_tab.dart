import 'dart:convert';
import 'dart:io';
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

class _JSONProcessorTabState extends State<JSONProcessorTab> {
  List<Map<String, dynamic>> _data = [];
  String _logs = '';
  String? _fileName;
  bool _isProcessing = false;

  void _addLog(String message) {
    setState(() {
      _logs += '[${DateTime.now().toLocal()}] $message\n';
    });
  }

  Future<String?> _extractUid(String link) async {
    if (link.isEmpty) return null;

    _addLog('Processing link: $link');

    // Case 1: profile.php?id=NUMBER
    final profileRegex = RegExp(r'profile\.php\?id=(\d+)');
    final profileMatch = profileRegex.firstMatch(link);
    if (profileMatch != null) {
      final uid = profileMatch.group(1);
      _addLog('Extracted UID from profile link: $uid');
      return uid;
    }

    // Case 2: numeric in path
    final numericRegex = RegExp(r'facebook\.com/(\d+)');
    final numericMatch = numericRegex.firstMatch(link);
    if (numericMatch != null) {
      final uid = numericMatch.group(1);
      _addLog('Extracted UID from numeric path: $uid');
      return uid;
    }

    // Case 3: share link -> fetch and parse
    try {
      _addLog('Fetching share link content...');
      final response = await http.get(
        Uri.parse(link),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        },
      );

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
              final uid = match.group(1);
              _addLog('Extracted UID from meta tag: $uid');
              return uid;
            }
          }
        }

        // B: "userID":"123..."
        final userIDRegex = RegExp(r'"userID":"(\d+)"');
        final userIDMatch = userIDRegex.firstMatch(response.body);
        if (userIDMatch != null) {
          final uid = userIDMatch.group(1);
          _addLog('Extracted UID from userID: $uid');
          return uid;
        }
      } else {
        _addLog('HTTP Error: ${response.statusCode}');
      }
    } catch (e) {
      _addLog('Error fetching link: $e');
    }

    _addLog('Could not extract UID from link');
    return null;
  }

  Future<void> _importJSON() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        _addLog('File selected: ${result.files.single.name}');
        _fileName = result.files.single.name;

        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        final List<dynamic> jsonData = json.decode(content);

        setState(() {
          _data = jsonData.map((item) => item as Map<String, dynamic>).toList();
        });

        _addLog('Imported ${_data.length} records');
      }
    } catch (e) {
      _addLog('Error importing JSON: $e');
    }
  }

  Future<void> _processData() async {
    if (_data.isEmpty) {
      _addLog('No data to process');
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    _addLog('Starting data processing...');

    for (int i = 0; i < _data.length; i++) {
      final item = _data[i];
      final username = item['username']?.toString() ?? '';

      if (username.contains('facebook.com')) {
        _addLog('Processing record ${i + 1}: $username');
        final uid = await _extractUid(username);
        
        if (uid != null) {
          setState(() {
            _data[i]['username'] = uid;
          });
          _addLog('Replaced username with UID: $uid');
        } else {
          _addLog('Failed to extract UID, keeping original username');
        }
      } else {
        _addLog('Record ${i + 1}: Not a Facebook link, skipping');
      }
    }

    setState(() {
      _isProcessing = false;
    });
    _addLog('Data processing completed');
  }

  Future<void> _downloadJSON() async {
    if (_data.isEmpty) {
      _addLog('No data to download');
      return;
    }

    try {
      final String fileName = _fileName ?? 'processed_data';
      final String baseName = path.basenameWithoutExtension(fileName);
      final String newFileName = 'uid_$baseName.json';

      // Get downloads directory - FIXED PATH
      Directory? downloadsDir;
      if (Platform.isAndroid) {
        // For Android, use external storage
        downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          // Fallback to getExternalStorageDirectory
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
        await file.writeAsString(json.encode(_data));

        _addLog('File saved successfully: ${file.path}');
        
        // Check if file was actually created
        if (await file.exists()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File saved to: ${file.path}'),
              backgroundColor: const Color(0xFF467731),
            ),
          );
        } else {
          _addLog('Error: File was not created');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error: File was not saved'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } else {
        _addLog('Could not access downloads directory');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error: Could not access storage'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      _addLog('Error saving file: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _importJSON,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF598745),
                  ),
                  child: const Text('Import JSON'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _processData,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF719F5D),
                  ),
                  child: _isProcessing 
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : const Text('Process Data'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _data.isEmpty ? null : _downloadJSON,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF91B880),
            ),
            child: const Text('Download Processed JSON'),
          ),
          const SizedBox(height: 16),
          Text(
            'Records: ${_data.length}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF467731),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFB2D4A3)),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Logs:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF467731),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F9F3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: SingleChildScrollView(
                        child: Text(
                          _logs.isEmpty ? 'No logs yet...' : _logs,
                          style: const TextStyle(
                            fontFamily: 'Monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
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