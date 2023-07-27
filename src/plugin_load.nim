## Plugin loading; currently this is only static plugins.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

# We need to turn off UnusedImport here, because the nim static
# analyzer thinks the below imports are unused. When we first import,
# they call registerPlugin(), which absolutely will get called.
{.warning[UnusedImport]: off.}

import plugins/codecShebang
import plugins/codecElf
import plugins/codecDocker
import plugins/codecZip
import plugins/codecPythonPy
import plugins/codecPythonPyc
import plugins/codecMacOs
import plugins/ciGithub
import plugins/ciJenkins
import plugins/ciGitlab
import plugins/conffile
import plugins/ownerAuthors
import plugins/ownerGithub
import plugins/vctlGit
import plugins/ecs
import plugins/externalTool
import plugins/system
when hostOs == "linux":
  import plugins/procfs
