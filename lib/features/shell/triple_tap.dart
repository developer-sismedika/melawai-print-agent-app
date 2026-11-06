/// Triple-tap counter for the hidden kiosk escape gesture.
///
/// Three taps inside [window] complete the gesture; a pause longer than
/// [window] restarts the count. Time is injected so tests never sleep.
class TripleTapCounter {
  TripleTapCounter({this.window = const Duration(milliseconds: 900)});

  /// Max gap between consecutive taps that still counts as one gesture.
  final Duration window;

  int _count = 0;
  DateTime? _lastTap;

  /// Register one tap at [now]. Returns true exactly on the third tap of
  /// a completed gesture (the counter then resets for the next one).
  bool register(DateTime now) {
    if (_lastTap == null || now.difference(_lastTap!) > window) {
      _count = 0;
    }
    _lastTap = now;
    _count++;
    if (_count >= 3) {
      _count = 0;
      return true;
    }
    return false;
  }

  /// Forget any partial gesture (used when the shell goes away).
  void reset() {
    _count = 0;
    _lastTap = null;
  }
}
