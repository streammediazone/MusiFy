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

  Uri _shareRootUri() => Uri.https(
    'kdrive.infomaniak.com',
    '/2/app/$_driveId/share/$_shareToken/files',
  );

  Uri _folderFilesUri(String folderId, {String? cursor}) => Uri.https(
    'kdrive.infomaniak.com',
    '/2/app/$_driveId/share/$_shareToken/files/$folderId/files',
    {if (cursor != null) 'cursor': cursor},
  );

  Future<dynamic> _getJson(Uri uri) async {
    final response = await http.get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw Exception('kDrive odpovedal HTTP ${response.statusCode} pri načítaní obsahu.');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<LibraryResult> loadAudioTracks() async {
    // The public-share /files endpoint returns metadata for the shared root
    // directory. Its children must be requested from /files/{folderId}/files.
    final root = await _getJson(_shareRootUri());
    if (root is! Map || root['data'] is! Map) {
      throw FormatException('kDrive neposkytol metadáta zdieľaného priečinka.');
    }
    final rootData = Map<String, dynamic>.from(root['data'] as Map);
    final rootId = (rootData['id'] ?? '').toString();
    if (rootId.isEmpty || rootData['type'] != 'dir') {
      throw FormatException('Zdieľaný odkaz nevrátil priečinok. ID: $rootId, typ: ${rootData['type']}.');
    }

    final tracks = <Track>[];
    final pendingFolders = <String>[rootId];
    final visitedFolders = <String>{};
    final diagnostics = <String>['Koreň: ID=$rootId, názov=${rootData['name'] ?? '-'}'];

    while (pendingFolders.isNotEmpty) {
      final folderId = pendingFolders.removeAt(0);
      if (!visitedFolders.add(folderId)) continue;

      final cursors = <String>{};
      String? cursor;
      for (var page = 0; page < 100; page++) {
        final response = await _getJson(_folderFilesUri(folderId, cursor: cursor));
        final pageData = _parsePage(response);
        diagnostics.add('Priečinok $folderId / strana ${page + 1}: položiek ${pageData.items.length}, has_more=${pageData.hasMore}, cursor=${pageData.cursor == null ? 'null' : 'prítomný'}, ${pageData.responseKeys}');
        for (final item in pageData.items) {
          final type = (item['type'] ?? '').toString();
          final id = (item['id'] ?? '').toString();
          if (type == 'dir' && id.isNotEmpty) {
            pendingFolders.add(id);
            continue;
          }
          if (type != 'file') continue;

          final track = Track.fromJson(item);
          final name = track.name.toLowerCase();
          final audio = track.mimeType.startsWith('audio/') ||
              const ['.flac', '.mp3', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.wma']
                  .any(name.endsWith);
          if (audio && track.id.isNotEmpty) tracks.add(track);
        }

        if (!pageData.hasMore) break;
        final next = pageData.cursor;
        if (next == null || next.isEmpty || !cursors.add(next)) {
          throw Exception('kDrive neposkytol platný kurzor ďalšej stránky.');
        }
        cursor = next;
      }
    }

    tracks.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    diagnostics.add('Hotovo: priečinkov ${visitedFolders.length}, skladieb ${tracks.length}');
    return LibraryResult(tracks, diagnostics);
  }

  _Page _parsePage(dynamic value) {
    if (value is String) value = jsonDecode(value);
    if (value is List) {
      return _Page(
        value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
        false,
        null,
        'odpoveď je priamo zoznam',
      );
    }
    if (value is! Map) {
      throw FormatException('Neočakávaný formát zoznamu kDrive: ${value.runtimeType}.');
    }

    final root = Map<String, dynamic>.from(value);
    final data = root['data'] is Map
        ? Map<String, dynamic>.from(root['data'] as Map)
        : <String, dynamic>{};
    final pagination = root['pagination'] is Map
        ? Map<String, dynamic>.from(root['pagination'] as Map)
        : (data['pagination'] is Map
            ? Map<String, dynamic>.from(data['pagination'] as Map)
            : <String, dynamic>{});

    dynamic raw = root['data'];
    if (raw is Map) {
      raw = data['files'] ?? data['items'] ?? data['results'] ??
          data['entries'] ?? data['children'] ?? data['data'];
    }
    raw ??= root['files'] ?? root['items'] ?? root['results'] ??
        root['entries'] ?? root['children'];

    if (raw is! List) {
      throw FormatException(
        'Zoznam položiek priečinka kDrive nemá očakávaný formát. '
        'Root kľúče: ${root.keys.join(', ')}; data typ: ${root['data']?.runtimeType}.',
      );
    }

    final items = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final more = root['has_more'] == true || root['hasMore'] == true ||
        data['has_more'] == true || data['hasMore'] == true ||
        pagination['has_more'] == true || pagination['hasMore'] == true;
    final cursorValue = root['cursor'] ?? root['next_cursor'] ?? root['nextCursor'] ??
        data['cursor'] ?? data['next_cursor'] ?? data['nextCursor'] ??
        pagination['cursor'] ?? pagination['next_cursor'] ?? pagination['nextCursor'];
    final cursor = cursorValue?.toString();
    return _Page(items, more, cursor, 'kľúče root=${root.keys.join(',')}; data=${data.keys.join(',')}; pagination=${pagination.keys.join(',')}');
  }
}

class _Page {
  const _Page(this.items, this.hasMore, this.cursor, this.responseKeys);
  final List<Map<String,dynamic>> items;
  final bool hasMore;
  final String? cursor;
  final String responseKeys;
}

class LibraryResult {
  const LibraryResult(this.tracks, this.diagnostics);
  final List<Track> tracks;
  final List<String> diagnostics;
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _service = KDriveService();
  late Future<LibraryResult> _future;
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
    body: FutureBuilder<LibraryResult>(
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
        final result = snapshot.data!;
        final tracks = result.tracks;
        if (tracks.isEmpty) return const Center(child: Text('V zdieľanom priečinku sa nenašli hudobné súbory.'));
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20,12,20,8), child: Text('${tracks.length} skladieb', style: const TextStyle(color: Colors.white70))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Diagnostika načítania'),
            children: [Container(width: double.infinity, padding: const EdgeInsets.all(10), color: const Color(0xFF1B1C22), child: SelectableText(result.diagnostics.join('\\n'), style: const TextStyle(fontSize: 11, height: 1.5, color: Colors.white70)))],
          )),
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
