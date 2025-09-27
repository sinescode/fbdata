import 'package:flutter/material.dart';
import 'tabs/json_processor_tab.dart';
import 'tabs/json_to_excel_tab.dart';

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