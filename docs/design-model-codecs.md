# Native model-file codecs

Chalk's model-file codecs mark ML model artifacts the same way the
Mach-O codec marks executables — modify in place, leave the file a
valid model that its native loaders accept. The `chalk` binary is the
sole producer of marks; downstream tools (Crayon's file-tracker is the
motivating one) trigger chalk via subprocess on the file write.

This document covers four sibling codecs:

- **safetensors** — single-file format, JSON header. New C codec.
- **gguf** — single-file format, custom KV header (v2/v3). New C codec.
- **PyTorch / Keras** (`.pt`/`.pth`/`.keras`) — ZIP-based. Extend the
  existing `codecZip`; no new codec.
- **sidecar** — last-resort `<path>.chalk` fallback for everything
  else (legacy pickle `.pt`, `.bin`, ONNX until protobuf support
  lands). New codec, file I/O only.

ONNX is out of scope for this PR set — the protobuf parser is a
separate undertaking.

## Key audit

The single most important section of this document. Adding chalk
keyspecs is a versioned-schema commitment across every chalk mark in
every customer environment; the bar is high. Each candidate key
needs an explicit decision: reuse an existing key, move to runtime
only, or add a new keyspec.

The motivating crayon-side prototype today has these keys in its
mark; column three is the audit decision.

| Concept | Crayon prototype today | Decision |
|---|---|---|
| Magic / version / identity | `MAGIC`, `CHALK_VERSION`, `CHALK_ID`, `METADATA_ID`, `METADATA_HASH`, `HASH`, `CHALK_RAND` | Reuse — chalk's standard mark already includes these. |
| Timestamp | `TIMESTAMP_WHEN_CHALKED` | Reuse. |
| Host | `HOST_NODENAME_WHEN_CHALKED`, `PLATFORM_WHEN_CHALKED` | Reuse. |
| Path | `PATH_WHEN_CHALKED` | Reuse. |
| Re-chalking lineage | `OLD_CHALK_METADATA_HASH`, `OLD_CHALK_METADATA_ID` | Reuse. |
| File format | `CRAYON_FILE_FORMAT` | **Drop.** Use specific `ARTIFACT_TYPE` values (see below). |
| Model identifier (`meta-llama/Llama-2-7b`, `llama2:7b`) | `CRAYON_MODEL_ID` | **Reuse `ORIGIN_URI`** — synthesize URI per source family: `https://huggingface.co/{org}/{name}`, `ollama://{name}:{tag}`. Treats hosted-model-card semantics the way `ORIGIN_URI` already treats VCS repository origin. |
| Source family hint (`huggingface` / `ollama` / `local`) | `CRAYON_SOURCE` | **Drop.** Derivable from `ORIGIN_URI` scheme/host at report time. |
| Triggering process | `CRAYON_DOWNLOADER_UID`, `CRAYON_DOWNLOADER_EXE` | **Drop from on-disk mark.** Belongs in the chalk operation report, not the artifact. The `INJECTOR_*` family already covers chalk's own identity; the upstream caller is correlation context that crayon emits in its own NDJSON. |
| Session correlation | `CRAYON_SESSION_ID` | **Drop from on-disk mark.** Crayon-internal runtime correlation; redundant with crayon's NDJSON. |
| Conversion lineage (CHALK_ID of source after ST → GGUF) | `DERIVED_FROM` | **NEW keyspec: `DERIVED_FROM_CHALK_ID`.** Type string. Kind `ChalkTimeArtifact`. General-purpose lineage — not ML-specific; any in-place file conversion can carry it. Drafted alongside this PR set. |

**Net delta to the chalk key vocabulary: one new keyspec.** Every
other crayon-prototype key collapses into reuse or moves to
runtime-only.

### `ARTIFACT_TYPE` values

`ARTIFACT_TYPE` already names file-format-specific values
(`"ELF"`, `"Mach-O executable"`, `"JAR"`, `"WAR"`, …). The model
codecs follow the same pattern:

| Codec | Value |
|---|---|
| safetensors | `"SafeTensors model"` |
| gguf | `"GGUF model"` |
| codecZip on `.pt` / `.pth` | `"PyTorch checkpoint"` |
| codecZip on `.keras` | `"Keras model"` |
| sidecar | `"ML model"` (generic) |

These are added as `artType*` constants in `src/types.nim` and
appended to the `ARTIFACT_TYPE` keyspec doc string. No new keyspec
needed.

If reports later want to filter on format independently of
ARTIFACT_TYPE (e.g. "all PyTorch artifacts regardless of container"),
that's a future `MODEL_FORMAT` keyspec. Not in this PR set.

## Per-codec design

### safetensors

**Container shape.** `[u64 LE header_size][JSON header][tensor data]`.
Tensor `data_offsets` are relative to the data section, so the header
can grow without breaking offsets.

**Mark insertion.** Inject `__metadata__.chalk = "<mark JSON>"` into
the header. If `__metadata__` is missing, create it; if `chalk` is
already present, replace it. Atomic temp-file rename.

**Mark extraction.** Read `__metadata__.chalk`, JSON-unescape, parse.

**Unchalked hash.** SHA-256 of the file with the entire
`,"chalk":"…"` (or `"chalk":"…",` when first key) byte range
structurally located and removed from the JSON header — header_size
field is recomputed for the canonical form. Stable under remarking
with payloads of any length, regardless of whether `__metadata__` was
created by us. If `__metadata__.chalk` is absent the unchalked hash
equals the natural file SHA-256.

**Refusals.** Files with a header that fails JSON parse are passed to
the sidecar codec.

### gguf

**Container shape.** `[magic "GGUF"][u32 version][u64 tensor_count][u64
kv_count][KV pairs][tensor info][padding][tensor data]`. KV pairs are
typed (string, int, array, …). Tensor info offsets are relative to
the post-padding data section start, so growing KV requires
recomputing alignment.

**Mark insertion.** Append a string KV pair `chalk.mark` =
`<mark JSON>` to the KV section, increment `kv_count`, regenerate
alignment padding. Atomic temp-file rename.

**Mark extraction.** Walk KV pairs looking for `chalk.mark`.

**Unchalked hash.** SHA-256 of the file with the `chalk.mark` KV pair
removed and `kv_count` decremented (then rerun alignment recompute
for the canonical form). Stable across remarks. If `chalk.mark` is
absent the unchalked hash equals the natural file SHA-256.

**Versions.** v2 and v3 only; v1 (deprecated) is refused, dropped to
sidecar.

### PyTorch / Keras via `codecZip`

**Container shape.** Both formats are ZIP archives — modern PyTorch
since 1.6 (the `zipfile_serialization` default), Keras 3 always.

**Strategy.** Extend the existing `zip_extensions` config in
`base_init.c4m` (or wherever `codecZip` reads it) from `["zip", "jar",
"war", "ear"]` to add `"pt"`, `"pth"`, `"keras"`. The codec already
inserts a top-level `chalk.json` archive entry, which both formats'
loaders ignore.

**Validation step before merge.** Confirm a roundtripped chalk-marked
artifact still loads:

- PyTorch: `torch.load(path)` returns the same state_dict.
- Keras: `keras.models.load_model(path)` returns an equivalent model.

If either rejects the modified archive, that format is escalated to
its own codec. (Anticipated outcome: both pass; the loaders only
inspect known archive members.)

**ARTIFACT_TYPE differentiation.** A small `codecModelZip` wrapper
plugin (or a minor extension to `codecZip`'s `ctArtCallback`) emits
`"PyTorch checkpoint"` for `.pt`/`.pth` and `"Keras model"` for
`.keras`; existing `.jar`/`.war`/`.ear` mapping is preserved.

**Out of scope: legacy `.pt`.** `.pt` files saved before
torch ≥ 1.6 (or with `_use_new_zipfile_serialization=False`) are pure
pickle, not ZIP. They land on the sidecar codec.

### Sidecar fallback

Last-resort codec for files that don't match any in-band format.
Writes `<path>.chalk` next to the artifact containing the mark JSON,
one line, terminated. Lower priority (lower number) than every
format-specific codec, but still extension-gated to a configured
`sidecar_extensions` list — the codec is not a global fallthrough,
it's a deliberate "we recognize this as an ML model but cannot mark
in-band" path.

Default `sidecar_extensions`: `["onnx", "bin"]`. PyTorch legacy
`.pt`/`.pth` pickle files are picked up if `codecZip`'s scan refuses
them (magic mismatch).

Mark JSON is identical to in-band marks — same keys, same `HASH`
semantics (sidecar's `HASH` is the natural file SHA-256, since
nothing is mutated). Read path: `chalk extract <model.bin>` looks for
`<path>.chalk` and parses it.

## Repo layout

Mirroring the Mach-O codec precedent (`docs/design-macho-codec.md`).

| Path | What |
|---|---|
| `src/codecs/safetensors/{include,src}/` | C library (parse, mark insert/remove/extract, unchalked hash). C23, libcrypto for SHA-256. |
| `src/codecs/gguf/{include,src}/` | Same shape, GGUF-specific. |
| `src/utils/safetensors.nim`, `src/utils/gguf.nim` | FFI bindings, compile the C via `{.compile.}`. |
| `src/plugins/codecSafetensors.nim`, `codecGguf.nim`, `codecModelSidecar.nim` | Codec plugins. |
| `src/plugins/codecZip.nim` | Touched only for the `.pt`/`.pth`/`.keras` extension hook + `ARTIFACT_TYPE` differentiation. |
| `src/plugin_load.nim` | Registers `codecSafetensors`, `codecGguf`, `codecModelSidecar`. |
| `src/configs/base_plugins.c4m` | New `plugin safetensors`, `plugin gguf`, `plugin model_sidecar` blocks. Priority: safetensors `1`, gguf `1`, model_sidecar `1500` (below source/zip but above nothing). |
| `src/configs/base_keyspecs.c4m` | New `keyspec DERIVED_FROM_CHALK_ID`. `ARTIFACT_TYPE` doc string extended. |
| `src/types.nim` | New `artTypeSafetensors`, `artTypeGguf`, `artTypePytorchCheckpoint`, `artTypeKerasModel`, `artTypeMLModel`. |
| `tests/unit/test_safetensors.nim`, `test_gguf.nim`, `test_model_sidecar.nim` | Nim unit tests on committed fixture artifacts. |
| `tests/unit/test_codec_zip_models.nim` | Confirms `.pt` / `.pth` / `.keras` go through `codecZip` correctly. |

## Cross-platform

The C libraries have no platform-specific dependencies (libcrypto for
SHA-256, plain POSIX file I/O). Codecs are registered as native on
both `macosx` and `linux` — chalk on Linux can read and write both
in-band and sidecar marks on model files produced anywhere.

## Stacking

This PR set stacks on top of `jtv/macho-native-codec` (the Mach-O
codec PR). It reuses that PR's `src/codecs/` subdirectory layout
convention and the per-codec `{.compile.}` pattern from
`src/utils/macho.nim`.

## Open follow-ups (not blockers for this PR set)

- **ONNX codec.** Protobuf message has a `metadata_props` map; the
  natural place to put a chalk mark. Out of scope here.
- **`MODEL_FORMAT` keyspec.** If reports want to filter on model
  format independently of `ARTIFACT_TYPE`, this is a future
  one-line addition.
- **Trigger-context runtime keys.** If demand emerges to capture
  which crayon-side process triggered a chalk run *inside the chalk
  report* (vs crayon's own NDJSON), that becomes a small set of
  `_OP_TRIGGER_*` runtime-only keys. Today crayon's NDJSON is the
  authoritative correlation, so no additions.
- **Re-marking efficiency.** Per-format codecs all rewrite the file
  on remark — same as the existing macho/elf codecs. Acceptable for
  ML artifact sizes (most marks land at write time, not
  repeatedly).
