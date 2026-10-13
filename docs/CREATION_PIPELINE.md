# Character production through the existing plugin

Doboo keeps one character identity and revision across hosts. Pets and Watch may
use different representations of that character. This is a production workflow
inside the existing MCP/plugin, not a new public website or image-generation API.

## OpenAI's existing workflow

The [official Pets guide](https://learn.chatgpt.com/docs/pets#create-a-custom-pet)
describes Create pet installing `hatch-pet`. The installed OpenAI `work-pets`
0.1.6 package also supplies generation job preparation, layout guides, strip
extraction, assembly, previews and structural/visual quality gates. This plugin
executes those scripts in place; it does not copy or replace their compositor.
The public web-upload paragraph describes v1; the currently callable Pets tools
and installed contract support v2. New production runs require v2 (73 required
frames, nine motion states plus sixteen look directions).

The OpenAI plugin, Python with Pillow, and ffmpeg for the required MP4 preview are dependencies. Discovery prefers an
explicit `DOBOO_PETS_SKILL_DIR` / `DOBOO_PYTHON`, then installed work-pets versions
and installed Python interpreters, including the desktop's bundled runtime.
Image generation uses the host's imagegen capability. There is no silent paid API
fallback or credential scraping. Native imports continue working without either
dependency.

## Executable workflow

The `use-character` skill drives these MCP tools:

1. `begin_character_creation`: complete customized character definition, a visual
   identity/change brief, style, optional reference images. The character ID is
   stable and its version increases. Existing sprite artwork is automatically
   supplied as an identity reference. Run data and job prompts are persistent.
2. `creation_status` + `supply_character_artwork`: host imagegen performs each
   ready job using its prescribed references. The host supplies the actual PNG
   and concrete visual review. Standard rows immediately go through the bundled
   extraction and inspection. Repairing a job invalidates dependent reviews.
3. `run_character_production`: standard rows → cardinal extraction → first look
   row registration → v2 assembly/despill → final quality gate. The host generates
   newly ready jobs between stages and supplies real direction-semantic reviews.
   Final GIF previews are extracted from the encoded atlas, not the source art.
   Missing or failed reports prevent publication. No model-authored `ok` replaces
   execution of OpenAI's quality scripts.
4. `next_pet_action` + `record_pet_response`: the authenticated host invokes the
   returned Pets tool and returns its actual response. Sequence: snapshot the current active Pet, validate,
   prepare upload, create/update, paginated readback, download link. Selection
   is unchanged by default; `activate: true` explicitly adds selection and its
   verification. Readback rejects an unexpected active-selection change without
   automatically overwriting it.
   The durable custom Pet ID is bound to the character ID; later revisions update
   it. Unknown outcomes reuse the same pending action/upload session. A per-ID
   reservation prevents concurrent runs from creating duplicates. It remains
   reserved when an outcome is unknown and must be reconciled before another run.
5. `verify_pet_download`: compare stored encoded bytes, or decoded RGBA pixels
   after lossless re-encoding. Only then publish the full revision to the local
   library. Reject a differing or lossy asset instead of declaring equivalence.
6. Existing iPhone/Watch transfer, then `record_watch_receipt`: require matching
   ID, version, semantic definition hash and receiver selection. The transport
   additionally checks the exact transferred byte hash. Definitions use sorted
   JSON with unescaped slashes in Swift and JavaScript, checked by the interchange
   test. Different JSON indentation does not mean a different character.

The lifecycle server cannot directly call another host's authenticated connector.
The skill supplies the orchestration; returned receipts are explicitly
**host-reported**, not cryptographically authenticated by the Doboo server. Unit
fixtures are not real Pet registrations. The status field `deliveryConfirmed`
means these submitted delivery checks passed; it does not attest visual quality
on a physical Watch. Inspect rendering separately.

Device delivery is separate from Pets creation and verification. The plugin never
boots a simulator, builds or installs an app, or starts a device process. When
Watch delivery is requested, the native import/send flow supplies the receipt.
The previous developer-device automation and automatic launch-time import/send
path have been removed.

## Representation contract

`appearance` is the primary/Pets representation. Optional `appearance.watch`
contains `renderer`, `tint`, and optional `sprite` under the same constraints.
It cannot recursively contain another `watch`. An absent override uses the
primary representation. Both representations are included in the same versioned
pack and total 32 MiB limit. The native round-blob override is appropriate for
Doboo's existing character; other characters can supply their own Watch sprite.
The iPhone editor exposes a native Watch override and defaults new sheet imports
to v2. Older clients that reject unknown fields need the updated app to import a
pack with this extension.

A Pets upload changes appearance, not model behavior. Dot/agent identity and
personality still follow the existing character-context paths; Pets registration
does not imply their persistent settings or live work-state synchronization.

## Observed verification, 2026-10-13

- Real bundled MCP server invoked the installed preparation script, produced the
  base job and exact identity references, and rejected publication without art.
- Authenticated Pets `validate_pet_spritesheet` accepted the existing v1 check
  asset; OpenAI's `--require-v2` validator rejected it for new v2 production.
  This is preflight verification, not a new custom Pet registration.
- Lifecycle tests exercise stable-ID updates, stale action rejection, ambiguous
  retries, pagination, changed bytes, concurrent publication and stale Watch
  receipts using explicitly isolated fixtures. They also verify opt-in activation,
  preservation of the current Pet, early input rejection, and invalidation of
  visual verdicts after artwork repair. The plugin suite passes 32 tests with one
  platform-specific skip; these are not live create/update calls.
- Swift tests and independent Swift/JavaScript file interchange pass, including
  differing Watch representation and matching semantic hashes (26 Swift and six
  character-tool tests). TypeScript checking and repository consistency pass.
- Image generation was retried through the built-in tool and failed before an
  image was produced: HTTP 400, `quotapie_subscription_guard`,
  `subscription_route_unsupported`. Inspection of the running relay shows its
  subscription guard accepts POST `/responses` and `/responses/compact`, and
  GET `/models`; other routes are rejected before upstream forwarding. This is
  an unsupported protected route, not evidence of exhausted quota or invalid art.
- The authenticated Pets list remains reachable and contains no Doboo custom Pet.
  This does not demonstrate create/update, which still needs validated artwork.
- This verification pass uses no simulator or physical device. Native receipt
  and rendering remain unverified for the generated revision.

The full creation/registration/update flow is **not yet verified**. A supported,
user-authorized image-generation route is required before continuing the saved
base job. Protection remains enabled; no account switch or paid fallback is
attempted. Do not upload a built-in Pet, blank fixture or unvalidated replacement
as a substitute for the requested character. The resumable production run is
preserved, so recovery does not require device access or a new character ID.
