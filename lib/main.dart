import 'dart:io';
import 'dart:convert';
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
  double _steeringAngle = 0.0; // In radians (-3 to 3)
  double _throttleValue = 0.0; // -1.0 to 1.0

  // UDP SETTINGS (SAME AS HELLO APP)
  final String _espIP = '192.168.4.1';
  final int _udpPort = 8888;
  String _status = 'Connect to ESP32-AP WiFi first';

  // 🚀 UDP SEND FUNCTION (IDENTICAL TO HELLO APP)
  Future<void> _sendUDP() async {
    RawDatagramSocket? socket;
    try {
      // CREATE NEW SOCKET (like Hello app)
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      
      // FORMAT: "S:-1.23,T:0.45" (same parsing on ESP32)
      String data = "S:${_steeringAngle.toStringAsFixed(2)},T:${_throttleValue.toStringAsFixed(2)}";
      final messageBytes = Uint8List.fromList(data.codeUnits);
      
      // SEND UDP (EXACT Hello app method)
      int bytesSent = socket.send(messageBytes, InternetAddress(_espIP), _udpPort);
      
      print('UDP sent $bytesSent bytes: $data'); // Debug
      
    } catch (e) {
      print('UDP Error: $e');
    } finally {
      socket?.close(); // CLOSE SOCKET (like Hello app)
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff1d271d),
      body: Stack(
        children: [
          // 1. TOP BAR (Status Info) - ADDED UDP STATUS
          Positioned(
            top: 15,
            left: 20,
            right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("UDP: $_espIP:$_udpPort | S:${_steeringAngle.toStringAsFixed(1)} T:${_throttleValue.toStringAsFixed(1)}",
                    style: const TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold, fontSize: 12)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
                  color: Colors.yellow,
                  child: const Text("KILL SWITCH",
                      style: TextStyle(
                          color: Colors.black, fontWeight: FontWeight.w900)),
                ),
                const CircleAvatar(
                    backgroundColor: Colors.red,
                    radius: 20,
                    child: Text("STOP",
                        style: TextStyle(fontSize: 10, color: Colors.white))),
              ],
            ),
          ),

          // 2. LEFT SIDE (Steering Wheel) - ADDED UDP SEND
          Positioned(
            bottom: 40,
            left: 60,
            child: Column(
              children: [
                const Text("STEERING",
                    style: TextStyle(color: Colors.white54, letterSpacing: 1.5)),
                const SizedBox(height: 15),
                GestureDetector(
                  onPanUpdate: (details) async {
                    setState(() {
                      _steeringAngle += details.delta.dx / 50;
                      _steeringAngle = _steeringAngle.clamp(-3.0, 3.0);
                    });
                    // 🚀 SEND UDP ON EVERY MOVE (Hello app method)
                    await _sendUDP();
                  },
                  onPanEnd: (_) async {
                    setState(() => _steeringAngle = 0.0);
                    // 🚀 SEND UDP ON RELEASE
                    await _sendUDP();
                  },
                  child: Transform.rotate(
                    angle: _steeringAngle,
                    child: SizedBox(
                      width: 200,
                      height: 200,
                      child: Image.asset('images/steering_wheel.png',
                          fit: BoxFit.contain),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 3. RIGHT SIDE (Throttle Slider) - ADDED UDP SEND
          Positioned(
            bottom: 40,
            right: 60,
            child: Column(
              children: [
                const Text("THROTTLE",
                    style: TextStyle(
                        color: Colors.white54, fontWeight: FontWeight.bold)),
                const SizedBox(height: 15),
                Row(
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text("F",
                            style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                        SizedBox(height: 140),
                        Text("R",
                            style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(width: 15),
                    GestureDetector(
                      onVerticalDragUpdate: (details) async {
                        setState(() {
                          _throttleValue -= details.delta.dy / 100;
                          _throttleValue = _throttleValue.clamp(-1.0, 1.0);
                        });
                        // 🚀 SEND UDP ON EVERY MOVE (Hello app method)
                        await _sendUDP();
                      },
                      onVerticalDragEnd: (_) async {
                        setState(() => _throttleValue = 0.0);
                        // 🚀 SEND UDP ON RELEASE
                        await _sendUDP();
                      },
                      child: Container(
                        height: 200,
                        width: 55,
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          border: Border.all(color: Colors.white24, width: 2),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Fill Bar logic
                            Positioned(
                              bottom: _throttleValue >= 0
                                  ? 100
                                  : 100 + (_throttleValue * 100),
                              child: Container(
                                width: 55,
                                height: (_throttleValue.abs() * 100),
                                color: _throttleValue >= 0
                                    ? Colors.greenAccent.withOpacity(0.4)
                                    : Colors.redAccent.withOpacity(0.4),
                              ),
                            ),
                            Container(
                                height: 2, width: 55, color: Colors.white38),
                            // Rectangular Handle
                            Positioned(
                              bottom: 87.5 + (_throttleValue * 87.5),
                              child: Container(
                                width: 51,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: _throttleValue >= 0
                                      ? Colors.greenAccent
                                      : Colors.redAccent,
                                  border: Border.all(color: Colors.black26),
                                ),
                                child: const Icon(Icons.unfold_more,
                                    color: Colors.black54),
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
