import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:exif/exif.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

// Shared preferences keys (used in UI and background isolate)
const String prefsKeyDir = 'selected_directory';
const String prefsKeyAndroidTreeUri = 'android_tree_uri';
// Monitoring removed: no longer tracking monitoring flags

// Top-level helper to parse EXIF datetime string
DateTime? parseExifDate(String dateStr) {
  try {
    // Accept common EXIF formats like:
    // - YYYY:MM:DD HH:MM:SS
    // - YYYY:MM:DD HH:MM:SS.sss
    // - YYYY:MM:DD HH:MM:SS+TZ or HH:MM:SS-TZ
    final regex = RegExp(r'^(\d{4}):(\d{2}):(\d{2})\s+(\d{2}):(\d{2}):(\d{2})');
    final m = regex.firstMatch(dateStr);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = int.parse(m.group(4)!);
    final minute = int.parse(m.group(5)!);
    final second = int.parse(m.group(6)!);
    return DateTime(year, month, day, hour, minute, second);
  } catch (_) {
    return null;
  }
}

// Monitoring and background tasks removed; headless scan no longer used.

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  String? _androidTreeUri; // SAF tree URI for Android write access
  final List<String> _logs = [];
  bool _isProcessing = false;
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

  @override
  void initState() {
    super.initState();
    // Restore previously selected directory and monitoring flag.
    // Best-effort: ignore errors in test or unsupported environments.
    _restorePreferences();
  }

  Future<void> _restorePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = prefs.getString(prefsKeyDir);
      _androidTreeUri = prefs.getString(prefsKeyAndroidTreeUri);
      // Monitoring removed: nothing to restore beyond selected dir and SAF uri
      if (!mounted) return;
      if (dir != null) {
        final exists = await Directory(dir).exists();
        if (exists) {
          setState(() {
            _selectedDirectory = dir;
          });
          _addLog("フォルダを復元しました: $dir");
        } else {
          // Clear stale value
          await prefs.remove(prefsKeyDir);
        }
      }

      // No background tasks to manage

      // Background summary removed
    } catch (_) {
      // Ignore: e.g., MissingPluginException under tests.
    }
  }

  Future<void> _savePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_selectedDirectory != null) {
        await prefs.setString(prefsKeyDir, _selectedDirectory!);
      }
      if (_androidTreeUri != null) {
        await prefs.setString(prefsKeyAndroidTreeUri, _androidTreeUri!);
      }
    } catch (_) {
      // Ignore persistence failures silently.
    }
  }

  Future<bool> _hasStorageAccess() async {
    if (!Platform.isAndroid) return true;
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdk = androidInfo.version.sdkInt;
    if (sdk >= 33) {
      final status = await Permission.photos.status; // READ_MEDIA_IMAGES
      return status.isGranted;
    }
    final status = await Permission.storage.status;
    return status.isGranted;
  }

  Future<bool> _ensureStorageAccess() async {
    if (!Platform.isAndroid) return true;
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdk = androidInfo.version.sdkInt;

    // Android 13+ は READ_MEDIA_IMAGES をランタイムで要求
    if (sdk >= 33) {
      var status = await Permission.photos.status; // READ_MEDIA_IMAGES
      if (!status.isGranted) {
        final proceed = await _showPermissionRationaleDialog();
        if (!proceed) return false;
        status = await Permission.photos.request();
        if (!status.isGranted) {
          if (status.isPermanentlyDenied) {
            await _showOpenSettingsDialog();
          }
          return false;
        }
      }
      return true;
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
      _addLog("エラー: ストレージへのアクセスが拒否されました。");
      return;
    }
    if (Platform.isAndroid) {
      // Use SAF to grant persistent write access to the folder (no per-file prompts)
      try {
        const ch = MethodChannel('com.puclnu.photorename/media');
        final res = await ch.invokeMethod<dynamic>('pickTree');
        if (res is! Map) {
          _addLog("エラー: 不正な応答形式 (pickTree)");
          return;
        }
        final treeUri = res['treeUri'] as String?;
        final path = (res['path'] as String?) ?? _selectedDirectory; // best-effort abs path
        if (treeUri != null) {
          setState(() {
            _androidTreeUri = treeUri;
            _selectedDirectory = path;
            _logs.clear();
          });
          _addLog("フォルダ(SAF)を選択: ${path ?? '(unknown)'}");
          await _savePreferences();
          return;
        }
      } catch (e) {
        _addLog("エラー: SAF フォルダ選択に失敗しました: $e");
      }
    }

    // Fallback: platform directory picker (non-Android)
    final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      setState(() {
        _selectedDirectory = selectedDirectory;
        _logs.clear();
      });
      _addLog("選択したフォルダ: $selectedDirectory");
      await _savePreferences();
    }
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
          targetDate = parseExifDate(dateStr);
          if (targetDate != null) break;
        }
      }

      // 3. 異常値判定
      if (targetDate == null || targetDate.isAfter(DateTime.now())) {
        _addLog("スキップ: 有効なEXIF日時が見つかりません ($name)");
        if (mounted) {
          setState(() => _skippedCount++);
        }
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

      bool renamed = false;
      if (Platform.isAndroid) {
        try {
          const ch = MethodChannel('com.puclnu.photorename/media');
          if (_androidTreeUri != null && _selectedDirectory != null) {
            final rel = p.relative(file.path, from: _selectedDirectory!);
            final ok = await ch.invokeMethod<bool>('safRename', {
              'treeUri': _androidTreeUri,
              'relativePath': rel,
              'newName': newName,
            });
            if (ok == true) {
              renamed = true;
            }
          }
          if (!renamed) {
            // Fallback to MediaStore update request (may show one-time consent)
            final ok = await ch.invokeMethod<bool>('renameMedia', {
              'path': file.path,
              'newName': newName,
            });
            if (ok == true) {
              renamed = true;
            }
          }
        } catch (e) {
          _addLog("警告: MediaStore経由のリネームに失敗しました: $e");
        }
      }
      if (!renamed) {
        try {
          await file.rename(newPath);
          renamed = true;
        } on FileSystemException catch (e) {
          if (Platform.isAndroid) {
            try {
              final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
              if (sdk >= 33) {
                _addLog("警告: Android 13以降では共有ストレージ上の直接リネームは制限されています。MediaStore/SAF が必要です。");
              }
            } catch (_) {}
          }
          throw e;
        }
      }
      if (renamed) {
        _addLog("自動リネーム: $name -> $newName");
      }
      if (mounted) {
        setState(() => _processedCount++);
      }
    } catch (e) {
      _addLog("エラー: 処理中に問題が発生しました $name: $e");
    }
  }

  Future<void> _runManualRename() async {
    if (_selectedDirectory == null) return;
    if (!await _ensureStorageAccess()) {
      _addLog("エラー: 権限がないため手動スキャンを開始できません。");
      return;
    }
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
      _addLog("エラー: 手動実行中に問題が発生しました: $e");
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
      _addLog("手動スキャン完了: $_processedCount 件を処理しました。");
    }
  }

  // _parseExifDate is migrated to top-level helper `parseExifDate`

  @override
  void dispose() {
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
              // Folder selection
              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _pickDirectory,
                icon: const Icon(Icons.folder_open),
                label: const Text("Select Folder"),
              ),
              const SizedBox(height: 8),
              if (_selectedDirectory != null)
                Text("Path: $_selectedDirectory", style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 16),

              // Auto Monitoring UI removed (feature disabled)

              // Manual Rename section
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade300)),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.handyman, size: 18),
                          SizedBox(width: 6),
                          Text("Manual Rename", style: TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        "Run a one‑time scan and rename files in the selected folder.",
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _statusItem("Processed", _processedCount, Colors.green),
                          _statusItem("Skipped", _skippedCount, Colors.orange),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton.icon(
                        onPressed: (_isProcessing || _selectedDirectory == null) ? null : _runManualRename,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(_isProcessing ? "Processing..." : "Run Manual Rename Now"),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              const Text("ログ:", style: TextStyle(fontWeight: FontWeight.bold)),
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
