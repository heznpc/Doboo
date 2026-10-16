import copy
from datetime import datetime, timedelta, timezone
import io
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import build_device as build


NOW = datetime(2026, 10, 16, tzinfo=timezone.utc)
PHONE = "AAAAAAAA-1111111111111111"
WATCH = "BBBBBBBB-2222222222222222"
TEAM = "TEAMTEST01"
TARGETS = {
    "iphoneos": build.Target("Companion", "iphoneos", "example.doboo", "Companion", TEAM, "0.2.0", "2"),
    "watchos": build.Target("Doboo", "watchos", "example.doboo.watch", "Doboo", TEAM, "0.2.0", "2"),
}


def profile(watch=True, wildcard=False):
    identifier = "22222222-2222-4222-8222-222222222222" if watch else "11111111-1111-4111-8111-111111111111"
    target = TARGETS["watchos" if watch else "iphoneos"]
    data = {
        "UUID": identifier, "Name": "Fixture development profile", "Platform": ["iOS"],
        "TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": [TEAM],
        "CreationDate": (NOW - timedelta(days=1)).replace(tzinfo=None),
        "ExpirationDate": (NOW + timedelta(days=30)).replace(tzinfo=None),
        "ProvisionedDevices": [WATCH, PHONE] if watch else [PHONE],
        "DeveloperCertificates": [b"fixture public certificate"],
        "Entitlements": {"application-identifier": f"{TEAM}.{'*' if wildcard else target.bundle_id}",
                         "com.apple.developer.team-identifier": TEAM, "get-task-allow": True},
    }
    return build.Profile(Path(identifier + ".mobileprovision"), data)


class ProfileSelectionTests(unittest.TestCase):
    def test_selects_phone_and_watch_profiles_for_their_requested_devices(self):
        wrong_watch = profile(watch=False, wildcard=True)
        correct_watch = profile()
        candidates = [wrong_watch, correct_watch]
        self.assertEqual(build.select_profile(candidates, TARGETS["iphoneos"], PHONE, NOW), wrong_watch)
        self.assertEqual(build.select_profile(candidates, TARGETS["watchos"], WATCH, NOW), correct_watch)
        self.assertEqual(build.profile_rejection(wrong_watch, TARGETS["watchos"], WATCH, NOW), "requested device is absent")
        with self.assertRaisesRegex(build.BuildError, "requested device is absent"):
            build.select_profile([wrong_watch], TARGETS["watchos"], WATCH, NOW)

    def test_rejects_expired_future_distribution_wrong_team_and_wrong_app_profiles(self):
        changes = [
            lambda data: data.update(ExpirationDate=NOW.replace(tzinfo=None)),
            lambda data: data.update(CreationDate=(NOW + timedelta(days=1)).replace(tzinfo=None)),
            lambda data: data["Entitlements"].update({"get-task-allow": False}),
            lambda data: data.update(TeamIdentifier=["OTHERTEAM1"]),
            lambda data: data["Entitlements"].update({"application-identifier": f"{TEAM}.example.other"}),
            lambda data: data.update(Platform=["OSX"]),
        ]
        for change in changes:
            with self.subTest(change=change):
                candidate = profile()
                change(candidate.data)
                self.assertIsNotNone(build.profile_rejection(candidate, TARGETS["watchos"], WATCH, NOW))
                with self.assertRaises(build.BuildError):
                    build.select_profile([candidate], TARGETS["watchos"], WATCH, NOW)

    def test_exact_profile_is_preferred_and_wildcard_is_bounded(self):
        exact, wildcard = profile(), profile(wildcard=True)
        self.assertEqual(build.select_profile([wildcard, exact], TARGETS["watchos"], WATCH, NOW), exact)
        wildcard.data["Entitlements"]["application-identifier"] = f"{TEAM}.example.*"
        self.assertTrue(build.application_id_matches(wildcard, "example.doboo.watch"))
        self.assertFalse(build.application_id_matches(wildcard, "examples.doboo"))
        self.assertFalse(build.application_id_matches(wildcard, "example.doboo", "OTHERTEAM1.example.doboo"))

    def test_sdk_scoped_config_contains_only_profile_and_signing_metadata(self):
        profiles = {"iphoneos": profile(False, True), "watchos": profile()}
        config = build.signing_config(TARGETS, profiles)
        for sdk in TARGETS:
            self.assertIn(f"PROVISIONING_PROFILE_SPECIFIER[sdk={sdk}*] = {profiles[sdk].uuid}", config)
            self.assertIn(f"CODE_SIGN_STYLE[sdk={sdk}*] = Manual", config)
        self.assertNotIn(PHONE, config)
        self.assertNotIn(WATCH, config)
        self.assertNotIn("certificate", config)

    def test_target_identity_comes_from_release_project_settings(self):
        objects = {"project": {"buildConfigurationList": "base-list", "targets": ["phone", "watch"]},
                   "base-list": {"buildConfigurations": ["base-release"]},
                   "base-release": {"name": "Release", "buildSettings": {
                       "DEVELOPMENT_TEAM": TEAM, "MARKETING_VERSION": "0.2.0", "CURRENT_PROJECT_VERSION": "2"}}}
        for key, target in [("phone", TARGETS["iphoneos"]), ("watch", TARGETS["watchos"])]:
            objects[key] = {"name": target.name, "productType": "com.apple.product-type.application", "buildConfigurationList": key + "-list"}
            objects[key + "-list"] = {"buildConfigurations": [key + "-release"]}
            objects[key + "-release"] = {"name": "Release", "buildSettings": {
                "SDKROOT": target.sdk, "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": target.bundle_id}}
        self.assertEqual(build.project_targets({"rootObject": "project", "objects": objects}), TARGETS)


class ArtifactVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.parent = Path(self.directory.name) / "Companion.app"
        self.apps = {"iphoneos": self.parent, "watchos": self.parent / "Watch/Doboo.app"}
        self.profiles = {"iphoneos": profile(False, True), "watchos": profile()}
        self.entitlements = {}
        self.commands = []
        for sdk, app in self.apps.items():
            app.mkdir(parents=True)
            target = TARGETS[sdk]
            info = {"CFBundleIdentifier": target.bundle_id, "CFBundleVersion": "4", "CFBundleShortVersionString": target.version,
                    "CFBundleSupportedPlatforms": ["iPhoneOS" if sdk == "iphoneos" else "WatchOS"],
                    "UIDeviceFamily": [1, 2] if sdk == "iphoneos" else [4]}
            if sdk == "watchos":
                info.update(WKApplication=True, WKCompanionAppBundleIdentifier=TARGETS["iphoneos"].bundle_id)
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            (app / "embedded.mobileprovision").write_bytes(plistlib.dumps(self.profiles[sdk].data))
            self.entitlements[str(app)] = {"application-identifier": f"{TEAM}.{target.bundle_id}",
                                          "com.apple.developer.team-identifier": TEAM, "get-task-allow": True}
        mocked = patch.object(build, "run", self.fake_run)
        mocked.start()
        self.addCleanup(mocked.stop)

    def fake_run(self, command):
        self.commands.append(command)
        if command[0] == "security":
            return Path(command[-1]).read_bytes()
        if command[:2] == ["codesign", "--verify"]:
            return b""
        if command[0] == "codesign":
            return plistlib.dumps(self.entitlements[command[-1]])
        self.fail(f"Unexpected tool call: {command[0]}")

    def verify(self):
        return build.verify_artifacts(self.parent, TARGETS, self.profiles,
                                      {"iphoneos": PHONE, "watchos": WATCH}, "4", NOW)

    def edit_info(self, sdk, **values):
        path = self.apps[sdk] / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update(values)
        path.write_bytes(plistlib.dumps(info))

    def test_checks_both_signed_apps_and_expected_build_override(self):
        self.assertEqual(self.verify(), self.apps["watchos"])
        for app in self.apps.values():
            self.assertIn(["codesign", "--verify", "--deep", "--strict", str(app)], self.commands)
        self.assertEqual(TARGETS["iphoneos"].build_number, "2")

    def test_rejects_the_original_wrong_watch_profile_in_built_output(self):
        (self.apps["watchos"] / "embedded.mobileprovision").write_bytes(plistlib.dumps(profile(False, True).data))
        with self.assertRaisesRegex(build.BuildError, "selected provisioning profile"):
            self.verify()

    def test_rechecks_device_membership_even_if_profile_uuid_is_unchanged(self):
        data = copy.deepcopy(self.profiles["watchos"].data)
        data["ProvisionedDevices"] = [PHONE]
        (self.apps["watchos"] / "embedded.mobileprovision").write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(build.BuildError, "requested device is absent"):
            self.verify()

    def test_rejects_bundle_version_and_companion_mismatches(self):
        cases = [("CFBundleIdentifier", "example.wrong", "bundle ID"), ("CFBundleVersion", "3", "version"),
                 ("WKCompanionAppBundleIdentifier", "example.other", "companion association")]
        path = self.apps["watchos"] / "Info.plist"
        original = path.read_bytes()
        for key, value, message in cases:
            with self.subTest(key=key):
                path.write_bytes(original)
                self.edit_info("watchos", **{key: value})
                with self.assertRaisesRegex(build.BuildError, message):
                    self.verify()

    def test_rejects_missing_or_wrong_signed_application_identifier(self):
        for identifier in (None, f"{TEAM}.example.other"):
            with self.subTest(identifier=identifier):
                entitlements = self.entitlements[str(self.apps["watchos"])]
                entitlements.pop("application-identifier", None)
                if identifier:
                    entitlements["application-identifier"] = identifier
                with self.assertRaisesRegex(build.BuildError, "Signed entitlements"):
                    self.verify()

    def test_signature_verification_failure_stops_the_build(self):
        def fail_signature(command):
            if command[:2] == ["codesign", "--verify"]:
                raise build.BuildError("invalid signature fixture")
            return self.fake_run(command)
        with patch.object(build, "run", fail_signature), self.assertRaisesRegex(build.BuildError, "invalid signature"):
            self.verify()


class CommandLineTests(unittest.TestCase):
    def test_both_hardware_udids_are_required_before_any_tool_runs(self):
        for args in ([], ["--iphone-udid", PHONE], ["--watch-udid", WATCH]):
            with self.subTest(args=args), patch.object(build, "run") as command, patch("sys.stderr", new=io.StringIO()):
                with self.assertRaises(SystemExit):
                    build.main(args)
                command.assert_not_called()

    def test_build_uses_only_a_generic_destination_and_no_account_updates(self):
        profiles = {"iphoneos": profile(False, True), "watchos": profile()}
        with tempfile.TemporaryDirectory() as temporary:
            derived = Path(temporary) / "build"
            with (patch.object(build, "run", return_value=b"{}") as helper,
                  patch.object(build, "project_targets", return_value=TARGETS),
                  patch.object(build.Path, "home", return_value=Path(temporary)),
                  patch.object(build, "select_profile", side_effect=lambda _, target, *args: profiles[target.sdk]),
                  patch.object(build, "verify_artifacts", return_value=derived / "verified-watch.app") as verify,
                  patch.object(build.subprocess, "run", return_value=build.subprocess.CompletedProcess([], 0)) as execute,
                  patch("sys.stdout", new=io.StringIO())):
                self.assertEqual(build.main(["--iphone-udid", PHONE, "--watch-udid", WATCH,
                                             "--build-number", "4", "--derived-data", str(derived)]), 0)
                command = execute.call_args.args[0]
                self.assertEqual(command[0], "xcodebuild")
                self.assertEqual(command[command.index("-destination") + 1], "generic/platform=iOS")
                self.assertEqual(command[command.index("-configuration") + 1], "Release")
                self.assertIn("CURRENT_PROJECT_VERSION=4", command)
                for forbidden in ("-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", PHONE, WATCH):
                    self.assertNotIn(forbidden, command)
                self.assertEqual(execute.call_count, 1)
                self.assertEqual(helper.call_count, 1)
                self.assertEqual(helper.call_args.args[0][:5], ["plutil", "-convert", "json", "-o", "-"])
                self.assertEqual(verify.call_args.args[-1], "4")


if __name__ == "__main__":
    unittest.main()
