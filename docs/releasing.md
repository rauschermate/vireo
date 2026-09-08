# Releasing Vireo

This guide explains how to cut a signed, notarized release with working
auto-updates. It also explains the version scheme and how updates reach users.

## What a release ships

- A notarized, stapled `Vireo.dmg` for direct download.
- An EdDSA-signed `appcast.xml` that the in-app updater (Sparkle) reads.
- A GitHub release tagged `v<version>` that holds both files.

The app polls one feed URL:
`https://github.com/rauschermate/vireo/releases/latest/download/appcast.xml`.
GitHub resolves `latest` to the newest release. So each release replaces the
feed on its own, and nothing else changes between releases.

## One-time setup

Do this once per machine that cuts releases.

### 1. Get an Apple Developer ID

1. Join the Apple Developer Program.
2. Install a "Developer ID Application" certificate in your login keychain.
3. Note your Team ID (10 characters) and the certificate name.

If you skip notarization, other Macs block the app with a Gatekeeper warning.

### 2. Create a notary profile

Run this once. Use an app-specific password from appleid.apple.com.

```bash
xcrun notarytool store-credentials VIREO_NOTARY_PROFILE \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

### 3. Generate the Sparkle signing key

Run:

```bash
./scripts/updater-keys.sh
```

The script stores the private key in your login keychain. It writes the public
key into `project/App-Info.plist` as `SUPublicEDKey`.

1. Commit the updated `project/App-Info.plist`.
2. Back up the private key offline:
   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.pem
   ```
3. Store the backup somewhere safe, then delete the local copy.

If you lose the private key, you can never ship a verifiable update again. Users
must then reinstall by hand.

The updater stays dormant until `SUPublicEDKey` holds a value. An unsigned dev
build never self-updates.

## Cut a release

Do these steps for every release.

### 1. Bump the version

Edit `project.yml`:

- Set `MARKETING_VERSION` to the new semantic version, for example `0.2.0`. This
  value becomes the tag `v0.2.0`. Sparkle shows it and compares it.
- Raise `CURRENT_PROJECT_VERSION` by one. It is an integer build number. Sparkle
  ranks updates by it, so it must always rise.

Commit the bump.

### 2. Build, sign, notarize, and publish

Set the three variables and run the release script:

```bash
VIREO_TEAM_ID=TEAMID \
  VIREO_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  VIREO_NOTARY_PROFILE=VIREO_NOTARY_PROFILE \
  ./scripts/release.sh --publish
```

The script runs the whole chain:

1. Regenerate the Xcode project.
2. Archive the app, signed with the Developer ID.
3. Notarize and staple the app.
4. Build `Vireo.dmg`, sign it, notarize it, and staple it.
5. EdDSA-sign the DMG and generate `appcast.xml`.
6. Create the GitHub release `v<version>` and upload both files.

To build the artifacts without a release, omit `--publish`. The script then
prints the upload command.

### 3. Point the website at the release

The download button in `site/index.html` must link to the DMG:

```
https://github.com/rauschermate/vireo/releases/latest/download/Vireo.dmg
```

## Versioning

- `MARKETING_VERSION` is the user-facing version (`CFBundleShortVersionString`).
  Use semantic versions such as `0.2.0` or `1.0.0`.
- `CURRENT_PROJECT_VERSION` is the build number (`CFBundleVersion`). Use a plain
  integer that always rises, one per release.
- The release tag is `v` plus `MARKETING_VERSION`.

## How updates reach users

- The app checks the feed every hour (`SUScheduledCheckInterval`, 3600 seconds).
- A user can also check now through **Vireo ▸ Check for Updates…**.
- When a newer version exists, the update pill appears in the window's
  bottom-left corner.
- Sparkle verifies the DMG signature against the built-in public key, replaces
  the app atomically, and relaunches. The custom pill drives the whole flow;
  Sparkle's own windows stay hidden.

## Ad-hoc build (no Apple account)

For a quick share without a Developer ID:

```bash
./scripts/build-app.sh release
./scripts/make-dmg.sh build/Vireo.app build/Vireo.dmg
```

Recipients must bypass Gatekeeper by hand. This build never auto-updates. Use it
only for informal testing.

## First-release checklist

- [ ] Developer ID certificate installed; Team ID known.
- [ ] Notary profile created.
- [ ] `./scripts/updater-keys.sh` run; `SUPublicEDKey` committed; private key backed up.
- [ ] Version set in `project.yml`.
- [ ] `./scripts/release.sh --publish` run.
- [ ] Website download button points at the release DMG.
