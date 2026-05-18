# Sparkle EdDSA Keys — Generation, Rotation, and Hygiene

MultiverseWP uses Sparkle 2.x for in-app auto-updates. Every release artefact
(`MultiverseWP-<version>.dmg`) must be signed with an **EdDSA (ed25519)
private key**. The matching **public key** is baked into the app via the
`SUPublicEDKey` Info.plist entry (see `project.yml`).

Sparkle refuses to install an update whose signature does not verify against
that public key. This is what stops a hijacked GitHub Pages feed from pushing
malware to your users.

> **The private key is never committed to this repository.** It lives in your
> macOS Keychain only, exported on demand into a local file for signing CI
> builds.

---

## 1. First-time key generation (one-time, per app)

After `xcodegen generate` and a first `xcodebuild build`, SPM checks out
Sparkle into `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/checkouts/Sparkle/`.
Inside that folder there is a `bin/` directory shipping the two CLI tools:

```bash
SPARKLE_DIR="$(find ~/Library/Developer/Xcode/DerivedData \
  -type d -path '*/SourcePackages/checkouts/Sparkle' 2>/dev/null | head -n1)"

# Generates a new ed25519 key pair, prints the public key, and stores the
# private key in your login Keychain under the item "https://sparkle-project.org".
"$SPARKLE_DIR/bin/generate_keys"
```

The tool prints something like:

```
A new Sparkle EdDSA key has been generated and stored in your Keychain.
Public key (use this in your Info.plist's SUPublicEDKey):

  Lu7XEa+xeR0qP9P2yZ8/Wb8AbCD…XYZ=
```

Copy that public key string and paste it into `project.yml`, replacing the
`REPLACE_ME_WITH_PUBLIC_KEY` placeholder under the `SUPublicEDKey` Info.plist
entry. Then re-run `xcodegen generate`.

The private key now lives in **Keychain Access → login → Passwords**, under
the service name `https://sparkle-project.org` and account name `ed25519`.
You can verify with:

```bash
security find-generic-password -s "https://sparkle-project.org" -a ed25519 -g
```

(The password value displayed there is the base64-encoded private key.)

---

## 2. Signing a release on the developer machine

Every time `scripts/release.sh` produces a DMG it also invokes
`sign_update` to sign the artefact and embed the signature in
`release/appcast.xml`. The release script auto-detects the Sparkle tools at
`$SPARKLE_DIR/bin/sign_update` and, if the private key is in the Keychain,
no extra setup is required.

If you ever need to sign manually:

```bash
"$SPARKLE_DIR/bin/sign_update" release/MultiverseWP-0.2.0.dmg
# → outputs:  sparkle:edSignature="..." length="12345678"
```

Paste those attributes into the `<enclosure>` element of `appcast.xml`.

---

## 3. Signing in CI (GitHub Actions)

GitHub Actions runners do not have access to your Keychain, so for tagged
releases we export the private key into a repository secret and feed it to
`sign_update` via the `-f` flag:

1. On your dev machine, export the key into a file (one-time):

   ```bash
   "$SPARKLE_DIR/bin/generate_keys" -x sparkle_ed_private.key
   # Note: -x writes the *currently active* private key to disk.
   # Treat this file as a secret. Delete it after you have set the GitHub
   # Actions secret.
   ```

2. In the GitHub web UI: **Settings → Secrets and variables → Actions →
   New repository secret**. Name it `SPARKLE_ED_PRIVATE_KEY`. Paste the file
   contents.

3. `shred -u sparkle_ed_private.key` (or `rm -P` on macOS).

4. `.github/workflows/release.yml` writes the secret to a temp file and runs
   `sign_update -f $TEMP_KEY_FILE` against the DMG before publishing the
   appcast. See that file for the exact wiring.

---

## 4. Rotating the key (rare, but plan for it)

A rotation is **destructive for older versions of the app** — once the new
public key is in `SUPublicEDKey`, builds shipped with the old `SUPublicEDKey`
will not accept updates signed by the new private key. They will keep running
the version they have. Users have to download a fresh DMG manually.

Steps:

1. Generate the new pair: `"$SPARKLE_DIR/bin/generate_keys" --account-name new`.
2. Update `project.yml` `SUPublicEDKey` → new public key.
3. Bump `MARKETING_VERSION` (Sparkle treats a key rotation as a major release).
4. Re-sign all future builds with the new private key.
5. Post a blog/release note telling existing users to grab the new DMG by
   hand. Once they install the new version, future auto-updates work again.

Rotate the key only when:

- The private key is suspected to be exposed (laptop stolen, secret leaked).
- You move to a fundamentally different signing setup (HSM, etc.).

---

## 5. Things that are NOT in the repo

- The private key itself (Keychain or GitHub Actions secret only).
- Any file with extension `.key`, `.priv`, `.pem` — gitignored as a defence
  in depth (`.gitignore` rule: `*.key`, `sparkle_ed_*`).

If you ever see one in `git status`, **stop**, do not commit, and rotate.
