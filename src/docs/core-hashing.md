# IDs and Hashing in Chalk

Chalk uses cryptographic hashing (SHA-256) to help uniquely identify
artifacts. Key to this is the concept of the *Chalk Hash*, which is a
normalized hash of an artifact, without a chalk mark inserted.

The normalized hash is generally used to create the `CHALK_ID`
field. Additionally, chalk validates the integrity of the metadata
fields in a chalk mark with the `METADATA_ID` field.

Two artifacts with the same `CHALK_ID` should be the same core
artifact. But, if the same set of bits were marked multiple times in
multiple ways, they will produce different `METADATA_ID`s.

There are important things to understand about the system:

1. The Chalk hash may not always be the same as what you'd get from
hashing the bits on disk.

2. Chalking of docker images and docker containers cannot currently
work the same way.

3. Digital Signatures using the In-Toto standard are available across
all artifact times to provide some additional assurance to those who
want it.

In this document, we explain the trade-offs, and look at how to handle
related use cases with Chalk.

## Chalk-internal IDs and Hashes

It's not sufficient to compare hashes of fully chalked artifacts for
identity. Even if all other bits are the same, if two artifacts aren't
identically chalked, they'll end up giving different hashes.

Of course, once metadata is added, it's can be valuable to understand
when an artifact's metadata seems to have been tampered with.

As a result, Chalk uses two identifiers:

- The `CHALK_ID` field usually allows you to compare the equality of
  two different artifacts, in a way that is not in any way dependent
  on the contents of the chalk mark. This field has some subtleties
  that are important to understand.

- The `METADATA_ID` field is 100% dependent on the contents of both
  the executable and the Chalk mark added to the executable. It is
  much more straightforward, and consistent across all artifact types.

### The Chalk Hash

One challenge Chalk IDs have to solve, is that we might be asked to
Chalk artifacts that are already chalked! Therefore, just using the
hash of files on disk is not good enough.

In some cases we can solve that by removing the chalk mark before
hashing (or computing as if the mark were removed, anyway). However,
that overcomplicates life for complex file formats, where being able
to recover the exact unchalked state can require significant
additional complexity and / or storage.

For instance, consider ZIP files. The file format has some
complexities, with multiple versions, and internal bits that can be
different from implementation to implementation.

And, we use a third-party library to both read data out of a ZIP file,
and reassemble the ZIP file.

It would be a tremendous amount of additional work to be able to
guarantee that, if we're removing a mark from a Zip file, the
resulting bits would be the exact same bits that were there before the
current mark was inserted (well, we could do it easily by keeping a
full second copy of the artifact, but doubling the size we don't find
reasonable).

Similarly, while our ELF codec does not use third party libraries, the
transformations we make don't necessarily have a single inverse they
map to. For instance, ELF binaries can keep the "section table"
basically anywhere in the binary, but much like the Unix `strip`
command, for the sake of simplicity and correctness, we move the
section table to the back of the binary. Moreover, it would take
significant additional work and require some storage to make this
operation invertable.

As a result, the Chalk Hash (the `HASH` metadata key), is not defined
based on the file system hash. Instead, it is a *normalized* hash,
meaning it should be a deterministic hash where the exact same input
will always give the same output.

However, the hash function isn't required to be based on being able to
reverse our transformations and recover the original file system
bits. Instead, We ensure that, if you calculate the Chalk Hash without
physically marking the file, it gives the same result as when you do
mark the file and calculate the results. Also, we ensure that deleting
a chalk mark and re-adding it always gives the same results.

To be clear, every bit of the content, after the normalization
process, that is not part of the chalk mark must be
authenticated. And, we require that any normalization process where
two artifacts give the same normalized input stream, then the two
artifacts must be semantically identical.

### More on The Chalk ID

Once an artifact has been normalized, and the normalizated data stream
has been hashed using SHA-256, we programiatically take 100 bits of
the raw hash output, base-32 encode those bits, and then add some
hyphens for clarity, to get the `CHALK_ID`.

Being 100 bits, the ID has enough cryptographic strength to ensure
integrity, and therefore, can usually be considered a more
human-readable version of the Chalk hash.

As a result, `CHALK_ID` is a required field in Chalk marks, whereas
the `HASH` field is not. When validating an artifact via `CHALK_ID`,
we re-normalize, and re-compute the Chalk hash, and then compare to
what's stored inside the Chalk mark. if the two IDs do not match, then
we know that the bits inside the artifact have changed, and Chalk
complains.

### The Docker exception

### Understanding the Metadata ID

## Doing file-system level comparisons.



2. The


adds a data section to executables, which
we want to do in a way that is as obviously correct as possible. To
that end, we always end up moving the section table to the





