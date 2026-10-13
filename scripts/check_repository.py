#!/usr/bin/env python3
"""Check committed source/resources without building or executing Doboo."""

import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def localization(path):
    text = path.read_text(encoding="utf-8")
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)
    require(pairs, f"No strings in {path.relative_to(ROOT)}")
    require(len(pairs) == len(dict(pairs)), f"Duplicate keys in {path.relative_to(ROOT)}")
    require(all(value.strip() for _, value in pairs), f"Empty translation in {path.relative_to(ROOT)}")
    return dict(pairs)


def main():
    project = (ROOT / "Doboo.xcodeproj/project.pbxproj").read_text()
    # Every source must be present in a source build phase, not just a navigator group.
    phases = re.findall(r'isa = PBXSourcesBuildPhase;(.*?)runOnlyForDeploymentPostprocessing', project, re.S)
    memberships = "\n".join(phases)
    source_files = list((ROOT / "Sources").rglob("*.swift")) + list((ROOT / "Tests").rglob("*.swift"))
    require(len({path.name for path in source_files}) == len(source_files), "Duplicate Swift basenames require a path-aware project check")
    for path in source_files:
        require(f"/* {path.name} in Sources */" in memberships,
                f"Regenerate Xcode project: missing source {path.relative_to(ROOT)}")

    for name in ("Assets.xcassets", "Localizable.strings", "PrivacyInfo.xcprivacy"):
        require(f"/* {name} in Resources */" in project, f"Missing resource build membership: {name}")
    require("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" in project, "App icon build setting missing")
    require("INFOPLIST_KEY_WKWatchOnly = YES;" in project, "Standalone Watch setting missing")

    translations = {
        language: localization(ROOT / f"Resources/{language}.lproj/Localizable.strings")
        for language in ("en", "ko")
    }
    require(translations["en"].keys() == translations["ko"].keys(), "English/Korean localization keys differ")
    # Product-facing keys have a stable dotted namespace; defaults keys use doboo's prefix.
    used_keys = set()
    for path in (ROOT / "Sources").rglob("*.swift"):
        used_keys.update(re.findall(r'"((?:app|about|welcome|accessibility|onboarding|settings|help|privacy|common|character)\.[A-Za-z0-9_.]+)"', path.read_text()))
    missing = used_keys - translations["en"].keys()
    require(not missing, f"Missing translations: {sorted(missing)}")

    manifest = plistlib.loads((ROOT / "Resources/PrivacyInfo.xcprivacy").read_bytes())
    require(manifest.get("NSPrivacyTracking") is False, "Tracking declaration changed")
    require(manifest.get("NSPrivacyCollectedDataTypes") == [], "Review collection declaration against app behavior")
    reasons = manifest.get("NSPrivacyAccessedAPITypes", [])
    require(any(item.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
                and "CA92.1" in item.get("NSPrivacyAccessedAPITypeReasons", []) for item in reasons),
            "UserDefaults preference storage must have a required-reason declaration")

    asset = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"
    catalog = json.loads((asset / "Contents.json").read_text())
    for entry in catalog["images"]:
        png = (asset / entry["filename"]).read_bytes()
        require(png[:8] == b"\x89PNG\r\n\x1a\n", "Icon is not PNG")
        width, height, depth, color = struct.unpack(">IIBB", png[16:26])
        require((width, height) == (1024, 1024), "Icon must be 1024 square")
        require(depth == 8 and color == 2, "Icon must be opaque RGB")
        offset = 8
        while offset + 12 <= len(png):
            length = struct.unpack(">I", png[offset:offset + 4])[0]
            kind = png[offset + 4:offset + 8]
            require(kind != b"tRNS", "Icon must not have transparent pixels")
            require(offset + length + 12 <= len(png), "Truncated PNG chunk")
            offset += length + 12
        require(entry.get("platform") == "watchos", "Icon platform must be watchOS")

    for path in (ROOT / "Doboo.xcodeproj").rglob("*.xcscheme"):
        ET.parse(path)
    ET.parse(ROOT / "Doboo.xcodeproj/project.xcworkspace/contents.xcworkspacedata")
    print(f"Repository consistency OK: {len(source_files)} Swift files, {len(translations['en'])} localized keys, resources and project references.")
    print("This does not compile, test, launch, or validate runtime behavior.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError) as error:
        print(f"Repository consistency failed: {error}", file=sys.stderr)
        sys.exit(1)
