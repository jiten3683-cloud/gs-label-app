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
#include <qrcode.h>         // esp_qrcode: draws QRs holding Tab/Enter as bitmaps

// ── Pin map ──────────────────────────────────────────────────────────────────
#define SCALE_RX_PIN   16    // UART1 RX  ← scale (via MAX3232) — GPIO16
// Printer TX = GPIO1 (UART0 / Serial) — same as original hardware

#define PRINT_BTN_PIN  13    // Active-LOW print button (INPUT_PULLUP)
#define LED_PIN        12    // BT status LED — HIGH=on, LOW=off (original JBCTAG BT_LED pin)
#define PRINT_LED_PIN  14    // Print activity LED (original JBCTAG Pirtn_LED pin)

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
bool     deviceConnected    = false;
bool     doStartAdv         = false;   // deferred re-advertise after disconnect
uint32_t disconnectMs       = 0;

// BLE chunk reassembly buffer
String bleBuffer = "";

// Deferred command: set by BLE onWrite(), consumed by loop()
// This keeps the BLE task unblocked while Serial sends TSPL at 9600 baud.
volatile bool cmdReady  = false;
String        cmdBuffer = "";

// Last complete print-job JSON — used by button to reprint
String lastPrintJson = "";

// Serial number: the last number used. App prints set it (from the job's "sn"),
// button and auto prints advance it, so all three share one running sequence.
uint32_t snLast     = 0;        // NVS "snN"

// Wall clock from the app (local-time epoch seconds, set by "sync" on every
// connect), carried forward with millis(). 0 until the app has connected since
// power-on — the ESP32 has no RTC. Print jobs don't set it: a reprint from
// Reports or the offline queue carries an old time.
uint32_t clockEpoch = 0;
uint32_t clockAtMs  = 0;

// Auto print (Settings → Auto Print in the app)
bool     autoOn       = false;  // NVS "auto"
float    autoMin      = 0.05f;  // NVS "autoMin" — minimum net, raw scale unit
bool     autoArmed    = false;  // pan must drop below autoMin/2 between items
uint32_t autoStableMs = 0;

// What a live print actually put on the label — reported to the app so the
// record matches the printed label exactly.
struct LiveValues {
  String   serial;
  uint32_t serialNo = 0;
  float    gross = 0, tare = 0, net = 0, stone = 0, metal = 0;
  float    amount = 0, making = 0;
  uint8_t  dec = 3;
  String   unit, date, time;
};

// Button/auto print records waiting for the app to reconnect (RAM only)
#define REC_PENDING_MAX 30
String  recPending[REC_PENDING_MAX];
uint8_t recPendN = 0;

// Scale state
// `value` is the number EXACTLY as the scale sent it — never unit-converted.
// `unit` is the unit token read off the same line ("g", "kg", "ct", …); empty if
// the scale sends none. `decimals` is how many digits followed the decimal point
// in the raw string, so the reprint reproduces the scale's own precision.
struct WeightReading {
  float    value    = 0;
  char     unit[6]  = "";
  uint8_t  decimals = 3;
  bool     stable   = false;
  uint32_t tsMs     = 0;
};
WeightReading latest;
float    tareGrams   = 0.0f;   // tare snapshot, in the same raw unit as latest.value
char     scaleBuf[64];
uint8_t  scaleIdx    = 0;
bool     scaleInPkt  = false;   // true while inside a *…# packet
float    prevValue   = -9999.0f;
uint32_t stableMs    = 0;       // millis() when weight last changed

unsigned long lastWeightPushMs = 0;
const unsigned long WEIGHT_PUSH_MS = 200;   // 5 Hz

// Button debounce
unsigned long btnPressMs   = 0;
bool          btnArmed     = true;
bool          btnLongFired = false;


// ── Forward declarations ──────────────────────────────────────────────────────
void notifyStatus(const String& code, const String& msg);
void handleCommand(const String& payload);
void executePrintJob(JsonDocument& doc);
void _sendOrientationTest(uint8_t dir);

// ============================================================================
//  TSPL helpers  →  Serial (UART0 GPIO1 TX) = same port as original firmware
// ============================================================================
inline void tspl(const char* s) { Serial.print(s); }

// Label size the gap sensor was last calibrated for. Persisted in NVS ("calW"/"calH")
// and restored in setup() — if this lived only in RAM, the first print after every
// power-on would re-run GAPDETECT and feed out several blank labels.
static uint16_t lastLabelW = 0, lastLabelH = 0;

void tsplBegin(uint16_t w, uint16_t h, uint8_t gap = 3,
               uint8_t density = 8, uint8_t speed = 2, uint8_t dir = 0) {
  // When label size changes, send SIZE+GAP as DIRECT commands first, then GAPDETECT.
  // GAPDETECT feeds one label so the printer re-learns the gap boundary — this prevents
  // content from landing in the inter-label gap after a media change.
  if (w != lastLabelW || h != lastLabelH) {
    Serial.printf("SIZE %d mm,%d mm\r\n", w, h);
    Serial.printf("GAP %d mm,0\r\n", gap);
    Serial.flush();
    delay(200);
    Serial.print("GAPDETECT\r\n");
    Serial.flush();
    // Small labels need more time: 20×10mm at speed-2 (50mm/s) may advance 150–200mm
    // of media to detect 5–6 gaps; allow 6 s to be safe.
    delay(h <= 15 ? 6000 : 4000);
    lastLabelW = w;
    lastLabelH = h;
    prefs.putUShort("calW", w);
    prefs.putUShort("calH", h);
  }
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



// esp_qrcode_generate() hands the finished symbol to a callback with no user
// pointer, so the drawing parameters travel in these.
static int qbX, qbY, qbCell, qbRot;

static void qrBitmapDraw(esp_qrcode_handle_t qr) {
  const int n = esp_qrcode_get_size(qr);
  const int dots = n * qbCell;
  const int bw = (dots + 7) / 8;
  // Rotation turns the symbol about its anchor the way QRCODE does, so the
  // anchor moves to the corner that ends up top-left.
  int x = qbX, y = qbY;
  if (qbRot == 90 || qbRot == 180) x -= dots;
  if (qbRot == 180 || qbRot == 270) y -= dots;
  x = max(0, x); y = max(0, y);
  Serial.printf("BITMAP %d,%d,%d,%d,0,", x, y, bw, dots);
  for (int py = 0; py < dots; py++) {
    for (int b = 0; b < bw; b++) {
      uint8_t v = 0;
      for (int bit = 0; bit < 8; bit++) {
        int px = b * 8 + bit;
        if (px >= dots) break;
        int mx = px / qbCell, my = py / qbCell, sx = mx, sy = my;
        if      (qbRot == 90)  { sx = my;         sy = n - 1 - mx; }
        else if (qbRot == 180) { sx = n - 1 - mx; sy = n - 1 - my; }
        else if (qbRot == 270) { sx = n - 1 - my; sy = mx; }
        if (esp_qrcode_get_module(qr, sx, sy)) v |= 0x80 >> bit;
      }
      // The TSC reads BITMAP bytes MSB first with bit 0 = black (checked
      // against printed labels 2026-09-30); rotation is already in the matrix.
      Serial.write((uint8_t)~v);
    }
  }
  Serial.print("\r\n");
}

// Draws the QR for [d] and prints it as a BITMAP, [cell] dots per module.
void qrBitmap(int x, int y, const String& ecc, int cell, int rot, const String& d) {
  qbX = x; qbY = y; qbCell = constrain(cell, 1, 10); qbRot = rot;
  esp_qrcode_config_t cfg = ESP_QRCODE_CONFIG_DEFAULT();
  cfg.display_func = qrBitmapDraw;
  cfg.max_qrcode_version = 20;
  cfg.qrcode_ecc_level = ecc == "L" ? ESP_QRCODE_ECC_LOW  : ecc == "Q" ? ESP_QRCODE_ECC_QUART
                       : ecc == "H" ? ESP_QRCODE_ECC_HIGH : ESP_QRCODE_ECC_MED;
  esp_qrcode_generate(&cfg, d.c_str());
}

void tsplQR(int x, int y, const String& ecc, int cell,
            const String& mode, int rot, const String& data) {
  // Line breaks ({nl}) and tabs ({tab}) let a keyboard-mode scanner press
  // Enter / Tab between fields. The TSC printer strips TAB from QRCODE text
  // in every mode (manual "B" segments included) and turns the \[R]/\[L]
  // escapes into CR+LF plus a repeated character, so such a QR is drawn here
  // and sent as a BITMAP instead. Every line break becomes ONE CR: scanners
  // press Enter for CR and again for LF, so CR+LF left a blank row in Excel.
  String d = data;
  d.replace("\r\n", "\r");
  d.replace("\n", "\r");
  for (unsigned i = 0; i < d.length(); i++) {
    if ((uint8_t)d[i] < 0x20) { qrBitmap(x, y, ecc, cell, rot, d); return; }
  }
  Serial.printf("QRCODE %d,%d,%s,%d,%s,%d,\"%s\"\r\n",
                x, y, ecc.c_str(), cell, mode.c_str(), rot, d.c_str());
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

// Font character heights in dots at 203 DPI — mirrors app kFontDotH
static const uint8_t kFontH[9] = {0, 12, 20, 24, 32, 48, 19, 27, 21};

// Reverse all 8 bits in a byte — used for 180° logo rotation
static inline uint8_t reverseByte(uint8_t b) {
  b = (b & 0xF0) >> 4 | (b & 0x0F) << 4;
  b = (b & 0xCC) >> 2 | (b & 0x33) << 2;
  b = (b & 0xAA) >> 1 | (b & 0x55) << 1;
  return b;
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
  uint8_t  dir      = label["dir"]      | 0;
  uint16_t copies   = doc["copies"]     | 1;

  const int wDots = (int)w * 8;
  const int hDots = (int)h * 8;

  // Always emit DIRECTION 0.  When dir=1 (reverse), every element's anchor is
  // mirrored to (wDots-x, hDots-y) and its rotation is flipped +180°.
  // This keeps the visual layout identical while the label feeds in reverse,
  // and avoids the coordinate-origin shift that DIRECTION 1 would introduce.
  tsplBegin(w, h, gap, darkness, 2, 0);

  for (JsonObject e : doc["elements"].as<JsonArray>()) {
    String type = e["type"] | "";
    // App >= 2026-09-30 sends a QR holding Tab/Enter as a ready bitmap
    // ('logo' + 'qr': 1). Without its picture (live print, or stripped for
    // NVS) it is drawn here from 'data'.
    if (type == "logo" && (e["qr"] | 0) && !e["bmp"].is<const char*>()) type = "qr";
    int x = e["x"] | 0;
    int y = e["y"] | 0;

    // Skip elements whose anchor is outside the label area
    if (x < 0 || y < 0 || x >= wDots || y >= hDots) continue;

    if (type == "text") {
      String txt  = e["text"] | "";
      txt.replace("\"", "'");
      String font = e["font"] | "3";
      int rot  = e["rot"] | 0;
      int ys   = e["ys"]  | 1;
      int fIdx = font.toInt(); if (fIdx < 1 || fIdx > 8) fIdx = 3;
      int textH = (int)kFontH[fIdx] * ys;
      if (dir == 1) {
        x = wDots - x; y = hDots - y; rot = (rot + 180) % 360;
      } else {
        // Clamp y so text height stays inside label (canvas clips visually; printer does not)
        if (y + textH > hDots) y = hDots - textH;
        if (y < 0) continue;
      }
      tsplText(x, y, font, rot, e["xs"] | 1, ys, txt);

    } else if (type == "qr") {
      String d  = e["data"] | ""; d.replace("\"", "'");
      int rot   = e["rot"]  | 0;
      int cells = e["size"] | 4;
      int qrDots = cells * 25;   // ≈ 25 modules per side for a typical small QR
      if (dir == 1) {
        x = wDots - x; y = hDots - y; rot = (rot + 180) % 360;
      } else {
        if (x + qrDots > wDots) x = max(0, wDots - qrDots);
        if (y + qrDots > hDots) y = max(0, hDots - qrDots);
      }
      tsplQR(x, y, e["ecc"] | "M", cells, e["mode"] | "A", rot, d);

    } else if (type == "bar") {
      String d  = e["data"] | ""; d.replace("\"", "'");
      int rot   = e["rot"]    | 0;
      int barH  = e["height"] | 60;
      if (dir == 1) {
        x = wDots - x; y = hDots - y; rot = (rot + 180) % 360;
      } else {
        if (y + barH > hDots) barH = hDots - y;
        if (barH < 8) continue;
      }
      tsplBarcode(x, y, e["btype"] | "128", barH,
                  e["hr"] | 1, rot, e["narrow"] | 2, e["wide"] | 2, d);

    } else if (type == "box") {
      int xe = e["xe"] | (x + 50);
      int ye = e["ye"] | (y + 50);
      int t  = e["t"]  | 2;
      if (dir == 1) {
        int nx = wDots - xe, ny = hDots - ye;
        xe = wDots - x;  ye = hDots - y;
        x  = nx;         y  = ny;
      }
      x  = max(0, x);       y  = max(0, y);
      xe = min(xe, wDots);  ye = min(ye, hDots);
      tsplBox(x, y, xe, ye, t);

    } else if (type == "logo") {
      int bw = e["bw"] | 0;
      int bh = e["lh"] | 0;
      if (dir == 1) {
        x = max(0, wDots - x - bw * 8);
        y = max(0, hDots - y - bh);
      }
      const char* bmpHex = e["bmp"] | "";
      if (strlen(bmpHex) > 0 && bw > 0 && bh > 0) {
        int totalBytes = bw * bh;
        if (dir == 1) {
          // 180° rotation: buffer decoded bytes, send rows in reverse with bit-reversed bytes
          uint8_t* buf = (uint8_t*)malloc(totalBytes);
          if (buf) {
            const char* p = bmpHex;
            for (int i = 0; i < totalBytes && p[0] != '\0' && p[1] != '\0'; i++, p += 2) {
              char nb[3] = { p[0], p[1], '\0' };
              buf[i] = (uint8_t)strtol(nb, nullptr, 16);
            }
            Serial.printf("BITMAP %d,%d,%d,%d,0,", x, y, bw, bh);
            for (int row = bh - 1; row >= 0; row--) {
              for (int col = bw - 1; col >= 0; col--) {
                Serial.write(reverseByte(buf[row * bw + col]));
              }
            }
            Serial.print("\r\n");
            free(buf);
          } else {
            // malloc failed — send without row/col reversal but still fix bit order
            Serial.printf("BITMAP %d,%d,%d,%d,0,", x, y, bw, bh);
            for (int i = 0; bmpHex[i] != '\0' && bmpHex[i+1] != '\0'; i += 2) {
              char nb[3] = { bmpHex[i], bmpHex[i+1], '\0' };
              Serial.write(reverseByte((uint8_t)strtol(nb, nullptr, 16)));
            }
            Serial.print("\r\n");
          }
        } else {
          // Normal path: TSC printer reads BITMAP bytes LSB-first, so reverse each byte
          Serial.printf("BITMAP %d,%d,%d,%d,0,", x, y, bw, bh);
          for (int i = 0; bmpHex[i] != '\0' && bmpHex[i+1] != '\0'; i += 2) {
            char nb[3] = { bmpHex[i], bmpHex[i+1], '\0' };
            Serial.write(reverseByte((uint8_t)strtol(nb, nullptr, 16)));
          }
          Serial.print("\r\n");
        }
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
}

// ============================================================================
//  Command dispatcher
// ============================================================================
void setClock(JsonDocument& doc) {
  uint32_t now = doc["now"] | 0;
  if (now > 1600000000UL) { clockEpoch = now; clockAtMs = millis(); }
}

void handleCommand(const String& payload) {
  DynamicJsonDocument doc(4096);
  DeserializationError err = deserializeJson(doc, payload);
  if (err) {
    notifyStatus("err", String("json:") + err.c_str());
    return;
  }

  String cmd = doc["cmd"] | "";

  if (cmd == "print") {
    // Never step the sequence backwards — a reprint from Reports carries an
    // old number. A deliberate reset arrives through "sync" instead.
    uint32_t n = doc["sn"]["n"] | 0;
    if (n > snLast) { snLast = n; prefs.putULong("snN", snLast); }
    // Button/auto prints must net off the same tare the app just printed with,
    // including one typed into the app by hand.
    if (doc.containsKey("tr")) tareGrams = doc["tr"] | 0.0f;
    disarmAutoPrint();
    lastPrintJson = payload;   // save in RAM for immediate button reprint
    savePrintJobToNvs(payload); // persist to NVS for power-cycle survival
    executePrintJob(doc);

  } else if (cmd == "sync") {
    // Sent by the app on every connect and whenever Settings are saved.
    setClock(doc);
    if (doc.containsKey("auto")) {
      autoOn = (doc["auto"] | 0) != 0;
      prefs.putBool("auto", autoOn);
    }
    if (doc.containsKey("min")) {
      autoMin = doc["min"] | 0.05f;
      if (autoMin <= 0) autoMin = 0.001f;
      prefs.putFloat("autoMin", autoMin);
    }
    if (doc.containsKey("sn")) {
      // Normally keep the higher counter; "force" is the app's serial reset.
      uint32_t n = doc["sn"] | 0;
      if ((doc["force"] | 0) || n > snLast) { snLast = n; prefs.putULong("snN", snLast); }
    }
    StaticJsonDocument<96> r;
    r["status"] = "sync";
    r["sn"]     = snLast;
    r["auto"]   = autoOn ? 1 : 0;
    r["ms"]     = millis();
    char out[96];
    size_t len = serializeJson(r, out, sizeof(out));
    pCharStatus->setValue((uint8_t*)out, len);
    pCharStatus->notify();
    delay(40);
    flushPrintRecords();   // labels printed while the app was away

  } else if (cmd == "tare") {
    tareGrams = latest.value;
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
    String s = "v=" + String(latest.value, (unsigned int)latest.decimals) +
               ",t=" + String(tareGrams, (unsigned int)latest.decimals) +
               ",u=" + String(latest.unit);
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
  Serial.print("DENSITY 9\r\n");
  // Print on the media the gap sensor is calibrated for (if known), so the test
  // label doesn't knock the printer out of step with the loaded roll.
  if (lastLabelW && lastLabelH) {
    Serial.printf("SIZE %d mm,%d mm\r\n", lastLabelW, lastLabelH);
  } else {
    Serial.print("SIZE 81 mm,13 mm\r\n");
    Serial.print("GAP 2.5 mm,0 mm\r\n");
  }
  Serial.print("DIRECTION 0\r\n");
  Serial.print("SET TEAR ON\r\n");
  Serial.print("CLS\r\n");
  Serial.print("TEXT 40,5,\"2\",0,1,1,\"GS-LABEL TEST\"\r\n");
  Serial.print("TEXT 40,42,\"2\",0,1,1,\"BLE FIRMWARE OK\"\r\n");
  Serial.print("PRINT 1,1\r\n");
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
//  Live print — the physical button and auto print both reprint the stored
//  template with the live weight and the next serial number, then report the
//  label to the app so it is saved in the print records.
//  Priority: RAM lastPrintJson → NVS stored job → hardcoded test print.
// ============================================================================

String formatSerial(JsonObject sn, uint32_t n) {
  char num[16];
  snprintf(num, sizeof(num), "%0*lu", (int)(sn["w"] | 5), (unsigned long)n);
  return String(sn["p"] | "") + num + String(sn["s"] | "");
}

// Fill the live values into every element of a stored job:
//   - elements with 'tpl' (text/QR/barcode/serial/date written with {tokens})
//   - weight elements tagged with 'wt_var'
// Every live print consumes the next serial number: app, button and auto
// prints all share one running sequence.
void fillLiveJob(JsonDocument& doc, LiveValues& lv) {
  // "Extra zero" setting from the app: pad one more decimal place so 200.20
  // prints as 200.200. Cosmetic only — the value is unchanged.
  lv.dec   = latest.decimals + ((doc["xz"] | 0) ? 1 : 0);
  lv.gross = latest.value;
  lv.tare  = tareGrams;
  lv.net   = max(0.0f, latest.value - tareGrams);
  // metal = live net − the stone deduction the operator entered in the app.
  lv.stone = doc["stone"] | 0.0f;
  lv.metal = max(0.0f, lv.net - lv.stone);
  float rate = doc["rate"] | 0.0f;
  float mk   = doc["mk"]   | 0.0f;
  lv.making = lv.metal * rate * mk / 100.0f;
  lv.amount = lv.metal * rate + lv.making;
  lv.unit   = String(doc["wu"] | latest.unit);

  // Jobs without serial info (quick print, old app) print without one.
  JsonObject sn = doc["sn"];
  if (!sn.isNull()) {
    snLast++;
    lv.serial   = formatSerial(sn, snLast);
    lv.serialNo = snLast;
    prefs.putULong("snN", snLast);
  }

  // Date/time: the app's clock, carried forward with millis(). Until the app
  // has set it since power-on, fall back to the date/time of the stored job.
  if (clockEpoch) {
    time_t t = (time_t)(clockEpoch + (millis() - clockAtMs) / 1000UL);
    struct tm tmv;
    gmtime_r(&t, &tmv);   // epoch is already local time, so no TZ shift
    char d[12], h[8];
    strftime(d, sizeof(d), "%d-%m-%Y", &tmv);
    strftime(h, sizeof(h), "%H:%M", &tmv);
    lv.date = d; lv.time = h;
  } else {
    lv.date = String(doc["dt"]["d"] | "");
    lv.time = String(doc["dt"]["t"] | "");
  }

  auto fmtW = [&](float v) {
    char b[32];
    snprintf(b, sizeof(b), "%.*f%s%s", (int)lv.dec, v < 0 ? 0.0f : v,
             lv.unit.length() ? " " : "", lv.unit.c_str());
    return String(b);
  };
  auto fmtMoney = [](float v) {
    char b[24];
    snprintf(b, sizeof(b), "%.2f", v);
    return String(b);
  };

  for (JsonObject e : doc["elements"].as<JsonArray>()) {
    const char* tpl = e["tpl"] | "";
    const char* etype = e["type"] | "";
    if (*tpl && strcmp(etype, "bar") == 0 && (e["dig"] | 0)) {
      // "Numbers only" barcode (Code 128-C): each field becomes digits only,
      // weights with exactly 3 decimals; separators typed in the template
      // stay. Mirrors digitsOnlyFields() in the app.
      auto digitsOf = [](const String& in) {
        String d;
        for (unsigned i = 0; i < in.length(); i++) if (isDigit(in[i])) d += in[i];
        return d;
      };
      auto fixedD = [&](float v, int dec) {
        char b[24];
        snprintf(b, sizeof(b), "%.*f", dec, v < 0 ? 0.0f : v);
        return digitsOf(String(b));
      };
      String q = tpl;
      q.replace("{net}",    fixedD(lv.net, 3));
      q.replace("{gross}",  fixedD(lv.gross, 3));
      q.replace("{tare}",   fixedD(lv.tare, 3));
      q.replace("{metal}",  fixedD(lv.metal, 3));
      q.replace("{amount}", fixedD(lv.amount, 2));
      q.replace("{making}", fixedD(lv.making, 2));
      q.replace("{serial}", digitsOf(lv.serial));
      q.replace("{date}",   digitsOf(lv.date));
      q.replace("{time}",   digitsOf(lv.time));
      e["data"] = q;
      continue;
    }
    if (*tpl) {
      String q = tpl;
      q.replace("{net}",    fmtW(lv.net));
      q.replace("{gross}",  fmtW(lv.gross));
      q.replace("{tare}",   fmtW(lv.tare));
      q.replace("{metal}",  fmtW(lv.metal));
      q.replace("{amount}", fmtMoney(lv.amount));
      q.replace("{making}", fmtMoney(lv.making));
      q.replace("{serial}", lv.serial);
      q.replace("{date}",   lv.date);
      q.replace("{time}",   lv.time);
      String type = e["type"] | "";
      if (type == "qr" || type == "bar" || (e["qr"] | 0)) e["data"] = q;
      else                                                e["text"] = q;
      // A QR the app sent as a bitmap: drop the stale picture so it is
      // redrawn from the new data (executePrintJob).
      if (e["qr"] | 0) e.remove("bmp");
      continue;
    }

    const char* wv = e["wt_var"] | "";
    if (!*wv) continue;

    float g = 0;
    if      (strcmp(wv, "net")   == 0) g = lv.net;
    else if (strcmp(wv, "gross") == 0) g = lv.gross;
    else if (strcmp(wv, "tare")  == 0) g = lv.tare;
    else if (strcmp(wv, "metal") == 0) g = lv.metal;
    else continue;  // stone: keep stored value

    // Unit is a plain suffix chosen in the app; fall back to whatever the scale
    // reports. Either way the number itself is printed unconverted.
    const char* pre  = e["pre"]  | "";
    const char* suf  = e["suf"]  | "";
    const char* unit = e["unit"] | latest.unit;
    char buf[64];
    snprintf(buf, sizeof(buf), "%s%.*f%s%s%s", pre, (int)lv.dec,
             g < 0 ? 0.0f : g, *unit ? " " : "", unit, suf);
    e["text"] = (const char*)buf;
  }
}

// Load the stored job. False when there is nothing (valid) to reprint.
bool loadLastJob(DynamicJsonDocument& doc) {
  String jobStr = lastPrintJson;
  if (jobStr.isEmpty()) jobStr = prefs.getString("lastJob", "");
  if (jobStr.isEmpty()) return false;
  return deserializeJson(doc, jobStr) == DeserializationError::Ok;
}

// ============================================================================
//  Print records — each button/auto label is sent to the app, or held (up to
//  REC_PENDING_MAX, RAM only) until the app reconnects.
// ============================================================================
void sendPrintRecord(const String& rec) {
  if (deviceConnected && pCharStatus) {
    pCharStatus->setValue((uint8_t*)rec.c_str(), rec.length());
    pCharStatus->notify();
    return;
  }
  if (recPendN == REC_PENDING_MAX) {   // full: drop the oldest
    for (uint8_t i = 1; i < REC_PENDING_MAX; i++) recPending[i - 1] = recPending[i];
    recPendN--;
  }
  recPending[recPendN++] = rec;
}

void flushPrintRecords() {
  for (uint8_t i = 0; i < recPendN && deviceConnected; i++) {
    pCharStatus->setValue((uint8_t*)recPending[i].c_str(), recPending[i].length());
    pCharStatus->notify();
    recPending[i] = "";
    delay(40);   // back-to-back notifies can be dropped by the phone's BLE stack
  }
  recPendN = 0;
}

// src: "btn" (physical button) or "auto". Returns false if there is no stored
// template to print.
bool livePrint(const char* src) {
  DynamicJsonDocument doc(8192);
  if (!loadLastJob(doc)) return false;
  disarmAutoPrint();

  digitalWrite(PRINT_LED_PIN, HIGH); delay(80); digitalWrite(PRINT_LED_PIN, LOW);
  LiveValues lv;
  fillLiveJob(doc, lv);
  executePrintJob(doc);

  // Kept well under the 244-byte notify limit (MTU 247).
  StaticJsonDocument<320> r;
  r["status"] = "rec";
  r["src"] = src;
  r["v"]  = lv.serial;
  r["n"]  = lv.serialNo;
  r["g"]  = lv.gross;
  r["t"]  = lv.tare;
  r["nt"] = lv.net;
  r["st"] = lv.stone;
  r["m"]  = lv.metal;
  r["a"]  = lv.amount;
  r["mk"] = lv.making;
  r["d"]  = lv.dec;
  r["u"]  = lv.unit;
  r["dt"] = lv.date;
  r["tm"] = lv.time;
  r["ms"] = millis();   // lets the app date records delivered after a reconnect
  String rec;
  serializeJson(r, rec);
  sendPrintRecord(rec);
  return true;
}

void buttonReprint() {
  if (!livePrint("btn")) {
    digitalWrite(PRINT_LED_PIN, HIGH); delay(80); digitalWrite(PRINT_LED_PIN, LOW);
    sendTestPrint();   // nothing printed from the app yet
  }
}

// ============================================================================
//  Auto print — prints the stored template by itself once a new item settles
//  on the pan. Enabled from the app (Settings → Auto Print), kept in NVS.
// ============================================================================
// Any print (app, button, auto) counts as this item's label: auto print waits
// for the pan to be cleared before the next one, so nothing prints twice.
void disarmAutoPrint() {
  autoArmed    = false;
  autoStableMs = 0;
}

// Called every loop(). One label per item: after printing, the pan has to go
// back below half the minimum weight before the next item can trigger.
void serviceAutoPrint() {
  if (!autoOn) return;
  if (millis() - latest.tsMs > 2000) { autoStableMs = 0; return; }   // no scale data

  float net = latest.value - tareGrams;
  if (net < autoMin * 0.5f) { autoArmed = true; autoStableMs = 0; return; }
  if (!autoArmed || net < autoMin || !latest.stable) { autoStableMs = 0; return; }

  // Stable must hold a little longer, so a single "ST" frame from a still
  // settling scale does not fire a label.
  if (!autoStableMs) { autoStableMs = millis(); return; }
  if (millis() - autoStableMs < 500) return;

  livePrint("auto");
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
    String v = c->getValue();
    if (v.isEmpty()) return;
    bleBuffer += v;
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
    digitalWrite(LED_PIN, HIGH);             // LED ON when connected
    BLEDevice::getAdvertising()->stop();     // stop advertising while connected
  }
  void onDisconnect(BLEServer*) override {
    deviceConnected = false;
    bleBuffer       = "";
    digitalWrite(LED_PIN, LOW);              // LED OFF when disconnected
    doStartAdv   = true;
    disconnectMs = millis();
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
  int8_t dot = -1;
  while (*p && i < 19 && (*p == '.' || (*p >= '0' && *p <= '9'))) {
    if (*p == '.') dot = i;
    nb[i++] = *p++;
  }

  if (i == 0) return;

  float v = atof(nb);

  // Digits after the decimal point in the raw string: "5.620" -> 3, "5" -> 0.
  uint8_t dec = (dot < 0) ? 0 : (uint8_t)(i - dot - 1);

  // Unit token — taken verbatim from immediately after the number, NEVER used to
  // rescale the value. Scanning the whole line would misfire: the "GS" in a
  // "ST,GS,+ 5.620 g" header contains a 'G'. Handles "5.620 g" and "1.234kg" alike.
  char unit[6] = "";
  {
    const char* q = p;
    while (*q == ' ') q++;
    uint8_t k = 0;
    while (*q && k < sizeof(unit) - 1 &&
           ((*q >= 'a' && *q <= 'z') || (*q >= 'A' && *q <= 'Z'))) unit[k++] = *q++;
    unit[k] = 0;
  }

  // Time-based stability: stable if the reading is unchanged for 1.5 s.
  // The original JBCTAG scale sends no stability token — we derive it from motion.
  // The ±0.5 g threshold is the original tuning and is kept exactly; it just has to
  // be restated in the unit currently being reported, or a kg reading would never
  // move by 0.5 and everything would read STABLE. This factor is used ONLY to size
  // the motion window — it never touches the value that gets displayed or printed.
  float tol = 0.5f;
  if      (!strcasecmp(unit, "kg")) tol = 0.0005f;
  else if (!strcasecmp(unit, "mg")) tol = 500.0f;
  else if (!strcasecmp(unit, "ct")) tol = 2.5f;
  else if (!strcasecmp(unit, "lb")) tol = 0.0011f;
  else if (!strcasecmp(unit, "oz")) tol = 0.0176f;
  if (fabsf(v - prevValue) > tol) {
    prevValue = v;
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

  latest.value    = v;
  latest.decimals = dec;
  strncpy(latest.unit, unit, sizeof(latest.unit) - 1);
  latest.unit[sizeof(latest.unit) - 1] = 0;
  latest.tsMs     = millis();
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

  StaticJsonDocument<192> doc;
  doc["g"]  = latest.value;                 // raw, exactly as the scale sent it
  doc["t"]  = tareGrams;
  doc["n"]  = latest.value - tareGrams;
  doc["s"]  = latest.stable ? 1 : 0;
  doc["u"]  = latest.unit;                  // scale's own unit token ("" if none)
  doc["d"]  = latest.decimals;              // raw precision, so the app can match it
  doc["ts"] = latest.tsMs;
  char out[192];
  size_t n = serializeJson(doc, out, sizeof(out));
  pCharWeight->setValue((uint8_t*)out, n);
  pCharWeight->notify();
}

// ============================================================================
//  Setup
// ============================================================================
void setup() {
  pinMode(LED_PIN,       OUTPUT);
  pinMode(PRINT_LED_PIN, OUTPUT);
  pinMode(PRINT_BTN_PIN, INPUT_PULLUP);
  digitalWrite(LED_PIN,       LOW);   // off at boot
  digitalWrite(PRINT_LED_PIN, LOW);   // off at boot

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

  // BLE advertising — use addServiceUUID() so m_customAdvData stays false.
  // This ensures start() always re-calls esp_ble_gap_config_adv_data() on
  // every restart, which is required after a stop() or disconnect.
  // setAdvertisementData() sets m_customAdvData=true and skips that step on
  // subsequent start() calls — leaving an empty packet that phones cannot see.
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMaxPreferred(0x12);

  BLEDevice::startAdvertising();

  // Open NVS namespace — load persisted print job if any
  prefs.begin("gslbl", false);
  String storedJob = prefs.getString("lastJob", "");
  if (storedJob.length() > 10) {
    lastPrintJson = storedJob;  // restore last template into RAM on boot
  }
  // Restore the calibrated label size so the first button print skips GAPDETECT
  lastLabelW = prefs.getUShort("calW", 0);
  lastLabelH = prefs.getUShort("calH", 0);
  snLast  = prefs.getULong("snN", 0);
  autoOn  = prefs.getBool("auto", false);
  autoMin = prefs.getFloat("autoMin", 0.05f);

  // Boot test print — fires 3 s after power-on, no BLE needed.
  delay(3000);
  sendTestPrint();

  digitalWrite(LED_PIN, LOW);
}

// ============================================================================
//  Loop
// ============================================================================
void loop() {
  // Restart advertising 500 ms after disconnect.
  if (doStartAdv && (millis() - disconnectMs >= 500)) {
    doStartAdv = false;
    BLEDevice::startAdvertising();
  }

  // Periodic retry every 5 s while disconnected — safety net for missed restarts.
  static uint32_t lastAdvMs = 0;
  if (!deviceConnected && !doStartAdv && (millis() - lastAdvMs >= 5000)) {
    lastAdvMs = millis();
    BLEDevice::startAdvertising();
  }

  serviceScale();
  pushWeightOverBLE();
  serviceAutoPrint();

  // Process BLE command on the Arduino task — keeps BLE task free to ACK writes
  if (cmdReady) {
    cmdReady = false;
    handleCommand(cmdBuffer);
    cmdBuffer = "";
  }

  // Physical button (GPIO13, active LOW)
  // Short press (< 3 s): reprint last label
  // Long press  (≥ 3 s): force BLE restart + 3 LED blinks
  bool btnDown = (digitalRead(PRINT_BTN_PIN) == LOW);

  if (btnDown && btnArmed) {
    btnArmed     = false;
    btnPressMs   = millis();
    btnLongFired = false;
  }

  if (!btnArmed && !btnLongFired && (millis() - btnPressMs >= 2000)) {
    btnLongFired    = true;
    deviceConnected = false;
    bleBuffer       = "";
    // 3 blinks on BT LED (GPIO12)
    for (int i = 0; i < 3; i++) {
      digitalWrite(LED_PIN, HIGH); delay(200);
      digitalWrite(LED_PIN, LOW);  delay(200);
    }
    BLEDevice::startAdvertising();
  }

  if (!btnDown && !btnArmed) {
    if (!btnLongFired && (millis() - btnPressMs >= 50)) {
      buttonReprint();
    }
    btnArmed = true;
  }

  delay(2);
}