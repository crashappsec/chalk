# Embedding provenance by hand

Chalk is an open-source tool to cryptographically sign artifacts with
metadata you collect and embed into the artifact at sign-time. The
details differ a bit for each artifact type and for each supported
operating system. For example when Chalk-signing an ELF binary on
Linux, we can shove metadata into sections of the ELF binary that the
operating system will ignore.

The first iteration of Chalk-signing for macOS binaries was a little
different. Unlike on Linux, macOS binaries are usually signed and
tampering with the binary would invalidate its signature.

So we'd base64-encode the binary into a shell script during
signing. The shell script would extract the binary when run. And Chalk
metadata can be safely stored in the shell script.

This was a good, low-risk first step. But Chalk would produce a
completely different-looking file and the execution path would be a
little different compared to an un-Chalk-ed binary.

We recently got around to implementing Mach-O support The Right Way
without the need for shell-script wrappers. We'll walk through how it
works by doing the metadata generation and injection by hand, using
only builtin tools: `cc`, `objcopy`, `codesign`, `otool`, and Python.

But first let's start with how it works on Linux, which is a little
easier to understand.

## Linux setup

Use Apple's [container](https://github.com/apple/container) tool to run a Ubuntu 24.04 VM.

```bash
container run -it --rm --volume "$PWD":/work \
  -e TERM=xterm -e PS1='linux$ ' ubuntu:24.04 bash --norc
```

Then, inside the VM, install the few dependencies we'll need as we try
out Chalk and manually replicate what it's doing.

```bash
apt-get update && apt-get install -y gcc binutils file coreutils jq curl
cd /work
VERSION=$(curl -fsSL https://dl.crashoverride.run/chalk/current-version.txt)
curl -Lo chalk https://dl.crashoverride.run/chalk/chalk-$VERSION-$(uname -s)-$(uname -m)
chmod +x chalk
```

## Chalk-signing a simple program

```bash

```

## Linux: just add a section

An ELF file is a header, some segments the loader maps into memory, and a
section table that mostly exists for tools. The loader only cares about sections
flagged `SHF_ALLOC`. Anything else it ignores completely. So if we add a section
and *don't* mark it allocatable, the program runs as if nothing happened.

```bash
echo '#include #<stdio.h>

int main() {
  printf("hello elf\n");
  return 0;
}' > hello.c
cc hello.c -o hello

# hash the unmarked binary, put the hash *inside* the mark, then add it
SUM=$(sha256sum hello | cut -d' ' -f1)
printf '{"MAGIC":"dadfedabbadabbed","CHALK_ID":"DEMO-ELF","HASH":"%s"}' "$SUM" > mark.json
objcopy --add-section .chalk.mark=mark.json \
        --set-section-flags .chalk.mark=noload,readonly \
        hello hello.fake-chalk
```

Run it:

```
linux$ ./hello
hello elf
linux$ ./hello.fake-chalk
hello elf
```

That's it. The binary still runs, it's still an ELF, and the mark — hash and all
— is sitting there as a first-class section:

```console
linux$ readelf -S hello.fake-chalk | grep -i chalk
  [26] .chalk.mark       PROGBITS         0000000000000000  0001005c
```

And that's exactly what the real `chalk insert` does to the same binary — same
`.chalk.mark` section, same JSON mark:

```console
linux$ cp hello hello.chalk
linux$ ./chalk insert ./hello.chalk
info:  .../hello.chalk: chalk mark successfully added
linux$ readelf -S hello.chalk | grep -i chalk
  [28] .chalk.mark       PROGBITS         0000000000000000  00010ae8
```

The cost is one tiny section. Nothing about an ELF is cryptographically sealed,
so adding bytes invalidates nothing.

### Confirming the hash on read

Here's the nice part. The mark stores the hash of the binary *without* the mark.
So to verify, I strip the section back off — that gives me the exact original
bytes back — and re-hash. If it matches the stored value, nobody touched the
code.

One gotcha reading the mark: don't use `objcopy -O binary --only-section`. That
only emits `SHF_ALLOC` sections, and ours is `noload`, so it prints nothing and
looks like the mark vanished. Use `--dump-section`, which ignores flags.

```console
linux$ # pull the stored hash out of the mark
linux$ STORED=$(objcopy --dump-section .chalk.mark=/dev/stdout hello.fake-chalk | jq -r .HASH)
linux$ # recompute over the binary *minus* the .chalk.mark section
linux$ objcopy --remove-section .chalk.mark hello.fake-chalk recovered
linux$ RECOMPUTED=$(sha256sum recovered | cut -d' ' -f1)
linux$ echo "stored:     $STORED"; echo "recomputed: $RECOMPUTED"
stored:     b46adb10ffc0d623e2b85a999835ef653f3499d785198ac62a39a08c2446e3c2
recomputed: b46adb10ffc0d623e2b85a999835ef653f3499d785198ac62a39a08c2446e3c2
linux$ [ "$STORED" = "$RECOMPUTED" ] && echo OK || echo MISMATCH
OK
```

The reason this works cleanly is that `objcopy --add-section` followed by
`--remove-section` round-trips to byte-identical output (`cmp` agrees), so
"remove the section and re-hash" really does reproduce the original.

Chalk verifies on read the same way — it just stores a *canonical* hash instead
of the raw-file sha:

```console
linux$ objcopy --dump-section .chalk.mark=/dev/stdout hello.chalk | jq -r '.ARTIFACT_TYPE, .HASH'
ELF
e55a72607acedc8b13c945a9380055c13f74475d9258cffbe8d5e945c818218e
```

That `HASH` (`e55a72…`) is **not** the raw-file sha we stored above (`b46adb…`),
and that's deliberate: our by-hand check hashed the raw original for simplicity,
whereas chalk neutralizes the mark section to a fixed 32-byte placeholder and
hashes *that* — exactly the canonicalization we do in full on the Mach-O side.
Both detect tampering; chalk's also survives re-marking with a different-size
mark, which a raw-file sha would not.

And if someone tampers with the code, the stored hash no longer matches —
flipping a single byte in `.text` is enough:

```console
linux$ TOFF=$(readelf -SW hello.fake-chalk | awk '$2==".text"{print $5}')
linux$ printf '\x90' | dd of=hello.fake-chalk bs=1 seek=$((16#$TOFF + 8)) count=1 conv=notrunc 2>/dev/null
linux$ objcopy --remove-section .chalk.mark hello.fake-chalk recovered
linux$ echo "stored:     $(objcopy --dump-section .chalk.mark=/dev/stdout hello.fake-chalk | jq -r .HASH)"
stored:     b46adb10ffc0d623e2b85a999835ef653f3499d785198ac62a39a08c2446e3c2
linux$ echo "recomputed: $(sha256sum recovered | cut -d' ' -f1)"
recomputed: 8d445167c666888bd90e33869c64c6244f17f73e09ba784796a0a8786f5276cd
linux$ # stored != recomputed  ->  tamper detected
```

chalk catches the same thing from the other direction: the `HASH` it records is a
fingerprint of the *code* (mark neutralized), so the original and a one-byte-
modified build get different fingerprints.

```console
linux$ cp hello good && ./chalk insert ./good >/dev/null 2>&1
linux$ objcopy --dump-section .chalk.mark=/dev/stdout good | jq -r .HASH
e55a72607acedc8b13c945a9380055c13f74475d9258cffbe8d5e945c818218e
linux$ cp hello evil
linux$ TOFF=$(readelf -SW evil | awk '$2==".text"{print $5}')
linux$ printf '\x90' | dd of=evil bs=1 seek=$((16#$TOFF + 8)) count=1 conv=notrunc 2>/dev/null
linux$ ./chalk insert ./evil >/dev/null 2>&1
linux$ objcopy --dump-section .chalk.mark=/dev/stdout evil | jq -r .HASH
0089824db7988e559fd615e500e25f17ca5cf1fa2f51d6429b1e5240ad2dbd15
```

So if a deployed binary's fingerprint doesn't match the `HASH` recorded at build
time (in your SBOM), its code was modified. (chalk treats that recorded hash as
immutable provenance — re-marking an already-chalked binary keeps the original
value rather than silently re-stamping it.)

Chalk does all of this in-process rather than shelling out to `objcopy`, but the
shape is identical: append the data, fix up the section table, and the unchalked
hash is computed over the binary with the mark region neutralized. That code
lives in `src/plugins/elf.nim`.

Now the fun part.

## macOS: the signature fights back

Here's the thing about a Mach-O on modern macOS: it carries a code signature
whose entire purpose is to detect that someone changed the file after it was
built. And chalk wants to change the file after it was built. These two facts do
not get along.

Even a plain `cc` build is already signed, because the linker ad-hoc-signs it on
Apple Silicon:

```console
mac$ cc hello.c -o hello
mac$ codesign -dvv hello 2>&1 | grep Signature
Signature=adhoc
mac$ codesign --verify --strict hello && echo ok
ok
```

So whatever I do, I have to come out the other side with a binary that still
passes `codesign --verify --strict`. Keep that command in mind — it's the judge
for everything below.

### The old trick: don't touch it, hide it

Chalk's original macOS codec sidesteps the whole problem. If editing a signed
binary is dangerous, then don't — base64 the entire thing into a shell script
that decodes itself to `/tmp` and re-execs at runtime, and hang the mark off the
end as a comment.

```bash
{
  echo '#!/bin/bash'
  echo 'CMDLOC=/tmp/.chalkcache_$(id -u)_hello; mkdir -p "$(dirname "$CMDLOC")"'
  echo '(base64 -d) > "$CMDLOC" << CHALK_END'
  base64 < hello
  echo 'CHALK_END'
  echo 'chmod +x "$CMDLOC"; exec "$CMDLOC" "$@"'
  echo '# {"MAGIC":"dadfedabbadabbed","CHALK_ID":"DEMO-WRAP"}'
} > hello.wrapped && chmod +x hello.wrapped
```

It works, it runs, you can `tail` the mark right off the end, and it never
touches the original signed bytes so there's nothing to invalidate. It was built
first because it's bulletproof and doesn't require understanding a single byte of
the Mach-O format. But look what it produced:

```console
mac$ file hello.wrapped
hello.wrapped: Bourne-Again shell script text executable
```

It's not a binary anymore. It's a shell script wearing a binary as a costume. It
can't be notarized as itself, it re-extracts to `/tmp` on every launch, and
"executable that base64-decodes itself into /tmp and execs it" is, to put it
gently, exactly what malware does. It's still in the tree as the fallback
(`src/plugins/codecMacOs.nim`) and for some cases it's the only option — but for
the common case we can do better.

### The two obvious shortcuts, both of which lie to you

The naive way to edit in place is the ELF instinct: just append my bytes. Or,
slightly smarter, append and re-sign. Both:

```bash
# A: append to the signed file
cp hello helloA; printf '{"x":1}' >> helloA
./helloA                            # runs fine!
codesign --verify --strict helloA   # helloA: main executable failed strict validation

# B: re-sign on top without stripping first
cp hello helloB; printf '{"x":1}' >> helloB
codesign --force --sign - helloB
codesign --verify --strict helloB   # still: failed strict validation
```

This is the trap. *Both binaries run.* If your test is "does it execute," they
pass. Only `--strict` catches them, with the gloriously unhelpful "failed strict
validation." Ship one of these and Gatekeeper rejects it on someone else's
machine.

Both fail for one structural reason: the signature must be the last thing in the
file and it covers everything before it. Append after it (A) and there's trailing
data the signature doesn't account for. Re-sign without stripping (B) and the
signature can't reach the end because your bytes are where it needs to go.

### The sequence that actually works

The rule basically dictates the algorithm: make the file final *first*, then sign
it, the way a fresh binary is signed.

1. Strip the existing signature.
2. Append the payload at the end of `__LINKEDIT`, and grow the segment so the
   bytes live *inside* it.
3. Insert an `LC_NOTE` load command pointing at the payload.
4. Re-sign. Now the signature lands after everything and covers it.

Steps 1 and 4 are just `codesign`. Steps 2 and 3 are the part no Apple tool will
do for you, so here's the Python. `LC_NOTE` (load command `0x31`) is Apple's
blessed slot for tool metadata: `dyld` ignores it, `strip` keeps it, and
`codesign --strict` tolerates it because it's a *known* load command rather than
mystery bytes.

```bash
cat > insert_note.py <<'PY'
import struct, sys
LC_SEGMENT_64, LC_NOTE, MH_MAGIC_64, PAGE = 0x19, 0x31, 0xfeedfacf, 0x4000
path = sys.argv[1]
payload = (sys.argv[2] if len(sys.argv) > 2 else
           '{"MAGIC":"dadfedabbadabbed","CHALK_ID":"DEMO-NATIVE"}').encode()
data = bytearray(open(path, "rb").read())
magic,_,_,_,ncmds,sizeofcmds,_,_ = struct.unpack_from("<IiiIIIII", data, 0)
assert magic == MH_MAGIC_64, "fat / non-64-bit binaries are refused"

# walk the load commands: find __LINKEDIT and where the first section data starts
off, linkedit_off, first_section_off = 32, None, len(data)
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, off)
    if cmd == LC_SEGMENT_64:
        segname = data[off+8:off+24].split(b"\0")[0]
        nsects  = struct.unpack_from("<I", data, off+64)[0]
        if segname == b"__LINKEDIT": linkedit_off = off
        soff = off + 72
        for _s in range(nsects):
            so = struct.unpack_from("<I", data, soff+48)[0]
            if so: first_section_off = min(first_section_off, so)
            soff += 80
    off += cmdsize

_, le_fileoff, le_filesize = struct.unpack_from("<QQQ", data, linkedit_off+32)
end_of_loadcmds = 32 + sizeofcmds
slack = first_section_off - end_of_loadcmds
print(f"  slack = {slack} bytes")
if slack < 40:
    sys.exit("  REFUSE: <40 bytes of slack -- relink with -Wl,-headerpad,0x1000")

# 2: payload at __LINKEDIT end, 16-byte aligned (matches chalk); grow the segment
end = le_fileoff + le_filesize
assert end == len(data), "strip the signature first"
payload_off = (end + 15) & ~15
data += b"\0" * (payload_off - end)
data += payload
new_filesize = (payload_off - le_fileoff) + len(payload)
new_vmsize   = (new_filesize + PAGE - 1) & ~(PAGE - 1)
struct.pack_into("<QQ", data, linkedit_off+32, new_vmsize, le_fileoff)
struct.pack_into("<Q",  data, linkedit_off+48, new_filesize)

# 3: LC_NOTE into the slack; bump the header's command count + size
note = struct.pack("<II", LC_NOTE, 40) + b"chalk".ljust(16, b"\0") \
     + struct.pack("<QQ", payload_off, len(payload))
data[end_of_loadcmds:end_of_loadcmds+40] = note
struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + 40)
open(path, "wb").write(data)
print(f"  LC_NOTE(chalk) -> payload @ {payload_off}, {len(payload)} bytes")
PY
```

The four steps:

```bash
cp hello hello.fake-chalk
codesign --remove-signature hello.fake-chalk   # 1. strip
python3 insert_note.py hello.fake-chalk        # 2 + 3. append + LC_NOTE
codesign --force --sign - hello.fake-chalk     # 4. re-sign ad-hoc
```

### The slack problem, which I walked straight into

The first time I ran this it "worked," and then the binary was dead:

```console
mac$ python3 insert_note.py hello.fake-chalk
  slack = 48 bytes
  LC_NOTE(chalk) -> payload @ 33024, 53 bytes
mac$ codesign --force --sign - hello.fake-chalk
mac$ codesign --verify --strict hello.fake-chalk
hello.fake-chalk: valid on disk                       # passes!
mac$ ./hello.fake-chalk; echo "exit=$?"
exit=132                                     # ...SIGILL. it's dead.
```

Same flavor of trap, one level deeper: strict validation passes, the binary
crashes. It's that `slack = 48 bytes`. Inserting `LC_NOTE` needs 40 bytes of free
space between the end of the load commands and the first section. I had 48, so my
note fit — but then step 4's `codesign` needs to add its *own*
`LC_CODE_SIGNATURE` command, and only 8 bytes were left. It overran into `__TEXT`
and clobbered the code. The signature is valid; it's just signing garbage.

The slack has to come from *build time*. This is the important bit about how the
real codec works: chalk runs on a finished binary, well after the linker is gone,
so it cannot make room — there's nothing to relink. If the slack isn't there, the
native codec simply **refuses** and the shell-script wrapper handles the file
instead (`chalk_macho.c` returns `cmNoLcSlack`; `codecMacho.nim` warns and defers
to the lower-priority wrapper). So `-Wl,-headerpad,0x1000` is advice for whoever
*compiles* the binary, not something chalk does at mark time — you add it to the
link line so that later, when chalk shows up, the room is already there:

```bash
cc -Wl,-headerpad,0x1000 hello.c -o hello   # ~4 KiB of header padding
```

In this walkthrough I'm wearing both hats — I'm the one building `hello`, so I can
just rebuild it. In a real pipeline the person marking the binary usually isn't
the person who built it, which is exactly why "not enough slack" is a refuse-and-
fall-back case rather than something the codec can fix. Rebuilt with headerpad,
there's plenty of slack:

```console
mac$ python3 insert_note.py hello.fake-chalk
  slack = 4112 bytes
  LC_NOTE(chalk) -> payload @ 33024, 53 bytes
mac$ ./hello.fake-chalk
hello macho
mac$ codesign --verify --strict hello.fake-chalk
hello.fake-chalk: valid on disk
hello.fake-chalk: satisfies its Designated Requirement
mac$ otool -l hello.fake-chalk | grep -A4 LC_NOTE
       cmd LC_NOTE
   cmdsize 40
data_owner chalk
    offset 33024
      size 53
```

That's the payoff. Unlike the wrapper, `file` still says `Mach-O 64-bit
executable`, Apple's own `otool` lists our note as a real load command, and
`--strict` is genuinely happy. This is what `src/plugins/codecMacho.nim` and the
C library under `src/codecs/macho/` do, just without me hand-editing structs.

And here's `chalk insert` doing the identical thing to the same binary — same
`LC_NOTE`, still `--strict`-valid, and `chalk extract` reads it straight back:

```console
mac$ cp hello hello.chalk
mac$ ./chalk insert ./hello.chalk
info:  /tmp/.../hello.chalk: chalk mark successfully added
mac$ file hello.chalk
hello.chalk: Mach-O 64-bit executable arm64
mac$ codesign --verify --strict hello.chalk && echo strict-OK
hello.chalk: valid on disk
strict-OK
mac$ otool -l hello.chalk | grep -A4 LC_NOTE
       cmd LC_NOTE
   cmdsize 40
data_owner chalk
    offset 33024
      size 507
mac$ ./chalk extract ./hello.chalk 2>&1 | grep -o 'Chalk mark extracted'
Chalk mark extracted
```

Same load command, same `data_owner chalk`, same 16-byte-aligned payload offset
(33024). chalk's payload is bigger — 507 bytes of real metadata vs our 53 — but
structurally it's the by-hand insert.

### Confirming the hash on read — why Mach-O can't do what ELF did

On Linux I verified by stripping the section back off and re-hashing the original.
On Mach-O that doesn't work, for two reasons:

1. I had to **strip the original signature** to mark the file, and I can't put it
   back — I don't have Apple's private key, and even ad-hoc re-signing isn't
   byte-reproducible. So "recover the original" is off the table.
2. Inserting the `LC_NOTE` **edited the header and the `__LINKEDIT` segment** in
   place (the command count, the segment sizes, the slack). So even ignoring the
   signature, the non-payload bytes aren't what they were.

So instead of hashing "the original," you hash a **canonical form**: take any
copy, throw away the signature, throw away whatever mark is there, and rewrite it
to one fixed shape — load-command slack zeroed, exactly one `LC_NOTE("chalk")`
whose payload is a fixed **32 zero bytes** (32 because that's a SHA-256 digest).
A binary with a 10-byte mark, a 500-byte mark, or no mark at all all collapse to
the *same* canonical bytes, so the hash is invariant under (re-)marking. That's
chalk's "unchalked hash."

Here's the canonicalizer. It assumes the signature has already been removed (we
do that with `codesign` just before calling it):

```bash
cat > canon_macho.py <<'PY'
# Canonicalize a thin 64-bit Mach-O so that "marked", "remarked with a
# different-size payload", and "unmarked" all produce identical bytes.
# Precondition: signature already removed (codesign --remove-signature).
# Output: canonical bytes on stdout; pipe to `shasum -a 256`.
import struct, sys
LC_SEGMENT_64, LC_NOTE, MH_MAGIC_64, PAGE = 0x19, 0x31, 0xfeedfacf, 0x4000
ZERO_PAYLOAD = 32

data = bytearray(open(sys.argv[1], "rb").read())
magic,_,_,_,ncmds,sizeofcmds,_,_ = struct.unpack_from("<IiiIIIII", data, 0)
assert magic == MH_MAGIC_64, "thin 64-bit only"

def parse():
    off, le_off, first_sec = 32, None, len(data)
    note_off = note_poff = note_psize = None
    n = struct.unpack_from("<I", data, 16)[0]
    for _ in range(n):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            seg = data[off+8:off+24].split(b"\0")[0]
            ns  = struct.unpack_from("<I", data, off+64)[0]
            if seg == b"__LINKEDIT": le_off = off
            so = off + 72
            for _s in range(ns):
                o = struct.unpack_from("<I", data, so+48)[0]
                if o: first_sec = min(first_sec, o)
                so += 80
        elif cmd == LC_NOTE and data[off+8:off+24].split(b"\0")[0] == b"chalk":
            note_off = off
            note_poff, note_psize = struct.unpack_from("<QQ", data, off+24)
        off += cmdsize
    return le_off, first_sec, note_off, note_poff, note_psize

# 1. If a chalk note is already present (always the last load command, in slack),
#    strip it and its payload so we're back to a clean base.
le_off, first_sec, note_off, note_poff, note_psize = parse()
if note_off is not None:
    # drop our payload AND any alignment padding codesign added after it
    _, le_fileoff, _ = struct.unpack_from("<QQQ", data, le_off+32)
    del data[note_poff:]
    struct.pack_into("<Q", data, le_off+48, note_poff - le_fileoff)   # filesize
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    struct.pack_into("<II", data, 16, ncmds - 1, sizeofcmds - 40)

# re-parse the now-clean base
le_off, first_sec, *_ = parse()
_, le_fileoff, le_filesize = struct.unpack_from("<QQQ", data, le_off+32)
ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
end_of_loadcmds = 32 + sizeofcmds

# 2. Zero the load-command slack so stale bytes (e.g. a removed LC_CODE_SIGNATURE)
#    can't perturb the hash.
for i in range(end_of_loadcmds, first_sec):
    data[i] = 0

# 3. Append a canonical 32-zero payload (16-byte aligned, like chalk) + LC_NOTE.
end = le_fileoff + le_filesize
payload_off = (end + 15) & ~15
data += b"\0" * (payload_off - end)
data += b"\0" * ZERO_PAYLOAD
new_filesize = (payload_off - le_fileoff) + ZERO_PAYLOAD
struct.pack_into("<QQ", data, le_off+32, (new_filesize + PAGE-1) & ~(PAGE-1), le_fileoff)
struct.pack_into("<Q",  data, le_off+48, new_filesize)
note = struct.pack("<II", LC_NOTE, 40) + b"chalk".ljust(16, b"\0") \
     + struct.pack("<QQ", payload_off, ZERO_PAYLOAD)
data[end_of_loadcmds:end_of_loadcmds+40] = note
struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + 40)

sys.stdout.buffer.write(data)
PY
```

And a one-liner to read the stored hash back out of the note:

```bash
cat > read_hash.py <<'PY'
import struct, json, sys
d = open(sys.argv[1], "rb").read()
n = struct.unpack_from("<I", d, 16)[0]; o = 32
for _ in range(n):
    c, cs = struct.unpack_from("<II", d, o)
    if c == 0x31 and d[o+8:o+24].split(b"\0")[0] == b"chalk":
        off, sz = struct.unpack_from("<QQ", d, o+24)
        print(json.loads(d[off:off+sz])["HASH"]); break
    o += cs
PY
```

A small helper that computes a binary's canonical hash (strip sig, canonicalize,
SHA-256):

```bash
canon_hash () { cp "$1" /tmp/_c; codesign --remove-signature /tmp/_c 2>/dev/null
                python3 canon_macho.py /tmp/_c | shasum -a 256 | cut -d' ' -f1; }
```

**Write** — compute the canonical hash of the base binary, embed it, mark, sign:

```bash
cp hello base; codesign --remove-signature base 2>/dev/null
H=$(python3 canon_macho.py base | shasum -a 256 | cut -d' ' -f1)

cp hello hello.fake-chalk; codesign --remove-signature hello.fake-chalk 2>/dev/null
python3 insert_note.py hello.fake-chalk \
  "{\"MAGIC\":\"dadfedabbadabbed\",\"CHALK_ID\":\"DEMO\",\"HASH\":\"$H\"}" >/dev/null
codesign --force --sign - hello.fake-chalk
```

There's no chicken-and-egg here: the canonical hash zeroes the payload, so it
doesn't depend on what we're about to write into the payload.

**Read** — recompute the canonical hash and compare to the stored one:

```console
mac$ echo "stored:     $(python3 read_hash.py hello.fake-chalk)"
stored:     aee3b2cbd3aa700a5f049e37c4ff47275f4df2f4c31f9f4e1575adc988398133
mac$ echo "recomputed: $(canon_hash hello.fake-chalk)"
recomputed: aee3b2cbd3aa700a5f049e37c4ff47275f4df2f4c31f9f4e1575adc988398133
```

And here's the real payoff against chalk: the `HASH` chalk baked into
`hello.chalk` up in the insert step is the *same* canonical hash — `canon_macho.py`
reproduces what chalk stored, byte for byte:

```console
mac$ python3 read_hash.py hello.chalk     # the HASH chalk stored
aee3b2cbd3aa700a5f049e37c4ff47275f4df2f4c31f9f4e1575adc988398133
mac$ canon_hash hello.chalk               # our by-hand canonical hash
aee3b2cbd3aa700a5f049e37c4ff47275f4df2f4c31f9f4e1575adc988398133
```

The size-invariance is real — mark the same binary with a tiny payload and a
400-byte payload and the canonical hash is identical:

```console
mac$ cp hello m_small; codesign --remove-signature m_small 2>/dev/null
mac$ python3 insert_note.py m_small '{"id":1}' >/dev/null; codesign -f -s - m_small 2>/dev/null
mac$ cp hello m_big;   codesign --remove-signature m_big 2>/dev/null
mac$ python3 insert_note.py m_big "{\"id\":2,\"pad\":\"$(printf 'A%.0s' {1..400})\"}" >/dev/null
mac$ codesign -f -s - m_big 2>/dev/null
mac$ echo "tiny: $(canon_hash m_small)"; echo "huge: $(canon_hash m_big)"
tiny: aee3b2cbd3aa700a5f049e37c4ff47275f4df2f4c31f9f4e1575adc988398133
huge: aee3b2cbd3aa700a5f049e37c4ff47275f4df2f4c31f9f4e1575adc988398133
```

And tamper detection holds even when the attacker re-signs to look legit — flip
one byte of `__text`, re-sign ad-hoc, and the canonical hash no longer matches
the one baked into the mark:

```console
mac$ cp hello.fake-chalk tampered
mac$ TOFF=$(otool -l tampered | awk '/sectname __text/{f=1} f&&/offset/{print $2; exit}')
mac$ python3 -c "d=bytearray(open('tampered','rb').read()); d[$TOFF+8]^=0xff; open('tampered','wb').write(d)"
mac$ codesign -f -s - tampered 2>/dev/null    # attacker re-signs
mac$ echo "stored:     $(python3 read_hash.py tampered)"
stored:     aee3b2cbd3aa700a5f049e37c4ff47275f4df2f4c31f9f4e1575adc988398133
mac$ echo "recomputed: $(canon_hash tampered)"
recomputed: d3cfbd20e05decdbf89a4da5169f3d85f429afcef42c306d880399f187f93aa9
mac$ # stored != recomputed  ->  tamper detected
```

chalk catches it identically — and lands on the *exact same* tampered fingerprint
our canonicalizer did:

```console
mac$ cp hello good && ./chalk insert ./good >/dev/null 2>&1
mac$ python3 read_hash.py good
aee3b2cbd3aa700a5f049e37c4ff47275f4df2f4c31f9f4e1575adc988398133
mac$ cp hello evil
mac$ TOFF=$(otool -l evil | awk '/sectname __text/{f=1} f&&/offset/{print $2; exit}')
mac$ python3 -c "d=bytearray(open('evil','rb').read()); d[$TOFF+8]^=0xff; open('evil','wb').write(d)"
mac$ codesign -f -s - evil 2>/dev/null
mac$ ./chalk insert ./evil >/dev/null 2>&1
mac$ python3 read_hash.py evil
d3cfbd20e05decdbf89a4da5169f3d85f429afcef42c306d880399f187f93aa9
```

`d3cfbd20…` is the same value `canon_macho.py` produced for the tampered binary
above — chalk's recorded fingerprint *is* the unchalked hash we built by hand,
and it's what flags a modified binary against the hash in your SBOM.

This is exactly `chalk_macho_unchalked_hash` in `src/codecs/macho/`, and its ELF
twin `unchalk` in `src/plugins/elf.nim` — same idea, neutralize the mark to a
fixed canonical form and hash that.

## So why is one of these so much worse than the other

| | Linux / ELF | macOS / Mach-O |
| --- | --- | --- |
| Where the mark lives | a `noload` section | `LC_NOTE` + payload at `__LINKEDIT` end |
| Loader ignores it? | yes (not `SHF_ALLOC`) | yes (`dyld` skips `LC_NOTE`) |
| Signing in the way? | no | yes, and it's tamper-evident on purpose |
| Steps to add a mark | 1 | 4 (strip → append → note → re-sign) |
| One tool does it? | yes, `objcopy` | no, `codesign` won't insert a load command |
| Layout gotcha | none | 40 bytes of load-command slack |
| "Runs but invalid"? | n/a | yes, twice (bad append, and the slack trap) |
| Verify the hash by... | remove the section, re-hash the original | canonicalize (can't recover the original) |

The one-sentence version: on Linux a chalk mark is just a section the loader was
always going to ignore, and you verify by removing it and re-hashing the
original; on macOS the mark has to be a real `LC_NOTE` spliced in with the one
sequence the code-signing toolchain will bless, and because you can't put the
original signature back, you verify against a canonical form instead. The wrapper
existed first because it dodged all of that. The native codec exists because
dodging it meant shipping a shell script instead of a binary.
