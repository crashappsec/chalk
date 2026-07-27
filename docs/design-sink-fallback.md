# Design: Sink Fallback Chain

This document describes the design and intent behind the `fallback_sink_config`
field, which allows a `sink_config` to name another `sink_config` to use when
the primary is unavailable.

## Motivation

Chalk's `disable_after_errors` mechanism stops hammering a sink that has
started consistently failing, but it leaves the problem of what to do with
reports that can no longer be delivered. Today they go to the report cache and
are retried on the next chalk invocation — but if the underlying endpoint is
persistently unavailable, those cached reports accumulate indefinitely.

For operations where metadata delivery is critical — `insert`, `build`, `exec`,
and heartbeats — this gap can be significant. A corporate proxy blocking TLS to
a presign endpoint, a regional API outage, or a misconfigured network policy
can silently drop chalk reports for as long as the condition persists.

The fallback chain gives operators a concrete alternative delivery path. Common
scenarios:

- Primary is a `presign` sink pointing to an internal API; fallback is an `s3`
  sink with write-only credentials, reached via a different egress path.
- Primary is a `post` sink in `us-east-1`; fallback is an identical `post` sink
  in `eu-west-1`.
- Primary is a high-fidelity `post` sink; fallback is a lightweight `dns` sink
  that at minimum confirms the operation occurred.

## Configuration

Add `fallback_sink_config` to any `sink_config` section to name the sink that
should receive the report when the primary cannot:

```con4m
sink_config primary_api {
  sink:                  "presign"
  uri:                   "https://api.corp.example.com/sign"
  disable_after_errors:  3
  fallback_sink_config:  "backup_s3"
}

sink_config backup_s3 {
  sink:                  "s3"
  uri:                   "s3://chalk-reports-backup/reports"
  uid:                   env("CHALK_S3_KEY_ID")
  secret:                env("CHALK_S3_SECRET")
  region:                "us-east-1"
  disable_after_errors:  5
  fallback_sink_config:  "last_resort_dns"
}

sink_config last_resort_dns {
  sink:            "dns"
  domain_template: "{METADATA_ID}.chalk.fallback.example.com"
  disable_after_errors: 10
}

subscribe("report", "primary_api")
```

Chains of arbitrary length are supported. Each sink in the chain has its own
`disable_after_errors` threshold — a fallback that itself starts failing will
eventually be disabled and the next link tried.

Circular chains (`A → B → A`) are rejected at configuration load time with an
error message.

**New field:**

| Field                  | Type     | Required | Default | Description                                                               |
| ---------------------- | -------- | -------- | ------- | ------------------------------------------------------------------------- |
| `fallback_sink_config` | `string` | false    | `""`    | Name of another `sink_config` to use when this sink fails or is disabled. |

The field is accepted on all sink types.

## Behavior

### On every delivery failure

When a primary sink fails to deliver a report (any error, regardless of whether
the `disable_after_errors` threshold has been reached), chalk walks the fallback
chain from that sink until it finds one that succeeds. The first success ends
the walk; the report is not sent to any further links in the chain.

The primary sink's consecutive-failure counter is incremented as normal. The
fallback acts as a safety net for the report but does not suppress the primary's
error accounting.

### After the primary is disabled

Once a sink's consecutive-failure counter reaches `disable_after_errors`,
`cfg.enabled` is set to `false` and nimutils stops calling it during publish.
Subsequent publish calls skip the primary silently — `ioErrorHandler` is never
fired for it again.

To handle this, chalk's publish path checks all subscribers that have been
runtime-disabled and have a fallback configured, and delivers to their fallback
chain directly. This happens in the same pass that handles active failures, so
the behavior is uniform regardless of when the sink was disabled.

### Runtime-disabled vs. user-disabled

`fallback_sink_config` only activates for sinks that were disabled due to an
error — not for sinks that were intentionally disabled by the operator. The
distinction is tracked in a runtime set (`runtimeDisabledSinks`) that is
populated only when chalk itself sets `enabled = false` due to an error:

| Cause                                 | `runtimeDisabledSinks` | Fallback triggers? |
| ------------------------------------- | ---------------------- | ------------------ |
| `enabled: false` in config            | no                     | no                 |
| `disable_after_errors` threshold      | yes                    | yes                |
| Hard HTTP 4xx error                   | yes                    | yes                |
| File sink write failure               | yes                    | yes                |
| File path unresolvable at config load | yes                    | yes                |
| Destination path not writable at load | yes                    | yes                |

### Fallback's own error counting

Each sink in the chain maintains its own independent consecutive-failure counter
and `disable_after_errors` threshold. If the fallback itself starts failing, it
accumulates toward its own threshold and is eventually disabled. At that point,
the next link in the chain is tried. A sink that has been deliberately tuned
with a higher threshold (or no threshold) can act as a persistent last resort.

### Interaction with the report cache

The report cache is unaffected. If every sink in the chain fails for a given
report, the original primary sink is added to `sinkErrors` and the report is
cached under its name as before. On the next chalk run, the primary starts
enabled again (the runtime-disabled state is in-memory only), so the cached
report is replayed through the full chain.

## Implementation

### Schema changes

**`src/configs/base_sinks.c4m`** — add `~fallback_sink_config: false` to each
sink type declaration so the con4m validator accepts the field.

**`src/configs/chalk.c42spec`** — add an `elif conffield == "fallback_sink_config"`
branch in `sink_config_check` to validate that the referenced name exists as a
`sink_config` section. Circular-chain detection is handled in Nim, not here,
because the full graph may not be loaded when the validator runs for any
individual section.

### Nim changes

**`src/sinks.nim`**

- `var sinkFallbacks: Table[string, string]` — maps `sink_config` name to its
  configured fallback name.
- `var runtimeDisabledSinks: HashSet[string]` — names of sinks disabled by
  chalk due to errors (not by user config).
- `proc getFallbackName*(name: string): string` — returns the fallback name, or
  `""` if none.
- `proc isRuntimeDisabled*(name: string): bool` — returns whether the sink was
  disabled by an error.
- `proc hasFallbackCycle(startName, proposed: string): bool` — walks
  `sinkFallbacks` to detect a cycle before registering a new entry.
- In `getSinkConfigByName`, new `of "fallback_sink_config"` case: reads the
  value, runs `hasFallbackCycle`, stores in `sinkFallbacks` if clean, and
  crucially does **not** add the field to `opts` (it is not a parameter for the
  underlying sink implementation).
- In `getSinkConfigByName`, at the two points where `enabled = false` is set
  for file-path errors: add `runtimeDisabledSinks.incl(name)`.
- In `ioErrorHandler`: add `runtimeDisabledSinks.incl(cfg.name)` when
  `not cfg.enabled` (covers hard errors, threshold disables, and file write
  failures). No fallback logic here.

**`src/utils/sink_impls.nim`** — no changes. `onSinkError` continues to set
`cfg.enabled = false` and re-raise; `ioErrorHandler` in `sinks.nim` observes
the result.

**`src/reportcache.nim`**

`tryFallbackChain(primary: SinkConfig, topicName: string, wrappedMsg: string): bool`
(in `sinks.nim`, called from `reportcache.nim`): walks the fallback chain from
`primary`. For each candidate link:

- Skips disabled sinks (enabled = false) and continues to the next link.
- If the candidate is already a live (non-runtime-disabled) subscriber of the
  same topic, it already received the message via the normal publish path —
  returns `true` immediately to avoid double delivery.
- Otherwise, creates a `$fallback$<topic>$<currentName>` temp topic, subscribes
  the candidate, and publishes the pre-wrapped message. `sinkErrors` is
  saved and restored around the publish so fallback failures do not contaminate
  the caller's error state. The temp subscription is cleaned up in a
  `try..finally` block. Returns `true` on first success.

`handleFallbacks(topic: string, msg: string)` (in `reportcache.nim`, called
from `safePublish`):

```
1. Collect candidates (deduplicated by name):
   a. Every sink in sinkErrors that has a fallback configured
      (active failure this publish cycle)
   b. Every subscriber of the topic that isRuntimeDisabled and has a fallback
      (was skipped silently by nimutils publish)
2. Wrap msg as "[ <msg> ]\n" and call tryFallbackChain for each candidate.
3. Remove successfully rescued sinks from sinkErrors.
4. For candidates whose chain was fully exhausted, add them to sinkErrors
   so the report is cached for the next run.
```

`safePublish` call order:

```
tracePublish(topic, msg, successfulPublishes)
handleFallbacks(topic, msg)
if sinkErrors.len != 0 and not cacheReadOnly:
  addSinkErrorsToCache(topic, msg)
```

All fallback logic is confined to `handleFallbacks` and `tryFallbackChain`.
`ioErrorHandler` and `getSinkConfigByName` only record the disable event;
`safePublish` is the single point that acts on it.
