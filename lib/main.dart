import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
  runApp(const RCCarApp());
}

class RCCarApp extends StatelessWidget {
  const RCCarApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const ControlScreen(),
    );
  }
}

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});
  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  // --- Control Variables ---
  double _steeringAngle = 0.0;
  double _throttleRaw = 0.0;
  double _trimValue = 0.0;

  bool _showTrimSlider = false;
  int _headlightStage = 0; 
  bool _parkingLightsOn = false;
  bool _spoilerUp = false;
  bool _isBraking = false;

  // --- S1, S2, S3 & Auto Variables ---
  bool _s1Active = false;
  bool _s2Active = false;
  bool _s3Active = false;
  bool _autoActive = false; // Local state only

  // --- Networking Variables ---
  String _espIP = '0.0.0.0'; 
  final int _udpPort = 8888;
  final int _discoveryPort = 8889;
  bool _isConnected = false;
  int _rssi = 0; 
  
  RawDatagramSocket? _controlSocket;
  RawDatagramSocket? _discoverySocket;
  Timer? _connTimeout;
  Timer? _heartbeatTimer;
  bool _blinkState = true;
  Timer? _blinkTimer;

  @override
  void initState() {
    super.initState();
    _loadTrimValue();
    _startDiscovery();
    _setupControlSocket(); 
    
    _heartbeatTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (_espIP != '0.0.0.0') _sendUDP();
    });

    _blinkTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      setState(() { _blinkState = !_blinkState; });
    });
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _blinkTimer?.cancel();
    _connTimeout?.cancel();
    _controlSocket?.close();
    _discoverySocket?.close();
    super.dispose();
  }

  void _startDiscovery() async {
    _discoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _discoveryPort);
    _discoverySocket?.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? dg = _discoverySocket?.receive();
        if (dg != null) {
          String msg = String.fromCharCodes(dg.data);
          if (msg == "ESP_DISCOVERY") {
            setState(() { _espIP = dg.address.address; });
          }
        }
      }
    });
  }

  void _setupControlSocket() async {
    _controlSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _controlSocket?.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? dg = _controlSocket?.receive();
        if (dg != null) {
          String response = String.fromCharCodes(dg.data);
          if (response.startsWith("RSSI:")) {
            setState(() {
              _rssi = int.tryParse(response.split(":")[1]) ?? 0;
              _isConnected = true;
            });
            _connTimeout?.cancel();
            _connTimeout = Timer(const Duration(seconds: 3), () {
              setState(() { _isConnected = false; _rssi = 0; });
            });
          }
        }
      }
    });
  }

  Future<void> _loadTrimValue() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _trimValue = prefs.getDouble('steering_trim') ?? 0.0);
  }

  Future<void> _saveTrimValue(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('steering_trim', value);
  }

  double get throttlePWM {
    if (_isBraking) return 1500.0;
    return (_throttleRaw + 1.0) * 500 + 1000;
  }

  double get displaySpeed => ((throttlePWM - 1500).abs() / 500) * 120;

  double get servoAngle {
    double center = 90.0 + _trimValue;
    double normalizedStick = (_steeringAngle / 2.0).clamp(-1.0, 1.0);
    return (normalizedStick < 0) 
        ? center + (normalizedStick * (center - 68.0))
        : center + (normalizedStick * (112.0 - center));
  }

  // --- UDP SEND LOGIC (Auto state removed) ---
  Future<void> _sendUDP() async {
    if (_controlSocket == null || _espIP == '0.0.0.0') return;
    try {
      String data = "S:${servoAngle.toStringAsFixed(1)},"
                    "T:${throttlePWM.toStringAsFixed(0)},"
                    "L:$_headlightStage,"
                    "P:${_parkingLightsOn ? 1 : 0},"
                    "W:${_spoilerUp ? 1 : 0},"
                    "B:${_isBraking ? 1 : 0},"
                    "S1:${_s1Active ? 1 : 0},"
                    "S2:${_s2Active ? 1 : 0},"
                    "S3:${_s3Active ? 1 : 0}";
      _controlSocket?.send(Uint8List.fromList(data.codeUnits), InternetAddress(_espIP), _udpPort);
    } catch (e) { debugPrint('UDP Error: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    bool leftActive = servoAngle <= 76.0;
    bool rightActive = servoAngle >= 106.0;

    return Scaffold(
      backgroundColor: const Color(0xff1d271d),
      body: Stack(
        children: [
          Positioned(top: 10, left: 10, child: Text("IP: $_espIP", style: const TextStyle(fontSize: 9, color: Colors.white24))),
          
          Positioned(top: 20, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6), decoration: BoxDecoration(color: _isConnected ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2), borderRadius: BorderRadius.circular(20)), child: Text("STEER: ${servoAngle.toStringAsFixed(1)}° | THROTTLE: ${throttlePWM.toStringAsFixed(0)}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))))),
          Positioned(top: 30, left: 60, child: _buildSignalBattery()),

          // ACTION BUTTONS GROUP
          Positioned(
            top: 40, right: 30,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // CIRCULAR BUTTONS COLUMN
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start, 
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildCircularButton(icon: Icons.flight_takeoff, active: _spoilerUp, color: Colors.cyanAccent, onTap: () => setState(() => _spoilerUp = !_spoilerUp)),
                        const SizedBox(width: 12),
                        _buildCircularButton(icon: Icons.warning_amber_rounded, active: _parkingLightsOn, color: Colors.orangeAccent, onTap: () => setState(() => _parkingLightsOn = !_parkingLightsOn)),
                        const SizedBox(width: 12),
                        _buildCircularButton(icon: Icons.highlight, active: _headlightStage > 0, color: _headlightStage == 1 ? Colors.blueAccent : Colors.yellowAccent, onTap: () => setState(() => _headlightStage = (_headlightStage + 1) % 3)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildCircularButton(label: "S1", active: _s1Active, color: Colors.purpleAccent, onTap: () => setState(() => _s1Active = !_s1Active)),
                        const SizedBox(width: 12),
                        _buildCircularButton(label: "S2", active: _s2Active, color: Colors.purpleAccent, onTap: () => setState(() => _s2Active = !_s2Active)),
                        const SizedBox(width: 12),
                        _buildCircularButton(label: "S3", active: _s3Active, color: Colors.purpleAccent, onTap: () => setState(() => _s3Active = !_s3Active)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(width: 15),
                // RECTANGULAR BUTTONS COLUMN (TRIM & AUTO)
                Column(
                  children: [
                    _buildRectButton(
                      label: "TRIM", 
                      active: _showTrimSlider, 
                      onTap: () => setState(() => _showTrimSlider = !_showTrimSlider)
                    ),
                    const SizedBox(height: 12),
                    _buildRectButton(
                      label: "AUTO", 
                      active: _autoActive, 
                      activeColor: Colors.blueAccent,
                      onTap: () => setState(() => _autoActive = !_autoActive)
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (_showTrimSlider) Center(child: _buildTrimPanel()),

          Positioned(
            bottom: 20, left: 0, right: 0, 
            child: Center(
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  CustomPaint(size: const Size(160, 80), painter: SpeedometerPainter(displaySpeed)),
                  Positioned(left: 32, bottom: 12, child: Transform.rotate(angle: pi, child: Icon(Icons.play_arrow, color: (leftActive && _blinkState) ? Colors.greenAccent : Colors.white.withOpacity(0.03), size: 32))),
                  Positioned(right: 32, bottom: 12, child: Icon(Icons.play_arrow, color: (rightActive && _blinkState) ? Colors.greenAccent : Colors.white.withOpacity(0.03), size: 32)),
                  Padding(padding: const EdgeInsets.only(bottom: 5), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(displaySpeed.toStringAsFixed(0), style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: displaySpeed > 90 ? Colors.redAccent : Colors.white)), const Text("M/H", style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold))])),
                ],
              ),
            ),
          ),

          Positioned(bottom: 30, left: 70, child: GestureDetector(onPanUpdate: (details) { setState(() { _steeringAngle += details.delta.dx / 60; _steeringAngle = _steeringAngle.clamp(-2.0, 2.0); }); }, onPanEnd: (_) { setState(() => _steeringAngle = 0.0); }, child: Transform.rotate(angle: _steeringAngle, child: SizedBox(width: 180, height: 180, child: Image.asset('images/steering_wheel.png', fit: BoxFit.contain))))),

          Positioned(
            bottom: 30, 
            right: 80, 
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  onTapDown: (_) => setState(() => _isBraking = true),
                  onTapUp: (_) => setState(() => _isBraking = false),
                  onTapCancel: () => setState(() => _isBraking = false),
                  child: Container(
                    height: 100, width: 60,
                    decoration: BoxDecoration(
                      color: _isBraking ? Colors.red : Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red, width: 2),
                    ),
                    child: const Center(child: Text("BRAKE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white))),
                  ),
                ),
                const SizedBox(width: 20),
                _buildThrottleControl(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRectButton({required String label, required bool active, required VoidCallback onTap, Color activeColor = Colors.greenAccent}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 80, 
        padding: const EdgeInsets.symmetric(vertical: 8), 
        decoration: BoxDecoration(
          color: active ? activeColor.withOpacity(0.2) : Colors.white.withOpacity(0.05), 
          borderRadius: BorderRadius.circular(8), 
          border: Border.all(color: active ? activeColor : Colors.white24, width: 1.5)
        ), 
        child: Center(
          child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14))
        )
      )
    );
  }

  Widget _buildCircularButton({IconData? icon, String? label, required bool active, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.2) : Colors.white.withOpacity(0.05),
          shape: BoxShape.circle,
          border: Border.all(color: active ? color : Colors.white24, width: 1.5)
        ),
        child: Center(
          child: icon != null 
            ? Icon(icon, color: active ? color : Colors.white, size: 20)
            : Text(label ?? "", style: TextStyle(color: active ? color : Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      ),
    );
  }

  Widget _buildTrimPanel() {
    return Container(width: 320, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white10)), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text("STEERING TRIM", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)), Slider(value: _trimValue, min: -15, max: 15, divisions: 300, activeColor: Colors.greenAccent, label: _trimValue.toStringAsFixed(1), onChanged: (val) { setState(() => _trimValue = val); _saveTrimValue(val); }), Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [IconButton(onPressed: () => setState(() => _trimValue = (_trimValue - 0.1).clamp(-15.0, 15.0)), icon: const Icon(Icons.remove, color: Colors.greenAccent)), TextButton(onPressed: () => setState(() => _trimValue = 0.0), child: const Text("RESET")), IconButton(onPressed: () => setState(() => _trimValue = (_trimValue + 0.1).clamp(-15.0, 15.0)), icon: const Icon(Icons.add, color: Colors.greenAccent))])]));
  }

  Widget _buildThrottleControl() {
    return Row(children: [const Column(children: [Text("F", style: TextStyle(color: Colors.greenAccent)), SizedBox(height: 140), Text("R", style: TextStyle(color: Colors.redAccent))]), const SizedBox(width: 15), GestureDetector(onVerticalDragUpdate: (details) { setState(() { _throttleRaw -= details.delta.dy / 100; _throttleRaw = _throttleRaw.clamp(-1.0, 1.0); }); }, onVerticalDragEnd: (_) { setState(() => _throttleRaw = 0.0); }, child: Container(height: 205, width: 50, decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white10, width: 2)), child: Stack(alignment: Alignment.center, children: [Positioned(bottom: _throttleRaw >= 0 ? 100 : 100 + (_throttleRaw * 100), child: Container(width: 50, height: (_throttleRaw.abs() * 100), color: _throttleRaw >= 0 ? Colors.greenAccent.withOpacity(0.3) : Colors.redAccent.withOpacity(0.3))), Container(height: 1, width: 50, color: Colors.white24), Positioned(bottom: 85 + (_throttleRaw * 85), child: Container(width: 46, height: 30, decoration: BoxDecoration(color: _throttleRaw >= 0 ? Colors.greenAccent : Colors.redAccent, borderRadius: BorderRadius.circular(4)), child: const Icon(Icons.unfold_more, color: Colors.black87)))])))]);
  }

  Widget _buildSignalBattery() {
    int percentage = ((_rssi + 100) * 2).clamp(0, 100);
    Color color = percentage > 60 ? Colors.greenAccent : percentage > 30 ? Colors.orangeAccent : Colors.redAccent;
    return Row(children: [Icon(Icons.wifi, color: color, size: 20), const SizedBox(width: 5), Text(_isConnected ? "$percentage%" : "OFFLINE", style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold))]);
  }
}

class SpeedometerPainter extends CustomPainter {
  final double speed;
  SpeedometerPainter(this.speed);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height);
    final rect = Rect.fromCircle(center: center, radius: size.width * 0.5);
    final trackPaint = Paint()..color = Colors.white10..style = PaintingStyle.stroke..strokeWidth = 10..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 3.14, 3.14, false, trackPaint);
    final progressPaint = Paint()..color = speed > 90 ? Colors.redAccent : Colors.greenAccent..style = PaintingStyle.stroke..strokeWidth = 10..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 3.14, (speed / 120) * 3.14, false, progressPaint);
  }
  @override bool shouldRepaint(SpeedometerPainter oldDelegate) => oldDelegate.speed != speed;
}