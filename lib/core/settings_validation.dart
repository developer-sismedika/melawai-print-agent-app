import '../agent/agent_client.dart';
import 'settings.dart';

/// Result of the Settings save flow (architecture doc §Settings:
/// validate URL shape -> /health -> /agent-info -> persist, token last).
class ValidationOutcome {
  const ValidationOutcome._({required this.ok, this.message = '', this.printers});

  final bool ok;
  final String message;
  final List<PrinterInfo>? printers;

  factory ValidationOutcome.success(List<PrinterInfo>? printers,
          {String message = ''}) =>
      ValidationOutcome._(ok: true, printers: printers, message: message);

  factory ValidationOutcome.failure(String message) =>
      ValidationOutcome._(ok: false, message: message);
}

class SettingsValidation {
  /// Never persists anything on failure (test V2: token must NOT be
  /// stored when health/catalogue checks fail).
  static Future<ValidationOutcome> validateAndSave({
    required SettingsStore settings,
    required AgentClient client,
    required String baseUrl,
    required String token,
    String? defaultPrinterId,
    String? apemUrl,
  }) async {
    final trimmed = baseUrl.trim();
    // Agent config is optional at setup: with no URL there is nothing to
    // validate, so save as-is (prints fail fast later via
    // E_NOT_CONFIGURED until both URL and token exist).
    if (trimmed.isEmpty) {
      await settings.save(
        baseUrl: '',
        token: token.trim(),
        defaultPrinterId: defaultPrinterId,
        apemUrl: apemUrl,
      );
      return ValidationOutcome.success(null,
          message: token.trim().isEmpty
              ? 'Settings saved — agent not configured yet.'
              : 'Settings saved — add the agent URL to enable checks.');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.isAbsolute ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return ValidationOutcome.failure(
          'Invalid agent URL — expected http://<ip>:9876');
    }
    final normalized = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;

    final candidate = client.withConfig(
        AgentConfig(baseUrl: normalized, token: token.trim()));
    try {
      final health = await candidate.health();
      if (!health.ok) {
        return ValidationOutcome.failure('Agent health check failed');
      }
    } on AgentException catch (e) {
      return ValidationOutcome.failure(
          'Agent unreachable: ${e.message}');
    }

    List<PrinterInfo> printers;
    try {
      printers = await candidate.agentInfo();
    } on AgentException catch (e) {
      return ValidationOutcome.failure('Printer catalogue failed: ${e.message}');
    }

    var printer = defaultPrinterId;
    if (printer == null || printer.isEmpty) {
      printer = settings.defaultPrinterId;
    }
    if (printers.isNotEmpty &&
        !printers.any((p) => p.id == printer)) {
      printer = printers.first.id;
    }

    await settings.save(
      baseUrl: normalized,
      token: token.trim(),
      defaultPrinterId: printer,
      apemUrl: apemUrl,
    );
    return ValidationOutcome.success(printers,
        message: 'Agent reachable — settings saved.');
  }
}

