/// Kiosk navigation allowlist (D2/D3) for the shell WebView.
///
/// Rules:
///  - only http(s) schemes can ever load;
///  - the host must equal the configured APEM host, ignoring a leading
///    `www.` (so `google.com` may follow its redirect to
///    `www.google.com` without being cancelled);
///  - ports must match, except when neither URL pins an explicit port —
///    that allows the common http -> https / `www` canonical redirects
///    while keeping clinic ports like `:9876` or `:8080` strict.
bool isAllowedNavigation(Uri uri, Uri allowed) {
  if (uri.host.isEmpty || allowed.host.isEmpty) return false;
  if (!(uri.isScheme('http') || uri.isScheme('https'))) return false;
  if (!(allowed.isScheme('http') || allowed.isScheme('https'))) return false;
  if (_normalizeHost(uri.host) != _normalizeHost(allowed.host)) return false;

  if (uri.port == allowed.port) return true;
  // Ports differ: allow only the standard-port pair (80/443), i.e.
  // neither URL carries an explicit port. http://x:80 -> https://x:443
  // counts as standard; x:8080 -> x:9876 does not.
  final uriPinned = _hasExplicitPort(uri);
  final allowedPinned = _hasExplicitPort(allowed);
  if (uriPinned || allowedPinned) return false;
  return true;
}

String _normalizeHost(String host) {
  var h = host.toLowerCase();
  if (h.startsWith('www.')) h = h.substring(4);
  return h;
}

bool _hasExplicitPort(Uri u) {
  // Uri.authority includes ':port' only when it was written explicitly
  // (or non-default... authority preserves what was parsed).
  final authority = u.authority;
  return authority.contains(':');
}
