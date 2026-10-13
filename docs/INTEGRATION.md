# Doboo integration

Owner instruction, 2026-10-13: keep Pets + Dots + subagents as one entertainment
character, exchanged through a gallery, and integrate this into Doboo's existing
Watch experience. The order of implementation does not redefine that scope.

## Existing history

| Commit | Change | Integration treatment |
| --- | --- | --- |
| `97b96ef` | Project initialization and product rules | Preserve history; update the product rule to the owner's integration instruction. |
| `bdec202` | First native Watch character, touch deformation, face, haptics and core tests | Keep the native renderer and interaction model. |
| `2e9501a` | Accessibility, lifecycle, resources, localization and invalid-input handling | Build on this branch rather than the older `main`. The prior source-only review did not prove runtime behavior. |

Troupe's remote `main` (`63a0acc`) contains only its introductory README. Its
working implementation was local, untracked PoC material. This integration
therefore ports the data and export behavior deliberately rather than pretending
there is a complete upstream feature commit to merge. Historical positioning,
advisor demo judgments and stale handoff files are not imported as requirements.

## One file across the experience

`Characters/*.doboo.json` is the common character definition. The native gallery creates, imports
and shares it; the Watch uses its identity
and appearance; Dots and Codex exports use the same identity and personality.
The format is specified in [CHARACTER_FORMAT.md](CHARACTER_FORMAT.md).

The first implementation uses an in-app gallery and explicit OS file sharing/import.
A web gallery is not a product requirement or an included service.
There is no hidden ChatGPT account mutation, public hosting, cloud account, or
pretend memory synchronization. A character's text cannot grant itself tools or
permissions. These are implementation boundaries, not a reduction of the agreed
product scope.

The existing Watch experience supplies touch, haptics, reduced-motion behavior
and accessibility. Native Doboo keeps continuous deformation. Imported Pets use
their own sprite artwork with frame playback and small touch reactions, since
flattened artwork cannot reproduce separate face/body deformation.

The iPhone gallery makes a user-selected file available to a paired Watch through
WatchConnectivity. A transfer being queued is distinct from the Watch validating,
saving and acknowledging that character. The gallery remains usable offline.
The earlier CloudKit suggestion was not an owner decision and is not a dependency
for this initial path.

## Validation boundaries

Verify native export → another user's file import → native re-export
using the same ID/version and compare all character fields and sprite bytes.
Verify generated Dots text and Codex TOML against that same file. Test malformed
files and conflicting revisions without replacing a saved character.

App launch, UI interaction, actual Watch transfer, actual dot configuration and
subagent execution are separate checks. Report each based on observed evidence;
successful source generation alone is not a successful host installation.

The repository's built-in example uses first-party Doboo artwork. External or
account-provided sprite sheets used for local validation are not redistributed
with the repository. Name research and its limits are in [NAME_REVIEW.md](NAME_REVIEW.md).
