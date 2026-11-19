import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class OfflineService {
  OfflineService._();
  static final OfflineService instance = OfflineService._();

  Future<Directory> _getOfflineDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docsDir.path, 'offline_masteran'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _filePathForVideo(String videoId) async {
    final dir = await _getOfflineDir();
    final safeId = videoId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return p.join(dir.path, '$safeId.mp4');
  }

  Future<String?> getExistingLocalPath(String videoId) async {
    if (videoId.trim().isEmpty) return null;
    final targetPath = await _filePathForVideo(videoId);
    final file = File(targetPath);
    if (await file.exists()) {
      final length = await file.length();
      if (length > 1024) {
        return targetPath;
      }
    }
    return null;
  }

  Future<int> getFileSizeBytes(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return 0;
    return file.length();
  }

  String formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb < 1) {
      final kb = (bytes / 1024).round();
      return '$kb KB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  Future<String> downloadYoutubeVideo(
    String videoId, {
    void Function(double progress)? onProgress,
  }) async {
    final yt = YoutubeExplode();
    final targetPath = await _filePathForVideo(videoId);
    final tempPath = '$targetPath.tmp';
    final tempFile = File(tempPath);

    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final muxedList = manifest.muxed.toList();
      if (muxedList.isEmpty) {
        throw Exception('Stream video YouTube tidak tersedia untuk diunduh.');
      }

      // Pilih kualitas MP4 muxed terkecil yang stabil agar hemat kuota & cepat
      muxedList.sort((a, b) => a.size.totalBytes.compareTo(b.size.totalBytes));
      final chosenStream = muxedList.first;
      final totalBytes = chosenStream.size.totalBytes;

      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      final sink = tempFile.openWrite();
      int downloaded = 0;

      try {
        final stream = yt.videos.streamsClient.get(chosenStream);
        await for (final chunk in stream) {
          sink.add(chunk);
          downloaded += chunk.length;
          if (totalBytes > 0 && onProgress != null) {
            onProgress((downloaded / totalBytes).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      final destFile = File(targetPath);
      if (await destFile.exists()) {
        await destFile.delete();
      }
      await tempFile.rename(targetPath);
      onProgress?.call(1.0);
      return targetPath;
    } catch (e) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    } finally {
      yt.close();
    }
  }

  Future<void> deleteOfflineVideo(String videoId) async {
    final targetPath = await _filePathForVideo(videoId);
    final file = File(targetPath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
