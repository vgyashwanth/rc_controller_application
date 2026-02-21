#include <ESP8266WiFi.h>
#include <WiFiUdp.h>
#include <Servo.h>
#include <Ticker.h>


// debug mode enable
// #define DEBUG_MODE

// System related variables
#define SERVO_PIN 5       // D1-GPIO5
#define MOTOR_PIN  4      // D2-GPIO4
#define SPOILER_PIN 0     // D3-GPIO0
#define HORN_PIN 2        // D4-GPIO2
#define HEAD_LIGHTS 12    // D6-GPIO12
#define BAR_LIGHTS 13     // D7-GPIO13
#define BOOSTER_LIGHTS 15 // D8-GPIO15
#define RED_LIGHTS 1      // TX-GPIO1

// frequency
#define HORN_FREQUENCY 300 // frequency of the  Horn in Hz (McLaren 765LT)
#define PARKING_LIGHT_FREQ 4500
#define PARKING_LIGHT_BLINK_TIME 0.4 //sec
#define BOOSTER_LIGHT_TOOGLE_TIME 0.05 // sec

// Ticker to create the Tasks
// Create two Ticker objects
Ticker ticker1;
Ticker ticker2;
bool isParkingLightTickerActive = false;
bool isBoosterLightTurnOnFirstTime = false;
uint8_t gBoosterLightToggleCounter = 0;
void ToggleBoosterLight(void);


// Spolier related variables
#define SPOILER_UP_ANGLE (90-24)
#define SPOILER_DOWN_ANGLE (90+26)

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
void SpoilerOn(bool On);
void parkingLights_ISR();

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

  // process the head lights
  if(rxData->headLights)
  {
     if(rxData->headLights == 1)
     {
        // Turn on the bar lights
        digitalWrite(BAR_LIGHTS, HIGH);
        // Turn off the other lights if already on
        digitalWrite(HEAD_LIGHTS, LOW);
        digitalWrite(RED_LIGHTS, LOW);
     }
     else
     {
        // Turn on all the lights
        digitalWrite(BAR_LIGHTS, HIGH);
        digitalWrite(HEAD_LIGHTS, HIGH);
        digitalWrite(RED_LIGHTS, HIGH);
     }
  }
  else 
  {
      // Turn off all the lights, only if the parking lights is off
      if(rxData->parkingLights == false)
      {
        digitalWrite(BAR_LIGHTS, LOW);
        digitalWrite(HEAD_LIGHTS, LOW);
        digitalWrite(RED_LIGHTS, LOW);
      }
  }

  // process the brake or if the car is going in reverse
  if(rxData->brakeActive || ( rxData->throttlePWM < 1500 ))
  { 
    if(rxData->parkingLights == false)
    {
      digitalWrite(RED_LIGHTS, HIGH);
    }
  }
  else
  {
    // Turn off only if their are not turned on using head lights and not turned on using parking lights also
    if((rxData->headLights == 1) && (rxData->parkingLights == false))
    {
      digitalWrite(RED_LIGHTS, LOW);
    }

  }

  // process the spoiler
  if(rxData->spoilerState)
  {
      SpoilerOn(HIGH);
  }
  else 
  {
      SpoilerOn(LOW);
  }


  // process the horn
  if(rxData->hornActive)
  {
    tone(HORN_PIN, HORN_FREQUENCY, 100);
  }
  else 
  { 
    if(rxData->parkingLights == false)
    {
      noTone(HORN_PIN);
    }
  }

  // process the parking lights
  if(rxData->parkingLights)
  {
    if(isParkingLightTickerActive == false)
    {
      ticker1.attach(PARKING_LIGHT_BLINK_TIME, parkingLights_ISR);
      isParkingLightTickerActive = true;
    }

  }
  else
  {
      ticker1.detach();
      isParkingLightTickerActive = false;
  }

  // process the booster light
  // it should not blink the light during brake
  if((rxData->throttlePWM > 1800) && (rxData->brakeActive == false) )
  { 
    #define TOOGLE_COUNTER_MAX 25
    if(isBoosterLightTurnOnFirstTime == false)
    {
      ticker2.attach(BOOSTER_LIGHT_TOOGLE_TIME, ToggleBoosterLight);
      isBoosterLightTurnOnFirstTime = true;
    }
    else if(gBoosterLightToggleCounter > TOOGLE_COUNTER_MAX)
    {
      ticker2.detach();
      digitalWrite(BOOSTER_LIGHTS, HIGH);
    }
    else
    {
      // Nothing to do
    }

  }
  else
  { 
      ticker2.detach();
      digitalWrite(BOOSTER_LIGHTS, LOW);
      isBoosterLightTurnOnFirstTime = false;
      gBoosterLightToggleCounter = 0;  
  }


}

void SpoilerOn(bool On)
{   
  // Read the Current Spoiler Postion
  uint8_t current_angle = spoiler.read();

  if(On)
  {

    for(uint8_t angle = current_angle; angle>=SPOILER_UP_ANGLE; angle-=2)
    {
        spoiler.write(angle);
    }

  }
  else
  {
    for(uint8_t angle = current_angle; angle<=SPOILER_DOWN_ANGLE; angle+=2)
    {
        spoiler.write(angle);
    }
  }
  
}



void parkingLights_ISR()
{
    // blink the parking lights with tone,
    static bool state = 0;
    state = state^1; // do the xor to flip the state
    digitalWrite(BAR_LIGHTS, state);
    digitalWrite(RED_LIGHTS, state);

    if(state)
    {
      tone(HORN_PIN, PARKING_LIGHT_FREQ, 1000);
    }
    else
    {
      noTone(HORN_PIN);
    }


}

void ToggleBoosterLight(void)
{
  static bool state = 0;
  state ^=1;
  digitalWrite(BOOSTER_LIGHTS,state);
  gBoosterLightToggleCounter++;

}


