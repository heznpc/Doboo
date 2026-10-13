# Verification guide

## Core and resource checks

Run the core Swift tests and `python3 scripts/check_repository.py` to check
interaction state, invalid coordinates and sizes, localization keys, project
references, resources, privacy declarations and asset metadata. Use `plutil`
to validate the project, plist and localization file formats.

## Native application checks

- Build the watchOS application with its normal resources and icon assets.
- Check release and cancellation, rapid touches, scene transitions and inactive state.
- Check VoiceOver actions and focus, large text, onboarding and settings.
- Check Always On, Reduce Motion, motion preferences, haptics and power use.
- Check signing, packaging, archive metadata, privacy/support URLs and store assets.

Static consistency checks do not substitute for compilation, UI interaction,
physical-device observations or distribution validation. Record each check and
its environment independently; keep account and device diagnostics private.
