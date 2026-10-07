# Releasing uHerdr

Releases are built by `.github/workflows/release.yml` when a `v*` tag is pushed. The workflow builds a universal (Apple silicon + Intel) `uHerdr.app`, signs it with Developer ID, notarizes and staples it, and publishes `uHerdr-<version>.dmg`, `uHerdr-<version>.zip`, and `SHA256SUMS` to a GitHub release with generated notes.

## Cutting a release

```sh
git switch main && git pull
git tag v0.2.0            # or v0.3.0-beta.1 for a pre-release
git push origin v0.2.0
```

The tag sets the version: `CFBundleShortVersionString` is the tag without `v` or any pre-release suffix, and `CFBundleVersion` is the commit count. Tags with a `-suffix` are published as pre-releases.

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

1. **Certificate:** in Xcode → Settings → Accounts → Manage Certificates, add a *Developer ID Application* certificate (or create one at developer.apple.com). In Keychain Access, export the certificate together with its private key as `.p12`.
2. **API key:** in App Store Connect → Users and Access → Integrations → App Store Connect API, create a team key with the *Developer* role and download the `.p8` (it can only be downloaded once).

## Building a release locally

```sh
UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh
xcrun notarytool store-credentials uherdr-notary   # once; prompts for credentials
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=uherdr-notary ./scripts/package-release.sh
```

Without notary credentials `package-release.sh` still creates the DMG and zip, but they are not notarized and Gatekeeper will block them on other Macs.
