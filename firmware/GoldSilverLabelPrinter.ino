/*
 * ============================================================================
 *  Gold & Silver Label Printer Bridge - ESP32 Firmware
 * ============================================================================
 *
 *  Hardware:
 *    - ESP32 DevKit (any variant with BLE)
 *    - TSC TTP-244 Pro printer  -> connected to ESP32 UART2 TX (GPIO17)
 *    - Weighing scale RS232 TX  -> connected to ESP32 UART1 RX (GPIO16)
 *      (RS232 voltage MUST be level-shifted via MAX3232 to 3.3V before ESP32 RX)
 *
 *  Roles:
 *    1. Continuously read ASCII weight stream from the weighing scale.
 *    2. Parse weight (Gross / Stable / Unstable / Net) and broadcast it over
 *       BLE notifications to the connected mobile app (Flutter).
 *    3. Receive label print jobs from the app over BLE (JSON), translate them
 *       to TSPL (TSC's printer language), and stream to the printer over UART.
 *    4. Provide tare/zero/reprint/status commands.
 *
 *  Author: Generated for Jitendra - Cowork mode
 *  License: MIT (use as you see fit, no warranty)
 * ============================================================================
 */

#include <Arduino.h>
#include <ArduinoJson.h>          // Install: ArduinoJson by Benoit Blanchon
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ---------------------- Pin Map ---------------------------------------------
#define SCALE_RX_PIN     16    // ESP32 RX1  (from MAX3232 RO pin -> scale RS232 TX)
#define SCALE_TX_PIN     -1    // not used (scale is one-way)
#define PRINTER_TX_PIN   17    // ESP32 TX2  -> TSC printer RX (TTL 3.3V or via level shifter)
#define PRINTER_RX_PIN   -1    // not used (we don't read back)
#define LED_PIN           2    // built-in LED

#define SCALE_BAUD     9600    // most Indian shop scales: 9600 8N1
#define PRINTER_BAUD   9600    // TSC TTP-244 Pro default

// ---------------------- BLE UUIDs -------------------------------------------
// Custom 128-bit UUIDs - keep these in sync with the Flutter app.
#define SERVICE_UUID         "6f0a0001-7b9a-4e9f-9b46-1d7b3a2c0001"
#define CHAR_WEIGHT_UUID     "6f0a0002-7b9a-4e9f-9b46-1d7b3a2c0001"  // NOTIFY  (weight stream)
#define CHAR_COMMAND_UUID    "6f0a0003-7b9a-4e9f-9b46-1d7b3a2c0001"  // WRITE   (app -> ESP)
#define CHAR_STATUS_UUID     "6f0a0004-7b9a-4e9f-9b46-1d7b3a2c0001"  // NOTIFY  (job/status feedback)

// ---------------------- Globals ---------------------------------------------
HardwareSerial ScaleSerial(1);
HardwareSerial PrinterSerial(2);

BLEServer*         pServer        = nullptr;
BLECharacteristic* pCharWeight    = nullptr;
BLECharacteristic* pCharCommand   = nullptr;
BLECharacteristic* pCharStatus    = nullptr;
bool               deviceConnected = false;

// Latest parsed reading
struct WeightReading {
  float grams = 0.0f;
  bool  stable = false;
  bool  isNet  = false;        // some scales send Gross or Net depending on tare state
  uint32_t tsMs = 0;
};
WeightReading latest;
float tareGrams = 0.0f;        // app-driven tare offset

// Scale ASCII line buffer
char scaleBuf[64];
uint8_t scaleIdx = 0;

unsigned long lastWeightPushMs = 0;
const unsigned long WEIGHT_PUSH_INTERVAL_MS = 200;   // 5 Hz to BLE

// ============================================================================
//                              BLE CALLBACKS
// ============================================================================
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s)    override { deviceConnected = true;  digitalWrite(LED_PIN, HIGH); }
  void onDisconnect(BLEServer* s) override { deviceConnected = false; digitalWrite(LED_PIN, LOW);
                                             BLEDevice::startAdvertising(); }
};

// ============================================================================
//                          TSPL COMMAND BUILDER
//   TSC TTP-244 Pro speaks TSPL/TSPL2. We build the label as a sequence of
//   plain-text TSPL lines terminated by \r\n and stream them over UART.
//   See "TSPL/TSPL2 Programming Manual" from TSC for the full command set.
// ============================================================================
void tsplBegin(uint16_t widthMm, uint16_t heightMm, uint8_t gapMm = 3,
               uint8_t density = 8, uint8_t speed = 4) {
  PrinterSerial.printf("SIZE %d mm,%d mm\r\n", widthMm, heightMm);
  PrinterSerial.printf("GAP %d mm,0\r\n", gapMm);
  PrinterSerial.printf("DENSITY %d\r\n", density);
  PrinterSerial.printf("SPEED %d\r\n", speed);
  PrinterSerial.print("DIRECTION 1\r\n");
  PrinterSerial.print("CLS\r\n");
}

// Print text. Font sizes: "1"-"8" (built-in), TSS24.BF2 etc. (Asian).
// x,y in dots (203dpi -> 8 dots/mm).
void tsplText(int x, int y, const String& font, int rot, int xmul, int ymul,
              const String& text) {
  PrinterSerial.printf("TEXT %d,%d,\"%s\",%d,%d,%d,\"%s\"\r\n",
                       x, y, font.c_str(), rot, xmul, ymul, text.c_str());
}

// 1D barcode. type: "128", "39", "EAN13" etc.
void tsplBarcode(int x, int y, const String& type, int height, int humanReadable,
                 int rot, int narrow, int wide, const String& data) {
  PrinterSerial.printf("BARCODE %d,%d,\"%s\",%d,%d,%d,%d,%d,\"%s\"\r\n",
                       x, y, type.c_str(), height, humanReadable, rot, narrow, wide, data.c_str());
}

// QR code. cellWidth 1-10, ecc "L"/"M"/"Q"/"H", mode A=auto.
void tsplQR(int x, int y, const String& ecc, int cellWidth, const String& mode,
            int rot, const String& data) {
  PrinterSerial.printf("QRCODE %d,%d,%s,%d,%s,%d,\"%s\"\r\n",
                       x, y, ecc.c_str(), cellWidth, mode.c_str(), rot, data.c_str());
}

// Box/line primitives - useful when the designer adds rectangles or rules.
void tsplBox(int x, int y, int xEnd, int yEnd, int thickness) {
  PrinterSerial.printf("BOX %d,%d,%d,%d,%d\r\n", x, y, xEnd, yEnd, thickness);
}

// Embedded PCX/BMP logo previously stored in printer flash via DOWNLOAD command.
// For dynamic logos, the app should send a base64 PNG and we'd PUTBMP it - left
// as an exercise (PUTBMP needs binary, increases firmware complexity).
void tsplLogo(int x, int y, const String& storedName) {
  PrinterSerial.printf("PUTBMP %d,%d,\"%s\"\r\n", x, y, storedName.c_str());
}

void tsplPrint(uint16_t copies = 1) {
  PrinterSerial.printf("PRINT 1,%d\r\n", copies);
}

// ============================================================================
//                       JSON PRINT JOB INTERPRETER
//
//   Expected BLE payload (one notification, app can chunk if > MTU):
//   {
//     "cmd": "print",
//     "label": { "w": 50, "h": 25, "gap": 3 },
//     "copies": 1,
//     "elements": [
//        {"type":"text", "x":10,  "y":10,  "font":"3", "rot":0, "xs":1, "ys":1, "text":"Pure Gold"},
//        {"type":"text", "x":10,  "y":40,  "font":"2", "text":"Gross: 12.345 g"},
//        {"type":"qr",   "x":250, "y":10,  "ecc":"M",  "size":4, "data":"PROD-001|12.345"},
//        {"type":"bar",  "x":10,  "y":120, "btype":"128", "height":60, "data":"AB123"},
//        {"type":"logo", "x":10,  "y":170, "name":"LOGO.BMP"}
//     ]
//   }
//
//   Other commands:  {"cmd":"tare"}, {"cmd":"zero"}, {"cmd":"status"},
//                    {"cmd":"feed","mm":5}, {"cmd":"raw","tspl":"..."}
// ============================================================================
void notifyStatus(const String& code, const String& msg) {
  if (!deviceConnected) return;
  StaticJsonDocument<160> doc;
  doc["status"] = code;
  doc["msg"]    = msg;
  char out[160];
  size_t n = serializeJson(doc, out, sizeof(out));
  pCharStatus->setValue((uint8_t*)out, n);
  pCharStatus->notify();
}

void executePrintJob(JsonDocument& doc) {
  JsonObject label = doc["label"];
  uint16_t w   = label["w"]   | 50;
  uint16_t h   = label["h"]   | 25;
  uint8_t  gap = label["gap"] | 3;
  uint16_t copies = doc["copies"] | 1;

  tsplBegin(w, h, gap);

  for (JsonObject e : doc["elements"].as<JsonArray>()) {
    String type = e["type"] | "";
    int x = e["x"] | 0;
    int y = e["y"] | 0;

    if (type == "text") {
      tsplText(x, y, e["font"] | "3", e["rot"] | 0,
               e["xs"] | 1, e["ys"] | 1, e["text"] | "");
    } else if (type == "qr") {
      tsplQR(x, y, e["ecc"] | "M", e["size"] | 4, e["mode"] | "A",
             e["rot"] | 0, e["data"] | "");
    } else if (type == "bar") {
      tsplBarcode(x, y, e["btype"] | "128", e["height"] | 60,
                  e["hr"] | 1, e["rot"] | 0,
                  e["narrow"] | 2, e["wide"] | 2, e["data"] | "");
    } else if (type == "box") {
      tsplBox(x, y, e["xe"] | (x+50), e["ye"] | (y+50), e["t"] | 2);
    } else if (type == "logo") {
      tsplLogo(x, y, e["name"] | "LOGO.BMP");
    }
  }
  tsplPrint(copies);
  notifyStatus("ok", "printed");
}

void handleCommand(const std::string& payload) {
  StaticJsonDocument<2048> doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) {
    notifyStatus("err", String("json:") + err.c_str());
    return;
  }
  String cmd = doc["cmd"] | "";

  if (cmd == "print") {
    executePrintJob(doc);
  } else if (cmd == "tare") {
    tareGrams = latest.grams;
    notifyStatus("ok", "tared");
  } else if (cmd == "zero") {
    tareGrams = 0.0f;
    notifyStatus("ok", "zeroed");
  } else if (cmd == "feed") {
    int mm = doc["mm"] | 5;
    PrinterSerial.printf("FORMFEED\r\n");           // or "FEED %d\r\n" - varies
    notifyStatus("ok", String("feed:") + mm);
  } else if (cmd == "raw") {
    String raw = doc["tspl"] | "";
    PrinterSerial.print(raw);
    PrinterSerial.print("\r\n");
    notifyStatus("ok", "raw-sent");
  } else if (cmd == "status") {
    notifyStatus("ok", String("g=") + latest.grams + ",tare=" + tareGrams);
  } else {
    notifyStatus("err", "unknown-cmd");
  }
}

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.length()) handleCommand(v);
  }
};

// ============================================================================
//                       SCALE ASCII STREAM PARSER
//
//   Continuous-mode scales (Essae, Avery, Sansui, Phoenix Alpha, etc.) emit
//   one line per reading. Common Indian formats include:
//
//      "ST,GS,  +12.345 g\r\n"   <- stable, gross
//      "US,NT,  +00.000 g\r\n"   <- unstable, net
//      "  +12.345 g\r\n"         <- bare format
//
//   Strategy: collect bytes until \r or \n, then extract status flags and the
//   first floating-point number we can find. Unit is assumed grams; you can
//   add conversion if the scale streams kg.
// ============================================================================
void parseScaleLine(const char* line) {
  // Detect stability marker
  latest.stable = (strstr(line, "ST") != nullptr) ||
                  (strstr(line, "S ")  != nullptr);
  latest.isNet  = (strstr(line, "NT") != nullptr) ||
                  (strstr(line, "NET") != nullptr);

  // Find first +/-/digit
  const char* p = line;
  while (*p && !(*p == '+' || *p == '-' || (*p >= '0' && *p <= '9'))) p++;
  if (!*p) return;

  char numbuf[16] = {0};
  uint8_t i = 0;
  while (*p && i < sizeof(numbuf)-1 &&
         (*p == '+' || *p == '-' || *p == '.' || (*p >= '0' && *p <= '9'))) {
    numbuf[i++] = *p++;
  }
  numbuf[i] = 0;
  float v = atof(numbuf);

  // Crude unit detection
  if (strstr(line, "kg") || strstr(line, "KG")) v *= 1000.0f;

  latest.grams = v;
  latest.tsMs  = millis();
}

void serviceScale() {
  while (ScaleSerial.available()) {
    char ch = (char)ScaleSerial.read();
    if (ch == '\r' || ch == '\n') {
      if (scaleIdx > 0) {
        scaleBuf[scaleIdx] = 0;
        parseScaleLine(scaleBuf);
        scaleIdx = 0;
      }
    } else if (scaleIdx < sizeof(scaleBuf)-1) {
      scaleBuf[scaleIdx++] = ch;
    } else {
      scaleIdx = 0;   // overflow -> reset
    }
  }
}

void pushWeightOverBLE() {
  if (!deviceConnected) return;
  if (millis() - lastWeightPushMs < WEIGHT_PUSH_INTERVAL_MS) return;
  lastWeightPushMs = millis();

  StaticJsonDocument<128> doc;
  doc["g"]      = latest.grams;            // raw gross from scale (grams)
  doc["t"]      = tareGrams;               // current tare offset
  doc["n"]      = latest.grams - tareGrams;// net
  doc["s"]      = latest.stable ? 1 : 0;
  doc["ts"]     = latest.tsMs;
  char out[128];
  size_t n = serializeJson(doc, out, sizeof(out));
  pCharWeight->setValue((uint8_t*)out, n);
  pCharWeight->notify();
}

// ============================================================================
//                              SETUP / LOOP
// ============================================================================
void setup() {
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  Serial.begin(115200);
  Serial.println("\n[BOOT] Gold/Silver Label Bridge starting...");

  ScaleSerial.begin(SCALE_BAUD,   SERIAL_8N1, SCALE_RX_PIN, SCALE_TX_PIN);
  PrinterSerial.begin(PRINTER_BAUD, SERIAL_8N1, PRINTER_RX_PIN, PRINTER_TX_PIN);

  // ----- BLE setup -----
  BLEDevice::init("GS-LABEL-BRIDGE");
  BLEDevice::setMTU(247);                  // larger MTU = fewer chunks for print jobs
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* svc = pServer->createService(SERVICE_UUID);

  pCharWeight = svc->createCharacteristic(CHAR_WEIGHT_UUID,
                  BLECharacteristic::PROPERTY_NOTIFY);
  pCharWeight->addDescriptor(new BLE2902());

  pCharCommand = svc->createCharacteristic(CHAR_COMMAND_UUID,
                  BLECharacteristic::PROPERTY_WRITE |
                  BLECharacteristic::PROPERTY_WRITE_NR);
  pCharCommand->setCallbacks(new CommandCallbacks());

  pCharStatus = svc->createCharacteristic(CHAR_STATUS_UUID,
                  BLECharacteristic::PROPERTY_NOTIFY);
  pCharStatus->addDescriptor(new BLE2902());

  svc->start();
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] Advertising as 'GS-LABEL-BRIDGE'");
}

void loop() {
  serviceScale();
  pushWeightOverBLE();
  // BLE writes are handled in CommandCallbacks::onWrite asynchronously.
  delay(2);
}
