# dockerignore equivalency tests

Verifies that Chalk's Nim `isExcluded()` implementation matches
`moby/patternmatcher.MatchesOrParentMatches()` exactly.

## Structure

| File                  | Purpose                                            |
| --------------------- | -------------------------------------------------- |
| `testcases.json`      | Single source of truth for all test cases          |
| `equivalency_test.go` | Runs cases against the canonical Go implementation |
| `check_nim.nim`       | Runs cases against the Nim implementation          |

`testcases.json` is the only file you need to edit when adding new cases.
Both the Go and Nim runners pick it up automatically.

## Running

**Go (reference implementation):**

```bash
cd tests/equivalency/dockerignore
go test -v ./...
```

**Nim:**

```bash
make unit-tests args="pattern tests/equivalency/dockerignore/check_nim.nim"
```

## Adding a test case

Add an object to `testcases.json`:

```json
{
  "comment": "short human-readable description",
  "patterns": ["pattern1", "pattern2"],
  "path": "some/path",
  "expected": true
}
```

Run both suites to confirm they agree. If the Go test fails, the
`expected` field is wrong -- fix it. If only the Nim test fails, the
Nim implementation diverges from Docker -- fix `src/docker/tar.nim`.
