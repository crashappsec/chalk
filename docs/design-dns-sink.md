# Design: DNS Sink

This document describes the design and intent behind the `dns` sink type,
including the motivation, key decisions made during implementation, and the
shared infrastructure it introduces.

## Motivation

Enterprise networks commonly enforce egress policies that block outbound
HTTPS connections to unknown destinations, either via TLS inspection or
domain blocklists. These policies prevent chalk from sending telemetry
over conventional HTTP/HTTPS sinks to arbitrary endpoints.

DNS traffic is rarely blocked at the same granularity: resolvers are
whitelisted by infrastructure teams and DNSSEC/DoT is the exception rather
than the rule. This makes DNS lookups a practical out-of-band channel for
emitting lightweight, structured metadata about chalk operations — enough
to confirm that a binary was chalked, or that an exec heartbeat fired,
without relying on TCP or TLS connectivity.

The `dns` sink makes one DNS lookup per report. The response is discarded.
The hostname itself carries the payload: chalk keys are substituted into a
configurable domain template, and the DNS lookup encodes the resulting
labels in-flight through the resolver hierarchy to the authoritative
nameserver, where they can be logged.

## Configuration

```con4m
sink_config my_dns_beacon {
  sink:                    "dns"
  domain_template:         "{METADATA_ID}.{_EXEC_ID}.chalk.example.com"
  record_type:             "A"
  missing_key_placeholder: "x"
  require_chalk_mark:      true
  disable_after_errors:    3
}

subscribe("report", "my_dns_beacon")
```

**Fields:**

| Field                     | Type     | Required | Default | Description                                                                                                                                         |
| ------------------------- | -------- | -------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `domain_template`         | `string` | true     | -       | Hostname template. `{KEY}` placeholders are replaced with values from the report.                                                                   |
| `record_type`             | `string` | false    | `"A"`   | DNS record type to query. Accepted values: `"A"`, `"AAAA"`, `"any"` (see below).                                                                    |
| `missing_key_placeholder` | `string` | false    | `"x"`   | Value substituted when a `{KEY}` placeholder cannot be resolved (see below).                                                                        |
| `dns_server`              | `string` | false    | `""`    | Custom resolver address: `"8.8.8.8"`, `"8.8.8.8:5353"`, `"[::1]:5353"`. When empty, the system resolver is used.                                    |
| `dns_timeout`             | `int`    | false    | `5000`  | Timeout in milliseconds for custom resolver queries. Has no effect when `dns_server` is empty.                                                      |
| `require_chalk_mark`      | `bool`   | false    | `false` | When `true`, skip emission entirely if the report contains no chalk marks. When `false`, fall back to a single lookup using report-level keys only. |
| `disable_after_errors`    | `int`    | false    | `3`     | Number of consecutive lookup failures before the sink is permanently disabled.                                                                      |

## Template Substitution

### Syntax

Placeholders use the `{KEY_NAME}` format, consistent with how docker push
tag templates work in Chalk (e.g. `tags: ["{BRANCH}-latest"]`). Key names
are case-insensitive: `{exec_id}`, `{EXEC_ID}`, and `{Exec_Id}` all resolve
to the same key.

### Lookup order

The sink emits one DNS lookup per chalk mark in `_CHALKS`. For each mark,
key lookup proceeds in this order:

1. Top-level report fields (host-level keys, e.g. `_OPERATION`, `_EXEC_ID`,
   `_TIMESTAMP`).
2. The current chalk mark's fields (chalk-time keys, e.g. `METADATA_ID`,
   `CHALK_ID`, `HASH`).

When `_CHALKS` is absent or empty the sink falls back to a single lookup
using only report-level keys (chalk-time keys will resolve to the placeholder).
Set `require_chalk_mark: true` to suppress this fallback and skip emission
entirely when no marks are present.

Both sources are extracted by parsing the JSON report string passed to the
sink output function. The report string is a JSON array `[ { ... } ]`
containing a single object; the sink unwraps `[0]` before key lookup.

### Missing and non-scalar keys

If a key is not found in either source, or its value is an array or object
(not a scalar), the placeholder is replaced with the value of
`missing_key_placeholder` (default `"x"`). This guarantees that the rendered
hostname is always syntactically valid — every label contains at least one
valid character — regardless of what keys the template references or what data
was collected for a particular operation.

When a key is not found, the sink also emits a `warn`-level log message
identifying the sink config name, the missing key, and the placeholder that
was substituted. This makes misconfigured templates immediately visible in
chalk's trace output without failing the lookup.

**Design decision:** The hardcoded default `"x"` ensures a valid DNS label
even when the user has not set `missing_key_placeholder`. An empty string
would produce consecutive dots and an invalid hostname; raising an error would
silently drop the report. Users who want a more recognizable sentinel (e.g.
`"unknown"` or `"0"`) can set `missing_key_placeholder` explicitly.
Users are expected to craft templates that only reference keys that will be
collected for the operations they subscribe to; the placeholder is a safety
valve, not an invitation to use arbitrary key names.

### Key normalization

Each `sink_config` can include `normalize.KEYNAME.callback` subsections to
transform a key's string value before it is substituted into the template.
This is the primary mechanism for handling values that may exceed the 63-character
DNS label limit (e.g. SHA-256 commit IDs):

```con4m
func trunc16(v: string) {
  return slice(v, 0, 16)
}

sink_config my_dns {
  sink:            "dns"
  domain_template: "{_COMMIT_ID}.{METADATA_ID}.chalk.example.com"
  dns_server:      "10.0.0.1"
  normalize _COMMIT_ID {
    callback: func trunc16
  }
}
```

The `callback` field type is `func(`x) -> `y` — a generic function that
receives the raw Box value of the key (a string, int, float, or bool as
stored in the report) and returns a Box of any type. The returned Box is
stringified with `$box` for DNS label substitution, which for scalar types
gives the natural string representation: no quoting for strings, plain
integer decimal for ints, `true`/`false` for bools, and a float with
a decimal point for floats. Float values will always contain a `.` in the
DNS label; add a normalize callback to strip it if needed.

If the callback raises or returns no value, the key's original string
representation is used and a `warn` is emitted.

Normalization is applied after key lookup but before the placeholder fallback:
if the key is not found, the placeholder is substituted directly without
calling the normalizer. Non-scalar key values (arrays, objects) that cannot
be converted to a Box are also substituted with the placeholder.

The callback for each key is fetched on demand from the con4m attribute store
(`sink_config.<name>.normalize.<key>.callback`) via `attrGetOpt[CallbackObj]`
at the point of substitution — only for keys that actually appear in the
template, avoiding unnecessary config traversal.

**Design decision:** Normalization lives in `sink_config`, not in the keyspec
or report template, because it is a property of how a specific sink renders
values — not a property of the key itself. Different DNS sinks targeting
different backends may need different truncation strategies for the same key.

### Hostname sanitization

The sink does not perform additional sanitization beyond the `"x"` fallback
and any user-supplied `normalize` callbacks. If a key value (after normalization)
contains characters that are invalid in a DNS label (e.g. underscores in
some strict resolver configurations), the resulting lookup will simply fail
and count toward the error threshold. Users are responsible for selecting
keys whose rendered values produce DNS-safe labels. Keys that are likely to
contain only alphanumeric characters and hyphens (such as `METADATA_ID`,
`CHALK_ID`, hash values, and ID-format strings) are the most reliable choices.

## Template Substitution Engine

Template substitution was previously only used for docker push tag rendering
in `src/docker/util.nim`. To share the same `{KEY}` parser with the DNS sink
(and any future sinks), the generic engine was extracted to
`src/utils/substitutions.nim`.

```nim
proc applySubstitutions*(s: string, lookup: proc(key: string): string): string
```

The function takes a format string and a caller-supplied lookup callback. Each
`{KEY}` token is extracted, uppercased, and passed to `lookup`; the return
value is spliced into the result. Malformed brace sequences (e.g. `{{`, or `}`
without a preceding `{`) raise `ValueError`.

The docker tag wrapper in `src/docker/util.nim` remains unchanged for callers:

```nim
proc applySubstitutions*(s: string, chalk: ChalkObj): string =
  s.applySubstitutions(proc(key: string): string = chalk.getChalkKey(key))
```

The DNS sink supplies its own callback that reads from parsed JSON instead of
from a `ChalkObj`:

```nim
proc dnsSinkLookup(
  key:         string,
  report:      JsonNode,
  placeholder: string,
  cfgName:     string,
): string
```

The `cfgName` parameter is the sink config name used in warning messages when
a key is not found and for dynamic callback lookup: `applyDnsNormalizer` fetches
the con4m callback for each key on demand via `attrGetOpt[CallbackObj]` at the
path `sink_config.<cfgName>.normalize.<key>.callback`, so only keys that actually
appear in the template are looked up.

**Design decision:** Making the callback the extension point (rather than, say,
a method on an interface type) keeps the engine simple and avoids any object
hierarchy. Nim closures capture the lookup context naturally.

## DNS Lookup Mechanism

All DNS logic lives in `src/utils/dns.nim`. The public API is a single
procedure:

```nim
proc dnsLookup*(
    domain:    string,
    server:    string   = "",
    qtype:     DnsQtype = DnsQtype.A,
    timeoutMs: int      = 5000,
)
```

`dnsLookup` validates and IDNA-encodes the hostname (see below), then
dispatches to one of two backends depending on whether `server` is set.

### System resolver (`server = ""`)

When no custom server is configured, `dnsLookup` calls POSIX `getaddrinfo`.
This is a blocking OS resolver call that respects `/etc/resolv.conf`,
search domains, and the system's NDots setting. The response is freed
immediately with `freeAddrInfo` and otherwise ignored.

The `ai_family` hint passed to `getaddrinfo` is derived from `qtype`:

| `record_type` | `DnsQtype`  | `ai_family` | Description                  |
| ------------- | ----------- | ----------- | ---------------------------- |
| `"A"`         | `A = 1`     | `AF_INET`   | IPv4 A record (default)      |
| `"AAAA"`      | `AAAA = 28` | `AF_INET6`  | IPv6 AAAA record             |
| `"any"`       | `ANY = 255` | `AF_UNSPEC` | Resolver chooses (A or AAAA) |

**Design decision:** `getaddrinfo` is the lowest-level portable DNS resolution
primitive in the standard library. It requires no socket management, no event
loop, and no threads. Its limitation — the OS resolver timeout cannot be
overridden — is acceptable when no custom server is configured, because the
system resolver is typically local and fast.

### Custom resolver (`server != ""`)

When `dns_server` is set, `dnsLookup` sends a raw UDP DNS query (RFC 1035)
directly to the specified address and port, bypassing the system resolver
entirely. This allows targeting a specific recursive resolver not listed in
`/etc/resolv.conf`, useful for directing beacons toward a controlled
authoritative server.

The query is a standard A/AAAA/ANY question with the Recursion Desired bit
set. Each query uses a cryptographically random 16-bit transaction ID
(`secureRand[uint16]()`). The response is inspected for the transaction ID
(bytes 0-1) and the RCODE field (bits 0-3 of byte 3); a non-zero RCODE raises
`IOError`. The response payload is otherwise discarded.

Source filtering is delegated to the kernel: `connect()` is called on the UDP
socket before sending, which causes the kernel to discard datagrams not
originating from the configured resolver address and port. This works
correctly whether `dns_server` is an IP address or a hostname. For literal IP
addresses `parseIpAddress` determines the socket family without a resolver
call; for hostnames `getaddrinfo` is used.

A `select`-based timeout is applied before each `recv` call. If no response
arrives within `timeoutMs` milliseconds, `IOError` is raised with a `"timed
out"` message, which the sink counts as a soft error toward the
`disable_after_errors` threshold.

### Server address parsing

`dns_server` is parsed by `parseServerPort`, which accepts:

- `"8.8.8.8"` — IPv4, default port 53
- `"8.8.8.8:5353"` — IPv4 with explicit port
- `"[::1]"` — bracketed IPv6, default port 53
- `"[::1]:5353"` — bracketed IPv6 with explicit port
- `"::1"` or `"2001:db8::1"` — bare IPv6 (brackets optional), default port 53

Parsing delegates to Nim's `std/uri.parseUri("dns://" & server)`. Bare IPv6
addresses are not valid URI syntax, so `parseUri` misparses them (splitting on
the last `:` gives a truncated hostname and a non-numeric port fragment).
This mismatch is detected by a round-trip check: if
`hostname + ":" + port != server`, the parse was malformed and the whole string
is used as the hostname with the default port.

### Record type validation

`record_type` is validated in the `sink_config_check` function in
`chalk.c42spec`. Invalid values (e.g. `"CNAME"`, `"TXT"`) are rejected at
config load time, before any DNS lookup is attempted:

```c4m
elif conffield == "record_type" {
  v := attr_get(path + "." + conffield, string)
  if not contains(["A", "AAAA", "any"], v) {
    return (conffield + ": must be one of \"A\", \"AAAA\", or \"any\" (got: \"" + v + "\")")
  }
}
```

**Design decision:** Most authoritative DNS logging infrastructure is built
around A record queries. `"A"` is the default because it is the most
universally supported record type and the most common target for DNS-based
telemetry pipelines. Record types that cannot be meaningfully sent as a query
hostname (e.g. `CNAME`, `TXT`, `MX`) are excluded entirely rather than
silently ignored at runtime.

## Hostname Validation and IDNA Encoding

Before any lookup is attempted, `dnsLookup` calls `toAsciiDomain`, which:

1. Splits the hostname on `.`.
2. For each label, checks whether it is pure ASCII. Non-ASCII labels are
   Punycode-encoded (RFC 3492) and prefixed with `xn--` (IDNA 2003).
3. Validates that each encoded label is at most 63 characters and the full
   name is at most 253 characters (RFC 1035 wire-format limit minus the
   root null byte).

`ValueError` is raised before any socket is opened if the hostname is invalid.
This means template rendering errors that produce an oversized label are caught
early and counted as a lookup failure toward `disable_after_errors`.

The Punycode encoder (`punycodeEncode` in `src/utils/dns.nim`) is implemented
from scratch per RFC 3492, since Nim's standard library has no IDNA support.
It is tested against all 18 reference strings from RFC 3492 Section 7.1.

## Error Handling

DNS lookup failures are treated as soft errors. They are counted in the
shared `sinkConsecFailures` table (keyed by sink config name) using the same
mechanism as the HTTP sinks. When consecutive failures reach the
`disable_after_errors` threshold, the sink sets `cfg.enabled = false` and
logs an error.

**Design decision:** All DNS errors are soft (threshold-based) rather than
distinguishing hard vs. soft as the HTTP sinks do. HTTP sinks classify 4xx
responses as hard errors (immediate disable) because they indicate a
configuration problem. DNS has no equivalent — a lookup failure could be
transient (SERVFAIL, NXDOMAIN for a typo, network blip) or permanent (bad
template rendering a malformed name), and there is no status code to
distinguish them. The threshold approach ensures transient failures do not
permanently disable the sink while repeated failures still trigger the
disable.

Successful lookups reset the counter via `resetSinkFailures(cfg)`, consistent
with the other network sinks.

## Interaction with Per-Chalk Reporting

The DNS sink iterates `_CHALKS` internally and emits one lookup per mark,
so it handles multi-mark reports naturally regardless of whether per-chalk
mode is enabled.

When `per_chalk_reports: true` is set on the `outconf` section (or
`per_chalk: true` on a `custom_report` section), the reporting pipeline emits
one report per chalk mark. Combined with the sink's internal iteration, this
means one lookup is emitted per mark — the same result as without per-chalk
mode — but each report is smaller and the sink processes exactly one mark at
a time rather than iterating a bundle.

## Source Locations

| Path                          | Role                                                                               |
| ----------------------------- | ---------------------------------------------------------------------------------- |
| `src/utils/dns.nim`           | `dnsLookup`, Punycode encoder, IDNA validation, server address parsing             |
| `src/utils/substitutions.nim` | Generic `{KEY}` template engine; callback-based lookup                             |
| `src/docker/util.nim`         | Thin `applySubstitutions(s, ChalkObj)` wrapper over the generic engine             |
| `src/utils/sink_impls.nim`    | `dnsSinkOut`, `dnsSinkLookup`, `applyDnsNormalizer`, `addDnsSink`                  |
| `src/configs/base_sinks.c4m`  | `sink dns { ... }` — con4m schema for DNS sink parameters                          |
| `src/configs/chalk.c42spec`   | `object normalize` — per-key callback spec; `sink_config_check` — field validation |
| `src/sinks.nim`               | `getSinkConfigByName` — int param handling for `dns_timeout`                       |
| `tests/unit/test_dns.nim`     | Unit tests: Punycode (RFC 3492 vectors), IDNA, server parsing, lookup errors       |
