import copy
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import io
import json
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
PHONE_TARGET = build.Target("Companion", "iphoneos", "example.doboo", "Companion", TEAM, "0.2.0", "2")
WATCH_TARGET = build.Target("Doboo", "watchos", "example.doboo.watch", "Doboo", TEAM, "0.2.0", "2")
WIDGET_TARGET = build.Target("DobooWidgets", "watchos", "example.doboo.watch.widgets", "DobooWidgets", TEAM,
                            "0.2.0", "2", build.APP_EXTENSION, (build.WATCH_APP_GROUP,))
TARGETS = {target.name: target for target in (PHONE_TARGET, WATCH_TARGET)}
WIDGET_TARGETS = {target.name: target for target in
                  (PHONE_TARGET, replace(WATCH_TARGET, app_groups=(build.WATCH_APP_GROUP,)), WIDGET_TARGET)}


def profile(target=WATCH_TARGET, wildcard=False):
    identifiers = {PHONE_TARGET.name: "11111111-1111-4111-8111-111111111111",
                   WATCH_TARGET.name: "22222222-2222-4222-8222-222222222222",
                   WIDGET_TARGET.name: "33333333-3333-4333-8333-333333333333"}
    identifier = identifiers[target.name]
    data = {
        "UUID": identifier, "Name": "Fixture development profile", "Platform": ["iOS"],
        "TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": [TEAM],
        "CreationDate": (NOW - timedelta(days=1)).replace(tzinfo=None),
        "ExpirationDate": (NOW + timedelta(days=30)).replace(tzinfo=None),
        "ProvisionedDevices": [WATCH, PHONE] if target.sdk == "watchos" else [PHONE],
        "DeveloperCertificates": [b"fixture public certificate"],
        "Entitlements": {"application-identifier": f"{TEAM}.{'*' if wildcard else target.bundle_id}",
                         "com.apple.developer.team-identifier": TEAM, "get-task-allow": True},
    }
    if target.app_groups:
        data["Entitlements"][build.APP_GROUPS] = list(target.app_groups)
    return build.Profile(Path(identifier + ".mobileprovision"), data)


def project_fixture(targets, root=None):
    objects = {"project": {"buildConfigurationList": "base-list", "targets": list(targets)},
               "base-list": {"buildConfigurations": ["base-release"]},
               "base-release": {"name": "Release", "buildSettings": {
                   "DEVELOPMENT_TEAM": TEAM, "MARKETING_VERSION": "0.2.0", "CURRENT_PROJECT_VERSION": "2"}}}
    for key, target in targets.items():
        objects[key] = {"name": target.name, "productType": target.product_type, "buildConfigurationList": key + "-list"}
        objects[key + "-list"] = {"buildConfigurations": [key + "-release"]}
        settings = {"SDKROOT": target.sdk, "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": target.bundle_id}
        if target.app_groups:
            settings["CODE_SIGN_ENTITLEMENTS"] = f"$(SRCROOT)/{target.name}.entitlements"
            (root / f"{target.name}.entitlements").write_bytes(plistlib.dumps({build.APP_GROUPS: list(target.app_groups)}))
        objects[key + "-release"] = {"name": "Release", "buildSettings": settings}
    return {"rootObject": "project", "objects": objects}


class ProfileSelectionTests(unittest.TestCase):
    def test_selects_phone_and_watch_profiles_for_their_requested_devices(self):
        wrong_watch, correct_watch = profile(PHONE_TARGET, wildcard=True), profile()
        candidates = [wrong_watch, correct_watch]
        self.assertEqual(build.select_profile(candidates, PHONE_TARGET, PHONE, NOW), wrong_watch)
        self.assertEqual(build.select_profile(candidates, WATCH_TARGET, WATCH, NOW), correct_watch)
        with self.assertRaisesRegex(build.BuildError, "requested device is absent"):
            build.select_profile([wrong_watch], WATCH_TARGET, WATCH, NOW)

    def test_rejects_expired_future_distribution_wrong_team_app_and_platform_profiles(self):
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
                with self.assertRaises(build.BuildError):
                    build.select_profile([candidate], WATCH_TARGET, WATCH, NOW)

    def test_exact_profile_is_preferred_and_wildcard_is_bounded(self):
        exact, wildcard = profile(), profile(wildcard=True)
        self.assertEqual(build.select_profile([wildcard, exact], WATCH_TARGET, WATCH, NOW), exact)
        wildcard.data["Entitlements"]["application-identifier"] = f"{TEAM}.example.*"
        self.assertTrue(build.application_id_matches(wildcard, "example.doboo.watch"))
        self.assertFalse(build.application_id_matches(wildcard, "examples.doboo"))
        self.assertFalse(build.application_id_matches(wildcard, "example.doboo", "OTHERTEAM1.example.doboo"))

    def test_watch_and_widget_select_distinct_profiles_with_the_group_and_watch_udid(self):
        profiles = {name: profile(target) for name, target in WIDGET_TARGETS.items()}
        for name, target in WIDGET_TARGETS.items():
            self.assertEqual(build.select_profile(list(profiles.values()), target,
                                                  PHONE if target.sdk == "iphoneos" else WATCH, NOW), profiles[name])
        profiles[WIDGET_TARGET.name].data["ProvisionedDevices"] = [PHONE]
        with self.assertRaisesRegex(build.BuildError, "requested device is absent"):
            build.select_profile([profiles[WIDGET_TARGET.name]], WIDGET_TARGET, WATCH, NOW)

    def test_profiles_without_the_required_group_fail_before_build(self):
        for target in (WIDGET_TARGETS[WATCH_TARGET.name], WIDGET_TARGET):
            for groups in (None, [], ["group.example.wrong"], "group.app.doboo.watch"):
                with self.subTest(target=target.name, groups=groups):
                    candidate = profile(target)
                    if groups is None:
                        candidate.data["Entitlements"].pop(build.APP_GROUPS)
                    else:
                        candidate.data["Entitlements"][build.APP_GROUPS] = groups
                    with self.assertRaisesRegex(build.BuildError, "required App Group"):
                        build.select_profile([candidate], target, WATCH, NOW)

    def test_xcode_managed_profiles_are_rejected_even_when_devices_and_entitlements_match(self):
        for target in WIDGET_TARGETS.values():
            with self.subTest(target=target.name):
                managed = profile(target)
                managed.data["IsXcodeManaged"] = True
                manual = profile(target)
                manual.data["IsXcodeManaged"] = False
                udid = PHONE if target.sdk == "iphoneos" else WATCH
                with self.assertRaisesRegex(build.BuildError, "Xcode-managed profile cannot be used for manual signing"):
                    build.select_profile([managed], target, udid, NOW)
                self.assertEqual(build.select_profile([managed, manual], target, udid, NOW), manual)

    def test_config_selects_by_target_name_within_each_sdk(self):
        for targets in (TARGETS, WIDGET_TARGETS):
            with self.subTest(count=len(targets)):
                profiles = {name: profile(target) for name, target in targets.items()}
                config = build.signing_config(targets, profiles)
                for sdk in ("iphoneos", "watchos"):
                    self.assertIn(f"PROVISIONING_PROFILE_SPECIFIER[sdk={sdk}*] = $(DOBOO_PROFILE_$(TARGET_NAME))", config)
                    self.assertIn(f"CODE_SIGN_STYLE[sdk={sdk}*] = Manual", config)
                for name in targets:
                    self.assertIn(f"DOBOO_PROFILE_{name} = {profiles[name].uuid}", config)
                self.assertNotIn(PHONE, config)
                self.assertNotIn(WATCH, config)
                self.assertNotIn("certificate", config)


class ProjectTargetTests(unittest.TestCase):
    def test_legacy_two_app_identity_comes_from_release_settings(self):
        self.assertEqual(build.project_targets(project_fixture(TARGETS)), TARGETS)

    def test_reads_widget_identity_and_each_targets_source_entitlements(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(build.project_targets(project_fixture(WIDGET_TARGETS, root), root), WIDGET_TARGETS)

    def test_rejects_widget_without_shared_entitlements_in_either_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in (WATCH_TARGET.name, WIDGET_TARGET.name):
                with self.subTest(target=name):
                    project = project_fixture(WIDGET_TARGETS, root)
                    (root / f"{name}.entitlements").write_bytes(plistlib.dumps({}))
                    with self.assertRaisesRegex(build.BuildError, "must both declare"):
                        build.project_targets(project, root)

    def test_rejects_invalid_widget_bundle_team_marketing_version_or_target_name(self):
        changes = [("PRODUCT_BUNDLE_IDENTIFIER", "example.unrelated.widget", "bundle ID must extend"),
                   ("DEVELOPMENT_TEAM", "OTHERTEAM1", "same development team"),
                   ("MARKETING_VERSION", "0.3.0", "matching marketing versions")]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for key, value, message in changes:
                with self.subTest(setting=key):
                    project = project_fixture(WIDGET_TARGETS, root)
                    project["objects"][WIDGET_TARGET.name + "-release"]["buildSettings"][key] = value
                    with self.assertRaisesRegex(build.BuildError, message):
                        build.project_targets(project, root)
            project = project_fixture(WIDGET_TARGETS, root)
            project["objects"][WIDGET_TARGET.name]["name"] = "Bad Name"
            with self.assertRaisesRegex(build.BuildError, "xcconfig variable identifiers"):
                build.project_targets(project, root)

    def test_build_override_unifies_different_source_build_numbers_for_legacy_and_widget_projects(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for targets in (TARGETS, WIDGET_TARGETS):
                with self.subTest(count=len(targets)):
                    project = project_fixture(targets, root)
                    project["objects"][WATCH_TARGET.name + "-release"]["buildSettings"]["CURRENT_PROJECT_VERSION"] = "3"
                    parsed = build.project_targets(project, root)
                    self.assertEqual(parsed[WATCH_TARGET.name].build_number, "3")
                    with self.assertRaisesRegex(build.BuildError, "provide --build-number"):
                        build.validate_build_versions(parsed)
                    build.validate_build_versions(parsed, "5")


class SigningSettingsTests(unittest.TestCase):
    def setUp(self):
        self.profiles = {name: profile(target) for name, target in WIDGET_TARGETS.items()}
        self.settings = {}
        for name, target in WIDGET_TARGETS.items():
            self.settings[name] = {"PROVISIONING_PROFILE_SPECIFIER": self.profiles[name].uuid,
                                   "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "Apple Development",
                                   "DEVELOPMENT_TEAM": TEAM, "PLATFORM_NAME": target.sdk,
                                   "PRODUCT_BUNDLE_IDENTIFIER": target.bundle_id, "PRODUCT_TYPE": target.product_type,
                                   "FULL_PRODUCT_NAME": target.product_name + (".appex" if target.product_type == build.APP_EXTENSION else ".app"),
                                   "MARKETING_VERSION": target.version, "CURRENT_PROJECT_VERSION": "4"}

    def show_settings(self, command):
        name = command[command.index("-target") + 1]
        self.assertIn("-showBuildSettings", command)
        self.assertIn("CURRENT_PROJECT_VERSION=4", command)
        self.assertEqual(command[command.index("-sdk") + 1], WIDGET_TARGETS[name].sdk)
        self.assertNotIn("build", command)
        self.assertNotIn("-allowProvisioningUpdates", command)
        return json.dumps([{"target": name, "buildSettings": self.settings[name]}]).encode()

    def verify(self):
        return build.verify_signing_settings(Path("Doboo.xcodeproj"), Path("signing.xcconfig"),
                                             WIDGET_TARGETS, self.profiles, "4")

    def test_inspects_each_target_separately_without_a_device_destination(self):
        with patch.object(build, "run", side_effect=self.show_settings) as command:
            self.verify()
            self.assertEqual(command.call_count, 3)
            for call in command.call_args_list:
                self.assertNotIn(PHONE, call.args[0])
                self.assertNotIn(WATCH, call.args[0])

    def test_wrong_or_unresolved_widget_profile_stops_before_build(self):
        for value in (self.profiles[WATCH_TARGET.name].uuid, "$(DOBOO_PROFILE_$(TARGET_NAME))", ""):
            with self.subTest(value=value):
                self.settings[WIDGET_TARGET.name]["PROVISIONING_PROFILE_SPECIFIER"] = value
                with patch.object(build, "run", side_effect=self.show_settings):
                    with self.assertRaisesRegex(build.BuildError, "PROVISIONING_PROFILE_SPECIFIER mismatch for DobooWidgets"):
                        self.verify()


class ArtifactVerificationTests(unittest.TestCase):
    targets = TARGETS

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.parent = Path(self.directory.name) / "Companion.app"
        self.apps = {PHONE_TARGET.name: self.parent, WATCH_TARGET.name: self.parent / "Watch/Doboo.app"}
        if WIDGET_TARGET.name in self.targets:
            self.apps[WIDGET_TARGET.name] = self.apps[WATCH_TARGET.name] / "PlugIns/DobooWidgets.appex"
        self.profiles = {name: profile(target) for name, target in self.targets.items()}
        self.entitlements = {}
        self.commands = []
        for name, app in self.apps.items():
            app.mkdir(parents=True)
            target = self.targets[name]
            info = {"CFBundleIdentifier": target.bundle_id, "CFBundleVersion": "4", "CFBundleShortVersionString": target.version,
                    "CFBundleSupportedPlatforms": ["iPhoneOS" if target.sdk == "iphoneos" else "WatchOS"],
                    "UIDeviceFamily": [1, 2] if target.sdk == "iphoneos" else [4],
                    "CFBundlePackageType": "XPC!" if target.product_type == build.APP_EXTENSION else "APPL"}
            if name == WATCH_TARGET.name:
                info.update(WKApplication=True, WKCompanionAppBundleIdentifier=PHONE_TARGET.bundle_id)
            if target.product_type == build.APP_EXTENSION:
                info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            (app / "embedded.mobileprovision").write_bytes(plistlib.dumps(self.profiles[name].data))
            self.entitlements[str(app)] = {"application-identifier": f"{TEAM}.{target.bundle_id}",
                                          "com.apple.developer.team-identifier": TEAM, "get-task-allow": True}
            if target.app_groups:
                self.entitlements[str(app)][build.APP_GROUPS] = list(target.app_groups)
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
        return build.verify_artifacts(self.parent, self.targets, self.profiles,
                                      {"iphoneos": PHONE, "watchos": WATCH}, "4", NOW)

    def edit_info(self, name, **values):
        path = self.apps[name] / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update(values)
        path.write_bytes(plistlib.dumps(info))

    def test_checks_every_signed_bundle_and_expected_build_override(self):
        self.assertEqual(self.verify(), self.apps[WATCH_TARGET.name])
        for app in self.apps.values():
            self.assertIn(["codesign", "--verify", "--deep", "--strict", str(app)], self.commands)
        self.assertEqual(PHONE_TARGET.build_number, "2")

    def test_rejects_the_original_wrong_watch_profile_in_built_output(self):
        (self.apps[WATCH_TARGET.name] / "embedded.mobileprovision").write_bytes(plistlib.dumps(profile(PHONE_TARGET, True).data))
        with self.assertRaisesRegex(build.BuildError, "selected provisioning profile"):
            self.verify()

    def test_rechecks_device_membership_even_if_profile_uuid_is_unchanged(self):
        data = copy.deepcopy(self.profiles[WATCH_TARGET.name].data)
        data["ProvisionedDevices"] = [PHONE]
        (self.apps[WATCH_TARGET.name] / "embedded.mobileprovision").write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(build.BuildError, "requested device is absent"):
            self.verify()

    def test_rejects_bundle_version_and_companion_mismatches(self):
        cases = [("CFBundleIdentifier", "example.wrong", "bundle ID"), ("CFBundleVersion", "3", "version"),
                 ("WKCompanionAppBundleIdentifier", "example.other", "companion association")]
        path = self.apps[WATCH_TARGET.name] / "Info.plist"
        original = path.read_bytes()
        for key, value, message in cases:
            with self.subTest(key=key):
                path.write_bytes(original)
                self.edit_info(WATCH_TARGET.name, **{key: value})
                with self.assertRaisesRegex(build.BuildError, message):
                    self.verify()

    def test_rejects_missing_or_wrong_signed_application_identifier(self):
        for identifier in (None, f"{TEAM}.example.other"):
            with self.subTest(identifier=identifier):
                entitlements = self.entitlements[str(self.apps[WATCH_TARGET.name])]
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

    def test_rejects_unexpected_embedded_extensions(self):
        (self.apps[WATCH_TARGET.name] / "PlugIns/Unexpected.appex").mkdir(parents=True)
        with self.assertRaisesRegex(build.BuildError, "exactly the expected widget extensions"):
            self.verify()


class WidgetArtifactVerificationTests(ArtifactVerificationTests):
    targets = WIDGET_TARGETS

    def test_rejects_missing_widget_even_when_parent_signatures_pass(self):
        self.apps[WIDGET_TARGET.name].rename(self.apps[WIDGET_TARGET.name].with_suffix(".missing"))
        with self.assertRaisesRegex(build.BuildError, "exactly the expected widget extensions"):
            self.verify()

    def test_rejects_widget_profile_replaced_by_the_watch_app_profile(self):
        path = self.apps[WIDGET_TARGET.name] / "embedded.mobileprovision"
        path.write_bytes(plistlib.dumps(self.profiles[WATCH_TARGET.name].data))
        with self.assertRaisesRegex(build.BuildError, "DobooWidgets bundle did not use the selected"):
            self.verify()

    def test_rechecks_widget_profile_device_and_app_group(self):
        path = self.apps[WIDGET_TARGET.name] / "embedded.mobileprovision"
        for change, message in ((lambda data: data.update(ProvisionedDevices=[PHONE]), "requested device is absent"),
                                (lambda data: data["Entitlements"].pop(build.APP_GROUPS), "required App Group")):
            with self.subTest(message=message):
                data = copy.deepcopy(self.profiles[WIDGET_TARGET.name].data)
                change(data)
                path.write_bytes(plistlib.dumps(data))
                with self.assertRaisesRegex(build.BuildError, message):
                    self.verify()

    def test_rejects_missing_wrong_or_extra_signed_app_groups(self):
        for name in (WATCH_TARGET.name, WIDGET_TARGET.name):
            original = copy.deepcopy(self.entitlements)
            for groups in ([], ["group.other"], [build.WATCH_APP_GROUP, "group.extra"]):
                with self.subTest(target=name, groups=groups):
                    self.entitlements = copy.deepcopy(original)
                    self.entitlements[str(self.apps[name])][build.APP_GROUPS] = groups
                    with self.assertRaisesRegex(build.BuildError, "Signed App Group entitlements"):
                        self.verify()
            self.entitlements = original

    def test_rejects_widget_bundle_version_platform_package_and_extension_point(self):
        cases = [("CFBundleIdentifier", "example.wrong", "bundle ID"), ("CFBundleVersion", "3", "version"),
                 ("CFBundleShortVersionString", "0.1.0", "version"),
                 ("CFBundleSupportedPlatforms", ["WatchSimulator"], "platform/device family"),
                 ("UIDeviceFamily", [1], "platform/device family"), ("CFBundlePackageType", "APPL", "package type"),
                 ("NSExtension", {"NSExtensionPointIdentifier": "com.apple.wrong"}, "extension point")]
        path = self.apps[WIDGET_TARGET.name] / "Info.plist"
        original = path.read_bytes()
        for key, value, message in cases:
            with self.subTest(key=key):
                path.write_bytes(original)
                self.edit_info(WIDGET_TARGET.name, **{key: value})
                with self.assertRaisesRegex(build.BuildError, message):
                    self.verify()


class CommandLineTests(unittest.TestCase):
    def test_both_hardware_udids_are_required_before_any_tool_runs(self):
        for args in ([], ["--iphone-udid", PHONE], ["--watch-udid", WATCH]):
            with self.subTest(args=args), patch.object(build, "run") as command, patch("sys.stderr", new=io.StringIO()):
                with self.assertRaises(SystemExit):
                    build.main(args)
                command.assert_not_called()

    def test_build_uses_only_a_generic_destination_and_no_account_updates(self):
        varied_targets = {name: replace(target, build_number="3" if name == WATCH_TARGET.name else "2")
                          for name, target in WIDGET_TARGETS.items()}
        for targets in (TARGETS, WIDGET_TARGETS, varied_targets):
            profiles = {name: profile(target) for name, target in targets.items()}
            with self.subTest(count=len(targets)), tempfile.TemporaryDirectory() as temporary:
                derived = Path(temporary) / "build"
                with (patch.object(build, "run", return_value=b"{}") as helper,
                      patch.object(build, "project_targets", return_value=targets),
                      patch.object(build.Path, "home", return_value=Path(temporary)),
                      patch.object(build, "select_profile", side_effect=lambda _, target, *args: profiles[target.name]) as select,
                      patch.object(build, "verify_signing_settings") as settings,
                      patch.object(build, "verify_artifacts", return_value=derived / "verified-watch.app") as verify,
                      patch.object(build.subprocess, "run", return_value=build.subprocess.CompletedProcess([], 0)) as execute,
                      patch("sys.stdout", new=io.StringIO()) as output):
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
                    self.assertEqual(settings.call_args.args[2:], (targets, profiles, "4"))
                    self.assertEqual(verify.call_args.args[0], derived.resolve() / "Build/Products/Release-iphoneos/Companion.app")
                    self.assertEqual(verify.call_args.args[-1], "4")
                    self.assertEqual(select.call_count, len(targets))
                    for call in select.call_args_list:
                        self.assertEqual(call.args[2], PHONE if call.args[1].sdk == "iphoneos" else WATCH)
                    self.assertIn("device installation and launch were not performed", output.getvalue())

    def test_missing_widget_profile_stops_before_xcodebuild(self):
        selector = build.select_profile
        with tempfile.TemporaryDirectory() as temporary:
            candidates = [profile(target) for name, target in WIDGET_TARGETS.items() if name != WIDGET_TARGET.name]
            with (patch.object(build, "run", return_value=b"{}"),
                  patch.object(build, "project_targets", return_value=WIDGET_TARGETS),
                  patch.object(build.Path, "home", return_value=Path(temporary)),
                  patch.object(build, "select_profile", side_effect=lambda _, target, udid, now: selector(candidates, target, udid, NOW)),
                  patch.object(build.subprocess, "run") as execute,
                  patch.object(build, "verify_signing_settings") as settings):
                with self.assertRaisesRegex(build.BuildError, "No valid development profile for DobooWidgets"):
                    build.main(["--iphone-udid", PHONE, "--watch-udid", WATCH])
                execute.assert_not_called()
                settings.assert_not_called()


if __name__ == "__main__":
    unittest.main()
