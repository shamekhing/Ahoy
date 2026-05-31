import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/enums.dart';
import '../../models/message.dart';
import '../chat/conversation_store.dart';
import '../chat/message_store.dart';
import '../crypto/local_data_crypto.dart';
import '../profile/profile_service.dart';

class LocalDataMigrator {
  final ProfileService _profileService;
  final ConversationStore _conversationStore;
  final MessageStore _messageStore;
  final LocalDataCrypto _localDataCrypto;
  final Future<Directory> Function() _documentsDirectoryProvider;

  LocalDataMigrator(
    this._profileService,
    this._conversationStore,
    this._messageStore,
    this._localDataCrypto, [
    Future<Directory> Function()? documentsDirectoryProvider,
  ]) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  Future<void> migrate() async {
    await _profileService.migrateLegacyProfile();

    if (_conversationStore.needsLegacyPlaintextMigration) {
      await _conversationStore.rewriteAll();
    }

    for (final conversationId in _messageStore.conversationIds) {
      await _migrateMessages(conversationId);
    }
  }

  Future<void> _migrateMessages(String conversationId) async {
    final messages = _messageStore.loadMessages(conversationId);
    var changed = _messageStore.needsLegacyPlaintextMigration(conversationId);

    final updated = <Message>[];
    for (final message in messages) {
      final migratedContent = await _migrateMediaContent(message);
      if (migratedContent != message.content) changed = true;
      updated.add(message.copyWith(content: migratedContent));
    }

    if (changed) {
      await _messageStore.replaceMessages(conversationId, updated);
    }
  }

  Future<String> _migrateMediaContent(Message message) async {
    if (message.type == MessageType.text ||
        message.content.isEmpty ||
        _localDataCrypto.isEncryptedFilePath(message.content)) {
      return message.content;
    }

    final source = File(message.content);
    if (!await source.exists()) return message.content;

    try {
      final appDir = await _documentsDirectoryProvider();
      final ext = message.type == MessageType.image ? 'jpg' : 'aac';
      final destPath =
          '${appDir.path}/ahoy_media_${message.id}.$ext${LocalDataCrypto.encryptedFileExtension}';
      await _localDataCrypto.writeEncryptedFile(
        File(destPath),
        await source.readAsBytes(),
      );

      if (destPath != message.content && _isOwnedMediaPath(source)) {
        try {
          await source.delete();
        } catch (_) {}
      }

      return destPath;
    } catch (_) {
      return message.content;
    }
  }

  bool _isOwnedMediaPath(File file) {
    final name = file.uri.pathSegments.isEmpty
        ? ''
        : file.uri.pathSegments.last;
    return name.startsWith('ahoy_media_') || name.startsWith('ahoy_voice_');
  }
}
