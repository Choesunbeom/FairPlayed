#!/usr/bin/env python3
"""Package a licensed App Store IPA inside an unsigned FairPlayed helper IPA.

This repacks archives; it does not decrypt FairPlay or sign the output.
Re-sign the resulting IPA before installing it. Python 3 standard library only.
"""
import argparse
import os
import plistlib
import sys
import zipfile

HELPER = "Payload/FairPlayed.app/"
PAYLOAD = HELPER + "EmbeddedPayload/"

def safe_path(path):
    return bool(path) and not path.startswith("/") and "\\" not in path and "\x00" not in path and all(p not in ("", ".", "..") for p in path.rstrip("/").split("/"))

def app_root(archive):
    roots = {p.split("/")[1] for p in archive.namelist()
             if p.startswith("Payload/") and len(p.split("/")) > 2 and p.split("/")[1].endswith(".app")}
    if len(roots) != 1:
        raise ValueError("IPA must contain exactly one Payload/*.app: " + str(sorted(roots)))
    return next(iter(roots))

def copy_entry(source, item, target, name):
    info = source.getinfo(item)
    clone = zipfile.ZipInfo(name, info.date_time)
    clone.compress_type = zipfile.ZIP_STORED if item.endswith("/") else zipfile.ZIP_DEFLATED
    clone.external_attr = info.external_attr
    clone.create_system = info.create_system
    target.writestr(clone, source.read(item))

def repack(base_ipa, target_ipa, output):
    base_ipa, target_ipa, output = map(os.path.abspath, (base_ipa, target_ipa, output))
    if output in (base_ipa, target_ipa):
        raise ValueError("Output must differ from both input files")
    with zipfile.ZipFile(base_ipa) as base, zipfile.ZipFile(target_ipa) as target:
        if base.testzip() is not None or target.testzip() is not None:
            raise ValueError("Archive CRC check failed")
        if app_root(base) != "FairPlayed.app":
            raise ValueError("Base IPA must contain Payload/FairPlayed.app")
        name = app_root(target)
        prefix = "Payload/" + name + "/"
        label = name[:-4]
        mapping = {}
        for info in target.infolist():
            item = info.filename
            if not safe_path(item):
                raise ValueError("Unsafe target ZIP path: " + item)
            if not item.startswith(prefix):
                continue
            rel = item[len(prefix):]
            if not rel or rel.startswith("Watch/"):
                continue
            dest = PAYLOAD + label + "/" + rel
            if dest in mapping:
                raise ValueError("Duplicate destination: " + dest)
            mapping[dest] = item
        if not mapping:
            raise ValueError("Target app has no files")

        extra = {}
        manifest = PAYLOAD + label + "/SC_Info/Manifest.plist"
        if manifest in mapping:
            data = plistlib.loads(target.read(mapping[manifest]))
            sinfs = data.get("SinfPaths") or []
            copies = data.get("SinfReplicationPaths") or []
            if sinfs and copies:
                if not isinstance(sinfs[0], str) or not safe_path(sinfs[0]):
                    raise ValueError("Invalid SINF path")
                original = PAYLOAD + label + "/" + sinfs[0]
                if original not in mapping:
                    raise ValueError("Missing main SINF")
                license_data = target.read(mapping[original])
                for rel in copies:
                    if not isinstance(rel, str) or not safe_path(rel) or rel.startswith("Watch/"):
                        continue
                    dest = PAYLOAD + label + "/" + rel
                    if dest not in mapping:
                        extra[dest] = license_data

        os.makedirs(os.path.dirname(output), exist_ok=True)
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as out:
            for info in base.infolist():
                item = info.filename
                if not safe_path(item):
                    raise ValueError("Unsafe base ZIP path: " + item)
                if item.startswith(PAYLOAD) or item.startswith(HELPER + "_CodeSignature/") or item == HELPER + "embedded.mobileprovision":
                    continue
                copy_entry(base, item, out, item)
            for dest, item in mapping.items():
                copy_entry(target, item, out, dest)
            for dest, data in extra.items():
                out.writestr(dest, data)

    with zipfile.ZipFile(output) as check:
        if check.testzip() is not None or HELPER + "Info.plist" not in check.namelist():
            raise ValueError("Output verification failed")
    print("Created:", output)
    print("Embedded:", label, "| files:", len(mapping), "| replicated SINF:", len(extra))
    print("This IPA is unsigned. Decryption and iOS compatibility are NOT verified.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_ipa")
    parser.add_argument("target_ipa")
    parser.add_argument("-o", "--output", default="FairPlayed-target-unsigned.ipa")
    args = parser.parse_args()
    try:
        repack(args.base_ipa, args.target_ipa, args.output)
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException) as ex:
        print("ERROR:", ex, file=sys.stderr)
        sys.exit(1)
