// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

void main() {
  runApp(const KestrelApp());
}

class KestrelApp extends StatelessWidget {
  const KestrelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kestrel',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kestrel')),
      body: const Center(child: Text('Kestrel')),
    );
  }
}
