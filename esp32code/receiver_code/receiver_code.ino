#include <ESP8266WiFi.h> // replace with ESP32WiFi.h for ESP32 rest everything is same.
#include <WiFiUdp.h>

const char* ssid = "Galaxy M51A0C4";
const char* password = "VGyk@#2002";

WiFiUDP udp;
char packetBuffer[255];

void setup() {
  Serial.begin(115200);
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);
  
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  
  Serial.println("\n✅ WiFi OK");
  Serial.print("ESP IP: "); Serial.println(WiFi.localIP());
  Serial.print("GATEWAY: "); Serial.println(WiFi.gatewayIP());  // PHONE IP!
  
  udp.begin(8888);
  Serial.println("🔍 LISTENING 8888 - MOVE THROTTLE NOW!");
  Serial.println("📱 Flutter IP must = ESP IP above!");
}

void loop() {

  // UDP Check
  int size = udp.parsePacket();
  if (size) {
    int len = udp.read(packetBuffer, 255);
    packetBuffer[len] = 0;
    Serial.printf("🎉 UDP %d bytes: %s\n", len, packetBuffer);
  }
}
