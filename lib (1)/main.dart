import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'db.dart';
import 'sms_engine.dart';
import 'sms_listener.dart';

/// رمز الدولة لأرقام الواتس (970 فلسطين، 972 إسرائيل). غيّره حسب رقم زبائنك.
const kCountryCode = '970';

String money(num v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

String fmtTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String t(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${t(d.month)}-${t(d.day)} ${t(d.hour)}:${t(d.minute)}';
}

void snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DaftariApp());
}

class DaftariApp extends StatelessWidget {
  const DaftariApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'دفتري',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        builder: (c, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const HomePage(),
      );
}

// ======================= الشاشة الرئيسية =======================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> rows = [];
  String q = '';
  int attention = 0;
  double totalDebt = 0;

  @override
  void initState() {
    super.initState();
    SmsEngine.changed.addListener(load);
    load();
    SmsListener.init();
  }

  @override
  void dispose() {
    SmsEngine.changed.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final db = await Db.get();
    final r = await db.rawQuery(Db.customersSql);
    final p = await db.rawQuery(
        "SELECT COUNT(*) n FROM transactions WHERE status='pending' AND method='bank'");
    final u = await db.rawQuery(
        "SELECT COUNT(*) n FROM incoming WHERE status IN ('unmatched','ambiguous','unparsed')");
    if (!mounted) return;
    setState(() {
      rows = r;
      attention = (p.first['n'] as int) + (u.first['n'] as int);
      totalDebt = r.fold<double>(0, (s, e) => s + (e['balance'] as num).toDouble());
    });
  }

  Future<void> go(Widget w) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    load();
  }

  @override
  Widget build(BuildContext context) {
    final list = rows
        .where((c) => q.isEmpty || (c['name'] as String).contains(q))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('دفتري'),
        actions: [
          IconButton(
              tooltip: 'إغلاق اليوم',
              icon: const Icon(Icons.fact_check_outlined),
              onPressed: () => go(const DailyClosePage())),
          IconButton(
              tooltip: 'الإعدادات',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => go(const SettingsPage())),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add),
        label: const Text('زبون جديد'),
        onPressed: () async {
          await editCustomer(context);
          load();
        },
      ),
      body: Column(children: [
        if (attention > 0)
          Material(
            color: Colors.amber.shade100,
            child: ListTile(
              leading: const Icon(Icons.warning_amber_rounded),
              title: Text('يحتاج انتباهك: $attention'),
              subtitle: const Text('دفعات معلّقة أو حوالات بدون صاحب'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => go(const PendingPage()),
            ),
          ),
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: ListTile(
            title: const Text('مجموع الديون على الزبائن'),
            trailing: Text('${money(totalDebt)} ₪',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'بحث عن زبون',
                border: OutlineInputBorder()),
            onChanged: (v) => setState(() => q = v),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('ما في زبائن بعد، أضف أول زبون'))
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final c = list[i];
                    final bal = (c['balance'] as num).toDouble();
                    final limit = (c['credit_limit'] as num?)?.toDouble() ?? 0;
                    final over = limit > 0 && bal > limit;
                    return ListTile(
                      title: Text(c['name'] as String),
                      subtitle: Text((c['phone'] ?? '').toString()),
                      leading: over
                          ? const Icon(Icons.flag, color: Colors.red)
                          : const Icon(Icons.person_outline),
                      trailing: Text('${money(bal)} ₪',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: bal > 0 ? Colors.red.shade700 : Colors.green.shade700)),
                      onTap: () => go(CustomerPage(customerId: c['id'] as int)),
                    );
                  }),
        ),
      ]),
    );
  }
}

// ======================= إضافة / تعديل زبون =======================
Future<void> editCustomer(BuildContext context, {Map<String, dynamic>? c}) async {
  final name = TextEditingController(text: c?['name']?.toString() ?? '');
  final phone = TextEditingController(text: c?['phone']?.toString() ?? '');
  final limit = TextEditingController(
      text: c == null ? '' : money((c['credit_limit'] as num?) ?? 0));
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(c == null ? 'زبون جديد' : 'تعديل الزبون'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم')),
          TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'الجوال (للواتس)')),
          TextField(
              controller: limit,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'سقف الدين ₪ (0 = بدون سقف)')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حفظ')),
      ],
    ),
  );
  if (ok != true || name.text.trim().isEmpty) return;
  final db = await Db.get();
  final data = {
    'name': name.text.trim(),
    'phone': phone.text.trim(),
    'credit_limit': double.tryParse(limit.text.trim()) ?? 0,
  };
  if (c == null) {
    final id = await db.insert('customers', data);
    await Db.audit('customer_add', 'id=$id');
  } else {
    await db.update('customers', data, where: 'id=?', whereArgs: [c['id']]);
    await Db.audit('customer_edit', 'id=${c['id']}');
  }
}

// ======================= صفحة الزبون =======================
class CustomerPage extends StatefulWidget {
  final int customerId;
  const CustomerPage({super.key, required this.customerId});
  @override
  State<CustomerPage> createState() => _CustomerPageState();
}

class _CustomerPageState extends State<CustomerPage> {
  Map<String, dynamic>? c;
  double bal = 0;
  List<Map<String, dynamic>> txs = [];

  @override
  void initState() {
    super.initState();
    SmsEngine.changed.addListener(load);
    load();
  }

  @override
  void dispose() {
    SmsEngine.changed.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final db = await Db.get();
    final r = await db.query('customers', where: 'id=?', whereArgs: [widget.customerId]);
    final t = await db.query('transactions',
        where: 'customer_id=?',
        whereArgs: [widget.customerId],
        orderBy: 'created_at DESC');
    final b = await Db.balanceOf(widget.customerId);
    if (!mounted || r.isEmpty) return;
    setState(() {
      c = r.first;
      txs = t;
      bal = b;
    });
  }

  Future<void> addTx(String type) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    String method = 'cash';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(type == 'debt' ? 'أخذ بضاعة' : 'تسجيل دفعة'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: amount,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'المبلغ ₪')),
              TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
              if (type == 'payment') ...[
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'cash', label: Text('نقداً')),
                    ButtonSegment(value: 'bank', label: Text('حوالة بنك')),
                  ],
                  selected: {method},
                  onSelectionChanged: (s) => setS(() => method = s.first),
                ),
                if (method == 'bank')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('بتنحسب "معلّقة" لحتى توصل الحوالة بحسابك',
                        style: TextStyle(fontSize: 12)),
                  ),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
          ],
        ),
      ),
    );
    final v = double.tryParse(SmsEngine.normDigits(amount.text.trim()));
    if (ok != true || v == null || v <= 0) return;

    // تحذير السقف
    final limit = (c!['credit_limit'] as num?)?.toDouble() ?? 0;
    if (type == 'debt' && limit > 0 && bal + v > limit) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('تنبيه'),
          content: Text('الدين بيصير ${money(bal + v)} ₪ وهاد أكبر من السقف (${money(limit)} ₪). تكمّل؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('لا')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('نعم')),
          ],
        ),
      );
      if (go != true) return;
    }

    final db = await Db.get();
    final isBank = type == 'payment' && method == 'bank';
    final id = await db.insert('transactions', {
      'customer_id': widget.customerId,
      'type': type,
      'amount': v,
      'method': type == 'debt' ? 'cash' : method,
      'status': isBank ? 'pending' : 'confirmed',
      'note': note.text.trim(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await Db.audit('tx_add', 'tx=$id type=$type amount=$v');
    load();
  }

  Future<void> remind() async {
    var ph = (c!['phone'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
    if (ph.isEmpty) {
      snack(context, 'ما في رقم جوال لهالزبون');
      return;
    }
    if (ph.startsWith('0')) ph = kCountryCode + ph.substring(1);
    final msg = 'مرحباً ${c!['name']}، المتبقي عليك ${money(bal)} ₪. شكراً لك.';
    final uri = Uri.parse('https://wa.me/$ph?text=${Uri.encodeComponent(msg)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String statusLabel(String s) =>
      {'pending': 'معلّقة', 'confirmed': 'مؤكدة', 'rejected': 'مرفوضة'}[s] ?? s;

  @override
  Widget build(BuildContext context) {
    if (c == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(c!['name'] as String), actions: [
        IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await editCustomer(context, c: c);
              load();
            }),
        IconButton(
            tooltip: 'تذكير واتس',
            icon: const Icon(Icons.chat_outlined),
            onPressed: remind),
      ]),
      body: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          color: bal > 0 ? Colors.red.shade50 : Colors.green.shade50,
          child: Column(children: [
            const Text('المتبقي عليه'),
            Text('${money(bal)} ₪',
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: () => addTx('debt'),
                    icon: const Icon(Icons.add_shopping_cart),
                    label: const Text('أخذ بضاعة'))),
            const SizedBox(width: 12),
            Expanded(
                child: FilledButton.tonalIcon(
                    onPressed: () => addTx('payment'),
                    icon: const Icon(Icons.payments_outlined),
                    label: const Text('دفع'))),
          ]),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: txs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final t = txs[i];
              final isDebt = t['type'] == 'debt';
              final pending = t['status'] == 'pending';
              final rejected = t['status'] == 'rejected';
              return ListTile(
                leading: Icon(isDebt ? Icons.arrow_upward : Icons.arrow_downward,
                    color: isDebt ? Colors.red : Colors.green),
                title: Text(
                    '${isDebt ? 'بضاعة' : 'دفعة'} ${money(t['amount'] as num)} ₪',
                    style: TextStyle(
                        decoration: rejected ? TextDecoration.lineThrough : null)),
                subtitle: Text([
                  if (!isDebt) (t['method'] == 'bank' ? 'بنك' : 'نقد'),
                  statusLabel(t['status'] as String),
                  fmtTime(t['created_at'] as int),
                  if ((t['note'] ?? '').toString().isNotEmpty) t['note'],
                ].join(' • ')),
                trailing: pending
                    ? PopupMenuButton<String>(
                        onSelected: (v) async {
                          await Db.setTxStatus(
                              t['id'] as int,
                              v == 'ok' ? 'confirmed' : 'rejected',
                              v == 'ok' ? 'manual_confirm' : 'manual_reject');
                          load();
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'ok', child: Text('تأكيد يدوي (شفتها بحسابي)')),
                          PopupMenuItem(value: 'no', child: Text('رفض')),
                        ],
                      )
                    : null,
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ======================= يحتاج انتباه =======================
class PendingPage extends StatefulWidget {
  const PendingPage({super.key});
  @override
  State<PendingPage> createState() => _PendingPageState();
}

class _PendingPageState extends State<PendingPage> {
  List<Map<String, dynamic>> pend = [], transfers = [];

  @override
  void initState() {
    super.initState();
    SmsEngine.changed.addListener(load);
    load();
  }

  @override
  void dispose() {
    SmsEngine.changed.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final db = await Db.get();
    final p = await db.rawQuery('''
      SELECT t.*, c.name FROM transactions t JOIN customers c ON c.id=t.customer_id
      WHERE t.status='pending' AND t.method='bank' ORDER BY t.created_at DESC''');
    final u = await db.query('incoming',
        where: "status IN ('unmatched','ambiguous','unparsed')",
        orderBy: 'occurred_at DESC');
    if (!mounted) return;
    setState(() {
      pend = p;
      transfers = u;
    });
  }

  Future<void> link(Map<String, dynamic> tr) async {
    final amount = (tr['amount'] as num).toDouble();
    final sorted = [...pend]..sort((a, b) {
        final da = ((a['amount'] as num) - amount).abs();
        final dbb = ((b['amount'] as num) - amount).abs();
        return da.compareTo(dbb);
      });
    if (sorted.isEmpty) {
      snack(context, 'ما في دفعات معلّقة تربطها');
      return;
    }
    final pick = await showDialog<int>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('اربط الحوالة بدفعة'),
        children: [
          for (final t in sorted)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, t['id'] as int),
              child: Text(
                  '${t['name']}  •  ${money(t['amount'] as num)} ₪  •  ${fmtTime(t['created_at'] as int)}'),
            ),
        ],
      ),
    );
    if (pick == null) return;
    await Db.linkTransfer(tr['id'] as int, pick);
    SmsEngine.changed.value++;
  }

  Future<void> ignoreTransfer(int id) async {
    final db = await Db.get();
    await db.update('incoming', {'status': 'ignored'}, where: 'id=?', whereArgs: [id]);
    await Db.audit('transfer_ignored', 'id=$id');
    SmsEngine.changed.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('يحتاج انتباهك')),
      body: ListView(children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('دفعات بنك معلّقة (لسا ما وصلت)',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (pend.isEmpty) const ListTile(title: Text('ما في')),
        for (final t in pend)
          ListTile(
            title: Text('${t['name']} • ${money(t['amount'] as num)} ₪'),
            subtitle: Text(fmtTime(t['created_at'] as int)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  tooltip: 'شفتها بحسابي',
                  icon: const Icon(Icons.check_circle_outline, color: Colors.green),
                  onPressed: () async {
                    await Db.setTxStatus(t['id'] as int, 'confirmed', 'manual_confirm');
                    SmsEngine.changed.value++;
                  }),
              IconButton(
                  tooltip: 'رفض',
                  icon: const Icon(Icons.cancel_outlined, color: Colors.red),
                  onPressed: () async {
                    await Db.setTxStatus(t['id'] as int, 'rejected', 'manual_reject');
                    SmsEngine.changed.value++;
                  }),
            ]),
          ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('حوالات وصلت بدون صاحب',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (transfers.isEmpty) const ListTile(title: Text('ما في')),
        for (final tr in transfers)
          ListTile(
            title: Text(tr['status'] == 'unparsed'
                ? 'رسالة بنك غير مفهومة'
                : '${money(tr['amount'] as num)} ₪ من ${tr['sender_name']}'),
            subtitle: Text(
                '${{'unmatched': 'ما لقيت دفعة بنفس المبلغ', 'ambiguous': 'أكثر من دفعة بنفس المبلغ', 'unparsed': 'عدّل القالب من الإعدادات'}[tr['status']] ?? ''} • ${fmtTime((tr['occurred_at'] as int?) ?? 0)}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (tr['status'] != 'unparsed')
                TextButton(onPressed: () => link(tr), child: const Text('ربط')),
              TextButton(
                  onPressed: () => ignoreTransfer(tr['id'] as int),
                  child: const Text('تجاهل')),
            ]),
          ),
      ]),
    );
  }
}

// ======================= إغلاق اليوم =======================
class DailyClosePage extends StatefulWidget {
  const DailyClosePage({super.key});
  @override
  State<DailyClosePage> createState() => _DailyClosePageState();
}

class _DailyClosePageState extends State<DailyClosePage> {
  final Map<String, double> v = {};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<double> sum(String sql, [List<Object?> args = const []]) async {
    final db = await Db.get();
    final r = await db.rawQuery(sql, args);
    return (r.first.values.first as num?)?.toDouble() ?? 0;
  }

  Future<void> load() async {
    final n = DateTime.now();
    final start = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
    final m = <String, double>{
      'debt': await sum(
          "SELECT SUM(amount) FROM transactions WHERE type='debt' AND status!='rejected' AND created_at>=?",
          [start]),
      'cash': await sum(
          "SELECT SUM(amount) FROM transactions WHERE type='payment' AND method='cash' AND status='confirmed' AND created_at>=?",
          [start]),
      'bank': await sum(
          "SELECT SUM(amount) FROM transactions WHERE type='payment' AND method='bank' AND status='confirmed' AND created_at>=?",
          [start]),
      'pending': await sum(
          "SELECT SUM(amount) FROM transactions WHERE type='payment' AND method='bank' AND status='pending'"),
      'pendingN': await sum(
          "SELECT COUNT(*) FROM transactions WHERE type='payment' AND method='bank' AND status='pending'"),
      'unmatchedN': await sum(
          "SELECT COUNT(*) FROM incoming WHERE status IN ('unmatched','ambiguous','unparsed')"),
      'total': await sum(
          "SELECT COALESCE(SUM(balance),0) FROM (${Db.customersSql})"),
    };
    if (!mounted) return;
    setState(() => v
      ..clear()
      ..addAll(m));
  }

  String report() {
    final d = DateTime.now();
    return '''إغلاق يوم ${d.year}-${d.month}-${d.day}
بضاعة بالدين اليوم: ${money(v['debt'] ?? 0)} ₪
مقبوض نقداً: ${money(v['cash'] ?? 0)} ₪
حوالات واصلة: ${money(v['bank'] ?? 0)} ₪
حوالات معلّقة: ${money(v['pending'] ?? 0)} ₪ (${(v['pendingN'] ?? 0).toInt()})
حوالات بدون صاحب: ${(v['unmatchedN'] ?? 0).toInt()}
مجموع الديون الكلي: ${money(v['total'] ?? 0)} ₪''';
  }

  Widget row(String label, String value, {Color? color}) => ListTile(
        title: Text(label),
        trailing: Text(value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إغلاق اليوم'), actions: [
        IconButton(
            tooltip: 'نسخ التقرير',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: report()));
              snack(context, 'اننسخ التقرير');
            }),
      ]),
      body: v.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              row('بضاعة بالدين اليوم', '${money(v['debt']!)} ₪', color: Colors.red.shade700),
              row('مقبوض نقداً اليوم', '${money(v['cash']!)} ₪', color: Colors.green.shade700),
              row('حوالات واصلة اليوم', '${money(v['bank']!)} ₪', color: Colors.green.shade700),
              const Divider(),
              row('حوالات معلّقة', '${money(v['pending']!)} ₪ (${v['pendingN']!.toInt()})',
                  color: Colors.orange.shade800),
              row('حوالات بدون صاحب', '${v['unmatchedN']!.toInt()}'),
              const Divider(),
              row('مجموع الديون الكلي', '${money(v['total']!)} ₪'),
            ]),
    );
  }
}

// ======================= الإعدادات =======================
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final paste = TextEditingController();
  String result = '';
  List<Map<String, dynamic>> tpls = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final db = await Db.get();
    final t = await db.query('sms_templates', orderBy: 'id');
    if (!mounted) return;
    setState(() => tpls = t);
  }

  Future<void> editTemplate([Map<String, dynamic>? t]) async {
    final bank = TextEditingController(text: t?['bank_code']?.toString() ?? '');
    final sender = TextEditingController(text: t?['sender_id']?.toString() ?? '');
    final pattern = TextEditingController(text: t?['pattern']?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t == null ? 'قالب جديد' : 'تعديل القالب'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: bank, decoration: const InputDecoration(labelText: 'اسم البنك/المحفظة')),
            TextField(
                controller: sender,
                decoration: const InputDecoration(
                    labelText: 'اسم المرسل كما بيظهر بالجوال')),
            TextField(
              controller: pattern,
              maxLines: 6,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                  labelText: 'Regex',
                  helperText: 'لازم فيه: (?<amount>..) (?<name>..) (?<op>..)',
                  helperMaxLines: 2),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حفظ')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      RegExp(pattern.text);
    } catch (_) {
      if (mounted) snack(context, 'الـ Regex فيه خطأ');
      return;
    }
    final db = await Db.get();
    final data = {
      'bank_code': bank.text.trim(),
      'sender_id': sender.text.trim(),
      'pattern': pattern.text.trim(),
      'active': 1,
    };
    if (t == null) {
      await db.insert('sms_templates', data);
    } else {
      await db.update('sms_templates', data, where: 'id=?', whereArgs: [t['id']]);
    }
    await Db.audit('template_edit', 'bank=${bank.text.trim()}');
    load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: const Text('قالب بنك'),
          onPressed: () => editTemplate()),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Text('الصق رسالة بنك (يدوياً)', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: paste,
          maxLines: 4,
          decoration: const InputDecoration(
              border: OutlineInputBorder(), hintText: 'الصق نص الرسالة هون'),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () async {
            final r = await SmsEngine.process(
                '', paste.text, DateTime.now().millisecondsSinceEpoch,
                paste: true);
            setState(() => result = r.message);
            if (r.status == 'matched') paste.clear();
          },
          child: const Text('حلّل ورتّب'),
        ),
        if (result.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(result)),
        const Divider(height: 32),
        const Text('قوالب البنوك', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
            'القوالب الحالية وهمية للتجربة. عدّلها حسب شكل رسائل بنكك الحقيقية.',
            style: TextStyle(fontSize: 12)),
        for (final t in tpls)
          ListTile(
            title: Text(t['bank_code'] as String),
            subtitle: Text('المرسل: ${t['sender_id']}'),
            trailing: Switch(
              value: t['active'] == 1,
              onChanged: (on) async {
                final db = await Db.get();
                await db.update('sms_templates', {'active': on ? 1 : 0},
                    where: 'id=?', whereArgs: [t['id']]);
                load();
              },
            ),
            onTap: () => editTemplate(t),
          ),
        const SizedBox(height: 80),
      ]),
    );
  }
}
