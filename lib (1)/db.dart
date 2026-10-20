import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class Db {
  static Database? _db;

  static Future<Database> get() async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'daftari.db');
    _db = await openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute('''CREATE TABLE customers(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT,
        credit_limit REAL DEFAULT 0)''');
      await db.execute('''CREATE TABLE transactions(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        customer_id INTEGER NOT NULL,
        type TEXT NOT NULL,            -- debt | payment
        amount REAL NOT NULL,
        method TEXT NOT NULL,          -- cash | bank
        status TEXT NOT NULL,          -- pending | confirmed | rejected
        note TEXT,
        created_at INTEGER NOT NULL)''');
      await db.execute('''CREATE TABLE incoming(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bank_code TEXT,
        amount REAL,
        sender_name TEXT,
        operation_id TEXT UNIQUE,
        occurred_at INTEGER,
        matched_tx_id INTEGER,
        status TEXT)                   -- matched | unmatched | ambiguous | unparsed | ignored''');
      await db.execute('''CREATE TABLE sms_templates(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bank_code TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        pattern TEXT NOT NULL,
        active INTEGER DEFAULT 1)''');
      await db.execute('''CREATE TABLE audit_log(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT, detail TEXT, created_at INTEGER)''');
      await db.execute('CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)');

      // قوالب وهمية للتجربة. بدّلها بصيغة رسائل بنوككم من شاشة الإعدادات.
      // لازم يكون فيها المجموعات المسمّاة: amount و name و op
      await db.insert('sms_templates', {
        'bank_code': 'bank_a',
        'sender_id': 'BANKA',
        'pattern':
            r'(?:received|استلمت|تم استلام)\D{0,15}(?<amount>[\d,]+(?:\.\d{1,2})?).{0,40}?(?:from|من)\s+(?<name>[^\n.]+?)[\s.,]*(?:ref|المرجع|رقم العملية)[:\s#]*(?<op>[A-Za-z0-9]+)',
        'active': 1,
      });
      await db.insert('sms_templates', {
        'bank_code': 'wallet_b',
        'sender_id': 'WALLETB',
        'pattern':
            r'(?<amount>[\d,]+(?:\.\d{1,2})?)\s*(?:ILS|NIS|شيكل|₪).{0,40}?(?:from|من)\s+(?<name>[^\n.]+?)[\s.,]*(?:ID|رقم)[:\s#]*(?<op>[A-Za-z0-9]+)',
        'active': 1,
      });
    });
    return _db!;
  }

  // رصيد كل زبون = البضاعة (غير المرفوضة) - الدفعات المؤكدة فقط
  static const customersSql = '''
    SELECT c.*,
      COALESCE((SELECT SUM(amount) FROM transactions
                WHERE customer_id=c.id AND type='debt' AND status!='rejected'),0)
      - COALESCE((SELECT SUM(amount) FROM transactions
                WHERE customer_id=c.id AND type='payment' AND status='confirmed'),0)
      AS balance
    FROM customers c ORDER BY c.name''';

  static Future<double> balanceOf(int customerId) async {
    final db = await get();
    final r = await db.rawQuery(
        'SELECT * FROM ($customersSql) WHERE id=?', [customerId]);
    if (r.isEmpty) return 0;
    return (r.first['balance'] as num).toDouble();
  }

  static Future<void> audit(String action, String detail) async {
    final db = await get();
    await db.insert('audit_log', {
      'action': action,
      'detail': detail,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // لا شيء بينحذف: الرفض مجرد تغيير حالة، ومسجّل بالـ audit
  static Future<void> setTxStatus(int id, String status, String action) async {
    final db = await get();
    await db.update('transactions', {'status': status},
        where: 'id=?', whereArgs: [id]);
    await audit(action, 'tx=$id status=$status');
  }

  static Future<void> linkTransfer(int transferId, int txId) async {
    final db = await get();
    await db.transaction((t) async {
      await t.update('transactions', {'status': 'confirmed'},
          where: 'id=?', whereArgs: [txId]);
      await t.update('incoming', {'matched_tx_id': txId, 'status': 'matched'},
          where: 'id=?', whereArgs: [transferId]);
    });
    await audit('manual_link', 'transfer=$transferId tx=$txId');
  }

  static Future<String?> getKv(String k) async {
    final db = await get();
    final r = await db.query('kv', where: 'k=?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  static Future<void> setKv(String k, String v) async {
    final db = await get();
    await db.insert('kv', {'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
