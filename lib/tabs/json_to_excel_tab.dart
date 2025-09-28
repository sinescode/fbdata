import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:excel/excel.dart';
import 'package:permission_handler/permission_handler.dart'; // Import permission_handler


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
        const TextCellValue('Username'),
        const TextCellValue('Password'),
        const TextCellValue('Authcode'),
        const TextCellValue('Email'),
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

      // FIXED: Request storage permission
      if (Platform.isAndroid) {
        var status = await Permission.storage.status;
         if (!status.isGranted) {
            status = await Permission.storage.request();
        }
        if (!status.isGranted) {
            _showError('Storage permission denied. Cannot save file.');
            return;
        }
      }

      // FIXED: Let user choose the save directory
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
        
        // Verify file was created
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

  // --- OMITTED: The build method is unchanged ---
  // --- Please use your existing build method as it is correct ---
  
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