import 'package:flutter_test/flutter_test.dart';
import 'package:melawai_print_agent_app/features/shell/triple_tap.dart';

void main() {
  final t0 = DateTime(2026, 10, 2, 10);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  test('three quick taps complete the gesture', () {
    final c = TripleTapCounter();
    expect(c.register(at(0)), isFalse);
    expect(c.register(at(300)), isFalse);
    expect(c.register(at(600)), isTrue);
    // Completed — the count restarts for the next gesture.
    expect(c.register(at(900)), isFalse);
  });

  test('a pause longer than the window restarts the count', () {
    final c = TripleTapCounter();
    expect(c.register(at(0)), isFalse);
    expect(c.register(at(300)), isFalse);
    expect(c.register(at(1400)), isFalse); // gap 1100ms > 900ms window
    expect(c.register(at(1500)), isFalse);
    expect(c.register(at(1600)), isTrue); // only counts as 3rd of new run
  });

  test('double taps never open the menu', () {
    final c = TripleTapCounter();
    expect(c.register(at(0)), isFalse);
    expect(c.register(at(400)), isFalse);
    expect(c.register(at(4000)), isFalse); // fresh start after pause
    expect(c.register(at(4300)), isFalse);
    expect(c.register(at(8000)), isFalse);
  });

  test('reset forgets a partial gesture', () {
    final c = TripleTapCounter();
    c.register(at(0));
    c.register(at(100));
    c.reset();
    expect(c.register(at(200)), isFalse);
    expect(c.register(at(300)), isFalse);
    expect(c.register(at(400)), isTrue);
  });
}
