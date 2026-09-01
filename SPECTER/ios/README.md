# SPECTER — iOS client (build & sideload)

The client is plain Swift + SwiftUI + CryptoKit + Network.framework. No third-party
pods/packages. You build it once in Xcode on your Mac and sideload it onto your iPhone.

## 1. Create the Xcode project

1. Open **Xcode → File → New → Project → iOS → App**.
2. Product Name: `SPECTER` · Interface: **SwiftUI** · Language: **Swift**.
3. Set a unique **Bundle Identifier**, e.g. `com.yourname.specter`.
4. Delete the auto-generated `ContentView.swift` and `SPECTERApp.swift`.
5. Drag **every file** from `ios/SPECTER/Sources/` into the project
   (check *Copy items if needed* and add to the SPECTER target):
   - `SPECTERApp.swift`, `ContentView.swift`, `RemoteScreenView.swift`
   - `SpecterClient.swift`, `SpecterCrypto.swift`, `SpecterProtocol.swift`
   - `SpecterKeys.swift`, `Helpers.swift`
6. Add the **Local Network** permission. Either drag in `ios/SPECTER/Info.plist`
   and point the target's *Info.plist File* build setting at it, **or** in the
   target's **Info** tab add a row:
   `Privacy - Local Network Usage Description` = *"SPECTER connects to your PC on the local network."*

No extra frameworks to link — `CryptoKit`, `CommonCrypto`, `Network`, `Security`
and `UIKit` are all system modules.

## 2. Sideload onto your iPhone (free, no TestFlight)

1. Plug in the iPhone, select it as the run destination.
2. **Signing & Capabilities → Team**: pick your personal Apple ID (free account is fine).
3. Press **Run (⌘R)**. Xcode installs the app on the phone.
4. On the phone: **Settings → General → VPN & Device Management → Developer App →
   Trust** your certificate.
5. Free-account caveat: the signature expires after **7 days** — just hit Run again
   from Xcode to refresh it. (A paid Apple Developer account extends this to a year.)

> The phone and PC must be on the **same Wi-Fi / LAN**. The first time you connect,
> iOS shows a "find devices on local network" prompt — allow it.

## 3. Connect

1. Start the server on the PC (`server/run.ps1`) and note the IP it prints.
2. In the app enter that **IP**, the **port** (default `45813`) and your **password**.
3. Toggle *Remember password* to store it in the iOS Keychain for one-tap reconnect.

## Gestures

| Gesture | Action |
|---|---|
| one-finger swipe | move cursor |
| single tap | left click |
| double tap | double click |
| two-finger tap | right click |
| press-hold then drag | hold left button (drag / select / move windows) |
| two-finger drag | scroll |
| ⌨︎ toolbar button | raise iOS keyboard (typing is forwarded; Bluetooth keyboards work too) |

Modifier buttons (Ctrl/Shift/Alt/Win) **latch** — tap Ctrl then `c` for Ctrl+C.
Tapping a special key auto-releases latched modifiers.
