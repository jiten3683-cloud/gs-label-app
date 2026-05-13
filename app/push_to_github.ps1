# =============================================================================
#  push_to_github.ps1
#  One-shot helper to push this folder to a NEW GitHub repository and trigger
#  the cloud build of the APK (no Flutter or Android SDK needed on this PC).
#
#  PREREQUISITE (5 minutes, one-time):
#    1. Install Git for Windows  -> https://git-scm.com/download/win
#    2. Make a free GitHub account at https://github.com  if you don't have one.
#    3. On GitHub, click the "+" top-right -> New repository.
#         Name it "gs-label-app"  (or anything you like).
#         Choose Public OR Private, no need to add README/.gitignore.
#         Click "Create repository".
#       Copy the URL shown, e.g.:
#         https://github.com/<your-username>/gs-label-app.git
#
#  HOW TO USE:
#    Right-click this script -> "Run with PowerShell".
#    It will ask for that repo URL, then push the project and tell you the
#    URL where the APK will appear once GitHub Actions finishes (~5 min).
# =============================================================================

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
function Say($t)  { Write-Host $t -ForegroundColor Cyan }
function OK($t)   { Write-Host "OK : $t" -ForegroundColor Green }
function Fail($t) { Write-Host "FAIL: $t" -ForegroundColor Red; exit 1 }

# --- 0. Git installed? -------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "Git is not installed. Install Git for Windows from https://git-scm.com/download/win and re-run this script."
}
OK ("git " + (git --version))

# --- 1. Ask for repo URL -----------------------------------------------------
Say ""
Say "Paste the GitHub repository URL you created."
Say "Example:  https://github.com/jitendra/gs-label-app.git"
$repoUrl = Read-Host "GitHub repo URL"
if (-not $repoUrl) { Fail "No URL provided." }

# --- 2. Configure git identity if missing ------------------------------------
$gitName  = (git config --global user.name  2>$null)
$gitEmail = (git config --global user.email 2>$null)
if (-not $gitName)  {
    $n = Read-Host "Your name for git commits"
    git config --global user.name  "$n"
}
if (-not $gitEmail) {
    $e = Read-Host "Your email for git commits"
    git config --global user.email "$e"
}

# --- 3. Init / commit --------------------------------------------------------
if (-not (Test-Path ".\.git")) {
    Say "Initialising new git repository..."
    git init -b main | Out-Null
}
git add .
git diff --cached --quiet 2>$null
if ($LASTEXITCODE -ne 0) {
    git commit -m "Initial commit: Gold & Silver Label app" | Out-Null
    OK "Commit created."
} else {
    OK "Nothing new to commit."
}

# --- 4. Push -----------------------------------------------------------------
$remotes = git remote
if ($remotes -notcontains "origin") {
    git remote add origin $repoUrl
} else {
    git remote set-url origin $repoUrl
}

Say ""
Say "Pushing to GitHub. A login window will pop up the first time -"
Say "use your GitHub username and a Personal Access Token as password."
Say "Create a token here:  https://github.com/settings/tokens?type=beta"
Say "  Scopes needed:  'repo'  and  'workflow'."
Say ""
git push -u origin main
if ($LASTEXITCODE -ne 0) { Fail "Push failed - see the message above." }
OK "Code pushed."

# --- 5. Show next-step URL ---------------------------------------------------
$base = $repoUrl -replace "\.git$", ""
Say ""
Say "===================================================================="
Say "  Done!  GitHub Actions will now build the APK automatically."
Say ""
Say "  Watch the build:   $base/actions"
Say "  Build takes ~5 minutes the first time."
Say ""
Say "  When it shows a green check, open the run and download the artifact"
Say "  named  gs-label-app-release-apk  -- it contains app-release.apk."
Say "===================================================================="
