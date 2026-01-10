#include <WiFi.h>
#include <WiFiUdp.h>

const char* ssid = "ESP32-AP";
const char* password = "12345678";
WiFiUDP udp;
const int udpPort = 8888;
char packetBuffer[128];

void setup() {
  Serial.begin(115200);
  delay(2000);
  WiFi.softAP(ssid, password);
  IPAddress IP = WiFi.softAPIP();
  Serial.printf("RC Car AP: %s\nUDP Port: %d\n", IP.toString().c_str(), udpPort);
  udp.begin(udpPort);
  Serial.println("READY");
}

void loop() {
  int packetSize = udp.parsePacket();
  if (packetSize) {
    int len = udp.read(packetBuffer, 128);
    packetBuffer[len] = 0;
    
    float steering = 0, throttle = 0;
    char* s = strstr(packetBuffer, "S:");
    char* t = strstr(packetBuffer, "T:");
    if (s) steering = atof(s+2);
    if (t) throttle = atof(t+2);
    
    Serial.printf("🚗 S:%.2f T:%.2f | %s\n", steering, throttle, packetBuffer);
  }
}
