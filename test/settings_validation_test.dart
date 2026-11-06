import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:melawai_print_agent_app/agent/agent_client.dart';
import 'package:melawai_print_agent_app/core/settings.dart';
import 'package:melawai_print_agent_app/core/settings_validation.dart';

Future<SettingsStore> loadTestSettings({
  Map<String, Object> initialValues = const {},
  SecretStore? secrets,
}) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  // Never default to SecureSecretStore here: the Keychain/Keystore
  // platform channel does not exist in tests.
  return SettingsStore.load(prefs: prefs, secrets: secrets ?? InMemorySecretStore());
}

MockClient _healthyCatalogue() => MockClient((r) async {
      if (r.url.path == '/health') {
        return http.Response('{"status":"ok"}', 200);
      }
      if (r.url.path == '/agent-info') {
        return http.Response(
          jsonEncode({
            'printers': [
              {'id': 'mock-receipt', 'formats': ['text/plain'], 'paper': 'continuous'},
              {'id': 'pdf-printer', 'formats': ['application/pdf'], 'paper': 'A4'},
            ],
          }),
          200,
        );
      }
      return http.Response('{"error":{"code":"not_found","message":"x"}}', 404);
    });

AgentClient _client(MockClient mc) => AgentClient(
      resolveConfig: () => const AgentConfig(),
      httpClient: mc,
      timeout: const Duration(milliseconds: 400),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('V1 valid URL -> health -> catalogue -> token persisted last', () async {
    final secrets = InMemorySecretStore();
    final store = await loadTestSettings(secrets: secrets);
    final outcome = await SettingsValidation.validateAndSave(
      settings: store,
      client: _client(_healthyCatalogue()),
      baseUrl: 'http://192.168.1.10:9876/',
      token: ' secret-token ',
    );
    expect(outcome.ok, isTrue);
    expect(outcome.printers, hasLength(2));

    // normalized (no trailing slash), token trimmed, default picked
    expect(store.agentBaseUrl, 'http://192.168.1.10:9876');
    expect(store.bearerToken, 'secret-token');
    expect(store.defaultPrinterId, 'mock-receipt'); // first catalogue entry
    expect(store.isConfigured, isTrue);

    // survives a reload (same secret store, fresh prefs object)
    final reloaded = await loadTestSettings(secrets: secrets);
    expect(reloaded.bearerToken, 'secret-token');
  });

  test('V2 agent down -> failure, token NOT persisted', () async {
    final secrets = InMemorySecretStore();
    final store = await loadTestSettings(secrets: secrets);
    final down = MockClient((r) async {
      throw http.ClientException('connection refused');
    });
    final outcome = await SettingsValidation.validateAndSave(
      settings: store,
      client: _client(down),
      baseUrl: 'http://192.168.1.10:9876',
      token: 'secret-token',
    );
    expect(outcome.ok, isFalse);
    expect(outcome.message, contains('unreachable'));
    expect(secrets.containsKey(SettingsStore.kToken), isFalse);
    expect(store.isConfigured, isFalse);
  });

  test('V5 empty agent URL -> saved without HTTP (agent optional)',
      () async {
    final secrets = InMemorySecretStore();
    final store = await loadTestSettings(secrets: secrets);
    var called = false;
    final spy = MockClient((r) async {
      called = true;
      return http.Response('{}', 200);
    });
    final outcome = await SettingsValidation.validateAndSave(
      settings: store,
      client: _client(spy),
      baseUrl: '',
      token: '',
      apemUrl: 'http://192.168.1.40:3004/',
    );
    expect(outcome.ok, isTrue);
    expect(outcome.message, contains('agent not configured'));
    expect(called, isFalse); // no network validation when URL is empty
    expect(store.isConfigured, isFalse);
    // The APEM URL still persists — the kiosk works without an agent.
    expect(store.apemUrl, 'http://192.168.1.40:3004/');
  });

  test('V4 malformed URL rejected before any HTTP', () async {
    final secrets = InMemorySecretStore();
    final store = await loadTestSettings(secrets: secrets);
    var called = false;
    final spy = MockClient((r) async {
      called = true;
      return http.Response('{}', 200);
    });
    final outcome = await SettingsValidation.validateAndSave(
      settings: store,
      client: _client(spy),
      baseUrl: 'not a url',
      token: 'secret-token',
    );
    expect(outcome.ok, isFalse);
    expect(outcome.message, contains('Invalid agent URL'));
    expect(called, isFalse);
    expect(secrets.containsKey(SettingsStore.kToken), isFalse);
  });

  test('catalogue failure blocks persistence even when health passes', () async {
    final secrets = InMemorySecretStore();
    final store = await loadTestSettings(secrets: secrets);
    final partial = MockClient((r) async {
      if (r.url.path == '/health') {
        return http.Response('{"status":"ok"}', 200);
      }
      throw http.ClientException('reset');
    });
    final outcome = await SettingsValidation.validateAndSave(
      settings: store,
      client: _client(partial),
      baseUrl: 'http://192.168.1.10:9876',
      token: 'secret-token',
    );
    expect(outcome.ok, isFalse);
    expect(secrets.containsKey(SettingsStore.kToken), isFalse);
  });
}
