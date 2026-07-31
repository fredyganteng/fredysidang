// =============================================================
//  UNPAM CARE — Sistem Monitoring Kesehatan
//  - Dengan kontrol grafik dari Flutter ke ESP32 via MQTT
//  - Koneksi MQTT yang stabil dengan retry mechanism
// =============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';

// ===== KONFIGURASI MQTT =====
const String MQTT_BROKER = '203.175.125.45';
const int MQTT_PORT = 1883;
const String MQTT_USER = 'unpamhealths';
const String MQTT_PASS = 'fredyganteng';

// MQTT Topics
const String TOPIC_COMMAND = 'unpam/care/command';
const String TOPIC_STATUS = 'unpam/care/status';
const String TOPIC_DATA = 'unpam/care/data';
const String TOPIC_RESPONSE = 'unpam/care/response';
const String TOPIC_GSR = 'unpam/care/data/gsr';
const String TOPIC_HR = 'unpam/care/data/hr';
const String TOPIC_SPO2 = 'unpam/care/data/spo2';
const String TOPIC_TEMP = 'unpam/care/data/temp';

// ===== BATAS ALARM =====
const double kGsrLimit = 8.0;
const int kHrLimit = 120;
const int kSpo2Limit = 94;
const double kTempLimit = 37.5;

// ===== UKURAN TETAP =====
const double kHeaderH = 48;
const double kStatusCardH = 96;
const double kCardHeaderH = 20;
const double kCardBadgeH = 22;
const double kChipRowH = 48;
const double kChartCardH = 208;
const double kFooterH = 34;
const double kListBottomPad = 104;

// =============================================================
//  PALET & GAYA
// =============================================================
class C {
  static const bg = Color(0xFF070A11);
  static const bg2 = Color(0xFF0D1220);
  static const card = Color(0xFF131A28);
  static const line = Color(0x16FFFFFF);
  static const primary = Color(0xFF29B6F6);

  static const gsr = Color(0xFF26C6DA);
  static const spo2 = Color(0xFF5C89F5);
  static const hr = Color(0xFFEC407A);
  static const temp = Color(0xFF66BB6A);

  static const ok = Color(0xFF66BB6A);
  static const warn = Color(0xFFFFB300);
  static const danger = Color(0xFFEF5350);

  static const t1 = Colors.white;
  static const t2 = Colors.white70;
  static const t3 = Colors.white38;
}

const _numStyle = TextStyle(
  fontWeight: FontWeight.w700,
  fontFeatures: [FontFeature.tabularFigures()],
);

BoxDecoration cardDeco({Color? glow}) => BoxDecoration(
  gradient: const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF161E2E), Color(0xFF111726)],
  ),
  borderRadius: BorderRadius.circular(18),
  border: Border.all(color: glow ?? C.line, width: 1.4),
  boxShadow: [
    BoxShadow(
      color: glow?.withOpacity(0.20) ?? const Color(0x33000000),
      blurRadius: glow != null ? 18 : 14,
      spreadRadius: glow != null ? -4 : 0,
      offset: glow != null ? Offset.zero : const Offset(0, 6),
    ),
  ],
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const UnpamCareApp());
}

class UnpamCareApp extends StatelessWidget {
  const UnpamCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UNPAM CARE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: C.bg,
        colorScheme: const ColorScheme.dark(
          primary: C.primary,
          surface: C.card,
        ),
        useMaterial3: true,
      ),
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 1.0,
        maxScaleFactor: 1.1,
        child: child!,
      ),
      home: const SplashPage(),
    );
  }
}

// =============================================================
//  SPLASH PAGE
// =============================================================
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _ring;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  final AudioPlayer _player = AudioPlayer();

  String _status = 'Memuat';
  double _progress = 0;
  bool _demo = false;
  bool _canSkip = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();
    _ring = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _fade = CurvedAnimation(parent: _intro, curve: Curves.easeOut);
    _scale = Tween<double>(
      begin: 0.80,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _intro, curve: Curves.easeOutBack));

    Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _canSkip = true);
    });

    _boot();
  }

  void _set(double p, String msg) {
    if (mounted) {
      setState(() {
        _progress = p;
        _status = msg;
      });
    }
  }

  Future<void> _boot() async {
    final audioDone = _playWelcome();

    _set(0.12, 'Menyiapkan tampilan');
    await _intro.forward().orCancel.catchError((_) {});

    _set(0.35, 'Menyiapkan notifikasi');
    await _prepareNotif();

    _set(0.58, 'Membaca pengaturan');
    await _loadSettings();

    if (_demo) {
      _set(0.85, 'Mode simulasi aktif');
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } else {
      _set(0.78, 'Menyiapkan koneksi MQTT');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    _set(1.0, 'Siap digunakan');
    await audioDone;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _goDashboard();
  }

  void _goDashboard() {
    if (_navigated || !mounted) return;
    _navigated = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => const DashboardPage(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(
              begin: 1.06,
              end: 1.0,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
            child: child,
          ),
        ),
      ),
    );
  }

  Future<void> _playWelcome() async {
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.play(AssetSource('audio/welcome.mp3'));
      await _player.onPlayerComplete.first.timeout(
        const Duration(seconds: 12),
        onTimeout: () {},
      );
    } catch (e) {
      debugPrint('Audio gagal: $e');
    }
  }

  Future<void> _prepareNotif() async {
    try {
      final n = FlutterLocalNotificationsPlugin();
      await n.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      await n
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('Notifikasi gagal disiapkan: $e');
    }
  }

  Future<void> _loadSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      _demo = p.getBool('demo_mode') ?? false;
    } catch (e) {
      debugPrint('Pengaturan gagal dibaca: $e');
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _ring.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.35),
            radius: 1.1,
            colors: [Color(0xFF16203A), C.bg],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, cons) {
              final side = math.min(
                math.min(210.0, cons.maxWidth * 0.56),
                cons.maxHeight * 0.34,
              );
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: cons.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _logoBlock(side),
                        _titleBlock(),
                        _progressBlock(),
                        const Text(
                          'Universitas Pamulang',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white24,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _logoBlock(double side) => FadeTransition(
    opacity: _fade,
    child: ScaleTransition(
      scale: _scale,
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _ring,
              builder: (_, __) => CustomPaint(
                size: Size(side, side),
                painter: _RingPainter(_ring.value, _progress),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(side * 0.14),
              child: Image.asset(
                'assets/images/logo_unpam.png',
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.school_rounded,
                  size: side * 0.5,
                  color: C.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _titleBlock() => FadeTransition(
    opacity: _fade,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'UNPAM CARE',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: 6,
            color: C.t1,
          ),
        ),
        const SizedBox(height: 6),
        Container(width: 46, height: 2, color: C.primary),
        const SizedBox(height: 10),
        const Text(
          'Sistem Monitoring Kesehatan',
          style: TextStyle(fontSize: 12, color: C.t3, letterSpacing: 1.2),
        ),
      ],
    ),
  );

  Widget _progressBlock() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 48),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _progress),
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOut,
            builder: (_, v, __) => LinearProgressIndicator(
              value: v,
              minHeight: 4,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation<Color>(C.primary),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 16,
          child: Text(
            _status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: C.t3),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 38,
          child: AnimatedOpacity(
            opacity: _canSkip ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: TextButton(
              onPressed: _canSkip ? _goDashboard : null,
              style: TextButton.styleFrom(
                foregroundColor: C.primary,
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('Masuk tanpa menunggu alat'),
            ),
          ),
        ),
      ],
    ),
  );
}

class _RingPainter extends CustomPainter {
  final double spin;
  final double progress;
  _RingPainter(this.spin, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 6;
    if (r <= 0) return;
    final rect = Rect.fromCircle(center: c, radius: r);

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withOpacity(0.08),
    );

    canvas.drawArc(
      rect,
      spin * 2 * math.pi,
      math.pi * 0.42,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2
        ..color = C.primary.withOpacity(0.55),
    );

    canvas.drawArc(
      rect.deflate(7),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3
        ..color = C.primary,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.spin != spin || old.progress != progress;
}

// =============================================================
//  MODEL DATA SENSOR
// =============================================================
class SensorData {
  final double gsr;
  final int spo2;
  final int hr;
  final double temp;
  final String cat;
  final bool wifi;
  final String chart;

  SensorData({
    required this.gsr,
    required this.spo2,
    required this.hr,
    required this.temp,
    required this.cat,
    required this.wifi,
    this.chart = 'all',
  });

  factory SensorData.fromJson(Map<String, dynamic> j) => SensorData(
    gsr: (j['gsr'] ?? 0).toDouble(),
    spo2: (j['spo2'] ?? 0).toInt(),
    hr: (j['hr'] ?? 0).toInt(),
    temp: (j['temp'] ?? 0).toDouble(),
    cat: (j['cat'] ?? '-').toString(),
    wifi: (j['wifi'] ?? false) == true,
    chart: (j['chart'] ?? 'all').toString(),
  );

  Map<String, dynamic> toJson() => {
    'gsr': gsr,
    'spo2': spo2,
    'hr': hr,
    'temp': temp,
    'cat': cat,
    'wifi': wifi,
    'chart': chart,
  };

  static SensorData empty() =>
      SensorData(gsr: 0, spo2: 0, hr: 0, temp: 0, cat: '-', wifi: false);
}

enum ConnState { disconnected, connecting, connected }

// =============================================================
//  DASHBOARD
// =============================================================
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin {
  // MQTT Client
  MqttServerClient? _mqttClient;
  bool _mqttConnected = false;
  Timer? _reconnectTimer;
  Timer? _demoTimer;
  int _reconnectAttempts = 0;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _subscription;

  late final AnimationController _pulse;

  ConnState _state = ConnState.disconnected;
  SensorData _data = SensorData.empty();

  final List<int> _hrHistory = [];
  final List<double> _gsrHistory = [];
  final List<double> _tempHistory = [];

  DateTime? _lastUpdate;
  bool _demo = false;
  bool _stale = false;

  DateTime _lastCache = DateTime.fromMillisecondsSinceEpoch(0);

  final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();
  bool _gsrAlerted = false;
  bool _hrAlerted = false;

  String _activeChart = 'all';
  bool _isSendingCommand = false;
  String _mqttStatus = 'Disconnected';

  // preset warna umum (nama + Color)
  static const List<MapEntry<String, Color>> _colorPresets = [
    MapEntry('Merah', Color(0xFFF80000)),
    MapEntry('Oranye', Color(0xFFFF8000)),
    MapEntry('Kuning', Color(0xFFFFFF00)),
    MapEntry('Hijau', Color(0xFF00F800)),
    MapEntry('Cyan', Color(0xFF00FFFF)),
    MapEntry('Biru', Color(0xFF0000F8)),
    MapEntry('Ungu', Color(0xFF8000F8)),
    MapEntry('Magenta', Color(0xFFF800F8)),
    MapEntry('Putih', Color(0xFFFFFFFF)),
    MapEntry('Abu', Color(0xFF808080)),
    MapEntry('Hitam', Color(0xFF000000)),
  ];

  // warna ESP saat ini — dikoordinasikan dgn alat (sumber kebenaran = ESP/NVS)
  final Map<String, Color> _espColors = {
    'gsr': C.gsr,
    'spo2': C.spo2,
    'hr': C.hr,
    'temp': C.temp,
    'bg': const Color(0xFFFFFFFF), // background layar ESP (default putih)
    'chartbg': const Color(0xFFFFFFFF), // <-- BARU
  };

  // default pabrik ESP (RGB565) utk tombol reset
  static const Map<String, int> _espDefault565 = {
    'gsr': 0x045F,
    'spo2': 0xC800,
    'hr': 0x8010,
    'temp': 0x0480,
    'bg': 0xFFFF,
    'chartbg': 0xFFFF,
  };

  Color get _cGsr => _espColors['gsr'] ?? C.gsr;
  Color get _cSpo2 => _espColors['spo2'] ?? C.spo2;
  Color get _cHr => _espColors['hr'] ?? C.hr;
  Color get _cTemp => _espColors['temp'] ?? C.temp;

  String _toRgb565Hex(Color c) {
    final v = ((c.red >> 3) << 11) | ((c.green >> 2) << 5) | (c.blue >> 3);
    return v.toRadixString(16).toUpperCase().padLeft(4, '0');
  }

  Color _fromRgb565(int v) {
    final r = ((v >> 11) & 0x1F) * 255 ~/ 31;
    final g = ((v >> 5) & 0x3F) * 255 ~/ 63;
    final b = (v & 0x1F) * 255 ~/ 31;
    return Color.fromARGB(255, r, g, b);
  }

  Color? _parse565(String s) {
    s = s.trim();
    if (s.startsWith('0x') || s.startsWith('0X')) s = s.substring(2);
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : _fromRgb565(v);
  }

  void _syncColorsFromMap(Map<String, dynamic> map) {
    const jsonKeys = {
      'col_gsr': 'gsr',
      'col_spo2': 'spo2',
      'col_hr': 'hr',
      'col_temp': 'temp',
      'col_bg': 'bg',
      'col_chartbg': 'chartbg',
    };
    bool changed = false;
    jsonKeys.forEach((jk, target) {
      if (map.containsKey(jk)) {
        final c = _parse565(map[jk].toString());
        if (c != null) {
          _espColors[target] = c;
          changed = true;
        }
      }
    });
    if (changed) {
      setState(() {});
      _saveEspColors();
      debugPrint('🎨 Warna disinkron dari ESP');
    }
  }

  Future<void> _saveEspColors() async {
    try {
      final p = await SharedPreferences.getInstance();
      final m = _espColors.map((k, v) => MapEntry(k, v.value));
      await p.setString('esp_colors', jsonEncode(m));
    } catch (_) {}
  }

  Future<void> _loadEspColors() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('esp_colors');
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      m.forEach((k, v) {
        if (_espColors.containsKey(k))
          _espColors[k] = Color((v as num).toInt());
      });
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _requestStatus() {
    if (_mqttConnected) _publishMessage(TOPIC_COMMAND, 'status');
  }

  void _showColorPicker(String target, String label, VoidCallback? refresh) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Warna $label', style: const TextStyle(fontSize: 18)),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.count(
            crossAxisCount: 5,
            shrinkWrap: true,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final preset in _colorPresets)
                GestureDetector(
                  onTap: () {
                    Navigator.pop(ctx);
                    _sendColorCommand(target, preset.value);
                    refresh?.call();
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: preset.value,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 1.5),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preset.key,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 8, color: C.t3),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
        ],
      ),
    );
  }

  // ===== MQTT CONNECTION =====
  Future<void> _connectMQTT() async {
    if (_demo) return;

    if (_mqttClient != null && _mqttConnected) {
      debugPrint('MQTT already connected');
      return;
    }

    setState(() {
      _state = ConnState.connecting;
      _mqttStatus = 'Connecting...';
    });

    try {
      _mqttClient = MqttServerClient(
        MQTT_BROKER,
        'flutter_client_${DateTime.now().millisecondsSinceEpoch}',
      );
      _mqttClient!.port = MQTT_PORT;
      _mqttClient!.keepAlivePeriod = 60;
      _mqttClient!.logging(on: true);

      // Set connection handler - PERBAIKAN DI SINI
      _mqttClient!.onConnected = _onMQTTConnected;
      _mqttClient!.onDisconnected = _onMQTTDisconnected;
      _mqttClient!.onSubscribed = _onMQTTSubscribed;
      _mqttClient!.onSubscribeFail = _onMQTTSubscribeFail;
      // HAPUS atau COMMENT baris ini
      // _mqttClient!.onUnsubscribed = _onMQTTUnsubscribed;

      // Connect
      debugPrint('Connecting to MQTT broker: $MQTT_BROKER:$MQTT_PORT');
      final connMessage = MqttConnectMessage()
          .withClientIdentifier(
            'flutter_client_${DateTime.now().millisecondsSinceEpoch}',
          )
          .withWillTopic(TOPIC_STATUS)
          .withWillMessage('{"status":"offline"}')
          .withWillQos(MqttQos.atLeastOnce)
          .authenticateAs(MQTT_USER, MQTT_PASS);
      _mqttClient!.connectionMessage = connMessage;

      await _mqttClient!.connect();

      // Subscribe to topics
      if (_mqttClient!.connectionStatus!.state ==
          MqttConnectionState.connected) {
        _subscribeToTopics();
      }
    } catch (e) {
      debugPrint('MQTT Connection error: $e');
      setState(() {
        _state = ConnState.disconnected;
        _mqttStatus = 'Error: $e';
      });
      _scheduleReconnect();
    }
  }

  // HAPUS atau COMMENT fungsi ini karena tidak digunakan
  // void _onMQTTUnsubscribed(String topic) {
  //   debugPrint('📤 Unsubscribed from: $topic');
  // }
  void _subscribeToTopics() {
    if (_mqttClient == null || !_mqttConnected) return;

    const topics = [
      TOPIC_DATA,
      TOPIC_RESPONSE,
      TOPIC_STATUS,
      TOPIC_GSR,
      TOPIC_HR,
      TOPIC_SPO2,
      TOPIC_TEMP,
    ];

    for (final topic in topics) {
      _mqttClient!.subscribe(topic, MqttQos.atLeastOnce);
      debugPrint('📥 Subscribed to: $topic');
    }

    // Set up message stream listener
    _subscription?.cancel();
    _subscription = _mqttClient!.updates?.listen((
      List<MqttReceivedMessage<MqttMessage>> events,
    ) {
      for (final event in events) {
        _onMQTTMessage(event);
      }
    });
    Future.delayed(const Duration(milliseconds: 800), _requestStatus);
  }

  void _onMQTTConnected() {
    setState(() {
      _mqttConnected = true;
      _state = ConnState.connected;
      _mqttStatus = 'Connected';
      _reconnectAttempts = 0;
    });
    debugPrint('✅ MQTT Connected');
    _snack('✅ Terhubung ke server MQTT');
  }

  void _onMQTTDisconnected() {
    setState(() {
      _mqttConnected = false;
      _state = ConnState.disconnected;
      _mqttStatus = 'Disconnected';
      if (_lastUpdate != null) _stale = true;
    });
    debugPrint('⚠️ MQTT Disconnected');
    _scheduleReconnect();
  }

  void _onMQTTSubscribed(String topic) {
    debugPrint('📥 Subscribed to: $topic');
  }

  void _onMQTTSubscribeFail(String topic) {
    debugPrint('❌ Failed to subscribe: $topic');
  }

  void _onMQTTUnsubscribed(String topic) {
    debugPrint('📤 Unsubscribed from: $topic');
  }

  void _onMQTTMessage(MqttReceivedMessage<MqttMessage> event) {
    final message = event.payload as MqttPublishMessage;
    final payload = MqttPublishPayload.bytesToStringAsString(
      message.payload.message,
    );

    try {
      debugPrint('📥 MQTT Message: $payload');

      // Try to parse as JSON
      final map = jsonDecode(payload) as Map<String, dynamic>;

      // Check if this is a response or status
      if (map.containsKey('status')) {
        _handleStatusMessage(map);
        return;
      }

      // Check if this is sensor data (has gsr, hr, etc)
      if (map.containsKey('gsr') || map.containsKey('hr')) {
        _handleSensorData(payload);
        return;
      }
    } catch (e) {
      debugPrint('❌ Failed to parse MQTT message: $e');
    }
  }

  void _handleStatusMessage(Map<String, dynamic> map) {
    final status = map['status'] ?? '';

    if (status == 'chart_ok') {
      final chart = map['chart'] ?? 'all';
      setState(() {
        _activeChart = chart;
        _isSendingCommand = false;
      });
      _snack('✅ Grafik $chart aktif di ESP');
    } else if (status == 'online') {
      _syncColorsFromMap(map); // <-- retained/status: tarik warna dari ESP
    } else if (status == 'color_ok') {
      final target = (map['target'] ?? '').toString();
      final value = (map['value'] ?? '').toString();
      final c = _parse565(value);
      if (c != null && _espColors.containsKey(target)) {
        setState(() => _espColors[target] = c);
        _saveEspColors();
      }
      _snack('✅ Warna $target → $value');
    } else if (status == 'color_reset') {
      setState(
        () => _espDefault565.forEach((k, v) => _espColors[k] = _fromRgb565(v)),
      );
      _saveEspColors();
      _snack('✅ Warna ESP direset');
    } else if (status == 'connected') {
      _snack('✅ Terhubung ke ESP');
    } else if (status == 'time_ok') {
      debugPrint('⏰ Time set OK');
    } else if (status == 'error') {
      _snack('❌ ${map['message'] ?? 'Error'}');
    }
  }

  void _handleSensorData(String payload) {
    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final data = SensorData.fromJson(map);

      // Update UI
      _applyData(data);

      // Send time if just connected
      if (_state != ConnState.connected) {
        setState(() => _state = ConnState.connected);
        _sendTime();
      }
    } catch (e) {
      debugPrint('❌ Parse sensor data error: $e');
    }
  }

  void _scheduleReconnect() {
    if (_demo) return;

    _reconnectTimer?.cancel();
    final delay = math.min(60, 5 + _reconnectAttempts * 5);
    _reconnectAttempts++;

    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (mounted && !_mqttConnected && !_demo) {
        debugPrint('🔄 Reconnecting MQTT... (attempt $_reconnectAttempts)');
        _connectMQTT();
      }
    });
  }

  // ===== SEND COMMANDS VIA MQTT =====
  Future<void> _sendChartCommand(String chartType) async {
    if (!_mqttConnected) {
      _snack('❌ Tidak terhubung ke server MQTT');
      return;
    }

    if (_isSendingCommand) {
      _snack('⏳ Tunggu perintah selesai');
      return;
    }

    setState(() {
      _isSendingCommand = true;
    });

    try {
      final command = 'chart:$chartType';
      _publishMessage(TOPIC_COMMAND, command);
      debugPrint('📤 Sending command: $command');

      // Wait for confirmation (timeout 5 seconds)
      await Future.delayed(const Duration(seconds: 5));

      setState(() {
        _isSendingCommand = false;
      });
    } catch (e) {
      debugPrint('❌ Error sending: $e');
      setState(() {
        _isSendingCommand = false;
      });
      _snack('❌ Gagal mengirim perintah');
    }
  }

  void _sendColorCommand(String target, Color color) {
    if (!_mqttConnected) {
      _snack('❌ Tidak terhubung ke server MQTT');
      return;
    }
    final hex = _toRgb565Hex(color);
    _publishMessage(TOPIC_COMMAND, 'color:$target:$hex');
    // update optimistik + simpan (lewat 565 biar persis kayak yg tampil di alat)
    setState(() => _espColors[target] = _fromRgb565(int.parse(hex, radix: 16)));
    _saveEspColors();
    _snack('🎨 Warna $target dikirim (0x$hex)');
  }

  void _sendColorReset() {
    if (!_mqttConnected) {
      _snack('❌ Tidak terhubung ke server MQTT');
      return;
    }
    _publishMessage(TOPIC_COMMAND, 'color:reset');
    setState(
      () => _espDefault565.forEach((k, v) => _espColors[k] = _fromRgb565(v)),
    );
    _saveEspColors();
    _snack('🎨 Warna direset ke default');
  }

  void _sendTime() {
    final now = DateTime.now();
    final secs = now.hour * 3600 + now.minute * 60 + now.second;
    _publishMessage(TOPIC_COMMAND, 'T:$secs');
    debugPrint('📤 Time sent: $secs');
  }

  void _sendPing() {
    if (_mqttConnected) {
      _publishMessage(TOPIC_COMMAND, 'ping');
      debugPrint('📤 Ping sent');
    }
  }

  void _publishMessage(String topic, String message) {
    if (_mqttClient == null || !_mqttConnected) {
      debugPrint('❌ Cannot publish: not connected');
      return;
    }

    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(message);
      _mqttClient!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
    } catch (e) {
      debugPrint('❌ Publish error: $e');
    }
  }

  // ===== DATA HANDLING =====
  void _applyData(SensorData d) {
    if (!mounted) return;
    setState(() {
      _data = d;
      _lastUpdate = DateTime.now();
      _stale = false;
      _addToHistory(d);
      if (d.chart.isNotEmpty && d.chart != _activeChart) {
        _activeChart = d.chart;
        _isSendingCommand = false;
        debugPrint('📊 Chart updated from ESP: $_activeChart');
      }
    });
    _syncPulse(d.hr);
    _checkAlerts(d);
    if (!_demo) _cacheData(d);
  }

  void _addToHistory(SensorData d) {
    if (d.hr > 0) {
      _hrHistory.add(d.hr);
      if (_hrHistory.length > 60) _hrHistory.removeAt(0);
    }
    if (d.gsr > 0) {
      _gsrHistory.add(d.gsr);
      if (_gsrHistory.length > 60) _gsrHistory.removeAt(0);
    }
    if (d.temp > 0) {
      _tempHistory.add(d.temp);
      if (_tempHistory.length > 60) _tempHistory.removeAt(0);
    }
  }

  Future<void> _cacheData(SensorData d) async {
    final now = DateTime.now();
    if (now.difference(_lastCache).inSeconds < 10) return;
    _lastCache = now;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('last_data', jsonEncode(d.toJson()));
      await p.setInt('last_ts', now.millisecondsSinceEpoch);
    } catch (_) {}
  }

  void _syncPulse(int hr) {
    if (hr <= 0) return;
    final ms = ((60000 / hr) / 2).round().clamp(160, 700);
    if ((_pulse.duration!.inMilliseconds - ms).abs() > 40) {
      _pulse.duration = Duration(milliseconds: ms);
      _pulse.repeat(reverse: true);
    }
  }

  // ===== NOTIFICATIONS =====
  Future<void> _initNotif() async {
    try {
      await _notif.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      await _notif
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('Notifikasi gagal disiapkan: $e');
    }
  }

  Future<void> _showNotif(int id, String title, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'unpam_alert',
        'Peringatan UNPAM CARE',
        channelDescription: 'Notifikasi saat sensor melewati batas aman',
        importance: Importance.max,
        priority: Priority.high,
        color: C.danger,
        enableVibration: true,
      ),
    );
    try {
      await _notif.show(id, title, body, details);
    } catch (_) {}
  }

  void _checkAlerts(SensorData d) {
    if (d.gsr > kGsrLimit) {
      if (!_gsrAlerted) {
        _gsrAlerted = true;
        _showNotif(
          1,
          'GSR tinggi',
          'GSR terbaca ${d.gsr.toStringAsFixed(1)} uS. Tarik napas pelan dan tenangkan diri.',
        );
      }
    } else {
      _gsrAlerted = false;
    }

    if (d.hr > kHrLimit) {
      if (!_hrAlerted) {
        _hrAlerted = true;
        _showNotif(
          2,
          'Detak jantung tinggi',
          'Detak jantung ${d.hr} bpm. Istirahat sebentar sebelum melanjutkan aktivitas.',
        );
      }
    } else {
      _hrAlerted = false;
    }
  }

  // ===== DEMO MODE =====
  void _startDemo() {
    _disconnectMQTT();
    _demoTimer?.cancel();
    final rnd = math.Random();
    double gsr = 4.2;
    int hr = 78;
    int spo2 = 97;
    double temp = 36.6;

    setState(() {
      _state = ConnState.connected;
      _stale = false;
      _activeChart = 'all';
      _mqttStatus = 'Demo Mode';
    });

    _demoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      gsr = (gsr + (rnd.nextDouble() - 0.46) * 0.7).clamp(1.0, 12.0).toDouble();
      hr = (hr + rnd.nextInt(9) - 4).clamp(58, 138).toInt();
      spo2 = (spo2 + rnd.nextInt(3) - 1).clamp(91, 100).toInt();
      temp = (temp + (rnd.nextDouble() - 0.5) * 0.14)
          .clamp(35.6, 38.4)
          .toDouble();

      _applyData(
        SensorData(
          gsr: gsr,
          spo2: spo2,
          hr: hr,
          temp: temp,
          cat: gsr > 8 ? 'Tegang' : (gsr > 5 ? 'Waspada' : 'Rileks'),
          wifi: true,
          chart: _activeChart,
        ),
      );
    });
  }

  void _stopDemo() {
    _demoTimer?.cancel();
    _demoTimer = null;
  }

  // ===== MQTT DISCONNECT =====
  void _disconnectMQTT() {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    try {
      _mqttClient?.disconnect();
    } catch (_) {}
    _mqttClient = null;
    _mqttConnected = false;
    setState(() {
      _state = ConnState.disconnected;
      _mqttStatus = 'Disconnected';
      if (_lastUpdate != null) _stale = true;
    });
  }

  void _reconnectNow() {
    _reconnectAttempts = 0;
    if (_demo) {
      _startDemo();
    } else {
      _connectMQTT();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: C.card,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ===== CHART SELECTOR WIDGET =====
  Widget _chartSelector() {
    return Container(
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _chartButton('Semua', 'all', Icons.dashboard_rounded),
          const SizedBox(width: 8),
          _chartButton('GSR', 'gsr', Icons.waves_rounded),
          const SizedBox(width: 8),
          _chartButton('HR', 'hr', Icons.monitor_heart_rounded),
          const SizedBox(width: 8),
          _chartButton('Suhu', 'temp', Icons.thermostat_rounded),
        ],
      ),
    );
  }

  Widget _chartButton(String label, String type, IconData icon) {
    final isActive = _activeChart == type;
    final isLoading = _isSendingCommand && isActive;

    return Expanded(
      child: ElevatedButton(
        onPressed: isLoading ? null : () => _sendChartCommand(type),
        style: ElevatedButton.styleFrom(
          backgroundColor: isActive ? C.primary.withOpacity(0.2) : C.card,
          foregroundColor: isActive ? C.primary : C.t2,
          padding: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: isActive ? C.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isLoading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: C.primary,
                ),
              )
            else
              Icon(icon, size: 14),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chartStatusIndicator() {
    if (_activeChart == 'all') return const SizedBox.shrink();

    Map<String, dynamic> chartInfo = {
      'gsr': {'label': 'GSR', 'icon': Icons.waves_rounded, 'color': C.gsr},
      'hr': {
        'label': 'Bpm',
        'icon': Icons.monitor_heart_rounded,
        'color': C.hr,
      },
      'temp': {
        'label': 'Suhu',
        'icon': Icons.thermostat_rounded,
        'color': C.temp,
      },
    };

    if (!chartInfo.containsKey(_activeChart)) return const SizedBox.shrink();
    final info = chartInfo[_activeChart];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.line),
      ),
      child: Row(
        children: [
          Icon(info['icon'], color: info['color'], size: 16),
          const SizedBox(width: 8),
          Text(
            _isSendingCommand
                ? 'Mengirim perintah...'
                : 'Menampilkan grafik ${info['label']}',
            style: TextStyle(
              fontSize: 8,
              color: _isSendingCommand ? C.primary : C.t2,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: _isSendingCommand
                ? null
                : () => _sendChartCommand('all'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              _isSendingCommand ? 'Loading...' : 'Kembali',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    )..repeat(reverse: true);
    _initNotif();
    _startup();
  }

  Future<void> _startup() async {
    await _loadSettings();
    await _loadCachedData();
    await _loadEspColors(); // <-- BARU
    if (_demo) {
      _startDemo();
    } else {
      _connectMQTT();
    }
  }

  Future<void> _loadSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      _demo = p.getBool('demo_mode') ?? false;
    } catch (e) {
      debugPrint('Pengaturan gagal dibaca: $e');
    }
  }

  Future<void> _loadCachedData() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('last_data');
      final ts = p.getInt('last_ts');
      if (raw == null || ts == null) return;
      final d = SensorData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _data = d;
        _lastUpdate = DateTime.fromMillisecondsSinceEpoch(ts);
        _stale = true;
        _addToHistory(d);
        _activeChart = d.chart;
      });
    } catch (e) {
      debugPrint('Data simpanan gagal dibaca: $e');
    }
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _pulse.dispose();
    _disconnectMQTT();
    super.dispose();
  }

  // =============================================================
  //  TAMPILAN
  // =============================================================
  @override
  Widget build(BuildContext context) {
    final alerts = _activeAlerts();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [C.bg2, C.bg],
            stops: [0, 0.45],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              RefreshIndicator(
                color: C.primary,
                backgroundColor: C.card,
                onRefresh: () async {
                  _reconnectNow();
                  await Future<void>.delayed(const Duration(milliseconds: 600));
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, kListBottomPad),
                  children: [
                    _header(),
                    const SizedBox(height: 16),
                    _statusCard(),
                    const SizedBox(height: 16),
                    _chartSelector(),
                    _chartStatusIndicator(),
                    const SizedBox(height: 12),
                    _sectionLabel('Pembacaan sensor'),
                    const SizedBox(height: 10),
                    _sensorGrid(),
                    const SizedBox(height: 20),
                    _sectionLabel('Tren Detak Jantung'),
                    const SizedBox(height: 10),
                    _hrChartCard(),
                    const SizedBox(height: 16),
                    _sectionLabel('Tren GSR'),
                    const SizedBox(height: 10),
                    _gsrChartCard(),
                    const SizedBox(height: 16),
                    _sectionLabel('Tren Suhu '),
                    const SizedBox(height: 10),
                    _tempChartCard(),
                    const SizedBox(height: 16),
                    _LiveFooter(
                      lastUpdate: _lastUpdate,
                      stale: _stale,
                      mqttStatus: _mqttStatus,
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: _alertBanner(alerts),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- HEADER ----------
  Widget _header() {
    return SizedBox(
      height: kHeaderH,
      child: Row(
        children: [
          ScaleTransition(
            scale: Tween<double>(
              begin: 1.0,
              end: 1.18,
            ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: C.hr.withOpacity(0.14),
              ),
              child: const Icon(Icons.favorite, color: C.hr, size: 20),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'UNPAM CARE',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  'Monitoring kesehatan via MQTT',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: C.t3),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: _showSettings,
              icon: const Icon(Icons.tune_rounded, color: C.t2, size: 22),
              tooltip: 'Pengaturan',
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 10.5,
        color: C.t3,
        letterSpacing: 1.8,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  // ---------- STATUS CARD ----------
  Widget _statusCard() {
    late Color tone;
    late IconData icon;
    late String label;
    late String hint;

    switch (_state) {
      case ConnState.connected:
        tone = C.ok;
        icon = Icons.check_rounded;
        label = _demo ? 'Mode simulasi' : 'Terhubung';
        hint = _demo
            ? 'Data dibuat otomatis, alat tidak dipakai'
            : 'MQTT: $_mqttStatus | Chart: $_activeChart';
        break;
      case ConnState.connecting:
        tone = C.warn;
        icon = Icons.sync_rounded;
        label = 'Menghubungkan';
        hint = 'Menghubungkan ke broker MQTT...';
        break;
      case ConnState.disconnected:
        tone = C.warn;
        icon = Icons.cloud_off_rounded;
        label = 'Tanpa alat';
        hint = _lastUpdate == null
            ? 'Aplikasi tetap bisa dibuka. Nyalakan alat lalu ketuk tombol sambung.'
            : 'Menampilkan pembacaan terakhir. Ketuk tombol sambung untuk mencoba lagi.';
        break;
    }

    final connected = _state == ConnState.connected;

    return Container(
      height: kStatusCardH,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: cardDeco(),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => connected ? _disconnectMQTT() : _reconnectNow(),
            onLongPress: _showSettings,
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tone.withOpacity(0.14),
                border: Border.all(color: tone, width: 2.2),
              ),
              child: _state == ConnState.connecting
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(C.warn),
                      ),
                    )
                  : Icon(icon, color: tone, size: 25),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: tone,
                  ),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 30,
                  child: Text(
                    hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: C.t3,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: connected ? null : _reconnectNow,
              icon: Icon(
                Icons.refresh_rounded,
                size: 22,
                color: connected ? Colors.white12 : C.primary,
              ),
              tooltip: 'Sambungkan',
            ),
          ),
        ],
      ),
    );
  }

  // ---------- SPANDUK PERINGATAN ----------
  List<String> _activeAlerts() {
    if (_stale) return const [];
    final list = <String>[];
    if (_data.gsr > kGsrLimit)
      list.add('GSR ${_data.gsr.toStringAsFixed(1)} uS');
    if (_data.hr > kHrLimit) list.add('Detak ${_data.hr} bpm');
    if (_data.spo2 > 0 && _data.spo2 < kSpo2Limit)
      list.add('SpO2 ${_data.spo2} %');
    if (_data.temp > kTempLimit) {
      list.add('Suhu ${_data.temp.toStringAsFixed(1)} C');
    }
    return list;
  }

  Widget _alertBanner(List<String> alerts) {
    final show = alerts.isNotEmpty;
    return IgnorePointer(
      ignoring: !show,
      child: AnimatedSlide(
        offset: show ? Offset.zero : const Offset(0, 0.6),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          child: Container(
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1319),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: C.danger.withOpacity(0.55)),
              boxShadow: const [
                BoxShadow(color: Color(0x66000000), blurRadius: 18),
              ],
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: C.danger,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Di luar batas aman',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: C.danger,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        alerts.isEmpty ? '' : alerts.join('  •  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: C.t2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- KISI SENSOR ----------
  Widget _sensorGrid() {
    final live = !_stale;
    final gsrHigh = live && _data.gsr > kGsrLimit;
    final hrHigh = live && _data.hr > kHrLimit;
    final spo2Low = live && _data.spo2 > 0 && _data.spo2 < kSpo2Limit;
    final tempHigh = live && _data.temp > kTempLimit;

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 0.92,
      children: [
        _SensorCard(
          icon: Icons.waves_rounded,
          label: 'GSR',
          value: _data.gsr,
          decimals: 1,
          unit: 'uS',
          accent: C.gsr,
          min: 0,
          max: 15,
          alert: gsrHigh,
          dimmed: _stale,
          badge: _data.cat == '-' ? '' : _data.cat,
        ),
        _SensorCard(
          icon: Icons.bloodtype_rounded,
          label: 'SpO2',
          value: _data.spo2.toDouble(),
          decimals: 0,
          unit: '%',
          accent: C.spo2,
          min: 85,
          max: 100,
          alert: spo2Low,
          dimmed: _stale,
          badge: _data.spo2 == 0 ? '' : (spo2Low ? 'Rendah' : 'Normal'),
        ),
        _SensorCard(
          icon: Icons.monitor_heart_rounded,
          label: 'Detak jantung',
          value: _data.hr.toDouble(),
          decimals: 0,
          unit: 'bpm',
          accent: C.hr,
          min: 40,
          max: 160,
          alert: hrHigh,
          dimmed: _stale,
          badge: _data.hr == 0
              ? ''
              : (hrHigh ? 'Tinggi' : (_data.hr < 60 ? 'Rendah' : 'Normal')),
        ),
        _SensorCard(
          icon: Icons.thermostat_rounded,
          label: 'Suhu tubuh',
          value: _data.temp,
          decimals: 1,
          unit: '°C',
          accent: C.temp,
          min: 34,
          max: 40,
          alert: tempHigh,
          dimmed: _stale,
          badge: _data.temp == 0 ? '' : (tempHigh ? 'Demam' : 'Normal'),
        ),
      ],
    );
  }

  // ---------- GRAFIK ----------
  Widget _hrChartCard() {
    final has = _hrHistory.length >= 2;
    final avg = has
        ? (_hrHistory.reduce((a, b) => a + b) / _hrHistory.length).round()
        : 0;
    final lo = has ? _hrHistory.reduce(math.min) : 0;
    final hi = has ? _hrHistory.reduce(math.max) : 0;

    return Container(
      height: kChartCardH,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: cardDeco(glow: has ? C.hr : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: kChipRowH,
            child: Row(
              children: [
                _chip('Rata-rata', has ? '$avg' : '--', C.hr),
                const SizedBox(width: 8),
                _chip('Terendah', has ? '$lo' : '--', C.hr),
                const SizedBox(width: 8),
                _chip('Tertinggi', has ? '$hi' : '--', C.hr),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: has
                ? CustomPaint(
                    size: Size.infinite,
                    painter: _ChartPainter(
                      data: _hrHistory.map((e) => e.toDouble()).toList(),
                      color: C.hr,
                      minValue: 40,
                      maxValue: 160,
                    ),
                  )
                : const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'Grafik muncul setelah dua pembacaan masuk dari alat.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: C.t3, fontSize: 12),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _gsrChartCard() {
    final has = _gsrHistory.length >= 2;
    final avg = has
        ? (_gsrHistory.reduce((a, b) => a + b) / _gsrHistory.length)
        : 0.0;
    final lo = has ? _gsrHistory.reduce(math.min) : 0.0;
    final hi = has ? _gsrHistory.reduce(math.max) : 0.0;

    return Container(
      height: kChartCardH,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: cardDeco(glow: has ? C.gsr : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: kChipRowH,
            child: Row(
              children: [
                _chip('Rata-rata', has ? avg.toStringAsFixed(1) : '--', C.gsr),
                const SizedBox(width: 8),
                _chip('Terendah', has ? lo.toStringAsFixed(1) : '--', C.gsr),
                const SizedBox(width: 8),
                _chip('Tertinggi', has ? hi.toStringAsFixed(1) : '--', C.gsr),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: has
                ? CustomPaint(
                    size: Size.infinite,
                    painter: _ChartPainter(
                      data: List<double>.of(_gsrHistory),
                      color: C.gsr,
                      minValue: 0,
                      maxValue: 15,
                    ),
                  )
                : const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'Grafik muncul setelah dua pembacaan masuk dari alat.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: C.t3, fontSize: 12),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tempChartCard() {
    final has = _tempHistory.length >= 2;
    final avg = has
        ? (_tempHistory.reduce((a, b) => a + b) / _tempHistory.length)
        : 0.0;
    final lo = has ? _tempHistory.reduce(math.min) : 0.0;
    final hi = has ? _tempHistory.reduce(math.max) : 0.0;

    return Container(
      height: kChartCardH,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: cardDeco(glow: has ? C.temp : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: kChipRowH,
            child: Row(
              children: [
                _chip('Rata-rata', has ? avg.toStringAsFixed(1) : '--', C.temp),
                const SizedBox(width: 8),
                _chip('Terendah', has ? lo.toStringAsFixed(1) : '--', C.temp),
                const SizedBox(width: 8),
                _chip('Tertinggi', has ? hi.toStringAsFixed(1) : '--', C.temp),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: has
                ? CustomPaint(
                    size: Size.infinite,
                    painter: _ChartPainter(
                      data: List<double>.of(_tempHistory),
                      color: C.temp,
                      minValue: 34,
                      maxValue: 40,
                    ),
                  )
                : const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'Grafik muncul setelah dua pembacaan masuk dari alat.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: C.t3, fontSize: 12),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value, Color color) => Expanded(
    child: Container(
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withOpacity(0.15), width: 0.8),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                style: const TextStyle(fontSize: 9.5, color: C.t3),
              ),
              const SizedBox(height: 1),
              Text(
                value,
                maxLines: 1,
                style: _numStyle.copyWith(fontSize: 15, color: color),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  // ---------- DIALOG PENGATURAN ----------
  void _showSettings() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: C.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text('Pengaturan MQTT', style: TextStyle(fontSize: 18)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: C.bg2,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _infoRow('Broker', MQTT_BROKER),
                      _infoRow('Port', '$MQTT_PORT'),
                      _infoRow('Username', MQTT_USER),
                      _infoRow('Password', '••••••••'),
                      const Divider(color: C.line, height: 20),
                      _infoRow('Status', _mqttStatus),
                      _infoRow('Chart', _activeChart),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _demo,
                  activeColor: C.primary,
                  onChanged: (v) {
                    setLocal(() {});
                    setState(() => _demo = v);
                  },
                  title: const Text(
                    'Mode simulasi',
                    style: TextStyle(fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Isi dashboard dengan data buatan untuk mencoba tampilan tanpa alat.',
                    style: TextStyle(fontSize: 11, color: C.t3),
                  ),
                ),
                const Divider(color: C.line, height: 24),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'WARNA TAMPILAN ESP',
                    style: TextStyle(
                      fontSize: 10,
                      color: C.t3,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Ketuk untuk mengganti warna di layar alat. Otomatis tersimpan & tersinkron.',
                  style: TextStyle(fontSize: 11, color: C.t3),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _colorTile('GSR', 'gsr', () => setLocal(() {})),
                    _colorTile('SpO2', 'spo2', () => setLocal(() {})),
                    _colorTile('HR', 'hr', () => setLocal(() {})),
                    _colorTile('Suhu', 'temp', () => setLocal(() {})),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _colorTile('Layar', 'bg', () => setLocal(() {})),
                    _colorTile(
                      'Grafik',
                      'chartbg',
                      () => setLocal(() {}),
                    ), // <-- BARU
                    const Spacer(),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _mqttConnected
                        ? () {
                            _sendColorReset();
                            setLocal(() {});
                          }
                        : null,
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: const Text(
                      'Reset warna default',
                      style: TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: C.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Tutup'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _saveSettings();
                if (_demo) {
                  _startDemo();
                } else {
                  _stopDemo();
                  _connectMQTT();
                }
              },
              child: const Text('Simpan & Sambung'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Text('$label:', style: const TextStyle(fontSize: 12, color: C.t3)),
        const SizedBox(width: 8),
        Text(value, style: const TextStyle(fontSize: 12, color: C.t1)),
      ],
    ),
  );

  Widget _colorTile(String label, String target, VoidCallback refresh) =>
      Expanded(
        child: GestureDetector(
          onTap: _mqttConnected
              ? () => _showColorPicker(target, label, refresh)
              : null,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: C.bg2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: C.line),
            ),
            child: Column(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: _espColors[target] ?? Colors.grey,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                const SizedBox(height: 5),
                Text(label, style: const TextStyle(fontSize: 8.5, color: C.t2)),
              ],
            ),
          ),
        ),
      );

  Future<void> _saveSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('demo_mode', _demo);
    } catch (e) {
      debugPrint('Pengaturan gagal disimpan: $e');
    }
  }
}

// =============================================================
//  BARIS WAKTU PEMBARUAN
// =============================================================
class _LiveFooter extends StatefulWidget {
  final DateTime? lastUpdate;
  final bool stale;
  final String mqttStatus;
  const _LiveFooter({
    required this.lastUpdate,
    required this.stale,
    required this.mqttStatus,
  });

  @override
  State<_LiveFooter> createState() => _LiveFooterState();
}

class _LiveFooterState extends State<_LiveFooter> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 2) return 'barusan';
    if (d.inSeconds < 60) return '${d.inSeconds} detik lalu';
    if (d.inMinutes < 60) return '${d.inMinutes} menit lalu';
    if (d.inHours < 24) return '${d.inHours} jam lalu';
    return '${d.inDays} hari lalu';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.lastUpdate;
    final line1 = t == null
        ? 'Belum ada data dari alat'
        : 'Diperbarui ${_ago(t)}';
    final line2 = widget.stale
        ? 'Angka di atas adalah pembacaan tersimpan'
        : 'MQTT: ${widget.mqttStatus}';

    return SizedBox(
      height: kFooterH,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            line1,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: C.t3),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 14,
            child: Text(
              line2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: widget.stale ? C.warn : C.t3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================
//  KARTU SENSOR
// =============================================================
class _SensorCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final int decimals;
  final String unit;
  final Color accent;
  final double min;
  final double max;
  final bool alert;
  final bool dimmed;
  final String badge;

  const _SensorCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.decimals,
    required this.unit,
    required this.accent,
    required this.min,
    required this.max,
    this.alert = false,
    this.dimmed = false,
    this.badge = '',
  });

  @override
  Widget build(BuildContext context) {
    final tone = alert ? C.danger : accent;
    final ratio = value <= 0
        ? 0.0
        : ((value - min) / (max - min)).clamp(0.0, 1.0).toDouble();

    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: cardDeco(glow: alert ? C.danger : null),
        child: Column(
          children: [
            SizedBox(
              height: kCardHeaderH,
              child: Row(
                children: [
                  Icon(icon, color: tone, size: 18),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: C.t2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: ratio),
                          duration: const Duration(milliseconds: 700),
                          curve: Curves.easeOutCubic,
                          builder: (_, v, __) =>
                              CustomPaint(painter: _GaugePainter(v, tone)),
                        ),
                      ),
                      Positioned.fill(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: TweenAnimationBuilder<double>(
                                tween: Tween(begin: 0, end: value),
                                duration: const Duration(milliseconds: 700),
                                curve: Curves.easeOut,
                                builder: (_, v, __) => Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Text(
                                      value <= 0
                                          ? '--'
                                          : v.toStringAsFixed(decimals),
                                      maxLines: 1,
                                      style: _numStyle.copyWith(
                                        fontSize: 26,
                                        color: tone,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: Text(
                                        unit,
                                        maxLines: 1,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: C.t3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              height: kCardBadgeH,
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedOpacity(
                  opacity: badge.isEmpty ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: tone.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      badge.isEmpty ? ' ' : badge,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: tone,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================
//  GAUGE PAINTER
// =============================================================
class _GaugePainter extends CustomPainter {
  final double ratio;
  final Color tone;
  _GaugePainter(this.ratio, this.tone);

  static const _start = math.pi * 0.75;
  static const _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final radius = side / 2 - 4;
    if (radius <= 0) return;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: radius,
    );

    canvas.drawArc(
      rect,
      _start,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withOpacity(0.07),
    );

    if (ratio <= 0) return;

    canvas.drawArc(
      rect,
      _start,
      _sweep * ratio,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = tone,
    );
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.ratio != ratio || old.tone != tone;
}

// =============================================================
//  CHART PAINTER
// =============================================================
class _ChartPainter extends CustomPainter {
  final List<double> data;
  final Color color;
  final double minValue;
  final double maxValue;

  _ChartPainter({
    required this.data,
    required this.color,
    required this.minValue,
    required this.maxValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2 || size.height <= 0 || size.width <= 0) return;

    final rawMin = data.reduce(math.min);
    final rawMax = data.reduce(math.max);
    final pad = math.max(2.0, (rawMax - rawMin) * 0.15);
    final minV = math.min(minValue, rawMin - pad);
    final maxV = math.max(maxValue, rawMax + pad);
    final range = (maxV - minV) < 1 ? 1.0 : (maxV - minV);

    double yOf(num v) => size.height - ((v - minV) / range) * size.height;

    final grid = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final dx = size.width / (data.length - 1);
    final pts = <Offset>[
      for (int i = 0; i < data.length; i++) Offset(dx * i, yOf(data[i])),
    ];

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (int i = 0; i < pts.length - 1; i++) {
      final p0 = i == 0 ? pts[0] : pts[i - 1];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = (i + 2 < pts.length) ? pts[i + 2] : p2;

      final c1 = Offset(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
      );
      final c2 = Offset(
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
      );
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.3), color.withOpacity(0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.4
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    final last = pts.last;
    canvas.drawCircle(last, 8, Paint()..color = color.withOpacity(0.18));
    canvas.drawCircle(last, 4, Paint()..color = color);
    canvas.drawCircle(
      last,
      4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withOpacity(0.85),
    );
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.data.length != data.length ||
      (data.isNotEmpty && old.data.isNotEmpty && old.data.last != data.last);
}
