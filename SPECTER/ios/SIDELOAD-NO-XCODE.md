# Sideloading SPECTER without installing Xcode (iOS 26.6.1)

> TrollStore does **not** work on iOS 26.6.1 (its exploit was patched back in iOS 16.7/17.0),
> so this is the way to get a custom-built app on a modern iPhone without a paid
> developer account. The app is signed with your **free** Apple ID and works for 7 days
> per signing, then you refresh it.

The idea: a cloud macOS machine compiles the app into an **unsigned `.ipa`** for you
(no local Xcode). You then install that `.ipa` with a signing tool that re-signs it
with your Apple ID at install time.

## Step 1 — Put this project on GitHub (one time)

1. Create a free account at github.com and a new **private** repository, e.g. `specter`.
2. Push the whole `C:\SPECTER` folder to it. If you don't use git yet, from the folder:
   ```bash
   git init
   git add .
   git commit -m "SPECTER"
   git branch -M main
   git remote add origin https://github.com/<you>/specter.git
   git push -u origin main
   ```
   (The `.github/workflows/build-ipa.yml` and `ios/project.yml` I added drive the build.)
3. *(optional)* Edit `ios/project.yml` and set `PRODUCT_BUNDLE_IDENTIFIER` to something
   unique to you, e.g. `com.yourname.specter`.

## Step 2 — Build the .ipa in the cloud

1. On GitHub open the repo → **Actions** tab → enable workflows if prompted.
2. Pick **build-ipa** → **Run workflow** → run on `main`.
3. Wait ~3–6 minutes. Open the finished run → **Artifacts** → download
   **`SPECTER-unsigned-ipa`** → unzip to get `SPECTER-unsigned.ipa`.

GitHub gives free macOS runner minutes on private repos and unlimited on public ones —
plenty for this.

## Step 3 — Install it with your Apple ID (no Xcode)

Pick **one** tool. Since you have a Mac, **Sideloadly** is the simplest.

### Option A — Sideloadly (Mac or Windows, easiest)
1. Install Sideloadly from sideloadly.io. It bundles what it needs — **no Xcode required**.
2. Plug in the iPhone, open Sideloadly.
3. Drag `SPECTER-unsigned.ipa` in, enter your Apple ID, click **Start**.
   (Use an app-specific password if your Apple ID has 2FA.)
4. On the phone: **Settings → General → VPN & Device Management → Developer App → Trust**.
5. To refresh before the 7 days expire, just run Sideloadly again.

### Option B — SideStore (on-device, auto-refresh, no computer after setup)
Nicer long-term because it refreshes the 7-day signature over Wi-Fi by itself, but the
one-time setup (a pairing file + the SideStore app) is more involved. See sidestore.io.
Once installed, open the `.ipa` in SideStore → **+** → install.

## Step 4 — Run
1. Start the PC server (`server/run.ps1`), note the IP it prints.
2. Open SPECTER, allow the **local network** prompt, enter IP + port + password.

---

### Reality check
- You cannot avoid the *build* step — turning Swift source into an app needs Xcode's
  toolchain. We just moved that onto a free cloud Mac so **you** never install Xcode.
- If you ever decide the 7-day refresh is annoying and you *do* have the Mac anyway,
  building straight from Xcode (see `README.md`) is actually fewer moving parts.
