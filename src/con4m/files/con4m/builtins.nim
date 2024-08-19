## Built in functions. I will add more of these as I find them
## useful. They're all exposed so that you can selectively re-use
## them.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022 - 2023

import os, tables, osproc, strformat, strutils, options, streams, base64,
       macros, types, typecheck, st, parse, nimutils, errmsg,
       otherlits, treecheck, dollars, unicode, json, httpclient, net, uri,
       sugar, nimutils/managedtmp

var externalActionCallback: Option[(string, string) -> void]

template logExternalAction*(kind: string, msg: string) =
  if externalActionCallback.isSome():
    let fn = externalActionCallback.get()
    fn(kind, msg)

proc setExternalActionCallback*(fn: (string, string) -> void) =
  externalActionCallback = some(fn)

when defined(posix):
  import posix

when (NimMajor, NimMinor) >= (1, 7):
  {.warning[CastSizes]: off.}

template c4mException*(m: string): untyped =
  newException(Con4mError, m)

let
  trueRet  = some(pack(true))
  falseRet = some(pack(false))

proc c4mItoB*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Cast integers to booleans (testing for non-zero). Exposed as
  ## `bool(i)` by default.
  let i = unpack[int](args[0])
  if i != 0:
    return trueRet
  else:
    return falseRet

proc c4mFtoB*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Cast floats to booleans (testing for non-zero). Exposed as
  ## `bool(f)` by default.
  let f = unpack[float](args[0])
  if f != 0:
    return trueRet
  else:
    return falseRet

proc c4mStoB*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Cast strings to booleans (testing for empty strings). Exposed as
  ## `bool(s)` by default.
  let s = unpack[string](args[0])
  if s != "":
    return trueRet
  else:
    return falseRet

proc c4mLToB*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Cast lists of any type to booleans (testing for empty lists).
  ## Exposed as `bool(s)` by default.

  # We don't care what types are in the list, so don't unbox them.
  let l = unpack[seq[Box]](args[0])

  if len(l) == 0:
    return falseRet
  else:
    return trueRet

proc c4mDToB*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Cast dicitonaries of any type to booleans (testing for empty
  ## lists). Exposed as `bool(s)` by default.

  # Note that the key type should NOT be boxed when we unpack, but we
  # use Box to denote that we don't care about the parameter type.
  let d = unpack[Con4mDict[Box, Box]](args[0])

  if len(d) == 0:
    return falseRet
  else:
    return trueRet

proc c4mIToF*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Cast an integer to a float. Exposed as `float(i)` by default.
  let
    i = unpack[int](args[0])
    f = float(i)

  return some(pack(f))

proc c4mFToI*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Cast an float to an int (truncating). Exposed as `int(f)` by
  ## default.
  let
    f = unpack[float](args[0])
    i = int(f)

  return some(pack(i))

proc c4mSelfRet*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## This is used for a cast of arg[0] to a type with the exact same
  ## representation when boxed. Could technically no-op it, but
  ## whatever.
  return some(args[0])

macro toOtherLitDecl(name, call, err: untyped): untyped =
  quote do:
    proc `name`*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
      let
        str = unpack[string](args[0])
        opt = `call`(str)
      if opt.isSome():
        return some(pack(opt.get()))
      raise c4mException(`err`)

toOtherLitDecl(c4mSToDur,      otherLitToNativeDuration, "Invalid duration")
toOtherLitDecl(c4mSToIP,       otherLitToIPAddr,         "Invalid IP address")
toOtherLitDecl(c4mSToCIDR,     otherLitToCIDR,           "Invalid CIDR spec")
toOtherLitDecl(c4mSToSize,     otherLitToNativeSize,     "Invalid size spec")
toOtherLitDecl(c4mSToDate,     otherLitToNativeDate,     "Invalid date syntax")
toOtherLitDecl(c4mSToTime,     otherLitToNativeTime,     "Invalid time syntax")
toOtherLitDecl(c4mSToDateTime, otherLitToNativeDateTime, "Invalid date/time")

proc c4mDurAsMsec*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    duration = unpack[int](args[0])
    msec     = duration div 1000

  result = some(pack(msec))

proc c4mDurAsSec*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    duration = unpack[int](args[0])
    sec      = duration div 1000000

  result = some(pack(sec))

proc c4mStrToType*(args: seq[Box], unused: ConfigState): Option[Box] =
  try:    return some(pack(toCon4mType(unpack[string](args[0]))))
  except: raise c4mException(getCurrentExceptionMsg())

proc c4mStrToChars*(args: seq[Box], unused: ConfigState): Option[Box] =
  var s: seq[int] = @[]
  for rune in toRunes(unpack[string](args[0])):
    s.add(int(rune))
  result = some(pack(s))

proc c4mStrToBytes*(args: seq[Box], unused: ConfigState): Option[Box] =
  var s: seq[int] = @[]
  for ch in unpack[string](args[0]):
    s.add(int(ch))
  result = some(pack(s))

proc c4mCharsToString*(args: seq[Box], unused: ConfigState): Option[Box] =
  var r = ""
  for num in unpack[seq[Box]](args[0]):
    r.add($(Rune(unpack[int](num))))

  result = some(pack(r))

proc c4mSplit*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Takes the first argument, and converts it into a list,
  ## spliting it out based on the pattern in the second string.
  ## This should work as expected from other languages.
  ## Exposed as `split(s1, s2)` by default.
  # Note that, since the item type is known, we only box the
  # top-level, not the items.

  var
    big   = unpack[string](args[0])
    small = unpack[string](args[1])
    l     = big.split(small)

  return some(pack[seq[string]](l))

proc c4mToString*(args: seq[Box], state: ConfigState): Option[Box] =
  let
    actNode  = state.nodeStash.children[1]
    itemType = actNode.children[0].getType()

  return some(pack(oneArgToString(itemType, args[0])))

proc c4mEcho*(args: seq[Box], state: ConfigState): Option[Box] =
  ## Exposed as `echo(*s)` by default. Prints the parameters to
  ## stdout, followed by a newline at the end.

  var
    actNode = state.nodeStash.children[1]
    toPrint: seq[string] = @[]

  for i, item in args:
    let typeinfo = actNode.children[i].getType()
    toPrint.add(oneArgToString(typeInfo, item))

  stderr.writeLine(toPrint.join(" "))

proc c4mEnv*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Exposed as `env(s)` by default. Returns the value of the
  ## requested environment variable. If the environment variable is
  ## NOT set, it will return the empty string. To distingush between
  ## the environment variable not being set, or the variable being set
  ## to the empty string, use `c4mEnvExists`.

  let arg = unpack[string](args[0])

  return some(pack(getEnv(arg)))

proc c4mEnvExists*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Returns true if the requested variable name is set in the
  ## environment, false if it's not. Exposed as `envExists(s)` by
  ## default.
  ##
  ## Note that this can be used to distinguish between the variable
  ## not existing, and the variable being set explicitly to the empty
  ## string.
  let arg = unpack[string](args[0])

  return some(pack(existsEnv(arg)))

proc c4mEnvAll*(args: seq[Box] = @[], unused = ConfigState(nil)): Option[Box] =
  ## Return a dictionary with all envvars and their values.
  ## Exposed by default as `env()`
  var s = newCon4mDict[string, string]()

  for (k, v) in envPairs():
    s[k] = v

  var packed = pack(s)
  return some(packed)

proc c4mStrip*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Remove leading and trailing white space from a string.
  ## Exposed by default as `strip(s)`
  let
    arg = unpack[string](args[0])
    stripped = unicode.strip(arg)

  return some(pack(stripped))

proc c4mContainsStrStr*(args: seq[Box],
                        unused = ConfigState(nil)): Option[Box] =
  ## Returns true if `s1` contains the substring `s2`.
  ## Exposed by default as `contains(s1, s2)`
  let
    arg1 = unpack[string](args[0])
    arg2 = unpack[string](args[1])
    res = arg1.contains(arg2)

  return some(pack(res))

proc c4mStartsWith*(args: seq[Box],
                    unused = ConfigState(nil)): Option[Box] =

  let
    arg1 = unpack[string](args[0])
    arg2 = unpack[string](args[1])
    res = arg1.startsWith(arg2)

  return some(pack(res))

proc c4mEndsWith*(args: seq[Box],
                    unused = ConfigState(nil)): Option[Box] =

  let
    arg1 = unpack[string](args[0])
    arg2 = unpack[string](args[1])
    res = arg1.endsWith(arg2)

  return some(pack(res))

proc c4mFindFromStart*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Returns the index of the substring `s2`'s first appearence in the
  ## string `s1`, or -1 if it does not appear. Exposed by default as
  ## `find(s1, s2)`

  let
    s = unpack[string](args[0])
    sub = unpack[string](args[1])
    res = s.find(sub)

  return some(pack(res))

proc c4mSlice*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Returns the substring of `s` starting at index `start`, not
  ## including index `end`. The semantics of this are Pythonic, where
  ## -1 works as expected.
  ##
  ## Note that an index out of bounds will not error. If both
  ## indicies are out of bounds, you'll get the empty string.
  ## usually exposed as `slice(s, start, end)`

  let
    s       = unpack[string](args[0])
  var
    startix = unpack[int](args[1])
    endix   = unpack[int](args[2])

  if startix < 0:
    startix += s.len()
  if endix < 0:
    endix += s.len()

  try:
    return some(pack(s[startix .. endix]))
  except:
    return some(pack(""))

proc c4mSliceToEnd*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Returns the substring of `s` starting at index `start`, until the
  ## end of the string. The semantics of this are Pythonic, where -1
  ## works as expected (to index from the back).
  ##
  ## Note that an index out of bounds will not error. If both
  ## indicies are out of bounds, you'll get the empty string.
  ## usually exposed as `slice(s, start)`

  let
    s       = unpack[string](args[0])
    endix   = s.len() - 1
  var
    startix = unpack[int](args[1])


  if startix < 0:
    startix += s.len()

  try:
    return some(pack(s[startix .. endix]))
  except:
    return some(pack(""))

proc c4mListSlice*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Returns the sub-array of `s` starting at index `start`, not
  ## including index `end`. The semantics of this are Pythonic, where
  ## -1 works as expected.
  ##
  ## Note that an index out of bounds will not error. If both
  ## indicies are out of bounds, you'll get the empty list.
  ## usually exposed as `slice(s, start, end)`

  let
    s       = unpack[seq[Box]](args[0])
  var
    startix = unpack[int](args[1])
    endix   = unpack[int](args[2])

  if startix < 0:
    startix += s.len()
  if endix < 0:
    endix += s.len()

  try:
    return some(pack(s[startix .. endix]))
  except:
    return some(pack[seq[Box]](@[]))

proc c4mFormat*(args: seq[Box], state: ConfigState): Option[Box] =
  ## We don't error check on string bounds; when an exception gets
  ## raised, SCall will call fatal().
  var
    s   = unpack[string](args[0])
    res = newStringOfCap(len(s)*2)
    i   = 0
    key:    string
    `box?`: Option[Box]
    box:    Box = nil

  while i < s.len():
    case s[i]
    of '}':
      i += 1
      if i == s.len() or s[i] == '}':
        res.add(s[i])
        i += 1
      else:
        raise c4mException("Unescaped } w/o a matching { in format string")
    of '{':
      i = i + 1
      if s[i] == '{':
        res.add(s[i])
        i = i + 1
        continue
      key = newStringOfCap(20)
      while s[i] != '}':
        key.add(s[i])
        i = i + 1
      i = i + 1

      `box?` = state.attrLookup(key)
      if `box?`.isNone() and '.' notin key:
        let aoe = state.nodeStash.attrScope.attrLookup([key], 0, vlAttrUse)
        if aoe.isA(AttrOrSub):
          `box?` = aoe.get(AttrOrSub).get(Attribute).attrToVal()
      if `box?`.isSome():
        box = `box?`.get()
      else:
        try:
          box = runtimeVarLookup(state.frames, key)
        except:
          raise c4mException(fmt"Error in format: {key} not found")

      case box.kind
        of MkStr:
          res.add(unpack[string](box))
        of MkInt:
          res.add($(unpack[int](box)))
        of MkFloat:
          res.add($(unpack[float](box)))
        of MkBool:
          res.add($(unpack[bool](box)))
        else:
          raise c4mException("Error: Invalid type for format argument; " &
                             "container types not supported.")
    else:
      res.add(s[i])
      i = i + 1

  return some(pack(res))

proc c4mAbort*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Stops the entire program (not just the configuration file).
  ## Generally exposed as `abort()`

  stderr.writeLine(unpack[string](args[0]))
  quit(1)

proc c4mListLen*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Returns the number of elements in the list.
  var list = unpack[seq[Box]](args[0])

  return some(pack(len(list)))

proc c4mListContains*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    list = unpack[seq[Box]](args[0])
    val  = unpack[Box](args[1])

  for item in list:
    if item == val:
      return trueRet

  return falseRet

proc c4mDictContains*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    list   = unpack[OrderedTableRef[Box, Box]](args[0])
    target = unpack[Box](args[1])

  for key, val in list:
    if target == key:
      return trueRet

  return falseRet

proc c4mStrLen*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Returns the number of bytes in a string.
  var s = unpack[string](args[0])

  return some(pack(len(s)))

proc c4mDictLen*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  ## Returns the number of k,v pairs in a dictionary.
  var dict = unpack[Con4mDict[Box, Box]](args[0])

  return some(pack(len(dict)))

proc c4mDictKeys*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    keys: seq[Box]               = newSeq[Box]()
    box                          = args[0]
    d: OrderedTableRef[Box, Box] = unpack[OrderedTableRef[Box, Box]](box)

  for k, _ in d:
    keys.add(k)

  return some(pack[seq[Box]](keys))

proc c4mDictValues*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    values: seq[Box]             = newSeq[Box]()
    box                          = args[0]
    d: OrderedTableRef[Box, Box] = unpack[OrderedTableRef[Box, Box]](box)

  for _, v in d:
    values.add(v)

  return some(pack[seq[Box]](values))

proc c4mDictItems*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    tup:   seq[Box] # For the output tuples.
    items: seq[Box]              = newSeq[Box]()
    box                          = args[0]
    d: OrderedTableRef[Box, Box] = unpack[OrderedTableRef[Box, Box]](box)

  for k, v in d:
    tup = newSeq[Box]()
    tup.add(k)
    tup.add(v)
    items.add(pack[seq[Box]](tup))

  return some(pack[seq[Box]](items))

proc c4mListDir*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var res: seq[string] = @[]

  let dir = if len(args) == 0: "."
            else: resolvePath(unpack[string](args[0]))

  logExternalAction("list_dir", dir)

  unprivileged:
    for item in walkdir(dir):
      res.add(item.path)

  return some(pack[seq[string]](res))

proc c4mReadFile*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  unprivileged:
    let
      fname = resolvePath(unpack[string](args[0]))
      f     = newFileStream(fname, fmRead)

    if f == nil:
      result = some(pack(""))
    else:
      logExternalAction("read_file", fname)
      result = some(pack(f.readAll()))
      f.close()

proc c4mWriteFile*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    fname = resolvePath(unpack[string](args[0]))
    f     = newFileStream(fname, fmWrite)

  if f == nil: return falseRet

  logExternalAction("write_file", fname)
  f.write(unpack[string](args[1]))
  f.close()
  return trueRet

proc c4mJoinPath*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let res = joinPath(unpack[string](args[0]), unpack[string](args[1]))
  return some(pack(res))

proc c4mCopyFile*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    src = unpack[string](args[0])
    dst = unpack[string](args[1])

  unprivileged:
    try:
      copyFile(src, dst)
      logExternalAction("copy_file", src & " -> " & dst)

      result = trueRet
    except:
      result = falseRet

proc c4mResolvePath*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(resolvePath(unpack[string](args[0]))))

proc c4mCwd*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(getCurrentDir()))

proc findExeC4m*(args: seq[Box], s: ConfigState): Option[Box] =
  let
    cmdName    = unpack[string](args[0])
    extraPaths = unpack[seq[string]](args[1])
    results    = findAllExePaths(cmdName, extraPaths, true)

  if results.len() == 0:
    return some(pack(""))
  else:
    return some(pack(results[0]))

proc c4mChdir*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let path = resolvePath(unpack[string](args[0]))
  unprivileged:
    try:
      setCurrentDir(path)
      result = trueRet
    except:
      result = falseRet

proc c4mMkdir*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let path = resolvePath(unpack[string](args[0]))
  unprivileged:
    try:
      createDir(path)
      logExternalAction("make_dir", path)

      result = trueRet
    except:
      result = falseRet

proc c4mSetEnv*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    key = unpack[string](args[0])
    val = unpack[string](args[1])

  unprivileged:
    try:
      putEnv(key, val)
      logExternalAction("set_env", key)

      result = trueRet
    except:
      result = falseRet

proc c4mIsDir*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let path = resolvePath(unpack[string](args[0]))

  unprivileged:
    try:
      if getFileInfo(path, false).kind == pcDir:
        result = trueRet
      else:
        result = falseRet
    except:
        result = falseRet

proc c4mIsFile*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let path = resolvePath(unpack[string](args[0]))

  unprivileged:
    try:
      if getFileInfo(path, false).kind == pcFile:
        result = trueRet
      else:
        result = falseRet
    except:
      result = falseRet

proc c4mIsLink*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  unprivileged:
    try:
      let
        path = resolvePath(unpack[string](args[0]))
        kind = getFileInfo(path, false).kind

      if kind == pcLinkToDir or kind == pcLinkToFile:
        result = trueRet
      else:
        result = falseRet
    except:
      result = falseRet

proc c4mChmod*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    path = resolvePath(unpack[string](args[0]))
    raw  = unpack[int](args[1])
    mode = cast[FilePermission](raw)

  unprivileged:
    try:
      setFilePermissions(path, cast[set[FilePermission]](mode))
      logExternalAction("chmod", path & " -> " & toOct(raw, 4))

      result = trueRet
    except:
      result = falseRet

proc c4mGetPid*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(getCurrentProcessId()))

proc c4mFileLen*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let path = resolvePath(unpack[string](args[0]))

  unprivileged:
    try:
      result = some(pack(getFileSize(path)))
    except:
      result = some(pack(-1))

proc c4mTmpWrite*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  # args[0]: contents to write. args[1]: file extension. ret: full path
  let
    prefix = getUlid(dash=false)
    suffix = unpack[string](args[1])

  try:
    let (f, path) = getNewTempFile(prefix, suffix)

    f.write(unpack[string](args[0]))
    f.close()

    logExternalAction("tmp_write", path)

    return some(pack(path))
  except:
    return some(pack(""))

proc c4mBase64*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(encode(unpack[string](args[0]))))

proc c4mBase64Web*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(encode(unpack[string](args[0]), safe = true )))

proc c4mDecode64*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  try:
    return some(pack(decode(unpack[string](args[0]))))
  except:
    raise c4mException(getCurrentExceptionMsg())

proc c4mToHex*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(toHex(unpack[string](args[0]))))

proc c4mInttoHex*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(toHex(unpack[int](args[0]))))

proc c4mFromHex*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  try:
    return some(pack(parseHexStr(unpack[string](args[0]))))
  except:
    raise c4mException(getCurrentExceptionMsg())

proc c4mSha256*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(sha256Hex(unpack[string](args[0]))))

proc c4mSha512*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(sha512Hex(unpack[string](args[0]))))

proc c4mUpper*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(unicode.toUpper(unpack[string](args[0]))))

proc c4mLower*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(unicode.toLower(unpack[string](args[0]))))

proc c4mJoin*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    arr    = unpack[seq[string]](args[0])
    joiner = unpack[string](args[1])
  return some(pack(arr.join(joiner)))

proc c4mReplace*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    baseString  = unpack[string](args[0])
    toReplace   = unpack[string](args[1])
    replaceWith = unpack[string](args[2])

  return some(pack(baseString.replace(toReplace, replaceWith)))

template simpleRuneFunc(arr: seq[Box], f: untyped): Option[Box] =
  let
    i = unpack[int](args[0])
    r = Rune(i)

  some(pack(f(r)))

proc c4mUTF8Len*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  simpleRuneFunc(args, size)

proc c4mIsCombining*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  simpleRuneFunc(args, isCombining)

proc c4mIsLower*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  simpleRuneFunc(args, isLower)

proc c4mIsUpper*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  simpleRuneFunc(args, isUpper)

proc c4mIsSpace*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  simpleRuneFunc(args, isWhiteSpace)

proc c4mIsAlpha*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  simpleRuneFunc(args, isAlpha)

proc c4mIsNum*(args: seq[Box], unused = ConfigStatE(nil)): Option[Box] =
  let
    i = unpack[int](args[0])
    r = Rune(i)

  return if i >= int('0') and i <= int('9'): trueRet else: falseRet

proc c4mIsAlphaNum*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    i = unpack[int](args[0])
    r = Rune(i)

  if r.isAlpha() or (i >= int('0') and i <= int('9')):
    return trueRet
  else:
    return falseRet

proc c4mMimeToDict*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    outDict     = Con4mDict[string, string]()
    tmp: string
  let mimeLines = unpack[string](args[0]).split("\n")

  for line in mimeLines:
    let ix = line.find(':')
    if ix == -1:
      continue

    if ix + 1 == len(line):
      tmp = ""
    else:
      tmp = unicode.strip(line[ix + 1 .. ^1])

    outDict[unicode.strip(line[0 ..< ix])] = tmp

  return some(pack(outDict))

proc c4mMove*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  unprivileged:
    try:
      let
        src = unpack[string](args[0])
        dst = unpack[string](args[1])
        kind = getFileInfo(src, false).kind

      if kind == pcDir or kind == pcLinkToDir:
        moveDir(src, dst)
        result = trueRet
      else:
        moveFile(src, dst)
        result = trueRet
    except:
      result = falseRet

proc c4mQuote*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(quoteShell(unpack[string](args[0]))))

proc c4mGetOsName*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(hostOS))

proc c4mGetArch*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(hostCPU))

proc c4mGetArgv*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(commandLineParams()))

proc c4mGetExePath*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(resolvePath(getAppFilename())))

proc c4mGetExeName*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(getAppFilename().splitPath().tail))

proc c4mIntHigh*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(high(int64)))

proc c4mIntLow*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(low(int64)))

proc c4mRandom*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(secureRand[uint64]()))

proc c4mNow*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(unixTimeInMS()))

proc c4mBitOr*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    o1 = unpack[int](args[0])
    o2 = unpack[int](args[1])

  return some(pack(o1 or o2))

proc c4mBitAnd*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    o1 = unpack[int](args[0])
    o2 = unpack[int](args[1])

  return some(pack(o1 and o2))

proc c4mBitXor*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    o1 = unpack[int](args[0])
    o2 = unpack[int](args[1])

  return some(pack(o1 xor o2))

proc c4mBitShl*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    o1 = unpack[uint](args[0])
    o2 = unpack[uint](args[1])

  return some(pack(o1 shl o2))

proc c4mBitShr*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    o1 = unpack[uint](args[0])
    o2 = unpack[uint](args[1])

  return some(pack(o1 shr o2))

proc c4mBitNot*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let innum = unpack[uint](args[0])

  return some(pack(not innum))

var replacementState: Option[ConfigState] = none(ConfigState)

# this is so sections() in a con4m spec validation can get the value of
# the spec we're checking, instead of being introspective.
proc getReplacementState*(): Option[ConfigState] =
  return replacementState

proc setReplacementState*(state: ConfigState) =
  replacementState = some(state)

proc clearReplacementState*() =
  replacementState = none(ConfigState)

template scopeWalk(lookingfor: untyped) {.dirty.} =
  let
    name  = unpack[string](args[0])
    state = replacementState.getOrElse(localState)
    aOrE  = attrLookup(state.attrs, name.split("."), 0, vlExists)

  if aOrE.isA(AttrErr):
    return some(pack[seq[string]](@[]))

  let aOrS = aOrE.get(AttrOrSub)

  if aOrS.isA(Attribute):
    return some(pack[seq[string]](@[]))
  var
    sec              = aOrS.get(AttrScope)
    res: seq[string] = @[]

  for key, aOrS in sec.contents:
    if aOrS.isA(lookingfor):
      res.add(key)

proc c4mSections*(args: seq[Box], localState: ConfigState): Option[Box] =
  scopeWalk(AttrScope)
  return some(pack(res))

proc c4mFields*(args:  seq[Box], localState: ConfigState): Option[Box] =
  scopeWalk(Attribute)
  return some(pack(res))

proc c4mTypeOf*(args: seq[Box], localstate: ConfigState): Option[Box] =
  let
    actNode  = localstate.nodeStash.children[1]
    itemType = actNode.children[0].getType()

  return some(pack(itemType))

proc c4mCmpTypes*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    t1 = unpack[Con4mType](args[0])
    t2 = unpack[Con4mType](args[1])

  return some(pack(not t1.copyType().unify(t2.copyType()).isBottom()))

proc c4mAttrGetType*(args: seq[Box], localstate: ConfigState): Option[Box] =
  ## This allows us to, from within a c42 spec, query the type of an
  ## attr in the actual con4m file we're checking. Otherwise, we
  ## could simply use the previous function to get the type of an attribute.
  let
    varName = unpack[string](args[0])
    state   = replacementState.getOrElse(localState)
    aOrE    = attrLookup(state.attrs, varName.split("."), 0, vlExists)

  if aOrE.isA(AttrErr):       return some(pack(bottomType))
  let aOrS = aOrE.get(AttrOrSub)
  if not aOrS.isA(Attribute): return some(pack(bottomType))
  var sym  = aOrS.get(Attribute)

  return some(pack(sym.tInfo))

proc c4mRefTypeCmp*(args: seq[Box], localstate: ConfigState): Option[Box] =
  ## Arg 0 is the field we're type-checking.
  ## Arg 1 is the field that we expect to contain a typespec,
  ## where that typespec should indicate the type of arg 0.
  let
    varName = unpack[string](args[0])
    tsField = unpack[string](args[1])
    state   = replacementState.getOrElse(localState)
    aOrE1   = attrLookup(state.attrs, varName.split("."), 0, vlExists)
    aOrE2   = attrLookup(state.attrs, tsField.split("."), 0, vlExists)

  if aOrE1.isA(AttrErr):       return falseRet
  if aOrE2.isA(AttrErr):       return falseRet
  let
    aOrS1 = aOrE1.get(AttrOrSub)
    aOrS2 = aOrE2.get(AttrOrSub)

  if not aOrS1.isA(Attribute): return falseRet
  if not aOrS2.isA(Attribute): return falseRet

  var
    symToCheck = aOrS1.get(Attribute)
    tsFieldSym = aOrS2.get(Attribute)
    tsValOpt   = tsFieldSym.attrToVal()

  if tsFieldSym.tInfo.resolveTypeVars().kind != TypeTypeSpec:
    raise c4mException("Field '" & tsField & "' is not a typespec.")

  if tsValOpt.isNone():
    raise c4mException("Field '" & tsField & "' has no value provided.")

  var
    tsValType = unpack[Con4mType](tsValOpt.get())
    res       = not tsValType.unify(symToCheck.tInfo).isBottom()

  if not res and tsValType.resolveTypeVars().kind == symToCheck.getType().kind:
    return some(pack(true))

  return some(pack(res))

proc c4mAttrExists*(args: seq[Box], localstate: ConfigState): Option[Box] =
  let
    attrName     = unpack[string](args[0])
    state        = replacementState.getOrElse(localState)
    aOrE         = attrLookup(state.attrs, attrName.split("."), 0, vlExists)

  if aOrE.isA(AttrErr):
    return some(pack(false))
  return some(pack(true))

proc c4mOverride*(args: seq[Box], localState: ConfigState): Option[Box] =
  let
    attrName     = unpack[string](args[0])
    state        = replacementState.getOrElse(localState)
    actNode      = localstate.nodeStash.children[1]
    itemType     = actNode.children[1].getType()

  if attrSet(state.attrs, attrName, args[1], itemType).code != errOk:
    return falseRet

  let
    aOrE         = attrLookup(state.attrs, attrName.split("."), 0, vlExists)

  if aOrE.isA(AttrErr): return falseRet
  let aOrS = aOrE.get(AttrOrSub)

  if not aOrS.isA(Attribute): return falseRet
  let sym = aOrS.get(Attribute)

  if sym.tInfo.copyType().unify(itemType.copyType()).isBottom(): return falseRet
  if sym.locked or sym.override.isSome(): return falseRet

  sym.override = some(args[1])
  sym.value    = some(args[1])

  if state.nodeStash == nil:
    sym.lastUse = none(Con4mNode)
  else:
    sym.lastUse = some(state.nodeStash)

  return trueRet

proc c4mGetAttr*(args: seq[Box], localstate: ConfigState): Option[Box] =
  let
    attrName     = unpack[string](args[0])
    expectedType = (unpack[Con4mType](args[1])).copyType()
    state        = replacementState.getOrElse(localState)
    aOrE         = attrLookup(state.attrs, attrName.split("."), 0, vlExists)

  if aOrE.isA(AttrErr):
    raise c4mException("Field not found: " & attrName)
  let aOrS = aorE.get(AttrOrSub)

  if not aOrS.isA(Attribute):
    raise c4mException("Got a section (expected attribute) for: "  & attrName)
  let sym = aOrS.get(Attribute)

  if sym.tInfo.copyType().unify(expectedType).isBottom():
    raise c4mException("Typecheck failed for: " & attrName & " (attr type: " &
        $(sym.tInfo) & "; passed type: " & $(expectedType) & ")")

  return sym.value

proc c4mFnExists*(args: seq[Box], localstate: ConfigState): Option[Box] =
  let
    fn         = unpack[CallbackObj](args[0])
    state      = getReplacementState().getOrElse(localstate)
    candidates = state.findMatchingProcs(fn.name, fn.tInfo)

  return some(pack(candidates.len() > 0))

proc c4mSplitAttr*(args: seq[Box], unused: ConfigState): Option[Box] =
  let
    str = unpack[string](args[0])
    ix  = str.rfind('.')

  if ix == -1: return some(pack(@["", str]))
  return some(pack(@[ str[0 ..< ix], str[ix + 1 .. ^1]]))


proc c4mRm*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  try:
    let
      path = resolvePath(unpack[string](args[0]))
      kind = getFileInfo(path, false).kind

    if kind == pcDir or kind == pcLinkToDir:
        removeDir(path, true)
        logExternalAction("rm_dir", path)
        return trueRet
    else:
      removeFile(path)
      logExternalAction("rm_file", path)
      return trueRet
  except:
    return falseRet

proc c4mLSetItem*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    l    = unpack[seq[Box]](args[0])
    ix   = unpack[int](args[1])
    item = args[2]

  l[ix] = item

  return some(pack[seq[Box]](l))

proc c4mDGetItem*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    t    = unpack[OrderedTableRef[Box, Box]](args[0])
    key  = args[1]

  if key notin t:
    return none(Box)

  return some(t[key])

proc c4mDSetItem*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    t    = unpack[OrderedTableRef[Box, Box]](args[0])
    ix   = args[1]
    item = args[2]

  t[ix] = item

  return some(pack[OrderedTableRef[Box,Box]](t))

proc c4mLDeleteItem*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    l           = unpack[seq[Box]](args[0])
    toDel       = unpack[Box](args[1])
    n: seq[Box] = @[]

  for item in l:
    if item != toDel:
      n.add(item)

  return some(pack(n))

proc c4mDDeleteItem*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    t     = unpack[OrderedTableRef[Box, Box]](args[0])
    toDel = args[1]
    ret   = OrderedTableRef[Box, Box]()

  for k, v in t:
    if k != toDel:
      ret[k] = v

  return some(pack(ret))

proc c4mLRemoveIx*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    l           = unpack[seq[Box]](args[0])
    ix          = unpack[int](args[1])
    n: seq[Box] = @[]

  for i, item in l:
    if ix != i:
      n.add(item)

  return some(pack(n))

proc c4mArrAdd*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var
    a1 = unpack[seq[Box]](args[0])
    a2 = unpack[seq[Box]](args[1])

  return some(pack(a1 & a2))

proc c4mSplitPath*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  var s: seq[string]

  let (head, tail) = splitPath(unpack[string](args[0]))
  s.add(head)
  s.add(tail)

  return some(pack(s))

proc c4mPad*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    topad = unpack[string](args[0])
    width = unpack[int](args[1])

  if len(topad) >= width:
    return some(pack(topad))

  return some(pack(topad & repeat(' ', width - len(topad))))

proc c4mFuncDocDump*(args: seq[Box], localstate: ConfigState): Option[Box] =

  var retObj = newJObject()

  for name, entries in localstate.funcTable:
    for entry in entries:
      let
        key  = if entry.tinfo.noSpec:
                 entry.name
               else:
                 entry.name & $(entry.tinfo)
        doc  = entry.doc.getOrElse("")
        tags = entry.tags
        bi   = if entry.kind == FnBuiltIn: true else: false
        obj  = newJObject()

      obj["builtin"]                  = %(bi)
      if doc != "": obj["doc"]        = %(doc)
      if tags.len() != 0: obj["tags"] = %*(tags)

      retObj[key] = obj

  return some(pack($(retObj)))


proc c4mUrlBase*(url: string, post: bool, body: string,
                 headers: OrderedTableRef[string, string],
                pinnedCert: string, timeout: int): string =
  ## For now, the funcs that call us provide no interface to the timeout;
  ## they hardcode to 5 seconds.

  var
    tups:     seq[(string, string)]
    hdrObj:   HttpHeaders
    response: Response

  if headers != nil:
    for k, v in headers:
      tups.add((k, v))

  hdrObj = newHttpHeaders(tups)

  if post:
    response = safeRequest(url = url,
                           httpMethod = HttpPost,
                           body = body,
                           headers = hdrObj,
                           timeout = timeout,
                           pinnedCert = pinnedCert)
  else:
    response = safeRequest(url = url,
                           httpMethod = HttpGet,
                           headers = hdrObj,
                           timeout = timeout,
                           pinnedCert = pinnedCert)
  if not response.code.is2xx():
    result = "ERR " & response.status

  elif response.bodyStream == nil:
    result = "ERR 000 Response body was empty (internal error?)"

  else:
    logExternalAction(if post: "POST" else: "GET", url)
    try:
      result = response.bodyStream.readAll()
    except:
      result = "ERR 000 Read of response output stream failed."

proc c4mUrlGet*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    url    = unpack[string](args[0])
    res    = url.c4mUrlBase(post = false, body = "", headers = nil,
                            pinnedCert = "", timeout = 5000)

  result = some(pack(res))

proc c4mUrlGetPinned*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    url    = unpack[string](args[0])
    cert   = unpack[string](args[1])
    res    = url.c4mUrlBase(post = false, body = "", headers = nil,
                              pinnedCert = cert, timeout = 5000)

  result = some(pack(res))

proc c4mUrlPost*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    url     = unpack[string](args[0])
    body    = unpack[string](args[1])
    headers = unpack[OrderedTableRef[string, string]](args[2])
    res     = url.c4mUrlBase(true, body, headers, pinnedCert = "",
                             timeout = 5000)

  result = some(pack(res))

proc c4mExternalIp*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  result = some(pack(getMyIpV4Addr()))

proc c4mUrlPostPinned*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    url     = unpack[string](args[0])
    body    = unpack[string](args[1])
    headers = unpack[OrderedTableRef[string, string]](args[2])
    cert    = unpack[string](args[3])
    res     = url.c4mUrlBase(true, body, headers, cert, timeout = 5)

  result = some(pack(res))

when defined(posix):
  proc c4mCmd*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
    ## Generally exposed as `run(s)`
    ##
    ## Essentially calls the posix `system()` call, except that, a)
    ## stderr gets merged into stdout, b) the exit code is put at the
    ## start of the output, separated from the rest of the output with
    ## a colon, and c) this ALWAYS drops euid and egid in a
    ## setuid/setgid program, to avoid an attacker using a configuration
    ## file to run arbitrary commands as root.
    ##
    ## Note that this *does* restore privileges in the parent process
    ## once the command returns, but in a multi-threaded program,
    ## this might be worth noting, since threads at startup time
    ## are more likely to need permissions.
    ##
    ## Currently this is not dropping other Linux capabilities; I've
    ## been developing on my Mac so haven't gotten around to it yet.
    ## Since they can never be returned to a process once dropped,
    ## that might require a fork and a pipe?
    var
      cmd = unpack[string](args[0])

    unprivileged:
      logExternalAction("run", cmd)
      let (output, _) = execCmdEx(cmd)
      result = some(pack(output))

  proc c4mSystem*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
    ## Generally exposed as `system(s)`
    ##
    ## like `run` except returns a tuple containing the output and the
    ## exit code.
    var
      cmd               = unpack[string](args[0])
      outlist: seq[Box] = @[]

    unprivileged:
      logExternalAction("run", cmd)
      let (output, exitCode) = execCmdEx(cmd)
      outlist.add(pack(output))
      outlist.add(pack(exitCode))

    result = some(pack(outlist))

  proc c4mGetUid*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
    return some(pack(getuid()))

  proc c4mGetEuid*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
    return some(pack(geteuid()))

  proc c4mUname*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
    var
      unameInfo: Utsname
      items:     seq[string] = @[]
    discard posix.uname(unameInfo)
    items.add($(cast[cstring](addr unameInfo.sysname[0])))
    items.add($(cast[cstring](addr unameInfo.nodename[0])))
    items.add($(cast[cstring](addr unameInfo.release[0])))
    items.add($(cast[cstring](addr unameInfo.version[0])))
    items.add($(cast[cstring](addr unameInfo.machine[0])))
    result = some(pack(items))

else:
  ## I don't know the permissions models on any non-posix OS, so
  ## this might be wildly insecure on such systems, as far as I know.
  ## to that end, when posix is not defined, this command is removed
  ## from the defaults.
  proc c4mCmd*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
    ## An unsafe version of this for non-posix OSes. On such machines,
    ## it is NOT a default builtin.
    var cmd = unpack[string](args[0])

    let (output, _) = execCmdEx(cmd)

    return some(pack(output))

# For our purposes, if any of these is attached, then it's a tty.
proc c4mIsTty*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  if (isatty(cint(stdout.getFileHandle())) != 0 or
      isatty(cint(stderr.getFileHandle())) != 0 or
      isatty(cint(stdin.getFileHandle()))  != 0):
    return some(pack(true))
  else:
    return some(pack(false))

proc c4mTtyName*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let fd0: cint = cint(stdin.getFileHandle())
  if isatty(fd0) != 0:
    return some(pack(ttyname(fd0)))
  let fd1: cint = cint(stdout.getFileHandle())
  if isatty(fd1) != 0:
    return some(pack(ttyname(fd1)))
  let fd2: cint = cint(stderr.getFileHandle())
  if isatty(fd2) != 0:
    return some(pack(ttyname(fd2)))

  return some(pack(""))

proc copySection(src: AttrScope, dst: AttrScope) =
  for k, v in src.contents:
    if v.isA(AttrScope):
      let
        srcSub = v.get(AttrScope)
        newDst = AttrScope(name: srcSub.name, config: srcSub.config)
      copySection(srcSub, newDst)
      newDst.parent   = some(dst)
      dst.contents[k] = newDst
    else:
      let
        srcField = v.get(Attribute)
        newField = Attribute(name: srcField.name, scope: dst,
                             tInfo: srcField.tInfo.copyType(),
                             value: srcField.value)

      dst.contents[k] = newField

proc c4mCopyObject*(args: seq[Box], state: ConfigState): Option[Box] =
  let
    src      = unpack[string](args[0])
    srcParts = src.split(".")
    dst      = unpack[string](args[1])
    aOrE     = attrLookup(state.attrs, srcParts, 0, vlExists)

  result = falseRet

  if aOrE.isA(AttrErr) or "." in dst:
    return
  let
    srcAOrS = aOrE.get(AttrOrSub)

  if srcAOrS.isA(Attribute):
    return

  let
    newPathArr = srcParts[0 ..< ^1] & @[dst]
  # Conflict check trys to look it up, but tells con4m not to create it
  # if it doesn't already exist.  If it returned something, then the
  # object already exists, and we don't allow the copy (plus, it could
  # be a field!)
  #
  # This currently isn't working for Chalk;
  # I don't think it's an error in the lookup code, I think it probably
  # is due to the c42 pre-creating stuff?
  #
  #if attrExists(state.attrs, newPathArr):
  #  return

  result = trueRet

  let
    dstAOrS    = attrLookup(state.attrs, newPathArr, 0, vlSecDef).get(AttrOrSub)
    srcSection = srcAOrS.get(AttrScope)
    dstSection = dstAOrS.get(AttrScope)

  copySection(srcSection, dstSection)

var   containerName: Option[string]
const
  mountInfoFile    = "/proc/self/mountinfo"
  mountInfoPreface = "/docker/containers/"

proc getContainerName*(): Option[string] {.inline.} =
  once:
    var f = newFileStream(mountInfoFile)

    if f == nil: return none(string)

    let lines = f.readAll().split("\n")

    for line in lines:
      let prefixIx = line.find(mountInfoPreface)
      if prefixIx == -1: continue

      let
        startIx = prefixIx + mountInfoPreface.len()
        endIx   = line.find("/", startIx)

      containerName = some(line[startIx ..< endIx])

  return containerName

proc c4mContainerName(args: seq[Box], s: ConfigState): Option[Box] =
  return some(pack(containerName.getOrElse("")))

proc c4mInContainer(args: seq[Box], s: ConfigState): Option[Box] =
  result = if containerName.isSome(): trueRet else: falseRet

proc boolStub*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(false))
proc intStub*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(0))
proc floatStub*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(0.0))
proc stringStub*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(""))
proc listStub*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack[seq[Box]](@[]))
proc dictStub*(args: seq[Box], unused  = ConfigState(nil)): Option[Box] =
  let r = newCon4mDict[Box, Box]()
  return some(pack(r))
proc callbackStub*(args: seq[Box], unused  = ConfigState(nil)): Option[Box] =
  return some(pack(CallbackObj(tInfo: Con4mType(kind: TypeFunc, noSpec: true))))
proc typespecStub*(args: seq[Box], unused  = ConfigState(nil)): Option[Box] =
  return some(pack(Con4mType(kind: TypeTypeSpec)))

proc newCoreFunc*(s:    ConfigState,
                  sig:  string,
                  fn:   BuiltInFn,
                  doc:  string = "",
                  tags: seq[string] = @[],
                  stub: bool        = false) =
  ## Allows you to associate a NIM function with the correct signature
  ## to a configuration for use as a builtin con4m function. `name` is
  ## the parameter used to specify the name exposed to con4m. `tinfo`
  ## is the Conform type signature.

  let
    ix       = sig.find('(')
    name     = sig[0 ..< ix]
    coreName = if fn == nil: "callback" else: "builtin"
    tinfo    = sig[ix .. ^1].toCon4mType()
  var
    f        = fn

  if tinfo.kind != TypeFunc:
    raise c4mException(fmt"Signature provided for {coreName} " &
                          "is not a function signature.")

  if stub:
    case tInfo.retType.kind
    of TypeString, TypeIPAddr, TypeCIDR, TypeDate, TypeTime, TypeDateTime:
      f = stringStub
    of TypeBool:
      f = boolStub
    of TypeInt, TypeChar, TypeDuration, TypeSize, TypeTVar, TypeBottom:
      f = intStub
    of TypeFloat:
      f = floatStub
    of TypeTuple, TypeList:
      f = listStub
    of TypeDict:
      f = dictStub
    of TypeTypeSpec:
      f = typespecStub
    of TypeFunc:
      f = callbackStub

  let docVal = if doc != "": some(doc) else: none(string)

  let b = if f == nil:
            FuncTableEntry(kind:        FnUserDefined,
                           tinfo:       tinfo,
                           impl:        none(Con4mNode),
                           name:        name,
                           cannotCycle: false,
                           locked:      false,
                           doc:         docVal,
                           tags:        tags)
          else:
            # We intentionally don't set cannotCycle, seenThisCheck
            # or locked because they shouldn't be used for builtins.
            FuncTableEntry(kind:    FnBuiltIn,
                           tinfo:   tinfo,
                           builtin: f,
                           name:    name,
                           doc:     docVal,
                           tags:    tags)

  if f == nil:
    if tinfo.retType.isBottom():
      raise c4mException(fmt"{coreName}: callbacks must have a return type")

  if not s.funcTable.contains(name):
    s.funcTable[name] = @[b]
  else:
    for item in s.funcTable[name]:
      if not isBottom(copyType(tinfo), copyType(item.tinfo)):
        raise c4mException(fmt"Type for {coreName} conflicts with existing " &
                               "entry in the function table")
    s.funcTable[name].add(b)

proc newBuiltIn*(s:     ConfigState,
                 sig:   string,
                 fn:    BuiltInFn,
                 doc:   string      = "",
                        tags:  seq[string] = @[]) =
  try:
    newCoreFunc(s, sig, fn, doc, tags)
  except:
    let msg = getCurrentExceptionMsg()
    raise newException(ValueError,
                       fmt"When adding builtin '{sig}': {msg}")

const defaultBuiltins* = [
  # Type conversion operations
  ("bool(int) -> bool",
   BuiltInFn(c4mIToB),
   "Converts an `int` to `true`/`false`. 0 is `false`, everything else is `true`.",
   @["type conversion"]
  ),
  ("bool(float) -> bool",
   BuiltInFn(c4mFToB),
   "Converts a `float` to `true`/`false`.",
   @["type conversion"]
  ),
  ("bool(string) -> bool",
   BuiltInFn(c4mSToB),
   "If the string is empty, returns `false`. Otherwise, returns `true`.",
   @["type conversion"]),
  ("bool(list[`x]) -> bool",
   BuiltInFn(c4mLToB),
   "Returns `false` if the list is empty, `true` otherwise.",
   @["type conversion"]),
  ("bool(dict[`x,`y]) -> bool",
   BuiltInFn(c4mDToB),
   "Returns `false` if the dict is empty, `true` otherwise",
   @["type conversion"]),
  ("float(int) -> float",
   BuiltInFn(c4mItoF),
   "Converts the value into a `float`.",
   @["type conversion"]),
  ("int(float) -> int",
   BuiltInFn(c4mFtoI),
   "Converts a `float` to an `int`, with typical truncation semantics.",
   @["type conversion"]),
  ("$(`t) -> string",
   BuiltInFn(c4mToString),
   "Converts any value into a `string`.",
   @["type conversion"]),
  ("Duration(string) -> Duration",
   BuiltInFn(c4mSToDur),
   """
Parses a `string` into a `Duration` object. The config will error if the conversion fails.

`Duration` literals accept:
- us usec usecs
- ms msec msecs
- s sec secs seconds
- m min mins minutes
- h hr hrs hours
- d day days
- w wk wks week weeks
- y yr yrs year years

None of the above categories should be repeated. Multiple items can be space separated (though it is optional).

For instance, `1 week 2 days` is valid, as is:
`4yrs 2 days 4 hours 6min7sec2years`

This is the exact same syntax as if you declare a `Duration` literal directly, except for the quoting mechanism. Specifically:
```myduration := <<1 hr 10 mins>>```
Is effectively the same as:
```myduration := Duration("1 hr 10 mins")```

Except that syntax errors will be found before running the script in
the first case.
""",
   @["type conversion"]),
  ("IPAddr(string) -> IPAddr",
   BuiltInFn(c4mStoIP),
   """
Parses a `string` into an IP address. Both ipv4 and ipv6 addresses are allowed, but blocks of addresses are not; use the CIDR type for that.

Generally, using this function to convert from a `string` is not necessary; you can write IPAddr literals with 'special' literal quotes:
```x := << 2001:db8:1::ab9:C0A8:102 >>```
is functionally equal to:
```x := IPAddr("2001:db8:1::ab9:C0A8:102")```

In the first case, con4m will catch syntax errors before the configuration starts executing. In the second, the checking won't be until runtime, at which point the config execution will abort with an error.
""",
   @["type conversion"]),
  ("CIDR(string) -> CIDR",
   BuiltInFn(c4mSToCIDR),
   """
Parses a `string` that specifies a block of IP addresses into a `CIDR` type. CIDR stands for Classless Inter-Domain Routing; it's the standard way to express subnets.

Generally, using this function to convert from a `string` is not necessary; you can write `CIDR` literals with 'special' literal quotes:
```x := << 192.168.0.0/16 >>```
is functionally equal to:
```x := CIDR("192.168.0.0/16")```

In the first case, con4m will catch syntax errors before the configuration starts executing. In the second, the checking won't be until runtime, at which point the config execution will abort with an error. IPv6 addresses are also supported. Either of the following work:
```x := << 2001:db8:1::ab9:C0A8:102/127 >>
x := CIDR("2001:db8:1::ab9:C0A8:102/127")```
""",
   @["type conversion"]),
  ("Size(string) -> Size",
   BuiltInFn(c4mSToSize),
   """
Converts a `string` representing a size in bytes into a con4m `Size` object.
A size object can use any of the following units:

- b, B, bytes, Bytes    -- bytes
- k, K, kb, Kb, KB      -- kilobytes (1000 bytes)
- ki, Ki, kib, KiB, KIB -- kibibytes (1024 bytes)
- m, M, mb, Mb, MB      -- megabytes (1,000,000 bytes)
- mi, Mi, mib, MiB, MIB -- mebibytes (1,048,576 bytes)
- g, G, gb, Gb, GB      -- gigabytes (1,000,000,000 bytes)
- gi, Gi, gib, GiB, GIB -- gibibytes (1,073,741,824 bytes)
- t, T, tb, Tb, TB      -- terabytes (10^12 bytes)
- ti, Ti, tib, TiB, TIB -- tebibytes (2^40 bytes)

The following are functionally equal:
```
x := << 200ki >>
```
and:
```
x := Size("200ki")
```

The main difference is that the former is checked for syntax problems before execution, and the later is checked when the call is made.
""",
   @["type conversion"]),
  ("Date(string) -> Date",
   BuiltInFn(c4mSToDate),
   """
Converts a `string` representing a date into a Con4m date object. We generally accept ISO dates.

However, we assume that it might make sense for people to only provide one of the three items, and possibly two. Year and day of month without the month probably doesn't make sense often, but whatever.

But even the old ISO spec doesn't accept all variations (you can't even do year by itself. When the *year* is omitted, we use the *old* ISO format, in hopes that it will be recognized by most software.

Specifically, depending on a second omission, the format will be:
```
--MM-DD
--MM
---DD
```

However, if the year is provided, we will instead turn omitted numbers into 0's, because for M and D that makes no semantic sense (whereas it does for Y), so should be unambiguous and could give the right reuslts depending on the checking native libraries do when parsing.

We also go the ISO route and only accept 4-digit dates. And, we don't worry about negative years. They might hate me in the year 10,000, but I don't think there are enough cases where someone needs to specify "200 AD" in a config file to deal w/ the challenges with not fixing the length of the year field.

There is a separate `DateTime` type.

The following are all valid con4m `Date` objects:
```
x := Date("Jan 7, 2007")
x := Date("Jan 18 2027")
x := Date("Jan 2027")
x := Date("Mar 0600")
x := Date("2 Mar 1401")
x := Date("2 Mar")
x := Date("2004-01-06")
x := Date("--03-02")
x := Date("--03")
```

The following give the same effective results as above, but syntax errors are surfaced at compile time instead of run time:
```
x := << Jan 7, 2007 >>
x := << Jan 18 2027 >>
x := << Jan 2027 >>
x := << Mar 0600 >>
x := << 2 Mar 1401 >>
x := << 2 Mar >>
x := << 2004-01-06 >>
x := << --03-02 >>
x := << --03 >>
```
""",
   @["type conversion"]),
  ("Time(string) -> Time",
   BuiltInFn(c4mSToTime),
   """
Conversion of a `string` to a con4m `Time` specification, which follows ISO standards, including Z. The following are valid `Time` objects:
```
x := Time("12:23:01.13131423424214214-12:00")
x := Time("12:23:01.13131423424214214Z")
x := Time("12:23:01+23:00")
x := Time("2:03:01+23:00")
x := Time("02:03+23:00")
x := Time("2:03+23:00")
x := Time("2:03")
```

The following are identical, except that syntax errors are surfaced before execution begins:
```
x := << 12:23:01.13131423424214214-12:00 >>
x := << 12:23:01.13131423424214214Z >>
x := << 12:23:01+23:00 >>
x := << 2:03:01+23:00 >>
x := << 02:03+23:00 >>
x := << 2:03+23:00 >>
x := << 2:03 >>
```
""",
   @["type conversion"]),
  ("DateTime(string) -> DateTime",
   BuiltInFn(c4mSToDateTime),
   """
Conversion of a `string` to a `DateTime` type, which follows ISO standards, including Z, though see notes on the separate Date type.

The following are valid DateType objects:
```
x := DateTime("2004-01-06T12:23:01+23:00")
x := DateTime("--03T2:03")
x := DateTime("2 Jan, 2004 T 12:23:01+23:00")
```

The following are identical, except that syntax errors are surfaced before execution begins:
```
x := << 2004-01-06T12:23:01+23:00 >>
x := << --03T2:03 >>
x := << 2 Jan, 2004 T 12:23:01+23:00 >>
```
""",
   @["type conversion"]),
  ("char(int) -> char",
   BuiltInFn(c4mSelfRet),
   "Casts an int to a char, truncating on overflow",
   @["type conversion"]),
  ("int(char) -> int",
   BuiltInFn(c4mSelfRet),
   "Casts a char to an int",
   @["type conversion"]),
  ("to_usec(Duration) -> int",
   BuiltInFn(c4mSelfRet),
   "Cast a duration object to an integer in seconds",
   @["type conversion"]),
  ("to_msec(Duration) -> int",
   BuiltInFn(c4mDurAsMSec),
   "Convert a Duration object into an int representing msec",
   @["type conversion"]),
  ("to_sec(Duration) -> int",
   BuiltInFn(c4mDurAsSec),
   """
Convert a Duration object into an int representing seconds, truncating any sub-second information.
""",
   @["type conversion"]),
  ("to_type(string) -> typespec",
   BuiltInFn(c4mStrToType),
   """
Turns a `string` into a `typespec` object. Errors cause execution to terminate with an error. Generally, this shouldn't be necessary in user configuration files. Even if the user needs to name a type in a config file, the can directly write type literals.

For instance:
```
x := to_type("list[string]")
```
is equal to:
```
x := list[string]
```
""",
   @["type conversion"]),
  ("to_chars(string) -> list[char]",
   BuiltInFn(c4mStrToChars),
   """
Turns a `string` into an array of characters. These are unicode characters, not ASCII characters. Use `to_bytes()` to turn into bytes.

If the string isn't valid UTF-8, evaluation will stop with an error.
""",
   @["type conversion"]),
  ("to_bytes(string) -> list[char]",
   BuiltInFn(c4mStrToBytes),
   """
Turns a `string` into an array of 8-bit bytes.
""",
   @["type conversion"]),
  ("to_string(list[char]) -> string",
   BuiltInFn(c4mCharsToString),
   """
Turn a list of characters into a `string` object. Will work for both arrays utf8 codepoints and for raw bytes.
""",
   @["type conversion"]),


  #[ Not done yet:
  ("get_day(Date) -> int",          BuiltInFn(c4mGetDayFromDate)),
  ("get_month(Date) -> int",        BuiltInFn(c4mGetMonFromDate)),
  ("get_year(Date) -> int",         BuiltInFn(c4mGetYearFromDate)),
  ("get_day(DateTime) -> int",      BuiltInFn(c4mGetDayFromDate)),
  ("get_month(DateTime) -> int",    BuiltInFn(c4mGetMonFromDate)),
  ("get_year(DateTime) -> int",     BuiltInFn(c4mGetYearFromDate)),
  ("get_hour(Time) -> int",         BuiltInFn(c4mGetHourFromTime)),
  ("get_min(Time) -> int",          BuiltInFn(c4mGetMinFromTime)),
  ("get_sec(Time) -> int",          BuiltInFn(c4mGetSecFromTime)),
  ("fractsec(Time) -> int",         BuiltInFn(c4mGetFracFromTime)),
  ("tz_offset(Time) -> string",     BuiltInFn(c4mGetTZOffset)),
  ("get_hour(DateTime) -> int",     BuiltInFn(c4mGetHourFromTime)),
  ("get_min(DateTime) -> int",      BuiltInFn(c4mGetMinFromTime)),
  ("get_sec(DateTime) -> int",      BuiltInFn(c4mGetSecFromTime)),
  ("fractsec(DateTime) -> int",     BuiltInFn(c4mGetFracFromTime)),
  ("tz_offset(DateTime) -> string", BuiltInFn(c4mGetTZOffset)),
  ("ip_part(CIDR) -> IPAddr",       BuiltInFn(c4mCIDRToIP)),
  ("net_size(CIDR) -> int",         BuiltInFn(c4mCIDRToInt)),
  ("to_CIDR(IPAddr, int) -> CIDR",  BuiltInFn(c4mToCIDR)),
  ]#
  # String manipulation functions.
  ("contains(string, string) -> bool",
   BuiltInFn(c4mContainsStrStr),
   "Returns `true` if the first argument contains the second argument.",
   @["string"]),
  ("starts_with(string, string) -> bool",
   BuiltInFn(c4mStartsWith),
   "Returns `true` if the first argument starts with the second argument.",
   @["string"]),
  ("ends_with(string, string) -> bool",
   BuiltInFn(c4mEndsWith),
   "Returns `true` if the first argument ends with the second argument.",
   @["string"]),
  ("find(string, string) -> int",
   BuiltInFn(c4mFindFromStart),
   """
If the first argument contains the first `string` anywhere in it, this returns the index of the first match. Otherwise, it returns -1 to indicate no match.
""",
   @["string"]),
  ("len(string) -> int",
   BuiltInFn(c4mStrLen),
   """
Returns the length of a `string` in bytes. This does NOT return the number of characters if there are multi-byte characters. `utf8_len()` does that.
""",
   @["string"]),
  ("slice(string, int) -> string",
   BuiltInFn(c4mSliceToEnd),
   """
Returns a new `string` that's a substring of the first one, starting at the given index, continuing through to the end of the string. This has Python-like semantics, accepting negative numbers to index from the back.
""",
   @["string"]),
  ("slice(string, int, int) -> string",
   BuiltInFn(c4mSlice),
   """
Returns a new `string` that's a substring of the first one, starting at the given index, continuing through to the second index (non-inclusive). This has Python-like semantics, accepting negative numbers to index from the back.
""",
   @["string"]),
  ("slice(list[`x], int, int) -> list[`x]",
   BuiltInFn(c4mListSlice),
   """
Returns a new list that's derived by copying from the first one, starting at the given index, continuing through to the second index (non-inclusive). This has python-like semantics, accepting negative numbers to index from the back.
""",
   @["string"]),
  ("split(string,string) -> list[string]",
   BuiltInFn(c4mSplit),
   """
Turns a list into an array by splitting the first `string` based on the second `string`. The second `string` will not appear in the output.
""",
   @["string"]),
  ("strip(string) -> string",
   BuiltInFn(c4mStrip),
   """
Returns a copy of the input, with any leading or trailing white space removed.
""",
   @["string"]),
  ("pad(string, int) -> string",
   BuiltInFn(c4mPad),
   """
Return a copy of the input `string` that is at least as wide as indicated by the integer parameter. If the input `string` is not long enough, spaces are added to the end.
""",
   @["string"]),
  ("format(string) -> string",
   BuiltInFn(c4mFormat),
   """
Makes substitutions within a `string`, based on variables that are in scope. For the input `string`, anything inside braces {} will be treated as a specifier. You can access attributes that are out of scope by fully dotting from the top-level name. All tags are currently part of the dotted name. You can use both attributes and variables in a specifier. strings, bools, ints and floats are acceptable for specifiers, but lists and dictionaries are not.

There is currently no way to specify things like padding and alignment in a format specifier. If you want to insert an actual { or } character that shouldn't be part of a specifier, quote them by doubling them up (e.g., {{ to get a single left brace).
""",
   @["string"]),
  ("base64(string) -> string",
   BuiltInFn(c4mBase64),
   """
Returns a base64-encoded version of the `string`, using the traditional Base64 character set.
""",
   @["string"]),
  ("base64_web(string) -> string",
   BuiltInFn(c4mBase64Web),
   """
Returns a base64-encoded version of the `string`, using the web-safe Base64 character set.
""",
   @["string"]),
  ("debase64(string) -> string",
   BuiltInFn(c4mDecode64),
   "Decodes a base64 encoded `string`, accepting either common character set.",
   @["string"]),
  ("hex(string) -> string",
   BuiltInFn(c4mToHex),
   "Hex-encodes a string.",
   @["string"]),
  ("hex(int) -> string",
   BuiltInFn(c4mIntToHex),
   "Turns an integer into a hex-encoded `string`.",
   @["string"]),
  ("dehex(string) -> string",
   BuiltInFn(c4mFromHex),
   """
Takes a hex-encoded `string`, and returns a `string` with the hex-decoded bytes.
""",
   @["string"]),
  ("sha256(string) -> string",
   BuiltInFn(c4mSha256),
   """
Computes the SHA-256 hash of a `string`, returning the result as a hex-encoded `string`.
"""
   ,
   @["string"]),
  ("sha512(string) -> string",
   BuiltInFn(c4mSha512),
   """
Computes the SHA-512 hash of a `string`, returning the result as a hex-encoded `string`.
""",
   @["string"]),
  ("upper(string) -> string",
   BuiltInFn(c4mUpper),
   """
Converts any unicode characters to their upper-case representation, where possible, leaving them alone where not.
""",
   @["string"]),
  ("lower(string) -> string",
   BuiltInFn(c4mLower),
   """
Converts any unicode characters to their lower-case representation, where possible, leaving them alone where not.
""",
   @["string"]),
  ("join(list[string], string) -> string",
   BuiltInFn(c4mJoin),
   """
Creates a single `string` from a list of `string`, by adding the second value between each item in the list.
""",
   @["string"]),
  ("replace(string, string, string)->string",
   BuiltInFn(c4mReplace),
   """
Return a copy of the first argument, where any instances of the second argument are replaced with the third argument.
""",
   @["character"]),
  ("utf8_len(char) -> int",
   BuiltInFn(c4mUTF8Len),
   """
Return the number of UTF-8 encoded characters (aka codepoints) in a `string`.
""",
   @["character"]),
  ("is_combining(char) -> bool",
   BuiltInFn(c4mIsCombining),
   """
Returns `true` if a character is a UTF-8 combining character, and `false` otherwise.
""",
   @["character"]),
  ("is_lower(char) -> bool",
   BuiltInFn(c4mIsLower),
   """
Returns `true` if the given character is a lower case character, `false` otherwise.
This function is unicode aware.
""",
   @["character"]),
  ("is_upper(char) -> bool",
   BuiltInFn(c4mIsUpper),
   """
Returns `true` if the given character is an upper case character, `false` otherwise.
This function is unicode aware.
""",
   @["character"]),
  ("is_space(char) -> bool",
   BuiltInFn(c4mIsSpace),
   """
Returns `true` if the given character is a valid space character, per  the Unicode specification.
""",
   @["character"]),
  ("is_alpha(char) -> bool",
   BuiltInFn(c4mIsAlpha),
   """
Returns `true` if the given character is considered an alphabet character in the Unicode spec.
""",
   @["character"]),
  ("is_num(char) -> bool",
   BuiltInFn(c4mIsNum),
   """
Returns `true` if the given character is considered an number in the Unicode spec.
""",
   @["character"]),
  ("is_alphanum(char) -> bool",
   BuiltInFn(c4mIsAlphaNum),
   """
Returns `true` if the given character is considered an alpha-numeric character in the Unicode spec.
""",
   @["character"]),

  # Container (list and dict) basics.
  ("len(list[`x]) -> int",
   BuiltInFn(c4mListLen),
   "Returns the number of items in a list.",
   @["list"]),
  ("len(dict[`x,`y]) -> int",
   BuiltInFn(c4mDictLen),
   "Returns the number of items contained in a dict",
   @["dict"]),
  ("keys(dict[`x,`y]) -> list[`x]",
   BuiltInFn(c4mDictKeys),
   "Returns a list of the keys in a dictionary.",
   @["dict"]),
  ("values(dict[`x,`y]) -> list[`y]",
   BuiltInFn(c4mDictValues),
   "Returns a list of the values in a dictionary.",
   @["dict"]),
  ("items(dict[`x,`y]) -> list[(`x,`y)]",
   BuiltInFn(c4mDictItems),
   """
Returns a list containing two-tuples representing the keys and values in a dictionary.
""",
   @["dict"]),
  ("contains(list[`x],`x) -> bool",
   BuiltInFn(c4mListContains),
   """
Returns `true` if the first argument contains the second argument.
""",
   @["dict"]),
  ("contains(dict[`x ,`y],`x) -> bool",
   BuiltInFn(c4mDictContains),
   """
Returns `true` if the second argument is a set key in the dictionary, `false` otherwise.
""",
   @["dict"]),
  ("set(list[`x], int, `x) -> list[`x]",
   BuiltInFn(c4mLSetItem),
   """
This creates a new list, that is a copy of the original list, except that the index specified by the second parameter is replaced with the value in the third parameter.

NO values in Con4m can be mutated. Everything copies.
""",
   @["list"]),
  ("get(dict[`k,`v],`k) -> `v",
   BuiltInFn(c4mDGetItem),
   """
Returns a value in a dictionary
""",
   @["dict"]),
  ("set(dict[`k,`v],`k,`v) -> dict[`k,`v]",
   BuiltInFn(c4mDSetItem),
   """
Returns a new dictionary based on the old dictionary, except that the new key/value pair will be set. If the key was set in the old dictionary, the value will be replaced.

NO values in Con4m can be mutated. Everything copies.
""",
   @["dict"]),
  ("delete(list[`x], `x) -> list[`x]",
   BuiltInFn(c4mLDeleteItem),
   """
Returns a new list, based on the one passed in the first parameter, where any instances of the item (the second parameter) are removed. If the item does not appear, a copy of the original list will be returned.

NO values in Con4m can be mutated. Everything copies.
""",
   @["list"]),
  ("delete(dict[`k,`v], `k) -> dict[`k,`v]",
   BuiltInFn(c4mDDeleteItem),
   """
Returns a new dictionary that is a copy of the input dictionary, except the specified key will not be present, if it existed.

NO values in Con4m can be mutated. Everything copies.
""",
   @["dict"]),
  ("remove(list[`x], int) -> list[`x]",
   BuiltInFn(c4mLRemoveIx),
   """
This returns a copy of the first parameter, except that the item at the given index in the input will not be in the output. This has Python indexing semantics.

NO values in Con4m can be mutated. Everything copies.
""",
   @["list"]),
  ("array_add(list[`x],list[`x])->list[`x]",
   BuiltInFn(c4mArrAdd),
   """
This creates a new list by concatenating the items in two lists.

Con4m requires all items in a list have a comptable type.
""",
   @["list"]),

  # File system routines
  ("list_dir() -> list[string]",
   BuiltInFn(c4mListDir),
   "Returns a list of files in the current working directory.",
   @["filesystem"]),
  ("list_dir(string) -> list[string]",
   BuiltInFn(c4mListDir),
   """
Returns a list of files in the specified directory. If the directory is invalid, no error is given; the results will be the same as if the directory were empty.
""",
   @["filesystem"]),
  ("read_file(string) -> string",
   BuiltInFn(c4mReadFile),
   """
Returns the contents of the file. On error, this will return the empty `string`.
""",
   @["filesystem"]),
  ("write_file(string, string) -> bool",
   BuiltInFn(c4mWriteFile),
   """
Writes, to the file name given in the first argument, the value of the `string` given in the second argument. Returns `true` if successful, `false` otherwise.
""",
   @["filesystem"]),
  ("copy_file(string, string) -> bool",
   BuiltInFn(c4mCopyFile),
   """
Copies the contents of the file specified by the first argument to the file specified by the second, creating the new file if necessary,  overwriting it otherwise. Returns `true` if successful, `false` otherwise.
""",
   @["filesystem"]),
  ("move_file(string, string) -> bool",
   BuiltInFn(c4mMove),
   """
Moves the file specified by the first argument to the location specified by the second, overwriting any file, if present. Returns `true` if successful, `false` otherwise.
""",
   @["filesystem"]),
  ("rm_file(string) -> bool",
   BuiltInFn(c4mRm),
   """
Removes the specified file, if it exists, and the operation is allowed.  Returns `true` if successful.
""",
   @["filesystem"]),
  ("join_path(string, string) -> string",
   BuiltInFn(c4mJoinPath),
   """
Combines two pieces of a path in a way where you don't have to worry about extra slashes.
""",
   @["filesystem"]),
  ("resolve_path(string) -> string",
   BuiltInFn(c4mResolvePath),
   """
Turns a possibly relative path into an absolute path. This also expands home directories.
""",
   @["filesystem"]),
  ("path_split(string) -> tuple[string, string]",
   BuiltInFn(c4mSplitPath),
   """
Separates out the final path component from the rest of the path, i.e., typically used to split out the file name from the remainder of the path.
""",
   @["filesystem"]),
  ("find_exe(string, list[string]) -> string",
   BuiltInFn(findExeC4m),
   """
Locate an executable with the given name in the PATH, adding any extra
directories passed in the second argument.
""",
   @["filesystem"]),
  ("cwd()->string",
   BuiltInFn(c4mCwd),
   "Returns the current working directory of the process.",
   @["filesystem"]),
  ("chdir(string) -> bool",
   BuiltInFn(c4mChdir),
   """
Changes the current working directory of the process. Returns `true` if successful.
""",
   @["filesystem"]),
  ("mkdir(string) -> bool",
   BuiltInFn(c4mMkdir),
   "Creates a directory, and returns `true` on success.",
   @["filesystem"]),
  ("is_dir(string) -> bool",
   BuiltInFn(c4mIsDir),
   """
Returns `true` if the given file name exists at the time of the call, and is a directory.
""",
   @["filesystem"]),
  ("is_file(string) -> bool",
   BuiltInFn(c4mIsFile),
   """
Returns `true` if the given file name exists at the time of the call,  and is a regular file.
""",
   @["filesystem"]),
  ("is_link(string) -> bool",
   BuiltInFn(c4mIsLink),
   """
Returns `true` if the given file name exists at the time of the call, and is a link.
""",
   @["filesystem"]),
  ("chmod(string, int) -> bool",
   BuiltInFn(c4mChmod),
   """
Attempt to set the file permissions; returns `true` if successful.
""",
   @["filesystem"]),
  ("file_len(string) -> int",
   BuiltInFn(c4mFileLen),
   """
Returns the number of bytes in the specified file, or -1 if there is an error (e.g., no file, or not readable).
   """,
   @["filesystem"]),
  ("to_tmp_file(string, string) -> string",
   BuiltInFn(c4mTmpWrite),
   """
Writes the `string` in the first argument to a new temporary file. The second argument specifies an extension; a random value is used in the tmp file name.

This call returns the location that the file was written to.
""",
   @["filesystem"]),

  # System routines
  ("echo(*`a)",
   BuiltInFn(c4mEcho),
   """
Output any parameters passed (after automatic conversion to string). A newline is added at the end, but no spaces are added between arguments.

This outputs to stderr, NOT stdout.

`echo()` is the only function in con4m that:

- Accepts variable arguments
- Automatically converts items to strings.
   """,
   @["system"]),
  ("abort(string)",
   BuiltInFn(c4mAbort),
   """
Prints the given error message, then stops the entire program immediately  (not just the config file execution).

The exit code of the process will be 1.
""",
   @["system"]),
  ("env() -> dict[string, string]",
   BuiltInFn(c4mEnvAll),
   """
Returns all environment variables set for the process.
""",
   @["system"]),
  ("env(string) -> string",
   BuiltInFn(c4mEnv),
   """
Returns the value of a specific environment variable. If the environment variable isn't set, you will get the empty string (`""`), same as if the value is explicitly set, but to no value.

To distinguish between the two cases, either call `env_exists()` or dump all environment variables to a dictionary via `env()` and then call `contains()`.
""",
   @["system"]),
  ("env_exists(string) -> bool",
   BuiltInFn(c4mEnvExists),
   """
Returns `true` if the parameter is a named environment variable in the current environment.
""",
   @["system"]),
  ("set_env(string, string) -> bool",
   BuiltInFn(c4mSetEnv),
   """
Sets the value of the environment variable passed in the first parameter, to the value from the second parameter. It returns `true` if successful.
""",
   @["system"]),
  ("getpid() -> int",
   BuiltInFn(c4mGetPid),
   "Return the process ID of the current process",
   @["system"]),
  ("quote(string)->string",
   BuiltInFn(c4mQuote),
   """
Quote a `string`, so that it can be safely passed as a parameter to any shell (e.g., via `run()`)
""",
  @["system"]),
  ("osname() -> string",
   BuiltInFn(c4mGetOsName),
   """
Return a `string` containing the runtime operating system used. Possible values: "macos", "linux", "windows", "netbsd", "freebsd", "openbsd".
""",
   @["system"]),
  ("arch() -> string",
   BuiltInFn(c4mGetArch),
   """
Return a `string` containing the underlying hardware architecture. Supported values: "amd64", "arm64"

The value "amd64" is returned for any x86-64 platform. Other values may be returned on other operating systems, such as i386 on 32-bit X86, but Con4m is not built or tested against other environments.
""",
   @["system"]),
  ("program_args() -> list[string]",
   BuiltInFn(c4mGetArgv),
   """
Return the arguments passed to the program. This does *not* include the program name.
""",
   @["system"]),
  ("program_path() -> string",
   BuiltInFn(c4mGetExePath),
   """
Returns the absolute path of the currently running program.
""",
   @["system"]),
  ("program_name() -> string",
   BuiltInFn(c4mGetExeName),
   """
Returns the name of the executable program being run, without any path
component.
""",
   @["system"]),
  ("high() -> int",
   BuiltInFn(c4mIntHigh),
   """
Returns the highest possible value storable by an int. The int data type is always a signed 64-bit value, so this will always be: 9223372036854775807
   """,
   @["system"]),
  ("low() -> int",
   BuiltInFn(c4mIntLow),
   """
Returns the lowest possible value storable by an int. The int data type is always a signed 64-bit value, so this will always be: -9223372036854775808
   """,
   @["system"]),
  ("rand() -> int",
   BuiltInFn(c4mRandom),
   "Return a secure random, uniformly distributed 64-bit number.",
   @["system"]),
  ("now() -> int",
   BuiltInFn(c4mNow),
   """
Return the current Unix time in ms since Jan 1, 1970. Divide by 1000 for seconds.
""",
   @["system"]),

  ("container_name() -> string",
   BuiltInFn(c4mContainerName),
   """
Returns the name of the container we're running in, or the empty string if we
don't seem to be running in one.
""",
   @["system"]),
  ("in_container() -> bool",
   BuiltInFn(c4mInContainer),
   """
Returns true if we can determine that we're running in a container, and false
if not.
""",
   @["system"]),
  # Binary ops
  ("bitor(int, int) -> int",
   BuiltInFn(c4mBitOr),
   """
Returns the bitwise OR of its parameters.
""",
   @["binary_ops"]),
  ("bitand(int, int) -> int",
   BuiltInFn(c4mBitAnd),
   """
Returns the bitwise AND of its parameters.
""",
   @["binary_ops"]),
  ("xor(int, int) -> int",
   BuiltInFn(c4mBitXor),
   """
Returns the bitwise XOR of its parameters.
   """,
   @["binary_ops"]),
  ("shl(int, int) -> int",
   BuiltInFn(c4mBitShl),
   """
Shifts the bits of the first argument left by the number of bits indicated by the second argument.
   """,
   @["binary_ops"]),
  ("shr(int, int) -> int",
   BuiltInFn(c4mBitShr),
   """
Shifts the bits of the first argument right by the number of bits indicated by the second argument. Note that this operation is a pure shift; it does NOT maintain the sign bit.

That is, it acts as if the two parameters are unsigned.
   """,
   @["binary_ops"]),
  ("bitnot(int) -> int",
   BuiltInFn(c4mBitNot),
   """
Returns a new integer where every bit from the input is flipped.
""",
   @["binary_ops"]),

  # Other parsing stuff
  ("mime_to_dict(string) -> dict[string, string]",
   BuiltInFn(c4mMimeToDict),
   """
Takes a `string` consisting of mime headers, and converts them into  a dictionary of key/value pairs.

For instance:
```
mime_to_dict("Content-Type: text/html\r\nCustom-Header: hi!\r\n")
```

will return:
```
{ "Content-Type" : "text/html",
  "Custom-Header" : "hi!"
}
```

Note that lines that aren't validly formatted are skipped.
""",
   @["parsing"]),
  # Con4m-specific stuff
  ("sections(string) -> list[string]",
   BuiltInFn(c4mSections),
   """
This function is primarily intended to aid in custom config file validation, from a c42spec.

In a c42spec, this function returns a list of all the available 'sections' in the associated config file, beloinging the passed attribute.

In the context of a c42 spec, this code will run in the validation phase that occurs after the config file has finished execution.
For instance, if the config file has:
```
net_config {
  host foo { }
  host bar { }

  somenum: 12
}
```

Then `sections("net_config.host")` will return `["foo", "bar"]`

This does *not* return field values, only sections. So, if you call: `sections("net_config")`, the result will be `["host"]`; `"somenum"` is excluded.

When not running within the context of a c42 spec, this will query the existing configuration file.

In any case, if the passed attribute doesn't exist, or has no sections inside it, the result will be empty.
""",
   @["introspection"]),
  ("fields(string) -> list[string]",
   BuiltInFn(c4mFields),
"""
This function is primarily intended to aid in custom config file validation, from a c42spec.

In a c42spec, this function returns a list of all the available 'fields' in the associated config file, beloinging the passed attribute. Sections are ignored.

In the context of a c42 spec, this code will run in the validation phase that occurs after the config file has finished execution.
For instance, if the config file has:
```
somesection {
  foo: "hello"
  bar: "world"

  somesubsection {
  }
}
```

Then `fields("somesection")` will return `["foo", "bar"]`
When not running within the context of a c42 spec, this will query the existing configuration file.
""",
   @["introspection"]),
  ("typeof(`a) -> typespec",
   BuiltInFn(c4mTypeOf),
   """
This returns the type of the passed expression as a `typespec` object.

Note that the expression is evaluated, so if it has any side effects, they will run.

If you are writing a c42 spec, and want to know the type of an attribute in the runtime config file, this is the WRONG call. Pass the attribute name as a `string` to `attr_type()` for that.
""",
   @["introspection"]),
  ("typecmp(typespec, typespec) -> bool",
   BuiltInFn(c4mCmpTypes),
   """
Compares two types, and returns `true` if they are comptable, and `false` if they are not. For example, ``typecmp(list[`x], [1])`` will return `true`, even though the two types aren't strictly identical. They are, however, compatable, if we bind ``` `x ``` to int.

This is primarily intended to be used for custom type checking operations in a c42 spec.
""",
   @["introspection"]),
  ("attr_type(string) -> typespec",
   BuiltInFn(c4mAttrGetType),
   """
This function allows a c42 spec to retrieve the type associated with a specific attribute in an associated config file, at the time we're validating that config file, after its execution is finished.

C42 spec files cannot check their own attributes with this field. Actual configuration files can.
   """,
   @["introspection"]),
  ("attr_typecmp(string, string) -> bool",
   BuiltInFn(c4mRefTypeCmp),
   """
This allows the C42 specification to compare types of two attributes in the configuration file by attribute name. The two lines below are functionally equal:
```
attr_typecmp(arg1, arg2)
```
and:
```
typecmp(attr_type(arg1), attr_type(arg2))
```
""",
   @["introspection"]),
  ("attr_get(string, typespec[`t]) -> `t",
   BuiltInFn(c4mGetAttr),
   """
This function is meant to allow a c42 spec to get the value of the named attribute, after the config file has executed, during the validation process. It's imperative to provide the expected type of the return value in the second parameter.

It's used to dynamically check the type before returning. If it's wrong, execution will abort with an error message.

Passing in the dynamic type is important for supporting user-defined attributes of arbitrary type.

Con4m checks most types statically whenever possible, but in this case, there needs to be a runtime type check.
As a result, you need to be sure to know what type the field you're querying will be. You can use the `attr_type()` field to retrieve it, and you can be sure it will not change out from under you (unless you run an additional configuration file in the same evaluation context).
""",
   @["introspection"]),
  ("function_exists(func) -> bool",
   BuiltInFn(c4mFnExists),
   """
Returns `true` if if the function specification passed is a defined function.

In a C42 spec, this is checking for the presense of the function in the user config file, while it's being validated post-execution. The intent is to allow you to check dynamically for the appropriate user-defined callbacks existing.

If enabled outside the context of a c42 spec validation, this just checks the current runtime state of the current process at the time of evaluation.
   """,
   @["introspection"]),
  ("attr_split(string)->tuple[string, string]",
   BuiltInFn(c4mSplitAttr),
   """
This takes an attribute in full dot notation, and splits the final piece from the rest of the attribute path.
For instance:
```
attr_split("config.fw_rules.default.rule2")
```
Will result in:
```
("config.fw_rules.default", "rule2")
```
   """,
   @["introspection"]),
  ("attr_exists(string) -> bool",
   BuiltInFn(c4mAttrExists),
   """
In a C42 spec, this call checks the user runtime context, after execution (during the validation phase), returning true if the parameter is a valid, defined attribute, whether it's a field or a section.
""",
   @["introspection"]),
  ("add_override(string, `t) -> bool",
   BuiltInFn(c4mOverride),
   """
This is intended to be used to set a value 'override' for an attribute. A c42spec can use it to force a value in a config. A configuration may also use it to force a value.

Generally, overrides are always enforced once set. They're primarily intended for command-line flags that are set early, to prevent the config file from setting different defaults.

The Con4m `getopts` facility automatically applies overrides to fields, if a command line flag is spec'd to set a particular configuration attribute.
   """,
   @["introspection"]),

  ("function_doc_dump() -> string",
   BuiltInFn(c4mFuncDocDump),
  """
Returns a JSON-encoded `string` consisting of a single JSON 'object' mapping the signatures of available functions to their documentation.
 """,
  @["introspection"]),
  ("copy_object(string, string) -> bool",
   BuiltInFn(c4mCopyObject),
   """
Deep-copys a con4m object specified by full path in the first parameter, creating the object named in the second parameter.

Note that the second parameter cannot be in dot notation; the new object will be created in the same scope of the object being copied.

For instance, `copy_object("profile.foo", "bar")` will create `"profile.bar"`

This function returns `true` on success. Reasons it would fail:
1. The source path doesn't exist.
2. The source path exists, but is a field, not an object.
3. The destination already exists.

Note that this function does not enforce any c42 specification
itself. So if you copy a singleton object that doesn't comply with the
section, nothing will complain until (and if) a validation occurs.
""",
   @["system"]),
  ("url_get(string) -> string",
   BuiltInFn(c4mUrlGet),
   """
Retrieve the contents of the given URL, returning a string. If it's
a HTTPS URL, the remote host's certificate chain must validate for
data to be returned.

If there is an error, the first three digits will be an error code,
followed by a space, followed by any returned message. If the error
wasn't from a remote HTTP response code, it will be 000.

Requests that take more than 5 seconds will be canceled.
""",
   @["network"]),

  ("url_get_pinned(string, string) -> string",
   BuiltInFn(c4mUrlGetPinned),
   """
Same as `url_get()`, except takes a second parameter, which is a path to a
pinned certificate.

The certificate will only be checked if it's an HTTPS connection, but
the remote connection *must* be the party associated with the
certificate passed, otherwise an error will be returned, instead of data.
""",
   @["network"]),
  ("url_post(string, string, dict[string, string]) -> string",
   BuiltInFn(c4mUrlPost),
   """
Uses HTTP post to post to a given URL, returning the resulting as a
string, if successful. If not, the error code works the same was as
for `url_get()`.

The parameters here are:

1. The URL to which to post
2. The body to send with the request
3. The MIME headers to send, as a dictionary. Generally you should at least
   pass a Content-Type field (e.g., {"Content-Type" : "text/plain"}). Con4m
   will NOT assume one for you.

Requests that take more than 5 seconds will be canceled.
""",
   @["network"]),
  ("external_ip() -> string", BuiltInFn(c4mExternalIp),
   """
Returns the external IP address for the current machine.
""",
   @["network"]),
  ("url_post_pinned(string, string, dict[string, string], string) -> string",
   BuiltInFn(c4mUrlPostPinned),
   """
Same as `url_post()`, but takes a certificate file location in the final
parameter, with which HTTPS connections must authenticate against.
""",
   @["network"]),


  when defined(posix):
    ("run(string) -> string",
     BuiltInFn(c4mCmd),
     """
Execute the passed parameter via a shell, returning the output. This function blocks while the subprocess runs.

The exit code is not returned in this version.

Stdout and Stderr are combined in the output.
""",
     @["posix", "system"]),
    ("system(string) -> tuple[string, int]",
     BuiltInFn(c4mSystem),
     """
Execute the passed parameter via a shell, returning a tuple containing the output and the return code of the subprocess. This function blocks while the subprocess runs.

Stdout and Stderr are combined in the output.
     """,
     @["posix", "system"]),
    ("getuid() -> int",
     BuiltInFn(c4mGetUid),
     "Returns the real UID of the underlying logged in user.",
     @["posix", "system"]),
    ("geteuid() -> int",
     BuiltInFn(c4mGetEuid),
     "Returns the effective UID of the underlying logged in user.",
     @["posix", "system"]),
    ("uname() -> list[string]",
     BuiltInFn(c4mUname),
     """
Returns a `string` with common system information, generally should be the same as running `uname -a` on the commadn line.
""",
     @["posix", "system"]),
    ("using_tty() -> bool",
     BuiltInFn(c4mIsTty),
     """
Returns `true` if the current process is attached to a TTY (unix terminal driver). Generally, logged-in users can be expected to have a TTY (though some automation tools can have a TTY with no user).

Still, it's common to act as if a user is present when there is a TTY. For instance, it's common to default to showing colors when attached to a TTY, but to default to no-color otherwise.
""",
     @["posix", "system"]),
    ("tty_name() -> string",
     BuiltInFn(c4mTtyName),
     "Returns the name of the current tty, if any.",
     @["posix", "system"])
]

proc addBuiltinSet(s, bi, exclusions: auto) {.inline.} =
  for item in bi:
    let (name, impl, doc, tags) = item
    s.newBuiltIn(name, impl, doc, tags)

proc addDefaultBuiltins*(s: ConfigState, exclusions: openarray[int] = []) =
  ## This function loads existing default builtins. It gets called
  ## automatically if you ever call `newConfigState()`, `checkTree(node)`,
  ## `evalTree()`, `evalConfig()`, or `con4m()`.
  ##
  ## That is, you probably don't have to call this, though it will
  ## silently do nothing if you double-add.
  ##
  ## Instead, you probably should just use `newBuiltIn()` to add your
  ## own calls, unless you want to remove or rename things.
  ## These calls are grouped here in categories, matching the documentation.
  ## The ordering in the code above does not currently match; it is closer to
  ## the historical order in which things were added.
  ##
  ## You can pass exclusions into the second parameter, identifying
  ## the unique ID of functions you want to exclude. If you pass in
  ## invalid values, they're ignored.

  s.addBuiltinSet(defaultBuiltins, exclusions)
