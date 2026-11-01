import 'package:flutter/material.dart';

void main() {
  runApp(const MusiFyApp());
}

class MusiFyApp extends StatelessWidget {
  const MusiFyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF101114);
    const accent = Color(0xFF8B5CF6);

    return MaterialApp(
      title: 'MusiFy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const PlayerHomePage(),
    );
  }
}

class PlayerHomePage extends StatelessWidget {
  const PlayerHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'MusiFy',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: false,
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.library_music_rounded, size: 76, color: Color(0xFF8B5CF6)),
              SizedBox(height: 20),
              Text(
                'Tvoja hudobná knižnica',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 10),
              Text(
                'Základ aplikácie MusiFy je pripravený. Pripojenie kDrive a prehrávanie skladieb budú nasledovať v ďalšej fáze.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
