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
  // Control Variables
  double _steeringAngle = 0.0;
  double _throttleRaw = 0.0;
  double _trimValue = 0.0;

  // Toggle States
  bool _showTrimSlider = false;
  int _headlightStage = 0; 
  bool _parkingLightsOn = false;

  // Connection & Signal
  final String _espIP = '192.168.196.77';
  final int _udpPort = 8888;
  bool _isConnected = false;
  int _rssi = 0; 
  RawDatagramSocket? _socket;
  Timer? _connTimeout;
  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    _loadTrimValue();
    _setupSocket(); 
    
    // Heartbeat: Keeps the signal alive even when car is idling
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_socket != null) _sendUDP();
    });
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _connTimeout?.cancel();
    _socket?.close();
    super.dispose();
  }

  void _setupSocket() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket?.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? dg = _socket?.receive();
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

  double get throttlePWM => (_throttleRaw + 1.0) * 500 + 1000;
  double get displaySpeed => ((throttlePWM - 1500).abs() / 500) * 120;

  double get servoAngle {
    double center = 90.0 + _trimValue;
    double normalizedStick = (_steeringAngle / 2.0).clamp(-1.0, 1.0);
    return (normalizedStick < 0) 
        ? center + (normalizedStick * (center - 68.0))
        : center + (normalizedStick * (112.0 - center));
  }

  Future<void> _sendUDP() async {
    if (_socket == null) return;
    try {
      String data = "S:${servoAngle.toStringAsFixed(1)},T:${throttlePWM.toStringAsFixed(0)},L:$_headlightStage,P:${_parkingLightsOn ? 1 : 0}";
      final messageBytes = Uint8List.fromList(data.codeUnits);
      _socket?.send(messageBytes, InternetAddress(_espIP), _udpPort);
    } catch (e) { debugPrint('UDP Error: $e'); }
  }

  // --- Visual Signal Battery with Percentage ---
  Widget _buildSignalBattery() {
    IconData batteryIcon;
    Color signalColor;
    
    // Convert RSSI to Percentage (roughly -100 to -50 range)
    int percentage = ((_rssi + 100) * 2).clamp(0, 100);
    if (!_isConnected) percentage = 0;

    if (!_isConnected || _rssi == 0) {
      batteryIcon = Icons.battery_0_bar;
      signalColor = Colors.redAccent;
    } else if (_rssi > -60) {
      batteryIcon = Icons.battery_full;
      signalColor = Colors.greenAccent;
    } else if (_rssi > -75) {
      batteryIcon = Icons.battery_4_bar;
      signalColor = Colors.greenAccent;
    } else {
      batteryIcon = Icons.battery_1_bar;
      signalColor = Colors.orangeAccent;
    }

    return Row(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Transform.rotate(
              angle: 1.5708,
              child: Icon(batteryIcon, size: 45, color: signalColor.withOpacity(0.5)),
            ),
            Text(
              "$percentage%",
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        const SizedBox(width: 8),
        Text(_isConnected ? "CONNECTED" : "OFFLINE", 
            style: TextStyle(color: signalColor, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
      ],
    );
  }

  Widget _buildTrimStepButton({required IconData icon, required VoidCallback onPressed}) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
        child: Icon(icon, color: Colors.greenAccent, size: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff1d271d),
      body: Stack(
        children: [
          Positioned(top: 20, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6), decoration: BoxDecoration(color: _isConnected ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2), borderRadius: BorderRadius.circular(20)), child: Text("STEER: ${servoAngle.toStringAsFixed(1)}° | THROTTLE: ${throttlePWM.toStringAsFixed(0)}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))))),
          
          Positioned(top: 30, left: 60, child: _buildSignalBattery()),

          Positioned(
            top: 40, right: 30,
            child: Row(
              children: [
                GestureDetector(onTap: () { setState(() => _parkingLightsOn = !_parkingLightsOn); _sendUDP(); }, child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: _parkingLightsOn ? Colors.orangeAccent.withOpacity(0.2) : Colors.white.withOpacity(0.05), shape: BoxShape.circle, border: Border.all(color: _parkingLightsOn ? Colors.orangeAccent : Colors.white24, width: 1.5)), child: Icon(Icons.warning_amber_rounded, color: _parkingLightsOn ? Colors.orangeAccent : Colors.white, size: 20))),
                const SizedBox(width: 12),
                GestureDetector(onTap: () { setState(() => _headlightStage = (_headlightStage + 1) % 3); _sendUDP(); }, child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: _headlightStage == 0 ? Colors.white.withOpacity(0.05) : _headlightStage == 1 ? Colors.blueAccent.withOpacity(0.2) : Colors.yellowAccent.withOpacity(0.2), shape: BoxShape.circle, border: Border.all(color: _headlightStage == 0 ? Colors.white24 : _headlightStage == 1 ? Colors.blueAccent : Colors.yellowAccent, width: 1.5)), child: Icon(Icons.highlight, color: _headlightStage == 0 ? Colors.white : _headlightStage == 1 ? Colors.blueAccent : Colors.yellowAccent, size: 20))),
                const SizedBox(width: 15),
                GestureDetector(onTap: () => setState(() => _showTrimSlider = !_showTrimSlider), child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), decoration: BoxDecoration(color: _showTrimSlider ? Colors.greenAccent.withOpacity(0.2) : Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: _showTrimSlider ? Colors.greenAccent : Colors.white24, width: 1.5)), child: const Text("TRIM", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14)))),
              ],
            ),
          ),

          if (_showTrimSlider) Center(child: Container(width: 320, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white10)), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text("STEERING TRIM", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)), Row(children: [const Text("-15", style: TextStyle(fontSize: 10, color: Colors.white38)), Expanded(child: Slider(value: _trimValue, min: -15, max: 15, divisions: 300, activeColor: Colors.greenAccent, label: _trimValue.toStringAsFixed(1), onChanged: (val) { setState(() => _trimValue = val); _saveTrimValue(val); _sendUDP(); })), const Text("+15", style: TextStyle(fontSize: 10, color: Colors.white38))]), Text("Current Offset: ${_trimValue > 0 ? '+' : ''}${_trimValue.toStringAsFixed(1)}°", style: const TextStyle(color: Colors.greenAccent, fontSize: 12)), const SizedBox(height: 15), Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_buildTrimStepButton(icon: Icons.remove, onPressed: () { setState(() => _trimValue = (_trimValue - 0.1).clamp(-15.0, 15.0)); _saveTrimValue(_trimValue); _sendUDP(); }), TextButton(style: TextButton.styleFrom(backgroundColor: Colors.white10, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))), onPressed: () { setState(() => _trimValue = 0.0); _saveTrimValue(0.0); _sendUDP(); }, child: const Text("RESET TO 0.0°", style: TextStyle(color: Colors.white, fontSize: 10))), _buildTrimStepButton(icon: Icons.add, onPressed: () { setState(() => _trimValue = (_trimValue + 0.1).clamp(-15.0, 15.0)); _saveTrimValue(_trimValue); _sendUDP(); })])]))),

          Positioned(bottom: 20, left: 0, right: 0, child: Center(child: Stack(alignment: Alignment.bottomCenter, children: [CustomPaint(size: const Size(160, 80), painter: SpeedometerPainter(displaySpeed)), Padding(padding: const EdgeInsets.only(bottom: 5), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(displaySpeed.toStringAsFixed(0), style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: displaySpeed > 90 ? Colors.redAccent : Colors.white)), const Text("M/H", style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold))]))]))),

          Positioned(bottom: 30, left: 70, child: Column(children: [const Text("STEERING", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)), const SizedBox(height: 10), GestureDetector(onPanUpdate: (details) { setState(() { _steeringAngle += details.delta.dx / 60; _steeringAngle = _steeringAngle.clamp(-2.0, 2.0); }); _sendUDP(); }, onPanEnd: (_) { setState(() => _steeringAngle = 0.0); _sendUDP(); }, child: Transform.rotate(angle: _steeringAngle, child: SizedBox(width: 180, height: 180, child: Image.asset('images/steering_wheel.png', fit: BoxFit.contain))))])),

          Positioned(bottom: 30, right: 80, child: Column(children: [const Text(" THROTTLE", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)), const SizedBox(height: 10), Row(crossAxisAlignment: CrossAxisAlignment.center, children: [const Column(children: [Text("F", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)), SizedBox(height: 140), Text("R", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))]), const SizedBox(width: 15), GestureDetector(onVerticalDragUpdate: (details) { setState(() { _throttleRaw -= details.delta.dy / 100; _throttleRaw = _throttleRaw.clamp(-1.0, 1.0); }); _sendUDP(); }, onVerticalDragEnd: (_) { setState(() => _throttleRaw = 0.0); _sendUDP(); }, child: Container(height: 205, width: 50, decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white10, width: 2)), child: Stack(alignment: Alignment.center, children: [Positioned(bottom: _throttleRaw >= 0 ? 100 : 100 + (_throttleRaw * 100), child: Container(width: 50, height: (_throttleRaw.abs() * 100), color: _throttleRaw >= 0 ? Colors.greenAccent.withOpacity(0.3) : Colors.redAccent.withOpacity(0.3))), Container(height: 1, width: 50, color: Colors.white24), Positioned(bottom: 85 + (_throttleRaw * 85), child: Container(width: 46, height: 30, decoration: BoxDecoration(color: _throttleRaw >= 0 ? Colors.greenAccent : Colors.redAccent, borderRadius: BorderRadius.circular(4)), child: const Icon(Icons.unfold_more, color: Colors.black87)))])))])])),
        ],
      ),
    );
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