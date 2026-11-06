import 'package:flutter_test/flutter_test.dart';
import 'package:melawai_print_agent_app/features/shell/navigation_policy.dart';

void main() {
  Uri a(String s) => Uri.parse(s);

  test('exact origin allowed', () {
    expect(
      isAllowedNavigation(a('http://192.168.1.40:3004/app'), a('http://192.168.1.40:3004/')),
      isTrue,
    );
    expect(
      isAllowedNavigation(a('https://clinic.example/idem/app'), a('https://clinic.example/idem/app')),
      isTrue,
    );
  });

  test('www canonical redirect allowed (host only differs by www.)', () {
    expect(
      isAllowedNavigation(a('https://www.google.com/search?q=x'), a('https://google.com')),
      isTrue,
    );
    expect(
      isAllowedNavigation(a('https://google.com/x'), a('https://www.google.com')),
      isTrue,
    );
  });

  test('http -> https upgrade on standard ports allowed', () {
    expect(
      isAllowedNavigation(a('https://www.clinic.id/app'), a('http://clinic.id')),
      isTrue,
    );
  });

  test('cross-host blocked', () {
    expect(isAllowedNavigation(a('https://evil.com/'), a('https://google.com')), isFalse);
    expect(isAllowedNavigation(a('https://m.google.com/'), a('https://google.com')), isFalse);
    expect(
      isAllowedNavigation(a('https://google.com.evil.com/'), a('https://google.com')),
      isFalse,
    );
  });

  test('clinic ports stay strict', () {
    expect(
      isAllowedNavigation(a('http://192.168.1.40:9876/'), a('http://192.168.1.40:3004/')),
      isFalse,
    );
    expect(
      isAllowedNavigation(a('http://192.168.1.40/'), a('http://192.168.1.40:3004/')),
      isFalse,
    );
    expect(
      isAllowedNavigation(a('http://192.168.1.40:3004/x'), a('http://192.168.1.40:3004/')),
      isTrue,
    );
  });

  test('non-http schemes blocked', () {
    expect(isAllowedNavigation(a('file:///etc/passwd'), a('https://google.com')), isFalse);
    expect(isAllowedNavigation(a('intent://x#Intent'), a('https://google.com')), isFalse);
    expect(isAllowedNavigation(a('javascript:alert(1)'), a('https://google.com')), isFalse);
    expect(isAllowedNavigation(a('about:blank'), a('https://google.com')), isFalse);
  });

  test('blocked hosts also never match an empty configured origin', () {
    expect(isAllowedNavigation(a('https://google.com'), Uri.parse('')), isFalse);
  });
}
