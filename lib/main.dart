
import 'package:flutter/material.dart';

void main() {
  runApp(const BudgetManagerApp());
}

class BudgetManagerApp extends StatelessWidget {
  const BudgetManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Budget Manager',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Budget Manager'),
        ),
        body: const Center(
          child: Text(
            'Welcome to Budget Manager!',
            style: TextStyle(fontSize: 24),
          ),
        ),
      ),
    );
  }
}
