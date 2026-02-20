import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
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

class _ControlScreenState extends State<ControlScreen> with TickerProviderStateMixin {
  // --- Control State ---
  double _steeringAngle = 0.0;
  double _lastTouchAngle = 0.0;
  double _throttleRaw = 0.0; 
  double _trimValue = 0.0;
  double _currentSpeed = 0.0;

  // --- Momentum & Timing Memory ---
  double _lastPWMBeforeNeutral = 1500.0; 
  DateTime? _lastThrottleReleaseTime; 

  // --- Steering Config ---
  double _leftLimit = 68.0;   
  double _rightLimit = 112.0; 
  double _maxRotationLimit = 9.42; 
  double _steeringSensitivity = 1.0; 
  double _centeringSpeed = 20.0; 

  Ticker? _centeringTicker;
  Duration _lastElapsed = Duration.zero;

  // --- UI Panels ---
  bool _showTrimSlider = false;
  bool _showLimitSlider = false; 
  bool _showParamPanel = false;
  bool _showBrakePanel = false;
  bool _showMomentumPanel = false;

  // --- Car Functions ---
  int _headlightStage = 0; 
  bool _parkingLightsOn = false;
  bool _spoilerUp = false;
  bool _isBraking = false;
  bool _isReversing = false; 
  bool _s1Active = false; 
  bool _s2Active = false;
  bool _s3Active = false;
  bool _manualModeActive = false; 
  bool _isButtonSteering = false; 

  // --- Gearbox & Momentum Engine ---
  int _gearStage = 0; 
  double _animatedManualPWM = 1500.0;
  double _dischargeRate = 2.5; 
  late AnimationController _manualController;
  late Animation<double> _manualAnimation;
  bool _isManualThrottlePressed = false;
  bool _isPlusPressed = false; 
  bool _isMinusPressed = false;

  // --- Networking ---
  String _espIP = '0.0.0.0'; 
  final int _udpPort = 8888;
  final int _discoveryPort = 8889;
  bool _isConnected = false;
  int _rssi = 0; 
  RawDatagramSocket? _controlSocket;
  RawDatagramSocket? _discoverySocket;
  Timer? _connTimeout;
  Timer? _heartbeatTimer;

  // --- Braking ---
  Timer? _brakePulseTimer;
  int _brakeOverridePWM = 1500;
  double _maxBrakeDuration = 0.5; 

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _startDiscovery();
    _setupControlSocket(); 

    _manualController = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _manualAnimation = Tween<double>(begin: 1500.0, end: 1500.0).animate(_manualController);
    
    _heartbeatTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (_espIP != '0.0.0.0') _sendUDP();

      setState(() {
        if (!_isManualThrottlePressed && !_isBraking && _manualModeActive) {
          double decayStep = (15.0 / _dischargeRate).clamp(0.1, 100.0);
          if ((_animatedManualPWM - 1500).abs() <= (decayStep + 1.0)) {
            _animatedManualPWM = 1500.0; 
          } else if (_animatedManualPWM > 1500) {
            _animatedManualPWM -= decayStep;
          } else if (_animatedManualPWM < 1500) {
            _animatedManualPWM += decayStep;
          }
        }

        double targetSpeed = 0.0;
        if (_isBraking) {
          targetSpeed = 0.0;
        } else if (_manualModeActive) {
          double speedFactor = (_animatedManualPWM - 1500).abs() / 500.0;
          targetSpeed = speedFactor * 120.0;
        } else {
          targetSpeed = _throttleRaw.abs() * 120.0;
        }

        if (_currentSpeed < targetSpeed) {
          _currentSpeed = (_currentSpeed + 4.0).clamp(0.0, targetSpeed);
        } else {
          _currentSpeed = (_currentSpeed - 3.0).clamp(targetSpeed, 120.0);
        }
      });
    });

    _centeringTicker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _manualController.dispose();
    _heartbeatTimer?.cancel();
    _connTimeout?.cancel();
    _brakePulseTimer?.cancel();
    _controlSocket?.close();
    _discoverySocket?.close();
    _centeringTicker?.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (_lastElapsed == Duration.zero) { _lastElapsed = elapsed; return; }
    double dt = (elapsed.inMicroseconds - _lastElapsed.inMicroseconds) / 1000000.0;
    _lastElapsed = elapsed;
    if (_steeringAngle == 0.0) { _centeringTicker?.stop(); _lastElapsed = Duration.zero; return; }
    setState(() {
      double step = _centeringSpeed * dt; 
      if (_steeringAngle > 0) { _steeringAngle = max(0, _steeringAngle - step); } 
      else { _steeringAngle = min(0, _steeringAngle + step); }
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _trimValue = prefs.getDouble('steering_trim') ?? 0.0;
      _leftLimit = (prefs.getDouble('left_limit') ?? 68.0).clamp(10.0, 85.0);
      _rightLimit = (prefs.getDouble('right_limit') ?? 112.0).clamp(95.0, 170.0);
      _maxRotationLimit = (prefs.getDouble('max_rotation') ?? 9.42).clamp(0.785, 9.42);
      _steeringSensitivity = prefs.getDouble('steer_sens') ?? 1.0;
      _centeringSpeed = (prefs.getDouble('center_speed') ?? 20.0).clamp(10.0, 30.0);
      _maxBrakeDuration = prefs.getDouble('max_brake_dur') ?? 0.5;
      _dischargeRate = (prefs.getDouble('momentum_rate') ?? 2.5).clamp(0.1, 5.0);
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('steering_trim', _trimValue);
    await prefs.setDouble('left_limit', _leftLimit);
    await prefs.setDouble('right_limit', _rightLimit);
    await prefs.setDouble('max_rotation', _maxRotationLimit);
    await prefs.setDouble('steer_sens', _steeringSensitivity);
    await prefs.setDouble('center_speed', _centeringSpeed);
    await prefs.setDouble('max_brake_dur', _maxBrakeDuration);
    await prefs.setDouble('momentum_rate', _dischargeRate);
  }

  void _gearUp() { if (_gearStage < 5) { setState(() => _gearStage++); if (_isManualThrottlePressed) _engageManualThrottle(); } }
  void _gearDown() { if (_gearStage > 0) { setState(() => _gearStage--); if (_isManualThrottlePressed) _engageManualThrottle(); } }
  
  void _engageManualThrottle() {
    double targetPWM = _isReversing ? 1500.0 - (_gearStage * 100) : 1500.0 + (_gearStage * 100);
    _manualAnimation = Tween<double>(begin: _animatedManualPWM, end: targetPWM)
        .animate(CurvedAnimation(parent: _manualController, curve: Curves.easeOut));
    _manualController.addListener(_updatePWMFromAnimation);
    _manualController.forward(from: 0);
  }

  void _updatePWMFromAnimation() { setState(() { _animatedManualPWM = _manualAnimation.value; }); }

  void _releaseManualThrottle() {
    setState(() {
      _isManualThrottlePressed = false;
      _lastPWMBeforeNeutral = _animatedManualPWM;
      _lastThrottleReleaseTime = DateTime.now(); 
      _manualController.removeListener(_updatePWMFromAnimation);
      _manualController.stop(); 
    });
  }

  void _startDiscovery() async { _discoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _discoveryPort); _discoverySocket?.listen((RawSocketEvent event) { if (event == RawSocketEvent.read) { Datagram? dg = _discoverySocket?.receive(); if (dg != null) { String msg = String.fromCharCodes(dg.data); if (msg == "ESP_DISCOVERY") setState(() => _espIP = dg.address.address); } } }); }
  void _setupControlSocket() async { _controlSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0); _controlSocket?.listen((RawSocketEvent event) { if (event == RawSocketEvent.read) { Datagram? dg = _controlSocket?.receive(); if (dg != null) { String response = String.fromCharCodes(dg.data); if (response.startsWith("RSSI:")) { setState(() { _rssi = int.tryParse(response.split(":")[1]) ?? 0; _isConnected = true; }); _connTimeout?.cancel(); _connTimeout = Timer(const Duration(seconds: 3), () { setState(() { _isConnected = false; _rssi = 0; }); }); } } } }); }
  
  double get currentThrottlePWM {
    if (_isBraking) return _brakeOverridePWM.toDouble();
    if (_manualModeActive) return _animatedManualPWM;
    return (_throttleRaw + 1.0) * 500 + 1000;
  }

  double get servoAngle {
    double center = 90.0 + _trimValue;
    double normalizedStick = (_steeringAngle / _maxRotationLimit).clamp(-1.0, 1.0);
    return (normalizedStick < 0) ? center + (normalizedStick * (center - _leftLimit)) : center + (normalizedStick * (_rightLimit - center));
  }
  
  Future<void> _sendUDP() async { if (_controlSocket == null || _espIP == '0.0.0.0') return; try { String data = "S:${servoAngle.toStringAsFixed(1)},T:${currentThrottlePWM.toStringAsFixed(0)},L:$_headlightStage,P:${_parkingLightsOn ? 1 : 0},W:${_spoilerUp ? 1 : 0},B:${_isBraking ? 1 : 0},H:${_s1Active ? 1 : 0},S2:${_s2Active ? 1 : 0},S3:${_s3Active ? 1 : 0},REV:${_isReversing ? 1 : 0}"; _controlSocket?.send(Uint8List.fromList(data.codeUnits), InternetAddress(_espIP), _udpPort); } catch (e) { debugPrint('UDP Error: $e'); } }

  void _stopBrakePulse() { 
    _brakePulseTimer?.cancel(); 
    setState(() { 
      _isBraking = false; 
      _brakeOverridePWM = 1500; 
      if (_manualModeActive) _animatedManualPWM = 1500.0; 
      _lastPWMBeforeNeutral = 1500;
      _lastThrottleReleaseTime = null; 
    }); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff1d271d),
      body: Stack(
        children: [
          Positioned(
            top: 15, left: 15, 
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("IP: $_espIP", style: const TextStyle(fontSize: 9, color: Colors.white24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                _buildSignalIndicator(),
                const SizedBox(height: 10),
                _buildRectButtonSmall(label: "STEERING LIMITS", active: _showLimitSlider, onTap: () => _togglePanel('limit')),
                const SizedBox(height: 8),
                _buildRectButtonSmall(label: "BRAKE SETTINGS", active: _showBrakePanel, activeColor: Colors.redAccent, onTap: () => _togglePanel('brake')),
                const SizedBox(height: 8),
                _buildRectButtonSmall(label: "STEERING PARAMETERS", active: _showParamPanel, onTap: () => _togglePanel('param')),
                const SizedBox(height: 25), 
                _buildHornButton(),
              ],
            ),
          ),
          Positioned(top: 20, left: 0, right: 70, child: Center(child: _buildHUD())),
          Positioned(
            top: 40, right: 30,
            child: Row(
              children: [
                _buildAccessoryColumn(),
                const SizedBox(width: 15),
                _buildModeColumn(),
                const SizedBox(width: 12),
                _buildSteerControlColumn(),
              ],
            ),
          ),
          if (_showTrimSlider) Center(child: _buildTrimPanel()),
          if (_showLimitSlider) Center(child: _buildLimitPanel()),
          if (_showParamPanel) Center(child: _buildParamPanel()),
          if (_showBrakePanel) Center(child: _buildBrakePanel()),
          if (_showMomentumPanel) Center(child: _buildMomentumPanel()),
          Positioned(bottom: 30, left: 70, child: _isButtonSteering ? _buildButtonSteering() : _buildWheelSteering()),
          Positioned(bottom: 20, left: 0, right: 0, child: Center(child: _buildSpeedometer())),
          Positioned(bottom: 30, right: 30, child: _buildRightControlArea()),
        ],
      ),
    );
  }

  void _togglePanel(String panel) {
    setState(() {
      _showTrimSlider = (panel == 'trim' && !_showTrimSlider);
      _showLimitSlider = (panel == 'limit' && !_showLimitSlider);
      _showParamPanel = (panel == 'param' && !_showParamPanel);
      _showBrakePanel = (panel == 'brake' && !_showBrakePanel);
      _showMomentumPanel = (panel == 'momentum' && !_showMomentumPanel);
    });
  }

  Widget _buildHUD() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6), 
      decoration: BoxDecoration(color: _isConnected ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(20)), 
      child: Text("PWM: ${currentThrottlePWM.toStringAsFixed(0)} | STEER: ${servoAngle.toStringAsFixed(1)}°", 
      style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.bold, fontSize: 11))
    );
  }

  Widget _buildHornButton() {
    return GestureDetector(
      onTapDown: (_) => setState(() => _s1Active = true),
      onTapUp: (_) => setState(() => _s1Active = false),
      onTapCancel: () => setState(() => _s1Active = false),
      child: Container(
        width: 65, height: 65, 
        decoration: BoxDecoration(color: _s1Active ? Colors.purpleAccent : Colors.purpleAccent.withOpacity(0.1), shape: BoxShape.circle, border: Border.all(color: Colors.purpleAccent, width: 2.5)),
        child: Center(child: Icon(Icons.campaign, color: _s1Active ? Colors.white : Colors.purpleAccent, size: 35)),
      ),
    );
  }

  Widget _buildAccessoryColumn() {
    return Column(children: [
      Row(children: [
        _buildCircularButton(icon: Icons.flight_takeoff, active: _spoilerUp, color: Colors.cyanAccent, onTap: () => setState(() => _spoilerUp = !_spoilerUp)), 
        const SizedBox(width: 12), 
        _buildCircularButton(icon: Icons.warning_amber_rounded, active: _parkingLightsOn, color: Colors.orangeAccent, onTap: () => setState(() => _parkingLightsOn = !_parkingLightsOn)), 
        const SizedBox(width: 12), 
        _buildCircularButton(icon: Icons.highlight, active: _headlightStage > 0, color: _headlightStage == 1 ? Colors.blueAccent : Colors.yellowAccent, onTap: () => setState(() => _headlightStage = (_headlightStage + 1) % 3))
      ]), 
      const SizedBox(height: 12), 
      Row(children: [
        _buildCircularButton(label: "S2", active: _s2Active, color: Colors.purpleAccent, onTap: () => setState(() => _s2Active = !_s2Active)), 
        const SizedBox(width: 12), 
        _buildCircularButton(label: "S3", active: _s3Active, color: Colors.purpleAccent, onTap: () => setState(() => _s3Active = !_s3Active))
      ])
    ]);
  }

  Widget _buildModeColumn() {
    return Column(children: [
      _buildRectButton(label: "TRIM", active: _showTrimSlider, onTap: () => _togglePanel('trim')), 
      const SizedBox(height: 12), 
      _buildRectButton(label: "MANUAL", active: _manualModeActive, activeColor: Colors.orangeAccent, onTap: () { setState(() { _manualModeActive = !_manualModeActive; _isReversing = false; _gearStage = 0; _animatedManualPWM = 1500.0; _lastThrottleReleaseTime = null; }); })
    ]);
  }

  Widget _buildSteerControlColumn() {
    return Column(children: [
      _buildRectButton(label: "STEER", active: _isButtonSteering, activeColor: Colors.cyanAccent, onTap: () => setState(() { _isButtonSteering = !_isButtonSteering; _steeringAngle = 0.0; })), 
      const SizedBox(height: 12), 
      if (_manualModeActive) _buildRectButton(label: "MOMENTUM", active: _showMomentumPanel, activeColor: Colors.yellowAccent, onTap: () => _togglePanel('momentum')),
    ]);
  }

  Widget _buildRightControlArea() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildBrakeAndReverse(),
        const SizedBox(width: 20),
        _manualModeActive ? _buildManualThrottle() : _buildStandardThrottle(),
      ],
    );
  }

  Widget _buildBrakeAndReverse() {
    return Column(children: [
      if (_manualModeActive) GestureDetector(
        onTap: () { setState(() { _isReversing = !_isReversing; if (_isManualThrottlePressed) _engageManualThrottle(); }); }, 
        child: Container(height: 60, width: 60, decoration: BoxDecoration(color: _isReversing ? Colors.blue : Colors.blue.withOpacity(0.15), borderRadius: BorderRadius.circular(10), border: Border.all(color: _isReversing ? Colors.white : Colors.blue, width: 2)), child: Center(child: Text("R", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _isReversing ? Colors.white : Colors.blue))))
      ),
      if (_manualModeActive) const SizedBox(height: 10),
      GestureDetector(
        onTapDown: (_) { 
          setState(() { 
            _isBraking = true;
            _brakePulseTimer?.cancel();

            // --- DYNAMIC WINDOW LOGIC ---
            bool isWithinDynamicWindow = false;
            if (_lastThrottleReleaseTime != null) {
              // Calculate how fast we were going as a factor of 0.0 to 1.0
              double speedIntensity = (_lastPWMBeforeNeutral - 1500).abs() / 500.0;
              
              // Dynamic window: if at 100% speed, window is 3s. If at 10% speed, window is 0.3s.
              double dynamicWindowSeconds = (speedIntensity * 3.0).clamp(0.1, 3.0);
              
              int elapsedMs = DateTime.now().difference(_lastThrottleReleaseTime!).inMilliseconds;
              if (elapsedMs < (dynamicWindowSeconds * 1000)) {
                isWithinDynamicWindow = true;
              }
            }

            double speedDiff = (_lastPWMBeforeNeutral - 1500).abs();
            
            // Only fire the pulse if we are within the dynamic time window
            if (speedDiff > 30 && isWithinDynamicWindow) {
              bool wasMovingForward = _lastPWMBeforeNeutral > 1500;
              int durationMs = ((speedDiff / 500.0) * _maxBrakeDuration * 1000).toInt(); 
              _brakeOverridePWM = wasMovingForward ? 1000 : 2000;
              _brakePulseTimer = Timer(Duration(milliseconds: durationMs), () { 
                setState(() { 
                  _brakeOverridePWM = 1500; 
                  if (_manualModeActive) _animatedManualPWM = 1500.0;
                }); 
              });
            } else { 
              // Window expired or car already basically stopped - don't jerk the car
              _brakeOverridePWM = 1500; 
            }
          }); 
        },
        onTapUp: (_) => _stopBrakePulse(),
        onTapCancel: () => _stopBrakePulse(),
        child: Container(height: 100, width: 60, decoration: BoxDecoration(color: _isBraking ? Colors.red : Colors.red.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.red, width: 2)), child: const Center(child: Text("BRAKE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)))),
      ),
    ]);
  }

  Widget _buildMomentumPanel() {
    return Container(
      width: 350, padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.95), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.yellowAccent.withOpacity(0.4))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("THROTTLE DISCHARGE RATE", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.yellowAccent)),
          const SizedBox(height: 20),
          Text("${_dischargeRate.toStringAsFixed(1)} (Inertia Intensity)", style: const TextStyle(fontSize: 12, color: Colors.white70)),
          const SizedBox(height: 10),
          Slider(value: _dischargeRate, min: 0.1, max: 5.0, divisions: 49, activeColor: Colors.yellowAccent, onChanged: (val) { setState(() => _dischargeRate = val); _saveSettings(); }),
          const Text("Lower = More Momentum", style: TextStyle(fontSize: 9, color: Colors.white38)),
        ],
      ),
    );
  }

  Widget _buildManualThrottle() {
    double fillPercent = ((_animatedManualPWM - 1500).abs() / 500).clamp(0.0, 1.0);
    String gearText = _gearStage == 0 ? "N" : "G$_gearStage";
    return Row(children: [
      GestureDetector(
        onTapDown: (_) { setState(() => _isManualThrottlePressed = true); _engageManualThrottle(); },
        onTapUp: (_) => _releaseManualThrottle(),
        onTapCancel: () => _releaseManualThrottle(),
        child: Container(height: 205, width: 80, decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12), border: Border.all(color: _isReversing ? Colors.blueAccent : Colors.orangeAccent, width: 2)), child: Stack(alignment: Alignment.bottomCenter, children: [Container(width: 80, height: 205 * fillPercent, decoration: BoxDecoration(gradient: LinearGradient(colors: _isReversing ? [Colors.blue, Colors.lightBlueAccent] : [Colors.deepOrange, Colors.orangeAccent], begin: Alignment.topCenter, end: Alignment.bottomCenter), borderRadius: BorderRadius.circular(10))), const Center(child: RotatedBox(quarterTurns: 3, child: Text("DRIVE", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white70, letterSpacing: 4))))])),
      ),
      const SizedBox(width: 15),
      Column(children: [
        _buildGearButton(Icons.add, () => _gearUp(), _isPlusPressed, (v) => _isPlusPressed = v),
        const SizedBox(height: 10),
        Container(width: 50, height: 40, decoration: BoxDecoration(border: Border.all(color: Colors.white24)), child: Center(child: Text(gearText, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)))),
        const SizedBox(height: 10),
        _buildGearButton(Icons.remove, () => _gearDown(), _isMinusPressed, (v) => _isMinusPressed = v),
      ])
    ]);
  }

  Widget _buildGearButton(IconData icon, VoidCallback action, bool isPressed, Function(bool) setPressed) {
    return GestureDetector(
      onTapDown: (_) { setState(() => setPressed(true)); action(); },
      onTapUp: (_) => setState(() => setPressed(false)),
      onTapCancel: () => setState(() => setPressed(false)),
      child: Container(width: 50, height: 50, decoration: BoxDecoration(color: isPressed ? Colors.orangeAccent : Colors.white12, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orangeAccent)), child: Icon(icon, color: isPressed ? Colors.black : Colors.orangeAccent)),
    );
  }

  Widget _buildSignalIndicator() { int percentage = ((_rssi + 100) * 2).clamp(0, 100); Color color = percentage > 60 ? Colors.greenAccent : percentage > 30 ? Colors.orangeAccent : Colors.redAccent; return Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.wifi, color: color, size: 16), const SizedBox(width: 5), Text(_isConnected ? "$percentage%" : "OFFLINE", style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold))]); }
  Widget _buildRectButtonSmall({required String label, required bool active, required VoidCallback onTap, Color activeColor = Colors.cyanAccent}) { return GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: active ? activeColor.withOpacity(0.2) : Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(4), border: Border.all(color: active ? activeColor : Colors.white10)), child: Text(label, style: TextStyle(color: active ? activeColor : Colors.white38, fontSize: 8, fontWeight: FontWeight.bold)))); }
  Widget _buildRectButton({required String label, required bool active, required VoidCallback onTap, Color activeColor = Colors.greenAccent}) { return GestureDetector(onTap: onTap, child: Container(width: 80, padding: const EdgeInsets.symmetric(vertical: 8), decoration: BoxDecoration(color: active ? activeColor.withOpacity(0.2) : Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: active ? activeColor : Colors.white24, width: 1.5)), child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11))))); }
  Widget _buildCircularButton({IconData? icon, String? label, required bool active, required Color color, required VoidCallback onTap}) { return GestureDetector(onTap: onTap, child: Container(width: 40, height: 40, decoration: BoxDecoration(color: active ? color.withOpacity(0.2) : Colors.white.withOpacity(0.05), shape: BoxShape.circle, border: Border.all(color: active ? color : Colors.white24, width: 1.5)), child: Center(child: icon != null ? Icon(icon, color: active ? color : Colors.white, size: 20) : Text(label ?? "", style: TextStyle(color: active ? color : Colors.white, fontWeight: FontWeight.bold, fontSize: 12))))); }
  Widget _buildTrimPanel() { return Container(width: 320, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.black.withOpacity(0.8), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white10)), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text("STEERING TRIM", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)), Slider(value: _trimValue, min: -15, max: 15, divisions: 300, activeColor: Colors.greenAccent, label: _trimValue.toStringAsFixed(1), onChanged: (val) { setState(() => _trimValue = val); _saveSettings(); }), Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [IconButton(onPressed: () => setState(() { _trimValue = (_trimValue - 0.1).clamp(-15.0, 15.0); _saveSettings(); }), icon: const Icon(Icons.remove, color: Colors.greenAccent)), TextButton(onPressed: () => setState(() { _trimValue = 0.0; _saveSettings(); }), child: const Text("RESET")), IconButton(onPressed: () => setState(() { _trimValue = (_trimValue + 0.1).clamp(-15.0, 15.0); _saveSettings(); }), icon: const Icon(Icons.add, color: Colors.greenAccent))])])); }
  Widget _buildLimitPanel() { return Container(width: 350, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.black.withOpacity(0.9), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.cyanAccent.withOpacity(0.3))), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text("STEERING LIMITS (EPA)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent)), const SizedBox(height: 10), Text("MAX LEFT: ${_leftLimit.toStringAsFixed(0)}°", style: const TextStyle(fontSize: 12)), Slider(value: _leftLimit, min: 10, max: 85, activeColor: Colors.cyanAccent, onChanged: (val) { setState(() => _leftLimit = val); _saveSettings(); }), Text("MAX RIGHT: ${_rightLimit.toStringAsFixed(0)}°", style: const TextStyle(fontSize: 12)), Slider(value: _rightLimit, min: 95, max: 170, activeColor: Colors.cyanAccent, onChanged: (val) { setState(() => _rightLimit = val); _saveSettings(); })])); }
  
  Widget _buildParamPanel() {
    const double oneDegInRad = 0.0174533;
    return Container(
      width: 400, padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.95), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.orangeAccent.withOpacity(0.4))),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("STEERING PARAMETERS", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent, letterSpacing: 1.2)),
            const SizedBox(height: 10),
            Text("ROTATION LOCK: ${(_maxRotationLimit * 57.3).toStringAsFixed(0)}°", style: const TextStyle(fontSize: 12, color: Colors.white70)),
            Row(children: [
              IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.orangeAccent), onPressed: () { setState(() => _maxRotationLimit = (_maxRotationLimit - oneDegInRad).clamp(0.785, 9.42)); _saveSettings(); }),
              Expanded(child: Slider(value: _maxRotationLimit, min: 0.785, max: 9.42, activeColor: Colors.orangeAccent, onChanged: (val) { setState(() => _maxRotationLimit = val); _saveSettings(); })),
              IconButton(icon: const Icon(Icons.add_circle_outline, color: Colors.orangeAccent), onPressed: () { setState(() => _maxRotationLimit = (_maxRotationLimit + oneDegInRad).clamp(0.785, 9.42)); _saveSettings(); }),
            ]),
            const SizedBox(height: 10),
            Text("SENSITIVITY: ${_steeringSensitivity.toStringAsFixed(1)}x", style: const TextStyle(fontSize: 12, color: Colors.white70)),
            Slider(value: _steeringSensitivity, min: 0.5, max: 2.5, divisions: 20, activeColor: Colors.orangeAccent, onChanged: (val) { setState(() => _steeringSensitivity = val); _saveSettings(); }),
            const SizedBox(height: 10),
            Text("CENTERING SPEED: ${_centeringSpeed.toStringAsFixed(1)}", style: const TextStyle(fontSize: 12, color: Colors.white70)),
            Slider(value: _centeringSpeed, min: 10.0, max: 30.0, divisions: 40, activeColor: Colors.orangeAccent, onChanged: (val) { setState(() => _centeringSpeed = val); _saveSettings(); }),
          ],
        ),
      ),
    );
  }

  Widget _buildBrakePanel() { return Container(width: 350, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.black.withOpacity(0.95), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.redAccent.withOpacity(0.4))), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text("ACTIVE BRAKE DURATION", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)), const SizedBox(height: 20), Text("${_maxBrakeDuration.toStringAsFixed(2)} Seconds @ Max Speed", style: const TextStyle(fontSize: 12, color: Colors.white70)), const SizedBox(height: 10), Slider(value: _maxBrakeDuration, min: 0.05, max: 2.0, divisions: 39, activeColor: Colors.redAccent, onChanged: (val) { setState(() => _maxBrakeDuration = val); _saveSettings(); })])); }
  Widget _buildWheelSteering() { return GestureDetector(onPanStart: (details) { _centeringTicker?.stop(); _lastElapsed = Duration.zero; final box = context.findRenderObject() as RenderBox; final Offset center = box.localToGlobal(Offset(70 + 90, MediaQuery.of(context).size.height - 30 - 90)); final Offset pos = details.globalPosition - center; _lastTouchAngle = atan2(pos.dy, pos.dx); }, onPanUpdate: (details) { final RenderBox box = context.findRenderObject() as RenderBox; final Offset center = box.localToGlobal(Offset(70 + 90, MediaQuery.of(context).size.height - 30 - 90)); final Offset currentPos = details.globalPosition - center; double currentAngle = atan2(currentPos.dy, currentPos.dx); double diff = currentAngle - _lastTouchAngle; if (diff > pi) diff -= 2 * pi; if (diff < -pi) diff += 2 * pi; setState(() { _steeringAngle = (_steeringAngle + (diff * _steeringSensitivity)).clamp(-_maxRotationLimit, _maxRotationLimit); }); _lastTouchAngle = currentAngle; }, onPanEnd: (_) { _centeringTicker?.start(); _lastTouchAngle = 0.0; }, child: Transform.rotate(angle: _steeringAngle, child: SizedBox(width: 180, height: 180, child: Image.asset('images/steering_wheel.png', fit: BoxFit.contain)))); }
  Widget _buildButtonSteering() { bool isLeftPressed = _steeringAngle <= -_maxRotationLimit; bool isRightPressed = _steeringAngle >= _maxRotationLimit; return Row(children: [GestureDetector(onTapDown: (_) { _centeringTicker?.stop(); setState(() => _steeringAngle = -_maxRotationLimit); }, onTapUp: (_) { _lastElapsed = Duration.zero; _centeringTicker?.start(); }, child: Container(width: 85, height: 85, decoration: BoxDecoration(color: isLeftPressed ? Colors.cyanAccent : Colors.cyanAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.cyanAccent, width: 2)), child: Icon(Icons.arrow_back_ios_new, size: 40, color: isLeftPressed ? Colors.black : Colors.cyanAccent))), const SizedBox(width: 20), GestureDetector(onTapDown: (_) { _centeringTicker?.stop(); setState(() => _steeringAngle = _maxRotationLimit); }, onTapUp: (_) { _lastElapsed = Duration.zero; _centeringTicker?.start(); }, child: Container(width: 85, height: 85, decoration: BoxDecoration(color: isRightPressed ? Colors.cyanAccent : Colors.cyanAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.cyanAccent, width: 2)), child: Icon(Icons.arrow_forward_ios, size: 40, color: isRightPressed ? Colors.black : Colors.cyanAccent)))]); }
  
  Widget _buildStandardThrottle() { 
    return Row(children: [
      const Column(children: [Text("F", style: TextStyle(color: Colors.greenAccent)), SizedBox(height: 140), Text("R", style: TextStyle(color: Colors.redAccent))]), 
      const SizedBox(width: 15), 
      GestureDetector(
        onVerticalDragUpdate: (details) { 
          setState(() { 
            _throttleRaw -= details.delta.dy / 100; 
            _throttleRaw = _throttleRaw.clamp(-1.0, 1.0); 
            _lastPWMBeforeNeutral = (_throttleRaw + 1.0) * 500 + 1000;
          }); 
        }, 
        onVerticalDragEnd: (_) { 
          setState(() {
            _throttleRaw = 0.0; 
            _lastThrottleReleaseTime = DateTime.now(); 
          });
        }, 
        child: Container(height: 205, width: 50, decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white10, width: 2)), child: Stack(alignment: Alignment.center, children: [Positioned(bottom: _throttleRaw >= 0 ? 100 : 100 + (_throttleRaw * 100), child: Container(width: 50, height: (_throttleRaw.abs() * 100), color: _throttleRaw >= 0 ? Colors.greenAccent.withOpacity(0.3) : Colors.redAccent.withOpacity(0.3))), Container(height: 1, width: 50, color: Colors.white24), Positioned(bottom: 85 + (_throttleRaw * 85), child: Container(width: 46, height: 30, decoration: BoxDecoration(color: _throttleRaw >= 0 ? Colors.greenAccent : Colors.redAccent, borderRadius: BorderRadius.circular(4)), child: const Icon(Icons.unfold_more, color: Colors.black87)))])))]); 
  }

  Widget _buildSpeedometer() { return SizedBox(width: 180, height: 90, child: CustomPaint(painter: SpeedometerPainter(_currentSpeed), child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [Text("${_currentSpeed.toStringAsFixed(0)}", style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w900, color: Colors.white, fontStyle: FontStyle.italic)), const Text("KM/H", style: TextStyle(fontSize: 10, color: Colors.white54, fontWeight: FontWeight.bold, letterSpacing: 1.5)), const SizedBox(height: 5)]))); }
}

class SpeedometerPainter extends CustomPainter {
  final double speed;
  SpeedometerPainter(this.speed);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height);
    final radius = size.width * 0.5;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final trackPaint = Paint()..color = Colors.white.withOpacity(0.1)..style = PaintingStyle.stroke..strokeWidth = 10..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, pi, pi, false, trackPaint);
    final progressPaint = Paint()..color = speed > 90 ? Colors.redAccent : Colors.greenAccent..style = PaintingStyle.stroke..strokeWidth = 10..strokeCap = StrokeCap.round;
    double sweepAngle = (speed / 120) * pi;
    canvas.drawArc(rect, pi, sweepAngle, false, progressPaint);
  }
  @override bool shouldRepaint(SpeedometerPainter oldDelegate) => oldDelegate.speed != speed;
}