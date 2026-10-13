# Releasing Brim

These steps are for the maintainer. Releases are built and signed on the
maintainer's Mac, and no certificate or password is stored on GitHub.

## 1. Build

Start from a clean commit on `main`, with Xcode 27 and an Apple Development
or Developer ID certificate in the keychain.

```bash
./scripts/build_release.sh
```

The script builds only committed files and records the source commit in the
app. It checks the app and helper signatures, then writes the disk image and
its SHA-256 checksum to `build/`.

## 2. Draft the release

Use the project's version in the tag and file names. For version 1.0:

```bash
git tag v1.0
git push origin v1.0
```

```bash
gh release create v1.0 build/Brim-1.0.dmg build/Brim-1.0.dmg.sha256 \
  --draft --verify-tag --title "Brim 1.0" --generate-notes
```

## 3. Publish

```bash
gh workflow run release.yml -f tag=v1.0
```

The workflow repeats the build, test and lint checks. It publishes the draft
only after verifying the checksum, the signatures, the helper layout, the
version and the source commit.

A build signed with a free Apple Development certificate is not notarised,
so people open it once through System Settings > Privacy & Security > Open
Anyway, as the README explains. A Developer ID build is notarised when
`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` and `APPLE_TEAM_ID` are set.
