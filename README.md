# Gold & Silver Label Printing System

End-to-end deliverable for a wireless tag/label printing solution targeting the gold & silver retail industry.

```
GoldSilverLabelApp/
├─ README.md                                     this file
├─ docs/
│   └─ Gold_Silver_Label_App_Architecture.docx   Full architecture & design document
├─ firmware/
│   ├─ GoldSilverLabelPrinter.ino                ESP32 sketch (Arduino)
│   └─ README_FIRMWARE.md                        Wiring, BLE GATT, test recipe
├─ app/                                          Flutter app (Android + iOS)
│   ├─ pubspec.yaml
│   ├─ README_APP.md
│   └─ lib/
│       ├─ main.dart
│       ├─ services/      ble_service.dart   db_service.dart
│       ├─ models/        label_element.dart
│       └─ pages/         home_shell.dart   scale_page.dart
│                         designer_page.dart  templates_page.dart
│                         reports_page.dart  connect_page.dart
└─ mockups/
    └─ app_screens_mockup.html                   Visual mockups of all 5 screens
```

## Topology
```
[ Weighing Scale ] --RS232--> [ ESP32 Bridge ] <--BLE--> [ Flutter App ]
                                     |
                                  UART/TSPL
                                     v
                            [ TSC TTP-244 Pro ]
```

## How to start
1. Open `mockups/app_screens_mockup.html` in a browser to see the UI layout.
2. Read `docs/Gold_Silver_Label_App_Architecture.docx` for the full design.
3. Flash `firmware/GoldSilverLabelPrinter.ino` to your ESP32 (instructions in `firmware/README_FIRMWARE.md`).
4. Build the Flutter app: `cd app && flutter pub get && flutter run` (see `app/README_APP.md`).

## Features delivered in this drop
- ESP32 firmware: BLE GATT, continuous-ASCII scale parser, TSPL command builder, JSON command interpreter.
- Flutter app: 5 screens (Scale, Designer, Templates, Reports, Device), drag-and-drop label designer with placeholders, SQLite-backed history, CSV / XLSX export.
- Mockups: HTML visual reference for every screen plus a block diagram.
- Architecture document: hardware BOM, pin map, BLE protocol, app screens, data model, workflows, roadmap.

## Roadmap (not in this drop)
- Logo upload from phone → chunked BLE → printer flash (`DOWNLOAD BMP`).
- GST/HSN-aware product master CRUD screen.
- Optional Firebase sync for multi-counter or multi-shop.
- Hindi / Gujarati / Tamil UI translations via `intl` ARB files.
