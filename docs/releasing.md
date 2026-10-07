# Releasing uHerdr

Releases are built by `.github/workflows/release.yml` when a version tag such as `v0.2.0` (matching `v[0-9]*`) is pushed. The workflow builds a universal (Apple silicon + Intel) `uHerdr.app`, signs it with Developer ID, notarizes and staples it, and publishes `uHerdr-<version>.dmg`, `uHerdr-<version>.zip`, and `SHA256SUMS` to a GitHub release with generated notes.

For stable releases it then uploads `appcast.xml`, the [Sparkle](https://sparkle-project.org) update feed. Installed apps read it from `releases/latest/download/appcast.xml`, so publishing a stable release is what offers it as an update; the feed points at that release's zip and shows its generated notes. Pre-releases are never "latest" and get no feed.

## Cutting a release

```sh
git switch main && git pull
TAG=v0.2.0                # or v0.3.0-beta.1 for a pre-release
git tag "$TAG"
git push origin "$TAG"
```

The tag sets the version: `CFBundleShortVersionString` is the tag without `v` or any pre-release suffix, and `CFBundleVersion` is the commit count. Tags with a `-suffix` are published as pre-releases. Sparkle compares `CFBundleVersion`, so always tag a commit on `main` that is newer than the previous release.

To test the pipeline without publishing, run the **Release** workflow manually from the Actions tab. It produces an unsigned, un-notarized build as a workflow artifact.

## One-time setup

Add these repository secrets under **Settings → Secrets and variables → Actions**.

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 of your exported **Developer ID Application** certificate and private key: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` |
| `MACOS_SIGN_IDENTITY` | Full identity name, for example `Developer ID Application: Your Name (TEAMID1234)`; list with `security find-identity -v -p codesigning` |
| `NOTARY_KEY_P8` | Contents of an App Store Connect API key (`AuthKey_XXXX.p8`) |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | Issuer ID shown on the App Store Connect API keys page |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key, exported as described below |

1. **Certificate:** in Xcode → Settings → Accounts → Manage Certificates, add a *Developer ID Application* certificate (or create one at developer.apple.com). In Keychain Access, export the certificate together with its private key as `.p12`.
2. **API key:** in App Store Connect → Users and Access → Integrations → App Store Connect API, create a team key with the *Developer* role and download the `.p8` (it can only be downloaded once).
3. **Update signing key:** Sparkle verifies every update and feed with an EdDSA key. After `swift package resolve`, create the key in your login keychain and print its public half:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   Commit the public key as the default `SPARKLE_PUBLIC_KEY` in `scripts/build-app.sh`. Export the private key, store it as the `SPARKLE_PRIVATE_KEY` secret, and delete the file:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle.key
   gh secret set SPARKLE_PRIVATE_KEY < sparkle.key && rm sparkle.key
   ```

   Back the key up somewhere safe. Installed apps only accept updates signed with it; losing it means users must reinstall manually.

## Building a release locally

```sh
UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh
xcrun notarytool store-credentials uherdr-notary   # once; prompts for credentials
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=uherdr-notary ./scripts/package-release.sh
./scripts/make-appcast.sh   # signs dist/appcast.xml with the key in your keychain
```

Without notary credentials `package-release.sh` still creates the DMG and zip, but they are not notarized and Gatekeeper will block them on other Macs.
