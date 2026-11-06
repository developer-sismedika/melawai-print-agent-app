import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'orientation.dart';

/// Agent connection configuration, snapshotted per call so validation
/// (Settings save flow) can run against candidate values before persisting.
class AgentConfig {
  const AgentConfig({this.baseUrl = '', this.token = ''});

  final String baseUrl;
  final String token;

  bool get hasBaseUrl => baseUrl.isNotEmpty;
  bool get isConfigured => hasBaseUrl && token.isNotEmpty;

  String get normalizedBaseUrl =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  @override
  String toString() => 'AgentConfig(baseUrl: $baseUrl, token: ***)';
}

/// Secret storage abstraction so unit tests never touch platform channels.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production store backed by Keychain (iOS) / Keystore (Android).
class SecureSecretStore implements SecretStore {
  const SecureSecretStore();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Test double.
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);

  bool containsKey(String key) => _data.containsKey(key);
}

/// Non-secret settings (SharedPreferences) + token (SecretStore).
/// Persistence order follows the architecture doc: non-secrets first,
/// token last — a save that dies half-way never leaves a token behind
/// an unvalidated URL.
class SettingsStore extends ChangeNotifier {
  SettingsStore({required this.prefs, required this.secrets});

  static const kBaseUrl = 'agentBaseUrl';
  static const kToken = 'bearerToken';
  static const kDefaultPrinter = 'defaultPrinterId';
  static const kApemUrl = 'apemUrl';
  static const kOrientation = 'orientation';
  static const kAutoPrintPdf = 'autoPrintPdf';

  final SharedPreferences prefs;
  final SecretStore secrets;

  String agentBaseUrl = '';
  String bearerToken = '';
  String defaultPrinterId = '';
  String apemUrl = '';
  String orientation = 'auto';

  /// Kiosk always-sends-to-printer for PDFs (D13). Default on.
  bool autoPrintPdf = true;

  static Future<SettingsStore> load({
    SharedPreferences? prefs,
    SecretStore? secrets,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final s = secrets ?? const SecureSecretStore();
    final store = SettingsStore(prefs: p, secrets: s)
      ..agentBaseUrl = p.getString(kBaseUrl) ?? ''
      ..bearerToken = await s.read(kToken) ?? ''
      ..defaultPrinterId = p.getString(kDefaultPrinter) ?? ''
      ..apemUrl = p.getString(kApemUrl) ?? ''
      ..orientation = p.getString(kOrientation) ?? 'auto'
      ..autoPrintPdf = p.getBool(kAutoPrintPdf) ?? true;
    return store;
  }

  AgentConfig get config =>
      AgentConfig(baseUrl: agentBaseUrl, token: bearerToken);

  bool get isConfigured => config.isConfigured;

  OrientationMode get orientationMode =>
      orientationModeFromName(orientation);

  /// Orientation is independent of the Validate & Save flow so it can be
  /// changed (and applied) even while the agent is unconfigured.
  Future<void> setOrientation(String mode) async {
    await prefs.setString(kOrientation, mode);
    orientation = mode;
    notifyListeners();
  }

  /// Like [setOrientation]: immediate, independent of Validate & Save.
  Future<void> setAutoPrintPdf(bool enabled) async {
    await prefs.setBool(kAutoPrintPdf, enabled);
    autoPrintPdf = enabled;
    notifyListeners();
  }

  Future<void> save({
    required String baseUrl,
    required String token,
    String? defaultPrinterId,
    String? apemUrl,
  }) async {
    await prefs.setString(kBaseUrl, baseUrl);
    if (defaultPrinterId != null) {
      await prefs.setString(kDefaultPrinter, defaultPrinterId);
    }
    if (apemUrl != null) {
      await prefs.setString(kApemUrl, apemUrl);
    }
    await secrets.write(kToken, token);
    agentBaseUrl = baseUrl;
    bearerToken = token;
    if (defaultPrinterId != null) this.defaultPrinterId = defaultPrinterId;
    if (apemUrl != null) this.apemUrl = apemUrl;
    notifyListeners();
  }

  Future<void> setDefaultPrinter(String id) async {
    await prefs.setString(kDefaultPrinter, id);
    defaultPrinterId = id;
    notifyListeners();
  }
}
