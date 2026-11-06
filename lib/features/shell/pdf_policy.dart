import 'dart:convert';

/// PDF auto-print policy (decision D13): decides what counts as a PDF
/// request and how its bridge print payload is built. Pure functions —
/// unit-tested in `test/auto_print_pdf_test.dart`.

/// D9: max envelope bytes the handler accepts (1 MB).
const int maxBridgeEnvelopeBytes = 1024 * 1024;

/// Max raw bytes we inline: base64 inflates 4/3, so 750 KB raw ≈ 1000 KB
/// envelope with JSON overhead — just under the 1 MB cap. The page-side
/// shim uses the same constant (750 * 1024).
const int maxInlinePdfRawBytes = 750 * 1024;

/// Extract `filename="..."` / `filename=token` from a Content-Disposition
/// header. `filename*=` (RFC 5987, usually UTF-8) is not parsed — the
/// plain `filename` form is what clinic servers send.
String? filenameFromDisposition(String? header) {
  if (header == null || header.isEmpty) return null;
  final m =
      RegExp(r'filename\*?="?([^";]+)"?', caseSensitive: false).firstMatch(header);
  var name = m?.group(1)?.trim();
  if (name != null && name.toLowerCase().startsWith("utf-8''")) {
    name = name.substring(7);
  }
  if (name == null || name.isEmpty) return null;
  return name;
}

/// True when the request should be captured for auto-print: path ends
/// with `.pdf`, or the server reported a PDF mime type / disposition
/// filename. `blob:` URLs never identify as PDF by URL alone — the shell
/// captures them optimistically and the page-side fetch validates the
/// `%PDF` magic bytes.
bool isPdfRequest(
  Uri uri, {
  String? contentDisposition,
  String? mimeType,
}) {
  final mime = mimeType?.toLowerCase();
  if (mime != null && mime.contains('pdf')) return true;
  final name = filenameFromDisposition(contentDisposition);
  if (name != null && name.toLowerCase().endsWith('.pdf')) return true;
  return uri.path.toLowerCase().endsWith('.pdf');
}

/// Best-effort human title for the print job.
String pdfTitleFrom(Uri uri, {String? filename}) {
  if (filename != null && filename.isNotEmpty) return filename;
  final last = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
  if (last.isNotEmpty) return last;
  return 'document.pdf';
}

/// Build the bridge `print` payload for a captured PDF.
///
/// - [base64] present and small enough -> inline `content` (D9 cap).
/// - URL is http(s) but the bytes exceed the inline cap ->
///   `artifactUrl`, so Dart re-fetches bytes on the transport plane
///   (public URLs only — the WebView fetch is preferred precisely
///   because it carries session cookies).
/// - anything else -> [error] for the operator toast. `blob:` URLs can
///   go neither route once they exceed the inline cap.
({Map<String, dynamic>? payload, String? error}) buildPdfPrintPayload({
  required String documentId,
  required Uri uri,
  required String title,
  String? base64,
  bool tooLarge = false,
}) {
  final canArtifact = uri.isScheme('http') || uri.isScheme('https');
  if (base64 != null && base64.isNotEmpty) {
    final payload = <String, dynamic>{
      'documentId': documentId,
      'format': 'application/pdf',
      'contentEncoding': 'base64',
      'content': base64,
      'title': title,
    };
    if (_envelopeLen(payload) <= maxBridgeEnvelopeBytes) {
      return (payload: payload, error: null);
    }
  }
  if (canArtifact) {
    final payload = <String, dynamic>{
      'documentId': documentId,
      'format': 'application/pdf',
      'artifactUrl': uri.toString(),
      'title': title,
    };
    if (_envelopeLen(payload) <= maxBridgeEnvelopeBytes) {
      return (payload: payload, error: null);
    }
  }
  return (
    payload: null,
    error: 'PDF too large to print directly and no direct URL available '
        '(max ${maxBridgeEnvelopeBytes ~/ 1024} KB)',
  );
}

int _envelopeLen(Map<String, dynamic> payload) =>
    jsonEncode({'v': 1, 'action': 'print', 'payload': payload}).length;
