##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk profile` command.

import unicode, ../config

proc runCmdProfile*(args: seq[string]) =
  var
    toPublish = ""
    profiles: seq[string] = @[]

  if len(args) == 0:
      let profs = getChalkRuntime().attrs.contents["profile"].get(AttrScope)
      toPublish &= formatTitle("Available Profiles (see 'chalk profile " &
        "NAME' for details on a specific profile)")
      toPublish &= profs.listSections("Profile Name")
  else:
    if "all" in args:
      for k, v in chalkConfig.profiles:
        profiles.add(k)
    else:
      for profile in args:
        if profile notin chalkConfig.profiles:
          error("No such profile: " & profile)
          continue
        else:
          profiles.add(profile)

    for profile in profiles:
      var
        table = tableC4mStyle(2)
        prof  = chalkConfig.profiles[profile]

      toPublish &= formatTitle("Profile: " & profile)
      if prof.doc.isSome():
        toPublish &= unicode.strip(prof.doc.get()) & "\n"
      if prof.enabled != true:
        toPublish &= "WARNING! Profile is currently disabled."
      table.addRow(@["Key Name", "Report?"])
      for k, v in prof.keys:
        table.addRow(@[k, $(v.report)])
      toPublish &= table.render()

    toPublish &= "\nIf keys are NOT listed, they will not be reported.\n"
    toPublish &= "Any keys set to 'false' were set explicitly.\n"
  publish("defaults", toPublish)
