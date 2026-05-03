# Caller-attestation protocol

Chalk's `insert` and `docker` paths now accept a structured attestation
blob from the parent process — typically a system-spawned endpoint
agent (Crayon being the motivating consumer) that knows things about
an artifact chalk itself cannot derive: provenance ("this model came
from huggingface"), build context, host context, and identifying
information about the attestor itself.

The attestation is informational, not authoritative. Chalk records
what it is told and surfaces a discrepancy when its own observations
disagree with the caller. The trust assumption is that the caller is
a system process spawning chalk as the user; on Linux/macOS that is
sufficient isolation for the use case.

This document specifies the wire format, validation rules, status
semantics, and where the data lands. Everything here is a contract:
changing it after the fact requires a version bump.

## Channel

Two channels, in priority order:

1. **`CHALK_CALLER_ATTESTATION`** — JSON envelope passed inline as an
   environment variable.
2. **`CHALK_CALLER_ATTESTATION_FILE`** — absolute path to a file
   containing the same JSON envelope. Read only when
   `CHALK_CALLER_ATTESTATION` is unset.

The env-var channel is convenient but bounded by `ARG_MAX` (~256 KB
on macOS, larger on Linux). Large attestations (signed VC chains,
SBOM excerpts) should use the file channel; the caller may unlink the
file after spawning chalk so secrets don't persist on disk.

stdin is deliberately not a channel. `chalk docker` already consumes
stdin in some flows; reusing it for attestation would conflict.

If both env vars are unset, the attestation feature is inert. No
message is logged. This is the common case for direct-CLI use.

## Envelope

```json
{
  "version": 1,

  "CALLER_ATTESTED_INFO": { "...": "about the attestor" },
  "CALLER_ATTESTED_HOST_INFO": { "...": "about the host" },
  "CALLER_ATTESTED_BUILD_INFO": { "...": "about the build" },

  "CALLER_ATTESTED_ARTIFACT_INFO": {
    "/abs/realpath/to/artifact": {
      "sha256": "<lowercase hex>",
      "info": { "...": "free-form, opaque to chalk" }
    }
  }
}
```

- **`version`** is required and must be `1` for this revision. An
  unknown major version causes the envelope to be rejected with an
  `error`-level log; chalk continues without attestation. Minor
  versions can be added compatibly by extending top-level keys.
- The four `CALLER_ATTESTED_*` keys are individually optional — any
  combination is valid, including all four omitted (in which case
  the envelope was pointless but is not an error).
- Any other top-level key whose name matches `X-*` is allowed and
  passed through untouched (forward-compat slot for caller
  experimentation). Other unknown top-level keys are warned about
  and dropped.
- Each of the three host/build/info buckets is an object. Its inner
  shape is opaque to chalk. Chalk does not validate, transform, or
  redact it.
- `CALLER_ATTESTED_ARTIFACT_INFO`'s value is an object whose keys are
  paths and whose values are objects with the strict shape
  `{ "sha256": string, "info": any }`. Any other shape rejects the
  whole envelope.

## Path-matching contract

The caller MUST provide each artifact path as the **fully resolved
absolute path with no symbolic links remaining** — i.e., the path that
`realpath(3)` would produce. Chalk does not normalize on the caller's
behalf. This is an explicit, documented contract: callers are system
processes that already know their own filesystem layout, and pushing
normalization to the caller eliminates an entire class of "the caller
sent `./model.onnx` and chalk processed `/work/model.onnx`" bugs.

Chalk on the receiving side computes the same realpath for each
artifact it processes and matches against attestation entries by
exact string equality. Anything not matched goes to the untracked
bucket (see below).

## Per-artifact value: status wrapper

The value emitted into a chalked artifact's mark and reports under
`CALLER_ATTESTED_ARTIFACT_INFO` is **always** the wrapped form below.
The raw caller payload is never emitted directly.

```json
// status: match — common case
{ "status": "match", "info": { ... } }

// status: mismatch — caller-attested hash differs from chalk's
// unchalked hash for the artifact.  Race condition or tampering.
{
  "status":          "mismatch",
  "attested_sha256": "<from caller>",
  "observed_sha256": "<chalk's unchalked hash>",
  "info":            { ... }
}

// status: unverified — chalk could not compute an unchalked hash
// for this artifact (codec didn't produce one, or the file moved
// between scan and hash).  Treat as an integrity gap, not a match.
{
  "status":          "unverified",
  "attested_sha256": "<from caller>",
  "info":            { ... }
}
```

Hashes surface in the mark only on `mismatch` / `unverified`. On
`match` chalk has independently confirmed the attested hash; there is
no value in echoing it back. This keeps marks compact in the common
case and makes any appearance of an `attested_sha256`/`observed_sha256`
pair a reliable signal that something needs investigation.

`mismatch` and `unverified` each emit a `warn`-level log line naming
the artifact and the status. The chalk operation does not abort —
the attestation is recorded, the status flags the concern, and
downstream tooling decides policy.

## Untracked artifacts

A `CALLER_ATTESTED_ARTIFACT_INFO` entry whose path does not match any
artifact chalk ends up tracking is aggregated into a host-level key:

```json
"CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO": {
  "/abs/path": { "sha256": "<hex>", "info": { ... } }
}
```

No status wrapper — chalk never observed the file, so there is
nothing to compare. Each untracked entry emits a `warn` log line.

Common reasons a path lands here:

- The caller hashed a file and chalk didn't end up scanning it
  (filtered by ignore list, removed mid-flight, etc.).
- The caller's path didn't survive realpath on the chalk side
  (caller violated the contract above).
- For `chalk docker`, a path that isn't inside any build context.

## Docker semantics

For `chalk docker build` (and other docker subcommands that produce
an artifact), the caller's contract is:

> Every path under `CALLER_ATTESTED_ARTIFACT_INFO` MUST be inside one
> of the build's context directories.

Chalk-docker enumerates the context dirs from the invocation —
positional context, plus any `--build-context name=path` entries —
and `realpath`s each. For each attested path, chalk checks that it
starts with one of those realpaths. If yes, chalk reads the file
from the host filesystem, computes its SHA-256, and emits the status
wrapper into the **image's** mark. If no, it goes to the untracked
bucket with a `warn`.

Chalk does **not** attempt to map host paths to in-image paths.
The caller's mental model is host-side; chalk records what was said
about which host file, and the consumer of the mark decides how to
reconcile that with the resulting image layout.

The host/build/info buckets pass through unchanged — they're
attached to the image's mark just as they would be to any other
artifact's host-level keys.

## Top-level proxying

The non-artifact buckets are proxied to top-level chalk keys, name
preserved:

| Caller envelope key          | Chalk key (host-level)       |
| ---------------------------- | ---------------------------- |
| `CALLER_ATTESTED_INFO`       | `CALLER_ATTESTED_INFO`       |
| `CALLER_ATTESTED_HOST_INFO`  | `CALLER_ATTESTED_HOST_INFO`  |
| `CALLER_ATTESTED_BUILD_INFO` | `CALLER_ATTESTED_BUILD_INFO` |

Each is a free-form object; chalk does not destructure, validate, or
transform.

## Keyspecs and templates

Five new chalk keys, all of con4m type `` `x `` (free-form, mirroring
the existing pattern used for nested data):

- `CALLER_ATTESTED_INFO` — `ChalkTimeHost`
- `CALLER_ATTESTED_HOST_INFO` — `ChalkTimeHost`
- `CALLER_ATTESTED_BUILD_INFO` — `ChalkTimeHost`
- `CALLER_ATTESTED_ARTIFACT_INFO` — `ChalkTimeArtifact`
- `CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO` — `ChalkTimeHost`

Mark templates take the four chalk-time keys (the `RunTimeHost`
`CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO` is collected after marks
are written and so cannot land in a mark by construction):

- `mark_default` (covers all chalking ops, including docker — chalk
  uses one mark template across the board)
- `mark_all` and `mark_large`

Report templates take all five keys:

- `report_default`
- `insertion_default`
- `report_all` and `report_large`

Explicitly **not** added to `mark_reproducable`. Attested payloads
are not deterministic by design (timestamps, build IDs, attestor
identity all vary), and the reproducible template's purpose is
bit-for-bit reproducibility.

## Validation and failure handling

Validation is performed once, eagerly, when the attestation plugin
is initialized:

1. JSON parse — failure → `error` log, attestation discarded, chalk
   continues without it. Exit code unaffected.
2. Top-level must be an object.
3. `version` must be present and equal to `1`.
4. Each recognized `CALLER_ATTESTED_*` key, if present, must be an
   object.
5. `CALLER_ATTESTED_ARTIFACT_INFO`'s entries must each have a
   `sha256` (lowercase hex, length 64) and may have an `info` of any
   JSON type. No other fields are allowed in the per-entry shape.
6. Unknown top-level keys not matching `X-*` → `warn`, then dropped.

A validation failure at any non-soft step (1–5) discards the entire
attestation. Half-applying a malformed envelope would be worse than
applying none. The chalk operation continues; no attestation keys
appear in the mark or report.

## Plugin shape

A single new plugin, `caller_attestation`:

- Reads + parses + validates the envelope on first invocation.
- Caches the parsed result for the lifetime of the chalk process.
- `ctHostCallback` emits the three top-level buckets and (after
  artifact iteration is complete) the untracked-artifact aggregate.
- `ctArtCallback` per artifact: looks up by realpath, computes the
  status wrapper against the artifact's unchalked hash, emits.

The plugin does no I/O of its own beyond the initial envelope read.
No network calls, no signature verification (the attestation is
informational, not cryptographic). If signed attestations become
interesting later, they slot in as `CALLER_ATTESTED_INFO.signature`
on the caller side and a downstream verifier — not chalk's job.

## Examples

### Single-artifact insert

Caller writes `/work/models/llama.gguf`, hashes it, then spawns:

```sh
CHALK_CALLER_ATTESTATION='{
  "version": 1,
  "CALLER_ATTESTED_INFO": {
    "attestor": "crayon-file-tracker",
    "attestor_version": "0.4.1"
  },
  "CALLER_ATTESTED_ARTIFACT_INFO": {
    "/work/models/llama.gguf": {
      "sha256": "ab12...ef",
      "info": {
        "source": "huggingface",
        "repo":   "meta-llama/Llama-2-7b-gguf",
        "revision": "v1.0"
      }
    }
  }
}' chalk insert /work/models/llama.gguf
```

Chalk hashes the file, gets a match, and the resulting GGUF mark
contains:

```json
"CALLER_ATTESTED_INFO": { "attestor": "crayon-file-tracker", ... },
"CALLER_ATTESTED_ARTIFACT_INFO": {
  "status": "match",
  "info": { "source": "huggingface", ... }
}
```

### Race-condition mismatch

Same call, but the file is rewritten between the caller hashing it
and chalk processing it. Chalk's unchalked hash differs from
`attested_sha256`. The mark records:

```json
"CALLER_ATTESTED_ARTIFACT_INFO": {
  "status": "mismatch",
  "attested_sha256": "ab12...ef",
  "observed_sha256": "9f44...01",
  "info": { "source": "huggingface", ... }
}
```

and chalk logs at `warn`:

> `/work/models/llama.gguf`: caller-attested hash mismatch (attested
> ab12…ef, observed 9f44…01); attestation recorded with status
> "mismatch".

### Untracked attestation

Caller attests two files but only one is actually scanned (e.g., the
other is in an ignored path). The scanned one's mark gets the
normal `CALLER_ATTESTED_ARTIFACT_INFO` entry; the operation's
host-level keys also include:

```json
"CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO": {
  "/work/cache/intermediate.bin": {
    "sha256": "...",
    "info":   { ... }
  }
}
```

with a `warn` per untracked path.

### Docker build, multi-context

```sh
CHALK_CALLER_ATTESTATION_FILE=/run/crayon/attest.json \
  chalk docker build \
    --build-context vendor=/opt/vendor-deps \
    -t myimg /work/repo
```

Chalk realpaths `/work/repo` and `/opt/vendor-deps`, then for each
attested path checks membership in either. In-context paths get
host-side hashed and emitted into the image's mark; out-of-context
paths land in the untracked bucket.

## Non-goals

- **Schema enforcement on the inner `info` payloads.** Free-form is
  the contract. If a downstream consumer wants schema discipline,
  that's an agreement between the caller and that consumer.
- **Signature verification.** The trust model is process-spawning,
  not cryptographic. Signed attestations are out of scope; if added
  later, they live inside `CALLER_ATTESTED_INFO`.
- **Mapping host paths to in-image paths for docker.** Caller-side
  concern.
- **Mutating attestations across re-chalk operations.** The current
  attestation overwrites whatever was there last; preserving history
  is the job of `OLD_CHALK_METADATA_*`.

## Open questions to resolve before implementation

None blocking. Items deferred to the implementation PR or follow-ups:

- The exact name and registration spot for the new plugin (likely
  `src/plugins/callerAttestation.nim`, registered in
  `base_plugins.c4m`).
- Whether the file-channel read should use `O_NOFOLLOW` to reject
  symlinks (defensive — the caller is trusted but symlink swaps are
  cheap to defend against).
- Whether to add a unit test that exercises envelope validation with
  malformed JSON / wrong version / wrong shape, separate from any
  end-to-end functional test.
