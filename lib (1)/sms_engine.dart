import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'db.dart';

class SmsResult {
  final String status; // matched | ambiguous | unmatched | unparsed | duplicate | ignored
  final String message;
  SmsResult(this.status, this.message);
}

class SmsEngine {
  /// يتحدّث كل ما تغيّرت البيانات بسبب رسالة جديدة، والشاشات بتسمعله.
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static const otpWords = [
    'otp', 'code', 'verification', 'password', 'pin',
    'رمز', 'كود', 'التحقق', 'كلمة المرور', 'كلمة السر',
  ];

  static bool isOtp(String body) {
    final b = body.toLowerCase();
    return otpWords.any((w) => b.contains(w));
  }

  static String normDigits(String s) {
    const ar = '٠١٢٣٤٥٦٧٨٩';
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    var out = s;
    for (var i = 0; i < 10; i++) {
      out = out.replaceAll(ar[i], '$i').replaceAll(fa[i], '$i');
    }
    return out;
  }

  static String normName(String s) {
    var n = s.replaceAll(RegExp(r'[ً-ٰٟـ]'), '');
    n = n.replaceAll(RegExp('[أإآ]'), 'ا');
    n = n.replaceAll('ى', 'ي').replaceAll('ة', 'ه');
    n = n.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ');
    return n.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  }

  /// تشابه الأسماء من 0 إلى 1 (حسب الكلمات، مع قبول اختلاف البداية)
  static double nameScore(String a, String b) {
    final ta = normName(a).split(' ').where((e) => e.isNotEmpty).toList();
    final tb = normName(b).split(' ').where((e) => e.isNotEmpty).toList();
    if (ta.isEmpty || tb.isEmpty) return 0;
    var hits = 0;
    for (final x in ta) {
      final ok = tb.any((y) =>
          y == x ||
          (x.length >= 3 && y.length >= 3 && (y.startsWith(x) || x.startsWith(y))));
      if (ok) hits++;
    }
    return hits / (ta.length < tb.length ? ta.length : tb.length);
  }

  static String _h(String s) {
    var h = 5381;
    for (final c in s.codeUnits) {
      h = ((h << 5) + h + c) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }

  /// المدخل الرئيسي: فلترة + تحليل + مطابقة.
  /// paste=true: المستخدم لصق الرسالة يدوياً، فنجرّب كل القوالب بغض النظر عن المرسل.
  static Future<SmsResult> process(String sender, String body, int tsMs,
      {bool paste = false}) async {
    final db = await Db.get();

    // 1) رموز التحقق: تجاهل نهائي، لا تخزين ولا سجل
    if (isOtp(body)) return SmsResult('ignored', 'رسالة رمز تحقق، تم تجاهلها');

    // 2) مرسل غير معتمد: تجاهل نهائي
    final tpls = await db.query('sms_templates', where: 'active=1');
    final cands = paste
        ? tpls
        : tpls
            .where((t) =>
                (t['sender_id'] as String).trim().toLowerCase() ==
                sender.trim().toLowerCase())
            .toList();
    if (cands.isEmpty) return SmsResult('ignored', 'مرسل غير معتمد');

    // 3) التحليل بقوالب البنك
    final text = normDigits(body);
    String bank = cands.first['bank_code'] as String;
    String? amountS, name, op;
    for (final t in cands) {
      try {
        final m = RegExp(t['pattern'] as String, caseSensitive: false, dotAll: true)
            .firstMatch(text);
        if (m != null) {
          amountS = m.namedGroup('amount');
          name = (m.namedGroup('name') ?? '').trim();
          op = m.namedGroup('op');
          bank = t['bank_code'] as String;
          break;
        }
      } catch (_) {/* قالب خاطئ: تجاهله */}
    }
    final amount = double.tryParse((amountS ?? '').replaceAll(',', ''));
    if (amount == null || op == null || op.isEmpty) {
      // نخزّن بصمة فقط، لا نص الرسالة
      await db.insert(
          'incoming',
          {
            'bank_code': bank,
            'amount': 0,
            'sender_name': '',
            'operation_id': 'u-${_h(body)}-$tsMs',
            'occurred_at': tsMs,
            'status': 'unparsed',
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      changed.value++;
      return SmsResult('unparsed', 'رسالة بنك ما انفهمت، راجع القالب');
    }

    // 4) منع التكرار
    final key = '$bank:$op';
    final dup = await db.query('incoming', where: 'operation_id=?', whereArgs: [key]);
    if (dup.isNotEmpty) return SmsResult('duplicate', 'هاي الحوالة انحسبت قبل');

    // 5) المطابقة: نفس المبلغ بالضبط + خلال 48 ساعة
    const window = 48 * 3600 * 1000;
    final rows = await db.rawQuery('''
      SELECT t.id, c.name FROM transactions t
      JOIN customers c ON c.id = t.customer_id
      WHERE t.type='payment' AND t.method='bank' AND t.status='pending'
        AND ABS(t.amount - ?) < 0.01 AND ABS(t.created_at - ?) < ?''',
        [amount, tsMs, window]);

    Future<int> insertTransfer(String status, int? txId) => db.insert('incoming', {
          'bank_code': bank,
          'amount': amount,
          'sender_name': name,
          'operation_id': key,
          'occurred_at': tsMs,
          'matched_tx_id': txId,
          'status': status,
        });

    if (rows.length == 1) {
      final txId = rows.first['id'] as int;
      await insertTransfer('matched', txId);
      await Db.setTxStatus(txId, 'confirmed', 'auto_confirm');
      changed.value++;
      return SmsResult('matched',
          'وصلت ${amount.toStringAsFixed(0)} ₪ من ${rows.first['name']}، تم تسجيلها');
    }
    if (rows.length > 1) {
      await insertTransfer('ambiguous', null);
      changed.value++;
      return SmsResult('ambiguous', 'في أكثر من دفعة بنفس المبلغ، اختار يدوياً');
    }
    await insertTransfer('unmatched', null);
    changed.value++;
    return SmsResult('unmatched',
        'وصلت ${amount.toStringAsFixed(0)} ₪ من $name ولا في دفعة معلّقة بنفس المبلغ');
  }
}
