#include <ESP8266WiFi.h> 
#include <WiFiUdp.h>

const char* ssid = "Galaxy M51A0C4";
const char* password = "VGyk@#2002";

WiFiUDP udp;
char packetBuffer[255];

void setup() {
  Serial.begin(115200);
  delay(100); 
  
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);
  
  Serial.print("Connecting");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  
  Serial.println("\n✅ WiFi OK");
  Serial.print("ESP IP: "); Serial.println(WiFi.localIP());
  
  udp.begin(8888);
  Serial.println("🔍 Listening on 8888...");
}

void loop() {
  // Check for incoming packets (Commands or Heartbeats)
  int size = udp.parsePacket();
  
  if (size > 0) {
    int len = udp.read(packetBuffer, 255);
    if (len > 0) {
      packetBuffer[len] = 0; // Null terminate
      Serial.printf("🎉 Received: %s\n", packetBuffer);

      // Reply back with RSSI immediately
      udp.beginPacket(udp.remoteIP(), udp.remotePort());
      String rssiMsg = "RSSI:" + String(WiFi.RSSI());
      udp.print(rssiMsg);
      udp.endPacket();
    }
  }
  
  yield(); // Keep background WiFi tasks running
}