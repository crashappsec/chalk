Contributions
=============

| Type                      | Where to contribute                                                                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| File an issue             | Submit an issue in [the relevant GitHub repository](https://github.com/crashappsec)                                                            |
| Update this documentation | Create a PR or submit an issue in the [Documentation repository](https://github.com/crashappsec/docs)                                          |
| Contribute code changes   | Follow the process [below](#contributing-to-the-project), then raise a PR in [the relevant GitHub repository](https://github.com/crashappsec/) |


Contributing Code to the Project
================================

Thank you for your interest in contributing to the project, below are the steps 
that we ask all contributors to take to ensure that the project stays compliant 
with its GPLv3 license and its codebase can remain fully open.

1. If you don't already have one make an account on [GitHub](https://github.com/).
2. Read and agree to the project's code of conduct [here](https://github.com/crashappsec/.github/blob/main/code-of-conduct.md)
3. Read the current version of the Contributor License Agreement (CLA), the
   [individual CLA is here](https://github.com/crashappsec/chalk-internal/blob/main/cla-individual-1.0.md), 
   the [entity CLA is here.](https://github.com/crashappsec/chalk-internal/blob/main/cla-entity-1.0.md)
   (Please ensure you understand and agree to them, if you have any questions please reach
   out to us at [opensource@crashoverride.com](mailto:opensource@crashoverride.com))

4. File a pull request on the Chalk project, as [shown here](#filing-the-pull-request).

5. Wait for someone from the team to merge your pull request. You may start
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
Agreement version 1.0 (https://github.com/crashappsec/chalk-internal/blob/main/cla-individual-1.0.md), with MD5 checksum
2acaee37d7cd4ca34c537bcc0d5ef6d9.

I furthermore declare that I am authorized and able to make this
agreement and sign this declaration.

Finally, I agree to abide by the project's code of conduct version 1.0
(https://github.com/crashappsec/.github/blob/main/code-of-conduct.md), 
with MD5 checksum f5587cc97110aa2fa21bc7c8d6861c44.

Signed,

[your name]
https://github.com/[your github userid]
```

If you are contributing as an entity the contents of the file should
look as follows:

```
[date YYYY-MM-DD]

I hereby agree to the terms of the Entity Contributors License
Agreement version 1.0 (https://github.com/crashappsec/chalk-internal/blob/main/cla-entity-1.0.md), with MD5 checksum
59ea9b11340d11f9d730d7e85c61ac96.

I furthermore declare that I am authorized and able to make this
agreement and sign this declaration.

Finally, I agree to abide by the project's code of conduct version 1.0 
(https://github.com/crashappsec/.github/blob/main/code-of-conduct.md), 
with MD5 checksum f5587cc97110aa2fa21bc7c8d6861c44.

Signed,

[your name]
https://github.com/[your github userid]
```

Replace the bracketed text as follows:

* `[date]` with today's date, in the unambiguous numeric form `YYYY-MM-DD`.
* `[your name]` with your name.
* `[your github userid]` with your GitHub userid.


Checking File Versions and MD5 Checksums
----------------------------------------

You can confirm the MD5 checksums of the code of conduct and CLAs by running the md5 program over them:

```
md5sum code-of-conduct.md
f5587cc97110aa2fa21bc7c8d6861c44  code-of-conduct.md

md5sum cla-{individual,entity}-1.0.md
2acaee37d7cd4ca34c537bcc0d5ef6d9  cla-individual-1.0.md
59ea9b11340d11f9d730d7e85c61ac96  cla-entity-1.0.md
```

If the output is different from above, do not sign the CLA and let us know.

That's it!

* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
