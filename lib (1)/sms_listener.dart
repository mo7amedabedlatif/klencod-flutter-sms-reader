import 'package:another_telephony/telephony.dart';
import 'db.dart';
import 'sms_engine.dart';

final Telephony _telephony = Telephony.instance;

/// لازم يكون top-level عشان يشتغل والتطبيق مسكّر
@pragma('vm:entry-point')
Future<void> smsBackgroundHandler(SmsMessage m) async {
  await SmsEngine.process(
    m.address ?? '',
    m.body ?? '',
    m.date ?? DateTime.now().millisecondsSinceEpoch,
  );
}

class SmsListener {
  static bool _started = false;

  static Future<void> init() async {
    if (_started) return;
    _started = true;
    final ok = await _telephony.requestPhoneAndSmsPermissions;
    if (ok != true) return;
    await catchUp();
    _telephony.listenIncomingSms(
      onNewMessage: (m) async {
        await SmsEngine.process(
          m.address ?? '',
          m.body ?? '',
          m.date ?? DateTime.now().millisecondsSinceEpoch,
        );
        SmsEngine.changed.value++;
      },
      onBackgroundMessage: smsBackgroundHandler,
      listenInBackground: true,
    );
  }

  /// يقرأ الرسائل اللي وصلت والتطبيق مسكّر أو الجوال مطفي.
  /// آمن: منع التكرار بالرقم المرجعي يضمن إنه ما بتنحسب مرتين.
  static Future<void> catchUp() async {
    final saved = await Db.getKv('sms_cursor');
    final cursor = int.tryParse(saved ?? '') ??
        DateTime.now()
            .subtract(const Duration(days: 2))
            .millisecondsSinceEpoch;
    final msgs = await _telephony.getInboxSms(
      columns: [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
      filter: SmsFilter.where(SmsColumn.DATE).greaterThan(cursor.toString()),
      sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.ASC)],
    );
    var maxDate = cursor;
    for (final m in msgs) {
      final d = m.date ?? DateTime.now().millisecondsSinceEpoch;
      await SmsEngine.process(m.address ?? '', m.body ?? '', d);
      if (d > maxDate) maxDate = d;
    }
    await Db.setKv('sms_cursor', maxDate.toString());
    SmsEngine.changed.value++;
  }
}
