import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  double _steeringAngle = 0.0; 
  double _throttleRaw = 0.0;   
  
  final String _espIP = '192.168.196.77';
  final int _udpPort = 8888;
  bool _isConnected = false;

  // PWM Calculation (1000 - 2000)
  double get throttlePWM => (_throttleRaw + 1.0) * 500 + 1000;
  double get displaySpeed => ((throttlePWM - 1500).abs() / 500) * 120;

  // ✅ NEW: Perfect servo angle remapping
  // -2.0 → 68° (90-22), 0→90°, +2.0→112° (90+22)
  double get servoAngle => 90.0 + (_steeringAngle * 11.0);

  Future<void> _sendUDP() async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // ✅ FIXED: Send REMAPPED servo angle (68-112°)
      String data = "S:${servoAngle.toStringAsFixed(0)},T:${throttlePWM.toStringAsFixed(0)}";
      final messageBytes = Uint8List.fromList(data.codeUnits);
      int bytesSent = socket.send(messageBytes, InternetAddress(_espIP), _udpPort);
      
      if (bytesSent > 0) {
        if (!_isConnected) {
          setState(() => _isConnected = true);
        }
      }
    } catch (e) {
      debugPrint('UDP Error: $e');
      setState(() => _isConnected = false);
    } finally {
      socket?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff1d271d), 
      body: Stack(
        children: [
          // 1. TOP INFO BAR (Shows BOTH raw + servo angle)
          Positioned(
            top: 20,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
                decoration: BoxDecoration(
                  color: _isConnected ? Colors.green.withOpacity(0.3) : Colors.red.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_isConnected ? Icons.wifi : Icons.wifi_off, size: 14, color: Colors.white),
                    const SizedBox(width: 5),
                    Text(
                      "${_isConnected ? "CONN" : "DISCONN"} UDP:$_espIP:$_udpPort | S:${_steeringAngle.toStringAsFixed(1)}°(${servoAngle.toStringAsFixed(0)}°) T:${throttlePWM.toStringAsFixed(0)}",
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 2. CENTERED SPEEDOMETER (Fixed pi → 3.14)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    CustomPaint(
                      size: const Size(160, 80),
                      painter: SpeedometerPainter(displaySpeed),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displaySpeed.toStringAsFixed(0),
                            style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w900,
                                color: displaySpeed > 90 ? Colors.redAccent : Colors.white),
                          ),
                          Text(
                            "M/H",
                            style: TextStyle(
                                color: displaySpeed > 90 ? Colors.redAccent : Colors.white54,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 3. STEERING WHEEL (YOUR EXACT SETTINGS - UNCHANGED)
          Positioned(
            bottom: 30,
            left: 70,
            child: Column(
              children: [
                const Text("STEERING", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                GestureDetector(
                  onPanUpdate: (details) async {
                    setState(() {
                      _steeringAngle += details.delta.dx / 60;
                      _steeringAngle = _steeringAngle.clamp(-2.0, 2.0);
                    });
                    await _sendUDP();
                  },
                  onPanEnd: (_) async {
                    setState(() => _steeringAngle = 0.0);
                    await _sendUDP();
                  },
                  child: Transform.rotate(
                    angle: _steeringAngle,
                    child: SizedBox(
                      width: 180,
                      height: 180,
                      child: Image.asset('images/steering_wheel.png', fit: BoxFit.contain),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 4. THROTTLE CONTROL (UNCHANGED)
          Positioned(
            bottom: 30,
            right: 80,
            child: Column(
              children: [
                const Text(" THROTTLE", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Column(
                      children: [
                        Text("F", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                        SizedBox(height: 140),
                        Text("R", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(width: 15),
                    GestureDetector(
                      onVerticalDragUpdate: (details) async {
                        setState(() {
                          _throttleRaw -= details.delta.dy / 100;
                          _throttleRaw = _throttleRaw.clamp(-1.0, 1.0);
                        });
                        await _sendUDP();
                      },
                      onVerticalDragEnd: (_) async {
                        setState(() => _throttleRaw = 0.0);
                        await _sendUDP();
                      },
                      child: Container(
                        height: 205,
                        width: 50,
                        decoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white10, width: 2),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned(
                              bottom: _throttleRaw >= 0 ? 100 : 100 + (_throttleRaw * 100),
                              child: Container(
                                width: 50,
                                height: (_throttleRaw.abs() * 100),
                                color: _throttleRaw >= 0 
                                    ? Colors.greenAccent.withOpacity(0.3) 
                                    : Colors.redAccent.withOpacity(0.3),
                              ),
                            ),
                            Container(height: 1, width: 50, color: Colors.white24),
                            Positioned(
                              bottom: 85 + (_throttleRaw * 85),
                              child: Container(
                                width: 46,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: _throttleRaw >= 0 ? Colors.greenAccent : Colors.redAccent,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(Icons.unfold_more, color: Colors.black87),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// SpeedometerPainter (Fixed pi → 3.14)
class SpeedometerPainter extends CustomPainter {
  final double speed;
  SpeedometerPainter(this.speed);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height);
    final radius = size.width * 0.5;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 3.14, 3.14, false, trackPaint);  // Fixed: pi → 3.14

    final progressPaint = Paint()
      ..color = speed > 90 ? Colors.redAccent : Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    
    double sweepAngle = (speed / 120) * 3.14;  // Fixed: pi → 3.14
    canvas.drawArc(rect, 3.14, sweepAngle, false, progressPaint);
  }

  @override
  bool shouldRepaint(SpeedometerPainter oldDelegate) => oldDelegate.speed != speed;
}
