import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const MusiFyApp());

class MusiFyApp extends StatelessWidget {
  const MusiFyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MusiFy',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF101114),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8B5CF6), brightness: Brightness.dark),
      useMaterial3: true,
    ),
    home: const LibraryPage(),
  );
}

class Track {
  const Track({required this.id, required this.name, required this.size, required this.mimeType});
  final String id, name, mimeType;
  final int size;
  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: (json['id'] ?? json['file_id'] ?? '').toString(),
    name: (json['name'] ?? json['filename'] ?? 'Neznáma skladba').toString(),
    size: (json['size'] as num?)?.toInt() ?? 0,
    mimeType: (json['mime_type'] ?? '').toString(),
  );
}

class KDriveService {
  static const _driveId = '1800737';
  static const _shareToken = 'd5b56959-2447-46ed-aa12-942b2ce66042';

  Uri _filesUri({String? cursor}) => Uri.https(
    'kdrive.infomaniak.com',
    '/2/app/$_driveId/share/$_shareToken/files',
    {'with': 'capabilities', if (cursor != null) 'cursor': cursor},
  );

  Future<List<Track>> loadAudioTracks() async {
    final tracks = <Track>[];
    final cursors = <String>{};
    String? cursor;
    for (var page = 0; page < 100; page++) {
      final response = await http.get(_filesUri(cursor: cursor), headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw Exception('kDrive odpovedal HTTP ${response.statusCode}.');
      final root = jsonDecode(utf8.decode(response.bodyBytes));
      final pageData = _parsePage(root);
      for (final item in pageData.items) {
        final track = Track.fromJson(item);
        final n = track.name.toLowerCase();
        final audio = track.mimeType.startsWith('audio/') ||
          const ['.flac','.mp3','.m4a','.aac','.ogg','.opus','.wav','.wma'].any(n.endsWith);
        if (audio && track.id.isNotEmpty) tracks.add(track);
      }
      if (!pageData.hasMore) break;
      final next = pageData.cursor;
      if (next == null || next.isEmpty || !cursors.add(next)) throw Exception('kDrive neposkytol platný kurzor ďalšej stránky.');
      cursor = next;
    }
    tracks.sort((a,b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return tracks;
  }

  _Page _parsePage(dynamic value) {
    // Infomaniak public-share API returns:
    // { "result": "success", "data": [ ... ], "cursor": "...", "has_more": true }
    if (value is String) {
      value = jsonDecode(value);
    }
    if (value is List) {
      return _Page(
        value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
        false,
        null,
      );
    }
    if (value is! Map) {
      throw FormatException('Neočakávaný formát odpovede kDrive: ' + value.runtimeType.toString());
    }

    final root = Map<String, dynamic>.from(value);
    dynamic raw = root['data'];

    if (raw is Map) {
      final dataMap = Map<String, dynamic>.from(raw);
      raw = dataMap['files'] ?? dataMap['items'] ?? dataMap['results'] ?? dataMap['data'];
    }
    raw ??= root['files'] ?? root['items'] ?? root['results'];

    if (raw is! List) {
      final nested = root['response'] ?? root['payload'];
      if (nested is Map) {
        final nestedMap = Map<String, dynamic>.from(nested);
        raw = nestedMap['data'] ?? nestedMap['files'] ?? nestedMap['items'] ?? nestedMap['results'];
      }
    }

    if (raw is! List) {
      throw FormatException(
        'V odpovedi kDrive sa nenašiel zoznam súborov. '
        'Kľúče odpovede: ' + root.keys.join(', ') +
        '; typ data: ' + (root['data']?.runtimeType.toString() ?? 'null') + '.',
      );
    }

    final items = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final more = (root['has_more'] ?? false) == true;
    final cursor = (root['cursor'] ?? root['next_cursor'])?.toString();
    return _Page(items, more, cursor);
  }
}

class _Page {
  const _Page(this.items, this.hasMore, this.cursor);
  final List<Map<String,dynamic>> items;
  final bool hasMore;
  final String? cursor;
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _service = KDriveService();
  late Future<List<Track>> _future;
  @override
  void initState() { super.initState(); _future = _service.loadAudioTracks(); }
  void _reload() => setState(() => _future = _service.loadAudioTracks());

  String _size(int bytes) {
    if (bytes <= 0) return '';
    final mb = bytes / 1048576;
    return mb >= 1024 ? '${(mb/1024).toStringAsFixed(1)} GB' : '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('MusiFy', style: TextStyle(fontWeight: FontWeight.w700)),
      actions: [IconButton(tooltip: 'Obnoviť knižnicu', onPressed: _reload, icon: const Icon(Icons.refresh_rounded))],
    ),
    body: FutureBuilder<List<Track>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: Column(
          mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 18), Text('Načítavam hudobnú knižnicu z kDrive…')],
        ));
        if (snapshot.hasError) return Center(child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_rounded, size: 64, color: Colors.white54),
            const SizedBox(height: 18),
            const Text('Knižnicu sa nepodarilo načítať', textAlign: TextAlign.center, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text('${snapshot.error}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh), label: const Text('Skúsiť znova')),
          ]),
        ));
        final tracks = snapshot.data ?? const <Track>[];
        if (tracks.isEmpty) return const Center(child: Text('V zdieľanom priečinku sa nenašli hudobné súbory.'));
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20,12,20,8), child: Text('${tracks.length} skladieb', style: const TextStyle(color: Colors.white70))),
          Expanded(child: ListView.separated(
            itemCount: tracks.length,
            separatorBuilder: (_,__) => const Divider(height: 1, indent: 72),
            itemBuilder: (context,index) {
              final track = tracks[index];
              final details = [if (track.mimeType.isNotEmpty) track.mimeType, if (_size(track.size).isNotEmpty) _size(track.size)].join(' • ');
              return ListTile(
                leading: const CircleAvatar(backgroundColor: Color(0x268B5CF6), child: Icon(Icons.music_note_rounded, color: Color(0xFFB69BFF))),
                title: Text(track.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: details.isEmpty ? null : Text(details),
                trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              );
            },
          )),
        ]);
      },
    ),
  );
}
