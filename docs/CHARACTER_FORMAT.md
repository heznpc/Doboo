# Doboo character file v1

One UTF-8 `.doboo.json` file carries the same character into the gallery,
iPhone library, Watch and the Dots / Codex exports. `Characters/` contains
first-party examples. A file is character data, not executable code or a grant
of tool permissions. Sharing it includes its full text and embedded artwork.

| Field | Contract |
| --- | --- |
| `format` | `doboo.character.v1` |
| `id` | Stable lowercase slug, `[a-z0-9-]`, 1–64 characters |
| `version` | Safe integer 1…9,007,199,254,740,991; updates retain the ID and increase this number |
| `name`, `creator` | Nonempty single-line strings, at most 80 Unicode scalars |
| `description` | String, at most 500 characters |
| `identity.backstory`, `identity.voice` | Strings, at most 4,000 / 1,000 characters |
| `personality.traits` | Up to 20 strings, at most 160 characters each |
| `personality.instructions` | Up to 30 strings, at most 500 characters each |
| `appearance.renderer` | `native-doboo` or `spritesheet` |
| `appearance.tint` | `#RRGGBB` |
| `appearance.sprite` | Required for `spritesheet`: `layout`, `mimeType`, `base64` |
| `appearance.watch` | Optional separate `renderer`, `tint`, `sprite` representation for the same character; no nested override |

Sprite files are embedded PNG (`image/png`), at most 20 MiB after base64
decoding. `pets-v1` is 1536×1872; `pets-v2` is 1536×2288. Both use 192×208
cells in eight columns. A complete JSON file is limited to 32 MiB. No external
URL is fetched during import. Other image formats must be converted to PNG
before packaging; this preserves an offline, self-contained exchange file.

Rows 0–8: idle (6), running-right (8), running-left (8), waving (4), jumping (5),
failed (8), waiting (6), running/work (6), review (6). V2 rows 9–10 carry 16 look
directions clockwise from up. Watch touch maps to look directions when they
exist, with a small whole-sprite compression; native Doboo retains its local
deformation. Work-state rows are preserved in the file; this Watch renderer does not receive
work events. A sprite alone never transports chat memory or job progress.

Import must validate before replacing the current file. Identical ID/version
and identical data is idempotent. Different content with the same or older
version is rejected; a newer version may replace it through the import action.
Unknown schema versions are rejected. Original files remain available for
recovery when validation fails. Export must preserve the complete character,
including creator and artwork, not just the working instructions.

## Host outputs

- Dots: readable instructions with the character ID/version, identity and
  working style. This is user-applied configuration, not automatic account
  provisioning.
- Codex: standalone agent TOML with `name`, `description` and
  `developer_instructions`. Place it in a project’s `.codex/agents/` directory;
  model and permissions inherit from the host.
- Pets: embedded sprite bytes can be exported separately. Native Doboo has no
  sprite sheet until artwork is supplied; the UI must say this accurately.
- Watch: the same pack is stored offline; iPhone sends the file using
  WatchConnectivity, with queued and received states distinguished.

Sources checked 2026-10-13: [Pets](https://learn.chatgpt.com/docs/pets),
[Dots](https://learn.chatgpt.com/docs/dots),
[custom agents](https://learn.chatgpt.com/docs/agent-configuration/subagents).
The v2 layout also follows the installed work-pets 0.1.6 sprite contract;
support in every ChatGPT client is not assumed.

The production plugin now connects customization, installed OpenAI Pets v2 tools,
authenticated host registration/update and version-bound Watch receipts. See
[CREATION_PIPELINE.md](CREATION_PIPELINE.md) for the executable flow and actual
verification limits. File export alone is not publication.
