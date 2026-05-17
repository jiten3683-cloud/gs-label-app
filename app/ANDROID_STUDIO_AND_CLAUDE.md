# Android Studio + Claude Code plugin — setup walkthrough

## What you'll have when this is done
- **Android Studio** — full IDE with code editor, visual debugger, emulator, layout previewer. You can build the APK from inside it with one click (Build → Build APK).
- **Claude Code plugin** — a panel in Android Studio where you can chat with Claude about the project, ask it to read or change files, generate tests, explain bugs, etc.

## One-click installer
Right-click `install_android_studio_and_claude.ps1` → **Run with PowerShell** (Administrator). It installs:
1. Android Studio (via Chocolatey)
2. Node.js LTS (Claude's CLI runs on Node)
3. The `@anthropic-ai/claude-code` package globally

Total time ~15–25 minutes.

## After the installer finishes — 5 minutes of clicking

### 1. First run of Android Studio
Open Android Studio from the Start menu. The first-run wizard appears.
- Welcome screen → **Next**
- Install Type → **Standard** → Next
- UI theme → pick whatever you like
- Verify Settings → **Next** → **Finish**
- It downloads ~700 MB of SDK files. Walk away for 5 minutes.

When the welcome screen comes back, you're done with first-run.

### 2. Open the project
- Click **Open** (or File → Open if you already had it open).
- Navigate to:
  ```
  E:\display iot\ESP32_P10_Display_Firmware\GoldSilverLabelApp\app
  ```
- Click OK. Android Studio imports the Flutter project — it'll take ~2 minutes the first time. You'll see "Gradle sync in progress..." at the bottom; let it finish.

If a pop-up appears asking about the Flutter plugin, click **Install Plugins**.

### 3. Install the Claude Code plugin
- Top menu: **File → Settings** (or press `Ctrl+Alt+S`).
- Left sidebar: **Plugins**.
- Top tabs: **Marketplace**.
- Search box: type `Claude Code`
- The official plugin's publisher is **Anthropic**. Click **Install** next to it.
- Click **OK** to close Settings.
- Click **Restart IDE** when prompted.

### 4. Sign in
After Android Studio restarts:
- Look at the right-side toolbar (vertical strip of icons). You'll see a new Claude Code icon.
- Click it. A browser tab opens for sign-in.
- Sign in with the **same email you use at claude.ai**.
- Approve the connection. You'll see "Successfully authenticated" in the IDE panel.

### 5. Try it out
- In the Claude Code panel, type:
  ```
  Walk me through how lib/services/ble_service.dart works.
  ```
- Claude reads the file and explains it in plain English.

Other useful first prompts:
- `Add a "Logo Upload" button on the Designer page that picks an image and chunks it over BLE to the printer using the DOWNLOAD TSPL command`
- `Add a unit test for the LabelElement.toJson placeholder substitution`
- `Open the running build's error and fix it`

## Building the APK from inside Android Studio
With the project open:
- Top menu: **Build → Flutter → Build APK**.
- Wait ~3 minutes the first time, ~30 s after that.
- When done, a notification pops up; click "Locate" to open the folder containing `app-release.apk`.

That's the same APK you'd get from the command line — Android Studio just wraps the same `flutter build apk --release` command.

## Troubleshooting

**"Claude Code" doesn't show up in the marketplace** → the plugin requires Android Studio 2024.1+ and the JetBrains marketplace mirror must be reachable. File → Settings → Plugins → settings-gear icon → **Manage Plugin Repositories** → make sure the default `https://plugins.jetbrains.com/` is listed.

**Plugin installs but the panel is empty** → it usually means the `claude` CLI isn't on PATH for Android Studio's process. Close Android Studio, open a NEW Command Prompt, run `claude --version`. If that works, restart Android Studio and the plugin will find it. If `claude` is not found, run `npm install -g @anthropic-ai/claude-code` again and check that `npm config get prefix` matches a folder on your PATH.

**Sign-in loops back to the login page** → clear browser cookies for claude.ai and try again. Or run `claude` from a terminal once first — that creates the auth cache the plugin reads from.

**Flutter / Dart plugins not detected** → File → Settings → Languages & Frameworks → Flutter → set "Flutter SDK path" to where you extracted Flutter (e.g. `C:\src\flutter`). Apply, restart.

## Notes on pricing
The Claude Code plugin itself is free. Usage is metered against your Anthropic account just like the web Claude. If you're on a Pro subscription that subscription covers it; otherwise it bills per token via the API. You can see usage at <https://console.anthropic.com/settings/usage>.
