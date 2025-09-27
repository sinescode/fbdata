import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:excel/excel.dart';

class JSONToExcelTab extends StatefulWidget {
  const JSONToExcelTab({super.key});

  @override
  State<JSONToExcelTab> createState() => _JSONToExcelTabState();
}

class _JSONToExcelTabState extends State<JSONToExcelTab> {
  PlatformFile? _selectedJsonFile;
  bool _isConverting = false;

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFD782BA),
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

      // Add headers with styling
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

      // Save Excel file
      final baseName = path.basenameWithoutExtension(_selectedJsonFile!.name);
      final fileName = '${baseName}.xlsx';
      
      // Get the downloads directory and create fb_saver folder
      final Directory downloadsDir = Directory('/storage/emulated/0/Download');
      final Directory saveDir = Directory('${downloadsDir.path}/fb_saver');
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }
      
      final filePath = path.join(saveDir.path, fileName);
      final file = File(filePath);

      final excelBytes = excelFile.encode();
      if (excelBytes != null) {
        await file.writeAsBytes(excelBytes);
        
        _showSuccess('Converted and saved to ${saveDir.path}/$fileName');
      } else {
        _showError('Failed to encode Excel file');
      }
    } catch (e) {
      _showError('Failed to convert: $e');
    } finally {
      setState(() {
        _isConverting = false;
      });
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
                      color: Color(0xFFD782BA),
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
                      backgroundColor: const Color(0xFFE18AD4),
                    ),
                    child: const Text('Select JSON File'),
                  ),
                  const SizedBox(height: 16),
                  if (_selectedJsonFile != null) ...[
                    Text(
                      'Selected file: ${_selectedJsonFile!.name}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFD782BA),
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
              backgroundColor: const Color(0xFFEEB1D5),
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
                      color: Color(0xFFD782BA),
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