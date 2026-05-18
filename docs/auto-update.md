# Auto-Updates / Otomatik Güncellemeler

MultiverseWP uses **Sparkle 2.x** to keep itself up to date. This document
explains the user-facing behavior — what triggers an update, how to check
manually, and how to opt out.

> Sparkle hakkında Türkçe özet aşağıda **TR** başlığı altındadır.

---

## How it works (EN)

- The app embeds a public EdDSA key (`SUPublicEDKey` in `Info.plist`).
- Once per launch (and roughly every 24 hours afterwards) Sparkle fetches
  `https://unkownpr.github.io/multiversewp/appcast.xml`.
- If the appcast advertises a version newer than the running build,
  Sparkle verifies the EdDSA signature of the new DMG against the bundled
  public key. If the signature does not match, the update is rejected and
  nothing is installed. This is what stops a hijacked feed from delivering
  malware.
- After verification, Sparkle prompts you with the standard macOS update
  dialog (release notes, "Install Update" / "Remind Me Later" / "Skip This
  Version" buttons). Nothing installs without your click.

### Manual check

Two equivalent paths:

1. **Menu bar:** `MultiverseWP → Check for Updates…`
2. **Settings → About → "Check for Updates Now"**

Both buttons are disabled while a check is already in progress.

### Disabling automatic checks

Open **Settings → About** and uncheck *"Automatically check for updates"*.
This corresponds to Sparkle's `SUEnableAutomaticChecks` preference, stored
under your user defaults at `com.semihsilistre.multiversewp`. To force-disable
from a terminal:

```bash
defaults write com.semihsilistre.multiversewp SUEnableAutomaticChecks -bool NO
```

To re-enable:

```bash
defaults write com.semihsilistre.multiversewp SUEnableAutomaticChecks -bool YES
```

Even with automatic checks off, the "Check for Updates…" menu item keeps
working.

### Sandboxing & Sparkle

Sparkle 2.x supports App Sandbox via its XPC services (the
`SUEnableInstallerLauncherService` Info.plist key enables this). MultiverseWP
currently ships ad-hoc signed (no Apple Developer team), so it runs **outside
the sandbox** — Sparkle's regular installer path works without further setup.

When/if we move to a notarized, sandboxed build:

- The Sparkle installer XPC must be embedded in `Contents/XPCServices/`
  (Sparkle's SPM target does this automatically).
- The entitlements file (`Resources/MultiverseWP.entitlements`) keeps
  `com.apple.security.app-sandbox = YES`.
- No additional entitlement is required for Sparkle's launcher service; the
  default `com.apple.security.network.client` we already grant is sufficient
  to fetch the appcast.

If you ever see Sparkle fail with a *"could not connect to installer
service"* error on a sandboxed build, double-check that the XPC service ended
up in the app bundle (`ls MultiverseWP.app/Contents/XPCServices`). The most
common cause is a stale archive that pre-dates adding the Sparkle package —
fix with a clean build (`rm -rf build/ release/` and rebuild).

---

## Türkçe Özet (TR)

- Uygulama, açıldığında ve yaklaşık 24 saatte bir GitHub Pages üzerinde
  barındırılan `appcast.xml` dosyasını okur.
- Yeni bir sürüm varsa Sparkle, DMG dosyasının dijital imzasını uygulamaya
  gömülü açık anahtarla doğrular. İmza geçerli değilse güncelleme reddedilir.
- İmza doğrulanırsa standart macOS güncelleme penceresi açılır. Onay vermeden
  hiçbir şey kurulmaz.

### Elle kontrol

- **Menü çubuğu:** `MultiverseWP → Check for Updates…`
- **Ayarlar → Hakkında → "Check for Updates Now"**

### Otomatik kontrolü kapatma

Ayarlar → Hakkında bölümünde "Automatically check for updates" kutucuğunu
kaldırın. Terminalden hızlı yöntem:

```bash
defaults write com.semihsilistre.multiversewp SUEnableAutomaticChecks -bool NO
```

Otomatik kontrol kapalıyken bile menüdeki "Check for Updates…" çalışmaya
devam eder.
