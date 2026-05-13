# Gold & Silver Label App (Flutter)

Cross-platform (Android + iOS) operator app that pairs with the **GS-LABEL-BRIDGE** ESP32 firmware over BLE.

## Folder layout
```
app/
├─ pubspec.yaml
└─ lib/
   ├─ main.dart                    Material 3 root, Provider wiring
   ├─ services/
   │   ├─ ble_service.dart         BLE scan, connect, weight stream, command writer
   │   └─ db_service.dart          SQLite (templates, products, prints)
   ├─ models/
   │   └─ label_element.dart       LabelElement + placeholder resolution
   └─ pages/
       ├─ home_shell.dart          Bottom-nav scaffold
       ├─ scale_page.dart          Live Gross/Tare/Net + PRINT
       ├─ designer_page.dart       Drag-and-drop canvas designer
       ├─ templates_page.dart      Saved templates list
       ├─ reports_page.dart        Date-range report + CSV/XLSX export
       └─ connect_page.dart        BLE pairing UI
```

## Build
```bash
cd app
flutter pub get
flutter run -d <your-device>
```

### Android manifest additions (paste into `android/app/src/main/AndroidManifest.xml`)
```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
    android:maxSdkVersion="30"/>
```
Set `minSdkVersion 21` (or higher) in `android/app/build.gradle`.

### iOS plist additions (`ios/Runner/Info.plist`)
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Needed to communicate with the label printer bridge</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Needed to communicate with the label printer bridge</string>
```

## How the print pipeline works
1. The designer screen builds a list of `LabelElement` objects on a canvas measured in **printer dots** (8 dots = 1 mm @ 203 dpi).
2. The list is saved to SQLite as a JSON array.
3. On the Scale screen, when the operator taps **PRINT**:
   - The active template is loaded.
   - Placeholders (`{net}`, `{serial}`, `{date}`, `{rate}`, `{amount}` …) are filled with live values.
   - A JSON envelope `{cmd:"print", label:{...}, elements:[...]}` is written to the BLE command characteristic.
4. The ESP32 firmware translates each element to TSPL and streams it to the TSC TTP-244 Pro over UART.

## Placeholders supported
`{net}` `{gross}` `{tare}` `{serial}` `{date}` `{time}` `{product}` `{purity}` `{rate}` `{amount}`

Drop them inside any text, QR, or barcode `data` field.

## Reports
- Filter by date range and product.
- Live total net weight and total amount in footer.
- Export to **CSV** or **XLSX** (shared via Android share sheet / iOS share sheet).

## Next steps (not yet wired up)
- Logo upload from gallery → chunked BLE upload → printer flash via `DOWNLOAD` TSPL command.
- Product master CRUD screen (table is already in DB).
- Cloud sync (Firebase Firestore) — easy to add as an optional layer.
- Multi-language UI (Hindi / Gujarati / Tamil) using `intl` ARB files.
