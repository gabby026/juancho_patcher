# Juancho Patcher

Juancho is a custom patch-package format and iOS patch manager designed for devices where the app already has filesystem privileges.

## Package flow

Windows builder creates:

`ProjectName.juancho`

The package contains a versioned header, a compressed manifest/archive payload, and optional AES-GCM encryption using a PBKDF2-HMAC-SHA256 derived key.

The iOS app can now load a package in three ways:

1. upload a `.juancho` file through the Files picker;
2. select a stored `.juancho` package;
3. enter an absolute path to a `.juancho` file, or to a folder containing exactly one `.juancho` file.

With **Load & Patch**, the app:

1. locates the `.juancho` package;
2. validates the package header;
3. asks for the password when the package is protected;
4. decompresses/decrypts the package payload in memory;
5. validates the manifest, paths, file sizes, and SHA-256 values;
6. resolves the target application by bundle identifier;
7. backs up every existing destination file;
8. writes replacement files atomically;
9. verifies the installed SHA-256 values;
10. rolls back the current operation if verification fails.

**Unpatch / Restore** uses the persistent patch record and reverses the operation: it restores each backed-up file or removes files that were newly added by the patch. It also refuses to overwrite/remove a patched file that has been modified since installation.

The package payload is not extracted blindly into the target application. The app decodes it into memory and only writes files after validation.

## Security

Password-protected packages use the existing Juancho AES-GCM/PBKDF2 implementation. The package must contain valid crypto metadata, and an incorrect password causes authentication failure before the payload is accepted.

## iOS target

Deployment target: iOS 16.0.

The app does not contain or rely on a sandbox escape. Direct access to another application's container only works when the runtime/device already grants the necessary filesystem privileges.

## Build

Open `iOS/Juancho/Juancho.xcodeproj` in Xcode.

For an unsigned CI build, run the GitHub Actions workflow **Build Juancho unsigned IPA**. The workflow packages the generated `Juancho.app` as an IPA artifact.

## Package format

The custom extension is `.juancho`. A separate `.manifest.json` is only a human-readable export from the Windows builder; the iOS app reads the manifest embedded in the package payload.

**Important:** a raw 7-Zip archive that was merely renamed to `.juancho` is not the same as a Juancho package. The Windows builder should emit the JUANCHO1 package format used by `JuanchoPackageCodec`.
