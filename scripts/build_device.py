#!/usr/bin/env python3
"""Build and verify the paired apps and Watch widgets using existing local profiles only."""

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


APPLICATION = "com.apple.product-type.application"
APP_EXTENSION = "com.apple.product-type.app-extension"
APP_GROUPS = "com.apple.security.application-groups"
WATCH_APP_GROUP = "group.app.doboo.watch"


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
    product_type: str = APPLICATION
    app_groups: tuple[str, ...] = ()


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


def entitlement_groups(entitlements):
    groups = entitlements.get(APP_GROUPS, [])
    if not isinstance(groups, list) or any(not isinstance(group, str) or not group.startswith("group.") for group in groups):
        return None
    return set(groups)


def app_target(targets, sdk):
    matches = [target for target in targets.values() if target.sdk == sdk and target.product_type == APPLICATION]
    if len(matches) != 1:
        raise BuildError(f"Expected one application target for {sdk}.")
    return matches[0]


def watch_extensions(targets):
    return [target for target in targets.values() if target.product_type == APP_EXTENSION and target.sdk == "watchos"]


def project_targets(project_data, source_root=None):
    objects = project_data["objects"]
    project = objects[project_data["rootObject"]]
    base = release_settings(objects, project)
    targets = {}
    for key in project["targets"]:
        target = objects[key]
        product_type = target.get("productType")
        if product_type not in (APPLICATION, APP_EXTENSION):
            continue
        settings = {**base, **release_settings(objects, target), "TARGET_NAME": target["name"]}
        if source_root is not None:
            settings.update(SRCROOT=str(source_root), SOURCE_ROOT=str(source_root), PROJECT_DIR=str(source_root))
        sdk = resolved(settings.get("SDKROOT", ""), settings)
        if sdk not in ("iphoneos", "watchos"):
            continue
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", target["name"]) or target["name"] in targets:
            raise BuildError("Device target names must be unique xcconfig variable identifiers.")
        if product_type == APP_EXTENSION and sdk != "watchos":
            raise BuildError("Only Watch app extensions are supported by this device build.")
        values = [resolved(settings.get(name, ""), settings) for name in
                  ("PRODUCT_BUNDLE_IDENTIFIER", "PRODUCT_NAME", "DEVELOPMENT_TEAM", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION")]
        bundle_id, product_name, team, version, build_number = values
        if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id) or not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise BuildError(f"Invalid bundle ID or development team for {target['name']}.")
        if not product_name or Path(product_name).name != product_name or product_name in (".", "..") or not version or not build_number:
            raise BuildError(f"Invalid product name or version for {target['name']}.")
        groups = set()
        if settings.get("CODE_SIGN_ENTITLEMENTS"):
            if source_root is None:
                raise BuildError("The source root is required to inspect target entitlements.")
            entitlement_path = Path(source_root) / resolved(settings["CODE_SIGN_ENTITLEMENTS"], settings)
            try:
                groups = entitlement_groups(plistlib.loads(entitlement_path.read_bytes()))
            except (OSError, plistlib.InvalidFileException) as error:
                raise BuildError(f"Missing or invalid entitlements for {target['name']}.") from error
            if groups is None:
                raise BuildError(f"Invalid App Group entitlements for {target['name']}.")
        targets[target["name"]] = Target(target["name"], sdk, bundle_id, product_name, team, version,
                                         build_number, product_type, tuple(sorted(groups)))
    phone, watch = app_target(targets, "iphoneos"), app_target(targets, "watchos")
    extensions = watch_extensions(targets)
    if len(extensions) > 1:
        raise BuildError("Expected at most one Watch widget extension target.")
    if len({target.bundle_id for target in targets.values()}) != len(targets):
        raise BuildError("Device targets must use distinct bundle IDs.")
    if any(target.team != phone.team for target in targets.values()):
        raise BuildError("The companion, Watch app, and widgets must use the same development team.")
    if any(target.version != phone.version for target in targets.values()):
        raise BuildError("The companion, Watch app, and widgets must use matching marketing versions.")
    for extension in extensions:
        if not extension.bundle_id.startswith(watch.bundle_id + "."):
            raise BuildError("The Watch widget bundle ID must extend the Watch app bundle ID.")
        if any(WATCH_APP_GROUP not in target.app_groups for target in (watch, extension)):
            raise BuildError(f"The Watch app and widgets must both declare {WATCH_APP_GROUP}.")
    return targets


def validate_build_versions(targets, build_number=None):
    if len({build_number or target.build_number for target in targets.values()}) != 1:
        raise BuildError("The companion, Watch app, and widgets must use matching build numbers; "
                         "provide --build-number to override them together.")


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
    if data.get("IsXcodeManaged") is True:
        return "Xcode-managed profile cannot be used for manual signing"
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
    groups = entitlement_groups(entitlements)
    if groups is None or not set(target.app_groups).issubset(groups):
        return "required App Group is absent or invalid"
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
        raise BuildError(f"No valid development profile for {target.name} ({target.bundle_id}). {detail}. "
                         "Provide a local profile containing the requested hardware UDID and required entitlements; "
                         "no account or device changes were attempted.")
    return max(valid, key=lambda profile: (
        "*" not in profile.data["Entitlements"]["application-identifier"],
        as_utc(profile.data["ExpirationDate"]), as_utc(profile.data["CreationDate"]), profile.uuid))


def signing_config(targets, profiles):
    lines = []
    for sdk in ("iphoneos", "watchos"):
        lines += [f"CODE_SIGN_STYLE[sdk={sdk}*] = Manual",
                  f"DEVELOPMENT_TEAM[sdk={sdk}*] = {app_target(targets, sdk).team}",
                  f"CODE_SIGN_IDENTITY[sdk={sdk}*] = Apple Development",
                  f"PROVISIONING_PROFILE_SPECIFIER[sdk={sdk}*] = $(DOBOO_PROFILE_$(TARGET_NAME))"]
    lines += [f"DOBOO_PROFILE_{target.name} = {profiles[target.name].uuid}" for target in targets.values()]
    return "\n".join(lines) + "\n"


def verify_signing_settings(project, config, targets, profiles, build_number=None):
    for target in targets.values():
        command = ["xcodebuild", "-project", str(project), "-target", target.name, "-configuration", "Release",
                   "-sdk", target.sdk, "-xcconfig", str(config), "-disableAutomaticPackageResolution",
                   "-onlyUsePackageVersionsFromResolvedFile", "-showBuildSettings", "-json"]
        if build_number:
            command.append(f"CURRENT_PROJECT_VERSION={build_number}")
        rows = json.loads(run(command))
        settings = [row["buildSettings"] for row in rows if row.get("target") == target.name]
        if len(settings) != 1:
            raise BuildError(f"Cannot verify resolved signing settings for {target.name}.")
        expected = {"PROVISIONING_PROFILE_SPECIFIER": profiles[target.name].uuid,
                    "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "Apple Development",
                    "DEVELOPMENT_TEAM": target.team, "PLATFORM_NAME": target.sdk,
                    "PRODUCT_BUNDLE_IDENTIFIER": target.bundle_id, "PRODUCT_TYPE": target.product_type,
                    "FULL_PRODUCT_NAME": target.product_name + (".appex" if target.product_type == APP_EXTENSION else ".app"),
                    "MARKETING_VERSION": target.version, "CURRENT_PROJECT_VERSION": build_number or target.build_number}
        for key, value in expected.items():
            if settings[0].get(key) != value:
                raise BuildError(f"Resolved {key} mismatch for {target.name}; the build was not started.")


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
    if info.get("CFBundlePackageType") != ("XPC!" if target.product_type == APP_EXTENSION else "APPL"):
        raise BuildError(f"Built bundle package type mismatch for {target.name}.")
    if target.product_type == APP_EXTENSION and info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        raise BuildError(f"Built widget extension point mismatch for {target.name}.")
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    actual = read_profile(app / "embedded.mobileprovision")
    if actual.uuid != selected.uuid:
        raise BuildError(f"The built {target.name} bundle did not use the selected provisioning profile.")
    reason = profile_rejection(actual, target, udid, now)
    if reason:
        raise BuildError(f"The built {target.name} provisioning profile is invalid: {reason}.")
    entitlements = plistlib.loads(run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)]))
    signed_id = entitlements.get("application-identifier")
    if (not isinstance(signed_id, str) or not application_id_matches(actual, target.bundle_id, signed_id)
            or entitlements.get("com.apple.developer.team-identifier") != target.team
            or entitlements.get("get-task-allow") is not True):
        raise BuildError(f"Signed entitlements mismatch for {target.name}.")
    if entitlement_groups(entitlements) != set(target.app_groups):
        raise BuildError(f"Signed App Group entitlements mismatch for {target.name}.")
    return info


def verify_artifacts(parent, targets, profiles, udids, build_number=None, now=None):
    now = now or datetime.now(timezone.utc)
    phone, watch = app_target(targets, "iphoneos"), app_target(targets, "watchos")
    phone_info = verify_app(parent, phone, profiles[phone.name], udids["iphoneos"], build_number, now)
    embedded = parent / "Watch" / f"{watch.product_name}.app"
    if sorted((parent / "Watch").glob("*.app")) != [embedded]:
        raise BuildError("The companion must embed exactly the expected Watch app.")
    watch_info = verify_app(embedded, watch, profiles[watch.name], udids["watchos"], build_number, now)
    if watch_info.get("WKCompanionAppBundleIdentifier") != phone.bundle_id or watch_info.get("WKApplication") is not True:
        raise BuildError("The embedded Watch app has an invalid companion association.")
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        if phone_info[key] != watch_info[key]:
            raise BuildError("The companion and embedded Watch app versions differ.")
    extensions = watch_extensions(targets)
    expected_extensions = [embedded / "PlugIns" / f"{target.product_name}.appex" for target in extensions]
    if sorted((embedded / "PlugIns").glob("*.appex")) != sorted(expected_extensions):
        raise BuildError("The Watch app must embed exactly the expected widget extensions.")
    for extension, path in zip(extensions, expected_extensions):
        extension_info = verify_app(path, extension, profiles[extension.name], udids["watchos"], build_number, now)
        for key in ("CFBundleVersion", "CFBundleShortVersionString"):
            if extension_info[key] != watch_info[key]:
                raise BuildError("The Watch app and embedded widget versions differ.")
    return embedded


def hardware_udid(value):
    if not re.fullmatch(r"(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})", value):
        raise argparse.ArgumentTypeError("Use a hardware UDID, not a CoreDevice UUID.")
    return value.upper()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog="Only local profiles and generic builds are used. This command never queries, installs, or launches on a device.")
    parser.add_argument("--iphone-udid", required=True, type=hardware_udid)
    parser.add_argument("--watch-udid", required=True, type=hardware_udid)
    parser.add_argument("--build-number", help="Override CURRENT_PROJECT_VERSION for both apps and Watch widgets.")
    parser.add_argument("--derived-data", type=Path, help="Build output directory outside the repository; defaults to a new temporary directory.")
    args = parser.parse_args(argv)
    if args.build_number and not re.fullmatch(r"[1-9][0-9]*(?:\.[0-9]+){0,2}", args.build_number):
        parser.error("--build-number must be a positive numeric bundle version.")
    repo = Path(__file__).resolve().parent.parent
    projects = sorted(repo.glob("*.xcodeproj"))
    if len(projects) != 1:
        raise BuildError("Expected one Xcode project at the repository root.")
    project = projects[0]
    targets = project_targets(json.loads(run(["plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")])), repo)
    validate_build_versions(targets, args.build_number)
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
    profiles = {target.name: select_profile(local_profiles, target, udids[target.sdk], now) for target in targets.values()}
    derived = (args.derived_data or Path(tempfile.mkdtemp(prefix="doboo-device-"))).expanduser().resolve()
    if derived == repo or repo in derived.parents:
        raise BuildError("Use a derived-data directory outside the repository; built apps contain device provisioning profiles.")
    with tempfile.TemporaryDirectory(prefix="doboo-device-signing-") as temporary:
        config = Path(temporary) / "signing.xcconfig"
        config.write_text(signing_config(targets, profiles))
        verify_signing_settings(project, config, targets, profiles, args.build_number)
        phone = app_target(targets, "iphoneos")
        command = ["xcodebuild", "-project", str(project), "-scheme", phone.name,
                   "-configuration", "Release", "-destination", "generic/platform=iOS",
                   "-derivedDataPath", str(derived), "-xcconfig", str(config),
                   "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "build"]
        if args.build_number:
            command.append(f"CURRENT_PROJECT_VERSION={args.build_number}")
        print("Building companion, Watch app, and any Watch widgets with verified local development profiles.", flush=True)
        result = subprocess.run(command, cwd=repo, stdin=subprocess.DEVNULL, check=False)
        if result.returncode:
            raise BuildError(f"Generic device build failed (exit {result.returncode}). No device operations were performed.")
        parent = derived / "Build/Products/Release-iphoneos" / f"{phone.product_name}.app"
        embedded = verify_artifacts(parent, targets, profiles, udids, args.build_number)
    print(f"Verified companion: {parent}\nVerified embedded Watch app: {embedded}")
    for extension in watch_extensions(targets):
        print(f"Verified embedded Watch widget: {embedded / 'PlugIns' / (extension.product_name + '.appex')}")
    print("Build only; device installation and launch were not performed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BuildError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"Device build stopped: {error}", file=sys.stderr)
        sys.exit(1)
