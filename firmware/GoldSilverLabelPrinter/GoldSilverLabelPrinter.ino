/*
 * ============================================================================
 *  Gold & Silver Label Printer Bridge — ESP32 Firmware
 * ============================================================================
 *
 *  Hardware (matches original JBCTAG wiring — no rewiring needed):
 *    - Scale  RS232 TX → MAX3232 → ESP32 GPIO16 (UART1 RX)
 *    - TSC TTP-244 Pro RS232 RX ← MAX3232 ← ESP32 GPIO1  (UART0 TX = Serial)
 *    - Flutter App ↔ ESP32 BLE GATT
 *    - Print button → GPIO13 (active LOW, internal pull-up)
 *    - Status LED   → GPIO2
 *
 *  Printer uses Serial (UART0 / GPIO1 TX) at 9600 baud — identical to the
 *  original JBCTAG firmware.  Debug messages also arrive at the printer but
 *  TSPL ignores unrecognised strings, so this is harmless.
 *
 *  BLE replaces Classic-BT SPP.  The Flutter app (flutter_blue_plus) uses
 *  BLE GATT; Classic-BT SPP is gone.
 *
 *  KEY FIX:  flutter_blue_plus splits JSON > 244 bytes across multiple BLE
 *            writes.  Fix: accumulate chunks in bleBuffer until JSON braces
 *            balance, then parse once.
 * ============================================================================
 */

#include <Arduino.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Preferences.h>    // NVS persistent storage for offline template

// ── Pin map ──────────────────────────────────────────────────────────────────
#define SCALE_RX_PIN   16    // UART1 RX  ← scale (via MAX3232) — GPIO16
// Printer TX = GPIO1 (UART0 / Serial) — same as original hardware

#define PRINT_BTN_PIN  13    // Active-LOW print button (INPUT_PULLUP)
#define LED_PIN         2    // Status LED

#define SCALE_BAUD    9600
#define PRINTER_BAUD  9600   // must match Serial.begin() below

// ── BLE UUIDs (must match Flutter app) ───────────────────────────────────────
#define SERVICE_UUID      "6f0a0001-7b9a-4e9f-9b46-1d7b3a2c0001"
#define CHAR_WEIGHT_UUID  "6f0a0002-7b9a-4e9f-9b46-1d7b3a2c0001"
#define CHAR_COMMAND_UUID "6f0a0003-7b9a-4e9f-9b46-1d7b3a2c0001"
#define CHAR_STATUS_UUID  "6f0a0004-7b9a-4e9f-9b46-1d7b3a2c0001"

// ── Globals ───────────────────────────────────────────────────────────────────
HardwareSerial ScaleSerial(1);   // UART1, GPIO16 RX
Preferences    prefs;            // NVS namespace "gslbl"

BLEServer*         pServer      = nullptr;
BLECharacteristic* pCharWeight  = nullptr;
BLECharacteristic* pCharCommand = nullptr;
BLECharacteristic* pCharStatus  = nullptr;
bool deviceConnected = false;

// BLE chunk reassembly buffer
String bleBuffer = "";

// Deferred command: set by BLE onWrite(), consumed by loop()
// This keeps the BLE task unblocked while Serial sends TSPL at 9600 baud.
volatile bool cmdReady  = false;
String        cmdBuffer = "";

// Last complete print-job JSON — used by button to reprint
String lastPrintJson = "";

// Scale state
struct WeightReading { float grams = 0; bool stable = false; uint32_t tsMs = 0; };
WeightReading latest;
float    tareGrams   = 0.0f;
char     scaleBuf[64];
uint8_t  scaleIdx    = 0;
bool     scaleInPkt  = false;   // true while inside a *…# packet
float    prevGrams   = -9999.0f;
uint32_t stableMs    = 0;       // millis() when weight last changed

unsigned long lastWeightPushMs = 0;
const unsigned long WEIGHT_PUSH_MS = 200;   // 5 Hz

// Button debounce
unsigned long btnPressMs = 0;
bool          btnArmed   = true;


// ── Forward declarations ──────────────────────────────────────────────────────
void notifyStatus(const String& code, const String& msg);
void handleCommand(const String& payload);
void executePrintJob(JsonDocument& doc);
void _sendOrientationTest(uint8_t dir);

// ============================================================================
//  TSPL helpers  →  Serial (UART0 GPIO1 TX) = same port as original firmware
// ============================================================================
inline void tspl(const char* s) { Serial.print(s); }

void tsplBegin(uint16_t w, uint16_t h, uint8_t gap = 3,
               uint8_t density = 8, uint8_t speed = 2, uint8_t dir = 0) {
  Serial.print("DOWNLOAD \"A.BAS\"\r\n");
  Serial.printf("SIZE %d mm,%d mm\r\n", w, h);
  Serial.printf("GAP %d mm,0\r\n", gap);
  Serial.printf("DENSITY %d\r\n", density);
  Serial.printf("SPEED %d\r\n", speed);
  Serial.print("SET TEAR ON\r\n");
  // dir=0: origin top-left (matches designer canvas). dir=1: rotated 180° for flipped printers.
  Serial.printf("DIRECTION %d\r\n", dir);
  Serial.print("CLS\r\n");
}

void tsplText(int x, int y, const String& font, int rot,
              int xm, int ym, const String& text) {
  Serial.printf("TEXT %d,%d,\"%s\",%d,%d,%d,\"%s\"\r\n",
                x, y, font.c_str(), rot, xm, ym, text.c_str());
}

void tsplQR(int x, int y, const String& ecc, int cell,
            const String& mode, int rot, const String& data) {
  Serial.printf("QRCODE %d,%d,%s,%d,%s,%d,\"%s\"\r\n",
                x, y, ecc.c_str(), cell, mode.c_str(), rot, data.c_str());
}

void tsplBarcode(int x, int y, const String& type, int h, int hr, int rot,
                 int narrow, int wide, const String& data) {
  Serial.printf("BARCODE %d,%d,\"%s\",%d,%d,%d,%d,%d,\"%s\"\r\n",
                x, y, type.c_str(), h, hr, rot, narrow, wide, data.c_str());
}

void tsplBox(int x, int y, int xe, int ye, int thick) {
  Serial.printf("BOX %d,%d,%d,%d,%d\r\n", x, y, xe, ye, thick);
}

void tsplLogo(int x, int y, const String& name) {
  Serial.printf("PUTBMP %d,%d,\"%s\"\r\n", x, y, name.c_str());
}

void tsplPrint(uint16_t copies = 1) {
  Serial.printf("PRINT 1,%d\r\n", copies);
  Serial.print("EOP\r\n");
  Serial.print("A\r\n");
}

// ============================================================================
//  BLE status notification
// ============================================================================
void notifyStatus(const String& code, const String& msg) {
  if (!deviceConnected || !pCharStatus) return;
  StaticJsonDocument<160> doc;
  doc["status"] = code;
  doc["msg"]    = msg;
  char out[160];
  size_t n = serializeJson(doc, out, sizeof(out));
  pCharStatus->setValue((uint8_t*)out, n);
  pCharStatus->notify();
}

// ============================================================================
//  Print job executor
// ============================================================================
void executePrintJob(JsonDocument& doc) {
  JsonObject label  = doc["label"];
  uint16_t w        = label["w"]        | 50;
  uint16_t h        = label["h"]        | 25;
  uint8_t  gap      = label["gap"]      | 3;
  uint8_t  darkness = label["darkness"] | 8;
  uint8_t  dir      = label["dir"]      | 0;   // 0=normal, 1=rotated 180° for flipped printers
  uint16_t copies   = doc["copies"]     | 1;

  tsplBegin(w, h, gap, darkness, 2, dir);

  for (JsonObject e : doc["elements"].as<JsonArray>()) {
    String type = e["type"] | "";
    int x = e["x"] | 0;
    int y = e["y"] | 0;

    if (type == "text") {
      String txt = e["text"] | "";
      txt.replace("\"", "'");
      tsplText(x, y, e["font"] | "3", e["rot"] | 0, e["xs"] | 1, e["ys"] | 1, txt);

    } else if (type == "qr") {
      String d = e["data"] | ""; d.replace("\"", "'");
      tsplQR(x, y, e["ecc"] | "M", e["size"] | 4, e["mode"] | "A", e["rot"] | 0, d);

    } else if (type == "bar") {
      String d = e["data"] | ""; d.replace("\"", "'");
      tsplBarcode(x, y, e["btype"] | "128", e["height"] | 60,
                  e["hr"] | 1, e["rot"] | 0, e["narrow"] | 2, e["wide"] | 2, d);

    } else if (type == "box") {
      tsplBox(x, y, e["xe"] | (x + 50), e["ye"] | (y + 50), e["t"] | 2);

    } else if (type == "logo") {
      const char* bmpHex = e["bmp"] | "";
      int bw = e["bw"] | 0;
      int bh = e["lh"] | 0;   // height in dots
      if (strlen(bmpHex) > 0 && bw > 0 && bh > 0) {
        // Inline TSPL BITMAP: decode hex pairs to raw bytes
        Serial.printf("BITMAP %d,%d,%d,%d,0,", x, y, bw, bh);
        for (int i = 0; bmpHex[i] != '\0' && bmpHex[i+1] != '\0'; i += 2) {
          char nibbles[3] = { bmpHex[i], bmpHex[i+1], '\0' };
          Serial.write((uint8_t)strtol(nibbles, nullptr, 16));
        }
        Serial.print("\r\n");
      } else {
        tsplLogo(x, y, e["name"] | "LOGO.BMP");
      }
    }
  }

  tsplPrint(copies);
  notifyStatus("ok", "printed");
}

// ============================================================================
//  Orientation test print — prints a 50×25mm label with corner labels so the
//  user can verify which direction is "normal" for their printer.
// ============================================================================
void _sendOrientationTest(uint8_t dir) {
  Serial.print("DOWNLOAD \"A.BAS\"\r\n");
  Serial.print("SIZE 50 mm,25 mm\r\n");
  Serial.print("GAP 3 mm,0\r\n");
  Serial.printf("DIRECTION %d\r\n", dir);
  Serial.print("SET TEAR ON\r\n");
  Serial.print("DENSITY 8\r\n");
  Serial.print("CLS\r\n");
  // Corner labels so user can see which edge is the origin
  Serial.print("TEXT 8,8,\"2\",0,1,1,\"TOP-LEFT\"\r\n");
  Serial.print("TEXT 8,60,\"2\",0,1,1,\"BOTTOM-LEFT\"\r\n");
  // Direction indicator centred
  Serial.printf("TEXT 100,30,\"3\",0,1,1,\"%s\"\r\n",
                dir == 0 ? "DIR 0 - NORMAL" : "DIR 1 - ROTATED 180");
  // Barcode in lower half to distinguish orientation visually
  Serial.print("BARCODE 8,110,\"128\",40,1,0,2,2,\"ORIENT-TEST\"\r\n");
  Serial.print("PRINT 1,1\r\n");
  Serial.print("EOP\r\n");
  Serial.print("A\r\n");
}

// ============================================================================
//  Command dispatcher
// ============================================================================
void handleCommand(const String& payload) {
  DynamicJsonDocument doc(4096);
  DeserializationError err = deserializeJson(doc, payload);
  if (err) {
    notifyStatus("err", String("json:") + err.c_str());
    return;
  }

  String cmd = doc["cmd"] | "";

  if (cmd == "print") {
    lastPrintJson = payload;   // save in RAM for immediate button reprint
    savePrintJobToNvs(payload); // persist to NVS for power-cycle survival
    executePrintJob(doc);

  } else if (cmd == "tare") {
    tareGrams = latest.grams;
    notifyStatus("ok", "tared");

  } else if (cmd == "zero") {
    tareGrams = 0;
    notifyStatus("ok", "zeroed");

  } else if (cmd == "feed") {
    Serial.print("FORMFEED\r\n");
    notifyStatus("ok", "feed");

  } else if (cmd == "test_print") {
    // Orientation test print — dir 0 or 1
    uint8_t dir = doc["dir"] | 0;
    _sendOrientationTest(dir);
    notifyStatus("ok", "test-print");

  } else if (cmd == "raw") {
    String r = doc["tspl"] | "";
    Serial.print(r);
    Serial.print("\r\n");
    notifyStatus("ok", "raw-sent");

  } else if (cmd == "status") {
    String s = "g=" + String(latest.grams, 3) + ",t=" + String(tareGrams, 3);
    notifyStatus("ok", s);

  } else {
    notifyStatus("err", "unknown:" + cmd);
  }
}

// ============================================================================
//  Test print — hardcoded label, no BLE needed.
//  Uses same TSPL2 DOWNLOAD mode as original JBCTAG firmware.
//  Fires on boot AND when button pressed with no prior app job.
// ============================================================================
void sendTestPrint() {
  // DOWNLOAD mode matches original JBCTAG SLIP_PRINT()
  Serial.print("DOWNLOAD \"A.BAS\"\r\n");
  Serial.print("DENSITY 9\r\n");
  Serial.print("SIZE 81 mm,13 mm\r\n");
  Serial.print("GAP 2.5 mm,0 mm\r\n");
  Serial.print("DIRECTION 0\r\n");
  Serial.print("SET TEAR ON\r\n");
  Serial.print("CLS\r\n");
  Serial.print("TEXT 40,5,\"2\",0,1,1,\"GS-LABEL TEST\"\r\n");
  Serial.print("TEXT 40,42,\"2\",0,1,1,\"BLE FIRMWARE OK\"\r\n");
  Serial.print("PRINT 1,1\r\n");
  Serial.print("EOP\r\n");
  Serial.print("A\r\n");
}

// ============================================================================
//  NVS helpers — persist last print template for offline button printing
// ============================================================================

// Strip large BITMAP data from logo elements before saving to NVS.
// The stripped copy falls back to PUTBMP (printer-stored file) in offline mode.
void savePrintJobToNvs(const String& jsonStr) {
  DynamicJsonDocument doc(8192);
  if (deserializeJson(doc, jsonStr) != DeserializationError::Ok) return;
  // Remove bmp hex from logo elements to stay within NVS 4 KB limit
  for (JsonObject e : doc["elements"].as<JsonArray>()) {
    if (String(e["type"] | "") == "logo") e.remove("bmp");
  }
  String stripped;
  serializeJson(doc, stripped);
  if (stripped.length() < 3900) {
    prefs.putString("lastJob", stripped);
  }
  // If still too large (e.g. many elements), skip NVS — RAM copy still used
}

// ============================================================================
//  Button reprint — with live-weight substitution for weight-tagged elements.
//  Priority: RAM lastPrintJson → NVS stored job → hardcoded test print.
// ============================================================================
void buttonReprint() {
  digitalWrite(LED_PIN, LOW); delay(80); digitalWrite(LED_PIN, HIGH);

  String jobStr = lastPrintJson;
  if (jobStr.isEmpty()) {
    jobStr = prefs.getString("lastJob", "");
  }
  if (jobStr.isEmpty()) {
    sendTestPrint();
    return;
  }

  DynamicJsonDocument doc(8192);
  if (deserializeJson(doc, jobStr) != DeserializationError::Ok) {
    sendTestPrint();
    return;
  }

  // ── Substitute live weight into elements tagged with wt_var ────────────────
  float netG = latest.grams - tareGrams;
  if (netG < 0) netG = 0;

  for (JsonObject e : doc["elements"].as<JsonArray>()) {
    const char* wv = e["wt_var"] | "";
    if (!*wv) continue;

    float g = 0;
    if      (strcmp(wv, "net")   == 0) g = netG;
    else if (strcmp(wv, "gross") == 0) g = latest.grams;
    else if (strcmp(wv, "tare")  == 0) g = tareGrams;
    else if (strcmp(wv, "metal") == 0) g = netG;
    else continue;  // stone: keep stored value

    const char* pre = e["pre"] | "";
    const char* suf = e["suf"] | "";
    char buf[64];
    snprintf(buf, sizeof(buf), "%s%.3f g%s", pre, g < 0 ? 0.0f : g, suf);
    e["text"] = (const char*)buf;
  }

  executePrintJob(doc);
  notifyStatus("ok", "btn-print");
}

// ============================================================================
//  BLE chunk reassembly
// ============================================================================
bool isJsonComplete(const String& s) {
  int  depth   = 0;
  bool inStr   = false;
  bool esc     = false;
  bool started = false;
  for (char c : s) {
    if (esc)               { esc = false; continue; }
    if (c == '\\' && inStr){ esc = true;  continue; }
    if (c == '"')          { inStr = !inStr; continue; }
    if (inStr)             continue;
    if (c == '{')          { depth++; started = true; }
    else if (c == '}')     { depth--; if (started && depth == 0) return true; }
  }
  return false;
}

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.empty()) return;
    bleBuffer += String(v.c_str());
    if (isJsonComplete(bleBuffer)) {
      // Hand off to loop() — never call Serial inside BLE task.
      // Serial.printf() at 9600 baud blocks for ~260 ms per label,
      // preventing Write Responses and breaking the second print.
      if (!cmdReady) {   // drop if loop hasn't consumed previous yet
        cmdBuffer = bleBuffer;
        cmdReady  = true;
      }
      bleBuffer = "";
    }
  }
};

// ============================================================================
//  BLE server callbacks
// ============================================================================
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    deviceConnected = true;
    bleBuffer = "";
    digitalWrite(LED_PIN, HIGH);
  }
  void onDisconnect(BLEServer*) override {
    deviceConnected = false;
    bleBuffer = "";
    digitalWrite(LED_PIN, LOW);
    BLEDevice::startAdvertising();
  }
};

// ============================================================================
//  Scale ASCII parser
// ============================================================================
// Throttle for scale raw diagnostic forwarding
uint32_t lastScaleDiagMs = 0;

void parseScaleLine(const char* line) {
  // Forward raw line via BLE status every 2 s for diagnostics (Scale Debug panel in app)
  if (millis() - lastScaleDiagMs >= 2000) {
    lastScaleDiagMs = millis();
    notifyStatus("scale", String(line));
  }

  // Find start of numeric value — skip all non-numeric except sign
  const char* p = line;
  while (*p && !((*p >= '0' && *p <= '9') || *p == '+' || *p == '-')) p++;
  if (!*p) return;

  char nb[20] = {0}; uint8_t i = 0;

  // Capture optional sign, then skip spaces between sign and digits (e.g. "+ 5.620")
  if (*p == '+' || *p == '-') {
    if (*p == '-') nb[i++] = '-';   // keep negative sign; drop '+'
    p++;
    while (*p == ' ') p++;           // skip space between sign and digits
  }

  // Capture digits and decimal point
  while (*p && i < 19 && (*p == '.' || (*p >= '0' && *p <= '9'))) nb[i++] = *p++;

  if (i == 0) return;

  float v = atof(nb);

  // Unit conversion
  if (strstr(line, " kg") || strstr(line, " KG") || strstr(line, ",kg") || strstr(line, ",KG")) {
    v *= 1000.0f;
  } else if (strstr(line, " lb") || strstr(line, " LB")) {
    v *= 453.592f;
  } else if (strstr(line, " mg") || strstr(line, " MG")) {
    v /= 1000.0f;
  }

  // Time-based stability: stable if weight unchanged (±0.5g) for 1.5 s.
  // The original JBCTAG scale sends no stability token — we derive it from motion.
  if (fabsf(v - prevGrams) > 0.5f) {
    prevGrams = v;
    stableMs  = millis();
    latest.stable = false;
  } else {
    latest.stable = (millis() - stableMs >= 1500);
  }

  // Also honour any explicit stability markers (standard scale protocols)
  if (strstr(line, "ST") || strstr(line, "SB") || strstr(line, "STABLE"))
    latest.stable = true;
  if (strstr(line, "US,") || strstr(line, "US ") || strstr(line, "OL") ||
      strstr(line, "UNSTABLE"))
    latest.stable = false;

  latest.grams = v;
  latest.tsMs  = millis();
}

// Dual-mode scale reader:
//   Format A — original JBCTAG hardware:  *5.620#   (star = start, hash = end)
//   Format B — standard RS232 scales:     "ST,GS,+  5.620 g\r\n"
void serviceScale() {
  while (ScaleSerial.available()) {
    char ch = ScaleSerial.read();

    // ── Format A: *…# packet ─────────────────────────────────────────────────
    if (ch == '*') {
      scaleIdx   = 0;
      scaleInPkt = true;
      continue;
    }
    if (scaleInPkt) {
      if (ch == '#') {
        if (scaleIdx > 0) { scaleBuf[scaleIdx] = 0; parseScaleLine(scaleBuf); }
        scaleIdx   = 0;
        scaleInPkt = false;
      } else if (scaleIdx < (int)sizeof(scaleBuf) - 1) {
        scaleBuf[scaleIdx++] = ch;
      } else {
        scaleIdx   = 0;   // overflow — discard and resync
        scaleInPkt = false;
      }
      continue;
    }

    // ── Format B: newline-terminated ────────────────────────────────────────
    if (ch == '\r' || ch == '\n') {
      if (scaleIdx > 0) { scaleBuf[scaleIdx] = 0; parseScaleLine(scaleBuf); scaleIdx = 0; }
    } else if (scaleIdx < (int)sizeof(scaleBuf) - 1) {
      scaleBuf[scaleIdx++] = ch;
    } else { scaleIdx = 0; }
  }
}

void pushWeightOverBLE() {
  if (!deviceConnected) return;
  if (millis() - lastWeightPushMs < WEIGHT_PUSH_MS) return;
  lastWeightPushMs = millis();

  StaticJsonDocument<128> doc;
  doc["g"]  = latest.grams;
  doc["t"]  = tareGrams;
  doc["n"]  = latest.grams - tareGrams;
  doc["s"]  = latest.stable ? 1 : 0;
  doc["ts"] = latest.tsMs;
  char out[128];
  size_t n = serializeJson(doc, out, sizeof(out));
  pCharWeight->setValue((uint8_t*)out, n);
  pCharWeight->notify();
}

// ============================================================================
//  Setup
// ============================================================================
void setup() {
  pinMode(LED_PIN,      OUTPUT);
  pinMode(PRINT_BTN_PIN, INPUT_PULLUP);
  digitalWrite(LED_PIN, LOW);

  // UART0 / Serial = printer at 9600 baud (GPIO1 TX → MAX3232 → TSC printer)
  // Same as original JBCTAG firmware.  Debug text also flows here; printer
  // ignores non-TSPL lines.
  Serial.begin(PRINTER_BAUD);

  // Scale UART1 (GPIO16 RX)
  ScaleSerial.begin(SCALE_BAUD, SERIAL_8N1, SCALE_RX_PIN, -1);

  // BLE
  BLEDevice::init("GS-LABEL-BRIDGE");
  BLEDevice::setMTU(247);
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

  // BLE advertising — 31-byte limit per packet.
  // Name "GS-LABEL-BRIDGE"=17 bytes + 128-bit UUID=18 bytes = 35 bytes → overflow.
  // Fix: name in main ad packet, service UUID in scan response.
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->setMinPreferred(0x06);
  adv->setMaxPreferred(0x12);

  BLEAdvertisementData advData;
  advData.setName("GS-LABEL-BRIDGE");   // 17 bytes — fits in 31
  adv->setAdvertisementData(advData);

  BLEAdvertisementData scanData;
  scanData.setCompleteServices(BLEUUID(SERVICE_UUID));  // 18 bytes in scan response
  adv->setScanResponseData(scanData);

  BLEDevice::startAdvertising();

  // Open NVS namespace — load persisted print job if any
  prefs.begin("gslbl", false);
  String storedJob = prefs.getString("lastJob", "");
  if (storedJob.length() > 10) {
    lastPrintJson = storedJob;  // restore last template into RAM on boot
  }

  // Boot test print — fires 3 s after power-on, no BLE needed.
  delay(3000);
  sendTestPrint();

  digitalWrite(LED_PIN, LOW);
}

// ============================================================================
//  Loop
// ============================================================================
void loop() {
  serviceScale();
  pushWeightOverBLE();

  // Process BLE command on the Arduino task — keeps BLE task free to ACK writes
  if (cmdReady) {
    cmdReady = false;
    handleCommand(cmdBuffer);
    cmdBuffer = "";
  }

  // Physical print button (GPIO13, active LOW) — reprints last app job
  bool btnDown = (digitalRead(PRINT_BTN_PIN) == LOW);
  if (btnDown && btnArmed && (millis() - btnPressMs > 300)) {
    btnArmed   = false;
    btnPressMs = millis();
    buttonReprint();
  }
  if (!btnDown) btnArmed = true;

  delay(2);
}