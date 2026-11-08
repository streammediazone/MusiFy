import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_service/audio_service.dart';
import 'services/flac_picture_parser.dart';

enum AppTheme { original, midnightAmoled, auroraGlow, crystalDream, goldenHorizon }

class ThemePalette {
  const ThemePalette({required this.background, required this.surface, required this.surface2, required this.accent, required this.secondary, required this.muted, required this.border, required this.progressTrack, required this.playerGradient, required this.radius, required this.glass});
  final Color background, surface, surface2, accent, secondary, muted, border, progressTrack;
  final List<Color> playerGradient;
  final double radius;
  final bool glass;
}

const Map<AppTheme, ThemePalette> _palettes = {
  AppTheme.original: ThemePalette(background: Color(0xFF090D0B), surface: Color(0xFF151B17), surface2: Color(0xFF1D2620), accent: Color(0xFF70E34B), secondary: Color(0xFF1D7043), muted: Color(0xFF9BA69E), border: Color(0xFF29342C), progressTrack: Color(0xFF38443B), playerGradient: [Color(0xFF244A31), Color(0xFF13251B), Color(0xFF263A2C)], radius: 16, glass: false),
  AppTheme.midnightAmoled: ThemePalette(background: Color(0xFF020608), surface: Color(0xFF071317), surface2: Color(0xFF0D2228), accent: Color(0xFF00E5F0), secondary: Color(0xFF087F91), muted: Color(0xFF91B7BA), border: Color(0xFF14515A), progressTrack: Color(0xFF244047), playerGradient: [Color(0xFF06323A), Color(0xFF02090D), Color(0xFF071B22)], radius: 12, glass: false),
  AppTheme.auroraGlow: ThemePalette(background: Color(0xFF10091D), surface: Color(0xFF20132E), surface2: Color(0xFF342044), accent: Color(0xFFFF8A32), secondary: Color(0xFFCE4FEA), muted: Color(0xFFC2AFCF), border: Color(0xFF694078), progressTrack: Color(0xFF50345E), playerGradient: [Color(0xFF542C78), Color(0xFF19112E), Color(0xFF9A3D55)], radius: 24, glass: false),
  AppTheme.crystalDream: ThemePalette(background: Color(0xFF11172A), surface: Color(0xFF252D48), surface2: Color(0xFF394464), accent: Color(0xFFB69CFF), secondary: Color(0xFF7CBAFF), muted: Color(0xFFD0D7F0), border: Color(0xFF68769F), progressTrack: Color(0xFF536080), playerGradient: [Color(0xFF8D9FCB), Color(0xFF353C61), Color(0xFF6B5A9B)], radius: 30, glass: true),
  AppTheme.goldenHorizon: ThemePalette(background: Color(0xFF100D08), surface: Color(0xFF201A10), surface2: Color(0xFF302515), accent: Color(0xFFFFC247), secondary: Color(0xFFE59A28), muted: Color(0xFFD4C5A5), border: Color(0xFF725522), progressTrack: Color(0xFF51432A), playerGradient: [Color(0xFF594016), Color(0xFF17120A), Color(0xFF3D2A0E)], radius: 10, glass: false),
};

final ValueNotifier<AppTheme> appTheme = ValueNotifier<AppTheme>(AppTheme.original);
ThemePalette get _palette => _palettes[appTheme.value]!;
Color get _bg => _palette.background;
Color get _surface => _palette.surface;
Color get _surface2 => _palette.surface2;
Color get _green => _palette.accent;
Color get _muted => _palette.muted;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.streamzone.musify.channel.audio',
    androidNotificationChannelName: 'MusiFy – prehrávanie hudby',
    androidNotificationOngoing: true,
  );
  runApp(const MusiFyApp());
}

class MusiFyApp extends StatefulWidget {
  const MusiFyApp({super.key});
  @override State<MusiFyApp> createState() => _MusiFyAppState();
}

class _MusiFyAppState extends State<MusiFyApp> {
  @override
  void initState() {
    super.initState();
    _restoreTheme();
  }

  Future<void> _restoreTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('musify_player_theme');
      final theme = AppTheme.values.where((value) => value.name == saved).firstOrNull;
      if (theme != null) appTheme.value = theme;
    } catch (_) {
      // Keep the original theme if local preferences cannot be read.
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppTheme>(
    valueListenable: appTheme,
    builder: (context, selectedTheme, _) => MaterialApp(
      title: 'MusiFy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: ColorScheme.fromSeed(seedColor: _green, brightness: Brightness.dark, surface: _surface),
        useMaterial3: true,
        appBarTheme: AppBarTheme(backgroundColor: _bg, surfaceTintColor: Colors.transparent, elevation: 0),
        sliderTheme: SliderThemeData(activeTrackColor: _green, thumbColor: _green, inactiveTrackColor: _palette.progressTrack, overlayColor: _green.withValues(alpha: .14)),
      ),
      home: const LibraryPage(),
    ),
  );
}



class Track {
  const Track({required this.id, required this.name, required this.size, required this.mimeType, this.revision = ''});
  final String id, name, mimeType, revision;
  final int size;
  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: (json['id'] ?? json['file_id'] ?? '').toString(),
    name: (json['name'] ?? json['filename'] ?? 'Neznáma skladba').toString(),
    size: (json['size'] as num?)?.toInt() ?? 0,
    mimeType: (json['mime_type'] ?? '').toString(),
    revision: (json['etag'] ?? json['updated_at'] ?? json['modified_at'] ?? json['last_modified'] ?? '').toString(),
  );
}

class KDriveService {
  static const _driveId = '1800737';
  static const _shareToken = 'd5b56959-2447-46ed-aa12-942b2ce66042';
  final http.Client _client = http.Client();
  Uri _downloadUri(String fileId) => Uri.https('kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files/$fileId/download');
  Uri _shareRootUri() => Uri.https('kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files');
  Uri _folderFilesUri(String folderId, {String? cursor, int? page}) => Uri.https(
    'kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files/$folderId/files',
    {if (cursor != null) 'cursor': cursor, if (page != null) 'page': '$page', 'per_page': '100'},
  );
  Future<dynamic> _getJson(Uri uri) async {
    final response = await _client.get(uri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw Exception('kDrive odpovedal HTTP ${response.statusCode} pri načítaní obsahu.');
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
  Future<LibraryResult> loadAudioTracks({
    Future<void> Function(List<Track>)? onInitialBatchReady,
    Future<void> Function(List<Track>)? onProgress,
  }) async {
    final root = await _getJson(_shareRootUri());
    if (root is! Map || root['data'] is! Map) throw FormatException('kDrive neposkytol metadáta zdieľaného priečinka.');
    final rootData = Map<String, dynamic>.from(root['data'] as Map);
    final rootId = (rootData['id'] ?? '').toString();
    if (rootId.isEmpty || rootData['type'] != 'dir') throw FormatException('Zdieľaný odkaz nevrátil priečinok. ID: $rootId, typ: ${rootData['type']}.');
    final tracks = <Track>[];
    final allUniqueTracks = <String, Track>{};
    var initialBatchPublished = false;
    var initialBatchReady = false;
    final trackSourcePages = <String, List<String>>{};
    final itemDiagnosticMetadata = <String, String>{};
    var pendingFolders = <String>[rootId];
    final visitedFolders = <String>{};
    final diagnostics = <String>['Koreň: ID=$rootId, názov=${rootData['name'] ?? '-'}'];
    // Fetch independent folders concurrently; pages within one folder remain
    // sequential because the next cursor depends on the previous response.
    Future<({List<Track> tracks, List<String> folders, List<String> logs})> readFolder(String folderId) async {
      final folderTracks = <Track>[];
      final childFolders = <String>[];
      final logs = <String>[];
      final cursors = <String>{};
      final excludedSamples = <String>[];
      final pageDiagnostics = <String>[];
      final seenPageAudioIds = <String>{};
      var pageCount = 0;
      var listedItems = 0;
      var fileItems = 0;
      var audioItems = 0;
      var lastHasMore = false;
      var hitPageLimit = false;
      String? cursor;
      var pageNumber = 1;
      for (var page = 0; page < 100; page++) {
        final requestMode = cursor == null ? 'page=$pageNumber' : 'cursor (${cursor.length} znakov)';
        final response = await _getJson(_folderFilesUri(folderId, cursor: cursor, page: cursor == null ? pageNumber : null));
        final pageData = _parsePage(response);
        pageCount++;
        listedItems += pageData.items.length;
        lastHasMore = pageData.hasMore;
        final pageAudioIds = <String>[];
        final pageRepeatedIds = <String>[];
        for (final item in pageData.items) {
          final type = (item['type'] ?? '').toString();
          final id = (item['id'] ?? '').toString();
          if (type == 'dir' && id.isNotEmpty) { childFolders.add(id); continue; }
          if (type != 'file') continue;
          fileItems++;
          final track = Track.fromJson(item);
          final name = track.name.toLowerCase();
          final audio = track.mimeType.startsWith('audio/') || const ['.flac', '.mp3', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.wma'].any(name.endsWith);
          if (audio && track.id.isNotEmpty) {
            audioItems++;
            folderTracks.add(track);
            allUniqueTracks.putIfAbsent(track.id, () => track);
            pageAudioIds.add(track.id);
            final metadataKeys = const ['etag', 'size', 'created_at', 'updated_at', 'modified_at', 'mtime', 'last_modified', 'checksum', 'hash', 'parent_id'];
            final metadata = <String, dynamic>{};
            for (final key in metadataKeys) {
              if (item.containsKey(key) && item[key] != null) metadata[key] = item[key];
            }
            itemDiagnosticMetadata[track.id] = metadata.isEmpty ? 'bez známych metadátových polí' : jsonEncode(metadata);
            if (!seenPageAudioIds.add(track.id)) pageRepeatedIds.add(track.id);
            trackSourcePages.putIfAbsent(track.id, () => <String>[]).add('$folderId / strana $pageCount');
          } else if (excludedSamples.length < 8) {
            excludedSamples.add('${track.name} [${track.mimeType.isEmpty ? 'bez MIME' : track.mimeType}]');
          }
        }
        final firstIds = pageAudioIds.take(5).join(',');
        final lastIds = pageAudioIds.length <= 5 ? '' : pageAudioIds.skip(pageAudioIds.length - 5).join(',');
        final overlap = pageRepeatedIds.take(12).join(',');
        pageDiagnostics.add('Strana $pageCount: request=$requestMode, položiek=${pageData.items.length}, audio=${pageAudioIds.length}, prvé ID=[$firstIds], posledné ID=[$lastIds], opakovanie z predošlých strán=${pageRepeatedIds.length}${overlap.isEmpty ? '' : ' [$overlap]'}, has_more=${pageData.hasMore}, cursor=${pageData.cursor == null || pageData.cursor!.isEmpty ? 'nie' : 'áno (${pageData.cursor!.length} znakov)'}, ${pageData.responseKeys}');
        if (!initialBatchPublished && allUniqueTracks.length >= 100) {
          initialBatchPublished = true;
          final initialTracks = allUniqueTracks.values.take(100).toList()
            ..sort((a, b) {
              final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
              return byName != 0 ? byName : a.id.compareTo(b.id);
            });
          await onInitialBatchReady?.call(initialTracks);
          initialBatchReady = true;
        } else if (initialBatchPublished && initialBatchReady) {
          final progressTracks = allUniqueTracks.values.toList()
              ..sort((a, b) {
                final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
                return byName != 0 ? byName : a.id.compareTo(b.id);
              });
          await onProgress?.call(progressTracks);
        }
        if (!pageData.hasMore) break;
        if (page == 99) hitPageLimit = true;
        final next = pageData.cursor;
        if (next != null && next.isNotEmpty) {
          if (!cursors.add(next)) throw Exception('kDrive opakovane vrátil rovnaký kurzor.');
          cursor = next;
        } else { pageNumber++; }
      }
      logs.add('Priečinok $folderId: stránok=$pageCount, položiek=$listedItems, súborov=$fileItems, rozpoznané audio=$audioItems, podpriečinky=${childFolders.length}, posledné has_more=$lastHasMore, limit 100 strán=${hitPageLimit ? 'ÁNO' : 'nie'}');
      logs.addAll(pageDiagnostics);
      if (excludedSamples.isNotEmpty) logs.add('Vynechané súbory (ukážka): ${excludedSamples.join(' | ')}');
      return (tracks: folderTracks, folders: childFolders, logs: logs);
    }
    while (pendingFolders.isNotEmpty) {
      final batch = pendingFolders.take(3).toList();
      pendingFolders = pendingFolders.skip(batch.length).toList();
      final fresh = batch.where((id) => visitedFolders.add(id)).toList();
      final results = await Future.wait(fresh.map(readFolder));
      for (final result in results) {
        tracks.addAll(result.tracks);
        pendingFolders.addAll(result.folders);
        diagnostics.addAll(result.logs);
      }
    }
    if (!initialBatchPublished && allUniqueTracks.isNotEmpty) {
      initialBatchPublished = true;
      final initialTracks = allUniqueTracks.values.take(100).toList()
          ..sort((a, b) {
                final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
                return byName != 0 ? byName : a.id.compareTo(b.id);
              });
      await onInitialBatchReady?.call(initialTracks);
      initialBatchReady = true;
    }
    // Report ID collisions before deduplication so we can distinguish repeated
    // API entries from different files incorrectly sharing the same identifier.
    final tracksById = <String, List<Track>>{};
    for (final track in tracks) {
      tracksById.putIfAbsent(track.id, () => <Track>[]).add(track);
    }
    final duplicateGroups = tracksById.entries.where((entry) => entry.value.length > 1).toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final duplicateOccurrences = tracks.length - tracksById.length;
    diagnostics.add('Kontrola ID: prijaté audio=${tracks.length}, unikátne ID=${tracksById.length}, ID s opakovaním=${duplicateGroups.length}, nadbytočné výskyty=$duplicateOccurrences');
    for (final entry in duplicateGroups.take(20)) {
      final names = entry.value.map((track) => track.name).toSet().join(' / ');
      final pages = trackSourcePages[entry.key]?.join(', ') ?? 'neznáma';
      diagnostics.add('Duplicitné ID ${entry.key} (výskytov ${entry.value.length}, stránky: $pages): $names; metadáta=${itemDiagnosticMetadata[entry.key] ?? 'nedostupné'}');
    }
    if (duplicateGroups.length > 20) {
      diagnostics.add('Ďalšie duplicitné ID: ${duplicateGroups.length - 20}');
    }
    // Keep the existing one-entry-per-ID behavior until the collision cause is known.
    final uniqueTracks = Map<String, Track>.from(allUniqueTracks);
    final orderedTracks = uniqueTracks.values.toList()
      ..sort((a, b) {
                final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
                return byName != 0 ? byName : a.id.compareTo(b.id);
              });
    diagnostics.add('Hotovo: priečinkov ${visitedFolders.length}, skladieb ${orderedTracks.length} (unikátne ID)');
    if (initialBatchReady) await onProgress?.call(orderedTracks);
    return LibraryResult(orderedTracks, diagnostics);
  }
  _Page _parsePage(dynamic value) {
    if (value is String) value = jsonDecode(value);
    if (value is List) return _Page(value.whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList(), false, null, 'odpoveď je priamo zoznam');
    if (value is! Map) throw FormatException('Neočakávaný formát zoznamu kDrive: ${value.runtimeType}.');
    final root = Map<String,dynamic>.from(value);
    final data = root['data'] is Map ? Map<String,dynamic>.from(root['data'] as Map) : <String,dynamic>{};
    final pagination = root['pagination'] is Map ? Map<String,dynamic>.from(root['pagination'] as Map) : (data['pagination'] is Map ? Map<String,dynamic>.from(data['pagination'] as Map) : <String,dynamic>{});
    dynamic raw = root['data'];
    if (raw is Map) raw = data['files'] ?? data['items'] ?? data['results'] ?? data['entries'] ?? data['children'] ?? data['data'];
    raw ??= root['files'] ?? root['items'] ?? root['results'] ?? root['entries'] ?? root['children'];
    if (raw is! List) throw FormatException('Zoznam položiek priečinka kDrive nemá očakávaný formát. Root kľúče: ${root.keys.join(', ')}; data typ: ${root['data']?.runtimeType}.');
    final items = raw.whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
    final explicitMore = root['has_more'] ?? root['hasMore'] ?? data['has_more'] ?? data['hasMore'] ?? pagination['has_more'] ?? pagination['hasMore'];
    final perPage = int.tryParse('${root['items_per_page'] ?? data['items_per_page'] ?? pagination['items_per_page'] ?? ''}');
    final more = explicitMore == true || (explicitMore == null && perPage != null && raw.length >= perPage);
    final cursorValue = root['cursor'] ?? root['next_cursor'] ?? root['nextCursor'] ?? data['cursor'] ?? data['next_cursor'] ?? data['nextCursor'] ?? pagination['cursor'] ?? pagination['next_cursor'] ?? pagination['nextCursor'];
    return _Page(items, more, cursorValue?.toString(), 'server_page=${root['page'] ?? data['page'] ?? pagination['page'] ?? '-'}; items_per_page=${root['items_per_page'] ?? data['items_per_page'] ?? pagination['items_per_page'] ?? '-'}; explicit_has_more=${explicitMore ?? 'nevrátené'}; kľúče root=${root.keys.join(',')}; data=${data.keys.join(',')}; pagination=${pagination.keys.join(',')}');
  }
}
class _Page { const _Page(this.items,this.hasMore,this.cursor,this.responseKeys); final List<Map<String,dynamic>> items; final bool hasMore; final String? cursor; final String responseKeys; }
class LibraryResult { const LibraryResult(this.tracks,this.diagnostics); final List<Track> tracks; final List<String> diagnostics; }

class _LibrarySkeleton extends StatelessWidget {
  const _LibrarySkeleton({required this.completed, required this.total, required this.failures, required this.stage});
  final int completed;
  final int total;
  final int failures;
  final String stage;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Pripravujem tvoju hudbu', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
          SizedBox(height: 5),
          Text('Načítavam prvých 100 skladieb a ich obaly…', style: TextStyle(color: _muted, fontSize: 13)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? null : (completed / total).clamp(0.0, 1.0).toDouble(),
              minHeight: 4,
              backgroundColor: _surface2,
              color: _green,
            ),
          ),
          const SizedBox(height: 7),
          Text("$stage: $completed z $total${failures > 0 ? ' • neúspešné: $failures' : ''}", style: const TextStyle(color: _muted, fontSize: 11)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Container(
          height: 49,
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(15)),
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: 100,
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Container(
              height: 67,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(color: _surface.withValues(alpha: .55), borderRadius: BorderRadius.circular(15)),
              child: Row(children: [
                Container(width: 49, height: 49, decoration: BoxDecoration(color: _surface2, borderRadius: BorderRadius.circular(12))),
                const SizedBox(width: 12),
                Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FractionallySizedBox(widthFactor: index % 3 == 0 ? .58 : .78, child: Container(height: 10, decoration: BoxDecoration(color: _surface2, borderRadius: BorderRadius.circular(5)))),
                  const SizedBox(height: 9),
                  FractionallySizedBox(widthFactor: .38, child: Container(height: 7, decoration: BoxDecoration(color: _surface2, borderRadius: BorderRadius.circular(4)))),
                ])),
              ]),
            ),
          ),
        ),
      ),
    ],
  );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override State<LibraryPage> createState() => _LibraryPageState();
}
class _LibraryPageState extends State<LibraryPage> {
  final _service = KDriveService();
  late Future<LibraryResult> _future;
  late final AudioPlayer _player;
  List<Track>? _loadedTracks;
  final ValueNotifier<List<Track>> _tracksListenable = ValueNotifier<List<Track>>(<Track>[]);
  ConcatenatingAudioSource? _playlistSource;
  Future<void> _playlistMutation = Future<void>.value();
  int _initialArtworkCompleted = 0;
  int _initialArtworkTotal = 100;
  int _initialArtworkFailures = 0;
  String _initialArtworkStage = 'Sťahujem a kontrolujem obaly';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  int? _currentIndex;
  bool _loadingTrack = false;
  List<Track>? _cachedTracks;
  bool _playlistReady = false;
  List<String> _playlistTrackIds = <String>[];
  final Set<String> _artworkHasImage = <String>{};
  final Set<String> _artworkRequested = <String>{};
  final Set<String> _artworkChecked = <String>{};
  final Map<String, ValueNotifier<File?>> _trackArtwork = <String, ValueNotifier<File?>>{};
  final List<Track> _artworkQueue = <Track>[];
  int _activeArtworkWorkers = 0;
  Directory? _artworkCacheDirectory;
  final http.Client _artworkClient = http.Client();
  String _sort = 'Názov';

  @override void initState() {
    super.initState();
    _future = _loadLibrary();
    _player = AudioPlayer();
    _player.currentIndexStream.listen((index) { if (mounted && index != null) { setState(() => _currentIndex = index); final tracks = _loadedTracks ?? _cachedTracks; if (tracks != null && index >= 0 && index < tracks.length) _loadArtwork(tracks[index]); } });
  }
  @override void dispose() { _searchFocus.dispose(); _search.dispose(); _tracksListenable.dispose(); for (final notifier in _trackArtwork.values) { notifier.dispose(); } _artworkClient.close(); _service._client.close(); _player.dispose(); super.dispose(); }
  void _dismissSearchKeyboard() {
    _searchFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }
  Future<void> _reload() async {
    await _player.stop();
    if (!mounted) return;
    _playlistReady = false;
    _playlistTrackIds = <String>[];
    _currentIndex = null;
    _cachedTracks = null;
    _loadedTracks = null;
    _tracksListenable.value = <Track>[];
    _playlistSource = null;
    _artworkRequested.clear();
    _artworkChecked.clear();
    _artworkQueue.clear();
    _initialArtworkCompleted = 0;
    _initialArtworkStage = 'Sťahujem a kontrolujem obaly';
    if (!mounted) return;
    setState(() => _future = _loadLibrary());
  }


  Future<LibraryResult> _loadLibrary() => _service.loadAudioTracks(
    onInitialBatchReady: _handleInitialBatchReady,
    onProgress: _handleLibraryProgress,
  );

  Future<void> _handleInitialBatchReady(List<Track> tracks) async {
    if (!mounted) return;
    _initialArtworkTotal = tracks.length;
    _initialArtworkCompleted = 0;
    _initialArtworkFailures = 0;
    _initialArtworkStage = 'Sťahujem a kontrolujem obaly';
    if (mounted) setState(() {});
    await _prefetchArtwork(tracks, onProgress: (done, total) {
      _initialArtworkCompleted = done;
      _initialArtworkTotal = total;
      if (mounted) setState(() {});
    });
    if (!mounted) return;
    _initialArtworkStage = 'Pripravujem obrázky na zobrazenie';
    _initialArtworkCompleted = 0;
    setState(() {});
    await _precacheInitialArtwork(tracks, onProgress: (done, total) {
      _initialArtworkCompleted = done;
      _initialArtworkTotal = total;
      if (mounted) setState(() {});
    });
    if (!mounted) return;
    _loadedTracks = tracks;
    _tracksListenable.value = tracks;
    setState(() {});
  }

  Future<void> _handleLibraryProgress(List<Track> tracks) async {
    if (!mounted) return;
    _loadedTracks = tracks;
    if (mounted) {
      _tracksListenable.value = tracks;
      setState(() {});
    }
    await _appendTracksToPlaylist(tracks);
  }

  Future<void> _appendTracksToPlaylist(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final previousMutation = _playlistMutation;
    final gate = Completer<void>();
    _playlistMutation = gate.future;
    await previousMutation;
    try {
      final source = _playlistSource;
      if (!_playlistReady || source == null) return;
      // The library is alphabetically ordered. Insert newly discovered tracks
      // at their final position so the playback queue keeps the same order.
      for (var index = 0; index < tracks.length; index++) {
        final track = tracks[index];
        if (index < _playlistTrackIds.length && _playlistTrackIds[index] == track.id) {
          continue;
        }
        if (_playlistTrackIds.contains(track.id)) {
          continue;
        }
        _playlistTrackIds.insert(index, track.id);
        try {
          await source.insert(index, _audioSourceFor(track));
        } catch (_) {
          _playlistTrackIds.removeAt(index);
          // A library update must never interrupt current playback.
          break;
        }
      }
    } finally {
      gate.complete();
    }
  }

  AudioSource _audioSourceFor(Track track) => AudioSource.uri(
    _service._downloadUri(track.id),
    tag: MediaItem(id: track.id, title: track.name, album: 'MusiFy'),
  );

  Future<void> _prefetchArtwork(
    List<Track> tracks, {
    void Function(int completed, int total)? onProgress,
  }) async {
    var next = 0;
    var completed = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= tracks.length) return;
        await _loadArtwork(tracks[index]);
        if (!_artworkChecked.contains(tracks[index].id)) _initialArtworkFailures++;
        completed++;
        if (completed % 5 == 0 || completed == tracks.length) {
          onProgress?.call(completed, tracks.length);
        }
      }
    }
    final workers = tracks.length < 6 ? tracks.length : 6;
    await Future.wait(List.generate(workers, (_) => worker()));
  }

  Future<void> _precacheInitialArtwork(
    List<Track> tracks, {
    required void Function(int completed, int total) onProgress,
  }) async {
    if (!mounted) return;
    final pixelSize = (49 * MediaQuery.devicePixelRatioOf(context)).round();
    var next = 0;
    var completed = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= tracks.length) return;
        if (!mounted) return;
        final file = _artworkNotifier(tracks[index].id).value;
        if (file != null) {
          var failed = false;
          try {
            final provider = ResizeImage.resizeIfNeeded(
              pixelSize,
              pixelSize,
              FileImage(file),
            );
            await precacheImage(
              provider,
              context,
              onError: (error, stackTrace) { failed = true; },
            );
          } catch (_) {
            failed = true;
          }
          if (failed) _initialArtworkFailures++;
        }
        completed++;
        if (completed % 5 == 0 || completed == tracks.length) {
          onProgress(completed, tracks.length);
        }
      }
    }

    final workers = tracks.length < 6 ? tracks.length : 6;
    await Future.wait(List.generate(workers, (_) => worker()));
  }

  ValueNotifier<File?> _artworkNotifier(String id) =>
      _trackArtwork.putIfAbsent(id, () => ValueNotifier<File?>(null));

  void _publishArtwork(String id, File imageFile) {
    _artworkHasImage.add(id);
    _artworkNotifier(id).value = imageFile;
  }

  void _prioritizeArtwork(Track track) {
    if (!track.name.toLowerCase().endsWith('.flac')) return;
    if (_artworkChecked.contains(track.id)) {
      if (_artworkHasImage.contains(track.id) && _artworkNotifier(track.id).value == null) {
        _loadArtwork(track); // Restore the file reference from the disk cache if needed.
      }
      return;
    }
    if (_artworkRequested.contains(track.id)) return;
    final queuedIndex = _artworkQueue.indexWhere((item) => item.id == track.id);
    if (queuedIndex > 0) {
      final queued = _artworkQueue.removeAt(queuedIndex);
      _artworkQueue.insert(0, queued);
    } else if (queuedIndex < 0) {
      _artworkQueue.insert(0, track);
    }
    _pumpArtworkQueue();
  }

  void _pumpArtworkQueue() {
    while (_activeArtworkWorkers < 4 && _artworkQueue.isNotEmpty) {
      final track = _artworkQueue.removeAt(0);
      _activeArtworkWorkers++;
      _loadArtwork(track).whenComplete(() {
        _activeArtworkWorkers--;
        _pumpArtworkQueue();
      });
    }
  }

  Future<Directory> _getArtworkCacheDirectory() async {
    final directory = _artworkCacheDirectory ??=
        Directory('${(await getApplicationSupportDirectory()).path}/artwork');
    await directory.create(recursive: true);
    return directory;
  }

  String _artworkCacheName(Track track) =>
      base64Url.encode(utf8.encode('${track.id}|${track.size}|${track.revision}')).replaceAll('=', '');

  Future<void> _loadArtwork(Track track) async {
    if (!track.name.toLowerCase().endsWith('.flac')) {
      _artworkChecked.add(track.id);
      return;
    }
    if (_artworkChecked.contains(track.id)) {
      if (!_artworkHasImage.contains(track.id) || _artworkNotifier(track.id).value != null) return;
      if (!_artworkRequested.add(track.id)) return;
      try {
        final directory = await _getArtworkCacheDirectory();
        final cached = File('${directory.path}/${_artworkCacheName(track)}.img');
        if (await cached.exists() && await cached.length() > 0) {
          _publishArtwork(track.id, cached);
        } else {
          _artworkHasImage.remove(track.id);
          _artworkChecked.remove(track.id);
        }
      } catch (_) {
        _artworkHasImage.remove(track.id);
        _artworkChecked.remove(track.id);
      } finally {
        _artworkRequested.remove(track.id);
      }
      return;
    }
    if (!_artworkRequested.add(track.id)) return;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final directory = await _getArtworkCacheDirectory();
          final cacheName = _artworkCacheName(track);
          final cached = File('${directory.path}/$cacheName.img');
          if (await cached.exists()) {
            try {
              final length = await cached.length();
              if (length > 0) {
                _artworkChecked.add(track.id);
                _publishArtwork(track.id, cached);
                return;
              }
              await cached.delete();
            } catch (_) {
              // A damaged artwork cache entry is disposable; fetch it again.
            }
          }
          final noArtworkMarker = File('${directory.path}/$cacheName.none');
          if (await noArtworkMarker.exists()) {
            _artworkChecked.add(track.id);
            _artworkHasImage.remove(track.id);
            return;
          }

          final bytes = <int>[];
          Uint8List? image;
          var metadataComplete = false;
          var start = 0;
          const rangeEnds = <int>[262143, 1048575, 4194303, 8388607];
          for (final end in rangeEnds) {
            final request = http.Request('GET', _service._downloadUri(track.id));
            request.headers['Accept'] = 'audio/flac, application/octet-stream, */*';
            request.headers['Range'] = 'bytes=$start-$end';
            final response = await _artworkClient.send(request).timeout(const Duration(seconds: 25));
            if (response.statusCode != 200 && response.statusCode != 206) {
              throw HttpException('Artwork HTTP ${response.statusCode}');
            }
            await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
              const metadataLimit = 8 * 1024 * 1024;
              final remaining = metadataLimit - bytes.length;
              if (remaining <= 0) {
                throw const FormatException('FLAC metadáta prekročili limit 8 MB.');
              }
              if (chunk.length > remaining) {
                bytes.addAll(chunk.take(remaining));
              } else {
                bytes.addAll(chunk);
              }
              final parsed = readFlacPicture(bytes);
              if (parsed.complete) {
                metadataComplete = true;
                image = parsed.image;
                break;
              }
              if (bytes.length >= metadataLimit) {
                throw const FormatException('FLAC metadáta prekročili limit 8 MB.');
              }
            }
            if (metadataComplete) break;
            if (response.statusCode == 200) {
              throw const FormatException('Server ignoroval Range a metadáta sa nepodarilo dokončiť.');
            }
            start = end + 1;
          }
          if (!metadataComplete) {
            throw const FormatException('FLAC PICTURE metadáta sa nezmestili do rozsahu 8 MB.');
          }

          if (image != null && image.isNotEmpty) {
            final target = File('${directory.path}/${_artworkCacheName(track)}.img');
            final temporary = File('${target.path}.tmp');
            await temporary.writeAsBytes(image, flush: true);
            if (await target.exists()) await target.delete();
            await temporary.rename(target.path);
            final noArtworkMarker = File('${directory.path}/${_artworkCacheName(track)}.none');
            if (await noArtworkMarker.exists()) await noArtworkMarker.delete();
            _artworkChecked.add(track.id);
            _publishArtwork(track.id, target);
          } else {
            final marker = File('${directory.path}/${_artworkCacheName(track)}.none');
            final temporaryMarker = File('${marker.path}.tmp');
            await temporaryMarker.writeAsString('no-picture', flush: true);
            if (await marker.exists()) await marker.delete();
            await temporaryMarker.rename(marker.path);
            _artworkHasImage.remove(track.id);
            _artworkChecked.add(track.id);
          }
          return;
        } catch (_) {
          if (attempt == 1) rethrow;
          await Future.delayed(Duration(milliseconds: 350 * (attempt + 1)));
        }
      }
    } catch (_) {
      // Artwork failures never block library loading or audio playback.
    } finally {
      _artworkRequested.remove(track.id);
    }
  }

  Widget _artworkOrFallback(String trackId, int index, {double size = 49, double iconSize = 25}) {
    return ValueListenableBuilder<File?>(
      valueListenable: _artworkNotifier(trackId),
      builder: (context, file, _) {
        final pixelSize = (size * MediaQuery.devicePixelRatioOf(context)).round();
        return Container(
          width: size, height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * .24),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [[_green, _palette.secondary, _palette.secondary, _palette.secondary][index % 4], _surface2]),
          ),
          clipBehavior: Clip.antiAlias,
          child: file != null
              ? Image.file(file, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: pixelSize, cacheHeight: pixelSize,
                  errorBuilder: (context, error, stackTrace) => Center(child: Icon(Icons.music_note_rounded, color: Colors.white70, size: iconSize)))
              : Center(child: Icon(Icons.music_note_rounded, color: Colors.white70, size: iconSize)),
        );
      },
    );
  }

  Future<void> _playTrack(String trackId) async {
    final tracks = _loadedTracks ?? (await _future).tracks;
    final index = tracks.indexWhere((track) => track.id == trackId);
    if (index < 0) return;
    setState(() { _currentIndex = index; _loadingTrack = true; });
    _loadArtwork(tracks[index]);
    try {
      final latestIds = tracks.map((track) => track.id).toList(growable: false);
      if (!_playlistReady || _playlistSource == null) {
        final source = ConcatenatingAudioSource(
          children: tracks.map(_audioSourceFor).toList(growable: false),
        );
        await _player.setAudioSource(source, initialIndex: index, initialPosition: Duration.zero);
        _playlistSource = source;
        _playlistTrackIds = latestIds;
        _playlistReady = true;
        await _appendTracksToPlaylist(_loadedTracks ?? tracks);
      } else if (!listEquals(latestIds, _playlistTrackIds)) {
        await _appendTracksToPlaylist(tracks);
        final currentPlaylistIndex = _playlistTrackIds.indexOf(tracks[index].id);
        if (currentPlaylistIndex >= 0) {
          await _player.seek(Duration.zero, index: currentPlaylistIndex);
        }
      } else {
        await _player.seek(Duration.zero, index: index);
      }
      final playbackFuture = _player.play();
      if (mounted) setState(() => _loadingTrack = false);
      await playbackFuture;
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Skladbu sa nepodarilo prehrať: $error')));
    } finally {
      if (mounted) setState(() => _loadingTrack = false);
    }
  }
  Future<void> _togglePlayback() async {
    if (_player.playing) { await _player.pause(); }
    else if (_currentIndex != null) { await _player.play(); }
  }
  String _size(int bytes) {
    if (bytes <= 0) return '';
    final mb = bytes / 1048576;
    return mb >= 1024 ? '${(mb/1024).toStringAsFixed(1)} GB' : '${mb.toStringAsFixed(1)} MB';
  }
  String _artist(String name) {
    final dash = name.indexOf(' - ');
    return dash > 0 ? name.substring(0,dash) : 'Miestna knižnica';
  }
  String _title(String name) {
    final dash = name.indexOf(' - ');
    return dash > 0 ? name.substring(dash+3).replaceAll(RegExp(r'\\.(flac|mp3|m4a|aac|ogg|opus|wav|wma)$',caseSensitive:false),'') : name.replaceAll(RegExp(r'\\.(flac|mp3|m4a|aac|ogg|opus|wav|wma)$',caseSensitive:false),'');
  }
  List<Track> _visible(List<Track> tracks) {
    final q = _search.text.trim().toLowerCase();
    var result = tracks.where((t) => q.isEmpty || t.name.toLowerCase().contains(q)).toList();
    if (_sort == 'Interpret') result.sort((a,b) => _artist(a.name).compareTo(_artist(b.name)));
    if (_sort == 'Názov Z–A') result.sort((a,b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
    return result;
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 68,
      titleSpacing: 20,
      title: Row(children: [
        ClipRRect(borderRadius: BorderRadius.circular(9),child: Image.asset('assets/images/musify_logo.jpg',width:46,height:46,fit:BoxFit.contain)),
        const SizedBox(width:11),
        const Text('Musi',style:TextStyle(fontSize:23,fontWeight:FontWeight.w800,letterSpacing:-.7)),
        const Text('Fy',style:TextStyle(fontSize:23,fontWeight:FontWeight.w800,color:_green,letterSpacing:-.7)),
      ]),
      actions: [
        IconButton(tooltip:'Obnoviť knižnicu',onPressed:_reload,icon:const Icon(Icons.refresh_rounded)),
        IconButton(tooltip:'Nastavenia',onPressed:()=>_showSettings(),icon:const Icon(Icons.tune_rounded)),
        const SizedBox(width:6),
      ],
    ),
    body: FutureBuilder<LibraryResult>(
      future:_future,
      builder:(context,snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && _loadedTracks == null) {
          return _LibrarySkeleton(completed: _initialArtworkCompleted, total: _initialArtworkTotal, failures: _initialArtworkFailures, stage: _initialArtworkStage);
        }
        if (snapshot.hasError && _loadedTracks == null) {
          return Center(child:Padding(padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.cloud_off_rounded,size:60,color:_muted),const SizedBox(height:16),const Text('Knižnicu sa nepodarilo načítať',style:TextStyle(fontSize:19,fontWeight:FontWeight.w700)),const SizedBox(height:8),Text('${snapshot.error}',textAlign:TextAlign.center,style:const TextStyle(color:_muted)),const SizedBox(height:18),FilledButton.icon(onPressed:_reload,icon:const Icon(Icons.refresh),label:const Text('Skúsiť znova'))])));
        }
        final tracks = snapshot.data?.tracks ?? _loadedTracks ?? const <Track>[];
        _cachedTracks = tracks;
        final visible = _visible(tracks);
        final trackIndices = <String, int>{for (var i = 0; i < tracks.length; i++) tracks[i].id: i};
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Padding(padding:const EdgeInsets.fromLTRB(20,12,20,14),child:Row(crossAxisAlignment:CrossAxisAlignment.end,children:[
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Tvoja hudba',style:TextStyle(fontSize:25,fontWeight:FontWeight.w800,letterSpacing:-.6)),const SizedBox(height:3),Text(snapshot.hasError ? 'Synchronizácia zvyšku knižnice zlyhala' : snapshot.connectionState == ConnectionState.waiting ? 'Načítavam ďalšie skladby na pozadí…' : (_initialArtworkFailures > 0 ? 'Niektoré obaly sa nepodarilo načítať' : 'Hudobná knižnica'),style:const TextStyle(color:_muted,fontSize:13))])),
            Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:7),decoration:BoxDecoration(color:_surface2,borderRadius:BorderRadius.circular(_palette.radius * 1.2),border: Border.all(color: _palette.border)),child:Text('${tracks.length} skladieb',style:const TextStyle(color:_green,fontWeight:FontWeight.w700,fontSize:12))),
          ])),
          Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Container(height:50,decoration:BoxDecoration(color:_surface,borderRadius:BorderRadius.circular(16),border:Border.all(color:_palette.border)),child:TextField(controller:_search,focusNode:_searchFocus,textInputAction:TextInputAction.search,onSubmitted:(_)=>_dismissSearchKeyboard(),onTapOutside:(_)=>_dismissSearchKeyboard(),onChanged:(_)=>setState((){}),style:const TextStyle(fontSize:14),decoration:InputDecoration(hintText:'Hľadať skladbu alebo interpreta…',hintStyle:const TextStyle(color:_muted,fontSize:14),prefixIcon:const Icon(Icons.search_rounded,color:_muted),suffixIcon:_search.text.isEmpty?null:IconButton(onPressed:(){_search.clear();setState((){});},icon:const Icon(Icons.close_rounded)),border:InputBorder.none,contentPadding:const EdgeInsets.symmetric(vertical:14))))),
          const SizedBox(height:13),
          Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(children:[
            _filterChip('Všetky',true),
            const SizedBox(width:8),_filterChip('FLAC',false),
            const Spacer(),
            PopupMenuButton<String>(onSelected:(v)=>setState(()=>_sort=v),itemBuilder:(_)=>const [PopupMenuItem(value:'Názov',child:Text('Názov A–Z')),PopupMenuItem(value:'Názov Z–A',child:Text('Názov Z–A')),PopupMenuItem(value:'Interpret',child:Text('Interpret'))],child:Container(padding:const EdgeInsets.symmetric(horizontal:11,vertical:8),decoration:BoxDecoration(color:_surface,borderRadius:BorderRadius.circular(12)),child:Row(children:[const Icon(Icons.sort_rounded,size:17,color:_green),const SizedBox(width:5),Text(_sort,style:const TextStyle(fontSize:12))]))),
          ])),
          const SizedBox(height:8),
          Expanded(child:visible.isEmpty?const Center(child:Text('Žiadne skladby nezodpovedajú vyhľadávaniu.',style:TextStyle(color:_muted))):ListView.builder(cacheExtent:700,padding:const EdgeInsets.fromLTRB(12,4,12,14),itemCount:visible.length,itemBuilder:(context,i){
            final track=visible[i]; final originalIndex=trackIndices[track.id] ?? -1; final active=_currentIndex==originalIndex;
            _prioritizeArtwork(track);
            final details=[_artist(track.name),if(_size(track.size).isNotEmpty)_size(track.size)].join('  •  ');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Material(
                color: active ? const Color(0xFF18251B) : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
                child: InkWell(
                  borderRadius: BorderRadius.circular(15),
                  onTap: originalIndex < 0 ? null : () => _playTrack(track.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
                    child: Row(children: [
                      _artworkOrFallback(track.id, i),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_title(track.name), maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: active ? _green : Colors.white)),
                        const SizedBox(height: 4),
                        Text(details, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 11)),
                      ])),
                      const SizedBox(width: 6),
                      Icon(active ? Icons.graphic_eq_rounded : Icons.more_horiz_rounded, color: active ? _green : _muted, size: 22),
                    ]),
                  ),
                ),
              ),
            );
          })),
        ]);
      },
    ),
    bottomNavigationBar:_currentIndex==null?null:_miniPlayer(),
  );

  Widget _filterChip(String label,bool all) {
    final selected=all;
    return ChoiceChip(label:Text(label),selected:selected,onSelected:(_){if(!all) { return; }},showCheckmark:false,labelStyle:TextStyle(fontSize:12,fontWeight:FontWeight.w700,color:selected?_bg:_muted),selectedColor:_green,backgroundColor:_surface,side:BorderSide(color:selected?_green:_palette.border),padding:const EdgeInsets.symmetric(horizontal:8));
  }
  Widget _miniPlayer()=>SafeArea(top:false,child:GestureDetector(onTap:_openPlayer,child:Container(
    margin:const EdgeInsets.fromLTRB(10,0,10,7),
    padding:const EdgeInsets.fromLTRB(14,15,10,14),
    decoration:BoxDecoration(color:_surface2,borderRadius:BorderRadius.circular(_palette.radius),border:Border.all(color:_palette.border)),
    child:Column(mainAxisSize:MainAxisSize.min,children:[
      Row(crossAxisAlignment:CrossAxisAlignment.center,children:[
        _currentIndex!=null&&_cachedTracks!=null&&_currentIndex!<_cachedTracks!.length?_artworkOrFallback(_cachedTracks![_currentIndex!].id,_currentIndex!,size:59,iconSize:30):const SizedBox(width:59,height:59),const SizedBox(width:12),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(_currentIndex==null?'':_title(_trackTitle(_currentIndex!)),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:14)),
          const SizedBox(height:3),Text(_currentIndex==null?'':'MusiFy  •  FLAC',style:const TextStyle(color:_muted,fontSize:12)),
        ])),
        IconButton(tooltip:'Predchádzajúca skladba',constraints:const BoxConstraints(minWidth:56,minHeight:60),onPressed:_currentIndex==null||_currentIndex!<=0?null:()=>_player.seekToPrevious(),icon:const Icon(Icons.skip_previous_rounded,size:34)),
        StreamBuilder<PlayerState>(stream:_player.playerStateStream,builder:(context,snapshot){
          final playing=snapshot.data?.playing??false;
          return IconButton(tooltip:playing?'Pozastaviť':'Prehrať',constraints:const BoxConstraints(minWidth:65,minHeight:65),onPressed:_loadingTrack?null:_togglePlayback,icon:_loadingTrack?const SizedBox(width:28,height:28,child:CircularProgressIndicator(strokeWidth:2,color:_green)):Icon(playing?Icons.pause_circle_filled_rounded:Icons.play_circle_fill_rounded,color:_green,size:48));
        }),
        IconButton(tooltip:'Nasledujúca skladba',constraints:const BoxConstraints(minWidth:56,minHeight:60),onPressed:_currentIndex==null?null:()=>_player.seekToNext(),icon:const Icon(Icons.skip_next_rounded,size:34)),
      ]),
      StreamBuilder<Duration>(stream:_player.positionStream,builder:(context,s){
        final duration=_player.duration??Duration.zero;final pos=s.data??Duration.zero;
        final value=duration.inMilliseconds==0?0.0:pos.inMilliseconds.clamp(0,duration.inMilliseconds).toDouble()/duration.inMilliseconds;
        return ClipRRect(borderRadius:BorderRadius.circular(3),child:LinearProgressIndicator(value:value,minHeight:3,backgroundColor:_palette.progressTrack,valueColor:AlwaysStoppedAnimation(_green)));
      }),
    ]),
  )));

  String _trackTitle(int index)=>_cachedTracks!=null&&index>=0&&index<_cachedTracks!.length?_cachedTracks![index].name:'MusiFy';

  void _openPlayer() {
    _dismissSearchKeyboard();
    showModalBottomSheet(context:context,isScrollControlled:true,backgroundColor:Colors.transparent,builder:(context)=>_FullPlayer(player:_player,tracksListenable:_tracksListenable,artworkForTrack:_artworkNotifier));
  }
  Widget _themeOption(BuildContext context, AppTheme theme) {
    final palette = _palettes[theme]!;
    final selected = appTheme.value == theme;
    final title = switch (theme) {
      AppTheme.original => 'Pôvodný MusiFy',
      AppTheme.midnightAmoled => 'Midnight AMOLED',
      AppTheme.auroraGlow => 'Aurora Glow',
      AppTheme.crystalDream => 'Crystal Dream',
      AppTheme.goldenHorizon => 'Golden Horizon',
    };
    final subtitle = switch (theme) {
      AppTheme.original => 'Pôvodný tmavý vzhľad so zeleným akcentom',
      AppTheme.midnightAmoled => 'Hlboká čierna a tyrkysové akcenty',
      AppTheme.auroraGlow => 'Teplé gradienty a farebné vlny',
      AppTheme.crystalDream => 'Sklenené plochy a levanduľové odtiene',
      AppTheme.goldenHorizon => 'Čierna, zlato a geometrické detaily',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: selected ? palette.accent.withValues(alpha: .12) : palette.surface2,
        borderRadius: BorderRadius.circular(palette.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(palette.radius),
          onTap: () async {
            appTheme.value = theme;
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('musify_player_theme', theme.name);
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tému sa nepodarilo uložiť.')));
              }
            }
            if (context.mounted) Navigator.pop(context);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            child: Row(children: [
              Container(width: 38, height: 38, decoration: BoxDecoration(
                gradient: LinearGradient(colors: [palette.accent, palette.secondary]),
                borderRadius: BorderRadius.circular(palette.glass ? 13 : 9),
                border: Border.all(color: palette.border),
              ), child: Icon(theme == AppTheme.crystalDream ? Icons.diamond_rounded : theme == AppTheme.goldenHorizon ? Icons.auto_awesome : theme == AppTheme.auroraGlow ? Icons.waves_rounded : Icons.graphic_eq_rounded, color: palette.background, size: 21)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: palette.muted, fontSize: 11)),
              ])),
              Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: palette.accent),
            ]),
          ),
        ),
      ),
    );
  }

  void _showSettings()=>showModalBottomSheet(context:context,backgroundColor:_surface,isScrollControlled:true,showDragHandle:true,builder:(context)=>SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(20,8,20,28),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Text('Nastavenia',style:TextStyle(fontSize:23,fontWeight:FontWeight.w800)),const SizedBox(height:16),
    const Text('VZHĽAD PREHRÁVAČA', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.3)),
    const SizedBox(height: 10),
    for (final theme in AppTheme.values) _themeOption(context, theme),,
    ListTile(leading:Icon(Icons.cloud_outlined,color:_green),title:const Text('Hudobná knižnica'),subtitle:const Text('Zdroj: verejný priečinok kDrive')),
    ExpansionTile(
      leading: const Icon(Icons.monitor_heart_outlined, color: _green),
      title: const Text('Diagnostika prehrávania'),
      children: [
        StreamBuilder<MediaItem?>(
          stream: AudioService.currentMediaItemStream,
          builder: (context, mediaSnapshot) => StreamBuilder<PlaybackState>(
            stream: AudioService.playbackStateStream,
            builder: (context, stateSnapshot) {
              final media = mediaSnapshot.data;
              final state = stateSnapshot.data;
              final lines = [
                'MediaItem: ${media?.title ?? 'ŽIADNA'}',
                'Prehrávanie: ${state?.playing ?? 'bez dát'}',
                'ProcessingState: ${state?.processingState ?? 'bez dát'}',
                'Ovládacie prvky: ${state?.controls.map((c) => c.toString()).join(', ') ?? '-'}',
                'AudioPlayer: ${_player.playing} / index ${_player.currentIndex}',
              ];
              return Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(lines.join('\\n'), style: const TextStyle(color: _muted, fontSize: 11)),
              );
            },
          ),
        ),
      ],
    ),
    ExpansionTile(
      leading: const Icon(Icons.library_music_outlined, color: _green),
      title: const Text('Diagnostika knižnice'),
      children: [
        FutureBuilder<LibraryResult>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Načítavam diagnostiku knižnice…', style: TextStyle(color: _muted)),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText('Chyba načítania: ${snapshot.error}', style: const TextStyle(color: _muted, fontSize: 11)),
              );
            }
            final result = snapshot.data;
            if (result == null) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Diagnostické údaje nie sú dostupné.', style: TextStyle(color: _muted)),
              );
            }
            final report = result.diagnostics.join('\\n');
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: report));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Diagnostika skopírovaná do schránky')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Kopírovať diagnostiku'),
                    ),
                  ),
                  SelectableText(report, style: const TextStyle(color: _muted, fontSize: 11)),
                ],
              ),
            );
          },
        ),
      ],
    ),
  ]))));
}

class _FullPlayer extends StatelessWidget {
  const _FullPlayer({required this.player,required this.tracksListenable,required this.artworkForTrack});
  final AudioPlayer player;
  final ValueListenable<List<Track>> tracksListenable;
  final ValueListenable<File?> Function(String) artworkForTrack;
  String _time(Duration d)=>'${d.inMinutes}:${(d.inSeconds%60).toString().padLeft(2,'0')}';
  String _artist(String name) {
    final dash=name.indexOf(' - ');
    return dash>0?name.substring(0,dash):'Miestna knižnica';
  }
  String _title(String name) {
    final dash=name.indexOf(' - ');
    final value=dash>0?name.substring(dash+3):name;
    return value.replaceAll(RegExp(r'\\.(flac|mp3|m4a|aac|ogg|opus|wav|wma)$',caseSensitive:false),'');
  }
  @override
  Widget build(BuildContext context) {
    return Container(
      height:MediaQuery.of(context).size.height*.88,
      decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:_palette.playerGradient),borderRadius:BorderRadius.vertical(top:Radius.circular(_palette.glass ? 34 : 28)),border:Border.all(color:_palette.border.withValues(alpha: .8))),
      child:SafeArea(
        child:Padding(
          padding:const EdgeInsets.fromLTRB(22,8,22,20),
          child:ValueListenableBuilder<List<Track>>(
            valueListenable: tracksListenable,
            builder: (context, tracks, _) => StreamBuilder<int?>(
            stream:player.currentIndexStream,
            initialData:player.currentIndex,
            builder:(context,indexSnapshot) {
              final index=indexSnapshot.data;
              final valid=index!=null&&index>=0&&index<tracks.length;
              final name=valid?tracks[index].name:'MusiFy';
              return Column(children:[
                Row(children:[
                  IconButton(onPressed:()=>Navigator.pop(context),icon:const Icon(Icons.keyboard_arrow_down_rounded,size:30)),
                  const Expanded(child:Text('PRÁVE SA PREHRÁVA',textAlign:TextAlign.center,style:TextStyle(color:_muted,fontSize:11,fontWeight:FontWeight.w700,letterSpacing:1.5))),
                  IconButton(onPressed:()=>Navigator.pop(context),icon:const Icon(Icons.more_horiz_rounded)),
                ]),
                const Spacer(),
                Container(
                  width:MediaQuery.of(context).size.width*.72,
                  height:MediaQuery.of(context).size.width*.72,
                  constraints:const BoxConstraints(maxWidth:320,maxHeight:320),
                  decoration:BoxDecoration(borderRadius:BorderRadius.circular(_palette.glass ? 34 : 28),gradient:LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:_palette.playerGradient),boxShadow:[BoxShadow(color:_green.withValues(alpha: _palette.glass ? .28 : .12),blurRadius:40,spreadRadius:2)]),
                  child: valid
                    ? ValueListenableBuilder<File?>(
                        valueListenable: artworkForTrack(tracks[index].id),
                        builder: (context, imageFile, _) => imageFile == null
                          ? const Center(child:Icon(Icons.graphic_eq_rounded,size:112,color:_green))
                          : ClipRRect(
                              borderRadius:BorderRadius.circular(28),
                              child:Image.file(imageFile,fit:BoxFit.cover,width:double.infinity,height:double.infinity,cacheWidth:640,cacheHeight:640,errorBuilder:(context,error,stackTrace)=>const Center(child:Icon(Icons.graphic_eq_rounded,size:112,color:_green))),
                            ),
                      )
                    : const Center(child:Icon(Icons.graphic_eq_rounded,size:112,color:_green)),
                ),
                const SizedBox(height:34),
                Text(_title(name),key:ValueKey('title-$index'),maxLines:2,textAlign:TextAlign.center,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:22,fontWeight:FontWeight.w800,letterSpacing:-.4)),
                const SizedBox(height:7),
                Text(valid?_artist(name):'',key:ValueKey('artist-$index'),style:const TextStyle(color:_muted,fontSize:14)),
                const SizedBox(height:25),
                StreamBuilder<Duration>(stream:player.positionStream,builder:(context,s){
                  final duration=player.duration??Duration.zero;
                  final pos=s.data??Duration.zero;
                  final max=duration.inMilliseconds.toDouble().clamp(1,double.infinity).toDouble();
                  return Column(children:[
                    Slider(value:pos.inMilliseconds.toDouble().clamp(0,max).toDouble(),max:max,onChanged:(v)=>player.seek(Duration(milliseconds:v.round()))),
                    Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
                      Text(_time(pos),style:const TextStyle(color:_muted,fontSize:12)),
                      Text(_time(duration),style:const TextStyle(color:_muted,fontSize:12)),
                    ]),
                  ]);
                }),
                const SizedBox(height:18),
                Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:[
                  IconButton(iconSize:25,onPressed:()=>player.setShuffleModeEnabled(!player.shuffleModeEnabled),icon:StreamBuilder<bool>(stream:player.shuffleModeEnabledStream,builder:(c,s)=>Icon(Icons.shuffle_rounded,color:(s.data??false)?_green:_muted))),
                  IconButton(iconSize:38,onPressed:()=>player.seekToPrevious(),icon:const Icon(Icons.skip_previous_rounded)),
                  StreamBuilder<PlayerState>(stream:player.playerStateStream,builder:(context,s){
                    final playing=s.data?.playing??false;
                    return Container(width:70,height:70,decoration:BoxDecoration(color:_green,shape:BoxShape.circle,boxShadow:[BoxShadow(color:_green.withValues(alpha:.28),blurRadius:18,spreadRadius:2)]),child:IconButton(iconSize:39,color:_bg,onPressed:()=>playing?player.pause():player.play(),icon:Icon(playing?Icons.pause_rounded:Icons.play_arrow_rounded)));
                  }),
                  IconButton(iconSize:38,onPressed:()=>player.seekToNext(),icon:const Icon(Icons.skip_next_rounded)),
                  IconButton(iconSize:25,onPressed:()=>player.setLoopMode(player.loopMode==LoopMode.off?LoopMode.all:LoopMode.off),icon:StreamBuilder<LoopMode>(stream:player.loopModeStream,builder:(c,s)=>Icon(Icons.repeat_rounded,color:(s.data??LoopMode.off)==LoopMode.off?_muted:_green))),
                ]),
                const Spacer(),
              ]);
            },
          ),
          ),
        ),
      ),
    );
  }
}
