#!/usr/bin/env python3
"""Build and verify the paired device apps using existing local profiles only."""

import argparse
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid


class BuildError(Exception):
    pass


@dataclass(frozen=True)
class Target:
    name: str
    sdk: str
    bundle_id: str
    product_name: str
    team: str
    version: str
    build_number: str


@dataclass(frozen=True)
class Profile:
    path: Path
    data: dict

    @property
    def uuid(self):
        return str(uuid.UUID(self.data["UUID"]))


def run(command):
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode:
        raise BuildError(f"{command[0]} failed (exit {result.returncode}): "
                         f"{result.stderr.decode(errors='replace').strip()[-1200:]}")
    return result.stdout


def release_settings(objects, owner):
    configurations = objects[owner["buildConfigurationList"]]["buildConfigurations"]
    config = next((objects[key] for key in configurations if objects[key]["name"] == "Release"), None)
    if config is None or config.get("baseConfigurationReference"):
        raise BuildError("Release settings must be available directly in the Xcode project.")
    return config["buildSettings"]


def resolved(value, settings):
    value = str(value)
    for _ in range(10):
        updated = re.sub(r"\$\(([^)]+)\)|\$\{([^}]+)\}",
                         lambda match: str(settings.get(match[1] or match[2], match[0])), value)
        if updated == value:
            if "$" in value:
                raise BuildError(f"Unresolved project setting: {value}")
            return value
        value = updated
    raise BuildError("Cyclic project build settings.")


def project_targets(project_data):
    objects = project_data["objects"]
    project = objects[project_data["rootObject"]]
    base = release_settings(objects, project)
    targets = {}
    for key in project["targets"]:
        target = objects[key]
        if target.get("productType") != "com.apple.product-type.application":
            continue
        settings = {**base, **release_settings(objects, target), "TARGET_NAME": target["name"]}
        sdk = resolved(settings.get("SDKROOT", ""), settings)
        if sdk not in ("iphoneos", "watchos"):
            continue
        if sdk in targets:
            raise BuildError(f"Expected one application target for {sdk}.")
        values = [resolved(settings.get(name, ""), settings) for name in
                  ("PRODUCT_BUNDLE_IDENTIFIER", "PRODUCT_NAME", "DEVELOPMENT_TEAM", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION")]
        bundle_id, product_name, team, version, build_number = values
        if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id) or not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise BuildError(f"Invalid bundle ID or development team for {target['name']}.")
        if not product_name or Path(product_name).name != product_name or product_name in (".", "..") or not version or not build_number:
            raise BuildError(f"Invalid product name or version for {target['name']}.")
        targets[sdk] = Target(target["name"], sdk, bundle_id, product_name, team, version, build_number)
    if set(targets) != {"iphoneos", "watchos"}:
        raise BuildError("Expected one iPhone application and one Watch application target.")
    if targets["iphoneos"].team != targets["watchos"].team:
        raise BuildError("The companion and Watch targets must use the same development team.")
    return targets


def read_profile(path):
    try:
        data = plistlib.loads(run(["security", "cms", "-D", "-i", str(path)]))
        profile = Profile(path, data)
        profile.uuid
        return profile
    except (ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        raise BuildError(f"Invalid provisioning profile: {path.name}") from error


def as_utc(value):
    if not isinstance(value, datetime):
        return None
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def application_id_matches(profile, bundle_id, signed_id=None):
    pattern = profile.data.get("Entitlements", {}).get("application-identifier", "")
    prefix, separator, suffix = pattern.partition(".")
    if not separator or prefix not in profile.data.get("ApplicationIdentifierPrefix", []):
        return False
    expected = f"{prefix}.{bundle_id}"
    if signed_id is not None and signed_id != expected:
        return False
    return suffix == bundle_id or suffix == "*" or (
        suffix.endswith(".*") and "*" not in suffix[:-2] and bundle_id.startswith(suffix[:-1]))


def profile_rejection(profile, target, udid, now):
    data = profile.data
    entitlements = data.get("Entitlements", {})
    expiry, created = as_utc(data.get("ExpirationDate")), as_utc(data.get("CreationDate"))
    if expiry is None or expiry <= now:
        return "expired or missing expiration"
    if created is None or created > now:
        return "not yet valid or missing creation date"
    if entitlements.get("get-task-allow") is not True or data.get("ProvisionsAllDevices"):
        return "not a device development profile"
    platforms = {"iOS"} if target.sdk == "iphoneos" else {"iOS", "watchOS"}
    if not platforms.intersection(data.get("Platform", [])):
        return "profile platform mismatch"
    if not data.get("DeveloperCertificates"):
        return "missing development certificate"
    if target.team not in data.get("TeamIdentifier", []) or entitlements.get("com.apple.developer.team-identifier") != target.team:
        return "development team mismatch"
    if not application_id_matches(profile, target.bundle_id):
        return "application ID mismatch"
    if udid.upper() not in [value.upper() for value in data.get("ProvisionedDevices", []) if isinstance(value, str)]:
        return "requested device is absent"
    return None


def select_profile(profiles, target, udid, now):
    valid, reasons = [], Counter()
    for profile in profiles:
        reason = profile_rejection(profile, target, udid, now)
        if reason:
            reasons[reason] += 1
        else:
            valid.append(profile)
    if not valid:
        detail = "; ".join(f"{reason}: {count}" for reason, count in sorted(reasons.items())) or "no readable local profiles"
        raise BuildError(f"No valid development profile for {target.sdk} ({target.bundle_id}). {detail}. "
                         "Provide a local profile containing the requested hardware UDID; no account or device changes were attempted.")
    return max(valid, key=lambda profile: (
        "*" not in profile.data["Entitlements"]["application-identifier"],
        as_utc(profile.data["ExpirationDate"]), as_utc(profile.data["CreationDate"]), profile.uuid))


def signing_config(targets, profiles):
    lines = []
    for sdk in ("iphoneos", "watchos"):
        lines += [f"CODE_SIGN_STYLE[sdk={sdk}*] = Manual",
                  f"DEVELOPMENT_TEAM[sdk={sdk}*] = {targets[sdk].team}",
                  f"CODE_SIGN_IDENTITY[sdk={sdk}*] = Apple Development",
                  f"PROVISIONING_PROFILE_SPECIFIER[sdk={sdk}*] = {profiles[sdk].uuid}"]
    return "\n".join(lines) + "\n"


def verify_app(app, target, selected, udid, build_number, now):
    try:
        info = plistlib.loads((app / "Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise BuildError(f"Missing or invalid built app: {app}") from error
    expected_platform = "iPhoneOS" if target.sdk == "iphoneos" else "WatchOS"
    expected_family = 1 if target.sdk == "iphoneos" else 4
    if info.get("CFBundleIdentifier") != target.bundle_id:
        raise BuildError(f"Built bundle ID mismatch for {target.name}.")
    if info.get("CFBundleVersion") != (build_number or target.build_number) or info.get("CFBundleShortVersionString") != target.version:
        raise BuildError(f"Built version mismatch for {target.name}.")
    if expected_platform not in info.get("CFBundleSupportedPlatforms", []) or expected_family not in info.get("UIDeviceFamily", []):
        raise BuildError(f"Built platform/device family mismatch for {target.name}.")
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    actual = read_profile(app / "embedded.mobileprovision")
    if actual.uuid != selected.uuid:
        raise BuildError(f"The built {target.sdk} app did not use the selected provisioning profile.")
    reason = profile_rejection(actual, target, udid, now)
    if reason:
        raise BuildError(f"The built {target.sdk} provisioning profile is invalid: {reason}.")
    entitlements = plistlib.loads(run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)]))
    signed_id = entitlements.get("application-identifier")
    if (not isinstance(signed_id, str) or not application_id_matches(actual, target.bundle_id, signed_id)
            or entitlements.get("com.apple.developer.team-identifier") != target.team
            or entitlements.get("get-task-allow") is not True):
        raise BuildError(f"Signed entitlements mismatch for {target.name}.")
    return info


def verify_artifacts(parent, targets, profiles, udids, build_number=None, now=None):
    now = now or datetime.now(timezone.utc)
    phone, watch = targets["iphoneos"], targets["watchos"]
    phone_info = verify_app(parent, phone, profiles["iphoneos"], udids["iphoneos"], build_number, now)
    embedded = parent / "Watch" / f"{watch.product_name}.app"
    if sorted((parent / "Watch").glob("*.app")) != [embedded]:
        raise BuildError("The companion must embed exactly the expected Watch app.")
    watch_info = verify_app(embedded, watch, profiles["watchos"], udids["watchos"], build_number, now)
    if watch_info.get("WKCompanionAppBundleIdentifier") != phone.bundle_id or watch_info.get("WKApplication") is not True:
        raise BuildError("The embedded Watch app has an invalid companion association.")
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        if phone_info[key] != watch_info[key]:
            raise BuildError("The companion and embedded Watch app versions differ.")
    return embedded


def hardware_udid(value):
    if not re.fullmatch(r"(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})", value):
        raise argparse.ArgumentTypeError("Use a hardware UDID, not a CoreDevice UUID.")
    return value.upper()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog="Only local profiles and generic builds are used. This command never queries, installs, or launches on a device.")
    parser.add_argument("--iphone-udid", required=True, type=hardware_udid)
    parser.add_argument("--watch-udid", required=True, type=hardware_udid)
    parser.add_argument("--build-number", help="Override CURRENT_PROJECT_VERSION for both apps.")
    parser.add_argument("--derived-data", type=Path, help="Build output directory outside the repository; defaults to a new temporary directory.")
    args = parser.parse_args(argv)
    if args.build_number and not re.fullmatch(r"[1-9][0-9]*(?:\.[0-9]+){0,2}", args.build_number):
        parser.error("--build-number must be a positive numeric bundle version.")
    repo = Path(__file__).resolve().parent.parent
    projects = sorted(repo.glob("*.xcodeproj"))
    if len(projects) != 1:
        raise BuildError("Expected one Xcode project at the repository root.")
    project = projects[0]
    targets = project_targets(json.loads(run(["plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")])))
    directories = [Path.home() / "Library/MobileDevice/Provisioning Profiles",
                   Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]
    local_profiles = []
    for directory in directories:
        for path in sorted(directory.glob("*.mobileprovision")):
            try:
                local_profiles.append(read_profile(path))
            except BuildError:
                continue
    now = datetime.now(timezone.utc)
    udids = {"iphoneos": args.iphone_udid, "watchos": args.watch_udid}
    profiles = {sdk: select_profile(local_profiles, target, udids[sdk], now) for sdk, target in targets.items()}
    derived = (args.derived_data or Path(tempfile.mkdtemp(prefix="doboo-device-"))).expanduser().resolve()
    if derived == repo or repo in derived.parents:
        raise BuildError("Use a derived-data directory outside the repository; built apps contain device provisioning profiles.")
    with tempfile.TemporaryDirectory(prefix="doboo-device-signing-") as temporary:
        config = Path(temporary) / "signing.xcconfig"
        config.write_text(signing_config(targets, profiles))
        command = ["xcodebuild", "-project", str(project), "-scheme", targets["iphoneos"].name,
                   "-configuration", "Release", "-destination", "generic/platform=iOS",
                   "-derivedDataPath", str(derived), "-xcconfig", str(config),
                   "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "build"]
        if args.build_number:
            command.append(f"CURRENT_PROJECT_VERSION={args.build_number}")
        print("Building companion and Watch apps with verified local development profiles.", flush=True)
        result = subprocess.run(command, cwd=repo, stdin=subprocess.DEVNULL, check=False)
        if result.returncode:
            raise BuildError(f"Generic device build failed (exit {result.returncode}). No device operations were performed.")
        parent = derived / "Build/Products/Release-iphoneos" / f"{targets['iphoneos'].product_name}.app"
        embedded = verify_artifacts(parent, targets, profiles, udids, args.build_number)
    print(f"Verified companion: {parent}\nVerified embedded Watch app: {embedded}\nBuild only; device installation and launch were not performed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BuildError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"Device build stopped: {error}", file=sys.stderr)
        sys.exit(1)
