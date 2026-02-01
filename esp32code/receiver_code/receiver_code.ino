#include <ESP8266WiFi.h> 
#include <WiFiUdp.h>
#include <Servo.h>

const char* ssid = "Galaxy M51A0C4";
const char* password = "VGyk@#2002";

WiFiUDP udp;
Servo spoilerServo; 
unsigned int localPort = 8888;
unsigned int broadcastPort = 8889; 
unsigned long lastBroadcast = 0;

void setup() {
  Serial.begin(115200);
  spoilerServo.attach(14); // Pin D5
  
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);
  
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  
  Serial.println("\n✅ WiFi OK");
  Serial.print("IP: "); Serial.println(WiFi.localIP());
  
  udp.begin(localPort);
}

void loop() {
  // 1. DYNAMIC BROADCAST (Finds the subnet automatically)
  if (millis() - lastBroadcast > 2000) {
    IPAddress ip = WiFi.localIP();
    IPAddress broadcastIP(ip[0], ip[1], ip[2], 255); 
    
    udp.beginPacket(broadcastIP, broadcastPort);
    udp.print("ESP_DISCOVERY");
    udp.endPacket();
    lastBroadcast = millis();
  }

  // 2. LISTEN FOR COMMANDS
  int size = udp.parsePacket();
  if (size > 0) {
    char buffer[255];
    int len = udp.read(buffer, 255);
    if (len > 0) {
      buffer[len] = 0;
      String data = String(buffer);
      Serial.println("Cmd: " + data);

      // Reply RSSI
      udp.beginPacket(udp.remoteIP(), udp.remotePort());
      udp.print("RSSI:" + String(WiFi.RSSI()));
      udp.endPacket();

      // FIXED: Using indexOf() instead of contains()
      if (data.indexOf("W:1") != -1) {
        spoilerServo.write(180); // Spoiler Up
      } else if (data.indexOf("W:0") != -1) {
        spoilerServo.write(0);   // Spoiler Down
      }
    }
  }
  yield();
}