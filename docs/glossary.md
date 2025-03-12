# Chalk Glossary

<!-- toc -->

- [Artifact](#artifact)
- [Chalk Mark](#chalk-mark)
- [Unchalked](#unchalked)
- [Metadata Key](#metadata-key)
  - [Chalkable keys](#chalkable-keys)
  - [Non-chalkable keys](#non-chalkable-keys)
- [Chalking](#chalking)
- [Extraction](#extraction)
- [Report](#report)
- [Report Template](#report-template)
- [Mark Template](#mark-template)
- [Sinks](#sinks)
- [Chalk ID](#chalk-id)
- [Metadata ID](#metadata-id)

<!-- tocstop -->

## Artifact

Any software artifact handled by Chalk, which can recursively include other
artifacts. For instance, a Zip file is an artifact type that can currently be
chalked, which can contain ELF executables that can also be chalked.

## Chalk Mark

JSON containing metadata about a software artifact, generally inserted directly
into the artifact in a way that doesn’t affect execution. Often, a chalk mark
will be minimal, containing only small bits of identifying information that can
be used to correlate the artifact with other metadata collected.

## Unchalked

A software artifact that does not have a chalk mark embedded in it.

## Metadata Key

Each piece of metadata Chalk is able to collect (metadata being data about
an artifact or a host on which an artifact has been found) is associated
with a metadata key. Chalk reports all metadata in JSon key/value pairs, and
you specify what gets added to a chalk mark and what gets reported on by
listing the metadata keys you’re interested in via the report template and mark
template.

### Chalkable keys

Metadata keys that can be added to chalk marks. When reported for a chalked
artifact (e.g., during extraction in production), they will always indicated
metadata collected when the artifact was being chalked.

### Non-chalkable keys

Metadata keys that will NOT be added to chalk marks. They will always be
reported for the current operation, and start with a `_`. There are plenty of
metadata keys that have chalkable and non-chalkable versions.

## Chalking

The act of adding metadata to a software artifact. Aka, “insertion”.

## Extraction

The act of reading metadata from artifacts and reporting on them.

## Report

Every time Chalk runs, it will want to report on its activity. That can include
information about artifacts, and also about the host. Reports are “published”
to output “sinks”. By default, you’ll get reports output to the console, and
written to a local log file, but can easily set up API post or writing to
object storage either by supplying environment variables, or by editing the
Chalk configuration.

## Report Template

You have complete flexibility over what goes into chalk reports. A report
template is a specification of what metadata keys that you want to report on.
They’re used to configure reports, and also to configure things like which
metadata items should be automatically added to a container as labels.

## Mark Template

Like report templates, you have complete flexibility over what goes into chalk
marks. A mark template is a specification of what metadata keys that you want
to go into the chalk mark.

## Sinks

Destination for a Chalk report. Currently, chalk supports:

- stdin/stdout
- JSON log file
- rotating (self-truncating) JSON log file
- S3 objects
- API post
- Presign - API returns S3-style presigned redirect where to upload report

## Chalk ID

A value unique to an unchalked artifact. Usually, it is derived from the
SHA-256 hash of the unchalked artifact, except when that hash is not available
at chalking time, in which case, it’s random. Chalk IDs are 100 bits, and human
readable (Base32).

## Metadata ID

A value unique to a chalked artifact. It is always derived from a normalized
hash of all other metadata (except for any metadata keys involved in signing
the Metadata ID). Metadata IDs are also 100 bits, and Base32 encoded.
