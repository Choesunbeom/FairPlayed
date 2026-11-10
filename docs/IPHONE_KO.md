# FairPlayed: iPhone-only use (experimental)

This fork preserves the original research code and adds an unsigned iOS IPA build workflow and an optional Python repackager.

**Important:** The original FairPlayed must have the encrypted target app inside its own installed application bundle. Importing an IPA *after* FairPlayed is installed does not satisfy this requirement. The repackager is designed to insert the target IPA **before sideload signing and installation**.

## 1. Build the base helper IPA in GitHub Actions

Open [Actions](../../actions/workflows/build-ios-ipa.yml) -> **Build FairPlayed unsigned iOS IPA** -> **Run workflow**. Once the build succeeds, download the artifact `FairPlayed-unsigned-IPA` and extract `FairPlayed-base-unsigned.ipa`.

This is an **unsigned build**. Do not install it yet if you want to embed a target app.

## 2. Repackage on your iPhone

With a Python 3 environment on the iPhone, place these three files in one accessible folder:

- `FairPlayed-base-unsigned.ipa` from GitHub Actions
- `target.ipa` downloaded legally with your own App Store license (for example via iPadn)
- `tools/repack_for_iphone.py` from this fork

Run:

```sh
python3 repack_for_iphone.py FairPlayed-base-unsigned.ipa target.ipa -o FairPlayed-target-unsigned.ipa
```

The output contains `Payload/FairPlayed.app/EmbeddedPayload/<TargetApp>/`. It copies the app's original `SC_Info` and attempts the `SinfReplicationPaths` copying performed in the upstream embedding script. It does **not** decrypt or sign anything.

## 3. Sign with SideStore and test

Import `FairPlayed-target-unsigned.ipa` into your signing app and install it. Keep Developer Mode enabled and sign into the Apple ID that has a license for the target. Launch FairPlayed and try the embedded-payload export from its interface.

If successful, check the app's shared Documents/Decrypted folder for the output IPA. If it is labelled `PARTIAL`, do not expect LiveContainer to run it. Even a fully decrypted IPA may have separate LiveContainer compatibility problems.

## Limitations and safety

- **Not tested on iOS 27.2.1**; upstream reports success only on 27.0.1. No guaranteed decrypting result.
- An IPA signed by SideStore may be changed by the signing application; keep the embedded resource files unmodified when signing.
- One target app per installation. Changing targets requires repackaging and reinstalling.
- Never upload target IPAs, Apple credentials, authorization tokens or private certificates into public GitHub repositories or GitHub Actions.
- This method is for licensed apps and interoperability research. Observe applicable laws and licenses.
- The base IPA build is automated, but **on-iPhone Python and signing are separate manual steps**. It is not a universal drag-and-drop decryption application.

Upstream: https://github.com/morzelowski/FairPlayed
