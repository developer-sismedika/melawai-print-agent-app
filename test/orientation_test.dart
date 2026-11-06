import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:melawai_print_agent_app/core/orientation.dart';
import 'package:melawai_print_agent_app/core/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('orientationsFor pins the axis per mode', () {
    expect(orientationsFor(OrientationMode.auto), hasLength(4));
    expect(
      orientationsFor(OrientationMode.portrait),
      const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
    );
    expect(
      orientationsFor(OrientationMode.landscape),
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
    // Pinned modes must NOT include the other axis — that is what
    // overrides the system auto-rotate lock.
    expect(orientationsFor(OrientationMode.portrait),
        isNot(contains(DeviceOrientation.landscapeLeft)));
    expect(orientationsFor(OrientationMode.landscape),
        isNot(contains(DeviceOrientation.portraitUp)));
  });

  test('orientationModeFromName is forgiving', () {
    expect(orientationModeFromName('landscape'), OrientationMode.landscape);
    expect(orientationModeFromName('portrait'), OrientationMode.portrait);
    expect(orientationModeFromName('auto'), OrientationMode.auto);
    expect(orientationModeFromName(''), OrientationMode.auto);
    expect(orientationModeFromName('garbage'), OrientationMode.auto);
  });

  test('orientation persists across reload', () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = InMemorySecretStore();
    final store = await SettingsStore.load(
      prefs: await SharedPreferences.getInstance(),
      secrets: secrets,
    );
    expect(store.orientation, 'auto');
    expect(store.orientationMode, OrientationMode.auto);

    await store.setOrientation('landscape');
    expect(store.orientation, 'landscape');

    // Fresh load reads it back from prefs.
    SharedPreferences.setMockInitialValues(
        {SettingsStore.kOrientation: 'landscape'});
    final reloaded = await SettingsStore.load(
      prefs: await SharedPreferences.getInstance(),
      secrets: secrets,
    );
    expect(reloaded.orientation, 'landscape');
    expect(reloaded.orientationMode, OrientationMode.landscape);
  });
}
