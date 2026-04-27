import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class MediaService {
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  bool _isRecording = false;

  /// Pick an image from gallery. Returns file path or null if cancelled.
  Future<String?> pickImage() async {
    final file = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    return file?.path;
  }

  /// Pick an image from camera. Returns file path or null if cancelled.
  Future<String?> capturePhoto() async {
    final file = await _picker.pickImage(source: ImageSource.camera, imageQuality: 70);
    return file?.path;
  }

  /// Start recording a voice message.
  Future<bool> startRecording() async {
    if (!await _recorder.hasPermission()) return false;
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/ahoy_voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    _isRecording = true;
    return true;
  }

  /// Stop recording and return the file path.
  Future<String?> stopRecording() async {
    if (!_isRecording) return null;
    _isRecording = false;
    return _recorder.stop();
  }

  bool get isRecording => _isRecording;

  Future<void> playAudio(String path) async {
    await _player.play(DeviceFileSource(path));
  }

  Future<void> stopAudio() async {
    await _player.stop();
  }

  Future<void> dispose() async {
    await _recorder.dispose();
    await _player.dispose();
  }
}
