#include <ESP8266WiFi.h>
#include <WiFiUdp.h>
#include <Servo.h>

// debug mode enable
 #define DEBUG_MODE 

#define MOTOR_PIN 5       // D1-GPIO5
#define SERVO_PIN 4       // D2-GPIO4
#define SPOILER_PIN 0     // D3-GPIO0
#define HORN_PIN 2        // D4-GPIO2
#define HEAD_LIGHTS 12    // D6-GPIO12
#define BAR_LIGHTS 13     // D7-GPIO13
#define BOOSTER_LIGHTS 15 // D8-GPIO15
#define RED_LIGHTS 1      // TX-GPIO1

#define HORN_FREQUENCY 415 // frequency of the  Horn in Hz (McLaren 765LT)
#define PARKING_LIGHT_FREQ 1500

// Data packet
struct DataPacket
{
  uint16_t throttlePWM;
  float steerAngle;
  uint8_t headLights : 2;
  uint8_t parkingLights : 1;
  uint8_t spoilerState : 1;
  uint8_t brakeActive : 1;
  uint8_t hornActive : 1;
  uint8_t reverseActive : 1;
  uint8_t s2Active : 1;
  uint8_t s3Active : 1;
};

String extractValue(String data, String key);
void parseIncomingData(String sData, DataPacket *data);
void SystemInit(void);
void Control(DataPacket *rxData);
void PrintReceivedData(DataPacket *data);

Servo servo;        // create servo object to control a servo
Servo motor;        // for controlling the esc of the motor
Servo spoiler;      // for controlling the spoiler servo
DataPacket gRxData; // used to store the received data

const char *ssid = "Galaxy M51A0C4";
const char *password = "VGyk@#2002";

WiFiUDP udp;
unsigned int localPort = 8888;
unsigned int broadcastPort = 8889;
unsigned long lastBroadcast = 0;

void setup()
{
  Serial.begin(115200);

  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);

  while (WiFi.status() != WL_CONNECTED)
  {
    delay(500);
    Serial.print(".");
  }

  Serial.println("\n✅ WiFi OK");
  Serial.print("IP: ");
  Serial.println(WiFi.localIP());

  udp.begin(localPort);

  // Do the System Initialization
  SystemInit();
}

void loop()
{
  // 1. DYNAMIC BROADCAST
  if (millis() - lastBroadcast > 10)
  {
    IPAddress ip = WiFi.localIP();
    IPAddress broadcastIP(ip[0], ip[1], ip[2], 255);

    udp.beginPacket(broadcastIP, broadcastPort);
    udp.print("ESP_DISCOVERY");
    udp.endPacket();
    lastBroadcast = millis();
  }

  // 2. LISTEN FOR COMMANDS
  int size = udp.parsePacket();
  if (size > 0)
  {
    char buffer[255];
    int len = udp.read(buffer, 255);
    if (len > 0)
    {
      buffer[len] = 0;
      String data = String(buffer);

      #if defined(DEBUG_MODE)
      Serial.println("CMD :" + data);
      #endif
      // DECODE THE STRING HERE
      parseIncomingData(data, &gRxData);

      #if defined(DEBUG_MODE)
      PrintReceivedData(&gRxData);
      #endif

      // Reply RSSI
      udp.beginPacket(udp.remoteIP(), udp.remotePort());
      udp.print("RSSI:" + String(WiFi.RSSI()));
      udp.endPacket();

      // Control Code will come here
      Control(&gRxData);
      
    }
  }
}

// --- HELPER FUNCTION: Extracts value between a Key and a Comma ---
String extractValue(String data, String key)
{
  int keyPos = data.indexOf(key);
  if (keyPos == -1)
    return "0";
  int startPos = keyPos + key.length();
  int endPos = data.indexOf(",", startPos);
  if (endPos == -1)
    endPos = data.length();
  return data.substring(startPos, endPos);
}

// --- NEW FUNCTION: Decodes the string into variables ---
void parseIncomingData(String sData, DataPacket *data)
{
  data->steerAngle = extractValue(sData, "S:").toFloat();
  data->throttlePWM = extractValue(sData, "T:").toInt();
  data->headLights = extractValue(sData, "L:").toInt();
  data->parkingLights = extractValue(sData, "P:").toInt();
  data->spoilerState = extractValue(sData, "W:").toInt();
  data->brakeActive = extractValue(sData, "B:").toInt();
  data->reverseActive = extractValue(sData, "REV:").toInt(); 
  data->hornActive = extractValue(sData, "H:").toInt();
  data->s2Active = extractValue(sData, "S2:").toInt();
  data->s3Active = extractValue(sData, "S3:").toInt();
}

void SystemInit(void)
{

  servo.attach(SERVO_PIN);
  motor.attach(MOTOR_PIN);
  spoiler.attach(SPOILER_PIN);
  pinMode(HEAD_LIGHTS, OUTPUT);
  pinMode(BAR_LIGHTS, OUTPUT);
  pinMode(HORN_PIN, OUTPUT);
  #if defined(DEBUG_MODE)
  #else
  pinMode(RED_LIGHTS, OUTPUT); // this is TXpin
  #endif
  pinMode(BOOSTER_LIGHTS, OUTPUT);

  // Motor ESC Calibration
  motor.writeMicroseconds(1500);
  delay(2000);
}

void Control(DataPacket *rxData)
{
  // Write the Throttle to the motor
  motor.writeMicroseconds(rxData->throttlePWM);

  // Write the steering angle
  servo.write(int(rxData->steerAngle));

  // process the horn
  if(rxData->hornActive)
  {
    tone(HORN_PIN, HORN_FREQUENCY, 100);
  }

  if(rxData->parkingLights)
  {
    tone(HORN_PIN, PARKING_LIGHT_FREQ, 100);
    delay(500);
    tone(HORN_PIN, PARKING_LIGHT_FREQ, 100);
    delay(500);

  }

}


void PrintReceivedData(DataPacket *data)
{
  // Serial printing for debugging the extracted values
  Serial.println("--- Incoming Control Data ---");

  Serial.print("Steer: "); Serial.print(data->steerAngle);
  Serial.print(" | PWM: "); Serial.print(data->throttlePWM);
  Serial.print(" | REV: "); Serial.println(data->reverseActive ? "YES" : "NO");

  Serial.print("Brake: "); Serial.print(data->brakeActive ? "ON" : "OFF");
  Serial.print(" | Headlights: "); Serial.print(data->headLights);
  Serial.print(" | Parking: "); Serial.println(data->parkingLights ? "ON" : "OFF");

  Serial.print("Spoiler: "); Serial.print(data->spoilerState ? "UP" : "DOWN");
  Serial.print(" | Horn: "); Serial.print(data->hornActive ? "ACTIVE" : "OFF");
  Serial.print(" | S2: "); Serial.print(data->s2Active);
  Serial.print(" | S3: "); Serial.println(data->s3Active);

  Serial.println("-----------------------------");

}
