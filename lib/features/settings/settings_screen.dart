import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../agent/agent_client.dart';
import '../../core/orientation.dart';
import '../../core/settings.dart';
import '../../core/settings_validation.dart';

/// Settings: agent URL, token, default printer. Save runs the full
/// validation flow (URL shape -> /health -> /agent-info) when a URL is
/// provided and persists the token only after both checks pass. Agent
/// URL and token are optional at setup: with no URL the form saves
/// directly and prints fail fast later via E_NOT_CONFIGURED.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  late final TextEditingController _apemController;
  String? _selectedPrinter;
  List<PrinterInfo> _printers = const [];
  bool _obscureToken = true;
  bool _busy = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsStore>();
    _urlController = TextEditingController(text: settings.agentBaseUrl);
    _tokenController = TextEditingController(text: settings.bearerToken);
    _apemController = TextEditingController(text: settings.apemUrl);
    _selectedPrinter =
        settings.defaultPrinterId.isEmpty ? null : settings.defaultPrinterId;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    _apemController.dispose();
    super.dispose();
  }

  Future<void> _validateAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    final settings = context.read<SettingsStore>();
    final client = context.read<AgentClient>();
    try {
      final outcome = await SettingsValidation.validateAndSave(
        settings: settings,
        client: client,
        baseUrl: _urlController.text,
        token: _tokenController.text,
        defaultPrinterId: _selectedPrinter,
        apemUrl: _apemController.text.trim().isEmpty
            ? null
            : _apemController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (outcome.ok) {
          _printers = outcome.printers ?? const [];
          if (_selectedPrinter == null && _printers.isNotEmpty) {
            _selectedPrinter = _printers.first.id;
          }
          _success = outcome.message.isEmpty
              ? 'Settings saved.'
              : outcome.message;
        } else {
          _error = outcome.message;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Agent URL',
                hintText: 'http://192.168.x.x:9876',
                helperText: 'Optional — leave empty to set up without an agent',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                final t = v?.trim() ?? '';
                if (t.isEmpty) return null; // optional at setup
                final uri = Uri.tryParse(t);
                if (uri == null ||
                    !uri.isAbsolute ||
                    !(uri.isScheme('http') || uri.isScheme('https')) ||
                    uri.host.isEmpty) {
                  return 'Invalid URL — expected http://<ip>:9876';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: 'API token',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureToken
                      ? Icons.visibility
                      : Icons.visibility_off),
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
              obscureText: _obscureToken,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _selectedPrinter,
              decoration: const InputDecoration(
                labelText: 'Default printer',
                border: OutlineInputBorder(),
                helperText: 'Fetched from the agent on save',
              ),
              items: [
                if (_selectedPrinter != null &&
                    !_printers.any((p) => p.id == _selectedPrinter))
                  DropdownMenuItem(
                      value: _selectedPrinter, child: Text(_selectedPrinter!)),
                ..._printers.map((p) => DropdownMenuItem(
                      value: p.id,
                      child: Text('${p.id} (${p.formats.join(', ')})'),
                    )),
              ],
              onChanged: (v) => setState(() => _selectedPrinter = v),
            ),
            const SizedBox(height: 12),
            // Orientation applies immediately and independently of
            // Validate & Save — usable while the agent is unconfigured.
            DropdownButtonFormField<String>(
              key: ValueKey('orientation-${settings.orientation}'),
              initialValue: settings.orientation,
              decoration: const InputDecoration(
                labelText: 'Screen orientation',
                helperText: 'Applies immediately',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                    value: 'auto', child: Text('Auto (follow sensor)')),
                DropdownMenuItem(value: 'portrait', child: Text('Portrait')),
                DropdownMenuItem(
                    value: 'landscape', child: Text('Landscape')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                await settings.setOrientation(v);
                if (!context.mounted) return;
                final ok = await applyOrientationVerified(
                    orientationModeFromName(v), context);
                if (!context.mounted) return;
                if (ok) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text(
                      'Did not rotate — turn off Auto rotate in the tablet '
                      'quick settings, then choose again.'),
                ));
              },
            ),
            const SizedBox(height: 4),
            // Auto-print PDFs: immediate like orientation (D13).
            SwitchListTile(
              key: const ValueKey('autoPrintPdfSwitch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-print PDFs'),
              subtitle: const Text(
                  'Print PDFs from the page directly instead of opening them'),
              value: settings.autoPrintPdf,
              onChanged: (v) => settings.setAutoPrintPdf(v),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _apemController,
              decoration: const InputDecoration(
                labelText: 'APEM web app URL',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
            if (_success != null)
              Text(_success!,
                  style: const TextStyle(color: Colors.green)),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _validateAndSave,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_sync),
              label: Text(_busy ? 'Validating...' : 'Validate & Save'),
            ),
            const SizedBox(height: 12),
            Text(
              'Saved: ${settings.isConfigured ? settings.agentBaseUrl : 'nothing yet'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
