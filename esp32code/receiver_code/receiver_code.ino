#include <ESP8266WiFi.h> // replace <ESP8266WiFi.h> with <WiFi.h> for ESP32
#include <WiFiUdp.h>

const char* ssid = "ESP8266-AP";
const char* password = "12345678";

WiFiUDP udp;
const int udpPort = 8888;
char packetBuffer[255];

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("=== ESP32 UDP FAST Server ===");
  
  WiFi.softAP(ssid, password);
  IPAddress IP = WiFi.softAPIP();
  Serial.print("AP IP: ");
  Serial.println(IP);
  Serial.printf("UDP listening on port %d\n\n", udpPort);
  
  udp.begin(udpPort);
  Serial.println("UDP server ready! (50x faster than HTTP)");
}

void loop() {
  int packetSize = udp.parsePacket();
  
  if (packetSize) {
    int len = udp.read(packetBuffer, 255);
    if (len > 0) {
      packetBuffer[len] = 0;
      Serial.printf("🚀 UDP HELLO #%d: '%s' (%d bytes)\n", 
                    millis()/1000, packetBuffer, len);
    }
  }
}
