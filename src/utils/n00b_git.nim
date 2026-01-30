import pkg/[
  nimutils,
  nimutils/logging,
]
import ".."/[
  utils/chalkdict,
  n00b/git,
  n00b/wrapping/collections,
  n00b/wrapping/string,
]

proc n00bListToStrings(list: ptr n00b_list_t): seq[string] =
  result = @[]
  if list == nil:
    return
  let count = list.listLen()
  for i in 0 ..< count:
    let item = cast[ptr n00b_string_t](list.listGet(i))
    if item != nil:
      result.add($item)

proc n00bDictToChalkDict*(dict: ptr n00b_dict_t): ChalkDict =
  result = ChalkDict()
  if dict == nil:
    return

  let items = dict.dictItems()
  if items == nil:
    return

  let count = items.listLen()
  for i in 0 ..< count:
    let itemTuple = cast[ptr n00b_tuple_t](items.listGet(i))
    if itemTuple == nil:
      continue
    let keyPtr = cast[ptr n00b_string_t](itemTuple.tupleGet(0))
    let valPtr = itemTuple.tupleGet(1)
    if keyPtr == nil or valPtr == nil:
      continue

    let key = $keyPtr
    let valueType = objType(valPtr)
    if valueType.isStringType():
      result[key] = pack($(cast[ptr n00b_string_t](valPtr)))
    elif valueType.isListType():
      result[key] = pack(n00bListToStrings(cast[ptr n00b_list_t](valPtr)))
    elif valueType.isBoolBoxType():
      result[key] = pack(unboxInt(valPtr) != 0)
    elif valueType.isIntBoxType():
      result[key] = pack(unboxInt(valPtr))
    else:
      trace("n00b git: unsupported value type for key=" & key & " type=" & $valueType)

proc n00bGitCollect*(repoRoot: string): ChalkDict =
  return n00bDictToChalkDict(gitCollect(repoRoot))
