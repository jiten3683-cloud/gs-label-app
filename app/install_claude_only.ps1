# =============================================================================
#  install_claude_only.ps1
#
#  Installs ONLY what's needed for the Claude Code plugin inside an already-
#  installed Android Studio:
#    - Node.js LTS
#    - @anthropic-ai/claude-code (the 'claude' CLI the plugin depends on)
#
#  USAGE:
#    Right-click  ->  "Run with PowerShell"   (Administrator)
#    Total time: ~3-5 minutes.
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

# --- 1. Chocolatey (already there from the previous installer, just in case) -
Section "Step 1/3  Chocolatey check"
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = "$env:ProgramData\chocolatey\bin;$env:Path"
}
OK "choco $(choco --version)"

# --- 2. Node.js LTS ---------------------------------------------------------
Section "Step 2/3  Node.js LTS"
if (Get-Command node -ErrorAction SilentlyContinue) {
    OK "node $(node --version) already installed"
} else {
    choco install -y nodejs-lts --no-progress
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}
node --version
npm --version

# --- 3. Claude Code CLI -----------------------------------------------------
Section "Step 3/3  Claude Code CLI (@anthropic-ai/claude-code)"
$pkg = "@anthropic-ai/claude-code"
$installed = (npm list -g $pkg 2>$null) -match "claude-code"
if ($installed) {
    OK "$pkg already installed"
} else {
    npm install -g $pkg
    if ($LASTEXITCODE -ne 0) {
        Warn "First attempt failed; retrying with --force..."
        npm install -g $pkg --force
        if ($LASTEXITCODE -ne 0) { Fail "npm install $pkg failed" }
    }
}

# Verify
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    OK "Claude CLI at $($claudeCmd.Source)"
    Write-Host "    Version: $(claude --version 2>&1 | Select-Object -First 1)"
} else {
    Warn "'claude' not on PATH yet. Open a NEW terminal and run 'claude --version' to confirm."
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Node + Claude CLI ready." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "INSIDE ANDROID STUDIO (5 minutes):" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Launch Android Studio."
Write-Host "  2. File -> Settings -> Plugins -> Marketplace"
Write-Host "     Search: Claude Code"
Write-Host "     Install the entry published by 'Anthropic'."
Write-Host "  3. Click 'Restart IDE' when prompted."
Write-Host "  4. After restart, click the Claude Code icon on the right toolbar."
Write-Host "     Sign in with your claude.ai account."
Write-Host ""
Write-Host "FIRST PROMPT TO TRY:" -ForegroundColor Cyan
Write-Host "  Open lib\services\ble_service.dart, then in the Claude panel ask:"
Write-Host "    'walk me through how this BLE service works and where it could be improved'"
