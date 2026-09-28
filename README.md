# Juancho Patcher

Juancho is a custom patch-package format and iOS patch manager designed for devices where the app already has filesystem privileges.

## Package flow

Windows builder creates:

`ProjectName.juancho`

The package contains a versioned header, a compressed manifest/archive payload, and optional AES-GCM encryption using a PBKDF2-HMAC-SHA256 derived key.

The iOS app:
1. imports the `.juancho` file;
2. asks for a password when required;
3. validates the manifest, archive paths, sizes, and SHA-256 values;
4. resolves the target application by bundle identifier;
5. backs up existing files;
6. writes replacements atomically;
7. verifies the installed hashes;
8. restores the backups on Unpatch.

## iOS target

Deployment target: iOS 16.0.

The app does not contain or rely on a sandbox escape. Direct access to another application's container only works when the runtime/device already grants the necessary filesystem privileges.

## Build

Open `iOS/Juancho/Juancho.xcodeproj` in Xcode.

For an unsigned CI build, run the GitHub Actions workflow **Build Juancho unsigned IPA**. The workflow packages the generated `Juancho.app` as an IPA artifact.

## Package format

The custom extension is `.juancho`. A separate `.manifest.json` is only a human-readable export from the Windows builder; the iOS app reads the manifest embedded in the package payload.
