# Customization inputs and revisions

Research checked against primary sources on 2026-10-13. These are design inputs,
not a change to Doboo's existing Pets / Dot / agent / Watch and gallery scope.

| Source | Observed mechanism | Application in Doboo |
| --- | --- | --- |
| [EA: Create Your Sims](https://thesims-api.ea.com/game-info/smarter-sims) | Appearance, clothing, walk style and voice are choices distinct from personality and aspirations. | Keep appearance and identity/voice/personality editable separately. A description or personality edit should not force regeneration of approved art. |
| [Nintendo: NookLink](https://en-americas-support.nintendo.com/app/answers/detail/a_id/49147/p/989) | Design QR codes can be scanned on a phone and downloaded in the game. | Imported creative work needs a real host delivery/readback path; producing an export alone is insufficient. |
| [Getty: Animal Crossing Art Generator](https://www.getty.edu/news/how-to-build-an-art-museum-in-animal-crossing/) | Getty's tool adapts existing images to game designs; the underlying community Pattern Tool accepts uploaded or drawn images. | Accept source drawings/photos as inputs, preserve their bytes and provenance, then convert to each host's required representation. This is an external tool workflow, not a claim that Sims has native arbitrary-photo avatar import. |

A completed atlas import is only one advanced input. It does not replace source
image customization. Doboo's conversation/MCP workflow now distinguishes:

- **Definition:** appearance, identity, voice, personality and requested changes.
- **Identity references:** the user's PNG, JPEG or WebP source art, decoded before
  use, up to 20 MiB and 25 megapixels each. Original filenames/extensions are not
  trusted; private snapshots preserve actual format and SHA-256.
- **Edit target:** the image whose existing features should survive except for
  the changes explicitly requested in the brief.
- **Visual revisions:** `revise_character_creation` starts a linked run using the
  prior canonical image as the edit target, keeping earlier output intact.
  References may be replaced or removed; all new artwork requires fresh QA.
- **Motion revisions:** `revise_character_motion` regenerates one requested gesture/action state, preserves other approved source art, then rebuilds and revalidates the complete atlas before updating the stable Pet.
- **Details revisions:** `revise_character_details` reuses exact verified art
  when the complete appearance is unchanged. It requires the same ID, a higher
  version, and a new real Pets update/readback; it clears prior Watch receipt.

This implements a source-art/edit loop and independent character settings. It
is not a claim to have implemented Sims' geometric face/body sliders or a
full drawing editor. Input files are selected through the host conversation;
the existing iPhone atlas picker remains an advanced import path.

The plugin uses the host's subscription image-generation tool and installed
OpenAI work-pets scripts. It neither asks for an API key nor buys an API fallback.
Image entitlement and rate-limit decisions belong to the configured host and provider.
