# DuoSoloSettings — independent iPhone Duo YouTube tweak

Built from MIT-licensed YTKACE DuoDeskPlayer, DuoStatusBar, DuoKit and
standalone settings hooks.

## Two switches under YouTube Settings → Tweaks → iPhone Duo

- Notebook layout + real-time blurred reflection: `YTKACE.Preference.Player.DuoDeskSplit`
- Hide video-overlapping status items: `YTKACE.Preference.Player.DuoStatusBarHidden`

Both default to on. Turning the first switch off also disables the reflection.
No YTKACE runtime is required; only the selected Duo modules are compiled.

Run `bash duosolo/build.sh` on macOS with Xcode for an arm64 iOS 17+ dylib.
The GitHub Action builds the same output. The result is unsigned; inject and
re-sign your own legally obtained YouTube IPA to install.

**Compatibility:** Uses private, undocumented iOS folding and portal APIs
and YouTube view classes, so actual iPhone Duo behavior must be tested.

License: MIT (see duosolo/LICENSE, original YTKACE contributors).
