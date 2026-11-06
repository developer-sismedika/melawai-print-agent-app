import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../agent/agent_client.dart';
import '../../core/orientation.dart';
import '../../core/settings.dart';
import '../../core/uuid.dart';
import '../../jobs/job_service.dart';
import 'bridge_handler.dart';
import 'bridge_shim.dart';
import 'navigation_policy.dart';
import 'pdf_policy.dart';
import 'triple_tap.dart';

/// Kiosk shell (D2/D11): full-screen WebView of the configured APEM
/// origin with the bridge injected at document start.
///
/// Kiosk properties enforced in-app:
///  - navigation allowlist: only the configured APEM origin loads;
///    http(s) links to other origins and non-http schemes are cancelled
///  - no chrome (no address bar, no app bar)
///  - D11: render-process death auto-reloads with a visible banner
///  - D11: triple-tap the top-left corner *below the status bar* (buzz
///    per tap, strong buzz on the third) to open the escape sheet
///    (Home / Settings / Support / Reload / Rotate / Clear cache) — the
///    operator's way out when the page is wedged or Guided
///    Access/lock task is on, plus one-tap rotation and cache clearing
class WebViewShell extends StatefulWidget {
  const WebViewShell({super.key});

  @override
  State<WebViewShell> createState() => _WebViewShellState();
}

class _WebViewShellState extends State<WebViewShell> {
  InAppWebViewController? _controller;
  double _progress = 0;
  final TripleTapCounter _cornerTaps = TripleTapCounter();
  int _blockedNotifications = 0;
  int _downloadIgnoredNotifications = 0;

  // D13 PDF auto-print: page fetch results arrive via the
  // pdfFetchResult JS handler (portable — no promise-awaiting
  // evaluateJavascript) and complete the waiting Dart future.
  final Map<String, Completer<Map<String, dynamic>>> _pdfFetches = {};
  final Set<String> _pdfCaptureInFlight = {};

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.orange : null,
      ));
  }

  Future<dynamic> _onBridgeCall(List<dynamic> args) async {
    final jobs = context.read<JobService>();
    final client = context.read<AgentClient>();
    final settings = context.read<SettingsStore>();
    final handler =
        BridgeHandler(jobs: jobs, client: client, settings: settings);
    final raw = args.isNotEmpty ? args.first : '';
    final response = await handler.handle(raw is String ? raw : '');
    // Surface outcomes natively: every bridge error becomes a snackbar
    // (E_* must never vanish into the page), and auto-printed PDFs
    // (documentId `pdf-…`) also confirm on success so the operator
    // knows the receipt went out.
    try {
      final req = jsonDecode(raw is String ? raw : '') as Map<String, dynamic>;
      final env = jsonDecode(response) as Map<String, dynamic>;
      final payload = req['payload'];
      final docId = payload is Map ? payload['documentId'] : null;
      if (env['ok'] == true) {
        if (docId is String && docId.startsWith('pdf-')) {
          _toast('PDF sent to printer.');
        }
      } else {
        final e = env['error'];
        _toast(
            '${e is Map ? e['code'] : 'ERROR'}: '
            '${e is Map ? e['message'] : response}',
            error: true);
      }
    } catch (_) {
      // Reporting must never break the bridge response.
    }
    return response;
  }

  /// JS handler: completes the Dart future waiting on [fetchId]. For
  /// shim-initiated fetches (no future) errors still surface as a
  /// toast — except a clean `not a PDF` magic-byte miss on an
  /// optimistic `blob:` capture, which is silently ignored.
  Future<dynamic> _onPdfFetchResult(List<dynamic> args) async {
    final raw = args.isNotEmpty ? args.first : '';
    if (raw is! String || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final fetchId = m['fetchId'] as String? ?? '';
      final completer = _pdfFetches[fetchId];
      if (completer != null && !completer.isCompleted) {
        completer.complete(m);
      } else {
        final error = m['error'];
        if (error is String && error.isNotEmpty && error != 'not a PDF') {
          _toast('PDF: $error', error: true);
        }
      }
    } catch (_) {
      // Malformed report — ignore.
    }
    return null;
  }

  /// D13: capture a PDF navigation/download before the allowlist —
  /// the page fetch runs in the WebView (session cookies included),
  /// then the result goes through the regular bridge print path.
  bool _isCaptureTarget(Uri uri) =>
      isPdfRequest(uri) || uri.isScheme('blob');

  Future<void> _capturePdf(Uri uri, {String? title}) async {
    if (!mounted) return;
    final url = uri.toString();
    if (!_pdfCaptureInFlight.add(url)) {
      _toast('Already sending this PDF…');
      return;
    }
    final fetchId = 'dart-${DateTime.now().microsecondsSinceEpoch}';
    try {
      _toast('Reading PDF…');
      final completer = Completer<Map<String, dynamic>>();
      _pdfFetches[fetchId] = completer;
      await _controller?.evaluateJavascript(
          source: 'window.__mpaFetchPdf && '
              '__mpaFetchPdf(${jsonEncode(url)}, ${jsonEncode(fetchId)})');
      final res = await completer.future.timeout(const Duration(seconds: 30));
      final err = res['error'];
      if (err is String && err.isNotEmpty) {
        if (err == 'not a PDF') return; // blob magic-byte miss: stay silent
        _toast('PDF: $err', error: true);
        return;
      }
      if (!mounted) return;
      final built = buildPdfPrintPayload(
        documentId: 'pdf-${newUuidV4()}',
        uri: uri,
        title: title ?? pdfTitleFrom(uri),
        base64: res['b64'] as String?,
        tooLarge: res['tooLarge'] == true,
      );
      final payload = built.payload;
      if (payload == null) {
        _toast(built.error ?? 'PDF capture failed.', error: true);
        return;
      }
      final handler = BridgeHandler(
        jobs: context.read<JobService>(),
        client: context.read<AgentClient>(),
        settings: context.read<SettingsStore>(),
      );
      final raw =
          await handler.handle(jsonEncode({'v': 1, 'action': 'print', 'payload': payload}));
      final env = jsonDecode(raw) as Map<String, dynamic>;
      if (env['ok'] == true) {
        _toast('PDF sent to printer.');
      } else {
        final e = env['error'];
        _toast(
            '${e is Map ? e['code'] : 'ERROR'}: '
            '${e is Map ? e['message'] : raw}',
            error: true);
      }
    } catch (e) {
      _toast(e is TimeoutException
          ? 'PDF fetch timed out.'
          : 'PDF print failed: $e', error: true);
    } finally {
      _pdfFetches.remove(fetchId);
      _pdfCaptureInFlight.remove(url);
    }
  }

  /// Triple-tap escape (D11): every tap buzzes so the operator knows
  /// the hidden corner registered; the third tap buzzes stronger and
  /// opens the menu. A pause longer than the counter window restarts
  /// the count, so accidental double-taps never open the menu.
  void _onCornerTap() {
    final completed = _cornerTaps.register(DateTime.now());
    HapticFeedback.mediumImpact();
    if (completed) {
      HapticFeedback.heavyImpact();
      _showEscapeSheet();
    }
  }

  bool _sheetVisible = false;

  void _showEscapeSheet() {
    if (!mounted || _sheetVisible) return;
    _sheetVisible = true;
    showModalBottomSheet<void>(
      context: context,
      // Landscape screens are short: without a scroll cap the 7-row
      // sheet overflows and the bottom items (Rotate / Clear cache)
      // become unreachable. Cap at 90% of the screen and scroll.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  leading: Icon(Icons.touch_app),
                  title: Text('Support menu'),
                  subtitle: Text('Tap this corner 3 times to reopen'),
                ),
                ListTile(
                  leading: const Icon(Icons.home),
                  title: const Text('Home'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(context).pushReplacementNamed('/');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('Settings'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(context).pushNamed('/settings');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.health_and_safety),
                  title: const Text('Support / health'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(context).pushNamed('/support');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('Reload page'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _controller?.reload();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.screen_rotation),
                  title: Text(MediaQuery.sizeOf(context).width >=
                          MediaQuery.sizeOf(context).height
                      ? 'Rotate to portrait'
                      : 'Rotate to landscape'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    // Pin the opposite axis right now; the choice persists
                    // and is re-applied on every app start. Verified after
                    // a short settle so a system that ignores the pin (One
                    // UI auto-rotate quirk) produces a visible hint instead
                    // of a silent no-op.
                    final isLandscape = MediaQuery.sizeOf(context).width >=
                        MediaQuery.sizeOf(context).height;
                    final next = isLandscape ? 'portrait' : 'landscape';
                    await context.read<SettingsStore>().setOrientation(next);
                    if (!mounted) return;
                    final ok = await applyOrientationVerified(
                        orientationModeFromName(next), context);
                    if (!mounted) return;
                    if (ok) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text(
                          'Did not rotate — turn off Auto rotate in the tablet '
                          'quick settings, then tap Rotate again.'),
                    ));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cleaning_services),
                  title: const Text('Clear web cache'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await _confirmClearCache();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => _sheetVisible = false);
  }

  /// Clear cookies + web storage + HTTP cache, then reload. Guarded
  /// individually so a platform that lacks one API (or a dead WebView)
  /// still clears what it can instead of failing the whole request.
  Future<void> _clearWebCache() async {
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {}
    try {
      await WebStorageManager.instance().deleteAllData();
    } catch (_) {}
    try {
      // Static + global: clears the WebView HTTP/disk cache for the app
      // (the deprecated per-instance clearCache pointed here).
      await InAppWebViewController.clearAllCache();
    } catch (_) {}
  }

  Future<void> _confirmClearCache() async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear web cache?'),
        content: const Text(
            'Cookies, local storage and cached files of the APEM page are '
            'removed. The operator may need to sign in again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _clearWebCache();
    if (!mounted) return;
    _controller?.reload();
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Web cache cleared — page reloaded.')));
  }

  void _recover(String reason) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$reason — reloading...'),
      backgroundColor: Colors.orange,
    ));
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      _controller?.reload();
    });
  }

  void _showBlocked(Uri uri) {
    _blockedNotifications++;
    // Silent block after the first — a chatty banner would be escape-
    // hatch bait; the operator simply stays where they are.
    if (_blockedNotifications == 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Blocked: only the APEM web app can be opened here.'),
      ));
    }
  }

  @override
  void dispose() {
    _cornerTaps.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final apemUrl = settings.apemUrl.trim();
    // Escape hotspot must sit BELOW the status-bar inset: with
    // targetSdk 35+ Android forces edge-to-edge, so the top ~24-40 dp
    // belongs to the system status-bar window — touches there are
    // swallowed (and can pull the notification shade) instead of
    // reaching this overlay.
    final topInset = MediaQuery.paddingOf(context).top;

    if (apemUrl.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('APEM')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.language, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                const Text('No APEM web app URL configured.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pushReplacementNamed('/settings'),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final allowedOrigin = Uri.parse(apemUrl);

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            top: false,
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(apemUrl)),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  // D13: compile the AUTO default into the shim; the
                  // live setting re-applies on every page load.
                  source: kPrintAgentShim.replaceFirst(
                      '__AUTO_PDF_DEFAULT__',
                      settings.autoPrintPdf ? 'true' : 'false'),
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  forMainFrameOnly: false,
                ),
              ]),
              initialSettings: InAppWebViewSettings(
                useShouldOverrideUrlLoading: true,
                javaScriptEnabled: true,
                mediaPlaybackRequiresUserGesture: true,
                // Kiosk: no zoom surprises on tablet taps.
                supportZoom: false,
                disableVerticalScroll: false,
                disableHorizontalScroll: true,
                // D13: downloads route through onDownloadStartRequest —
                // PDFs print, everything else is acknowledged once.
                useOnDownloadStart: true,
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                controller.addJavaScriptHandler(
                  handlerName: 'printAgent',
                  callback: _onBridgeCall,
                );
                controller.addJavaScriptHandler(
                  handlerName: 'pdfFetchResult',
                  callback: _onPdfFetchResult,
                );
              },
              shouldOverrideUrlLoading: (controller, action) async {
                final uri = action.request.url;
                if (uri == null) return NavigationActionPolicy.CANCEL;
                // D13 PDF capture runs before the allowlist: printing a
                // PDF is a safe local action even off-origin (the agent
                // never leaves the LAN), and `blob:` fetches must happen
                // in the page anyway. Off, the allowlist applies as usual.
                if (settings.autoPrintPdf && _isCaptureTarget(uri)) {
                  unawaited(_capturePdf(uri));
                  return NavigationActionPolicy.CANCEL;
                }
                if (isAllowedNavigation(uri, allowedOrigin)) {
                  return NavigationActionPolicy.ALLOW;
                }
                if (!mounted) return NavigationActionPolicy.CANCEL;
                _showBlocked(uri);
                return NavigationActionPolicy.CANCEL;
              },
              // Popups (window.open / target=_blank): PDFs capture for
              // auto-print; anything else stays inside the kiosk by
              // loading in this view — the allowlist re-runs on it.
              onCreateWindow: (controller, action) async {
                final uri = action.request.url;
                if (uri == null) return false;
                if (context.read<SettingsStore>().autoPrintPdf &&
                    _isCaptureTarget(uri)) {
                  unawaited(_capturePdf(uri));
                  return false;
                }
                if (uri.isScheme('http') || uri.isScheme('https')) {
                  await controller.loadUrl(
                      urlRequest: URLRequest(url: uri));
                }
                return false;
              },
              onDownloadStartRequest: (controller, request) async {
                final uri = request.url;
                if (context.read<SettingsStore>().autoPrintPdf &&
                    isPdfRequest(
                      uri,
                      contentDisposition: request.contentDisposition,
                      mimeType: request.mimeType,
                    )) {
                  _capturePdf(
                    uri,
                    title: filenameFromDisposition(request.contentDisposition) ??
                        pdfTitleFrom(uri),
                  );
                  return;
                }
                // Non-PDF (or auto-print off): WebView downloads are not
                // used by the kiosk — acknowledge once so the tap does
                // not look dead.
                _downloadIgnoredNotifications++;
                if (_downloadIgnoredNotifications == 1) {
                  _toast('Only PDFs are handled here — other downloads '
                      'are ignored.', error: true);
                }
              },
              onLoadStop: (controller, url) {
                if (!mounted) return;
                setState(() => _progress = 0);
                // Keep the shim's AUTO flag in sync with the live
                // setting (new documents re-inject the compile-time
                // default, which can be stale after a Settings change).
                final auto = context.read<SettingsStore>().autoPrintPdf;
                unawaited(controller.evaluateJavascript(
                    source: 'window.__mpaSetAutoPdf && '
                        'window.__mpaSetAutoPdf(${auto ? 'true' : 'false'})'));
              },
              onProgressChanged: (controller, progress) {
                if (mounted) setState(() => _progress = progress / 100);
              },
              // D11 crash recovery (iOS + Android).
              onWebContentProcessDidTerminate: (controller) =>
                  _recover('Web content stopped'),
              onRenderProcessGone: (controller, details) {
                _recover('Web view crashed');
              },
            ),
          ),
          // D11 hidden escape gesture: triple-tap the top-left corner
          // just below the status bar (see topInset above).
          Positioned(
            top: topInset + 4,
            left: 0,
            width: 64,
            height: 64,
            child: GestureDetector(
              // Each tap buzzes (the status bar would otherwise eat
              // touches silently); the third tap opens the menu.
              onTap: _onCornerTap,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(width: 64, height: 64),
            ),
          ),
          if (_progress > 0 && _progress < 1)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(value: _progress, minHeight: 2),
            ),
        ],
      ),
    );
  }
}
