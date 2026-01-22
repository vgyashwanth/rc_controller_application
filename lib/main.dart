import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
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
  double _steeringAngle = 0.0; 
  double _throttleRaw = 0.0;   
  
  bool _showTrimSlider = false;
  double _trimValue = 0.0; 

  final String _espIP = '192.168.196.77';
  final int _udpPort = 8888;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    _loadTrimValue();
  }

  Future<void> _loadTrimValue() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _trimValue = prefs.getDouble('steering_trim') ?? 0.0;
    });
  }

  Future<void> _saveTrimValue(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('steering_trim', value);
  }

  double get throttlePWM => (_throttleRaw + 1.0) * 500 + 1000;
  double get displaySpeed => ((throttlePWM - 1500).abs() / 500) * 120;

  double get servoAngle {
    double center = 90.0 + _trimValue;
    const double minLimit = 68.0;
    const double maxLimit = 112.0;

    double normalizedStick = (_steeringAngle / 2.0).clamp(-1.0, 1.0);

    if (normalizedStick < 0) {
      return center + (normalizedStick * (center - minLimit));
    } else {
      return center + (normalizedStick * (maxLimit - center));
    }
  }

  Future<void> _sendUDP() async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      String data = "S:${servoAngle.toStringAsFixed(1)},T:${throttlePWM.toStringAsFixed(0)}";
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
          // 1. TOP INFO BAR
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
                  const SizedBox(width: 8), // Slightly more breathing room
                  Text(
                    "STEER: ${servoAngle.toStringAsFixed(1)}° | THROTTLE: ${throttlePWM.toStringAsFixed(0)}",
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

          // TRIM BUTTON
          Positioned(
            top: 40,
            right: 30,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _showTrimSlider = !_showTrimSlider;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  color: _showTrimSlider ? Colors.greenAccent.withOpacity(0.2) : Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _showTrimSlider ? Colors.greenAccent : Colors.white24, 
                    width: 1.5
                  ),
                ),
                child: Text(
                  "TRIM",
                  style: TextStyle(
                    color: _showTrimSlider ? Colors.greenAccent : Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          ),

          if (_showTrimSlider)
            Center(
              child: Container(
                width: 320,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("STEERING TRIM", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text("-15", style: TextStyle(fontSize: 10)),
                        Expanded(
                          child: Slider(
                            value: _trimValue,
                            min: -15,
                            max: 15,
                            divisions: 300, // ✅ Changed from 60 to 300 for 0.1 degree steps
                            activeColor: Colors.greenAccent,
                            label: _trimValue.toStringAsFixed(1),
                            onChanged: (val) {
                              setState(() => _trimValue = val);
                              _saveTrimValue(val);
                              _sendUDP();
                            },
                          ),
                        ),
                        const Text("+15", style: TextStyle(fontSize: 10)),
                      ],
                    ),
                    Text(
                      "Current Offset: ${_trimValue > 0 ? '+' : ''}${_trimValue.toStringAsFixed(1)}°",
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

          // 2. CENTERED SPEEDOMETER
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

          // 3. STEERING WHEEL
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

          // 4. THROTTLE CONTROL
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
    canvas.drawArc(rect, 3.14, 3.14, false, trackPaint); 

    final progressPaint = Paint()
      ..color = speed > 90 ? Colors.redAccent : Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    
    double sweepAngle = (speed / 120) * 3.14;  
    canvas.drawArc(rect, 3.14, sweepAngle, false, progressPaint);
  }

  @override
  bool shouldRepaint(SpeedometerPainter oldDelegate) => oldDelegate.speed != speed;
}