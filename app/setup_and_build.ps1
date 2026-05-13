# =============================================================================
#  setup_and_build.ps1
#  One-shot installer + builder for the GS Label app on Windows.
#
#  USAGE:
#    1. Right-click  ->  "Run with PowerShell"     (run as Administrator)
#    2. Wait ~20-40 minutes the first time (depends on internet).
#    3. The resulting APK path is printed at the end and also copied to
#       this folder as  gs-label-app.apk .
#
#  What it does:
#    - Installs Chocolatey (Windows package manager) if missing
#    - Installs JDK 17, Git, Flutter SDK
#    - Installs Android command-line tools and accepts SDK licences
#    - Scaffolds android/ next to lib/
#    - Injects Bluetooth + location permissions into AndroidManifest.xml
#    - Runs flutter pub get  and  flutter build apk --release
# =============================================================================

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
function Section($t) { Write-Host "`n========== $t ==========" -ForegroundColor Cyan }
function OK($t)      { Write-Host "OK : $t" -ForegroundColor Green }
function Warn($t)    { Write-Host "WARN: $t" -ForegroundColor Yellow }
function Fail($t)    { Write-Host "FAIL: $t" -ForegroundColor Red; exit 1 }

# --- 0. Admin check ----------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Please right-click this script and choose 'Run with PowerShell' as Administrator."
}

# --- 1. Chocolatey -----------------------------------------------------------
Section "Step 1/7  Chocolatey (Windows package manager)"
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = "$env:ProgramData\chocolatey\bin;$env:Path"
}
OK "choco $(choco --version)"

# --- 2. Tools (JDK 17, Git, Flutter) ----------------------------------------
Section "Step 2/7  Install JDK 17, Git, Flutter"
choco install -y temurin17 git flutter --no-progress
# refresh PATH so new tools resolve in this session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
$javaHome = (Get-Item "C:\Program Files\Eclipse Adoptium\jdk-17*").FullName | Select-Object -First 1
if ($javaHome) { [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine") }
$env:JAVA_HOME = $javaHome
OK "JDK at $env:JAVA_HOME"
flutter --version

# --- 3. Android command-line tools ------------------------------------------
Section "Step 3/7  Android command-line tools"
$sdkRoot = "$env:LOCALAPPDATA\Android\sdk"
if (-not (Test-Path "$sdkRoot\cmdline-tools\latest\bin\sdkmanager.bat")) {
    $zip  = "$env:TEMP\cmdline-tools.zip"
    $url  = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip"
    Write-Host "Downloading Android cmdline-tools (~120 MB)..."
    Invoke-WebRequest -Uri $url -OutFile $zip
    New-Item -ItemType Directory -Force -Path "$sdkRoot\cmdline-tools" | Out-Null
    Expand-Archive -Path $zip -DestinationPath "$sdkRoot\cmdline-tools" -Force
    Rename-Item -Path "$sdkRoot\cmdline-tools\cmdline-tools" -NewName "latest"
}
$sdkMan = "$sdkRoot\cmdline-tools\latest\bin\sdkmanager.bat"
[System.Environment]::SetEnvironmentVariable("ANDROID_HOME", $sdkRoot, "Machine")
[System.Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $sdkRoot, "Machine")
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:Path = "$sdkRoot\platform-tools;$sdkRoot\cmdline-tools\latest\bin;$env:Path"

Write-Host "Installing platform-tools + platform 34 + build-tools 34.0.0..."
& $sdkMan --install "platform-tools" "platforms;android-34" "build-tools;34.0.0" | Out-Null

Write-Host "Accepting Android SDK licences..."
"y`ny`ny`ny`ny`ny`ny`ny`ny`n" | & $sdkMan --licenses | Out-Null
OK "Android SDK in $sdkRoot"

# --- 4. Flutter configuration ------------------------------------------------
Section "Step 4/7  Configure Flutter"
flutter config --android-sdk "$sdkRoot" --no-analytics | Out-Null
flutter doctor

# --- 5. Scaffold android/ ----------------------------------------------------
Section "Step 5/7  Scaffold android/ project files"
if (-not (Test-Path ".\android")) {
    flutter create --project-name gs_label_app --org com.gslabel --platforms android .
} else {
    OK "android/ already exists"
}

# --- 6. Patch AndroidManifest.xml -------------------------------------------
Section "Step 6/7  Inject Bluetooth permissions"
$manifest = ".\android\app\src\main\AndroidManifest.xml"
$x = Get-Content $manifest -Raw
if ($x -notmatch "BLUETOOTH_SCAN") {
    $perms = @"
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
    <uses-permission android:name="android.permission.BLUETOOTH"/>
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"/>
"@
    $x = $x -replace '(<manifest [^>]+>)', "`$1`r`n$perms"
    Set-Content -Path $manifest -Value $x -NoNewline
    OK "Permissions added to AndroidManifest.xml"
} else {
    OK "Permissions already present"
}

# raise minSdkVersion to 21 (flutter_blue_plus requires it)
$gradle = ".\android\app\build.gradle"
if (Test-Path $gradle) {
    (Get-Content $gradle) `
        -replace "minSdkVersion flutter.minSdkVersion", "minSdkVersion 21" `
        -replace "minSdk = flutter.minSdkVersion", "minSdk = 21" |
        Set-Content $gradle
    OK "minSdkVersion set to 21"
}

# --- 7. Build ----------------------------------------------------------------
Section "Step 7/7  Build the release APK"
flutter pub get
flutter build apk --release
$apk = ".\build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $apk)) { Fail "APK not produced. Check the Flutter output above." }
Copy-Item $apk ".\gs-label-app.apk" -Force

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host " APK ready :  $((Resolve-Path .\gs-label-app.apk).Path)"     -ForegroundColor Green
Write-Host " (Also at $apk)"                                              -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Install on a phone via:"
Write-Host "  adb install -r gs-label-app.apk"
Write-Host "or copy the .apk file to the phone and tap it"
