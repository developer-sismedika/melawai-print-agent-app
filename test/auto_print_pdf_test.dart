import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melawai_print_agent_app/core/settings.dart';
import 'package:melawai_print_agent_app/features/shell/bridge_shim.dart';
import 'package:melawai_print_agent_app/features/shell/pdf_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// D13: PDF auto-print policy + Auto-print PDFs setting + shim wiring.
void main() {
  group('filenameFromDisposition', () {
    test('quoted filename', () {
      expect(filenameFromDisposition('attachment; filename="kupon.pdf"'),
          'kupon.pdf');
    });

    test('bare filename token', () {
      expect(filenameFromDisposition('inline; filename=abc.pdf'), 'abc.pdf');
    });

    test('filename* UTF-8 form strips the prefix', () {
      // Percent-decoding is left to the caller — the plain filename
      // form is what clinic servers send.
      expect(filenameFromDisposition("attachment; filename*=UTF-8''k%20x.pdf"),
          'k%20x.pdf');
    });

    test('absent / empty header', () {
      expect(filenameFromDisposition(null), isNull);
      expect(filenameFromDisposition(''), isNull);
      expect(filenameFromDisposition('inline'), isNull);
    });
  });

  group('isPdfRequest', () {
    test('path ends with .pdf (case-insensitive)', () {
      expect(isPdfRequest(Uri.parse('http://x/a/b.pdf')), isTrue);
      expect(isPdfRequest(Uri.parse('http://x/a/b.PDF')), isTrue);
      expect(isPdfRequest(Uri.parse('http://x/a/b.pdf?v=2#p')), isTrue);
    });

    test('non-pdf path', () {
      expect(isPdfRequest(Uri.parse('http://x/a/b.html')), isFalse);
      expect(isPdfRequest(Uri.parse('http://x/a/pdf-view')), isFalse);
    });

    test('server says PDF even without .pdf in the path', () {
      expect(
          isPdfRequest(Uri.parse('http://x/download?id=1'),
              mimeType: 'application/pdf'),
          isTrue);
      expect(
          isPdfRequest(Uri.parse('http://x/download?id=1'),
              contentDisposition: 'attachment; filename="receipt.pdf"'),
          isTrue);
      expect(
          isPdfRequest(Uri.parse('http://x/download?id=1'),
              mimeType: 'text/html'),
          isFalse);
    });

    test('blob URLs never identify as PDF by URL alone', () {
      expect(isPdfRequest(Uri.parse('blob:https://apem.local/uuid-1')), isFalse);
    });
  });

  group('pdfTitleFrom', () {
    test('filename wins', () {
      expect(pdfTitleFrom(Uri.parse('http://x/y/z.pdf'), filename: 'k.pdf'),
          'k.pdf');
    });

    test('falls back to the last path segment', () {
      expect(pdfTitleFrom(Uri.parse('http://x/y/z.pdf')), 'z.pdf');
    });

    test('bare origin falls back to document.pdf', () {
      expect(pdfTitleFrom(Uri.parse('http://x/')), 'document.pdf');
    });
  });

  group('buildPdfPrintPayload', () {
    final uri = Uri.parse('https://apem.local/receipt.pdf');
    // 400 KB of valid-looking base64 (well under the inline cap).
    final smallB64 = 'JVBERi0xLjQK' * (400 * 1024 ~/ 12);

    test('small bytes go inline with contentEncoding base64', () {
      final built = buildPdfPrintPayload(
        documentId: 'pdf-1',
        uri: uri,
        title: 'receipt.pdf',
        base64: smallB64,
      );
      expect(built.error, isNull);
      final p = built.payload!;
      expect(p['content'], smallB64);
      expect(p['contentEncoding'], 'base64');
      expect(p['format'], 'application/pdf');
      expect(p['documentId'], 'pdf-1');
      expect(p['title'], 'receipt.pdf');
      expect(p.containsKey('artifactUrl'), isFalse);
      final envelope =
          jsonEncode({'v': 1, 'action': 'print', 'payload': p});
      expect(envelope.length, lessThanOrEqualTo(maxBridgeEnvelopeBytes));
    });

    test('too large on http(s) falls back to artifactUrl', () {
      final built = buildPdfPrintPayload(
        documentId: 'pdf-2',
        uri: uri,
        title: 'receipt.pdf',
        tooLarge: true,
      );
      expect(built.error, isNull);
      expect(built.payload!['artifactUrl'], uri.toString());
      expect(built.payload!.containsKey('content'), isFalse);
      expect(built.payload!['format'], 'application/pdf');
    });

    test('inline bytes that still overflow the envelope go artifact', () {
      final huge = 'A' * (maxBridgeEnvelopeBytes + 100);
      final built = buildPdfPrintPayload(
        documentId: 'pdf-3',
        uri: uri,
        title: 'receipt.pdf',
        base64: huge,
      );
      expect(built.error, isNull);
      expect(built.payload!['artifactUrl'], uri.toString());
    });

    test('too large blob: cannot use artifactUrl — operator error', () {
      final built = buildPdfPrintPayload(
        documentId: 'pdf-4',
        uri: Uri.parse('blob:https://apem.local/uuid-1'),
        title: 'blob.pdf',
        tooLarge: true,
      );
      expect(built.payload, isNull);
      expect(built.error, contains('too large'));
    });

    test('http(s) with nothing fetched still offers artifactUrl', () {
      final built = buildPdfPrintPayload(
        documentId: 'pdf-5',
        uri: uri,
        title: 'receipt.pdf',
      );
      expect(built.error, isNull);
      expect(built.payload!['artifactUrl'], uri.toString());
    });

    test('blob with nothing fetched and no bytes is an error', () {
      final built = buildPdfPrintPayload(
        documentId: 'pdf-6',
        uri: Uri.parse('blob:https://apem.local/uuid-2'),
        title: 'blob.pdf',
      );
      expect(built.payload, isNull);
      expect(built.error, isNotNull);
    });
  });

  group('Auto-print PDFs setting', () {
    test('defaults on, persists off across reload', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      final s = InMemorySecretStore();

      final loaded = await SettingsStore.load(prefs: p, secrets: s);
      expect(loaded.autoPrintPdf, isTrue);

      await loaded.setAutoPrintPdf(false);
      final reloaded = await SettingsStore.load(prefs: p, secrets: s);
      expect(reloaded.autoPrintPdf, isFalse);

      await reloaded.setAutoPrintPdf(true);
      final again = await SettingsStore.load(prefs: p, secrets: s);
      expect(again.autoPrintPdf, isTrue);
    });
  });

  group('shim PDF wiring', () {
    test('AUTO default token present exactly once', () {
      final matches =
          RegExp('__AUTO_PDF_DEFAULT__').allMatches(kPrintAgentShim);
      expect(matches.length, 1);
      final injected = kPrintAgentShim
          .replaceFirst('__AUTO_PDF_DEFAULT__', 'true');
      expect(injected.contains('__AUTO_PDF_DEFAULT__'), isFalse);
      expect(injected, contains('var AUTO = true;'));
      final off =
          kPrintAgentShim.replaceFirst('__AUTO_PDF_DEFAULT__', 'false');
      expect(off, contains('var AUTO = false;'));
    });

    test('fetch / result / click hooks present', () {
      expect(kPrintAgentShim, contains('window.__mpaFetchPdf'));
      expect(kPrintAgentShim, contains('window.__mpaSetAutoPdf'));
      expect(kPrintAgentShim, contains("'pdfFetchResult'"));
      expect(kPrintAgentShim, contains('mpaAutoPrint'));
      expect(kPrintAgentShim, contains("'%PDF'"));
      expect(kPrintAgentShim, contains("addEventListener('click'"));
    });

    test('auto documentIds carry the pdf- prefix the shell toasts on', () {
      expect(kPrintAgentShim, contains("documentId: 'pdf-'"));
    });
  });
}
