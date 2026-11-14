import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API-ключи — только в защищённом хранилище ОС (Android Keystore,
/// Windows DPAPI). Ключ не логируется и не попадает в тексты ошибок.
abstract interface class KeyStore {
  Future<String?> read(String providerId);
  Future<void> write(String providerId, String key);
  Future<void> delete(String providerId);
}

class SecureKeyStore implements KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String _name(String providerId) => 'api_key.$providerId';

  @override
  Future<String?> read(String providerId) async {
    try {
      return await _storage.read(key: _name(providerId));
    } catch (_) {
      // Повреждённое хранилище — считаем, что ключа нет. Текст исключения
      // не показываем и не логируем.
      return null;
    }
  }

  @override
  Future<void> write(String providerId, String key) =>
      _storage.write(key: _name(providerId), value: key);

  @override
  Future<void> delete(String providerId) =>
      _storage.delete(key: _name(providerId));
}

/// Для тестов.
class MemoryKeyStore implements KeyStore {
  final _keys = <String, String>{};

  @override
  Future<String?> read(String providerId) async => _keys[providerId];

  @override
  Future<void> write(String providerId, String key) async =>
      _keys[providerId] = key;

  @override
  Future<void> delete(String providerId) async => _keys.remove(providerId);
}
