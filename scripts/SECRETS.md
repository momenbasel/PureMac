# Release pipeline secrets

`.github/workflows/release.yml` requires the following GitHub Actions secrets
on `momenbasel/PureMac`. All must be set before the next tag push or the
notarize/staple steps will fail and ship a broken signature (the cause of #86).

The pipeline uses an **App Store Connect API key** for notarization (modern,
no rotation, scoped to one team) instead of the legacy
`APPLE_ID + app-specific-password` flow.

## Required secrets (7)

| Secret | Source | Notes |
|--------|--------|-------|
| `BUILD_CERTIFICATE_BASE64` | Filtered Developer ID Application `.p12` (cert + matching private key only), base64 | `base64 -i cert.p12 \| pbcopy` |
| `P12_PASSWORD` | Password set when exporting the `.p12` | Random — only you and CI need it |
| `KEYCHAIN_PASSWORD` | Random string | Only used to lock the runner's temp keychain — never leaves CI |
| `APP_STORE_CONNECT_KEY_ID` | The 10-char ID from the `.p8` filename (`AuthKey_XXXXXXXXXX.p8`) | e.g. `5G7R52L8RK` |
| `APP_STORE_CONNECT_ISSUER_ID` | UUID from <https://appstoreconnect.apple.com/access/integrations/api> | e.g. `5de3898a-cd31-4061-850f-ae17b389e46a` |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Full contents of the `.p8` file (`-----BEGIN PRIVATE KEY-----` ... `-----END PRIVATE KEY-----`) | Paste raw, including the BEGIN/END lines |
| `SPARKLE_ED25519_PRIVATE_KEY` | The private Ed25519 key exported from Sparkle's `generate_keys -x` flow | Used by `generate_appcast` to sign `appcast.xml` |

## Optional secret (1)

| Secret | Source | Notes |
|--------|--------|-------|
| `HOMEBREW_TAP_TOKEN` | Fine-grained PAT with `Contents: read+write` on `momenbasel/homebrew-tap` | Without this the tap formula bump step is skipped (in-repo `homebrew/puremac.rb` still bumps via the default `GITHUB_TOKEN`) |

## Extracting your Developer ID cert as a filtered `.p12`

```bash
mkdir -p ~/Desktop/PureMac-secrets && cd ~/Desktop/PureMac-secrets

# 1. Export everything from login keychain
P12_PWD=$(openssl rand -base64 24)
echo "$P12_PWD" > P12_PASSWORD.txt
security export -k login.keychain-db -t identities -f pkcs12 -P "$P12_PWD" -o all.p12

# 2. Dump to PEM, isolate the Developer ID cert + matching private key
openssl pkcs12 -in all.p12 -passin "pass:$P12_PWD" -nodes -out all.pem
security find-certificate -c "Developer ID Application: Moamen Basel" -p login.keychain-db > devid.crt

# 3. Use python to split private keys, then match by modulus
python3 - <<'PY'
import re
content = open("all.pem").read()
for i, k in enumerate(re.findall(r"-----BEGIN PRIVATE KEY-----.*?-----END PRIVATE KEY-----", content, re.DOTALL), 1):
    open(f"key_{i}.pem", "w").write(k + "\n")
PY

CERT_MOD=$(openssl x509 -in devid.crt -modulus -noout | shasum -a 256 | awk '{print $1}')
for k in key_*.pem; do
  if [[ "$(openssl rsa -in "$k" -modulus -noout 2>/dev/null | shasum -a 256 | awk '{print $1}')" == "$CERT_MOD" ]]; then
    cp "$k" devid.key && break
  fi
done

# 4. Re-pack as a clean p12 with ONLY Developer ID + key
openssl pkcs12 -export \
  -in devid.crt -inkey devid.key \
  -name "Developer ID Application: Moamen Basel (H3WXHVTP97)" \
  -out PureMac-DeveloperID.p12 \
  -passout "pass:$P12_PWD" \
  -macalg sha256 -keypbe AES-256-CBC -certpbe AES-256-CBC

# 5. Base64 for the GH secret + scrub intermediates
base64 -i PureMac-DeveloperID.p12 -o PureMac-DeveloperID.p12.b64
rm -P all.p12 all.pem devid.key key_*.pem
```

## Storing the ASC API key locally for `notarytool`

Already set up — confirmed via `xcrun notarytool history --keychain-profile AC_NOTARY`.
For reference:

```bash
xcrun notarytool store-credentials AC_NOTARY \
  --key ~/.appstoreconnect/private_keys/AuthKey_5G7R52L8RK.p8 \
  --key-id 5G7R52L8RK \
  --issuer 5de3898a-cd31-4061-850f-ae17b389e46a
```

That keychain profile is consumed by `scripts/release-local.sh` for emergency
hotfixes. The CI workflow uses raw secrets instead (no keychain dependency on
the runner).

## Setting them all via gh CLI

```bash
# Fill in the 4 you control:
P12_PWD=$(cat ~/Desktop/PureMac-secrets/P12_PASSWORD.txt)
KC_PWD=$(cat ~/Desktop/PureMac-secrets/KEYCHAIN_PASSWORD.txt)

gh secret set BUILD_CERTIFICATE_BASE64       --repo momenbasel/PureMac < ~/Desktop/PureMac-secrets/PureMac-DeveloperID.p12.b64
gh secret set P12_PASSWORD                   --repo momenbasel/PureMac --body "$P12_PWD"
gh secret set KEYCHAIN_PASSWORD              --repo momenbasel/PureMac --body "$KC_PWD"
gh secret set APP_STORE_CONNECT_KEY_ID       --repo momenbasel/PureMac --body "5G7R52L8RK"
gh secret set APP_STORE_CONNECT_ISSUER_ID    --repo momenbasel/PureMac --body "5de3898a-cd31-4061-850f-ae17b389e46a"
gh secret set APP_STORE_CONNECT_PRIVATE_KEY  --repo momenbasel/PureMac < ~/.appstoreconnect/private_keys/AuthKey_5G7R52L8RK.p8

# Optional:
gh secret set HOMEBREW_TAP_TOKEN             --repo momenbasel/PureMac --body "<your fine-grained PAT>"

# Verify:
gh secret list --repo momenbasel/PureMac
```

After upload:

```bash
rm -P ~/Desktop/PureMac-secrets/PureMac-DeveloperID.p12* \
      ~/Desktop/PureMac-secrets/P12_PASSWORD.txt \
      ~/Desktop/PureMac-secrets/KEYCHAIN_PASSWORD.txt
```

## Storing the Sparkle Ed25519 key locally

Generate the public/private pair once with Sparkle's `generate_keys` tool. The
public key goes into `PureMac/Info.plist` as `SUPublicEDKey`. The private key
should be exported from the same keychain account and stored in GitHub Actions
as `SPARKLE_ED25519_PRIVATE_KEY`.

Example flow:

```bash
./bin/generate_keys --account puremac
./bin/generate_keys --account puremac -x puremac-ed25519.key
cat puremac-ed25519.key
```

Use the exported file contents as the secret value. The release workflow pipes
that value into `generate_appcast --ed-key-file -` when building `appcast.xml`.

## Triggering a release

Dry run first (build + sign + notarize, no upload, no homebrew bump):

```bash
gh workflow run release.yml --repo momenbasel/PureMac -f version=2.2.0 -f dry_run=true
gh run watch --repo momenbasel/PureMac
```

Real release (after dry run is green):

```bash
git tag v2.2.0
git push origin v2.2.0
```

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
