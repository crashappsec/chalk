---
title: Metadata Reference
description:
---

<table><colgroup><col width=20 /><col width=20 /><col width=20 /><col width=40 /></colgroup><thead><tr><th>Key</th><th>Collection Type</th><th>Value Type</th><th>Description</th></tr></thead><tbody><tr><td>MAGIC</td><td>Chalk-Time, Host</td><td>string</td><td><p>This key must appear as the first item in all chalk marks, and the
value cannot be changed. It is used to identify the beginning of a
chalk mark. While JSON objects typically do not support ordered keys,
we still require conforming marks to put this one first.</p>
<p>The chalk mark itself may be embedded in various ways, depending on
the artifact type. Still, this key is used to help ease detection.</p>
<p>This key should generally never be reported, as it is redundant to do so.</p>
</td></tr><tr><td>CHALK_VERSION</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This represents the Chalk version used at the time of the insertion of
the Chalk mark. This must be added to each Chalk mark, to help ensure
compatibility with future versions.</p>
</td></tr><tr><td>DATE_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>This gives a readable date that the chalk operation occurred, in the
local time zone set for the machine where the marking happened.</p>
<p>This field does <em>not</em> include the time of the marking. For that, you
can add the <code>TIME_CHALKED</code> key, use the <code>DATETIME_WHEN_CHALKED</code> key,
or use the <code>TIMESTAMP_WHEN_CHALKED</code> key.</p>
</td></tr><tr><td>TIME_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>This is a string indicating the time of the chalk operation, in human
readable format, given in the local time zone of the machine on which
the chalk operation occurred. This only has one value per run-- when
chalking, <code>TIMESTAMP_WHEN_CHALKED</code> gives per-chalk time values, if
desired.</p>
</td></tr><tr><td>TZ_OFFSET_WHEN_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>The time zone offset from UTC of the machine on which the chalk
operation occurred, as collected when the chalk operation occurred.</p>
</td></tr><tr><td>DATETIME_WHEN_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>This field is a human readable time stamp indicating the time that the
chalk mark was made, using the local clock of the machine that did the
chalking. The value is a full ISO-8601 Date-time string, including a
timezone offset.</p>
<p>For insertion operations (including docker insertion), the value of
this field will represent the same moment in time that the reported
value of <code>_TIMESTAMP</code> would give for the operation.</p>
</td></tr><tr><td>EARLIEST_VERSION</td><td>Chalk-Time, Host</td><td>string</td><td><p>This key is reserved for future use; it is not currently used in any capacity.</p>
</td></tr><tr><td>HOSTINFO_WHEN_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>This returns information about the host on which the chalk operation
occurred, collected at the time of that operation. On posix
systems, it's taken from the 'version' field obtained from a call to
the <code>uname()</code> system call.</p>
</td></tr><tr><td>PUBLIC_IPV4_ADDR_WHEN_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>This returns the IPv4 address on the local machine used to route
external traffic. It's determined by setting up a UDP connection to
Cloudflare's public DNS service, but does not involve sending any data.</p>
</td></tr><tr><td>NODENAME_WHEN_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>The node name at the time of the software's chalk mark insertion. On
posix systems, this will be equivalent to the <code>uname()</code> field
<code>nodename</code>.</p>
</td></tr><tr><td>INJECTOR_CHALK_ID</td><td>Chalk-Time, Host</td><td>string</td><td><p>The <code>CHALK_ID</code> of the chalk binary used to create the chalk mark</p>
</td></tr><tr><td>INJECTOR_PUBLIC_KEY</td><td>Chalk-Time, Host</td><td>string</td><td><p>The public key stored within the injecting Chalk binary, as generated
by <code>chalk setup</code>. This key is configured to go into a Chalk mark
whenever you intend to sign software.  It can be added even if you're
not signing, however.</p>
</td></tr><tr><td>INJECTOR_VERSION</td><td>Chalk-Time, Host</td><td>string</td><td><p>The software version for the chalk binary used in creating the chalk
mark (see also, <code>INJECTOR_CHALK_ID</code>).</p>
</td></tr><tr><td>PLATFORM_WHEN_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>A string consisting of the OS and system architecture of the platform
on which the chalk mark was created.</p>
</td></tr><tr><td>INJECTOR_COMMIT_ID</td><td>Chalk-Time, Host</td><td>string</td><td><p>The commit hash used to build the chalk binary that created the chalk
mark.</p>
</td></tr><tr><td>INJECTOR_ARGV</td><td>Chalk-Time, Host</td><td>list[string]</td><td><p>This field contains the full contents of the command line arguments
used to invoke <code>chalk</code> at the time of an insertion operation.</p>
</td></tr><tr><td>INJECTOR_ENV</td><td>Chalk-Time, Host</td><td>dict[string, string]</td><td><p>Environment variables set at the time when <code>chalk</code> was invoked for an
insertion operation.</p>
<p>Data from environment variables defaults to being redacted, meaning
the variable names will be reported, but not the contents. However,
this can be tweaked on a per-environment variable basis.</p>
<p>The behavior is configured with the following configuration attributes:</p>
<ul>
<li><strong>env_always_show</strong>, a list of environment variables to show unredacted.</li>
<li><strong>env_never_show</strong>, a list of environment variables NOT to show in this
report.</li>
<li><strong>env_redact</strong>, a list of environment variables to redact.</li>
<li><strong>env_default_action</strong>, a value (&quot;show&quot;, &quot;redact&quot;, &quot;ignore&quot;) that indicates
what to do for unnamed environment variables. This defaults to &quot;redact&quot;.</li>
</ul>
<p>Currently, this filtering is not handled per-report, meaning <code>ENV</code> and
<code>_ENV</code> will always be identical if you attempt to collect both at
chalk time.</p>
</td></tr><tr><td>TENANT_ID_WHEN_CHALKED</td><td>Chalk-Time, Host</td><td>string</td><td><p>A user-defined unique identifier, intended to represent a unique user
in multi-tenant environments. This key is set only at the time in
which a chalk operation occurs. Its value can be used at that time for
various URL substitutions (for instance, in the <code>CHALK_PTR</code> key).</p>
<p>The default OSS configuration never sets this value, but it can be
configured manually, or in binaries created by tooling.</p>
</td></tr><tr><td>CHALK_ID</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This is a unique identifier for an <em>unchalked</em> software artifact. When
possible, if the same unchalked artifact is chalked on two different
machines, it will give identical <code>CHALK_ID</code>s.</p>
<p>Chalk marks are always four groups of characters separated by dashes;
the first and last group are six characters, and the middle two groups
four characters.</p>
<p>The non-dash characters are taken from a base32 character set, and the
letters will always be upper case.</p>
<p>Any time a chalk mark is created for a piece of software, this field
must be part of the mark.</p>
<p>Whenever possible, the <code>CHALK_ID</code> will be derived from the hash of the
unchalked artifact (we encoded 100 bits from the hash). This helps
ensure that different machines will calculate the same <code>CHALK_ID</code> on
the same artifact.</p>
<p>Currently, the hash is used for calculating this value for all
artifact types <em>EXPECT</em> docker images, where we cannot reliably get
such a value. In that case, the value is randomly selected, and will
be different every time.</p>
<p>This identifier differs from the <code>METADATA_ID</code> in that the <code>CHALK_ID</code>
is a unique identifier for the unchalked artifact, whereas
<code>METADATA_ID</code> is a unique identifier for the <em>CHALKED</em> artifact. A
single file can have multiple <code>METADATA_ID</code>s when chalked multiple
times, but only one <code>CHALK_ID</code> (again, excepting docker images).</p>
<p>See the documentation for <code>METADATA_ID</code> for more information.</p>
</td></tr><tr><td>TIMESTAMP_WHEN_CHALKED</td><td>Chalk-Time, Artifact</td><td>int</td><td><p>This field consists of the number of milliseconds since the Unix
epoch, at the time the chalk mark was created for the given
artifact. The Unix epoch started at the beginning of Jan 1, 1970, UTC.</p>
<p>When multiple pieces of software are marked in the same run of Chalk,
this will generally indicate the time between chalks.</p>
<p>If, instead of an integer, you would like a more readable
representation, check out the <code>DATE_CHALKED</code>, <code>TIME_CHALKED</code>,
<code>TZ_OFFSET_WHEN_CHALKED</code> and <code>DATETIME_WHEN_CHALKED</code> keys, though
those keys are computed once per-run, and not on a per-artifact basis.</p>
</td></tr><tr><td>CHALK_PTR</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This field is set at Chalk time, and is user definable. It should be
used to inject a URL into the software, where the URL indicates the
location of the report created at Chalk time for this artifact.</p>
<p>There are special substitution variables to allow you to include
artifact-specific information in the URL, all of which are evaluated
at the time of chalking:</p>
<ul>
<li><strong>{chalk_id}</strong> is replaced with the <code>CHALK_ID</code> for this software.</li>
<li><strong>{now}</strong> is replaced with an integer timestamp, and will be identical
to the value of the software's <code>TIMESTAMP_WHEN_CHALKED</code> field, if used.</li>
<li><strong>{path}</strong> is replaced with the <code>PATH_WHEN_CHALKED</code> field for the artifact,
generally representing the software's location on the file system at the time
of chalking.</li>
<li><strong>{hash}</strong> is replaced with the software artifact's <code>HASH</code> field (the Chalk
hash; see <code>chalk help hashing</code>).</li>
<li><strong>{tenant}</strong> is replaced with the software artifact's
<code>TENANT_ID_WHEN_CHALKED</code> field, as set at the time of chalking.</li>
<li><strong>{random}</strong> is replaced with the value of <code>CHALK_RAND</code>, as set at the
time of chalking.</li>
</ul>
<p>The above substitutions all occur, even if the given keys are not
added to the software's chalk mark. See the documentation on those
individual metadata keys for more information about their semantics.</p>
</td></tr><tr><td>PATH_WHEN_CHALKED</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This key represents the file system path for the artifact, <em>at the time the
chalk mark was added</em>.</p>
</td></tr><tr><td>PATH_WITHIN_ZIP</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>For items chalked when they were in a ZIP file, this field gets their path
within that ZIP file.</p>
</td></tr><tr><td>CONTAINING_ARTIFACT_WHEN_CHALKED</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>For items chalked when they were in a embedded into a ZIP file, this is the
<code>CHALK_ID</code> of the containing artifact.</p>
</td></tr><tr><td>ARTIFACT_TYPE</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>A string indicating the type of a software artifact, as determined when the
chalk mark was added. Values can include:</p>
<ul>
<li>ELF (non-MacOS Unix)</li>
<li>Mach-O executable</li>
<li>Unix Script</li>
<li>Docker Image</li>
<li>Docker Container</li>
<li>Python</li>
<li>Python Bytecode</li>
<li>ZIP</li>
<li>JAR</li>
<li>WAR</li>
<li>EAR</li>
</ul>
</td></tr><tr><td>HASH</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Hash file of artifact w/o chalk in it, to ensure extracted chalk is
intact.  The hash algorithm is specific to the codec, and is generally
a normalization of the file that is format specific.</p>
<p>It is NOT the file system hash. For Chalk's purposes, even when
inserting a chalk mark, the file system hash is not a good hash to use
to decided whether two artifacts are the same non-chalked item. For
instance, if you chalk an artifact that has already been chalked, the
chalk HASH algorithm will see they're the same artifact, but the file
system hashes would definitely differ.</p>
<p>Also, for some codecs, due to file format complexities, if you DELETE
a chalk mark from an artifact, you may not get the same bits back as
before any chalk mark was inserted.</p>
<p>That's because there's a normalization process applied, and reversing
it is not worth the effort, especially for things like ZIP files and
ELF binaries, where the logic involved would be complex, and it would
also require storing data.</p>
<p>The codec-specific normalization process ensures the artifact
semantics are always valid, and that we have a consistent way to
hash. It just doesn't always enable recovering the original bits.</p>
<p>Nonetheless:</p>
<ol>
<li><p>The <code>_CURRENT_HASH</code> key will always give you the hash of the file
on the file system, at the end of the current operation.</p>
</li>
<li><p>For file system artifacts, The <code>PRE_CHALK_HASH</code> field will give the
file system hash before insertion. <strong>However</strong>, this is calculated
without considering whether it is already chalked of not.</p>
</li>
</ol>
<p>Additionally, some types of artifact (particularly Docker containers)
may not have a pre-chalk HASH value that we can easily compute, in
which case this field will not be reported.</p>
<p>See <code>chalk help hashing</code> for more information.</p>
</td></tr><tr><td>PRE_CHALK_HASH</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>For chalking operations only, this is the SHA-256 hash value of the
file, before the chalking operation took place.</p>
<p>This key does process chalk marks, only bits on disk. That is, if the
file was previously chalked before the current insertion, the hash
will include the old chalk mark being replaced.</p>
<p>The run-time key <code>_CURRENT_HASH</code> is available on all operations, and
for file system objects, gives the hash on disk after the operation
concludes.</p>
</td></tr><tr><td>ORIGIN_URI</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>The URI associated with the origin of the source code repository found at the
time of chalk mark insertion.</p>
</td></tr><tr><td>BRANCH</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>The branch name found in the source code repository found at the time
of chalk mark insertion.</p>
</td></tr><tr><td>COMMIT_ID</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>The most recent commit hash or id for the current repository and
branch identified at the time of chalk mark insertion.</p>
</td></tr><tr><td>ARTIFACT_VERSION</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This is reserved for future use; plugins specific to managed software
environments are expected to set this field. However, you can manually
set this value if desired.</p>
<p>This metadata key is meant to represent a software artifact's version
information, at the time that a chalk mark is inserted.</p>
</td></tr><tr><td>STORE_URI</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This field's value should be set to the URI of the software artifact's
intended storage location, at the time of chalking. Generally, this
field is meant for internal repository information, not public
information.</p>
<p>Currently, this field is not set by any chalk plugins. The user can
configure it to be set to a custom value.</p>
<p>This field can apply any of the same substitutions supported in the
<code>CHALK_PTR</code> field (see that key for details).</p>
</td></tr><tr><td>PACKAGE_URI</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This field's value should be set to the URI associated with a primary
public distribution point for the software artifact, as of the time of
chalking.</p>
<p>Currently, this field is not set by any chalk plugins. The user can
configure it to be set to a custom value.</p>
<p>This field can apply any of the same substitutions supported in the
<code>CHALK_PTR</code> field (see that key for details).</p>
</td></tr><tr><td>CODE_OWNERS</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This contains any identified code owners at the time that software was
chalked. Generally, this is a free-form field.</p>
<p>In the case where the chalking operation finds a <code>CODEOWNERS</code> or
<code>AUTHORS</code> file, it currently captures the entire free-form file. The
system does NOT currently attempt to extract only relevant parties,
based on local file system path.</p>
</td></tr><tr><td>VCS_DIR_WHEN_CHALKED</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>The version control directory tied to an artifact, identified at the
time of chalking.</p>
<p>This will contain the path information as found on the host on which
the artifact was chalked.</p>
</td></tr><tr><td>BUILD_ID</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>If, at the time of chalking, the system can field will contain the
associated job ID.</p>
</td></tr><tr><td>BUILD_URI</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>If, at the time of chalking, the system can identify a CI/CD job, this
field will contain the URI associated with the job, if found.</p>
<p>This field is generally expected to be supplied by the user, and can
use the same substitutions allowed for the <code>CHALK_PTR</code> field (see that
key's documentation for more detail).</p>
</td></tr><tr><td>BUILD_API_URI</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>If, at the time of chalking, the system an identify a CI/CD job, and
there is a discernible API endpoint, this field will contain the URI
for that endpoint.</p>
<p>This field is generally expected to be supplied by the user, and can
use the same substitutions allowed for the <code>CHALK_PTR</code> field (see that
key's documentation for more detail).</p>
</td></tr><tr><td>BUILD_TRIGGER</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Any recorded build trigger found at chalk time.</p>
</td></tr><tr><td>BUILD_CONTACT</td><td>Chalk-Time, Artifact</td><td>list[string]</td><td><p>Contact information set at chalk time for the person or people
associated with the triggered CI/CD job.</p>
</td></tr><tr><td>CHALK_RAND</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>A 64-bit random value created at chalk time only. This field is
selected per chalk (if enabled), and is intended to help ensure unique
<code>METADATA_ID</code> fields for artifacts in all circumstances. This is
encoded as hex digits.</p>
<p>This is intended for those people who want to be able to trace
specific artifacts to a specific build system.</p>
<p>Certainly, this key should be disabled in chalk marks if attempting
reproducible builds (in which case, also be sure not to chalk any keys
consisting of timestamps).</p>
<p>While there is a config-file callback associated with this metadata
key, it is set by the system, and cannot be overridden by the user.</p>
</td></tr><tr><td>OLD_CHALK_METADATA_HASH</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>In cases where a chalk insertion operation is being performed on a
software artifact that already contains a chalk mark, this field
represents the value of the <code>METADATA_HASH</code> field of the chalk mark
that is being replaced.</p>
<p>This helps support traceability in multi-stage CI/CD processes, where
it makes sense to inject (and/or report on) data at different points.</p>
<p>This field assumes that the old chalk mark was previously reported on,
in which case this field can be used as a reference to recover the
linked information.</p>
<p>See also the related key <code>OLD_CHALK_METADATA_ID</code>, which essentially
serves the same purpose, but using a different representation of the
data.</p>
</td></tr><tr><td>OLD_CHALK_METADATA_ID</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>In cases where a chalk insertion operation is being performed on a
software artifact that already contains a chalk mark, this field
represents the value of the <code>METADATA_ID</code> field of the chalk mark that
is being replaced.</p>
<p>This helps support traceability in multi-stage CI/CD processes, where
it makes sense to inject (and/or report on) data at different points.</p>
<p>This field assumes that the old chalk mark was previously reported on,
in which case this field can be used as a reference to recover the
linked information.</p>
<p>See also the related key <code>OLD_CHALK_METADATA_HASH</code>, which essentially
serves the same purpose, but using a different representation of the
data.</p>
</td></tr><tr><td>EMBEDDED_CHALK</td><td>Chalk-Time, Artifact</td><td>`x</td><td><p>In cases where a software artifact consists of a container consisting
of other software artifacts, this field captures the full chalk marks
for any such embedded software, at the time in which artifacts are
chalked.</p>
<p>The format of this key is an array of chalk marks, identical to the
contents of the <code>_CHALKS</code> key.</p>
<p>Currently, this embedding can only be recorded with ZIP-formatted
artifacts, such as JAR files. This will not be collected unless the
configuration variable <code>chalk_contained_items</code> is set.</p>
<p>We do not currently support this capability with containers, or any
other type of embedded artifact.</p>
</td></tr><tr><td>EMBEDDED_TMPDIR</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>When chalking embedded contents, the system uses a temporary
directory. This key captures the directory used for that
operation. Any directories in the sub-chalk will be under this path,
which will be reflected in path information for embedded artifacts.</p>
</td></tr><tr><td>CLOUD_METADATA_WHEN_CHALKED</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Deprecated, and only available for the simplest of AWS environments.</p>
<p>Instead, please use individual metadata fields for cloud provider
metadata.</p>
</td></tr><tr><td>SBOM</td><td>Chalk-Time, Artifact</td><td>dict[string, `x]</td><td><p>This field is meant to captures any SBOMs associated with a chalking
(i.e., a chalk mark insertion operation). The value, when provided, is
a dictionary. The keys of that dictionary indicate the tool used to
perform the chalking, and the value consists of a free-form JSON
object returned if the SBOM creation is successful.</p>
<p>Currently, the only supported tool integration is <code>syft</code>. It does not
run by default, but if you enable the config variable <code>run_sbom_tools</code>
(which can be also done on the command line with <code>--run-sbom-tools</code>),
and if you configure the key to be chalked or reported (by editing the
appropriate profile), then chalk insertion operations will attempt to
run the tool, even downloading it from its official distribution
source if needed.</p>
<p>You may also set the field yourself if you have other tooling for
collecting this information.</p>
</td></tr><tr><td>SAST</td><td>Chalk-Time, Artifact</td><td>dict[string, `x]</td><td><p>This field captures any static analysis security tooling reports that
are associated with a chalking (i.e., a chalk mark insertion
operation). The value, when provided, is a dictionary. The keys to
that dictionary indicate the tool used to perform the chalking, and
the value consists of a free-form JSON object returned if the SBOM
creation is successful.</p>
<p>Currently, the only supported tool integration is <code>semgrep</code>. It does
not run by default, but if you enable the config variable
<code>run_sast_tools</code> (which can be also done on the command line with
<code>--run-sast-tools</code>), and if you configure the key to be chalked or
reported (by editing the appropriate profile), then chalk insertion
operations will attempt to run the tool, even downloading it, if
needed, from its official distribution source (via Python's pip, which
you will need locally for this to work).</p>
<p>You may also set the field yourself if you have other tooling for
collecting this information.</p>
</td></tr><tr><td>ERR_INFO</td><td>Chalk-Time, Artifact</td><td>list[string]</td><td><p>This can capture any errors or other logging information reported
during the chalk insertion process. The errors are filtered based on
log level.</p>
<p>Only messages of a log level at least as severe as that found in the
configuration variable <code>chalk_log_level</code> are capture. By default, this
value is set to &quot;error&quot;.</p>
<p>That configuration variable is independent from the <code>log_level</code>
variable that controls console logging output.</p>
</td></tr><tr><td>SIGNING</td><td>Chalk-Time, Artifact</td><td>bool</td><td><p>This key must be added into chalk marks whenever chalk marks are being
digitally signed, to help ensure that it's possible to detect deleted
signatures.</p>
<p>It also generally does NOT need to be reported. If this field isn't
reported, and an attacker attempts to delete a signature, they could
remove this field. However, the (required when signing)
<code>METADATA_HASH</code> field will NOT validate if this field is deleted.</p>
</td></tr><tr><td>METADATA_HASH</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This field is used to help authenticate the rest of the metadata
placed into the chalk mark. It constitutes a hash of all the metadata
that is in the actual chalk mark.</p>
<p>Again, this is NOT derived from the insertion-time report; instead, it
is derived from the remainder chalk mark itself. That way, whenever
the chalk mark is extracted, the contents can be validated, thus
detecting whether software has been changed since marked.</p>
<p>For instance, if you mark a shell script, and then edit it, you will
get a validation error on any subsequent operation involving that
artifact until a new mark is inserted, the changes are reverted, or
the mark is deleted.</p>
<p>We use a simple binary normalization format for the hash, which sorts
keys in a well-known order. <code>METADATA_ID</code> isn't used in this
computation since it is derived from the <code>METADATA_HASH</code>, and
signature-related fields are not used, since they sign this value.</p>
<p>Whenever available at chalk time, the <code>HASH</code> field should be added to
artifacts (or the <code>CHALK_ID</code>, which would be derived from the same
value), in which case the <code>METADATA_HASH</code> protects the integrity of
the entire artifact, not just the associated metadata.</p>
<p>The <code>METADATA_ID</code> field is derived from the <code>METADATA_HASH</code> value, but
is more human-readable. It can also be used for metadata integrity,
which is why this field is not strictly required in a chalk mark.</p>
</td></tr><tr><td>METADATA_ID</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This is a more readable unique identifier for a chalked artifact. It
is always derived from 100 bits of the artifact's <code>METADATA_HASH</code>
field, and is encoded in the same way the <code>CHALK_ID</code> key is.</p>
</td></tr><tr><td>SIGNATURE</td><td>Chalk-Time, Artifact</td><td>dict[string, string]</td><td><p>Embedded digital signature for artifact. Note that this is only
supported for file system artifacts; containers and images use
detached signatures only.</p>
<p>Signatures are generated using the In-Toto standard.</p>
</td></tr><tr><td>DOCKER_FILE</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>When chalking docker containers, this gets the contents of the topmost
docker file passed to the docker command line, prior to any chalking.</p>
</td></tr><tr><td>DOCKERFILE_PATH</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Platform passed when performing <code>docker build</code>, if any.</p>
</td></tr><tr><td>DOCKER_PLATFORM</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Platform passed when performing 'docker build', if any.</p>
</td></tr><tr><td>DOCKER_LABELS</td><td>Chalk-Time, Artifact</td><td>dict[string, string]</td><td><p>Labels added to a docker image during the build process, if any.</p>
</td></tr><tr><td>DOCKER_TAGS</td><td>Chalk-Time, Artifact</td><td>list[string]</td><td><p>Tags added to a docker image. Will be in the form: REPOSITORY:TAG</p>
</td></tr><tr><td>DOCKER_CONTEXT</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>The docker context used when building a container.</p>
</td></tr><tr><td>DOCKER_ADDITIONAL_CONTEXTS</td><td>Chalk-Time, Artifact</td><td>dict[string, string]</td><td><p>Additional contexts specified when building a container.</p>
</td></tr><tr><td>DOCKER_CHALK_ADDED_LABELS</td><td>Chalk-Time, Artifact</td><td>dict[string, string]</td><td><p>List of labels programmatically added by Chalk.</p>
</td></tr><tr><td>DOCKER_CHALK_ADDED_TO_DOCKERFILE</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Additional instructions added to the passed dockerfile.</p>
</td></tr><tr><td>DOCKER_CHALK_TEMPORARY_TAG</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>If there was no tag when the build command is run, we use a temporary
tag so we can reliably inspect it after the build.</p>
</td></tr><tr><td>_OP_ARTIFACT_TYPE</td><td>Run-Time, Artifact</td><td>string</td><td><p>A string indicating the type of a software artifact, as determined at
the time a report was generated. The possible values are identical to
those listed in the documentation for the chalk-time key,
<code>ARTIFACT_TYPE</code>.</p>
<p>During insertion operations, this key is redundant with
<code>ARTIFACT_TYPE</code>, so there is generally no reason to report on both of
these at insertion time.</p>
</td></tr><tr><td>_OP_ARTIFACT_PATH</td><td>Run-Time, Artifact</td><td>string</td><td><p>The file system location (or alternate location information if not
file-system based) for a given artifact, in the environment local for
the current operation. For instance, if running a <code>chalk extract</code>
operation or a <code>chalk exec</code> operation, this value will represent where
software is at the time, which likely will not match the path captured
during the build process (which lives in the <code>PATH_WHEN_CHALKED</code> key).</p>
<p>However, on insertion operations, this field is redundant with
<code>PATH_WHEN_CHALKED</code>, except that it cannot be added to a chalk mark.</p>
</td></tr><tr><td>_CURRENT_HASH</td><td>Run-Time, Artifact</td><td>string</td><td><p>This field contains the SHA-256 hash of a software artifact, as
calculated by its codec, at the end of the current chalk operation,
whatever it is.</p>
<p>On insertion operations, this will capture the post-chalking hash
value, and thus will generally be different than the value of the
<code>HASH</code> key.</p>
<p>For extraction and exec operations, since they do not modify the
artifact, this will represent the same post-chalked artifact hash,
except in cases where the artifact isn't chalked, naturally.</p>
</td></tr><tr><td>_VALIDATED_METADATA</td><td>Run-Time, Artifact</td><td>bool</td><td><p>This is set to <code>true</code> if an object's metadata is okay, and the chalk
mark was well-formed. If an object is unsigned, this being <code>true</code> does
NOT mean that the metadata is authentic, just that the data is all
consistent.  If there is also a validated signature as well,
_VALIDATED_SIGNATURE will also be true.</p>
</td></tr><tr><td>_VALIDATED_SIGNATURE</td><td>Run-Time, Artifact</td><td>bool</td><td><p>This is set to true if a signature is both present and validated in an
artifact.</p>
<p>If, for some reason, there is a signature but we could not validate
(e.g., the public key is not available), then this will be set to
<code>false</code>.</p>
<p>However, this doesn't indicate tampering; in the case of a failed
validation, this key is omitted, and <code>_INVALID_SIGNATURE</code> will be
<code>true</code>.</p>
</td></tr><tr><td>_VIRTUAL</td><td>Run-Time, Artifact</td><td>bool</td><td><p>This reporting field indicates that a chalk mark was created for a
given artifact, but that the mark was NOT inserted into the artifact
(ideally, it would have instead been escrowed somewhere easy to
track).</p>
<p>Despite the fact that this key cannot be inserted into a chalk mark,
it is only ever set when performing chalking operations.</p>
</td></tr><tr><td>_OP_CHALKED_KEYS</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>Collected for <code>chalk insert</code> operations only, a list of all keys that
were added to the chalk mark. This only consists of the names of the
keys chalked, not any of the values.</p>
</td></tr><tr><td>_OP_ARTIFACT_REPORT_KEYS</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>Collected for <code>chalk insert</code> operations only, a list of all <em>artifact
specific</em> key names that will reported on in the primary operation
report. This is primarily intended for auxiliary (custom) reports
where the full contents are not being duplicated.</p>
</td></tr><tr><td>_PROCESS_PID</td><td>Run-Time, Artifact</td><td>int</td><td><p>The process ID of the running process associated with the artifact.</p>
<p>Currently, this is only available during a 'chalk exec' operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_DETAIL</td><td>Run-Time, Artifact</td><td>dict[string, string]</td><td><p>Collects key process info; the same info as in <code>_OP_ALL_PS_INFO</code>, but
only for the given process.</p>
<p>This overlaps with many of the other keys beginning with <code>_PROCESS</code>.</p>
<p>If you use this key, then the only such keys that do not overlap are:
<code>_PROCESS_FD_INFO _PROCESS_MOUNT_INFO</code> Currently, this is only
available during a <code>chalk exec</code> operation, where Chalk has been
configured to report when spawning the container entry point.</p>
</td></tr><tr><td>_PROCESS_PARENT_PID</td><td>Run-Time, Artifact</td><td>int</td><td><p>The process ID of the parent process.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_START_TIME</td><td>Run-Time, Artifact</td><td>float</td><td><p>Process start time, in seconds since boot.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_UTIME</td><td>Run-Time, Artifact</td><td>float</td><td><p>The amount of time the process has spent in user mode since starting,
in seconds.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_STIME</td><td>Run-Time, Artifact</td><td>float</td><td><p>The amount of time the process has spent in kernel mode since
starting, in seconds.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_CHILDREN_UTIME</td><td>Run-Time, Artifact</td><td>float</td><td><p>User mode time of the proc's waited-for children.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_CHILDREN_STIME</td><td>Run-Time, Artifact</td><td>float</td><td><p>Kernel mode time of the proc's waited-for children.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_STATE</td><td>Run-Time, Artifact</td><td>string</td><td><p>The state of the process (e.g, Running, Sleeping, Zombie, ...)</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_PGID</td><td>Run-Time, Artifact</td><td>int</td><td><p>The process group associated with the process.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_UMASK</td><td>Run-Time, Artifact</td><td>int</td><td><p>The umask associated with the process.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_UID</td><td>Run-Time, Artifact</td><td>list[int]</td><td><p>A list containing the real, effective, saved and fs UID of the
process.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_GID</td><td>Run-Time, Artifact</td><td>list[int]</td><td><p>A list containing the real, effective, saved and fs GID of the
process.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_NUM_FD_SIZE</td><td>Run-Time, Artifact</td><td>int</td><td><p>The number of allocated file descriptors.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_GROUPS</td><td>Run-Time, Artifact</td><td>list[int]</td><td><p>A list of the supplementary groups to which the process belongs.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_SECCOMP_STATUS</td><td>Run-Time, Artifact</td><td>string</td><td><p>The process' Seccomp status (<code>disabled</code>, <code>strict</code> or <code>filter</code>).</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_ARGV</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>The argv as reported via proc for the exec'd process we are reporting
on.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_CWD</td><td>Run-Time, Artifact</td><td>string</td><td><p>The current working directory of the process.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_EXE_PATH</td><td>Run-Time, Artifact</td><td>string</td><td><p>The path to the executable of the process being reported on.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_COMMAND_NAME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The current name of the process image being reported on.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_PROCESS_FD_INFO</td><td>Run-Time, Artifact</td><td>dict[string, dict[string, string]]</td><td><p>Returns information for all file descriptors in the process.
Keys are file descriptor numbers, but encoded as a string.</p>
<p>Values are dictionaries of info that vary based on the file type.</p>
</td></tr><tr><td>_PROCESS_MOUNT_INFO</td><td>Run-Time, Artifact</td><td>list[list[string]]</td><td><p>A list of mounts available to the process.</p>
<p>Currently, this is only available during a <code>chalk exec</code> operation,
where Chalk has been configured to report when spawning the container
entry point.</p>
</td></tr><tr><td>_OP_ALL_IMAGE_METADATA</td><td>Run-Time, Artifact</td><td>`x</td><td><p>All reported metadata for am image as examined, in JSON format. With
docker, this is equivalent to running <code>docker inspect</code> on the image.</p>
</td></tr><tr><td>_OP_ALL_CONTAINER_METADATA</td><td>Run-Time, Artifact</td><td>`x</td><td><p>All reported metadata for the running container, as reported by the
container runtime, in JSON format. With docker, this is equivalent to
running <code>docker inspect</code> on a running container.</p>
</td></tr><tr><td>_IMAGE_ID</td><td>Run-Time, Artifact</td><td>string</td><td><p>The image ID reported by docker for a container image.</p>
</td></tr><tr><td>_IMAGE_COMMENT</td><td>Run-Time, Artifact</td><td>string</td><td><p>Any comment explicitly set for the image.</p>
</td></tr><tr><td>_IMAGE_CREATION_DATETIME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The DATETIME formatted string for the reported container image
creation time.</p>
</td></tr><tr><td>_IMAGE_DOCKER_VERSION</td><td>Run-Time, Artifact</td><td>string</td><td><p>Docker version used to built the image</p>
</td></tr><tr><td>_IMAGE_AUTHOR</td><td>Run-Time, Artifact</td><td>string</td><td><p>The author of the image (see LABEL maintainer)</p>
</td></tr><tr><td>_IMAGE_ARCHITECTURE</td><td>Run-Time, Artifact</td><td>string</td><td><p>The reported architecture that the image was built for, for example <code>amd64</code> or <code>ppc64le</code>.</p>
</td></tr><tr><td>_IMAGE_VARIANT</td><td>Run-Time, Artifact</td><td>string</td><td><p>Specifies a variant of the CPU, for example <code>armv6l</code> to specify a particular CPU variant of the ARM CPU.</p>
</td></tr><tr><td>_IMAGE_OS</td><td>Run-Time, Artifact</td><td>string</td><td><p>Linux. The answer is linux.</p>
</td></tr><tr><td>_IMAGE_OS_VERSION</td><td>Run-Time, Artifact</td><td>string</td><td><p>Specifies the operating system version, for example 10.0.10586.</p>
</td></tr><tr><td>_IMAGE_SIZE</td><td>Run-Time, Artifact</td><td>int</td><td><p>The size in bytes of the image. This field exists so that a client will have an expected size for the content before validating. If the length of the retrieved content does not match the specified length, the content should not be trusted.</p>
</td></tr><tr><td>_IMAGE_ROOT_FS_TYPE</td><td>Run-Time, Artifact</td><td>string</td><td><p>The type of the image's root filesystem</p>
</td></tr><tr><td>_IMAGE_ROOT_FS_LAYERS</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>The layer IDs of the image's root filesystem</p>
</td></tr><tr><td>_IMAGE_HOSTNAME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The hostname a container uses for itself.</p>
</td></tr><tr><td>_IMAGE_DOMAINNAME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The domain name of the image.</p>
</td></tr><tr><td>_IMAGE_USER</td><td>Run-Time, Artifact</td><td>string</td><td><p>User associated with the image.</p>
</td></tr><tr><td>_IMAGE_EXPOSED_PORTS</td><td>Run-Time, Artifact</td><td>dict[string, dict[string, `x]]</td><td><p>Explicitly configured ports that instances of the image may bind to on
external interfaces. The keys will be of the form 'port/family', e.g.,
<code>446/tcp</code>. The values are info about specific interfaces where those
ports are bound, if provided. Otherwise, it's expected to be across
all interfaces.</p>
</td></tr><tr><td>_IMAGE_ENV</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>The environment configuration of an image.</p>
</td></tr><tr><td>_IMAGE_CMD</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>The default CMD of an image with its arguments.</p>
</td></tr><tr><td>_IMAGE_NAME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The image name associated with a container, as reported by the
runtime.</p>
</td></tr><tr><td>_IMAGE_HEALTHCHECK_TEST</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>Healthcheck command to be run to determine health status.</p>
</td></tr><tr><td>_IMAGE_HEALTHCHECK_INTERVAL</td><td>Run-Time, Artifact</td><td>string</td><td><p>Interval by which to run the healthcheck command.</p>
</td></tr><tr><td>_IMAGE_HEALTHCHECK_TIMEOUT</td><td>Run-Time, Artifact</td><td>string</td><td><p>Timeout after which the healthcheck is considered failed/unhealthy if not OK.</p>
</td></tr><tr><td>_IMAGE_HEALTHCHECK_START_PERIOD</td><td>Run-Time, Artifact</td><td>string</td><td><p>Healthcheck start period provides initialization time for containers that need time to bootstrap.
Probe failure during that period will not be counted towards the maximum number of retries.</p>
</td></tr><tr><td>_IMAGE_HEALTHCHECK_START_INTERVAL</td><td>Run-Time, Artifact</td><td>string</td><td><p>The time between health checks during the container start period.</p>
</td></tr><tr><td>_IMAGE_HEALTHCHECK_RETRIES</td><td>Run-Time, Artifact</td><td>int</td><td><p>How many time to attempt to retry the healthcheck before considering it failed.</p>
</td></tr><tr><td>_IMAGE_MOUNTS</td><td>Run-Time, Artifact</td><td>dict[string, `x]</td><td><p>Different types of mounts (e.g., cache, bind) of an image</p>
</td></tr><tr><td>_IMAGE_WORKINGDIR</td><td>Run-Time, Artifact</td><td>string</td><td><p>The WORKDIR instruction switches to a specific directory in the Docker image, like the application code directory, to make it easier to reference files in subsequent instructions.</p>
</td></tr><tr><td>_IMAGE_ENTRYPOINT</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>The path to the command within the contained file system, relative to
the root of the environment.</p>
</td></tr><tr><td>_IMAGE_NETWORK_DISABLED</td><td>Run-Time, Artifact</td><td>bool</td><td><p>Whether the networking stack of a container is isolated or not</p>
</td></tr><tr><td>_IMAGE_MAC_ADDR</td><td>Run-Time, Artifact</td><td>string</td><td><p>The set MAC address for a container</p>
</td></tr><tr><td>_IMAGE_ONBUILD</td><td>Run-Time, Artifact</td><td>string</td><td><p>The ONBUILD instruction which adds to the image a trigger instruction to be executed at a later time, when the image is used as the base for another build.</p>
</td></tr><tr><td>_IMAGE_LABELS</td><td>Run-Time, Artifact</td><td>dict[string, string]</td><td><p>Key-value pairs adding metadata to images</p>
</td></tr><tr><td>_IMAGE_STOP_SIGNAL</td><td>Run-Time, Artifact</td><td>int</td><td><p>The signal to be sent to the main process inside the container, which by default is SIGTERM</p>
</td></tr><tr><td>_IMAGE_STOP_TIMEOUT</td><td>Run-Time, Artifact</td><td>string</td><td><p>The timeout, which is 10 seconds by default for each container to stop. If even one of your containers does not respond to SIGTERM signals, Docker will wait for 10 seconds at least.</p>
</td></tr><tr><td>_IMAGE_SHELL</td><td>Run-Time, Artifact</td><td>string</td><td><p>The shell used within an image (e.g., <code>/bin/sh</code>) used to execute ENTRYPOINT, RUN and/or CMD commands</p>
</td></tr><tr><td>_IMAGE_VIRTUAL_SIZE</td><td>Run-Time, Artifact</td><td>int</td><td><p>The amount of data used for the read-only image data used by the container plus the container's writable layer size.</p>
</td></tr><tr><td>_IMAGE_LAST_TAG_TIME</td><td>Run-Time, Artifact</td><td>string</td><td><p>Last time an image was tagged.</p>
</td></tr><tr><td>_IMAGE_STORAGE_METADATA</td><td>Run-Time, Artifact</td><td>dict[string, string]</td><td><p>Storage metadata (key value pairs) associated with an image.</p>
</td></tr><tr><td>_STORE_URI</td><td>Run-Time, Artifact</td><td>string</td><td><p>URI where an artifact is none to have been stored, generally as a part
of the current operation.</p>
</td></tr><tr><td>_INSTANCE_CONTAINER_ID</td><td>Run-Time, Artifact</td><td>string</td><td><p>Any reported instance ID, such as the container ID for a running
container.</p>
</td></tr><tr><td>_INSTANCE_CREATION_DATETIME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The DATETIME formatted string for the reported container creation
time.</p>
</td></tr><tr><td>_INSTANCE_ENTRYPOINT_PATH</td><td>Run-Time, Artifact</td><td>string</td><td><p>The path to the command, if running in a containerized / virtual
environment.  The path is relative to the root of the environment.</p>
</td></tr><tr><td>_INSTANCE_ENTRYPOINT_ARGS</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>The arguments used when starting the instance.</p>
</td></tr><tr><td>_INSTANCE_ENV</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>Environment variables made available to the instance, in VAR=value
format.</p>
</td></tr><tr><td>_INSTANCE_RESOLVE_CONF_PATH</td><td>Run-Time, Artifact</td><td>string</td><td><p>Configuration path for DNS settings of the instance</p>
</td></tr><tr><td>_INSTANCE_HOSTNAME_PATH</td><td>Run-Time, Artifact</td><td>string</td><td><p>Configuration path for hostname settings of the instance</p>
</td></tr><tr><td>_INSTANCE_HOSTS_PATH</td><td>Run-Time, Artifact</td><td>string</td><td><p>Configuration path for hosts settings of the instance</p>
</td></tr><tr><td>_INSTANCE_LOG_PATH</td><td>Run-Time, Artifact</td><td>string</td><td><p>Path for storing logs for instance execution</p>
</td></tr><tr><td>_INSTANCE_IMAGE_ID</td><td>Run-Time, Artifact</td><td>string</td><td><p>The image ID associated with the instance, as a hash. Will generally
be lower-case ASCII prefixed with the string <code>sha256:</code></p>
</td></tr><tr><td>_INSTANCE_STATUS</td><td>Run-Time, Artifact</td><td>string</td><td><p>The status of a container or virtual instance (running, paused,
stopped, etc) as reported by the container runtime.</p>
</td></tr><tr><td>_INSTANCE_PID</td><td>Run-Time, Artifact</td><td>int</td><td><p>The process ID of the instance as reported by the container
runtime. This will generally be the actual PID, not a virtualized PID.</p>
</td></tr><tr><td>_INSTANCE_NAME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The name this container instance has been given by the container
runtime.</p>
</td></tr><tr><td>_INSTANCE_RESTART_COUNT</td><td>Run-Time, Artifact</td><td>int</td><td><p>The number of restarts the runtime reports associated with the
container.</p>
</td></tr><tr><td>_INSTANCE_DRIVER</td><td>Run-Time, Artifact</td><td>string</td><td><p>The instance driver (e.g., docker container driver, buildx) used, as reported by the runtime.</p>
</td></tr><tr><td>_INSTANCE_PLATFORM</td><td>Run-Time, Artifact</td><td>string</td><td><p>Platform of an instance, as reported by the runtime.</p>
</td></tr><tr><td>_INSTANCE_MOUNT_LABEL</td><td>Run-Time, Artifact</td><td>string</td><td><p>Mounts labels associated with the running container.</p>
</td></tr><tr><td>_INSTANCE_PROCESS_LABEL</td><td>Run-Time, Artifact</td><td>string</td><td><p>Process label for a running instance.</p>
</td></tr><tr><td>_INSTANCE_APP_ARMOR_PROFILE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Any AppArmor profile enabled for the instance.</p>
</td></tr><tr><td>_INSTANCE_EXEC_IDS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance execution ids as captured at runtime..</p>
</td></tr><tr><td>_INSTANCE_BINDS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Binds specified for a running instance.</p>
</td></tr><tr><td>_INSTANCE_CONTAINER_ID_FILE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>An instance's container ID file</p>
</td></tr><tr><td>_INSTANCE_LOG_CONFIG</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Log configuration for a running instance.</p>
</td></tr><tr><td>_INSTANCE_NETWORK_MODE</td><td>Run-Time, Artifact</td><td>string</td><td><p>Network mode for a running instance.</p>
</td></tr><tr><td>_INSTANCE_RESTART_POLICY_NAME</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Name of the restart policy for the running instance.</p>
</td></tr><tr><td>_INSTANCE_RESTART_RETRY_COUNT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>An instance's restart retry count.</p>
</td></tr><tr><td>_INSTANCE_AUTOREMOVE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Whether the container should be getting removed after its stopped</p>
</td></tr><tr><td>_INSTANCE_VOLUME_DRIVER</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Volume driver information (e.g., vieux/sshfs driver info) related to a running instance</p>
</td></tr><tr><td>_INSTANCE_VOLUMES_FROM</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Mount an instance's volume from another container as described in this option</p>
</td></tr><tr><td>_INSTANCE_CONSOLE_SIZE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>An instance's console size</p>
</td></tr><tr><td>_INSTANCE_ADDED_CAPS</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>Capabilities explicitly added to an instance.</p>
</td></tr><tr><td>_INSTANCE_DROPPED_CAPS</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>Capabilities explicitly dropped from an instance.</p>
</td></tr><tr><td>_INSTANCE_CGROUP_NS_MODE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Cgroup namespace mode of an instance</p>
</td></tr><tr><td>_INSTANCE_DNS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>DNS settings for an instance</p>
</td></tr><tr><td>_INSTANCE_DNS_OPTIONS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>DNS options configured for the instance</p>
</td></tr><tr><td>_INSTANCE_DNS_SEARCH</td><td>Run-Time, Artifact</td><td>`x</td><td><p>DNS search configuration for an instance.</p>
</td></tr><tr><td>_INSTANCE_EXTRA_HOSTS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Additional hosts to be looked up when there are network or DNS issues</p>
</td></tr><tr><td>_INSTANCE_GROUP_ADD</td><td>Run-Time, Artifact</td><td>`x</td><td></td></tr><tr><td>_INSTANCE_IPC_MODE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>IPC mode of an instance</p>
</td></tr><tr><td>_INSTANCE_CGROUP</td><td>Run-Time, Artifact</td><td>string</td><td><p>CGroup associated with the instance, as reported by the container
runtime</p>
</td></tr><tr><td>_INSTANCE_LINKS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Links of a running instance (legacy):
The link feature allows containers to discover each other and securely transfer information about one container to another container&quot;</p>
</td></tr><tr><td>_INSTANCE_OOM_SCORE_ADJ</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Running instance's OOM preferences (-1000 to 1000)</p>
</td></tr><tr><td>_INSTANCE_PID_MODE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>The PID mode of the container (e.g. &quot;host&quot;)</p>
</td></tr><tr><td>_INSTANCE_IS_PRIVILEGED</td><td>Run-Time, Artifact</td><td>bool</td><td><p>Whether or not the workload is running with admin privileges on the
underlying node.</p>
</td></tr><tr><td>_INSTANCE_PUBLISH_ALL_PORTS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Whether the instance publishes all exposed ports to the host interfaces</p>
</td></tr><tr><td>_INSTANCE_READONLY_ROOT_FS</td><td>Run-Time, Artifact</td><td>bool</td><td><p>Whether the root file system is immutable.  Note that this does not
preclude filesystem mounts that allow writing.</p>
</td></tr><tr><td>_INSTANCE_SECURITY_OPT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Security options for the running instance.</p>
</td></tr><tr><td>_INSTANCE_UTS_MODE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>UTS namespace mode for the running instance.</p>
</td></tr><tr><td>_INSTANCE_USER_NS_MODE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>User namespace mode for the running instance.</p>
</td></tr><tr><td>_INSTANCE_SHM_SIZE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Size of /dev/shm for the running instance. The format is <number><unit></p>
</td></tr><tr><td>_INSTANCE_RUNTIME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The container runtime associated with the instance.</p>
</td></tr><tr><td>_INSTANCE_ISOLATION</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Isolation technology in use for the instance, if reported by the
container runtime.</p>
</td></tr><tr><td>_INSTANCE_CPU_SHARES</td><td>Run-Time, Artifact</td><td>`x</td><td><p>A value greater or less than the default of 1024, increases or reduces the instances's weight, and gives it access to a greater or lesser proportion of the host machine's CPU cycles</p>
</td></tr><tr><td>_INSTANCE_MEMORY</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Memory allocated to the running instance</p>
</td></tr><tr><td>_INSTANCE_NANO_CPUS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's NanoCpus that represents CPU quota in units of 10-9 CPUs.</p>
</td></tr><tr><td>_INSTANCE_CGROUP_PARENT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Optional parent cgroup for the running instance</p>
</td></tr><tr><td>_INSTANCE_BLOCKIO_WEIGHT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's block IO weight (relative weight). Accepts a weight value between 10 and 1000.</p>
</td></tr><tr><td>_INSTANCE_BLOCKIO_WEIGHT_DEVICE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance' block IO weight (relative device weight, format: DEVICE_NAME:WEIGHT)</p>
</td></tr><tr><td>_INSTANCE_BLOCKIO_DEVICE_READ_BPS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's limit on read rate from a device (format: <device-path>:<number>[<unit>]). Number is a positive integer. Unit can be one of kb, mb, or gb</p>
</td></tr><tr><td>_INSTANCE_BLOCKIO_DEVICE_WRITE_BPS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's limit on write rate to a device (format: <device-path>:<number>[<unit>]). Number is a positive integer. Unit can be one of kb, mb, or gb.on</p>
</td></tr><tr><td>_INSTANCE_BLOCKIO_DEVICE_READ_IOPS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's limit read rate (IO per second) from a device (format: <device-path>:<number>). Number is a positive integer.</p>
</td></tr><tr><td>_INSTANCE_BLOCKIO_DEVICE_WRITE_IOPS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's limit on write rate (IO per second) to a device (format: <device-path>:<number>). Number is a positive integer.</p>
</td></tr><tr><td>_INSTANCE_CPU_PERIOD</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's limit on the CPU CFS (Completely Fair Scheduler) period</p>
</td></tr><tr><td>_INSTANCE_CPU_QUOTA</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's limit the CPU CFS (Completely Fair Scheduler) quota</p>
</td></tr><tr><td>_INSTANCE_CPU_REALTIME_PERIOD</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's limit on the CPU real-time period. In microseconds. Requires parent cgroups be set and cannot be higher than parent. Also check rtprio ulimits.</p>
</td></tr><tr><td>_INSTANCE_CPU_REALTIME_RUNTIME</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's limit on the CPU real-time runtime. In microseconds. Requires parent cgroups be set and cannot be higher than parent. Also check rtprio ulimits.</p>
</td></tr><tr><td>_INSTANCE_CPUSET_CPUS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's CPUs in which to allow execution (0-3, 0,1)</p>
</td></tr><tr><td>_INSTANCE_CPUSET_MEMS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's memory nodes (MEMs) in which to allow execution (0-3, 0,1). Only effective on NUMA systems.</p>
</td></tr><tr><td>_INSTANCE_DEVICES</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's devices.</p>
</td></tr><tr><td>_INSTANCE_CGROUP_RULES</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's cgroup rules.</p>
</td></tr><tr><td>_INSTANCE_DEVICE_REQUESTS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's device requests.</p>
</td></tr><tr><td>_INSTANCE_MEMORY_RESERVATION</td><td>Run-Time, Artifact</td><td>`x</td><td><p>The platform must guarantee the container can allocate at least the configured amount of memory</p>
</td></tr><tr><td>_INSTANCE_MEMORY_SWAP</td><td>Run-Time, Artifact</td><td>`x</td><td><p>The amount of memory this container is allowed to swap to disk</p>
</td></tr><tr><td>_INSTANCE_MEMORY_SWAPPINESS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Setting from 0 to 100 tuning the percentage of anonymous pages used by a running container instance that the host kernel can swap out.</p>
</td></tr><tr><td>_INSTANCE_OOM_KILL_DISABLE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Whether the out of memory kill is disabled for the running instance.</p>
</td></tr><tr><td>_INSTANCE_PIDS_LIMIT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>The limit of an instance's PIDs. -1 denotes unlimited PIDs.</p>
</td></tr><tr><td>_INSTANCE_ULIMITS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>ulimit settings for the running instance.</p>
</td></tr><tr><td>_INSTANCE_CPU_COUNT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>CPU count for the running instance.</p>
</td></tr><tr><td>_INSTANCE_CPU_PERCENT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Percentage of CPU for the running instance</p>
</td></tr><tr><td>_INSTANCE_IO_MAX_IOPS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>IO max IOPS setting for the running instance</p>
</td></tr><tr><td>_INSTANCE_IO_MAX_BPS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>IO max BPS for the running instance</p>
</td></tr><tr><td>_INSTANCE_MASKED_PATHS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Paths that are masked for the running instance, as they are not safe to mount inside the running instance.</p>
</td></tr><tr><td>_INSTANCE_READONLY_PATHS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Paths that are read-only for the running instance.</p>
</td></tr><tr><td>_INSTANCE_STORAGE_METADATA</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Storage metadata for the running instance.</p>
</td></tr><tr><td>_INSTANCE_MOUNTS</td><td>Run-Time, Artifact</td><td>list[dict[string, `x]]</td><td><p>Mounts associated with the running container.</p>
</td></tr><tr><td>_INSTANCE_HOSTNAME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The hostname of the instance, if reported by the container runtime.</p>
</td></tr><tr><td>_INSTANCE_DOMAINNAME</td><td>Run-Time, Artifact</td><td>string</td><td><p>The domain name of the instance, if any.</p>
</td></tr><tr><td>_INSTANCE_USER</td><td>Run-Time, Artifact</td><td>string</td><td><p>The user reported by the runtime, if any.</p>
</td></tr><tr><td>_INSTANCE_ATTACH_STDIN</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Wether stdin is attached to a running instance, so it can be used within chained pipe commands.</p>
</td></tr><tr><td>_INSTANCE_ATTACH_STDOUT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Wether stdout is attached to a running instance, so it can be used within chained pipe commands.</p>
</td></tr><tr><td>_INSTANCE_ATTACH_STDERR</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Wether stderr is attached to a running instance, so it can be used within chained pipe commands.</p>
</td></tr><tr><td>_INSTANCE_EXPOSED_PORTS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Information on exposed ports from the runtime. The keys will be of the
form 'port/family', e.g., <code>446/tcp</code>. The values are info about
specific interfaces where those ports are bound, if
provided. Otherwise, it's expected to be across all interfaces.</p>
</td></tr><tr><td>_INSTANCE_HAS_TTY</td><td>Run-Time, Artifact</td><td>bool</td><td><p>Whether the instance is using a TTY.</p>
</td></tr><tr><td>_INSTANCE_OPEN_STDIN</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's stdin open status</p>
</td></tr><tr><td>_INSTANCE_STDIN_ONCE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Whether the container runtime should close the stdin channel after it has been opened by a single attach.</p>
</td></tr><tr><td>_INSTANCE_CMD</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's CMD</p>
</td></tr><tr><td>_INSTANCE_CONFIG_IMAGE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's config image</p>
</td></tr><tr><td>_INSTANCE_VOLUMES</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance volumes</p>
</td></tr><tr><td>_INSTANCE_WORKING_DIR</td><td>Run-Time, Artifact</td><td>`x</td><td><p>WORKDIR of a running instance</p>
</td></tr><tr><td>_INSTANCE_ENTRYPOINT</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance's entrypoint directive</p>
</td></tr><tr><td>_INSTANCE_ONBUILD</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance on build directive</p>
</td></tr><tr><td>_INSTANCE_LABELS</td><td>Run-Time, Artifact</td><td>dict[string, string]</td><td><p>Reported labels attached to the instance.</p>
</td></tr><tr><td>_INSTANCE_BRIDGE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance bridge setting</p>
</td></tr><tr><td>_INSTANCE_SANDBOXID</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance sandbox id</p>
</td></tr><tr><td>_INSTANCE_HAIRPINMODE</td><td>Run-Time, Artifact</td><td>`x</td><td><p>HairpinMode of an instance</p>
</td></tr><tr><td>_INSTANCE_LOCAL_IPV6</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance local IPv6</p>
</td></tr><tr><td>_INSTANCE_LOCAL_IPV6_PREFIX_LEN</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance local IPv6 prefix length</p>
</td></tr><tr><td>_INSTANCE_BOUND_PORTS</td><td>Run-Time, Artifact</td><td>dict[string, dict[string, `x]]</td><td><p>Information on bound ports from the runtime.  The keys will be of the
form 'port/family', e.g., 446/tcp'.  The values are info about
specific interfaces where those ports are bound, if provided.
Otherwise, it's expected to be across all interfaces.</p>
</td></tr><tr><td>_INSTANCE_SANDBOX_KEY</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Instance sandbox key</p>
</td></tr><tr><td>_INSTANCE_SECONDARY_IPS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>An instance's secondary IPs</p>
</td></tr><tr><td>_INSTANCE_SECONDARY_IPV6_ADDRS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>An instance's secondary IPv6 addresses</p>
</td></tr><tr><td>_INSTANCE_ENDPOINTID</td><td>Run-Time, Artifact</td><td>`x</td><td><p>An instance's endpoint id</p>
</td></tr><tr><td>_INSTANCE_GATEWAY</td><td>Run-Time, Artifact</td><td>string</td><td><p>The network gateway used by the instance.</p>
</td></tr><tr><td>_INSTANCE_GLOBAL_IPV6_ADDRESS</td><td>Run-Time, Artifact</td><td>string</td><td><p>The externally bound IPv6 address for a container instance.</p>
</td></tr><tr><td>_INSTANCE_GLOBAL_IPV6_PREFIX_LEN</td><td>Run-Time, Artifact</td><td>`x</td><td><p>An instance's global IPv6 prefix length.</p>
</td></tr><tr><td>_INSTANCE_IP</td><td>Run-Time, Artifact</td><td>`x</td><td><p>The primary IPv4 address for the instance.</p>
</td></tr><tr><td>_INSTANCE_IP_PREFIX_LEN</td><td>Run-Time, Artifact</td><td>`x</td><td><p>An instance's IP prefix length.</p>
</td></tr><tr><td>_INSTANCE_IPV6_GATEWAY</td><td>Run-Time, Artifact</td><td>string</td><td><p>The network gateway used by the instance for IPv6 traffic, if any.</p>
</td></tr><tr><td>_INSTANCE_MAC</td><td>Run-Time, Artifact</td><td>string</td><td><p>The MAC address associated with the instance's primary network
instance.</p>
</td></tr><tr><td>_INSTANCE_NETWORKS</td><td>Run-Time, Artifact</td><td>`x</td><td><p>Networks for a running instance.</p>
</td></tr><tr><td>_REPO_TAGS</td><td>Run-Time, Artifact</td><td>list[string]</td><td><p>When reporting on operations involving a repository (e.g., a push or
pull), any tags associated with the artifact in the operation.</p>
</td></tr><tr><td>_REPO_DIGESTS</td><td>Run-Time, Artifact</td><td>dict[string, string]</td><td><p>When reporting on operations involving a repository (e.g., a push or
pull), any SHA256 digests associated with the artifact in the
operation, mapped to the associated tag.</p>
</td></tr><tr><td>_FOUND_BASE_MARK</td><td>Run-Time, Artifact</td><td>tuple[string, string]</td><td><p>When extracting from a docker image that is unmarked at the top layer,
if lower layers are searched, this will be set to the found values of
CHALK_ID and METADATA_ID, in the highest layer where a mark was found.</p>
<p>These values will not have been validated.</p>
</td></tr><tr><td>_SIGNATURE</td><td>Run-Time, Artifact</td><td>dict[string, string]</td><td><p>Digital signature for artifact.  For build/push operations, this will
generally represent the digital signature added as part of the
operation. For extraction operations, it represents a <em>validated</em>
extracted signature.</p>
</td></tr><tr><td>_INVALID_SIGNATURE</td><td>Run-Time, Artifact</td><td>bool</td><td><p>Set to true (and is only set) if there was an attestation that
explicitly did not validate.</p>
</td></tr><tr><td>_ACTION_ID</td><td>Run-Time, Host</td><td>string</td><td><p>This is a unique identifier generated for the current run of chalk. It
is not insertable into chalk marks, but may appear in any host report.</p>
<p>The purpose of this value is to ensure every chalk action has a unique
identifier, if desired.</p>
<p>The value is a 64-bit (secure) random value, encoded as hex.</p>
<p>While there is a config-file callback associated with this metadata
key, it is set by the system, and cannot be overridden by the user.</p>
</td></tr><tr><td>_ARGV</td><td>Run-Time, Host</td><td>list[string]</td><td><p>The full contents of argv used on invocation</p>
</td></tr><tr><td>_ENV</td><td>Run-Time, Host</td><td>dict[string, string]</td><td><p>This field, which can only appear in reports, contains information
about environment variables at the time of ANY chalk invocation. For a
chalkable version, see the documentation for <code>INJECTOR_ENV</code>.</p>
<p>Because chalk may be used to proxy container entry points that could
contain sensitive data, we support to redacting environment variables,
including skipping them outright. The behavior is configured with the
following configuration attributes:</p>
<ul>
<li><strong>env_always_show</strong>, a list of environment variables to show unredacted.</li>
<li><strong>env_never_show</strong>, a list of environment variables NOT to show in this
report.</li>
<li><strong>env_redact</strong>, a list of environment variables to redact.</li>
<li><strong>env_default_action</strong>, a value (&quot;show&quot;, &quot;redact&quot;, &quot;ignore&quot;) that
indicates what to do for unnamed environment variables. This defaults to
&quot;redact&quot;.</li>
</ul>
<p>Currently, this filtering is not handled per-report, meaning
<code>INJECTOR_ENV</code> and <code>_ENV</code> will always be identical if you attempt to
collect both at chalk time.</p>
</td></tr><tr><td>_TENANT_ID</td><td>Run-Time, Host</td><td>string</td><td><p>Akin to <code>TENANT_ID_WHEN_CHALKED</code>, but will not be added to a chalk
mark, and can be set for any given operation. The default OSS
configuration never sets this value, but it can be configured
manually, or in binaries created by tooling.</p>
</td></tr><tr><td>_OPERATION</td><td>Run-Time, Host</td><td>string</td><td><p>This field can be provided for any chalk report, and represents the
top-level command used to invoke chalk. The value might be slightly
different from the one invoked on the command line, even though it is
often the same.</p>
<p>This field will always be one of the following values:</p>
<ul>
<li><code>insert</code>, created via <code>chalk insert</code></li>
<li><code>extract</code>, created via <code>chalk extract</code></li>
<li><code>build</code>, created via <code>chalk docker</code> commands that build a container.</li>
<li><code>push</code>, created via <code>chalk docker</code> commands that push a container
(at which point we collect data to link the build image to the pushed image).</li>
<li><code>exec</code>, created when <code>chalk exec</code> is used to spawn a process.</li>
<li><code>heartbeat</code>, used for subsequent reports when <code>chalk exec</code> is used.</li>
<li><code>delete</code>, created via <code>chalk delete</code></li>
<li><code>env</code>, created when <code>chalk env</code> is called to create a moment-in-time report
for a current environment.</li>
<li><code>load</code>, created when a new configuration is inserted into a chalk binary.</li>
<li><code>setup</code>, used for reporting on self-chalking after <code>chalk setup</code> is run.</li>
<li><code>docker</code>, created for other (unhandled) docker commands, but not used in the
default configuration.</li>
</ul>
<p>These values correspond to the names used by the <code>outconf</code>
configuration section for setting up report I/O.</p>
<p>The <code>help</code>, <code>dump</code>, <code>version</code>, and <code>defaults</code> commands do not ever
generate reports.</p>
</td></tr><tr><td>_TIMESTAMP</td><td>Run-Time, Host</td><td>int</td><td><p>For the current operation only, this represents the number of
milliseconds since the Unix epoch. See the documentation for the
<code>TIMESTAMP</code> key for more details.</p>
<p>This is collected and reported on a per-chalk-invocation basis, not on
a per-software-artifact basis. It also cannot be directly added to a
chalk mark (but can be in a report for any chalk operation).</p>
</td></tr><tr><td>_DATE</td><td>Run-Time, Host</td><td>string</td><td><p>A human-readable date associated with the operation currently being
reported on. This is derived from the same value used if <code>_TIMESTAMP</code>
is reported.</p>
</td></tr><tr><td>_TIME</td><td>Run-Time, Host</td><td>string</td><td><p>A human-readable string containing the time associated with the
operation currently being reported on. This is derived from the same
value used if <code>_TIMESTAMP</code> is reported.</p>
<p>This value is reported based on the clock and time zone of the machine
performing the chalk operation.</p>
</td></tr><tr><td>_TZ_OFFSET</td><td>Run-Time, Host</td><td>string</td><td><p>The Time Zone offset from UTC for the current chalk operation.</p>
</td></tr><tr><td>_DATETIME</td><td>Run-Time, Host</td><td>string</td><td><p>A full ISO-8601 Date-time w/ timezone offset for the current
operation, derived from the same value used to set the _TIMESTAMP key.</p>
</td></tr><tr><td>_CHALKS</td><td>Run-Time, Host</td><td>string</td><td><p>Used to report chalks the operation worked on.</p>
<p><strong>IMPORTANT!</strong></p>
<p>Host reports using a profile that does not configure this key to
report will NOT output chalks.</p>
</td></tr><tr><td>_OP_CHALK_COUNT</td><td>Run-Time, Host</td><td>int</td><td><p>The number of chalks the operation worked on, meant primarily for
contexts where the chalks themselves are not being reported, such as
when reporting on aggregate stats.</p>
</td></tr><tr><td>_OP_UNMARKED_COUNT</td><td>Run-Time, Host</td><td>string</td><td><p>The number of unmarked artifacts that codecs saw in the current
operation. For inserts, this number will represent the number of items
that come codec was willing to chalk, except that the configuration
indicated to ignore the file (which will frequently happen with
scripts in a <code>.git</code> directory, for instance). For non-insertion
operations, the value will represent the number of software artifacts
processed that did not contain chalk marks.</p>
</td></tr><tr><td>_OP_CMD_FLAGS</td><td>Run-Time, Host</td><td>list[string]</td><td><p>Fully resolved command-line flags and values used in the current chalk
command's invocation.</p>
<p>This is slightly different from <code>_ARGV</code> in that arguments may have
experienced some processing.</p>
</td></tr><tr><td>_OP_SEARCH_PATH</td><td>Run-Time, Host</td><td>list[string]</td><td><p>The artifact search path used for the current chalk command's attempt
to locate chalked artifacts.</p>
</td></tr><tr><td>_OP_EXE_NAME</td><td>Run-Time, Host</td><td>string</td><td><p>The executable name for the current chalk invocation, which is
approximately argv[0].</p>
<p>This key attempts to use information from the command-line invocation
of chalk, instead of system-specific information on running processes
(see <code>_PROCESS_COMMAND_NAME</code>).</p>
</td></tr><tr><td>_OP_EXE_PATH</td><td>Run-Time, Host</td><td>string</td><td><p>The local path to the chalk executable for the current
invocation. This generally does not include the actual exe name.</p>
<p>This key attempts to use information from the command-line invocation
of chalk, instead of system-specific information on running processes
(see <code>_PROCESS_EXE_PATH</code>).</p>
</td></tr><tr><td>_OP_ARGV</td><td>Run-Time, Host</td><td>list[string]</td><td><p>This field contains the full contents of the command line arguments
used to invoke <code>chalk</code> for the current invocation. This field cannot
be inserted into chalk marks, but will have the same value as the
<code>INJECTOR_ARGV</code> key on any insertion operations.</p>
</td></tr><tr><td>_OP_CONFIG</td><td>Run-Time, Host</td><td>string</td><td><p>The contents of any user-definable configuration file used in the
current operation, if an external configuration file is used at all
(otherwise, even if requested, no value will be returned)</p>
</td></tr><tr><td>_UNMARKED</td><td>Run-Time, Host</td><td>list[string]</td><td><p>A list of artifact path information for any artifacts identified
during the current operation that were NOT marked. For insertion, this
means artifacts a codec should have processed but didn't due to
error. Otherwise, it will indicate a software artifact that the system
could have marked, but where no mark was found.</p>
</td></tr><tr><td>_OP_CHALKER_COMMIT_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The commit hash of the repository used to build the chalk binary used
in the current operation.</p>
</td></tr><tr><td>_OP_CHALKER_VERSION</td><td>Run-Time, Host</td><td>string</td><td><p>Version information for the chalk command used in the current chalk
invocation.</p>
</td></tr><tr><td>_OP_PLATFORM</td><td>Run-Time, Host</td><td>string</td><td><p>Platform info (os and architecture) for the current chalk invocation.</p>
</td></tr><tr><td>_OP_HOSTNAME</td><td>Run-Time, Host</td><td>string</td><td><p>Hostname information found that is associated with the machine on
which the current chalk command was executed.</p>
</td></tr><tr><td>_OP_HOSTINFO</td><td>Run-Time, Host</td><td>string</td><td><p>This returns information about the host on which the urrent operation
occurred, collected at the time of that operation. On posix
systems, it's taken from the 'version' field obtained from a call to
the <code>uname()</code> system call.</p>
</td></tr><tr><td>_OP_PUBLIC_IPV4_ADDR</td><td>Run-Time, Host</td><td>string</td><td><p>This returns the IPv4 address on the local machine used to route
external traffic. It's determined by setting up a UDP connection to
Cloudflare's public DNS service, but does not involve sending any
data.</p>
<p>There are other keys for reported IPs via other systems, including
cloud provider APIs, docker, procfs, etc.</p>
</td></tr><tr><td>_OP_NODENAME</td><td>Run-Time, Host</td><td>string</td><td><p>The node name at the time of the current operation. On posix systems,
this should be equivalent to the uname 'nodename' field.</p>
</td></tr><tr><td>_OP_CLOUD_METADATA</td><td>Run-Time, Host</td><td>string</td><td><p>Deprecated, and only available for the simplest of AWS environments.</p>
<p>Instead, please use individual metadata fields for cloud provider
metadata.</p>
</td></tr><tr><td>_OP_ERRORS</td><td>Run-Time, Host</td><td>list[string]</td><td><p>Errors identified during the current operation, not associated with a
particular artifact. See the documentation for <code>ERR_INFO</code>, which
shares the same log-level configuration.</p>
</td></tr><tr><td>_OP_HOST_REPORT_KEYS</td><td>Run-Time, Host</td><td>list[string]</td><td><p>Collected for <code>chalk insert</code> operations only, a list of all
<em>host-level</em> key names that will reported on in the primary operation
report. This is primarily intended for auxiliary (custom) reports
where the full contents are not being duplicated.</p>
</td></tr><tr><td>_OP_TCP_SOCKET_INFO</td><td>Run-Time, Host</td><td>list[list[string]]</td><td><p>On Linux machines, will return information about existing TCP sockets,
to the degree that the chalk process has permissions to access this
information.</p>
<p>One socket is returned per row. The columns returned are:</p>
<ol>
<li>The local IP address in use</li>
<li>The local port number in use</li>
<li>The remote IP address in use</li>
<li>The remote port number in use</li>
<li>The status of the connection (e.g., LISTEN, CONNECT, ...)</li>
<li>The UID of the process that owns the socket</li>
<li>The inode associated with the socket</li>
</ol>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_UDP_SOCKET_INFO</td><td>Run-Time, Host</td><td>list[list[string]]</td><td><p>On Linux machines, will return UDP state information, to the degree
that the chalk process has permissions to access this information.</p>
<p>One socket is returned per row. The columns returned are:</p>
<ol>
<li>The local IP address in use</li>
<li>The local port number in use</li>
<li>The remote IP address in use</li>
<li>The remote port number in use</li>
<li>The status of the connection (always UNCONN)</li>
<li>The UID of the process that owns the socket</li>
<li>The inode associated with the socket</li>
</ol>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_IPV4_ROUTES</td><td>Run-Time, Host</td><td>list[list[string]]</td><td><p>On Linux machines, will return IPV4 routing table information, to the
degree that the chalk process has permissions to access this
information.</p>
<p>One route is returned per row. The columns returned are:</p>
<ol>
<li>The destination network</li>
<li>The next hop (gateway address)</li>
<li>The netmask for the route</li>
<li>The interface (device) associated with the route</li>
<li>The kernel's 'Flags' field</li>
<li>The kernel's 'RefCnt' field</li>
<li>The kernel's 'Use' field</li>
<li>The kernel's 'Metric' field</li>
<li>The kernel's 'MTU' field</li>
<li>The kernel's 'Window' field</li>
<li>The kernel's 'IRTT' field</li>
</ol>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_IPV6_ROUTES</td><td>Run-Time, Host</td><td>list[list[string]]</td><td><p>On Linux machines, will return IPV6 routing table information, to the
degree that the chalk process has permissions to access this
information.</p>
<p>One route is returned per row.  The columns returned are:</p>
<ol>
<li>The destination network</li>
<li>The destination prefix length in hex</li>
<li>The source network</li>
<li>The source prefix length in hex</li>
<li>The next hop (gateway address)</li>
<li>The interface (device) associated with the route</li>
<li>The kernel's 'Flags' field</li>
<li>The kernel's 'RefCnt' field</li>
<li>The kernel's 'Use' field</li>
<li>The kernel's 'Metric' field</li>
</ol>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_IPV4_INTERFACES</td><td>Run-Time, Host</td><td>list[list[string]]</td><td><p>On Linux machines, will return information on IPV4 interface status.</p>
<p>One interface is listed per row.  The first column is the interface
name.</p>
<p>The next 8 columns are receive statistics:
bytes, packets, errors, drops, fifo, frame, compressed, multicast</p>
<p>The remaining columns are transmission statistics:
bytes, packets, errors, drops, fifo, colls, carrier, compressed</p>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_IPV6_INTERFACES</td><td>Run-Time, Host</td><td>list[list[string]]</td><td><p>On Linux machines, will return information on IPV6 interface status.</p>
<p>One interface is listed per row.  The first column is the interface name.</p>
<p>The remaining columns are:</p>
<ul>
<li>The netlink device number in hex</li>
<li>The prefix length in hex</li>
<li>The kernel's 'Scope value' (see include/net/ipv6.h)</li>
<li>The kernel's 'Interface flags' (see include/linux/rtnetlink.h')</li>
</ul>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_ARP_TABLE</td><td>Run-Time, Host</td><td>list[list[string]]</td><td><p>On Linux machines, will return the ARP table.</p>
<p>One row is returned for each ARP entry.  The columns are:</p>
<ol>
<li>The IP address</li>
<li>The kernel's recorded hardware type</li>
<li>Any flags set in the kernel for the ARP entry</li>
<li>The associated hardware address.</li>
<li>The kernel's record 'Mask' field</li>
<li>The network device from which the entry broadcasts.</li>
</ol>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_CPU_INFO</td><td>Run-Time, Host</td><td>dict[string, string]</td><td><p>Currently, this just returns CPU basic load average info, including
number of processes.</p>
<p>The values are all presented as strings.  The current available item info is:</p>
<ul>
<li>load: load averages over the last 1, 5 and 15 mins</li>
<li>lastpid: the last PID handed out by the system</li>
<li>runnable_procs: the number of current running processes</li>
<li>total_procs: the total number of running processes.</li>
</ul>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_ALL_PS_INFO</td><td>Run-Time, Host</td><td>dict[string, dict[string, string]]</td><td><p>For every process visible to Chalk, reports key process info.  The
keys are the PID as a string, even when they are clearly numeric
values.</p>
<p>The values are dictionaries of information associated with that process:</p>
<ul>
<li>state: The state of the process (e.g, Running, Sleeping, Zombie, ...)</li>
<li>ppid: The parent process ID</li>
<li>pgrp: The process group</li>
<li>sid:  The session ID of the process.</li>
<li>tty_nr: The encoded TTY number for the controlling terminal of the process.</li>
<li>tpgid: The ID of the terminal's process group.</li>
<li>user_time: The amount of time the process has spent in user mode since
starting, in seconds.</li>
<li>system_time: The amount of time the process has spent in kernel mode since
starting, in seconds.</li>
<li>child_utime: User mode time of the proc's waited-for children.</li>
<li>child_stime: Kernel mode time of the proc's waited-for children.</li>
<li>priority: The real-time scheduler's priority field reported by Linux.</li>
<li>nice: The nice value for the process (higher numbers are lower priority)</li>
<li>num_threads: The number of threads in the process.</li>
<li>runtime: The time since the process started, in seconds.</li>
<li>uid: A list containing the real, effective, saved and fs UID</li>
<li>gid: A list containing the real, effective, saved and fs GID</li>
<li>fd_size: The number of allocated file descriptors</li>
<li>groups: A list of the supplementary groups to which the process belongs.</li>
<li>seccomp: The process' Seccomp status ('disabled', 'strict' or 'filter')</li>
<li>umask: The umask associated with the process.</li>
<li>argv: The command line used when exec'ing the process.</li>
<li>path: The path to the executable.</li>
<li>cwd: The cwd of the process.</li>
<li>name: The short name of the process, as determined by /proc/pid/stat</li>
<li>command: The short name of the command, as determined by proc/pid/comm</li>
</ul>
<p>When running Chalk inside a container, this information will be the
virtualized view available insider the container.</p>
</td></tr><tr><td>_OP_CLOUD_PROVIDER</td><td>Run-Time, Host</td><td>string</td><td><p>In case of chalk running in the cloud, the type of the cloud provider the
node is running in. Currently the only supported values are gcp, aws, azure</p>
</td></tr><tr><td>_OP_CLOUD_PROVIDER_ACCOUNT_INFO</td><td>Run-Time, Host</td><td>`x</td><td><p>In case of chalk running in the cloud, the account ID or other identifying metadata
for the account owning the environment in which chalk executes in.</p>
<ul>
<li>For AWS this is the AWS Account ID</li>
<li>For Azure this is the Subscription ID</li>
<li>For GCP its the Service Account</li>
</ul>
</td></tr><tr><td>_OP_CLOUD_PROVIDER_REGION</td><td>Run-Time, Host</td><td>string</td><td><p>In case of chalk running in the cloud, the region in which chalk executes in</p>
</td></tr><tr><td>_OP_CLOUD_PROVIDER_IP</td><td>Run-Time, Host</td><td>string</td><td><p>In case of chalk running in the cloud, the public IPv4 of the host in which chalk
executes in</p>
</td></tr><tr><td>_OP_CLOUD_PROVIDER_INSTANCE_TYPE</td><td>Run-Time, Host</td><td>string</td><td><p>In case of chalk running in the cloud, the instance type where chalk
executes in (e.g., t2.medium for AWS)</p>
</td></tr><tr><td>_OP_CLOUD_PROVIDER_TAGS</td><td>Run-Time, Host</td><td>`x</td><td><p>In case of chalk running in the cloud, tags associated with the instance</p>
</td></tr><tr><td>_OP_CLOUD_PROVIDER_SERVICE_TYPE</td><td>Run-Time, Host</td><td>string</td><td><p>In case of chalk running in the cloud, the type of the service the node is
running in, (eks, ecs for AWS etc.)</p>
<p>This functionality is currently experimental, and only EKS, EC2, ECS are inferred
for AWS.</p>
</td></tr><tr><td>_AZURE_INSTANCE_METADATA</td><td>Run-Time, Host</td><td>dict[string, `x]</td><td><p>JSON containing cloud instance attributes, such as instance-id, IP
addresses, etc.</p>
<p>See <a href="https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service">https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service</a> for more</p>
</td></tr><tr><td>_GCP_INSTANCE_METADATA</td><td>Run-Time, Host</td><td>dict[string, `x]</td><td><p>JSON containing cloud instance attributes, such as instance-id, IP
addresses, etc.</p>
<p>See <a href="https://cloud.google.com/compute/docs/metadata/overview">https://cloud.google.com/compute/docs/metadata/overview</a> for more</p>
</td></tr><tr><td>_AWS_INSTANCE_IDENTITY_DOCUMENT</td><td>Run-Time, Host</td><td>dict[string, `x]</td><td><p>JSON containing instance attributes, such as instance-id, private IP
address, etc. See Instance identity documents.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_INSTANCE_IDENTITY_PKCS7</td><td>Run-Time, Host</td><td>string</td><td><p>Used to verify the document's authenticity and content against the
signature. See Instance identity documents.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_INSTANCE_IDENTITY_SIGNATURE</td><td>Run-Time, Host</td><td>string</td><td><p>Data that can be used by other parties to verify identity document's
origin and authenticity.  See Instance identity documents.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_INSTANCE_MONITORING</td><td>Run-Time, Host</td><td>string</td><td><p>Value showing whether the customer has enabled detailed one-minute
monitoring in CloudWatch. Valid values: <code>enabled</code>, <code>disabled</code>.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_AMI_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The AMI ID used to launch the instance.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_AMI_LAUNCH_INDEX</td><td>Run-Time, Host</td><td>string</td><td><p>If you started more than one instance at the same time, this value
indicates the order in which the instance was launched. The value of
the first instance launched is 0.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_AMI_MANIFEST_PATH</td><td>Run-Time, Host</td><td>string</td><td><p>The path to the AMI manifest file in Amazon S3. If you used an Amazon
EBS-backed AMI to launch the instance, the returned result is unknown.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_ANCESTOR_AMI_IDS</td><td>Run-Time, Host</td><td>string</td><td><p>The AMI IDs of any instances that were rebundled to create this
AMI. This value will only exist if the AMI manifest file contained an
ancestor-amis key.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_HOSTNAME</td><td>Run-Time, Host</td><td>string</td><td><p>If the EC2 instance is using IP-based naming (IPBN), this is the
private IPv4 DNS hostname of the instance. If the EC2 instance is
using Resource-based naming (RBN), this is the RBN. In cases where
multiple network interfaces are present, this refers to the eth0
device (the device for which the device number is 0). For more
information about IPBN and RBN, see Amazon EC2 instance hostname
types.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_IAM_INFO</td><td>Run-Time, Host</td><td>dict[string, `x]</td><td><p>If there is an IAM role associated with the instance, contains
information about the last time the instance profile was updated,
including the instance's LastUpdated date, InstanceProfileArn, and
InstanceProfileId. Otherwise, not present.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_INSTANCE_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The ID of an AWS instance.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_INSTANCE_LIFE_CYCLE</td><td>Run-Time, Host</td><td>string</td><td><p>The purchasing option of this instance. For more information see:</p>
<ul><li>https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-purchasing-options.html</li></ul>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_INSTANCE_TYPE</td><td>Run-Time, Host</td><td>string</td><td><p>The type of instance. For more information, see:</p>
<ul><li>https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-types.html</li></ul>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_IPV6_ADDR</td><td>Run-Time, Host</td><td>string</td><td><p>The IPv6 address of the instance, if any. In cases where multiple
network interfaces are present, this refers to the eth0 device network
interface and the first IPv6 address assigned.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_KERNEL_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The ID of the kernel launched with this instance, if applicable.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_LOCAL_HOSTNAME</td><td>Run-Time, Host</td><td>string</td><td><p>In cases where multiple network interfaces are present, this refers to
the eth0 device (the device for which the device number is 0). If the
EC2 instance is using IP-based naming (IPBN), this is the private IPv4
DNS hostname of the instance. If the EC2 instance is using
Resource-based naming (RBN), this is the RBN. For more information
about IPBN, RBN, and EC2 instance naming, see:</p>
<ul><li>https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-naming.html</li></ul>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_LOCAL_IPV4_ADDR</td><td>Run-Time, Host</td><td>string</td><td><p>The private IPv4 address of the instance, if any. In cases where
multiple network interfaces are present, this refers to the eth0
device (the device for which the device number is 0).</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_AZ</td><td>Run-Time, Host</td><td>string</td><td><p>The Availability Zone in which the instance launched.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_AZ_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The static Availability Zone ID in which the instance is launched. The
Availability Zone ID is consistent across accounts. However, it might
be different from the Availability Zone, which can vary by account.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_PLACEMENT_GROUP</td><td>Run-Time, Host</td><td>string</td><td><p>The name of the placement group in which the instance is launched.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_DEDICATED_HOST_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The ID of the host on which the instance is launched. Applicable only
to Dedicated Hosts.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_PARTITION_NUMBER</td><td>Run-Time, Host</td><td>string</td><td><p>The number of the partition in which the instance is launched.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_REGION</td><td>Run-Time, Host</td><td>string</td><td><p>The AWS Region in which the instance is launched.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_PUBLIC_HOSTNAME</td><td>Run-Time, Host</td><td>string</td><td><p>The instance's public DNS (IPv4). This category is only returned if
the enableDnsHostnames attribute is set to true. For more information,
see <a href="https://docs.aws.amazon.com/vpc/latest/userguide/vpc-dns.html">DNS attributes for your
VPC</a> in
the Amazon VPC User Guide. If the instance only has a public-IPv6
address and no public-IPv4 address, this item is not set.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_PUBLIC_IPV4_ADDR</td><td>Run-Time, Host</td><td>string</td><td><p>The public IPv4 address. If an Elastic IP address is associated with
the instance, the value returned is the Elastic IP address.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_OPENSSH_PUBKEY</td><td>Run-Time, Host</td><td>string</td><td><p>Public key for SSH access. Only available if supplied at instance
launch time.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_SECURITY_GROUPS</td><td>Run-Time, Host</td><td>list[string]</td><td><p>The names of the security groups applied to the instance.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_SECURITY_GROUP_IDS</td><td>Run-Time, Host</td><td>list[string]</td><td><p>The IDs of the security groups to which the network interface belongs.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_RESOURCE_DOMAIN</td><td>Run-Time, Host</td><td>string</td><td><p>The domain for AWS resources for the Region.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_PARTITION_NAME</td><td>Run-Time, Host</td><td>string</td><td><p>The partition that the resource is in. For standard AWS Regions, the
partition is aws. If you have resources in other partitions, the
partition is aws-partitionname. For example, the partition for
resources in the China (Beijing) Region is aws-cn.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_TAGS</td><td>Run-Time, Host</td><td>dict[string, string]</td><td><p>The instance tags associated with the instance. Only available if you
explicitly allow access to tags in instance metadata. For more
information, see <a href="https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_Tags.html#allow-access-to-tags-in-IMDS">Allow access to tags in instance
metadata</a>.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_AUTOSCALING_TARGET_LIFECYCLE_STATE</td><td>Run-Time, Host</td><td>string</td><td><p>Value showing the target Auto Scaling lifecycle state that an Auto
Scaling instance is transitioning to. Present when the instance
transitions to one of the target lifecycle states after March 10,
2022. Possible
values: Detached | InService | Standby | Terminated | Warmed:Hibernated | Warmed:Running | Warmed:Stopped | Warmed:Terminated. See Retrieve
the target lifecycle state through instance metadata in the Amazon EC2
Auto Scaling User Guide.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_BLOCK_DEVICE_MAPPING_AMI</td><td>Run-Time, Host</td><td>string</td><td><p>The virtual device that contains the root/boot file system.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_BLOCK_DEVICE_MAPPING_ROOT</td><td>Run-Time, Host</td><td>string</td><td><p>The virtual devices or partitions associated with the root devices or
partitions on the virtual device, where the root (/ or C:) file system
is associated with the given instance.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_BLOCK_DEVICE_MAPPING_SWAP</td><td>Run-Time, Host</td><td>string</td><td><p>The virtual devices associated with swap. Not always present.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_EVENTS_MAINTENANCE_HISTORY</td><td>Run-Time, Host</td><td>`x</td><td><p>If there are completed or canceled maintenance events for the
instance, contains a JSON string with information about the
events. For more information, see To view event history about
completed or canceled events.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_EVENTS_MAINTENANCE_SCHEDULED</td><td>Run-Time, Host</td><td>`x</td><td><p>If there are active maintenance events for the instance, contains a
JSON string with information about the events. For more information,
see View scheduled events.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_EVENTS_RECOMMENDATIONS_REBALANCE</td><td>Run-Time, Host</td><td>string</td><td><p>The approximate time, in UTC, when the EC2 instance rebalance
recommendation notification is emitted for the instance. The following
is an example of the metadata for this category: {&quot;noticeTime&quot;:
&quot;2020-11-05T08:22:00Z&quot;}. This category is available only after the
notification is emitted. For more information, see EC2 instance
rebalance recommendations.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_IDENTITY_CREDENTIALS_EC2_INFO</td><td>Run-Time, Host</td><td>dict[string, `x]</td><td><p>Information about the credentials
in identity-credentials/ec2/security-credentials/ec2-instance.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_IDENTITY_CREDENTIALS_EC2_SECURITY_CREDENTIALS_EC2_INSTANCE</td><td>Run-Time, Host</td><td>dict[string, `x]</td><td><p>Credentials for the instance identity role that allow on-instance
software to identify itself to AWS to support features such as EC2
Instance Connect and AWS Systems Manager Default Host Management
Configuration. These credentials have no policies attached, so they
have no additional AWS API permissions beyond identifying the instance
to the AWS feature.  This option will not log the SecretAccessKey and
Token.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_INSTANCE_ACTION</td><td>Run-Time, Host</td><td>string</td><td><p>Notifies the instance that it should reboot in preparation for
bundling. Valid values: none | shutdown | bundle-pending.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_MAC</td><td>Run-Time, Host</td><td>string</td><td><p>The instance's media access control (MAC) address. In cases where
multiple network interfaces are present, this refers to the eth0
device (the device for which the device number is 0).</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_INTERFACE_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The ID of the network interface.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_SUBNET_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The ID of the subnet in which the interface resides.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_VPC_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The ID of the VPC in which the interface resides.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_METRICS_VHOSTMD</td><td>Run-Time, Host</td><td>string</td><td><p>No longer available.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_PRODUCT_CODES</td><td>Run-Time, Host</td><td>string</td><td><p>AWS Marketplace product codes associated with the instance, if any.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_RAMDISK_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The ID of the RAM disk specified at launch time, if applicable.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_RESERVATION_ID</td><td>Run-Time, Host</td><td>string</td><td><p>The ID of the reservation.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_SPOT_INSTANCE_ACTION</td><td>Run-Time, Host</td><td>string</td><td><p>The action (hibernate, stop, or terminate) and the approximate time,
in UTC, when the action will occur. This item is present only if the
Spot Instance has been marked for hibernate, stop, or terminate. For
more information, see instance-action.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_AWS_SPOT_TERMINATION_TIME</td><td>Run-Time, Host</td><td>string</td><td><p>The approximate time, in UTC, that the operating system for your Spot
Instance will receive the shutdown signal. This item is present and
contains a time value (for example, 2015-01-05T18:02:00Z) only if the
Spot Instance has been marked for termination by Amazon EC2. The
termination-time item is not set to a time if you terminated the Spot
Instance yourself. For more information, see termination-time.</p>
<p>This key is only available as a run-time key, and only when running in
AWS where imdsv2 is available.</p>
</td></tr><tr><td>_CHALK_EXTERNAL_ACTION_AUDIT</td><td>Run-Time, Host</td><td>list[(string, string) -> void]</td><td><p>An audit trail of any actions taken by the config file that involved
the world beyond the chalk process. For instance, any file
modifications and web connections get audited, as do externally run
commands.</p>
</td></tr><tr><td>_CHALK_RUN_TIME</td><td>Run-Time, Host</td><td>int</td><td><p>Calculates the amount of time between the start of a chalk executable
and when a report is generated. It's an integer with resolution of
1/1000000th of a second.</p>
</td></tr><tr><td>$CHALK_CONFIG</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>This key is only used with chalk executables. It holds the embedded
configuration for that instance of the chalk command.</p>
<p>Chalk executables can only have their configuration changed via the
<code>chalk config</code> command, or <code>chalk setup</code>.</p>
</td></tr><tr><td>$CHALK_IMPLEMENTATION_NAME</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Added to chalk binaries to indicate the implementation of Chalk in use.</p>
</td></tr><tr><td>$CHALK_LOAD_COUNT</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Count how many times the self-mark has been rewritten.</p>
</td></tr><tr><td>$CHALK_PUBLIC_KEY</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Used for attestations.</p>
</td></tr><tr><td>$CHALK_ENCRYPTED_PRIVATE_KEY</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Also necessary for attestations.</p>
</td></tr><tr><td>$CHALK_API_KEY</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>API key used to optionally save/load attestation keys to cloud.</p>
</td></tr><tr><td>$CHALK_API_REFRESH_TOKEN</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>Key to hold the OIDC refresh token for non-user present API
re-authentication.</p>
</td></tr><tr><td>$CHALK_ATTESTATION_TOKEN</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>...</p>
</td></tr><tr><td>$CHALK_SECRET_ENDPOINT_URI</td><td>Chalk-Time, Artifact</td><td>string</td><td><p>...</p>
</td></tr><tr><td>$CHALK_SAVED_COMPONENT_PARAMETERS</td><td>Chalk-Time, Artifact</td><td>`x</td><td><p>This is where we save configuration parameters for components that
have been imported.</p>
<p>The items in the list consist of five-tuples:</p>
<ol>
<li>A boolean indicating whether it's an attribute parameter (false
means it's a variable parameter)</li>
<li>The base URL reference for the component</li>
<li>The name of the variable or attribute.</li>
<li>The Con4m type of the parameter.</li>
<li>The stored value (which will be of the type provided)</li>
</ol>
</td></tr><tr><td>$CHALK_COMPONENT_CACHE</td><td>Chalk-Time, Artifact</td><td>dict[string, string]</td><td><p>This consists of URLs (minus the file extension) mapped to source code
for components.</p>
</td></tr></tbody><caption>See <em>help key &lt;term&gt;</em> to search the table only</caption></table>
