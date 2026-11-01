import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_service/audio_service.dart';

const _bg = Color(0xFF090D0B);
const _surface = Color(0xFF151B17);
const _surface2 = Color(0xFF1D2620);
const _green = Color(0xFF70E34B);
const _muted = Color(0xFF9BA69E);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.streamzone.musify.channel.audio',
    androidNotificationChannelName: 'MusiFy – prehrávanie hudby',
    androidNotificationOngoing: true,
  );
  runApp(const MusiFyApp());
}

class MusiFyApp extends StatelessWidget {
  const MusiFyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MusiFy',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _bg,
      colorScheme: ColorScheme.fromSeed(seedColor: _green, brightness: Brightness.dark, surface: _surface),
      useMaterial3: true,
      appBarTheme: const AppBarTheme(backgroundColor: _bg, surfaceTintColor: Colors.transparent, elevation: 0),
      sliderTheme: const SliderThemeData(activeTrackColor: _green, thumbColor: _green, inactiveTrackColor: Color(0xFF38443B), overlayColor: Color(0x2270E34B)),
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
  Uri _downloadUri(String fileId) => Uri.https('kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files/$fileId/download');
  Uri _shareRootUri() => Uri.https('kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files');
  Uri _folderFilesUri(String folderId, {String? cursor, int? page}) => Uri.https(
    'kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files/$folderId/files',
    {if (cursor != null) 'cursor': cursor, if (page != null) 'page': '$page'},
  );
  Future<dynamic> _getJson(Uri uri) async {
    final response = await http.get(uri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw Exception('kDrive odpovedal HTTP ${response.statusCode} pri načítaní obsahu.');
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
  Future<LibraryResult> loadAudioTracks() async {
    final root = await _getJson(_shareRootUri());
    if (root is! Map || root['data'] is! Map) throw FormatException('kDrive neposkytol metadáta zdieľaného priečinka.');
    final rootData = Map<String, dynamic>.from(root['data'] as Map);
    final rootId = (rootData['id'] ?? '').toString();
    if (rootId.isEmpty || rootData['type'] != 'dir') throw FormatException('Zdieľaný odkaz nevrátil priečinok. ID: $rootId, typ: ${rootData['type']}.');
    final tracks = <Track>[];
    final pendingFolders = <String>[rootId];
    final visitedFolders = <String>{};
    final diagnostics = <String>['Koreň: ID=$rootId, názov=${rootData['name'] ?? '-'}'];
    while (pendingFolders.isNotEmpty) {
      final folderId = pendingFolders.removeAt(0);
      if (!visitedFolders.add(folderId)) continue;
      final cursors = <String>{};
      String? cursor;
      var pageNumber = 1;
      for (var page = 0; page < 100; page++) {
        final response = await _getJson(_folderFilesUri(folderId, cursor: cursor, page: cursor == null ? pageNumber : null));
        final pageData = _parsePage(response);
        diagnostics.add('Priečinok $folderId / strana ${page + 1}: položiek ${pageData.items.length}, has_more=${pageData.hasMore}, cursor=${pageData.cursor == null ? 'null' : 'prítomný'}, ${pageData.responseKeys}');
        for (final item in pageData.items) {
          final type = (item['type'] ?? '').toString();
          final id = (item['id'] ?? '').toString();
          if (type == 'dir' && id.isNotEmpty) { pendingFolders.add(id); continue; }
          if (type != 'file') continue;
          final track = Track.fromJson(item);
          final name = track.name.toLowerCase();
          final audio = track.mimeType.startsWith('audio/') || const ['.flac', '.mp3', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.wma'].any(name.endsWith);
          if (audio && track.id.isNotEmpty) tracks.add(track);
        }
        if (!pageData.hasMore) break;
        final next = pageData.cursor;
        if (next != null && next.isNotEmpty) {
          if (!cursors.add(next)) throw Exception('kDrive opakovane vrátil rovnaký kurzor.');
          cursor = next;
        } else { pageNumber++; }
      }
    }
    tracks.sort((a,b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    diagnostics.add('Hotovo: priečinkov ${visitedFolders.length}, skladieb ${tracks.length}');
    return LibraryResult(tracks, diagnostics);
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
    return _Page(items, more, cursorValue?.toString(), 'kľúče root=${root.keys.join(',')}; data=${data.keys.join(',')}; pagination=${pagination.keys.join(',')}');
  }
}
class _Page { const _Page(this.items,this.hasMore,this.cursor,this.responseKeys); final List<Map<String,dynamic>> items; final bool hasMore; final String? cursor; final String responseKeys; }
class LibraryResult { const LibraryResult(this.tracks,this.diagnostics); final List<Track> tracks; final List<String> diagnostics; }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override State<LibraryPage> createState() => _LibraryPageState();
}
class _LibraryPageState extends State<LibraryPage> {
  final _service = KDriveService();
  late Future<LibraryResult> _future;
  late final AudioPlayer _player;
  final _search = TextEditingController();
  int? _currentIndex;
  bool _loadingTrack = false;
  List<Track>? _cachedTracks;
  bool _playlistReady = false;
  String _filter = 'Všetky';
  String _sort = 'Názov';

  @override void initState() {
    super.initState();
    _future = _service.loadAudioTracks();
    _player = AudioPlayer();
    _player.currentIndexStream.listen((index) { if (mounted && index != null) setState(() => _currentIndex = index); });
  }
  @override void dispose() { _search.dispose(); _player.dispose(); super.dispose(); }
  void _reload() => setState(() => _future = _service.loadAudioTracks());

  Future<void> _playTrack(int index) async {
    final snapshot = await _future;
    final tracks = snapshot.tracks;
    if (index < 0 || index >= tracks.length) return;
    setState(() { _currentIndex = index; _loadingTrack = true; });
    try {
      if (!_playlistReady) {
        final sources = tracks.map((track) => AudioSource.uri(_service._downloadUri(track.id), tag: MediaItem(id: track.id, title: track.name, album: 'MusiFy'))).toList();
        await _player.setAudioSource(ConcatenatingAudioSource(children: sources), initialIndex: index, initialPosition: Duration.zero);
        _playlistReady = true;
      } else { await _player.seek(Duration.zero, index: index); }
      final playbackFuture = _player.play();
      if (mounted) setState(() => _loadingTrack = false);
      await playbackFuture;
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Skladbu sa nepodarilo prehrať: $error')));
    } finally { if (mounted) setState(() => _loadingTrack = false); }
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
        Container(width: 38,height: 38,decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),gradient: const LinearGradient(colors:[Color(0xFF4020A0),Color(0xFF7B2DCE),_green],begin:Alignment.topLeft,end:Alignment.bottomRight)),child: const Center(child: Text('M',style:TextStyle(fontSize:27,fontWeight:FontWeight.w900,color:Colors.white)))),
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
        if(snapshot.connectionState==ConnectionState.waiting) return const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[CircularProgressIndicator(color:_green),SizedBox(height:16),Text('Načítavam hudobnú knižnicu z kDrive…',style:TextStyle(color:_muted))]));
        if(snapshot.hasError) return Center(child:Padding(padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.cloud_off_rounded,size:60,color:_muted),const SizedBox(height:16),const Text('Knižnicu sa nepodarilo načítať',style:TextStyle(fontSize:19,fontWeight:FontWeight.w700)),const SizedBox(height:8),Text('${snapshot.error}',textAlign:TextAlign.center,style:const TextStyle(color:_muted)),const SizedBox(height:18),FilledButton.icon(onPressed:_reload,icon:const Icon(Icons.refresh),label:const Text('Skúsiť znova'))])));
        final tracks=snapshot.data!.tracks; _cachedTracks=tracks;
        final visible=_visible(tracks);
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Padding(padding:const EdgeInsets.fromLTRB(20,12,20,14),child:Row(crossAxisAlignment:CrossAxisAlignment.end,children:[
            const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Tvoja hudba',style:TextStyle(fontSize:25,fontWeight:FontWeight.w800,letterSpacing:-.6)),SizedBox(height:3),Text('Hudobná knižnica',style:TextStyle(color:_muted,fontSize:13))])),
            Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:7),decoration:BoxDecoration(color:_surface2,borderRadius:BorderRadius.circular(20)),child:Text('${tracks.length} skladieb',style:const TextStyle(color:_green,fontWeight:FontWeight.w700,fontSize:12))),
          ])),
          Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Container(height:50,decoration:BoxDecoration(color:_surface,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF27332A))),child:TextField(controller:_search,onChanged:(_)=>setState((){}),style:const TextStyle(fontSize:14),decoration:InputDecoration(hintText:'Hľadať skladbu alebo interpreta…',hintStyle:const TextStyle(color:_muted,fontSize:14),prefixIcon:const Icon(Icons.search_rounded,color:_muted),suffixIcon:_search.text.isEmpty?null:IconButton(onPressed:(){_search.clear();setState((){});},icon:const Icon(Icons.close_rounded)),border:InputBorder.none,contentPadding:const EdgeInsets.symmetric(vertical:14))))),
          const SizedBox(height:13),
          Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(children:[
            _filterChip('Všetky',true),
            const SizedBox(width:8),_filterChip('FLAC',false),
            const Spacer(),
            PopupMenuButton<String>(onSelected:(v)=>setState(()=>_sort=v),itemBuilder:(_)=>const [PopupMenuItem(value:'Názov',child:Text('Názov A–Z')),PopupMenuItem(value:'Názov Z–A',child:Text('Názov Z–A')),PopupMenuItem(value:'Interpret',child:Text('Interpret'))],child:Container(padding:const EdgeInsets.symmetric(horizontal:11,vertical:8),decoration:BoxDecoration(color:_surface,borderRadius:BorderRadius.circular(12)),child:Row(children:[const Icon(Icons.sort_rounded,size:17,color:_green),const SizedBox(width:5),Text(_sort,style:const TextStyle(fontSize:12))]))),
          ])),
          const SizedBox(height:8),
          Expanded(child:visible.isEmpty?const Center(child:Text('Žiadne skladby nezodpovedajú vyhľadávaniu.',style:TextStyle(color:_muted))):ListView.builder(padding:const EdgeInsets.fromLTRB(12,4,12,14),itemCount:visible.length,itemBuilder:(context,i){
            final track=visible[i]; final originalIndex=tracks.indexOf(track); final active=_currentIndex==originalIndex;
            final details=[_artist(track.name),if(_size(track.size).isNotEmpty)_size(track.size)].join('  •  ');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Material(
                color: active ? const Color(0xFF18251B) : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
                child: InkWell(
                  borderRadius: BorderRadius.circular(15),
                  onTap: () => _playTrack(originalIndex),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
                    child: Row(children: [
                      _artTile(i, active),
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
    return ChoiceChip(label:Text(label),selected:selected,onSelected:(_){if(!all)return;},showCheckmark:false,labelStyle:TextStyle(fontSize:12,fontWeight:FontWeight.w700,color:selected?_bg:_muted),selectedColor:_green,backgroundColor:_surface,side:BorderSide(color:selected?_green:const Color(0xFF29342C)),padding:const EdgeInsets.symmetric(horizontal:8));
  }
  Widget _artTile(int index,bool active)=>Container(width:49,height:49,decoration:BoxDecoration(borderRadius:BorderRadius.circular(12),gradient:LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:[[_green,const Color(0xFF1D7043),const Color(0xFF285C70),const Color(0xFF6B3D8E)][index%4],_surface2])),child:Center(child:Icon(active?Icons.equalizer_rounded:Icons.music_note_rounded,color:active?_green:Colors.white70,size:25)));
  Widget _miniPlayer()=>SafeArea(top:false,child:GestureDetector(onTap:_openPlayer,child:Container(
    margin:const EdgeInsets.fromLTRB(10,0,10,7),
    padding:const EdgeInsets.fromLTRB(14,15,10,14),
    decoration:BoxDecoration(color:_surface2,borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFF344238))),
    child:Column(mainAxisSize:MainAxisSize.min,children:[
      Row(crossAxisAlignment:CrossAxisAlignment.center,children:[
        Container(width:59,height:59,decoration:BoxDecoration(borderRadius:BorderRadius.circular(13),gradient:LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:[[_green,const Color(0xFF1D7043),const Color(0xFF285C70),const Color(0xFF6B3D8E)][(_currentIndex??0)%4],_surface2])),child:Center(child:Icon(Icons.equalizer_rounded,color:_green,size:30))),const SizedBox(width:12),
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
        return ClipRRect(borderRadius:BorderRadius.circular(3),child:LinearProgressIndicator(value:value,minHeight:3,backgroundColor:const Color(0xFF3A453D),valueColor:const AlwaysStoppedAnimation(_green)));
      }),
    ]),
  )));

  String _trackTitle(int index)=>_cachedTracks!=null&&index>=0&&index<_cachedTracks!.length?_cachedTracks![index].name:'MusiFy';

  void _openPlayer()=>showModalBottomSheet(context:context,isScrollControlled:true,backgroundColor:Colors.transparent,builder:(context)=>_FullPlayer(player:_player,tracks:_cachedTracks??const <Track>[]));
  void _showSettings()=>showModalBottomSheet(context:context,backgroundColor:_surface,isScrollControlled:true,showDragHandle:true,builder:(context)=>SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(20,8,20,28),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Text('Nastavenia',style:TextStyle(fontSize:23,fontWeight:FontWeight.w800)),const SizedBox(height:16),
    const ListTile(leading:Icon(Icons.palette_outlined,color:_green),title:Text('Vzhľad'),subtitle:Text('Tmavý motív • zelená akcentová farba')),
    const ListTile(leading:Icon(Icons.cloud_outlined,color:_green),title:Text('Hudobná knižnica'),subtitle:Text('Zdroj: verejný priečinok kDrive')),
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
  ]))));
}

class _FullPlayer extends StatelessWidget {
  const _FullPlayer({required this.player,required this.tracks});
  final AudioPlayer player;
  final List<Track> tracks;
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
      decoration:const BoxDecoration(color:_surface,borderRadius:BorderRadius.vertical(top:Radius.circular(28))),
      child:SafeArea(
        child:Padding(
          padding:const EdgeInsets.fromLTRB(22,8,22,20),
          child:StreamBuilder<int?>(
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
                  decoration:BoxDecoration(borderRadius:BorderRadius.circular(28),gradient:const LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:[Color(0xFF244A31),Color(0xFF13251B),Color(0xFF263A2C)]),boxShadow:[BoxShadow(color:_green.withOpacity(.12),blurRadius:40,spreadRadius:2)]),
                  child:const Center(child:Icon(Icons.graphic_eq_rounded,size:112,color:_green)),
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
                    return Container(width:70,height:70,decoration:const BoxDecoration(color:_green,shape:BoxShape.circle),child:IconButton(iconSize:39,color:_bg,onPressed:()=>playing?player.pause():player.play(),icon:Icon(playing?Icons.pause_rounded:Icons.play_arrow_rounded)));
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
    );
  }
}
