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

The actual subscription generation → v2 validation → Pets registration → visual
update → metadata update path was exercised, not replaced by lifecycle fixtures.

- QuotaPie previously rejected native image requests with HTTP 400,
  `quotapie_subscription_guard` / `subscription_route_unsupported`. Its protected
  route list omitted `/images/generations` and `/images/edits`. QuotaPie commit
  `c0e15d7` admits those native subscription routes while retaining the source
  account, quota/reserve cutoffs, report-only restrictions and in-flight abort.
  No protection disablement, account switch, paid API route or API key was used.
  Built-in imagegen subsequently produced the base, motion and look artwork.
- A source-image edit was also generated through built-in imagegen: the previous
  canonical image was the edit target, identity references remained separate,
  and the requested mouth change was saved in a linked draft without overwriting
  the original. This draft was not substituted for the published character.
- Version 2 passed installed OpenAI work-pets structural/quality scripts and
  three independent blind direction reviews. The authenticated Pets tools then
  validated, uploaded and created one custom Doboo Pet. List readback and a
  download of the stored sheet confirmed its identity and exact decoded pixels.
  Atlas SHA-256: `58e165e4ea022c2c60abf37df681b75ab582e6618cf2bd2b2ede58bc0dd2e1e6`.
- Version 3 changed the waving animation through built-in imagegen, with the
  downloaded actual Pet as an identity reference. The complete atlas was rebuilt
  and revalidated. All sixteen look cells were byte-identical in decoded RGBA
  to the independently reviewed parent. `update_pet` retained the same custom
  Pet ID; list readback and a new stored download matched the validated pixels.
  Atlas SHA-256: `933167c74f3de8fa98ba0763664ce3a86408211b9c9f58db5c32c2f40b448957`.
- Version 4 changed the description using a real metadata-only `update_pet` and
  list readback, with no image upload. All three publications preserved the
  existing active Dewey selection. The verified revisions and stable binding
  are retained in installed plugin data; a fresh process of the installed plugin
  reports the final revision as `pets-confirmed`. An already loaded older MCP
  process does not acquire new tool definitions until the host reconnects it.
- The quality report is `ok: true`, with 29-pixel jump lift, zero landing delta
  and maximum look-center drift of one pixel. Two reviewed look-continuity
  warnings remain (157.5-degree spacing and the 337.5→000 transition); these are
  documented visual limitations, not missing structural frames.
- Plugin tests: 37 passed, one platform-specific skip. Character-tool tests:
  six passed. TypeScript and repository consistency checks passed. Regression
  cases include old-parent metadata edits, full reference capacity, unchanged
  source retention, stable IDs, pending outcomes and stale Watch receipts.
- No simulator or physical device was accessed. The final version contains the
  distinct Watch representation, but Watch delivery and rendering for this
  revision remain unverified. No receipt was invented.

Final previews, exact prompts, source images, host receipts and downloads remain
in the private production runs. They are not committed as account-specific
fixtures or presented as a shared-gallery publication.
