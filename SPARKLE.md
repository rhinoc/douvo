# Sparkle Auto-Update

Douvo uses Sparkle 2 for macOS app updates. The app reads these values from
`Sources/Douvo/Info.plist`, which is embedded into the SwiftPM executable and
copied into the release `.app` bundle:

- `SUFeedURL`
- `SUPublicEDKey`
- `CFBundleShortVersionString`
- `CFBundleVersion`

The release workflow updates `appcast.xml` after each successful DMG build.
`scripts/update_appcast.sh` defaults to Sparkle `2.9.3`, matching the current
SwiftPM-resolved Sparkle version in `Package.resolved`.

## Release Flow

Releases are created from pushes to `main`, following the same pattern as Lofii:

1. GitHub Actions rewrites `SUFeedURL` to the current repository's raw
   `appcast.xml` URL.
2. `scripts/update_version.sh` bumps the patch version in `VERSION` and
   `Sources/Douvo/Info.plist`.
3. `scripts/build-dmg.sh` builds `dist/douvo-<version>-macos.dmg`.
4. `scripts/update_appcast.sh` signs the DMG with Sparkle `sign_update` and
   appends a new item to `appcast.xml`.
5. The workflow uploads the DMG to GitHub Releases as `v<version>`.
6. If `HOMEBREW_TAP_GITHUB_TOKEN` is configured, the workflow updates
   `Casks/douvo.rb` in the Homebrew tap repository using the same DMG URL and
   SHA-256 checksum.
7. `scripts/commit_release.sh` commits `VERSION`, `Info.plist`, and
   `appcast.xml` with `chore: auto release <version>`.

The release workflow skips `chore` commits to avoid a release loop.

## Sparkle Keys

Douvo uses a dedicated Sparkle EdDSA account named `douvo`.

The public key is committed in `Sources/Douvo/Info.plist` as `SUPublicEDKey`.
The private key must stay out of git and is stored in GitHub Actions as:

```text
SPARKLE_ED_PRIVATE_KEY
```

To generate or inspect the key with Sparkle's tools:

```bash
generate_keys --account douvo
generate_keys --account douvo -p
generate_keys --account douvo -x ~/Desktop/douvo_sparkle_private.txt
```

Set the GitHub secret from the exported private key:

```bash
gh secret set SPARKLE_ED_PRIVATE_KEY --repo rhinoc/douvo < ~/Desktop/douvo_sparkle_private.txt
```

Do not commit the exported private key.

## Homebrew Cask

Douvo's release workflow can publish the same GitHub Release DMG to a Homebrew
tap. By default it targets:

```text
rhinoc/homebrew-tap
```

Create that repository with a `Casks/` directory, then add a repository secret
to `rhinoc/douvo`:

```text
HOMEBREW_TAP_GITHUB_TOKEN
```

The token must be able to push to the tap repository. If the tap lives somewhere
else, set this repository variable:

```text
HOMEBREW_TAP_REPOSITORY=owner/homebrew-tap
```

When the secret is missing, the release workflow leaves the Homebrew step
disabled and continues publishing the GitHub Release and Sparkle appcast.

## Signing and Gatekeeper

Current release builds use ad-hoc signing by default and are not notarized.
That is enough to validate the DMG, GitHub Release, and Sparkle appcast flow,
but browser downloads may still trigger Gatekeeper quarantine. To use a real
signing identity, set `CODESIGN_IDENTITY`; if the identity lives in a custom
keychain, also set `CODESIGN_KEYCHAIN`.

After installing from the DMG, users can clear quarantine with:

```bash
xattr -dr com.apple.quarantine /Applications/Douvo.app
```

Before making the repository public, prefer switching release signing to a
Developer ID Application certificate and adding Apple notarization.
