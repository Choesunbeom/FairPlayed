#!/usr/bin/env python3
"""Apply the BitChord 1.0.2 dual-volume UI change without changing audio mixing.

The original full-screen slider is system volume. Long-pressing (0.42s)
switches the ongoing gesture to the independent native-engine gain.
The white progress is system volume; orange is the BitChord gain.
"""
from pathlib import Path
import shutil
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: patch.py /path/to/BitChord-source")

root = Path(sys.argv[1]).expanduser().resolve()
here = Path(__file__).resolve().parent


def replace_once(path: Path, old: str, new: str) -> None:
    contents = path.read_text(encoding="utf-8")
    count = contents.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one match in {path}, found {count}")
    path.write_text(contents.replace(old, new), encoding="utf-8")


swift_target = root / "AppleApp/Sources/UI/NowPlaying/DualVolumeControl.swift"
swift_target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(here / "DualVolumeControl.swift", swift_target)

transport = root / "AppleApp/Sources/UI/NowPlaying/NowPlayingView+Transport.swift"
text = transport.read_text(encoding="utf-8")
start_marker = "    /// The iOS volume row:"
end_marker = "    /// Music's order:"
if text.count(start_marker) != 1 or text.count(end_marker) != 1:
    raise RuntimeError("Unsupported BitChord transport layout; refusing to patch")
start = text.index(start_marker)
end = text.index(end_marker, start)
new_control = """    /// White = system output volume. Orange = BitChord-only output gain.
    /// Ordinary drag updates system volume; long-press then drag updates the
    /// existing controller.volume gain with haptic confirmation.
    /// No audio-session / mixWithOthers settings are modified.
    #if os(iOS)
    var deckVolumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16, height: 16)
                .playerGlyph()

            DualVolumeControl(appVolume: Binding(
                get: { controller.volume },
                set: { controller.volume = $0 }
            ))
            .frame(height: 28)

            Image(systemName: "speaker.wave.3.fill")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16, height: 16)
                .playerGlyph()
        }
    }
    #endif

"""
transport.write_text(text[:start] + new_control + text[end:], encoding="utf-8")

playback = root / "AppleApp/Sources/PlaybackSession/PlaybackController.swift"
replace_once(
    playback,
    """    var volume: Double = 0.9 {
        didSet { applyOutputGain() }
    }""",
    """    // This is APP gain, not iOS output volume. Persist separately.
    var volume: Double = {
        let saved = UserDefaults.standard.object(forKey: "bitchord_local_volume") as? Double ?? 0.9
        return min(max(saved, 0), 1)
    }() {
        didSet {
            UserDefaults.standard.set(volume, forKey: "bitchord_local_volume")
            applyOutputGain()
        }
    }""",
)

# Match the user's existing sideloaded BitChord bundle (build 40).
# Signing remains the user's responsibility; our unsigned build is #41.
project = root / "AppleApp/project.yml"
replace_once(project, 'CURRENT_PROJECT_VERSION: "6"', 'CURRENT_PROJECT_VERSION: "41"')
replace_once(
    project,
    'PRODUCT_BUNDLE_IDENTIFIER: app.bitchord.BitChord\n',
    'PRODUCT_BUNDLE_IDENTIFIER: com.music.bitchord\n',
)
replace_once(
    project,
    'PRODUCT_BUNDLE_IDENTIFIER: app.bitchord.BitChord.widget\n',
    'PRODUCT_BUNDLE_IDENTIFIER: com.music.bitchord.widget\n',
)

assert swift_target.exists()
assert "DualVolumeControl(appVolume:" in transport.read_text(encoding="utf-8")
assert "mix_with_other_audio" in playback.read_text(encoding="utf-8")
print("Patched BitChord 1.0.2: white system / orange local / long-hold haptic; mixing intact")
