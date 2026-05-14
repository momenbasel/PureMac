# Release pipeline secrets

`.github/workflows/release.yml` requires the following GitHub Actions secrets
on `momenbasel/PureMac`. All seven must be set before the next tag push or the
notarize/staple steps will fail and ship a broken signature (the cause of #86).

## Required secrets

| Secret | Source | Notes |
|--------|--------|-------|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application `.p12` exported from Keychain Access, `base64 -i cert.p12 \| pbcopy` | Includes both cert and private key |
| `P12_PASSWORD` | Password set when exporting the `.p12` | Choose a strong random one |
| `KEYCHAIN_PASSWORD` | Random string | Only used to lock the runner's temp keychain — never leaves CI |
| `APPLE_ID` | The Apple ID email used for App Store Connect | e.g. `you@icloud.com` |
| `APPLE_APP_PASSWORD` | App-specific password from <https://appleid.apple.com/account/manage> → Sign-In and Security → App-Specific Passwords | NOT your AppleID password |
| `APPLE_TEAM_ID` | `H3WXHVTP97` (already set in workflow as env, no secret needed unless you want to override) | — |
| `HOMEBREW_TAP_TOKEN` | Fine-grained PAT with `Contents: read+write` on `momenbasel/homebrew-tap` | Needed for the cross-repo formula bump step |

## Extracting your Developer ID cert as `.p12`

```bash
# 1. Open Keychain Access → login keychain → "My Certificates"
# 2. Right-click "Developer ID Application: Moamen Basel (H3WXHVTP97)" → Export
# 3. Save as PureMac-DeveloperID.p12, set P12_PASSWORD when prompted

# 4. Convert to base64 for the GH secret:
base64 -i ~/Downloads/PureMac-DeveloperID.p12 | pbcopy
# now paste into BUILD_CERTIFICATE_BASE64
```

CLI alternative (no GUI):

```bash
security find-certificate -c "Developer ID Application: Moamen Basel" -p login.keychain
# To export the matching private key as p12 you still need the GUI - macOS
# does not let `security export` dump private keys non-interactively.
```

## Generating the app-specific password

1. Sign in at <https://appleid.apple.com>
2. Sign-In and Security → App-Specific Passwords → +
3. Label it `PureMac CI Notarytool`
4. Copy the `xxxx-xxxx-xxxx-xxxx` string — set as `APPLE_APP_PASSWORD`

Verify locally first to avoid burning a CI minute on auth failure:

```bash
xcrun notarytool store-credentials puremac-ci \
  --apple-id "$APPLE_ID" \
  --team-id  "H3WXHVTP97" \
  --password "$APPLE_APP_PASSWORD"
```

## Setting them all via gh CLI

```bash
gh secret set BUILD_CERTIFICATE_BASE64 --repo momenbasel/PureMac < /tmp/cert.b64
gh secret set P12_PASSWORD             --repo momenbasel/PureMac --body "$P12_PASSWORD"
gh secret set KEYCHAIN_PASSWORD        --repo momenbasel/PureMac --body "$(openssl rand -base64 32)"
gh secret set APPLE_ID                 --repo momenbasel/PureMac --body "$APPLE_ID"
gh secret set APPLE_APP_PASSWORD       --repo momenbasel/PureMac --body "$APPLE_APP_PASSWORD"
gh secret set HOMEBREW_TAP_TOKEN       --repo momenbasel/PureMac --body "$HOMEBREW_TAP_TOKEN"

# Verify:
gh secret list --repo momenbasel/PureMac
```

## Triggering a release

After tag bump:

```bash
git tag v2.2.0
git push origin v2.2.0
```

Or via dispatch (no tag):

```bash
gh workflow run release.yml --repo momenbasel/PureMac -f version=2.2.0 -f dry_run=false
```

Use `dry_run=true` first to validate signing+notarize without uploading the
release or bumping homebrew.

## What ships

| Artifact | Purpose |
|----------|---------|
| `PureMac-X.Y.Z.dmg` | Direct download link in release notes (signed + notarized + stapled) |
| `PureMac-X.Y.Z.zip` | Source for the homebrew cask (notarized + stapled `.app` inside) |

Both checksums land in `build/CHECKSUMS.md` and the GH release body.

## Troubleshooting #86 (`code or signature have been modified`)

Root causes that the pipeline guards against, that the previous manual
release path did not:

- Files modified after `codesign` (e.g. running `xcodegen` post-sign breaks the
  signature). The pipeline runs `xcodegen` before `archive` and never edits the
  bundle after the export step.
- Notarizing the `.app` but shipping a `.zip` made before the staple. The
  pipeline staples the `.app` first, then re-zips it. Order matters — Gatekeeper
  on first launch checks the stapled ticket on the `.app`, not the zip.
- Using `Apple Development` cert (default in `project.yml`) for distribution —
  the pipeline overrides with `Developer ID Application` at archive time.
- Skipping `--options=runtime` (no hardened runtime → notary rejects). Pipeline
  passes it via `OTHER_CODE_SIGN_FLAGS`.
- Universal-binary signing race where `lipo` is run after sign. The archive
  step builds universal in one pass via `ARCHS="arm64 x86_64"` so the codesign
  covers both slices atomically.
