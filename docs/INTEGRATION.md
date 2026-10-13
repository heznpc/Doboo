# Doboo integration

Doboo shares one character definition across Pets, Dots, subagents and the Watch
experience, with a gallery for character exchange.

The common MCP server supports host-specific plugin connections. The gallery
MCP App is optional UI; the same discovery, inspection, adoption and character
context tools work without it. Apple Watch is one optional device adapter.

## One file across the experience

`Characters/*.doboo.json` is the common character definition. The native gallery creates, imports
and shares it; the Watch uses its identity
and appearance; Dots and Codex exports use the same identity and personality.
The format is specified in [CHARACTER_FORMAT.md](CHARACTER_FORMAT.md).

The native library provides OS file sharing/import. The plugin provides a host-internal plugin gallery and authenticated catalog search, publication and adoption. Local file export alone does not satisfy discovery/exchange. A standalone web gallery is not a requirement.
Host account changes occur only through the user-authorized host flow. Public catalog hosting and account provisioning have not been deployed. Shared character definitions do not imply memory synchronization. A character's text cannot grant itself tools or
permissions.

The existing Watch experience supplies touch, haptics, reduced-motion behavior
and accessibility. Native Doboo keeps continuous deformation. Imported Pets use
their own sprite artwork with frame playback and small touch reactions, since
flattened artwork cannot reproduce separate face/body deformation.

The iPhone gallery makes a user-selected file available to a paired Watch through
WatchConnectivity. A transfer being queued is distinct from the Watch validating,
saving and acknowledging that character. The gallery remains usable offline.

## Validation boundaries

Verify native export → another user's file import → native re-export
using the same ID/version and compare all character fields and sprite bytes.
Verify generated Dots text and Codex TOML against that same file. Test malformed
files and conflicting revisions without replacing a saved character.

App launch, UI interaction, actual Watch transfer, actual dot configuration and
subagent execution are separate checks. Report each based on observed evidence;
successful source generation alone is not a successful host installation.

The repository's built-in example uses first-party Doboo artwork. External or
account-provided sprite sheets are not bundled with the repository. Name research and its limits are in [NAME_REVIEW.md](NAME_REVIEW.md).
