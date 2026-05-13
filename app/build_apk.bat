@echo off
REM ===================================================================
REM  Build the GS Label app APK on Windows.
REM  Run this from the GoldSilverLabelApp\app folder, once Flutter + the
REM  Android SDK are installed (see prerequisites below).
REM ===================================================================

setlocal
echo === Step 1/5: check Flutter ===
where flutter >nul 2>&1 || (
  echo ERROR: Flutter not on PATH.
  echo Install from https://docs.flutter.dev/get-started/install/windows
  exit /b 1
)
flutter --version

echo === Step 2/5: scaffold host platform folders (android/, ios/, etc) ===
REM flutter create -t app . will add android\ ios\ web\ etc next to our lib\
flutter create --project-name gs_label_app --org com.gslabel --platforms android .

echo === Step 3/5: inject Bluetooth permissions into AndroidManifest ===
powershell -NoProfile -Command "$f='android\app\src\main\AndroidManifest.xml';$x=Get-Content $f -Raw;$add='    <uses-permission android:name=\"android.permission.BLUETOOTH_SCAN\" android:usesPermissionFlags=\"neverForLocation\"/>`r`n    <uses-permission android:name=\"android.permission.BLUETOOTH_CONNECT\"/>`r`n    <uses-permission android:name=\"android.permission.BLUETOOTH\"/>`r`n    <uses-permission android:name=\"android.permission.BLUETOOTH_ADMIN\"/>`r`n    <uses-permission android:name=\"android.permission.ACCESS_FINE_LOCATION\" android:maxSdkVersion=\"30\"/>`r`n';if($x -notmatch 'BLUETOOTH_SCAN'){$x=$x -replace '(<manifest [^>]+>)', \"`$1`r`n$add\";Set-Content $f $x -NoNewline}"

echo === Step 4/5: resolve dependencies ===
flutter pub get
if errorlevel 1 exit /b 1

echo === Step 5/5: build release APK ===
flutter build apk --release
if errorlevel 1 (
  echo Build failed. Common fixes:
  echo   - Run "flutter doctor" and fix any red items.
  echo   - Make sure JDK 17 is installed and JAVA_HOME is set.
  echo   - Accept Android SDK licences: "flutter doctor --android-licenses"
  exit /b 1
)

echo.
echo ========================================================
echo  APK ready at:
echo   build\app\outputs\flutter-apk\app-release.apk
echo  Side-load it to the phone with adb install or by sharing
echo  the file directly.
echo ========================================================
endlocal
