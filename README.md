# Juancho Patcher

Juancho is a custom patch-package format and iOS patch manager for devices where the app already has the filesystem privileges required to access the target application.

## Final package flow

The Windows builder creates:

`ProjectName.juancho`

The iOS Juancho app consumes that exact JUANCHO1 format.

### Windows

Use **JuanchoBuilder.exe** to:

- choose the replacement source folder;
- enter the target Bundle ID;
- enter the target base path such as `assets`;
- optionally enter a password;
- create `ProjectName.juancho` on the Desktop;
- extract a `.juancho` package for verification.

A password enables AES-GCM encryption using PBKDF2-HMAC-SHA256. No password means the package is unencrypted.

### iOS

The iOS app can load a package by:

- Uploading a `.juancho` file;
- Selecting a previously uploaded package;
- Entering the absolute path to a `.juancho` file;
- Entering a folder path that contains exactly one `.juancho`.

Loading a package only validates the package header.

When **Patch** is pressed:

- if the package is unprotected, patching proceeds immediately;
- if the package is protected, Juancho asks for the password at that moment;
- the password is never needed for an unprotected package.

The package is decrypted and decompressed in memory. The payload, manifest, paths, file sizes, and SHA-256 values are validated before anything is written to the target application.

The patch operation then:

1. resolves the target application by Bundle ID;
2. backs up every existing destination file;
3. writes each replacement atomically;
4. verifies the resulting SHA-256;
5. rolls back the operation if a write or verification fails.

**Unpatch / Restore** performs the reverse operation. It verifies that patched files have not been unexpectedly modified, restores the saved backups, removes files that were originally absent, and clears the patch record.

## JUANCHO1 format

Package layout:

`JUANCHO1` magic
+ version byte
+ encryption flags
+ little-endian header length
+ UTF-8 JSON header
+ compressed payload

Payload layout:

little-endian manifest length
+ JSON manifest
+ `JNPAYL1` archive
+ archive file entries

The Windows builder and iOS decoder deliberately use the same format. A raw ZIP or raw 7-Zip archive renamed to `.juancho` is not a valid JUANCHO1 package.

## Security

Protected packages use:

- PBKDF2-HMAC-SHA256;
- a random salt;
- a random 96-bit AES-GCM nonce;
- AES-256-GCM;
- authenticated metadata using `JUANCHO1/v1/<projectName>`.

The iOS decoder authenticates the encrypted payload before accepting it.

## iOS target

Deployment target: iOS 16.0.

The app does not contain or rely on a sandbox escape. Direct access to another application's container only works when the runtime/device already grants the required filesystem privileges.

## Build

### iOS

Open `iOS/Juancho/Juancho.xcodeproj` in Xcode.

The repository includes the **Build Juancho unsigned IPA** GitHub Actions workflow.

### Windows

Open `Windows/JuanchoBuilder/JuanchoBuilder.csproj` with .NET 8.

The repository includes the **Build Juancho Windows Builder** GitHub Actions workflow and publishes a self-contained x64 executable.
