import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// Schedules run on server time. The Global service (Asia region included) uses one GMT+9 clock;
// the separate Taiwan service uses GMT+8. Pick in the app.
Duration serverOffset = const Duration(hours: 9);
const regions = {
  'Global server, Asia region (GMT+9 / JST)': 9,
  'Taiwan service (GMT+8)': 8,
};
final plugin = FlutterLocalNotificationsPlugin();

// Heads-up alert with sound, vibration and a status-bar icon (like Facebook/Instagram alerts).
const details = NotificationDetails(
  android: AndroidNotificationDetails(
    'aion2_events_v2',
    'Aion 2 events',
    channelDescription: 'Alerts before Aion 2 events start',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('aion_chime'),
    enableVibration: true,
    icon: 'ic_notify',
    color: Color(0xFFD9B26A),
    ticker: 'Aion 2 event',
    visibility: NotificationVisibility.public,
    category: AndroidNotificationCategory.reminder,
  ),
);

// ---- Aion 2 look: night-sky navy, Elyos gold, aether teal ----
const gold = Color(0xFFD9B26A);
const aether = Color(0xFF5FD0E0);
const ink = Color(0xFF0A0E1A);
const panel = Color(0xFF141B2E);

(IconData, Color) metaOf(String id) => switch (id) {
      'shugo' => (Icons.celebration, gold),
      'invasion' => (Icons.crisis_alert, const Color(0xFFE5534B)),
      'rift' => (Icons.auto_awesome, const Color(0xFF9B7BFF)),
      'daily' => (Icons.wb_twilight, aether),
      _ => (Icons.event_repeat, aether),
    };

String two(int n) => n.toString().padLeft(2, '0');
String hm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';
String hms(DateTime t) => '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';

class Nx {
  final Duration d;
  final String srv, mine;
  Nx(this.d, this.srv, this.mine);
}

class Ev {
  final String id, name;
  final int? weekday; // server-time weekday (DateTime.monday..sunday), null = daily
  String times; // "HH:MM,HH:MM" in SERVER time
  bool on;
  Ev(this.id, this.name, this.times, {this.weekday, this.on = true});

  List<int> get mins {
    try {
      return times.split(',').map((s) {
        final p = s.trim().split(':');
        return int.parse(p[0]) * 60 + int.parse(p[1]);
      }).toList();
    } catch (_) {
      return [];
    }
  }

  List<DateTime> upcoming(DateTime nowUtc, Duration horizon) {
    final out = <DateTime>[];
    final s = nowUtc.add(serverOffset);
    final day0 = DateTime.utc(s.year, s.month, s.day);
    for (var d = 0; d <= horizon.inDays + 1; d++) {
      final day = day0.add(Duration(days: d));
      if (weekday != null && day.weekday != weekday) continue;
      for (final m in mins) {
        final utc = day.add(Duration(minutes: m)).subtract(serverOffset);
        if (utc.isAfter(nowUtc) && utc.isBefore(nowUtc.add(horizon))) out.add(utc);
      }
    }
    out.sort();
    return out;
  }
}

String hourly(int minute) => List.generate(
    24, (h) => '${h.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}').join(',');

List<Ev> defaults(int offset) {
  final tw = offset == 8;
  return [
    Ev('shugo', 'Shugo Festival', hourly(0)),
    Ev('invasion', 'Dimensional Invasion', hourly(30)),
    // Both lists are the same 3-hour cycle, just on each server's own clock. Tap the pencil to edit.
    Ev('rift', 'Spacetime Rift',
        tw ? '02:00,05:00,08:00,11:00,14:00,17:00,20:00,23:00' : '00:00,03:00,06:00,09:00,12:00,15:00,18:00,21:00'),
    // Assumes the reset is the same moment on both (07:00 UTC). Edit if your server differs.
    Ev('daily', 'Daily reset', tw ? '15:00' : '16:00'),
    Ev('weekly', 'Weekly reset', tw ? '15:00' : '16:00', weekday: DateTime.wednesday),
  ];
}

Future<void> reschedule(List<Ev> evs, int lead) async {
  await plugin.cancelAll();
  final now = DateTime.now().toUtc();
  var id = 1;
  for (final e in evs.where((e) => e.on)) {
    for (final t in e.upcoming(now, const Duration(hours: 48))) {
      final at = t.subtract(Duration(minutes: lead));
      if (!at.isAfter(now)) continue;
      if (id > 400) return;
      await plugin.zonedSchedule(id++, e.name,
          lead == 0 ? 'Starting now!' : 'Starts in $lead min',
          tz.TZDateTime.from(at, tz.UTC), details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle);
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('ic_notify')));
  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.requestNotificationsPermission();
  await android?.requestExactAlarmsPermission();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ink,
      colorScheme: const ColorScheme.dark(primary: gold, secondary: aether, surface: ink),
    ),
    home: const Home(),
  ));
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Ev> evs = defaults(9);
  int region = 9;
  int lead = 5;
  Timer? ticker;
  SharedPreferences? prefs;

  @override
  void initState() {
    super.initState();
    load();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    prefs = await SharedPreferences.getInstance();
    lead = prefs!.getInt('lead5') ?? 5;
    region = prefs!.getInt('region') ?? 9;
    serverOffset = Duration(hours: region);
    evs = defaults(region);
    for (final e in evs) {
      e.on = prefs!.getBool('on_${e.id}') ?? true;
      e.times = prefs!.getString('times_${e.id}') ?? e.times;
    }
    setState(() {});
    await reschedule(evs, lead); // keeps the next 48h topped up every time you open the app
  }

  Future<void> save() async {
    for (final e in evs) {
      await prefs!.setBool('on_${e.id}', e.on);
      await prefs!.setString('times_${e.id}', e.times);
    }
    await prefs!.setInt('lead5', lead);
    await prefs!.setInt('region', region);
    await reschedule(evs, lead);
  }

  Nx? nextOf(Ev e) {
    final now = DateTime.now().toUtc();
    final n = e.upcoming(now, const Duration(days: 8));
    if (n.isEmpty) return null;
    return Nx(n.first.difference(now), hm(n.first.add(serverOffset)), hm(n.first.toLocal()));
  }

  String fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '${h}h ${two(m)}m ${two(s)}s' : '${two(m)}m ${two(s)}s';
  }

  Future<void> edit(Ev e) async {
    final c = TextEditingController(text: e.times);
    final r = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              backgroundColor: panel,
              title: Text('${e.name} (server time, GMT+$region)'),
              content: TextField(
                  controller: c,
                  maxLines: 4,
                  decoration: const InputDecoration(helperText: 'HH:MM, comma separated')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
              ],
            ));
    if (r != null) {
      setState(() => e.times = r);
      await save();
    }
  }

  Widget label(String t) => Text(t,
      style: const TextStyle(fontSize: 10, letterSpacing: 2.5, color: aether, fontWeight: FontWeight.w600));

  Widget box({required Widget child, Color border = const Color(0x33D9B26A), List<BoxShadow>? glow}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
          gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1A2240), panel]),
          boxShadow: glow,
        ),
        child: child,
      );

  Widget eventCard(Ev e) {
    final (icon, color) = metaOf(e.id);
    final nx = e.on ? nextOf(e) : null;
    final soon = nx != null && nx.d.inMinutes < lead + 1;
    final progress = nx == null || nx.d.inSeconds >= 3600 ? 0.0 : 1 - nx.d.inSeconds / 3600;
    return box(
      border: soon ? color : color.withAlpha(70),
      glow: soon ? [BoxShadow(color: color.withAlpha(110), blurRadius: 18)] : null,
      child: Opacity(
        opacity: e.on ? 1 : 0.45,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color.withAlpha(40), border: Border.all(color: color.withAlpha(160))),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(e.name.toUpperCase(),
                  style: const TextStyle(fontFamily: 'serif', fontSize: 15, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
            ),
            IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.tune, size: 20, color: Colors.white54),
                onPressed: () => edit(e)),
            Switch(
                value: e.on,
                activeColor: color,
                onChanged: (v) async {
                  setState(() => e.on = v);
                  await save();
                }),
          ]),
          const SizedBox(height: 10),
          if (!e.on)
            const Text('Alerts off', style: TextStyle(color: Colors.white38))
          else if (nx == null)
            const Text('No times set', style: TextStyle(color: Colors.white38))
          else ...[
            Text(fmt(nx.d),
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w300, letterSpacing: 1, color: soon ? color : Colors.white)),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  value: progress, minHeight: 3, backgroundColor: Colors.white12, valueColor: AlwaysStoppedAnimation(color)),
            ),
            const SizedBox(height: 8),
            Text('${nx.srv} server   ·   ${nx.mine} your time',
                style: const TextStyle(fontSize: 12, color: Colors.white60, letterSpacing: 0.5)),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1B1636), ink, Color(0xFF060810)]),
        ),
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 28), children: [
            const Center(
              child: Text('AION 2',
                  style: TextStyle(fontFamily: 'serif', fontSize: 34, letterSpacing: 10, color: gold, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 2),
            const Center(
              child: Text('EVENT CHRONICLE',
                  style: TextStyle(fontSize: 11, letterSpacing: 5, color: aether, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 12),
            Container(
              height: 1,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.transparent, gold, Colors.transparent])),
            ),
            box(
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    label('SERVER · GMT+$region'),
                    const SizedBox(height: 4),
                    Text(hms(now.add(serverOffset)),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w300, color: gold)),
                  ]),
                ),
                Container(width: 1, height: 36, color: Colors.white12),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    label('YOUR TIME'),
                    const SizedBox(height: 4),
                    Text(hms(DateTime.now()),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w300)),
                  ]),
                ),
              ]),
            ),
            box(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                label('SERVER'),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: region,
                    isExpanded: true,
                    dropdownColor: panel,
                    items: regions.entries
                        .map((r) => DropdownMenuItem(value: r.value, child: Text(r.key)))
                        .toList(),
                    onChanged: (v) async {
                      for (final e in evs) {
                        await prefs!.remove('times_${e.id}');
                      }
                      setState(() {
                        region = v!;
                        serverOffset = Duration(hours: region);
                        evs = defaults(region);
                      });
                      await save();
                    },
                  ),
                ),
                const SizedBox(height: 6),
                label('ALERT ME'),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: lead,
                    isExpanded: true,
                    dropdownColor: panel,
                    items: [0, 1, 3, 5, 10]
                        .map((m) => DropdownMenuItem(value: m, child: Text(m == 0 ? 'When it starts' : '$m minutes before')))
                        .toList(),
                    onChanged: (v) async {
                      setState(() => lead = v!);
                      await save();
                    },
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.notifications_active, color: gold),
                label: const Text('SEND TEST ALERT', style: TextStyle(color: gold, letterSpacing: 2)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: gold), padding: const EdgeInsets.all(14)),
                onPressed: () => plugin.show(
                    0, 'Aion 2 Timers', 'Test alert: this is how your event alerts will look and sound.', details),
              ),
            ),
            for (final e in evs) eventCard(e),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Center(
                child: Text('Open the app every couple of days to keep alerts topped up.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white38)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
