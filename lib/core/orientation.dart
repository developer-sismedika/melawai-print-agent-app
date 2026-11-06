import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Screen-orientation preference (Settings screen + kiosk escape menu).
/// Persisted as the enum name: 'auto' | 'portrait' | 'landscape'.
enum OrientationMode { auto, portrait, landscape }

/// Unknown or legacy stored values fall back to [OrientationMode.auto],
/// so a corrupt pref can never brick rotation on a kiosk tablet.
OrientationMode orientationModeFromName(String name) {
  for (final m in OrientationMode.values) {
    if (m.name == name) return m;
  }
  return OrientationMode.auto;
}

/// The exact `SystemChrome.setPreferredOrientations` payload for a mode.
///
/// `portrait`/`landscape` PIN the axis, which overrides a system-wide
/// auto-rotate lock — that is the point: a kiosk mounted in one
/// orientation must not depend on the tablet's quick-settings toggle.
/// `auto` hands control back to the sensor in all four orientations.
List<DeviceOrientation> orientationsFor(OrientationMode mode) =>
    switch (mode) {
      OrientationMode.auto => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      OrientationMode.portrait => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
      OrientationMode.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
    };

/// Apply [mode] now. Safe to call on every change: repeated identical
/// calls are a no-op at the platform level.
Future<void> applyOrientation(OrientationMode mode) =>
    SystemChrome.setPreferredOrientations(orientationsFor(mode));

/// Apply [mode] and then verify the display actually followed.
///
/// On some Samsung/One UI tablets the system Auto rotate service keeps
/// deciding orientation while it is ON and ignores app pins (seen on
/// SM-X110: `requestedOrientation=USER_PORTRAIT` while the display stayed
/// at `ROTATION_90`). Waiting [settle] and re-reading MediaQuery turns
/// that silent failure into an actionable hint for the caller.
/// [OrientationMode.auto] is not verifiable (nothing is pinned) and
/// returns true immediately.
Future<bool> applyOrientationVerified(
  OrientationMode mode,
  BuildContext context, {
  Duration settle = const Duration(milliseconds: 1500),
}) async {
  await applyOrientation(mode);
  if (mode == OrientationMode.auto) return true;
  await Future<void>.delayed(settle);
  if (!context.mounted) return true;
  final actual = MediaQuery.orientationOf(context);
  final wanted = mode == OrientationMode.landscape
      ? Orientation.landscape
      : Orientation.portrait;
  return actual == wanted;
}
