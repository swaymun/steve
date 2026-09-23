# Automatic updates

Steve uses [Sparkle 2](https://sparkle-project.org/) for authenticated macOS updates. Release builds check the HTTPS appcast at `updates/appcast.xml`, verify its signature, verify the downloaded archive before extraction, and install updates automatically only after Steve has paused and drained active work. Anonymous system profiling is disabled.

The Ed25519 private key stays in the release Mac's login Keychain under Sparkle's default `ed25519` account. The repository contains only the public key in `updates/sparkle-config.plist`. Never export or commit the private key.

## Release flow

1. Commit and validate the release source with an incremented `CFBundleVersion`.
2. Run `scripts/release-macos.sh` with the existing Developer ID identity and `steve-notary` profile. The script embeds Sparkle.framework with its symlinks intact, signs each nested helper, signs and notarizes Steve, staples the app, recreates the final ZIP and checksum, then runs Sparkle's `generate_appcast` against that exact ZIP.
3. Review and commit the resulting `updates/appcast.xml`. Do not alter it after generation because the feed itself is signed.
4. Require exact-head CI, tag that commit, and upload the unchanged `artifacts/Steve-macOS.zip` and checksum to the matching GitHub release URL encoded in the appcast.
5. Verify the public feed and archive anonymously. Before calling automatic updates accepted, exercise an older signed candidate updating to the newer signed candidate without interrupting active work.

The release script fails when the Keychain signing key, generated feed signature, archive signature, or exact GitHub release URL is missing. Developer source builds embed Sparkle so the binary can load, but omit the release feed and do not start automatic updates.
