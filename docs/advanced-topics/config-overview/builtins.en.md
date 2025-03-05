---
title:
description:
---

# Builtin Functions for Configuration Files

## Builtins in category:_type conversion_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```bool(int) -> bool```</td><td><p>Converts an <code>int</code> to <code>true</code>/<code>false</code>. 0 is <code>false</code>, everything else is <code>true</code>.</p>
</td></tr><tr><td>```bool(float) -> bool```</td><td><p>Converts a <code>float</code> to <code>true</code>/<code>false</code>.</p>
</td></tr><tr><td>```bool(string) -> bool```</td><td><p>If the string is empty, returns <code>false</code>. Otherwise, returns <code>true</code>.</p>
</td></tr><tr><td>```bool(list[`x]) -> bool```</td><td><p>Returns <code>false</code> if the list is empty, <code>true</code> otherwise.</p>
</td></tr><tr><td>```bool(dict[`x, `y]) -> bool```</td><td><p>Returns <code>false</code> if the dict is empty, <code>true</code> otherwise</p>
</td></tr><tr><td>```float(int) -> float```</td><td><p>Converts the value into a <code>float</code>.</p>
</td></tr><tr><td>```int(float) -> int```</td><td><p>Converts a <code>float</code> to an <code>int</code>, with typical truncation semantics.</p>
</td></tr><tr><td>```int(char) -> int```</td><td><p>Casts a char to an int</p>
</td></tr><tr><td>```$(`t) -> string```</td><td><p>Converts any value into a <code>string</code>.</p>
</td></tr><tr><td>```Duration(string) -> Duration```</td><td><p>Parses a <code>string</code> into a <code>Duration</code> object. The config will error if the conversion fails.</p>
<p><code>Duration</code> literals accept:</p>
<ul>
<li>us usec usecs</li>
<li>ms msec msecs</li>
<li>s sec secs seconds</li>
<li>m min mins minutes</li>
<li>h hr hrs hours</li>
<li>d day days</li>
<li>w wk wks week weeks</li>
<li>y yr yrs year years</li>
</ul>
<p>None of the above categories should be repeated. Multiple items can be space separated (though it is optional).</p>
<p>For instance, <code>1 week 2 days</code> is valid, as is:
<code>4yrs 2 days 4 hours 6min7sec2years</code></p>
<p>This is the exact same syntax as if you declare a <code>Duration</code> literal directly, except for the quoting mechanism. Specifically:
<code>myduration := &lt;&lt;1 hr 10 mins&gt;&gt;</code>
Is effectively the same as:
<code>myduration := Duration(&quot;1 hr 10 mins&quot;)</code></p>
<p>Except that syntax errors will be found before running the script in
the first case.</p>
</td></tr><tr><td>```IPAddr(string) -> IPAddr```</td><td><p>Parses a <code>string</code> into an IP address. Both ipv4 and ipv6 addresses are allowed, but blocks of addresses are not; use the CIDR type for that.</p>
<p>Generally, using this function to convert from a <code>string</code> is not necessary; you can write IPAddr literals with 'special' literal quotes:
<code>x := &lt;&lt; 2001:db8:1::ab9:C0A8:102 &gt;&gt;</code>
is functionally equal to:
<code>x := IPAddr(&quot;2001:db8:1::ab9:C0A8:102&quot;)</code></p>
<p>In the first case, con4m will catch syntax errors before the configuration starts executing. In the second, the checking won't be until runtime, at which point the config execution will abort with an error.</p>
</td></tr><tr><td>```CIDR(string) -> CIDR```</td><td><p>Parses a <code>string</code> that specifies a block of IP addresses into a <code>CIDR</code> type. CIDR stands for Classless Inter-Domain Routing; it's the standard way to express subnets.</p>
<p>Generally, using this function to convert from a <code>string</code> is not necessary; you can write <code>CIDR</code> literals with 'special' literal quotes:
<code>x := &lt;&lt; 192.168.0.0/16 &gt;&gt;</code>
is functionally equal to:
<code>x := CIDR(&quot;192.168.0.0/16&quot;)</code></p>
<p>In the first case, con4m will catch syntax errors before the configuration starts executing. In the second, the checking won't be until runtime, at which point the config execution will abort with an error. IPv6 addresses are also supported. Either of the following work:</p>
<pre><code class="language-x">x := CIDR(&quot;2001:db8:1::ab9:C0A8:102/127&quot;)```
</code></pre>
</td></tr><tr><td>```Size(string) -> Size```</td><td><p>Converts a <code>string</code> representing a size in bytes into a con4m <code>Size</code> object.
A size object can use any of the following units:</p>
<ul>
<li>b, B, bytes, Bytes    -- bytes</li>
<li>k, K, kb, Kb, KB      -- kilobytes (1000 bytes)</li>
<li>ki, Ki, kib, KiB, KIB -- kibibytes (1024 bytes)</li>
<li>m, M, mb, Mb, MB      -- megabytes (1,000,000 bytes)</li>
<li>mi, Mi, mib, MiB, MIB -- mebibytes (1,048,576 bytes)</li>
<li>g, G, gb, Gb, GB      -- gigabytes (1,000,000,000 bytes)</li>
<li>gi, Gi, gib, GiB, GIB -- gibibytes (1,073,741,824 bytes)</li>
<li>t, T, tb, Tb, TB      -- terabytes (10^12 bytes)</li>
<li>ti, Ti, tib, TiB, TIB -- tebibytes (2^40 bytes)</li>
</ul>
<p>The following are functionally equal:</p>
<pre><code>x := &lt;&lt; 200ki &gt;&gt;
</code></pre>
<p>and:</p>
<pre><code>x := Size(&quot;200ki&quot;)
</code></pre>
<p>The main difference is that the former is checked for syntax problems before execution, and the later is checked when the call is made.</p>
</td></tr><tr><td>```Date(string) -> Date```</td><td><p>Converts a <code>string</code> representing a date into a Con4m date object. We generally accept ISO dates.</p>
<p>However, we assume that it might make sense for people to only provide one of the three items, and possibly two. Year and day of month without the month probably doesn't make sense often, but whatever.</p>
<p>But even the old ISO spec doesn't accept all variations (you can't even do year by itself. When the <em>year</em> is omitted, we use the <em>old</em> ISO format, in hopes that it will be recognized by most software.</p>
<p>Specifically, depending on a second omission, the format will be:</p>
<pre><code>--MM-DD
--MM
---DD
</code></pre>
<p>However, if the year is provided, we will instead turn omitted numbers into 0's, because for M and D that makes no semantic sense (whereas it does for Y), so should be unambiguous and could give the right reuslts depending on the checking native libraries do when parsing.</p>
<p>We also go the ISO route and only accept 4-digit dates. And, we don't worry about negative years. They might hate me in the year 10,000, but I don't think there are enough cases where someone needs to specify &quot;200 AD&quot; in a config file to deal w/ the challenges with not fixing the length of the year field.</p>
<p>There is a separate <code>DateTime</code> type.</p>
<p>The following are all valid con4m <code>Date</code> objects:</p>
<pre><code>x := Date(&quot;Jan 7, 2007&quot;)
x := Date(&quot;Jan 18 2027&quot;)
x := Date(&quot;Jan 2027&quot;)
x := Date(&quot;Mar 0600&quot;)
x := Date(&quot;2 Mar 1401&quot;)
x := Date(&quot;2 Mar&quot;)
x := Date(&quot;2004-01-06&quot;)
x := Date(&quot;--03-02&quot;)
x := Date(&quot;--03&quot;)
</code></pre>
<p>The following give the same effective results as above, but syntax errors are surfaced at compile time instead of run time:</p>
<pre><code>x := &lt;&lt; Jan 7, 2007 &gt;&gt;
x := &lt;&lt; Jan 18 2027 &gt;&gt;
x := &lt;&lt; Jan 2027 &gt;&gt;
x := &lt;&lt; Mar 0600 &gt;&gt;
x := &lt;&lt; 2 Mar 1401 &gt;&gt;
x := &lt;&lt; 2 Mar &gt;&gt;
x := &lt;&lt; 2004-01-06 &gt;&gt;
x := &lt;&lt; --03-02 &gt;&gt;
x := &lt;&lt; --03 &gt;&gt;
</code></pre>
</td></tr><tr><td>```Time(string) -> Time```</td><td><p>Conversion of a <code>string</code> to a con4m <code>Time</code> specification, which follows ISO standards, including Z. The following are valid <code>Time</code> objects:</p>
<pre><code>x := Time(&quot;12:23:01.13131423424214214-12:00&quot;)
x := Time(&quot;12:23:01.13131423424214214Z&quot;)
x := Time(&quot;12:23:01+23:00&quot;)
x := Time(&quot;2:03:01+23:00&quot;)
x := Time(&quot;02:03+23:00&quot;)
x := Time(&quot;2:03+23:00&quot;)
x := Time(&quot;2:03&quot;)
</code></pre>
<p>The following are identical, except that syntax errors are surfaced before execution begins:</p>
<pre><code>x := &lt;&lt; 12:23:01.13131423424214214-12:00 &gt;&gt;
x := &lt;&lt; 12:23:01.13131423424214214Z &gt;&gt;
x := &lt;&lt; 12:23:01+23:00 &gt;&gt;
x := &lt;&lt; 2:03:01+23:00 &gt;&gt;
x := &lt;&lt; 02:03+23:00 &gt;&gt;
x := &lt;&lt; 2:03+23:00 &gt;&gt;
x := &lt;&lt; 2:03 &gt;&gt;
</code></pre>
</td></tr><tr><td>```DateTime(string) -> DateTime```</td><td><p>Conversion of a <code>string</code> to a <code>DateTime</code> type, which follows ISO standards, including Z, though see notes on the separate Date type.</p>
<p>The following are valid DateType objects:</p>
<pre><code>x := DateTime(&quot;2004-01-06T12:23:01+23:00&quot;)
x := DateTime(&quot;--03T2:03&quot;)
x := DateTime(&quot;2 Jan, 2004 T 12:23:01+23:00&quot;)
</code></pre>
<p>The following are identical, except that syntax errors are surfaced before execution begins:</p>
<pre><code>x := &lt;&lt; 2004-01-06T12:23:01+23:00 &gt;&gt;
x := &lt;&lt; --03T2:03 &gt;&gt;
x := &lt;&lt; 2 Jan, 2004 T 12:23:01+23:00 &gt;&gt;
</code></pre>
</td></tr><tr><td>```char(int) -> char```</td><td><p>Casts an int to a char, truncating on overflow</p>
</td></tr><tr><td>```to_usec(Duration) -> int```</td><td><p>Cast a duration object to an integer in seconds</p>
</td></tr><tr><td>```to_msec(Duration) -> int```</td><td><p>Convert a Duration object into an int representing msec</p>
</td></tr><tr><td>```to_sec(Duration) -> int```</td><td><p>Convert a Duration object into an int representing seconds, truncating any sub-second information.</p>
</td></tr><tr><td>```to_type(string) -> typespec```</td><td><p>Turns a <code>string</code> into a <code>typespec</code> object. Errors cause execution to terminate with an error. Generally, this shouldn't be necessary in user configuration files. Even if the user needs to name a type in a config file, the can directly write type literals.</p>
<p>For instance:</p>
<pre><code>x := to_type(&quot;list[string]&quot;)
</code></pre>
<p>is equal to:</p>
<pre><code>x := list[string]
</code></pre>
</td></tr><tr><td>```to_chars(string) -> list[char]```</td><td><p>Turns a <code>string</code> into an array of characters. These are unicode characters, not ASCII characters. Use <code>to_bytes()</code> to turn into bytes.</p>
<p>If the string isn't valid UTF-8, evaluation will stop with an error.</p>
</td></tr><tr><td>```to_bytes(string) -> list[char]```</td><td><p>Turns a <code>string</code> into an array of 8-bit bytes.</p>
</td></tr><tr><td>```to_string(list[char]) -> string```</td><td><p>Turn a list of characters into a <code>string</code> object. Will work for both arrays utf8 codepoints and for raw bytes.</p>
</td></tr></tbody></table>

## Builtins in category:_string_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```contains(string, string) -> bool```</td><td><p>Returns <code>true</code> if the first argument contains the second argument.</p>
</td></tr><tr><td>```starts_with(string, string) -> bool```</td><td><p>Returns <code>true</code> if the first argument starts with the second argument.</p>
</td></tr><tr><td>```ends_with(string, string) -> bool```</td><td><p>Returns <code>true</code> if the first argument ends with the second argument.</p>
</td></tr><tr><td>```find(string, string) -> int```</td><td><p>If the first argument contains the first <code>string</code> anywhere in it, this returns the index of the first match. Otherwise, it returns -1 to indicate no match.</p>
</td></tr><tr><td>```len(string) -> int```</td><td><p>Returns the length of a <code>string</code> in bytes. This does NOT return the number of characters if there are multi-byte characters. <code>utf8_len()</code> does that.</p>
</td></tr><tr><td>```slice(string, int) -> string```</td><td><p>Returns a new <code>string</code> that's a substring of the first one, starting at the given index, continuing through to the end of the string. This has Python-like semantics, accepting negative numbers to index from the back.</p>
</td></tr><tr><td>```slice(string, int, int) -> string```</td><td><p>Returns a new <code>string</code> that's a substring of the first one, starting at the given index, continuing through to the second index (non-inclusive). This has Python-like semantics, accepting negative numbers to index from the back.</p>
</td></tr><tr><td>```slice(list[`x], int, int) -> list[`x]```</td><td><p>Returns a new list that's derived by copying from the first one, starting at the given index, continuing through to the second index (non-inclusive). This has python-like semantics, accepting negative numbers to index from the back.</p>
</td></tr><tr><td>```split(string, string) -> list[string]```</td><td><p>Turns a list into an array by splitting the first <code>string</code> based on the second <code>string</code>. The second <code>string</code> will not appear in the output.</p>
</td></tr><tr><td>```strip(string) -> string```</td><td><p>Returns a copy of the input, with any leading or trailing white space removed.</p>
</td></tr><tr><td>```pad(string, int) -> string```</td><td><p>Return a copy of the input <code>string</code> that is at least as wide as indicated by the integer parameter. If the input <code>string</code> is not long enough, spaces are added to the end.</p>
</td></tr><tr><td>```format(string) -> string```</td><td><p>Makes substitutions within a <code>string</code>, based on variables that are in scope. For the input <code>string</code>, anything inside braces {} will be treated as a specifier. You can access attributes that are out of scope by fully dotting from the top-level name. All tags are currently part of the dotted name. You can use both attributes and variables in a specifier. strings, bools, ints and floats are acceptable for specifiers, but lists and dictionaries are not.</p>
<p>There is currently no way to specify things like padding and alignment in a format specifier. If you want to insert an actual { or } character that shouldn't be part of a specifier, quote them by doubling them up (e.g., {{ to get a single left brace).</p>
</td></tr><tr><td>```base64(string) -> string```</td><td><p>Returns a base64-encoded version of the <code>string</code>, using the traditional Base64 character set.</p>
</td></tr><tr><td>```base64_web(string) -> string```</td><td><p>Returns a base64-encoded version of the <code>string</code>, using the web-safe Base64 character set.</p>
</td></tr><tr><td>```debase64(string) -> string```</td><td><p>Decodes a base64 encoded <code>string</code>, accepting either common character set.</p>
</td></tr><tr><td>```hex(string) -> string```</td><td><p>Hex-encodes a string.</p>
</td></tr><tr><td>```hex(int) -> string```</td><td><p>Turns an integer into a hex-encoded <code>string</code>.</p>
</td></tr><tr><td>```dehex(string) -> string```</td><td><p>Takes a hex-encoded <code>string</code>, and returns a <code>string</code> with the hex-decoded bytes.</p>
</td></tr><tr><td>```sha256(string) -> string```</td><td><p>Computes the SHA-256 hash of a <code>string</code>, returning the result as a hex-encoded <code>string</code>.</p>
</td></tr><tr><td>```sha512(string) -> string```</td><td><p>Computes the SHA-512 hash of a <code>string</code>, returning the result as a hex-encoded <code>string</code>.</p>
</td></tr><tr><td>```upper(string) -> string```</td><td><p>Converts any unicode characters to their upper-case representation, where possible, leaving them alone where not.</p>
</td></tr><tr><td>```lower(string) -> string```</td><td><p>Converts any unicode characters to their lower-case representation, where possible, leaving them alone where not.</p>
</td></tr><tr><td>```join(list[string], string) -> string```</td><td><p>Creates a single <code>string</code> from a list of <code>string</code>, by adding the second value between each item in the list.</p>
</td></tr></tbody></table>

## Builtins in category:_dict_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```contains(list[`x], `x) -> bool```</td><td><p>Returns <code>true</code> if the first argument contains the second argument.</p>
</td></tr><tr><td>```contains(dict[`x, `y], `x) -> bool```</td><td><p>Returns <code>true</code> if the second argument is a set key in the dictionary, <code>false</code> otherwise.</p>
</td></tr><tr><td>```len(dict[`x, `y]) -> int```</td><td><p>Returns the number of items contained in a dict</p>
</td></tr><tr><td>```keys(dict[`x, `y]) -> list[`x]```</td><td><p>Returns a list of the keys in a dictionary.</p>
</td></tr><tr><td>```values(dict[`x, `y]) -> list[`y]```</td><td><p>Returns a list of the values in a dictionary.</p>
</td></tr><tr><td>```items(dict[`x, `y]) -> list[(`x, `y) -> void]```</td><td><p>Returns a list containing two-tuples representing the keys and values in a dictionary.</p>
</td></tr><tr><td>```set(dict[`k, `v], `k, `v) -> dict[`k, `v]```</td><td><p>Returns a new dictionary based on the old dictionary, except that the new key/value pair will be set. If the key was set in the old dictionary, the value will be replaced.</p>
<p>NO values in Con4m can be mutated. Everything copies.</p>
</td></tr><tr><td>```delete(dict[`k, `v], `k) -> dict[`k, `v]```</td><td><p>Returns a new dictionary that is a copy of the input dictionary, except the specified key will not be present, if it existed.</p>
<p>NO values in Con4m can be mutated. Everything copies.</p>
</td></tr></tbody></table>

## Builtins in category:_list_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```len(list[`x]) -> int```</td><td><p>Returns the number of items in a list.</p>
</td></tr><tr><td>```set(list[`x], int, `x) -> list[`x]```</td><td><p>This creates a new list, that is a copy of the original list, except that the index specified by the second parameter is replaced with the value in the third parameter.</p>
<p>NO values in Con4m can be mutated. Everything copies.</p>
</td></tr><tr><td>```delete(list[`x], `x) -> list[`x]```</td><td><p>Returns a new list, based on the one passed in the first parameter, where any instances of the item (the second parameter) are removed. If the item does not appear, a copy of the original list will be returned.</p>
<p>NO values in Con4m can be mutated. Everything copies.</p>
</td></tr><tr><td>```remove(list[`x], int) -> list[`x]```</td><td><p>This returns a copy of the first parameter, except that the item at the given index in the input will not be in the output. This has Python indexing semantics.</p>
<p>NO values in Con4m can be mutated. Everything copies.</p>
</td></tr><tr><td>```array_add(list[`x], list[`x]) -> list[`x]```</td><td><p>This creates a new list by concatenating the items in two lists.</p>
<p>Con4m requires all items in a list have a comptable type.</p>
</td></tr></tbody></table>

## Builtins in category:_character_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```replace(string, string, string) -> string```</td><td><p>Return a copy of the first argument, where any instances of the second argument are replaced with the third argument.</p>
</td></tr><tr><td>```utf8_len(char) -> int```</td><td><p>Return the number of UTF-8 encoded characters (aka codepoints) in a <code>string</code>.</p>
</td></tr><tr><td>```is_combining(char) -> bool```</td><td><p>Returns <code>true</code> if a character is a UTF-8 combining character, and <code>false</code> otherwise.</p>
</td></tr><tr><td>```is_lower(char) -> bool```</td><td><p>Returns <code>true</code> if the given character is a lower case character, <code>false</code> otherwise.
This function is unicode aware.</p>
</td></tr><tr><td>```is_upper(char) -> bool```</td><td><p>Returns <code>true</code> if the given character is an upper case character, <code>false</code> otherwise.
This function is unicode aware.</p>
</td></tr><tr><td>```is_space(char) -> bool```</td><td><p>Returns <code>true</code> if the given character is a valid space character, per  the Unicode specification.</p>
</td></tr><tr><td>```is_alpha(char) -> bool```</td><td><p>Returns <code>true</code> if the given character is considered an alphabet character in the Unicode spec.</p>
</td></tr><tr><td>```is_num(char) -> bool```</td><td><p>Returns <code>true</code> if the given character is considered an number in the Unicode spec.</p>
</td></tr><tr><td>```is_alphanum(char) -> bool```</td><td><p>Returns <code>true</code> if the given character is considered an alpha-numeric character in the Unicode spec.</p>
</td></tr></tbody></table>

## Builtins in category:_filesystem_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```list_dir() -> list[string]```</td><td><p>Returns a list of files in the current working directory.</p>
</td></tr><tr><td>```list_dir(string) -> list[string]```</td><td><p>Returns a list of files in the specified directory. If the directory is invalid, no error is given; the results will be the same as if the directory were empty.</p>
</td></tr><tr><td>```read_file(string) -> string```</td><td><p>Returns the contents of the file. On error, this will return the empty <code>string</code>.</p>
</td></tr><tr><td>```write_file(string, string) -> bool```</td><td><p>Writes, to the file name given in the first argument, the value of the <code>string</code> given in the second argument. Returns <code>true</code> if successful, <code>false</code> otherwise.</p>
</td></tr><tr><td>```copy_file(string, string) -> bool```</td><td><p>Copies the contents of the file specified by the first argument to the file specified by the second, creating the new file if necessary,  overwriting it otherwise. Returns <code>true</code> if successful, <code>false</code> otherwise.</p>
</td></tr><tr><td>```move_file(string, string) -> bool```</td><td><p>Moves the file specified by the first argument to the location specified by the second, overwriting any file, if present. Returns <code>true</code> if successful, <code>false</code> otherwise.</p>
</td></tr><tr><td>```rm_file(string) -> bool```</td><td><p>Removes the specified file, if it exists, and the operation is allowed.  Returns <code>true</code> if successful.</p>
</td></tr><tr><td>```join_path(string, string) -> string```</td><td><p>Combines two pieces of a path in a way where you don't have to worry about extra slashes.</p>
</td></tr><tr><td>```resolve_path(string) -> string```</td><td><p>Turns a possibly relative path into an absolute path. This also expands home directories.</p>
</td></tr><tr><td>```path_split(string) -> tuple[string, string]```</td><td><p>Separates out the final path component from the rest of the path, i.e., typically used to split out the file name from the remainder of the path.</p>
</td></tr><tr><td>```find_exe(string, list[string]) -> string```</td><td><p>Locate an executable with the given name in the PATH, adding any extra
directories passed in the second argument.</p>
</td></tr><tr><td>```cwd() -> string```</td><td><p>Returns the current working directory of the process.</p>
</td></tr><tr><td>```chdir(string) -> bool```</td><td><p>Changes the current working directory of the process. Returns <code>true</code> if successful.</p>
</td></tr><tr><td>```mkdir(string) -> bool```</td><td><p>Creates a directory, and returns <code>true</code> on success.</p>
</td></tr><tr><td>```is_dir(string) -> bool```</td><td><p>Returns <code>true</code> if the given file name exists at the time of the call, and is a directory.</p>
</td></tr><tr><td>```is_file(string) -> bool```</td><td><p>Returns <code>true</code> if the given file name exists at the time of the call,  and is a regular file.</p>
</td></tr><tr><td>```is_link(string) -> bool```</td><td><p>Returns <code>true</code> if the given file name exists at the time of the call, and is a link.</p>
</td></tr><tr><td>```chmod(string, int) -> bool```</td><td><p>Attempt to set the file permissions; returns <code>true</code> if successful.</p>
</td></tr><tr><td>```file_len(string) -> int```</td><td><p>Returns the number of bytes in the specified file, or -1 if there is an error (e.g., no file, or not readable).</p>
</td></tr><tr><td>```to_tmp_file(string, string) -> string```</td><td><p>Writes the <code>string</code> in the first argument to a new temporary file. The second argument specifies an extension; a random value is used in the tmp file name.</p>
<p>This call returns the location that the file was written to.</p>
</td></tr></tbody></table>

## Builtins in category:_system_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```echo(*`a) -> void```</td><td><p>Output any parameters passed (after automatic conversion to string). A newline is added at the end, but no spaces are added between arguments.</p>
<p>This outputs to stderr, NOT stdout.</p>
<p><code>echo()</code> is the only function in con4m that:</p>
<ul>
<li>Accepts variable arguments</li>
<li>Automatically converts items to strings.</li>
</ul>
</td></tr><tr><td>```abort(string) -> void```</td><td><p>Prints the given error message, then stops the entire program immediately  (not just the config file execution).</p>
<p>The exit code of the process will be 1.</p>
</td></tr><tr><td>```env() -> dict[string, string]```</td><td><p>Returns all environment variables set for the process.</p>
</td></tr><tr><td>```env(string) -> string```</td><td><p>Returns the value of a specific environment variable. If the environment variable isn't set, you will get the empty string (<code>&quot;&quot;</code>), same as if the value is explicitly set, but to no value.</p>
<p>To distinguish between the two cases, either call <code>env_exists()</code> or dump all environment variables to a dictionary via <code>env()</code> and then call <code>contains()</code>.</p>
</td></tr><tr><td>```env_exists(string) -> bool```</td><td><p>Returns <code>true</code> if the parameter is a named environment variable in the current environment.</p>
</td></tr><tr><td>```set_env(string, string) -> bool```</td><td><p>Sets the value of the environment variable passed in the first parameter, to the value from the second parameter. It returns <code>true</code> if successful.</p>
</td></tr><tr><td>```getpid() -> int```</td><td><p>Return the process ID of the current process</p>
</td></tr><tr><td>```quote(string) -> string```</td><td><p>Quote a <code>string</code>, so that it can be safely passed as a parameter to any shell (e.g., via <code>run()</code>)</p>
</td></tr><tr><td>```osname() -> string```</td><td><p>Return a <code>string</code> containing the runtime operating system used. Possible values: &quot;macos&quot;, &quot;linux&quot;, &quot;windows&quot;, &quot;netbsd&quot;, &quot;freebsd&quot;, &quot;openbsd&quot;.</p>
</td></tr><tr><td>```arch() -> string```</td><td><p>Return a <code>string</code> containing the underlying hardware architecture. Supported values: &quot;amd64&quot;, &quot;arm64&quot;</p>
<p>The value &quot;amd64&quot; is returned for any x86-64 platform. Other values may be returned on other operating systems, such as i386 on 32-bit X86, but Con4m is not built or tested against other environments.</p>
</td></tr><tr><td>```program_args() -> list[string]```</td><td><p>Return the arguments passed to the program. This does <em>not</em> include the program name.</p>
</td></tr><tr><td>```program_path() -> string```</td><td><p>Returns the absolute path of the currently running program.</p>
</td></tr><tr><td>```program_name() -> string```</td><td><p>Returns the name of the executable program being run, without any path
component.</p>
</td></tr><tr><td>```high() -> int```</td><td><p>Returns the highest possible value storable by an int. The int data type is always a signed 64-bit value, so this will always be: 9223372036854775807</p>
</td></tr><tr><td>```low() -> int```</td><td><p>Returns the lowest possible value storable by an int. The int data type is always a signed 64-bit value, so this will always be: -9223372036854775808</p>
</td></tr><tr><td>```rand() -> int```</td><td><p>Return a secure random, uniformly distributed 64-bit number.</p>
</td></tr><tr><td>```now() -> int```</td><td><p>Return the current Unix time in ms since Jan 1, 1970. Divide by 1000 for seconds.</p>
</td></tr><tr><td>```container_name() -> string```</td><td><p>Returns the name of the container we're running in, or the empty string if we
don't seem to be running in one.</p>
</td></tr><tr><td>```in_container() -> bool```</td><td><p>Returns true if we can determine that we're running in a container, and false
if not.</p>
</td></tr><tr><td>```copy_object(string, string) -> bool```</td><td><p>Deep-copys a con4m object specified by full path in the first parameter, creating the object named in the second parameter.</p>
<p>Note that the second parameter cannot be in dot notation; the new object will be created in the same scope of the object being copied.</p>
<p>For instance, <code>copy_object(&quot;profile.foo&quot;, &quot;bar&quot;)</code> will create <code>&quot;profile.bar&quot;</code></p>
<p>This function returns <code>true</code> on success. Reasons it would fail:</p>
<ol>
<li>The source path doesn't exist.</li>
<li>The source path exists, but is a field, not an object.</li>
<li>The destination already exists.</li>
</ol>
<p>Note that this function does not enforce any c42 specification
itself. So if you copy a singleton object that doesn't comply with the
section, nothing will complain until (and if) a validation occurs.</p>
</td></tr></tbody></table>

## Builtins in category:_binary_ops_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```bitor(int, int) -> int```</td><td><p>Returns the bitwise OR of its parameters.</p>
</td></tr><tr><td>```bitand(int, int) -> int```</td><td><p>Returns the bitwise AND of its parameters.</p>
</td></tr><tr><td>```xor(int, int) -> int```</td><td><p>Returns the bitwise XOR of its parameters.</p>
</td></tr><tr><td>```shl(int, int) -> int```</td><td><p>Shifts the bits of the first argument left by the number of bits indicated by the second argument.</p>
</td></tr><tr><td>```shr(int, int) -> int```</td><td><p>Shifts the bits of the first argument right by the number of bits indicated by the second argument. Note that this operation is a pure shift; it does NOT maintain the sign bit.</p>
<p>That is, it acts as if the two parameters are unsigned.</p>
</td></tr><tr><td>```bitnot(int) -> int```</td><td><p>Returns a new integer where every bit from the input is flipped.</p>
</td></tr></tbody></table>

## Builtins in category:_parsing_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```mime_to_dict(string) -> dict[string, string]```</td><td><p>Takes a <code>string</code> consisting of mime headers, and converts them into  a dictionary of key/value pairs.</p>
<p>For instance:</p>
<pre><code>mime_to_dict(&quot;Content-Type: text/html\r\nCustom-Header: hi!\r\n&quot;)
</code></pre>
<p>will return:</p>
<pre><code>{ &quot;Content-Type&quot; : &quot;text/html&quot;,
  &quot;Custom-Header&quot; : &quot;hi!&quot;
}
</code></pre>
<p>Note that lines that aren't validly formatted are skipped.</p>
</td></tr></tbody></table>

## Builtins in category:_network_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```url_get(string) -> string```</td><td><p>Retrieve the contents of the given URL, returning a string. If it's
a HTTPS URL, the remote host's certificate chain must validate for
data to be returned.</p>
<p>If there is an error, the first three digits will be an error code,
followed by a space, followed by any returned message. If the error
wasn't from a remote HTTP response code, it will be 000.</p>
<p>Requests that take more than 5 seconds will be canceled.</p>
</td></tr><tr><td>```url_get_pinned(string, string) -> string```</td><td><p>Same as <code>url_get()</code>, except takes a second parameter, which is a path to a
pinned certificate.</p>
<p>The certificate will only be checked if it's an HTTPS connection, but
the remote connection <em>must</em> be the party associated with the
certificate passed, otherwise an error will be returned, instead of data.</p>
</td></tr><tr><td>```url_post(string, string, dict[string, string]) -> string```</td><td><p>Uses HTTP post to post to a given URL, returning the resulting as a
string, if successful. If not, the error code works the same was as
for <code>url_get()</code>.</p>
<p>The parameters here are:</p>
<ol>
<li>The URL to which to post</li>
<li>The body to send with the request</li>
<li>The MIME headers to send, as a dictionary. Generally you should at least
pass a Content-Type field (e.g., {&quot;Content-Type&quot; : &quot;text/plain&quot;}). Con4m
will NOT assume one for you.</li>
</ol>
<p>Requests that take more than 5 seconds will be canceled.</p>
</td></tr><tr><td>```external_ip() -> string```</td><td><p>Returns the external IP address for the current machine.</p>
</td></tr><tr><td>```url_post_pinned(string, string, dict[string, string], string) -> string```</td><td><p>Same as <code>url_post()</code>, but takes a certificate file location in the final
parameter, with which HTTPS connections must authenticate against.</p>
</td></tr></tbody></table>

## Builtins in category:_posix_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```run(string) -> string```</td><td><p>Execute the passed parameter via a shell, returning the output. This function blocks while the subprocess runs.</p>
<p>The exit code is not returned in this version.</p>
<p>Stdout and Stderr are combined in the output.</p>
</td></tr><tr><td>```system(string) -> tuple[string, int]```</td><td><p>Execute the passed parameter via a shell, returning a tuple containing the output and the return code of the subprocess. This function blocks while the subprocess runs.</p>
<p>Stdout and Stderr are combined in the output.</p>
</td></tr><tr><td>```getuid() -> int```</td><td><p>Returns the real UID of the underlying logged in user.</p>
</td></tr><tr><td>```geteuid() -> int```</td><td><p>Returns the effective UID of the underlying logged in user.</p>
</td></tr><tr><td>```uname() -> list[string]```</td><td><p>Returns a <code>string</code> with common system information, generally should be the same as running <code>uname -a</code> on the commadn line.</p>
</td></tr><tr><td>```using_tty() -> bool```</td><td><p>Returns <code>true</code> if the current process is attached to a TTY (unix terminal driver). Generally, logged-in users can be expected to have a TTY (though some automation tools can have a TTY with no user).</p>
<p>Still, it's common to act as if a user is present when there is a TTY. For instance, it's common to default to showing colors when attached to a TTY, but to default to no-color otherwise.</p>
</td></tr><tr><td>```tty_name() -> string```</td><td><p>Returns the name of the current tty, if any.</p>
</td></tr></tbody></table>

## Builtins in category:_chalk_

<table><thead><tr><th>Signature</th><th>Description</tr></thead><tbody><tr><td>```version() -> string```</td><td><p>The current version of the chalk program.</p>
</td></tr><tr><td>```subscribe(string, string) -> bool```</td><td><p>For the topic name given in the first parameter, subscribes the sink
configuration named in the second parameter.  The sink configuration
object must already be defined at the time of the call to subscribe()</p>
</td></tr><tr><td>```unsubscribe(string, string) -> bool```</td><td><p>For the topic name given in the first parameter, unsubscribes the sink
configuration named in the second parameter, if subscribed.</p>
</td></tr><tr><td>```error(string) -> void```</td><td><p>Immediately publishes a diagnostic message at log-level 'error'.  Whether this
gets delivered or not depends on the configuration.  Generally, errors will go
both to stderr, and be put in any published report.</p>
</td></tr><tr><td>```warn(string) -> void```</td><td><p>Immediately publishes a diagnostic message at log-level 'warn'.  Whether this
gets delivered or not depends on the configuration.  Generally, warnings go to
stderr, unless wrapping the docker command, but do not get published to reports.</p>
</td></tr><tr><td>```info(string) -> void```</td><td><p>Immediately publishes a diagnostic message at log-level 'info'.  Whether this
gets delivered or not depends on the configuration, but may be off by default.</p>
</td></tr><tr><td>```trace(string) -> void```</td><td><p>Immediately publishes a diagnostic message at log-level 'trace' (aka verbose).
Generally, these can get very noisy, and are intended more for testing,
debugging, etc.</p>
</td></tr><tr><td>```command_argv() -> list[string]```</td><td><p>Returns the arguments being passed to the command, such as the path
parameters.  This is not the same as the underlying process's argv; it
represents the arguments getting passed to the underlying chalk command.</p>
</td></tr><tr><td>```command_name() -> string```</td><td><p>Returns the name of the chalk command being run (not the underlying
executable name).</p>
</td></tr></tbody></table>
