import "."/[
  types,
  wrapping/list,
  wrapping/dict,
]
from "./wrapping/string" import `@`
import ".."/[
  utils/chalkdict,
]

export types

proc n00b_git_collect(
  repo_root: ptr n00b_string_t,
): ptr n00b_dict_t {.header:"util/git.h".}

proc n00bGitCollect*(repoRoot: string): ChalkDict =
  if repoRoot == "":
    return ChalkDict()
  return $n00b_git_collect(@repoRoot)
