import "."/[
  types,
  wrapping/string,
]

export types

proc n00b_git_collect(
  repo_root: ptr n00b_string_t,
): ptr n00b_dict_t {.header:"util/git.h".}

proc gitCollect*(repoRoot: string): ptr n00b_dict_t =
  if repoRoot == "":
    return nil
  return n00b_git_collect(@repoRoot)
