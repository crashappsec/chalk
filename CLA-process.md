Sign the CLA
=============

This is a step-by-step guide to signing the Crash Override
Contributors License Agreement via Pull Request. 

1. Please read the current versions of the
   [individual CLA here](cla-individual-1.0.md) or [entity CLA here](cla-entity-1.0.md)
   and ensure you understand and agree to them. If you have any questions please reach
   out to us at [opensource@crashoverride.com](mailto:opensource@crashoverride.com).

3. If you don't already have one make an account on [GitHub](https://github.com/).

4. File a pull request on the Chalk project, as [shown here](#filing-the-pull-request).

5. Email the Crash Override team, as [shown here](#sending-the-email).

6. Wait for someone from the team to merge your pull request. You may start
   opening pull requests for the project but we will only be able to merge
   your contributions after your signed CLA is merged.

* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *

Filing the Pull Request
-----------------------

If you don't yet know how to file a pull request, read [GitHub's
document about it](https://help.github.com/articles/using-pull-requests).

Make your pull request be the addition of a single file to the
[contributors](contributors) directory of this project. Name the file
with the same name as your GitHub userid, with `.md` appended to the
end. For example, for the user `ZeroCool_1995`, the full path to the file
would be `contributors/zerocool_1995.md`.

If you are contributing as an individual the contents of the file should
look as follows:

```
[date in YYYY-MM-DD format]

I hereby agree to the terms of the Individual Contributors License
Agreement, version 1.0, with MD5 checksum
2acaee37d7cd4ca34c537bcc0d5ef6d9.

I furthermore declare that I am authorized and able to make this
agreement and sign this declaration.

Signed,

[your name]
https://github.com/[your github userid]
```

If you are contributing as an entity the contents of the file should
look as follows:

```
[date YYYY-MM-DD]

I hereby agree to the terms of the Entity Contributors License
Agreement, version 1.0, with MD5 checksum
59ea9b11340d11f9d730d7e85c61ac96.

I furthermore declare that I am authorized and able to make this
agreement and sign this declaration.

Signed,

[your name]
https://github.com/[your github userid]
```

Replace the bracketed text as follows:

* `[date]` with today's date, in the unambiguous numeric form `YYYY-MM-DD`.
* `[your name]` with your name.
* `[your github userid]` with your GitHub userid.

You can confirm the MD5 checksums of the CLAs by running the md5 program over them:

```
md5sum cla-{individual,entity}-1.0.md
2acaee37d7cd4ca34c537bcc0d5ef6d9  cla-individual-1.0.md
59ea9b11340d11f9d730d7e85c61ac96  cla-entity-1.0.md
```

If the output is different from above, do not sign the CLA and let us know.

That's it!

* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *

Sending the Email
-----------------

Send an email to the Crash Override team at
[opensource@crashoverride.com](mailto:opensource@crashoverride.com),
with the subject "CLA" and the following body:

```
I submitted a pull request to indicate agreement to the terms
of the Contributors License Agreement.

Signed,

[your name]
https://github.com/[your github userid]
```

Replace the bracketed text as follows:

* `[your name]` with your name.
* `[your github userid]` with your GitHub userid.
