# ESP32 Firmware — Gold/Silver Label Bridge

## What this firmware does
1. Reads the continuous ASCII weight stream from your weighing scale on **UART1 (GPIO16)**.
2. Parses it (Stable/Unstable + Gross/Net + numeric value in grams).
3. Advertises a BLE GATT service `GS-LABEL-BRIDGE` and streams weight to the phone at 5 Hz.
4. Accepts JSON print jobs from the phone and converts them to **TSPL** commands for the **TSC TTP-244 Pro** printer on **UART2 (GPIO17)**.

## Wiring

| Signal | ESP32 pin | Goes to |
|---|---|---|
| Scale RS232 TX | GPIO16 (RX1) | **via MAX3232** — never connect RS232 levels directly to ESP32 |
| Scale GND | GND | Scale GND |
| Printer RX | GPIO17 (TX2) | TSC TTP-244 Pro RX (serial port pin 3 on DB-9) |
| Printer GND | GND | TSC GND (DB-9 pin 5) |
| Power | 5V/USB | ESP32 |

The TSC TTP-244 Pro's serial port runs at TTL-RS232 levels; if your printer expects ±12 V RS232 you need a MAX3232 on the printer side too.

## Required Arduino libraries
- `ArduinoJson` by Benoit Blanchon (v6.x or v7.x)
- ESP32 board package by Espressif (built-in BLE)

## BLE GATT layout

```
Service  6f0a0001-7b9a-4e9f-9b46-1d7b3a2c0001
 ├─ 6f0a0002-...0001  Weight       NOTIFY    {"g":..,"t":..,"n":..,"s":0/1,"ts":..}
 ├─ 6f0a0003-...0001  Command      WRITE     see protocol below
 └─ 6f0a0004-...0001  Status       NOTIFY    {"status":"ok|err","msg":".."}
```

## Command protocol (JSON over WRITE)

```jsonc
// Print a label
{
  "cmd": "print",
  "label": {"w": 50, "h": 25, "gap": 3},
  "copies": 1,
  "elements": [
    {"type":"text","x":10,"y":10,"font":"3","text":"GOLD 22K"},
    {"type":"text","x":10,"y":40,"text":"Net: 12.345 g"},
    {"type":"qr",  "x":250,"y":10,"size":4,"data":"GS-0001|22K|12.345"},
    {"type":"bar", "x":10, "y":120,"btype":"128","data":"GS0001","height":60}
  ]
}

{"cmd":"tare"}            // capture current weight as tare
{"cmd":"zero"}            // clear tare offset
{"cmd":"status"}          // get current snapshot
{"cmd":"feed","mm":5}     // feed paper
{"cmd":"raw","tspl":"BAR 10,10,400,4"} // escape hatch
```

## Coordinate system
- 1 mm = **8 dots** (printer is 203 dpi).
- A 50×25 mm label is therefore 400×200 dots — keep elements within that.

## Quick test from a phone (without the app)
Use **nRF Connect** on Android, connect to `GS-LABEL-BRIDGE`, find the Command characteristic and write:
```
{"cmd":"print","label":{"w":50,"h":25},"elements":[{"type":"text","x":10,"y":10,"text":"HELLO"}]}
```

## Known limitations & next steps
- Logo printing currently uses `PUTBMP` against a name stored in printer flash. To support runtime logo upload from the phone you'll need to chunk a `DOWNLOAD` binary over BLE — wired through but not implemented yet.
- Scale parser assumes grams; uncomment/extend the kg branch if your scale streams kg.
- No persistent settings yet (tare offset is RAM-only). Easy to add with `Preferences.h`.
