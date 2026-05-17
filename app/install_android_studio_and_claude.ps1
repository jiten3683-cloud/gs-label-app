# =============================================================================
#  install_android_studio_and_claude.ps1
#
#  Installs Android Studio and the prerequisites for the Claude Code plugin
#  (Node.js LTS + the @anthropic-ai/claude-code CLI).
#
#  USAGE:
#    Right-click  ->  "Run with PowerShell"   (Administrator)
#    Total time: ~15-25 minutes depending on internet speed.
#
#  After this finishes, follow the on-screen instructions to:
#    1. Open Android Studio
#    2. Install the "Claude Code" plugin from JetBrains Marketplace
#    3. Sign in with your Anthropic account
# =============================================================================

$ErrorActionPreference = "Stop"
function Section($t) { Write-Host "`n========== $t ==========" -ForegroundColor Cyan }
function OK($t)      { Write-Host "OK : $t" -ForegroundColor Green }
function Warn($t)    { Write-Host "WARN: $t" -ForegroundColor Yellow }
function Fail($t)    { Write-Host "FAIL: $t" -ForegroundColor Red; exit 1 }

# --- 0. Admin check ----------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Please right-click this script and choose 'Run with PowerShell' as Administrator."
}

# --- 1. Chocolatey (should already be installed, but just in case) ----------
Section "Step 1/4  Chocolatey check"
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = "$env:ProgramData\chocolatey\bin;$env:Path"
}
OK "choco $(choco --version)"

# --- 2. Android Studio ------------------------------------------------------
Section "Step 2/4  Android Studio (this is ~1.2 GB, please be patient)"
if (Get-Command "studio64" -ErrorAction SilentlyContinue) {
    OK "Android Studio already on PATH"
} elseif (Test-Path "C:\Program Files\Android\Android Studio\bin\studio64.exe") {
    OK "Android Studio already installed at C:\Program Files\Android\Android Studio"
} else {
    choco install -y androidstudio --no-progress
    if ($LASTEXITCODE -ne 0) { Fail "choco install androidstudio failed" }
    OK "Android Studio installed"
}

# --- 3. Node.js LTS ---------------------------------------------------------
Section "Step 3/4  Node.js LTS (needed by the Claude CLI)"
if (Get-Command node -ErrorAction SilentlyContinue) {
    OK "node $(node --version) already installed"
} else {
    choco install -y nodejs-lts --no-progress
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}
node --version
npm --version

# --- 4. Claude Code CLI -----------------------------------------------------
Section "Step 4/4  Claude Code CLI (@anthropic-ai/claude-code)"
$pkg = "@anthropic-ai/claude-code"
$installed = (npm list -g $pkg 2>$null) -match "claude-code"
if ($installed) {
    OK "$pkg already installed globally"
} else {
    npm install -g $pkg
    if ($LASTEXITCODE -ne 0) {
        Warn "First attempt failed; retrying with --force..."
        npm install -g $pkg --force
        if ($LASTEXITCODE -ne 0) { Fail "npm install $pkg failed" }
    }
    OK "$pkg installed"
}

# Sanity check - the CLI command is 'claude'
$claudeCmd = (Get-Command claude -ErrorAction SilentlyContinue)
if ($claudeCmd) {
    OK "Claude CLI available at $($claudeCmd.Source)"
} else {
    Warn "'claude' command not yet on PATH. Open a NEW terminal after this script finishes and run 'claude --version'."
}

# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Installation complete." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEPS (5 minutes, in Android Studio's UI):" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Launch Android Studio from the Start menu."
Write-Host "     - Walk through the first-run wizard. Pick STANDARD setup."
Write-Host "     - Wait for it to download missing SDK pieces (~5 min)."
Write-Host ""
Write-Host "  2. Open the GS Label project:"
Write-Host "     File -> Open -> navigate to"
Write-Host "       E:\display iot\ESP32_P10_Display_Firmware\GoldSilverLabelApp\app"
Write-Host "     Click OK. Let it import (~2 min)."
Write-Host ""
Write-Host "  3. Install the Claude Code plugin:"
Write-Host "     File -> Settings -> Plugins -> Marketplace tab"
Write-Host "     Search for:  Claude Code"
Write-Host "     Click Install on the entry by 'Anthropic'."
Write-Host "     Restart Android Studio when prompted."
Write-Host ""
Write-Host "  4. Sign in:"
Write-Host "     After restart, look for the Claude Code icon in the right toolbar."
Write-Host "     Click it. A login prompt opens in your browser."
Write-Host "     Sign in with the same account you use at claude.ai."
Write-Host ""
Write-Host "  5. Try it: open lib\main.dart, hit the Claude Code panel, and ask:"
Write-Host "       'walk me through how the app's BLE service works'"
Write-Host ""
