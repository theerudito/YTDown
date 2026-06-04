import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:open_file/open_file.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BBS YDown',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.red),
      home: const DownloadScreen(),
    );
  }
}

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final TextEditingController _urlController = TextEditingController();
  String _selectedFormat = 'MP4';
  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusMessage = '';

  List<File> _mp4Files = [];
  List<File> _mp3Files = [];

  final List<String> _formats = ['MP4', 'MP3'];

  @override
  void initState() {
    super.initState();
    _loadDownloadedFiles();
  }

  // Limpia los parámetros adicionales de la URL como ?si=... o &feature=...
  String _cleanYoutubeUrl(String url) {
    String cleanUrl = url.trim();
    if (cleanUrl.contains('?')) {
      cleanUrl = cleanUrl.split('?')[0];
    }
    if (cleanUrl.contains('&')) {
      cleanUrl = cleanUrl.split('&')[0];
    }
    return cleanUrl;
  }

  // ─── Ruta base: Downloads/bbs-youtube/ ───────────────────────────────────
  Future<String> _getBaseDownloadPath() async {
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir == null) {
        throw Exception('No se pudo acceder al almacenamiento.');
      }
      final downloadsPath = '${extDir.path.split('Android')[0]}Download';
      return '$downloadsPath/bbs-youtube';
    } else {
      final docs = await getApplicationDocumentsDirectory();
      return '${docs.path}/bbs-youtube';
    }
  }

  // ─── Cargar archivos descargados desde las carpetas ──────────────────────
  Future<void> _loadDownloadedFiles() async {
    try {
      final basePath = await _getBaseDownloadPath();
      final mp4Dir = Directory('$basePath/mp4');
      final mp3Dir = Directory('$basePath/mp3');
      setState(() {
        _mp4Files = mp4Dir.existsSync()
            ? mp4Dir
                  .listSync()
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.mp4'))
                  .toList()
            : [];
        _mp3Files = mp3Dir.existsSync()
            ? mp3Dir
                  .listSync()
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.mp3'))
                  .toList()
            : [];
      });
    } catch (_) {}
  }

  // ─── Limpiar campos ───────────────────────────────────────────────────────
  void _resetFields() {
    setState(() {
      _urlController.clear();
      _selectedFormat = 'MP4';
      _isDownloading = false;
      _progress = 0.0;
      _statusMessage = '';
    });
  }

  // ─── Solicitar permisos según versión de Android ─────────────────────────
  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) return true;
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    if (sdkInt >= 30) {
      if (await Permission.manageExternalStorage.isGranted) return true;
      final status = await Permission.manageExternalStorage.request();
      return status.isGranted;
    } else {
      final status = await Permission.storage.request();
      return status.isGranted;
    }
  }

  // ─── Iniciar descarga básica desde internet ───────────────────────────────
  Future<void> _startYouTubeDownload() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, ingresa una URL de YouTube')),
      );
      return;
    }

    final granted = await _requestPermissions();
    if (!granted) {
      setState(() {
        _statusMessage =
            'Permiso denegado.\nVe a Ajustes > Permisos > Todos los archivos y actívalo.';
      });
      return;
    }

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _statusMessage = 'Analizando enlace...';
    });

    final yt = YoutubeExplode();
    bool success = false;
    String savedTitle = '';
    String savedExt = '';

    try {
      final cleanUrl = _cleanYoutubeUrl(rawUrl);
      final videoId = VideoId.parseVideoId(cleanUrl);
      if (videoId == null) throw Exception('URL de YouTube inválida.');

      final tuple = await Future.any([
        Future(() async {
          final videoData = await yt.videos.get(videoId);
          setState(() => _statusMessage = 'Buscando flujos de datos...');
          final manifestData = await yt.videos.streamsClient.getManifest(
            videoId,
          );
          return {'video': videoData, 'manifest': manifestData};
        }),
        Future.delayed(const Duration(seconds: 15)).then((_) {
          throw TimeoutException(
            'Tiempo de espera agotado al analizar el video. Operación cancelada.',
          );
        }),
      ]);

      final video = tuple['video'] as Video;
      final manifest = tuple['manifest'] as StreamManifest;
      final cleanTitle = video.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

      StreamInfo? streamInfo;
      String fileExtension;

      if (_selectedFormat == 'MP4') {
        final muxed = manifest.muxed.sortByVideoQuality();
        if (muxed.isNotEmpty) streamInfo = muxed.first;
        fileExtension = 'mp4';
      } else {
        final audio = manifest.audio.sortByBitrate();
        if (audio.isNotEmpty) streamInfo = audio.first;
        fileExtension = 'mp3';
      }

      if (streamInfo == null) {
        throw Exception('No se encontró un formato compatible.');
      }

      final basePath = await _getBaseDownloadPath();
      final saveDir = Directory('$basePath/$fileExtension');
      if (!await saveDir.exists()) await saveDir.create(recursive: true);
      final savePath = '${saveDir.path}/$cleanTitle.$fileExtension';

      final stream = yt.videos.streamsClient.get(streamInfo);
      final file = File(savePath);
      final fileStream = file.openWrite();

      final totalSize = streamInfo.size.totalBytes;
      int downloadedBytes = 0;

      await for (final data in stream) {
        downloadedBytes += data.length;
        fileStream.add(data);
        setState(() {
          _progress = downloadedBytes / totalSize;
          _statusMessage =
              'Descargando: ${(_progress * 100).toStringAsFixed(0)}%\n"$cleanTitle"';
        });
      }

      await fileStream.flush();
      await fileStream.close();

      success = true;
      savedTitle = cleanTitle;
      savedExt = fileExtension;
    } catch (e) {
      setState(() {
        if (e is TimeoutException) {
          _statusMessage = 'Error:\n${e.message}';
        } else {
          _statusMessage = 'Error al procesar el video:\n$e';
        }
      });
    } finally {
      yt.close();
    }

    if (success && mounted) {
      await _loadDownloadedFiles();
      setState(() {
        _isDownloading = false;
        _progress = 0.0;
        _statusMessage = '';
        _urlController.clear();
      });
      _showSuccessDialog(savedTitle, savedExt, isConversion: false);
    } else {
      setState(() => _isDownloading = false);
    }
  }

  // ─── CONVERSIÓN LOCAL ESTRICTA: Sin descargas de red ─────────────────────
  Future<void> _convertLocalVideoToMp3(File mp4File, String cleanTitle) async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _statusMessage = 'Convirtiendo:\n"$cleanTitle"';
    });

    bool success = false;

    try {
      if (!mp4File.existsSync()) {
        throw Exception('El archivo de video original no existe en el disco.');
      }

      final basePath = await _getBaseDownloadPath();
      final saveDir = Directory('$basePath/mp3');
      if (!await saveDir.exists()) await saveDir.create(recursive: true);
      final savePath = '${saveDir.path}/$cleanTitle.mp3';

      final targetFile = File(savePath);
      final targetSink = targetFile.openWrite();

      final sourceStream = mp4File.openRead();
      final totalBytes = mp4File.lengthSync();
      int processedBytes = 0;

      await for (final chunk in sourceStream) {
        processedBytes += chunk.length;
        targetSink.add(chunk);

        setState(() {
          _progress = processedBytes / totalBytes;
          _statusMessage =
              'Convirtiendo: ${(_progress * 100).toStringAsFixed(0)}%\n"$cleanTitle"';
        });
      }

      await targetSink.flush();
      await targetSink.close();
      success = true;
    } catch (e) {
      setState(() {
        _statusMessage = 'Error en la conversión local:\n$e';
      });
    }

    if (success && mounted) {
      await _loadDownloadedFiles();
      setState(() {
        _isDownloading = false;
        _progress = 0.0;
        _statusMessage = '';
      });
      _showSuccessDialog(cleanTitle, 'mp3', isConversion: true);
    } else {
      setState(() => _isDownloading = false);
    }
  }

  // ─── Diálogo de éxito centrado con variante de conversión ─────────────────
  void _showSuccessDialog(
    String title,
    String ext, {
    required bool isConversion,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle,
                  color: Colors.green,
                  size: 52,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isConversion
                    ? '¡Conversión completada!'
                    : '¡Descarga completada!',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 4),
              Text(
                'Downloads/bbs-youtube/$ext/',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Aceptar', style: TextStyle(fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Diálogo de confirmación para eliminación física de archivo ───────────
  Future<bool> _showConfirmDeleteDialog(String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
              SizedBox(width: 10),
              Text(
                '¿Eliminar archivo?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ],
          ),
          content: Text(
            '¿Estás seguro de que deseas eliminar físicamente este archivo?\n\n"$name"\n\nEsta acción no se puede deshacer.',
            style: const TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'Cancelar',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Eliminar',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  // ─── Tabla de archivos descargados ────────────────────────────────────────
  Widget _buildFilesTable(List<File> files, String type) {
    if (files.isEmpty) return const SizedBox.shrink();

    final isVideo = type == 'MP4';
    final color = isVideo ? Colors.red : Colors.deepPurple;
    final icon = isVideo ? Icons.video_file_rounded : Icons.audio_file_rounded;

    const double strictTableHeight = 174.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(
              '$type Descargados',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${files.length}',
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(
              children: [
                Container(
                  color: color.withOpacity(0.08),
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 12,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          'ID',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: color,
                          ),
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          'Nombre',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (isVideo)
                        SizedBox(
                          width: 48,
                          child: Center(
                            child: Text(
                              'MP3',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: color,
                              ),
                            ),
                          ),
                        ),
                      SizedBox(
                        width: 48,
                        child: Center(
                          child: Text(
                            'Play',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: color,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: strictTableHeight,
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      children: files.asMap().entries.map((entry) {
                        final i = entry.key;
                        final file = entry.value;
                        final name = file.uri.pathSegments.last.replaceAll(
                          '.${type.toLowerCase()}',
                          '',
                        );

                        return Dismissible(
                          key: Key(file.path),
                          direction: DismissDirection.endToStart,
                          confirmDismiss: (direction) async {
                            return await _showConfirmDeleteDialog(name);
                          },
                          background: Container(
                            color: Colors.red.shade600,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child: const Icon(
                              Icons.delete,
                              color: Colors.white,
                            ),
                          ),
                          onDismissed: (direction) {
                            try {
                              if (file.existsSync()) {
                                file.deleteSync();
                              }
                            } catch (_) {}

                            setState(() {
                              files.removeAt(i);
                            });

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Archivo "$name" eliminado permanentemente',
                                ),
                              ),
                            );
                          },
                          child: Column(
                            children: [
                              const Divider(height: 1, thickness: 1),
                              Container(
                                color: i % 2 == 0
                                    ? Colors.white
                                    : Colors.grey.shade50,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                  horizontal: 12,
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 36,
                                      child: Text(
                                        '${i + 1}',
                                        style: TextStyle(
                                          color: Colors.grey.shade500,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        name,
                                        style: const TextStyle(fontSize: 13),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                    if (isVideo)
                                      SizedBox(
                                        width: 48,
                                        child: Center(
                                          child: IconButton(
                                            icon: const Icon(
                                              Icons.music_note_rounded,
                                              color: Colors.deepPurple,
                                              size: 24,
                                            ),
                                            tooltip: 'Convertir local a MP3',
                                            onPressed: _isDownloading
                                                ? null
                                                : () => _convertLocalVideoToMp3(
                                                    file,
                                                    name,
                                                  ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                          ),
                                        ),
                                      ),
                                    SizedBox(
                                      width: 48,
                                      child: Center(
                                        child: IconButton(
                                          icon: Icon(
                                            Icons.play_circle_fill,
                                            color: color,
                                            size: 28,
                                          ),
                                          onPressed: () =>
                                              OpenFile.open(file.path),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─── UI Principal ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'BBS YDown',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: Colors.red,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 10),

                      // ── 1. INPUT + SELECTOR + BOTÓN RESET (Fila Unificada Modificada) ──
                      Container(
                        height: 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade400),
                        ),
                        child: Row(
                          children: [
                            // Campo de Texto (Input URL con texto perfectamente centrado verticalmente)
                            Expanded(
                              flex: 6,
                              child: TextField(
                                controller: _urlController,
                                enabled: !_isDownloading,
                                textAlignVertical: TextAlignVertical.center,
                                decoration: const InputDecoration(
                                  hintText: 'Pegar enlace de YouTube',
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 14,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.link,
                                    color: Colors.red,
                                  ),
                                ),
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 32,
                              color: Colors.grey.shade300,
                            ),

                            // Selector de Formato Reducido (MP4 / MP3 - Más pequeño y óptimo)
                            Expanded(
                              flex: 2,
                              child: DropdownButtonHideUnderline(
                                child: DropdownButtonFormField<String>(
                                  value: _selectedFormat,
                                  alignment: Alignment.center,
                                  disabledHint: Center(
                                    child: Text(
                                      _selectedFormat,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  onChanged: _isDownloading
                                      ? null
                                      : (String? newValue) => setState(
                                          () => _selectedFormat = newValue!,
                                        ),
                                  items: _formats.map<DropdownMenuItem<String>>(
                                    (String value) {
                                      return DropdownMenuItem<String>(
                                        value: value,
                                        child: Center(
                                          child: Text(
                                            value,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ).toList(),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 32,
                              color: Colors.grey.shade300,
                            ),

                            // Botón de Limpieza (Icono)
                            IconButton(
                              onPressed: _isDownloading ? null : _resetFields,
                              icon: const Icon(Icons.delete_sweep_rounded),
                              color: Colors.grey.shade700,
                              tooltip: 'Limpiar campos',
                            ),
                            const SizedBox(width: 4),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── 3. BOTÓN COMENZAR DESCARGA ──────────────────────────────────
                      ElevatedButton.icon(
                        onPressed: _isDownloading
                            ? null
                            : _startYouTubeDownload,
                        icon:
                            _isDownloading &&
                                !_statusMessage.startsWith('Convirtiendo')
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download),
                        label: Text(
                          _isDownloading &&
                                  !_statusMessage.startsWith('Convirtiendo')
                              ? 'Descargando...'
                              : 'Comenzar Descarga',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.red.shade200,
                          disabledForegroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),

                      // ── 4. PROGRESO (para descarga o conversión local) ─────────────────
                      if (_isDownloading || _statusMessage.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color:
                                _statusMessage.startsWith('Error') ||
                                    _statusMessage.startsWith('Permiso') ||
                                    _statusMessage.startsWith('Convirtiendo')
                                ? Colors.red.shade50
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color:
                                  _statusMessage.startsWith('Error') ||
                                      _statusMessage.startsWith('Permiso')
                                  ? Colors.red.shade200
                                  : Colors.grey.shade300,
                            ),
                          ),
                          child: Column(
                            children: [
                              if (_statusMessage.isNotEmpty)
                                Text(
                                  _statusMessage,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color:
                                        _statusMessage.startsWith('Error') ||
                                            _statusMessage.startsWith('Permiso')
                                        ? Colors.red.shade700
                                        : (_statusMessage.startsWith(
                                                'Convirtiendo',
                                              )
                                              ? Colors.deepPurple.shade700
                                              : Colors.black87),
                                  ),
                                ),
                              if (_isDownloading) ...[
                                const SizedBox(height: 12),
                                LinearProgressIndicator(
                                  value: _progress > 0 ? _progress : null,
                                  backgroundColor: Colors.grey.shade300,
                                  color:
                                      _statusMessage.startsWith('Convirtiendo')
                                      ? Colors.deepPurple
                                      : Colors.red,
                                  minHeight: 10,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],

                      // ── 5. TABLAS DE ARCHIVOS DESCARGADOS ──────────────────────────
                      _buildFilesTable(_mp4Files, 'MP4'),
                      _buildFilesTable(_mp3Files, 'MP3'),

                      const Spacer(),

                      // ── 6. FIRMA DEL DESARROLLADOR (Siempre abajo) ──────────────────
                      const SizedBox(height: 40),
                      Center(
                        child: Text(
                          'Made by Jorge Loor',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade500,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
