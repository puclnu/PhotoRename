import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:exif/exif.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:watcher/watcher.dart';

void main() {
  runApp(const PhotoRenamerApp());
}

class PhotoRenamerApp extends StatelessWidget {
  const PhotoRenamerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhotoRename',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
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

class _MainScreenState extends State<MainScreen> {
  String? _selectedDirectory;
  final List<String> _logs = [];
  bool _isProcessing = false;
  bool _isMonitoring = false;
  StreamSubscription<WatchEvent>? _watcherSubscription;
  int _processedCount = 0;
  int _skippedCount = 0;

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, "${DateFormat('HH:mm:ss').format(DateTime.now())}: $message");
    });
  }

  Future<bool> _showPermissionRationaleDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('写真へのアクセス許可が必要です'),
            content: const Text(
                'PhotoRename は、写真を選択して EXIF 情報を読み取り、ファイル名を変更・保存するために「写真と動画」へのアクセス権限が必要です。処理は端末内のみで行われ、外部へ送信されません。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('続行'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _showOpenSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('権限が無効になっています'),
        content: const Text('設定で PhotoRename のストレージ権限を許可してください。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await openAppSettings();
            },
            child: const Text('設定を開く'),
          ),
        ],
      ),
    );
  }

  Future<bool> _ensureStorageAccess() async {
    if (!Platform.isAndroid) return true;
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdk = androidInfo.version.sdkInt;

    // Android 13+ は READ_MEDIA_IMAGES（ユーザーに機能説明のみ実施）
    if (sdk >= 33) {
      final proceed = await _showPermissionRationaleDialog();
      if (!proceed) return false;
      return true; // ランタイム権限は不要（または個別メディア権限。Manifest に準拠）
    }

    // Android 12L/12 以下はストレージ権限を要求
    var status = await Permission.storage.status;
    if (status.isGranted) return true;

    final proceed = await _showPermissionRationaleDialog();
    if (!proceed) return false;

    status = await Permission.storage.request();
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      await _showOpenSettingsDialog();
    }
    return false;
  }

  Future<void> _pickDirectory() async {
    if (!await _ensureStorageAccess()) {
      _addLog("Error: Storage permission denied.");
      return;
    }

    final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      if (_isMonitoring) _stopMonitoring();
      setState(() {
        _selectedDirectory = selectedDirectory;
        _logs.clear();
        _addLog("Selected directory: $selectedDirectory");
      });
    }
  }

  void _toggleMonitoring(bool value) {
    if (_selectedDirectory == null) {
      _addLog("Error: Select a folder first.");
      return;
    }
    if (value) {
      // Ensure permission again when enabling monitoring
      _ensureStorageAccess().then((ok) {
        if (!ok) return;
        if (!mounted) return;
        setState(() {
          _isMonitoring = true;
        });
        _startMonitoring();
      });
      return;
    }
    setState(() {
      _isMonitoring = value;
    });
    if (_isMonitoring) {
      _startMonitoring();
    } else {
      _stopMonitoring();
    }
  }

  void _startMonitoring() {
    if (_selectedDirectory == null) return;
    _addLog("Auto-monitoring started for: $_selectedDirectory");
    
    final watcher = DirectoryWatcher(_selectedDirectory!);
    _watcherSubscription = watcher.events.listen((event) {
      if (event.type == ChangeType.ADD) {
        _addLog("New file detected: ${p.basename(event.path)}");
        // Give the OS a moment to finish writing the file
        Future.delayed(const Duration(seconds: 1), () => _renameFile(File(event.path)));
      }
    });
  }

  void _stopMonitoring() {
    _watcherSubscription?.cancel();
    _watcherSubscription = null;
    _addLog("Auto-monitoring stopped.");
  }

  Future<void> _renameFile(File file) async {
    final name = p.basename(file.path);
    final ext = p.extension(name).toLowerCase();

    // 1. 対象拡張子チェック
    if (ext != '.jpg' && ext != '.jpeg' && ext != '.heic') return;

    // 5. スキップ条件: 既に目的形式の名前かチェック
    final nameWithoutExt = p.basenameWithoutExtension(name);
    final namePattern = RegExp(r'^\d{6}_\d{6}(_\d{2})?$');
    if (namePattern.hasMatch(nameWithoutExt)) return;

    try {
      // EXIFデータの読み込み
      final bytes = await file.readAsBytes();
      final exifData = await readExifFromBytes(bytes);
      
      // 2. 日時採用ルール
      DateTime? targetDate;
      final tags = ['EXIF DateTimeDigitized', 'EXIF DateTimeOriginal', 'Image DateTime'];

      for (final tag in tags) {
        if (exifData.containsKey(tag)) {
          final dateStr = exifData[tag]!.printable;
          targetDate = _parseExifDate(dateStr);
          if (targetDate != null) break;
        }
      }

      // 3. 異常値判定
      if (targetDate == null || targetDate.isAfter(DateTime.now())) {
        _addLog("Skip: No valid EXIF date ($name)");
        setState(() => _skippedCount++);
        return;
      }

      // 4. リネーム仕様
      String newBaseName = DateFormat('yyMMdd_HHmmss').format(targetDate);
      String newName = "$newBaseName$ext";
      String newPath = p.join(_selectedDirectory!, newName);

      // 同秒衝突チェック
      int counter = 1;
      while (await File(newPath).exists()) {
        if (p.basename(newPath) == name) return; // Prevent infinite loop if already renamed
        newName = "${newBaseName}_${counter.toString().padLeft(2, '0')}$ext";
        newPath = p.join(_selectedDirectory!, newName);
        counter++;
      }

      await file.rename(newPath);
      _addLog("Auto-Rename: $name -> $newName");
      setState(() => _processedCount++);
    } catch (e) {
      _addLog("Error processing $name: $e");
    }
  }

  Future<void> _runManualRename() async {
    if (_selectedDirectory == null) return;
    setState(() {
      _isProcessing = true;
      _processedCount = 0;
      _skippedCount = 0;
    });

    try {
      final dir = Directory(_selectedDirectory!);
      final List<FileSystemEntity> entities = await dir.list().toList();
      for (var entity in entities) {
        if (entity is File) await _renameFile(entity);
      }
    } catch (e) {
      _addLog("Error during manual run: $e");
    } finally {
      setState(() => _isProcessing = false);
      _addLog("Manual finish: $_processedCount processed.");
    }
  }

  DateTime? _parseExifDate(String dateStr) {
    try {
      final parts = dateStr.split(' ');
      if (parts.length != 2) return null;
      final dateParts = parts[0].split(':');
      final timeParts = parts[1].split(':');
      return DateTime(
        int.parse(dateParts[0]), int.parse(dateParts[1]), int.parse(dateParts[2]),
        int.parse(timeParts[0]), int.parse(timeParts[1]), int.parse(timeParts[2]),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _watcherSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("PhotoRename"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _pickDirectory,
                icon: const Icon(Icons.folder),
                label: const Text("Select Folder"),
              ),
              const SizedBox(height: 8),
              if (_selectedDirectory != null)
                Text("Path: $_selectedDirectory", style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text("Auto Monitoring", style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text("Automatically rename new photos in this folder"),
                value: _isMonitoring,
                onChanged: _toggleMonitoring,
                secondary: Icon(Icons.auto_mode, color: _isMonitoring ? Colors.blue : Colors.grey),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: (_isProcessing || _selectedDirectory == null) ? null : _runManualRename,
                icon: const Icon(Icons.play_arrow),
                label: Text(_isProcessing ? "Processing..." : "Run Manual Scan"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade50),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _statusItem("Processed", _processedCount, Colors.green),
                  _statusItem("Skipped", _skippedCount, Colors.orange),
                ],
              ),
              const SizedBox(height: 16),
              const Text("Logs:", style: TextStyle(fontWeight: FontWeight.bold)),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (context, index) => Text(_logs[index], style: const TextStyle(fontFamily: 'monospace', fontSize: 10)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        Text(count.toString(), style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}
