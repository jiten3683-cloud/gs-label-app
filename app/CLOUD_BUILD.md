# Cloud build — no Flutter / Android SDK installed on this PC

This route builds the APK on GitHub's servers in about 5 minutes. The only thing you install locally is Git (~50 MB).

## Step 1 — Install Git (one-time, 2 min)
Download from <https://git-scm.com/download/win> and run the installer with the default options.

## Step 2 — Create a GitHub account & repo (one-time, 2 min)
1. Sign up at <https://github.com> if you don't already have an account.
2. Top-right **+** menu → **New repository**.
3. Name it `gs-label-app` (anything works).
4. Public or Private — your choice.
5. Do **not** tick "Add a README" or "Add .gitignore". Just click **Create repository**.
6. On the next page, copy the HTTPS URL it shows you. It looks like:
   ```
   https://github.com/<your-username>/gs-label-app.git
   ```

## Step 3 — Create a Personal Access Token (one-time, 2 min)
GitHub requires a token instead of your password for `git push`.
1. <https://github.com/settings/tokens?type=beta> → **Generate new token**.
2. Name: `apk-build`. Expiry: 90 days.
3. Scopes / permissions:
   - Contents: **Read and write**
   - Workflows: **Read and write**
4. Click **Generate** and copy the token (`github_pat_…`). You can only see it once.

## Step 4 — Push the project (30 seconds)
1. Right-click `push_to_github.ps1` in this folder → **Run with PowerShell**.
2. Paste the repo URL when asked.
3. When the login window appears: username = your GitHub username, password = the token from Step 3.

## Step 5 — Download the APK (~5 min later)
1. On GitHub, open your repo → click the **Actions** tab.
2. The "Build APK" workflow is running. Wait for the green check.
3. Click the run → scroll down → under **Artifacts** click `gs-label-app-release-apk`.
4. Unzip it. Inside is `app-release.apk`.

## Step 6 — Install on your phone
- **Easy:** Email or WhatsApp the APK to yourself, open the attachment on the phone, tap it. (Enable "Install from unknown sources" if prompted.)
- **Faster, with USB cable + USB debugging:**
  ```
  adb install -r app-release.apk
  ```

## Re-builds in the future
Any time you change the code, run `push_to_github.ps1` again. GitHub Actions rebuilds automatically. Each rebuild is about 3 minutes after the first one (caching helps).

## Cost
GitHub Actions is free for public repos and gives 2,000 free build-minutes per month for private repos. A full APK build takes ~3-5 minutes — you can rebuild 400+ times per month for free.
