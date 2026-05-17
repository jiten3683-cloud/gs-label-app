/*
 * TestPrinter_NoBLE.ino
 *
 * Standalone sanity-check for the ESP32 -> TSC TTP-244 Pro wiring.
 * No BLE, no scale, no JSON. Just blasts a single test label out of
 * UART2 (GPIO17) every 5 seconds.
 *
 * If you see a label come out of the printer with this sketch, your
 * wiring is OK and the problem is somewhere else in the BLE / app
 * stack. If nothing prints, the problem is one of:
 *   - wrong DB-9 pin     (we need printer RX = DB-9 pin 3)
 *   - no level shifter   (printer expects RS-232 +/-12 V, ESP gives 3.3 V)
 *   - wrong baud rate    (printer at 19200/115200 instead of 9600)
 *   - no shared GND      (ESP GND must connect to DB-9 pin 5)
 *   - printer in USB mode (some TSC units have a mode switch)
 *   - gap sensor uncalibrated (printer ejects blank labels forever)
 *
 * Watch the Serial Monitor at 115200 baud for hints.
 */

#include <Arduino.h>

#define PRINTER_TX_PIN   17     // ESP32 TX2 -> printer DB-9 pin 3 (RX)
#define PRINTER_BAUD     9600   // ** change to 19200 / 38400 / 115200 if 9600 fails **
#define LED_PIN           2

HardwareSerial PrinterSerial(2);

void sendLabel(uint32_t n) {
  // Build a 50x25 mm label with a single big text on it.
  PrinterSerial.print("SIZE 50 mm,25 mm\r\n");
  PrinterSerial.print("GAP 3 mm,0\r\n");
  PrinterSerial.print("DENSITY 8\r\n");
  PrinterSerial.print("SPEED 4\r\n");
  PrinterSerial.print("DIRECTION 1\r\n");
  PrinterSerial.print("CLS\r\n");
  PrinterSerial.printf("TEXT 30,30,\"4\",0,1,1,\"TEST %lu\"\r\n", (unsigned long)n);
  PrinterSerial.printf("TEXT 30,90,\"3\",0,1,1,\"GS LABEL OK\"\r\n");
  PrinterSerial.print("PRINT 1,1\r\n");
}

void setup() {
  pinMode(LED_PIN, OUTPUT);
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("=== TestPrinter_NoBLE ===");
  Serial.printf("Printer TX pin = %d, baud = %d\n", PRINTER_TX_PIN, PRINTER_BAUD);

  PrinterSerial.begin(PRINTER_BAUD, SERIAL_8N1, -1 /*no rx*/, PRINTER_TX_PIN);

  // Wake the printer / clear any partial state
  PrinterSerial.print("\r\n");
  delay(200);
  PrinterSerial.print("CLS\r\n");
  delay(100);
}

uint32_t counter = 0;
void loop() {
  digitalWrite(LED_PIN, HIGH);
  counter++;
  Serial.printf("[%lu] Sending test label...\n", (unsigned long)counter);
  sendLabel(counter);
  digitalWrite(LED_PIN, LOW);
  delay(5000);
}
