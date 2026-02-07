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

class _ControlScreenState extends State<ControlScreen> with SingleTickerProviderStateMixin {
  // --- Control & UI Variables ---
  double _steeringAngle = 0.0;
  double _throttleRaw = 0.0; 
  double _trimValue = 0.0;
  
  // Updated: Steering Limit Variables with wider range
  double _leftLimit = 68.0;   
  double _rightLimit = 112.0; 
  bool _showTrimSlider = false;
  bool _showLimitSlider = false; 

  int _headlightStage = 0; 
  bool _parkingLightsOn = false;
  bool _spoilerUp = false;
  bool _isBraking = false;
  bool _isReversing = false; 
  bool _s1Active = false;
  bool _s2Active = false;
  bool _s3Active = false;
  bool _autoActive = false; 

  // --- Nitro Logic ---
  int _nitroStage = 0; 
  double _animatedNitroPWM = 1500.0;
  Timer? _initialDelayTimer; 
  Timer? _continuousDropTimer; 
  late AnimationController _nitroController;
  late Animation<double> _nitroAnimation;

  // --- Networking & Signal Indicator ---
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
    _loadSettings();
    _startDiscovery();
    _setupControlSocket(); 

    _nitroController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _nitroAnimation = Tween<double>(begin: 1500.0, end: 1500.0).animate(_nitroController)
      ..addListener(() { setState(() { _animatedNitroPWM = _nitroAnimation.value; }); });
    
    _heartbeatTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (_espIP != '0.0.0.0') _sendUDP();
    });

    _blinkTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      setState(() { _blinkState = !_blinkState; });
    });
  }

  @override
  void dispose() {
    _nitroController.dispose();
    _heartbeatTimer?.cancel();
    _blinkTimer?.cancel();
    _connTimeout?.cancel();
    _initialDelayTimer?.cancel();
    _continuousDropTimer?.cancel();
    _controlSocket?.close();
    _discoverySocket?.close();
    super.dispose();
  }

  // --- PERSISTENCE ---
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _trimValue = prefs.getDouble('steering_trim') ?? 0.0;
      _leftLimit = prefs.getDouble('left_limit') ?? 68.0;
      _rightLimit = prefs.getDouble('right_limit') ?? 112.0;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('steering_trim', _trimValue);
    await prefs.setDouble('left_limit', _leftLimit);
    await prefs.setDouble('right_limit', _rightLimit);
  }

  // --- NITRO LOGIC ---
  void _increaseNitro() {
    int cap = _isReversing ? 2 : 5;
    if (_nitroStage < cap) {
      _nitroStage++;
      double targetPWM = _isReversing 
          ? 1500.0 - (_nitroStage * 100) 
          : 1500.0 + (_nitroStage * 100);
      _animateToPWM(targetPWM);
      setState(() {}); 
    }
  }

  void _decreaseNitro() {
    if (_nitroStage > 0) {
      _nitroStage--;
      double targetPWM = _isReversing 
          ? 1500.0 - (_nitroStage * 100)
          : 1500.0 + (_nitroStage * 100);
      _animateToPWM(targetPWM);
      setState(() {});
    }
  }

  void _animateToPWM(double target) {
    _nitroAnimation = Tween<double>(begin: _animatedNitroPWM, end: target).animate(
      CurvedAnimation(parent: _nitroController, curve: Curves.linear)
    );
    _nitroController.forward(from: 0);
  }

  void _startCooldownLogic() {
    _stopCooldownLogic();
    _initialDelayTimer = Timer(const Duration(seconds: 3), () {
      _continuousDropTimer = Timer.periodic(const Duration(milliseconds: 550), (timer) {
        if (_nitroStage > 0) { _decreaseNitro(); } else { timer.cancel(); }
      });
    });
  }

  void _stopCooldownLogic() {
    _initialDelayTimer?.cancel();
    _continuousDropTimer?.cancel();
  }

  void _emergencyStopNitro() {
    _nitroStage = 0;
    _animateToPWM(1500.0);
    _stopCooldownLogic();
    setState(() {});
  }

  // --- NETWORKING ---
  void _startDiscovery() async {
    _discoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _discoveryPort);
    _discoverySocket?.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? dg = _discoverySocket?.receive();
        if (dg != null) {
          String msg = String.fromCharCodes(dg.data);
          if (msg == "ESP_DISCOVERY") setState(() => _espIP = dg.address.address);
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

  double get throttlePWM {
    if (_isBraking) return 1500.0;
    if (_autoActive) return _animatedNitroPWM;
    return (_throttleRaw + 1.0) * 500 + 1000;
  }

  double get displaySpeed => ((throttlePWM - 1500).abs() / 500) * 120;

  double get servoAngle {
    double center = 90.0 + _trimValue;
    double normalizedStick = (_steeringAngle / 2.0).clamp(-1.0, 1.0);
    
    return (normalizedStick < 0) 
        ? center + (normalizedStick * (center - _leftLimit))
        : center + (normalizedStick * (_rightLimit - center));
  }

  Future<void> _sendUDP() async {
    if (_controlSocket == null || _espIP == '0.0.0.0') return;
    try {
      String data = "S:${servoAngle.toStringAsFixed(1)},T:${throttlePWM.toStringAsFixed(0)},L:$_headlightStage,P:${_parkingLightsOn ? 1 : 0},W:${_spoilerUp ? 1 : 0},B:${_isBraking ? 1 : 0},H:${_s1Active ? 1 : 0},S2:${_s2Active ? 1 : 0},S3:${_s3Active ? 1 : 0}";
      _controlSocket?.send(Uint8List.fromList(data.codeUnits), InternetAddress(_espIP), _udpPort);
    } catch (e) { debugPrint('UDP Error: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    bool leftActive = servoAngle <= (_leftLimit + 8);
    bool rightActive = servoAngle >= (_rightLimit - 8);

    return Scaffold(
      backgroundColor: const Color(0xff1d271d),
      body: Stack(
        children: [
          // TOP LEFT: Signal & Steering Limits Toggle
          Positioned(
            top: 15, left: 15, 
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("IP: $_espIP", style: const TextStyle(fontSize: 9, color: Colors.white24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                _buildSignalIndicator(),
                const SizedBox(height: 10),
                _buildRectButtonSmall(
                  label: "STEERING LIMITS", 
                  active: _showLimitSlider, 
                  onTap: () => setState(() {
                    _showLimitSlider = !_showLimitSlider;
                    if (_showLimitSlider) _showTrimSlider = false;
                  })
                ),
              ],
            ),
          ),

          // TOP CENTER: Telemetry
          Positioned(top: 20, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6), decoration: BoxDecoration(color: _isConnected ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2), borderRadius: BorderRadius.circular(20)), child: Text("PWM: ${throttlePWM.toStringAsFixed(0)} | STEER: ${servoAngle.toStringAsFixed(1)}°", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))))),
          
          // TOP RIGHT: Control Grid
          Positioned(
            top: 40, right: 30,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                        GestureDetector(
                          onTapDown: (_) => setState(() => _s1Active = true),
                          onTapUp: (_) => setState(() => _s1Active = false),
                          onTapCancel: () => setState(() => _s1Active = false),
                          child: _buildCircularButton(icon: Icons.campaign, active: _s1Active, color: Colors.purpleAccent, onTap: () {}),
                        ),
                        const SizedBox(width: 12),
                        _buildCircularButton(label: "S2", active: _s2Active, color: Colors.purpleAccent, onTap: () => setState(() => _s2Active = !_s2Active)),
                        const SizedBox(width: 12),
                        _buildCircularButton(label: "S3", active: _s3Active, color: Colors.purpleAccent, onTap: () => setState(() => _s3Active = !_s3Active)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(width: 15),
                Column(
                  children: [
                    _buildRectButton(label: "TRIM", active: _showTrimSlider, onTap: () => setState(() {
                      _showTrimSlider = !_showTrimSlider;
                      if (_showTrimSlider) _showLimitSlider = false;
                    })),
                    const SizedBox(height: 12),
                    _buildRectButton(label: "AUTO", active: _autoActive, activeColor: Colors.orangeAccent, onTap: () { 
                      setState(() { 
                        _autoActive = !_autoActive; 
                        _isReversing = false; 
                        _emergencyStopNitro(); 
                      }); 
                    }),
                  ],
                ),
              ],
            ),
          ),

          // Center Panels
          if (_showTrimSlider) Center(child: _buildTrimPanel()),
          if (_showLimitSlider) Center(child: _buildLimitPanel()),

          // Speedometer
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

          // Steering Wheel
          Positioned(bottom: 30, left: 70, child: GestureDetector(onPanUpdate: (details) { setState(() { _steeringAngle += details.delta.dx / 60; _steeringAngle = _steeringAngle.clamp(-2.0, 2.0); }); }, onPanEnd: (_) { setState(() => _steeringAngle = 0.0); }, child: Transform.rotate(angle: _steeringAngle, child: SizedBox(width: 180, height: 180, child: Image.asset('images/steering_wheel.png', fit: BoxFit.contain))))),

          // Throttle / Brake / Reverse
          Positioned(
            bottom: 30, 
            right: 80, 
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Column(
                  children: [
                    if (_autoActive)
                      GestureDetector(
                        onTap: () { setState(() { _isReversing = !_isReversing; _emergencyStopNitro(); }); },
                        child: Container(
                          height: 60, width: 60, 
                          decoration: BoxDecoration(color: _isReversing ? Colors.blue : Colors.blue.withOpacity(0.15), borderRadius: BorderRadius.circular(10), border: Border.all(color: _isReversing ? Colors.white : Colors.blue, width: 2)), 
                          child: Center(child: Text("R", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _isReversing ? Colors.white : Colors.blue))),
                        ),
                      ),
                    if (_autoActive) const SizedBox(height: 10),
                    GestureDetector(
                      onTapDown: (_) { setState(() => _isBraking = true); _emergencyStopNitro(); },
                      onTapUp: (_) => setState(() => _isBraking = false),
                      onTapCancel: () => setState(() => _isBraking = false),
                      child: Container(height: 100, width: 60, decoration: BoxDecoration(color: _isBraking ? Colors.red : Colors.red.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.red, width: 2)), child: const Center(child: Text("BRAKE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)))),
                    ),
                  ],
                ),
                const SizedBox(width: 20),
                _autoActive ? _buildNitroTapBar() : _buildThrottleControl(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // LIMIT PANEL: Updated range 45 to 135
  Widget _buildLimitPanel() {
    return Container(
      width: 350, 
      padding: const EdgeInsets.all(20), 
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.9), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.cyanAccent.withOpacity(0.3))), 
      child: Column(
        mainAxisSize: MainAxisSize.min, 
        children: [
          const Text("STEERING LIMITS (EPA)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
          const SizedBox(height: 10),
          Text("MAX LEFT: ${_leftLimit.toStringAsFixed(0)}°", style: const TextStyle(fontSize: 12)),
          Slider(value: _leftLimit, min: 45, max: 85, activeColor: Colors.cyanAccent, onChanged: (val) {
            setState(() => _leftLimit = val);
            _saveSettings();
          }),
          Text("MAX RIGHT: ${_rightLimit.toStringAsFixed(0)}°", style: const TextStyle(fontSize: 12)),
          Slider(value: _rightLimit, min: 95, max: 135, activeColor: Colors.cyanAccent, onChanged: (val) {
            setState(() => _rightLimit = val);
            _saveSettings();
          }),
          TextButton(onPressed: () => setState(() {
             _leftLimit = 68.0; _rightLimit = 112.0; _saveSettings();
          }), child: const Text("RESET DEFAULTS", style: TextStyle(color: Colors.redAccent))),
        ]
      )
    );
  }

  Widget _buildSignalIndicator() {
    int percentage = ((_rssi + 100) * 2).clamp(0, 100);
    Color color = percentage > 60 ? Colors.greenAccent : percentage > 30 ? Colors.orangeAccent : Colors.redAccent;
    return Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.wifi, color: color, size: 16), const SizedBox(width: 5), Text(_isConnected ? "$percentage%" : "OFFLINE", style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold))]);
  }

  Widget _buildNitroTapBar() {
    double fillPercent = ((_animatedNitroPWM - 1500).abs() / 500).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (_) { _stopCooldownLogic(); _increaseNitro(); },
      onPanEnd: (_) { _startCooldownLogic(); },
      onPanCancel: () => _startCooldownLogic(),
      child: Column(
        children: [
          Text("GEAR $_nitroStage", style: TextStyle(color: _isReversing ? Colors.blueAccent : Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold)),
          const SizedBox(height: 5),
          Container(
            height: 205, width: 70,
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12), border: Border.all(color: (_isReversing ? Colors.blueAccent : Colors.orangeAccent).withOpacity(0.5), width: 2)),
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(width: 70, height: 205 * fillPercent, decoration: BoxDecoration(gradient: LinearGradient(colors: _isReversing ? [Colors.blue, Colors.lightBlueAccent] : [Colors.deepOrange, Colors.orangeAccent], begin: Alignment.topCenter, end: Alignment.bottomCenter), borderRadius: BorderRadius.circular(10))),
                Center(child: RotatedBox(quarterTurns: 3, child: Text(_isReversing ? "REV BOOST" : "TAP TO BOOST", style: const TextStyle(letterSpacing: 1, fontWeight: FontWeight.w900, color: Colors.white24)))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRectButton({required String label, required bool active, required VoidCallback onTap, Color activeColor = Colors.greenAccent}) {
    return GestureDetector(onTap: onTap, child: Container(width: 80, padding: const EdgeInsets.symmetric(vertical: 8), decoration: BoxDecoration(color: active ? activeColor.withOpacity(0.2) : Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: active ? activeColor : Colors.white24, width: 1.5)), child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14)))));
  }

  Widget _buildRectButtonSmall({required String label, required bool active, required VoidCallback onTap}) {
    return GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: active ? Colors.cyanAccent.withOpacity(0.2) : Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(4), border: Border.all(color: active ? Colors.cyanAccent : Colors.white10)), child: Text(label, style: TextStyle(color: active ? Colors.cyanAccent : Colors.white38, fontSize: 8, fontWeight: FontWeight.bold))));
  }

  Widget _buildCircularButton({IconData? icon, String? label, required bool active, required Color color, required VoidCallback onTap}) {
    return GestureDetector(onTap: onTap, child: Container(width: 40, height: 40, decoration: BoxDecoration(color: active ? color.withOpacity(0.2) : Colors.white.withOpacity(0.05), shape: BoxShape.circle, border: Border.all(color: active ? color : Colors.white24, width: 1.5)), child: Center(child: icon != null ? Icon(icon, color: active ? color : Colors.white, size: 20) : Text(label ?? "", style: TextStyle(color: active ? color : Colors.white, fontWeight: FontWeight.bold, fontSize: 12)))));
  }

  Widget _buildTrimPanel() {
    return Container(width: 320, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white10)), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text("STEERING TRIM", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)), Slider(value: _trimValue, min: -15, max: 15, divisions: 300, activeColor: Colors.greenAccent, label: _trimValue.toStringAsFixed(1), onChanged: (val) { setState(() => _trimValue = val); _saveSettings(); }), Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [IconButton(onPressed: () => setState(() { _trimValue = (_trimValue - 0.1).clamp(-15.0, 15.0); _saveSettings(); }), icon: const Icon(Icons.remove, color: Colors.greenAccent)), TextButton(onPressed: () => setState(() { _trimValue = 0.0; _saveSettings(); }), child: const Text("RESET")), IconButton(onPressed: () => setState(() { _trimValue = (_trimValue + 0.1).clamp(-15.0, 15.0); _saveSettings(); }), icon: const Icon(Icons.add, color: Colors.greenAccent))])]));
  }

  Widget _buildThrottleControl() {
    return Row(children: [const Column(children: [Text("F", style: TextStyle(color: Colors.greenAccent)), SizedBox(height: 140), Text("R", style: TextStyle(color: Colors.redAccent))]), const SizedBox(width: 15), GestureDetector(onVerticalDragUpdate: (details) { setState(() { _throttleRaw -= details.delta.dy / 100; _throttleRaw = _throttleRaw.clamp(-1.0, 1.0); }); }, onVerticalDragEnd: (_) { setState(() => _throttleRaw = 0.0); }, child: Container(height: 205, width: 50, decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white10, width: 2)), child: Stack(alignment: Alignment.center, children: [Positioned(bottom: _throttleRaw >= 0 ? 100 : 100 + (_throttleRaw * 100), child: Container(width: 50, height: (_throttleRaw.abs() * 100), color: _throttleRaw >= 0 ? Colors.greenAccent.withOpacity(0.3) : Colors.redAccent.withOpacity(0.3))), Container(height: 1, width: 50, color: Colors.white24), Positioned(bottom: 85 + (_throttleRaw * 85), child: Container(width: 46, height: 30, decoration: BoxDecoration(color: _throttleRaw >= 0 ? Colors.greenAccent : Colors.redAccent, borderRadius: BorderRadius.circular(4)), child: const Icon(Icons.unfold_more, color: Colors.black87)))])))]);
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
    canvas.drawArc(rect, pi, pi, false, trackPaint);
    final progressPaint = Paint()..color = speed > 90 ? Colors.redAccent : Colors.greenAccent..style = PaintingStyle.stroke..strokeWidth = 10..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, pi, (speed / 120) * pi, false, progressPaint);
  }
  @override bool shouldRepaint(SpeedometerPainter oldDelegate) => oldDelegate.speed != speed;
}