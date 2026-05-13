# Building the APK

The Cowork sandbox doesn't have the Flutter SDK or Android SDK and its package proxies are firewalled, so the APK has to be built on a machine you control. This is a one-time setup; after that every rebuild is `flutter build apk --release` (~30 seconds).

## Prerequisites (Windows, one-time, ~30 minutes)

1. **JDK 17** — https://adoptium.net/temurin/releases/?version=17  
   Set `JAVA_HOME` to the install folder.
2. **Flutter SDK** — https://docs.flutter.dev/get-started/install/windows  
   Extract to `C:\src\flutter`, add `C:\src\flutter\bin` to PATH.
3. **Android Studio** — https://developer.android.com/studio  
   Open once, then go to **More Actions → SDK Manager** and install:  
   - Android SDK Platform 34 (or current latest)  
   - Android SDK Build-Tools  
   - Android SDK Command-line Tools  
4. Verify: open a fresh terminal and run
   ```
   flutter doctor
   ```
   Fix any red items it reports. Run `flutter doctor --android-licenses` and accept all.

## Build

Open a Command Prompt in `GoldSilverLabelApp\app\` and run:

```
build_apk.bat
```

This will:
1. Scaffold the missing `android/`, `gradle/` host-platform folders next to `lib/`.
2. Inject the Bluetooth and location permissions into `AndroidManifest.xml`.
3. Resolve all pub.dev dependencies listed in `pubspec.yaml`.
4. Produce `build\app\outputs\flutter-apk\app-release.apk`.

## Install on the phone

Either drag-and-drop the `.apk` to your phone (enable "Install unknown apps" for your file manager), or with USB debugging on:

```
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

## Why I can't do this for you in Cowork

Cowork's shell is a sandboxed Linux container without Flutter (~1.5 GB) or the Android SDK (~3 GB) preinstalled, and its outbound network proxy blocks `storage.googleapis.com`, `pub.dev`, and `dl.google.com`. Those are the only sources for the missing pieces, so the build can't be primed here. The script above is what I'd run if I had access — it's the same flow.

## If you want to skip the install altogether

Push the project folder to GitHub and connect it to **Codemagic** (https://codemagic.io) or **GitHub Actions with the `subosito/flutter-action`** workflow — both will build a signed APK in the cloud. Happy to write the GitHub Actions yaml if you want to go that route.
