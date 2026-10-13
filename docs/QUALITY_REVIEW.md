# Verification guide

## Character identity and exchange

- Run the Swift core tests, JavaScript character tests and source consistency checks.
- Round-trip native export, file import and re-export with the same ID and revision.
- Compare all character settings and sprite bytes; test malformed input and revision conflicts.
- Parse generated Dot instructions and agent TOML; distinguish generated files from host execution.
- Check imported sprite alignment, localization, persistence across restart and sharing UI.

## Host and device boundaries

- Build the production application with its included Watch app, resources and icons.
- Verify host connection, tool discovery and resource retrieval independently of model behavior.
- For a catalog, test authenticated publication, discovery, adoption and receipt persistence.
- For a Pet, verify the selected stable ID separately from custom-image creation or update.
- For a Dot or named agent, verify the requested behavior in the intended host.
- For Watch transfer, distinguish queueing, sending, receiver validation, storage and display.
- Check device provisioning and connectivity before using installation as execution evidence.

Keep local account, device and diagnostic records outside the public repository.
Fixture exchanges, compilation and file generation do not prove another user's
host behavior or physical-device delivery.
