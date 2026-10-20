import 'package:daftari/sms_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OTP messages are detected', () {
    expect(SmsEngine.isOtp('Your verification code is 1234'), true);
    expect(SmsEngine.isOtp('رمز التحقق الخاص بك 4455'), true);
    expect(SmsEngine.isOtp('Received ILS 120 from Ahmed Ref: A1'), false);
  });

  test('Arabic digits are normalized', () {
    expect(SmsEngine.normDigits('مبلغ ١٢٠٫٥'), contains('120'));
    expect(SmsEngine.normDigits('۱۲۳'), '123');
  });

  test('Name normalization and scoring', () {
    expect(SmsEngine.normName('أحمد'), SmsEngine.normName('احمد'));
    expect(SmsEngine.normName('فاطمة'), SmsEngine.normName('فاطمه'));
    expect(SmsEngine.nameScore('احمد علي', 'أحمد محمد علي'), 1.0);
    expect(SmsEngine.nameScore('خالد', 'سامي'), 0.0);
  });
}
