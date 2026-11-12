import 'dart:async';
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../crypto/local_data_crypto.dart';
import '../../core/logging.dart';

class MediaService {
  /// Required since the ninth review: playback of owned media goes through
  /// the at-rest crypto; a nullable instance would silently reintroduce a
  /// plaintext path (spec §10).
  final LocalDataCrypto _localDataCrypto;
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _completionSub;
  File? _tempAudioFile;

  bool _isRecording = false;

  MediaService(this._localDataCrypto) {
    _completionSub = _player.onPlayerComplete.listen((_) {
      unawaited(_deleteTempAudio());
    });
  }

  /// Pick an image from gallery. Returns file path or null if cancelled.
  Future<String?> pickImage() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );
    return file?.path;
  }

  /// Pick an image from camera. Returns file path or null if cancelled.
  Future<String?> capturePhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 70,
    );
    return file?.path;
  }

  /// Start recording a voice message.
  Future<bool> startRecording() async {
    if (!await _recorder.hasPermission()) return false;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/ahoy_voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    _isRecording = true;
    return true;
  }

  /// Stop recording and return the file path.
  Future<String?> stopRecording() async {
    if (!_isRecording) return null;
    _isRecording = false;
    return _recorder.stop();
  }

  /// Stops an in-progress recording and discards the temp file: a cancelled
  /// voice message must leave nothing behind (UI review #14).
  Future<void> cancelRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Playback position of the current audio, for the voice-bubble progress
  /// bar (UI review #14).
  Stream<Duration> get onPositionChanged => _player.onPositionChanged;

  /// Total duration of the current audio, once known.
  Stream<Duration?> get onDurationChanged => _player.onDurationChanged;

  /// Fires when the current audio finishes playing.
  Stream<void> get onPlaybackComplete => _player.onPlayerComplete;

  bool get isRecording => _isRecording;

  Future<void> playAudio(String path) async {
    await _player.stop();
    await _deleteTempAudio();

    if (!_localDataCrypto.isEncryptedFilePath(path)) {
      // Legacy plaintext path from before at-rest encryption (audit L-10).
      await _player.play(DeviceFileSource(path));
      return;
    }

    final bytes = await _localDataCrypto.readEncryptedFile(File(path));
    if (bytes.isEmpty) {
      // A quarantined or empty media file has nothing to play (sixth
      // review, finding 8).
      ahoyLog('[MediaService] nothing to play for $path');
      return;
    }
    final dir = await getTemporaryDirectory();
    final temp = File(
      '${dir.path}/ahoy_audio_${DateTime.now().microsecondsSinceEpoch}.aac',
    );
    await temp.writeAsBytes(bytes, flush: true);
    _tempAudioFile = temp;
    try {
      await _player.play(DeviceFileSource(temp.path));
    } catch (_) {
      await _deleteTempAudio();
      rethrow;
    }
  }

  Future<void> stopAudio() async {
    await _player.stop();
    await _deleteTempAudio();
  }

  Future<void> dispose() async {
    await _completionSub?.cancel();
    await _player.stop();
    await _deleteTempAudio();
    await _recorder.dispose();
    await _player.dispose();
  }

  Future<void> _deleteTempAudio() async {
    final file = _tempAudioFile;
    _tempAudioFile = null;
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }
}
