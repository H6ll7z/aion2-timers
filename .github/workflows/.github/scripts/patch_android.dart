import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

void main() {
  // ---- AndroidManifest.xml ----
  final mf = File('android/app/src/main/AndroidManifest.xml');
  var s = mf.readAsStringSync();
  const perms = '''    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
''';
  const recv = '''        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter><action android:name="android.intent.action.BOOT_COMPLETED"/></intent-filter>
        </receiver>
''';
  if (!s.contains('ScheduledNotificationReceiver')) {
    s = s.replaceFirst('<application', '$perms    <application');
    s = s.replaceFirst('</application>', '$recv    </application>');
    s = s.replaceAll('android:label="aion2_timers"', 'android:label="Aion 2 Timers"');
  }
  mf.writeAsStringSync(s);

  // ---- app gradle (kts or groovy) ----
  final kts = File('android/app/build.gradle.kts');
  final isKts = kts.existsSync();
  final gf = isKts ? kts : File('android/app/build.gradle');
  var g = gf.readAsStringSync();
  final opts = RegExp(r'compileOptions\s*\{');
  g = g.replaceFirstMapped(
      opts,
      (m) => isKts
          ? '${m[0]}\n        isCoreLibraryDesugaringEnabled = true'
          : '${m[0]}\n        coreLibraryDesugaringEnabled true');
  g += isKts
      ? '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
      : "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n";
  gf.writeAsStringSync(g);
  // ---- status-bar icon (white shape, like other apps' notification icons) ----
  final res = 'android/app/src/main/res';
  Directory('$res/drawable').createSync(recursive: true);
  File('$res/drawable/ic_notify.xml').writeAsStringSync('''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp" android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M12,1 L14.6,9.4 L23,12 L14.6,14.6 L12,23 L9.4,14.6 L1,12 L9.4,9.4 Z"/>
</vector>
''');

  // ---- generated two-note chime sound ----
  Directory('$res/raw').createSync(recursive: true);
  File('$res/raw/aion_chime.wav').writeAsBytesSync(chime());
  File('$res/raw/keep.xml').writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:tools="http://schemas.android.com/tools"
    tools:keep="@raw/aion_chime,@drawable/ic_notify" />
''');
  print('patched');
}

Uint8List chime() {
  const rate = 44100;
  const secs = 1.2;
  final n = (rate * secs).toInt();
  final data = ByteData(44 + n * 2);
  void str(int o, String t) {
    for (var i = 0; i < t.length; i++) {
      data.setUint8(o + i, t.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    // note 1: 880 Hz, note 2 (from 0.3s): 1318 Hz, both with a soft decay
    var v = sin(2 * pi * 880 * t) * exp(-4 * t);
    if (t > 0.3) v += sin(2 * pi * 1318.5 * (t - 0.3)) * exp(-3.5 * (t - 0.3));
    final fade = i < 200 ? i / 200 : 1.0;
    data.setInt16(44 + i * 2, (v * 0.45 * fade * 32767).toInt().clamp(-32768, 32767), Endian.little);
  }
  return data.buffer.asUint8List();
}
