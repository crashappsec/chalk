# We want to make interoperability as easy as reasonable with other
# languages.  For most of these data types, languages will have
# libraries to work with these items (e.g., times and dates). So Con4m
# tries to keep everything in a format that is easy and unambiguous to
# parse.
#
# Sometimes that's no problem like w/ an IP address, but dates and
# times are a bit harder, specifically because the ISO standard (no
# longer) allows omitting the year, but in a config file that might be
# what's expected when providing a date for something expected to
# happen annually.
import types, strutils, parseutils, options, nimutils

proc otherLitToIPV4Addr(s: string): Option[Con4mIPAddr] =
  var ix = 0

  for i in 0 ..< 4:
    var b = 0
    if s[ix] notin '0'..'9':
      return none(Con4mIPAddr)
    while ix < len(s) and s[ix] in '0'..'9':
      b  *= 10
      b  += int(s[ix]) - int('0')
      ix += 1
    if len(s) == ix and i == 3:
      return some(Con4mIPAddr(s))
    if i == 3 or ix >= len(s) or s[ix] != '.' or b > 255:
      return none(Con4mIPAddr)
    ix += 1
  unreachable

proc otherLitToIPV6Addr(s: string): Option[Con4mIPAddr] =
  var
    i       = 0
    numSecs = 1
    secSz   = 0

  while i < len(s):
    case s[i]
    of '0'..'9', 'a'..'f', 'A'..'F':
      if secSz == 4: return none(Con4mIPAddr)
      secSz += 1
    of ':':
      secSz = 0
      if numSecs == 8: return none(Con4mIPAddr)
      numSecs += 1
    else:
      return none(Con4mIPAddr)
    i += 1
  if numSecs < 3:
    return none(Con4mIPAddr)
  return some(Con4mIPAddr(s))

proc otherLitToIPAddr*(lit: string): Option[Con4mIPAddr] =
  let s = lit.strip()

  result = s.otherLitToIPV4Addr()

  if result.isNone():
    result = s.otherLitToIPV6Addr()

proc otherLitToCIDR*(lit: string): Option[Con4mCIDR] =
  var
    s = lit.strip()
    f = s.find('/')
  if f == -1 or (f+1 == len(s)):
    return none(Con4mCIDR)
  if otherLitToIPAddr(s[0..<f]).isNone():
    return none(Con4mCIDR)
  try:
    var n: int
    discard s.parseInt(n, f + 1)
    if n < 0 or n > 128:
      return none(Con4mCIDR)
    elif n > 32 and s.contains('.'):
      return none(Con4mCIDR)
    else:
      return some(Con4mCIDR(s))
  except:
    return none(Con4mCIDR)

proc otherLitToNativeSize*(lit: string): Option[Con4mSize] =
  var
    s        = lit.strip()
    letterix = 0
    multiple = 1'u64

  if len(s) == 0:
    return none(Con4mSize)

  for i in 0 ..< len(s):
    if s[i] notin '0' .. '9':
      letterix = i
      break
  if letterix < 1:
    return none(Con4mSize)
  case s[letterix .. ^1].strip()
  of "b", "B", "Bytes", "bytes":
    multiple = 1
  of "k", "K", "kb", "Kb", "KB":
    multiple = 1000
  of "ki", "Ki", "kib", "KiB", "KIB":
    multiple = 1024
  of "m", "M", "mb", "Mb", "MB":
    multiple = 1000000
  of "mi", "Mi", "mib", "MiB", "MIB":
    multiple = 1048576
  of "g", "G", "gb", "Gb", "GB":
    multiple = 1000000000
  of "gi", "Gi", "gib", "GiB", "GIB":
    multiple = 1073741824
  of "t", "T", "tb", "Tb", "TB":
    multiple = 1000000000000'u64
  of "ti", "Ti", "tib", "TiB", "TIB":
    multiple = 1099511627776'u64
  else:
    return none(Con4mSize)
  try:
    var
      intpart = s[0 ..< letterix]
      sz: int
    discard intpart.parseInt(sz, 0)
    return some(Con4mSize(uint64(sz) * multiple))
  except:
    return none(Con4mSize)

proc otherLitToNativeDuration*(lit: string): Option[Con4mDuration] =
  var
    parts: seq[(string, string)] = @[]
    s                            = lit.strip()
    startix                      = 0
    ix                           = 0
    duration                     = 0'u64
    seenUsec                     = false
    seenMsec                     = false
    seenSec                      = false
    seenMin                      = false
    seenHr                       = false
    seenDay                      = false
    seenWeek                     = false
    seenYear                     = false
    numPart: string
    parsedInt: int

  while ix < len(s):
    startix = ix
    while ix < len(s):
      if s[ix] notin '0'..'9':
        break
      ix += 1
    if startix == ix:
      return none(Con4mDuration)
    numPart = s[startix ..< ix]
    while ix < len(s) and s[ix] == ' ': ix += 1
    if ix == len(s):
      return none(Con4mDuration)
    startix = ix
    while ix < len(s):
      case s[ix]
      of 'a'..'z', 'A'..'Z':
        ix = ix + 1
      else:
        break
    if startix == ix:
      return none(Con4mDuration)
    parts.add((numPart, s[startix ..< ix]))
    while ix < len(s):
      case s[ix]
      of ',':
        ix = ix + 1
      of '0'..'9', ' ':
        break
      else:
        return none(Con4mDuration)
    if startix == ix:
      return none(Con4mDuration)
    while ix < len(s) and s[ix] == ' ':
      ix = ix + 1
  if len(parts) == 0:
    return none(Con4mDuration)
  for (numAsString, unitStr) in parts:
    try:
      discard numAsString.parseInt(parsedInt, 0)
    except:
      return none(Con4mDuration)
    case unitStr.toLower()
    of "us", "usec", "usecs":
      if seenUsec: return none(Con4mDuration) else: seenUsec = true
      duration += uint64(parsedInt)
    of "ms", "msec", "msecs":
      if seenMsec: return none(Con4mDuration) else: seenMSec = true
      duration += uint64(parsedInt * 1000)
    of "s", "sec", "secs", "seconds":
      if seenSec: return none(Con4mDuration) else: seenSec = true
      duration += uint64(parsedInt * 1000000)
    of "m", "min", "mins", "minutes":
      if seenMin: return none(Con4mDuration) else: seenMin = true
      duration += uint64(parsedInt * 1000000 * 60)
    of "h", "hr", "hrs", "hours":
      if seenHr: return none(Con4mDuration) else: seenHr = true
      duration += uint64(parsedInt * 1000000 * 60 * 60)
    of "d", "day", "days":
      if seenDay: return none(Con4mDuration) else: seenDay = true
      duration += uint64(parsedInt * 1000000 * 60 * 60 * 24)
    of "w", "wk", "wks", "week", "weeks":
      if seenWeek: return none(Con4mDuration) else: seenWeek = true
      duration += uint64(parsedInt * 1000000 * 60 * 60 * 24 * 7)
    of "y", "yr", "yrs", "year", "years":
      if seenYear: return none(Con4mDuration) else: seenYear = true
      duration += uint64(parsedInt * 1000000 * 60 * 60 * 24 * 365)
    else:
      return none(Con4mDuration)
  return some(Con4mDuration(duration))

# For dates, we assume that it might make sense for people to only
# provide one of the three items, and possibly two. Year and day of
# month without the month probably doesn't make sense often, but
# whatever.
#
# But even the old ISO spec doesn't accept all variations (you can't
# even do year by itself. When the *year* is omitted, we use the *old*
# ISO format, in hopes that it will be recognized by most software.
# Specifically, depending on a second omission, the format will be:
# --MM-DD
# --MM
# ---DD
#
# However, if the year is provided, we will instead turn omitted
# numbers into 0's, because for M and D that makes no semantic sense
# (whereas it does for Y), so should be unambiguous and could give the
# right results depending on the checking native libraries do when
# parsing.
#
# Note that we also go the ISO route and only accept 4-digit
# dates. And, we don't worry about negative years. They might hate me
# in the year 10,000, but I don't think there are enough cases where
# someone needs to specify "200 AD" in a config file to deal w/ the
# challenges with not fixing the length of the year field.
proc usWrittenDate(lit: string): Option[Con4mDate] =
  var
    monthPart = ""
    dayPart   = ""
    yearPart  = ""
    s         = lit.strip()
    ix        = 0
    startix   = 0
    monthstr  = ""
    day       = 0
    year      = 0

  if len(s) == 0: return none(Con4mDate)
  while ix < len(s):
    case s[ix]
    of 'a' .. 'z', 'A' .. 'Z':
      ix += 1
    else:
      break
  if ix == startix: return none(Con4mDate)
  monthPart = s[startix ..< ix]
  while ix < len(s):
    if s[ix] == ' ':
      ix += 1
    else:
      break
  startix = ix
  while ix < len(s):
    case s[ix]
    of '0' .. '9':
      ix += 1
    of ' ', ',':
      break
    else:
      return none(Con4mDate)
  if startix != ix:
    dayPart = s[startIx ..< ix]
  if ix < len(s) and s[ix] == ',':
    ix += 1
  while ix < len(s):
    if s[ix] != ' ':
      break
    ix += 1
  startix = ix
  while ix < len(s):
    if s[ix] notin '0'..'9':
      break
    ix += 1
  if ix != len(s):
    return none(Con4mDate)
  yearPart = s[startix ..< ix]
  if len(daypart) == 4 and len(yearpart) == 0:
    yearpart = daypart
    daypart  = ""

  case monthpart.toLower()
  of "jan", "january":            monthstr = "01"
  of "feb", "february":           monthstr = "02"
  of "mar", "march":              monthstr = "03"
  of "apr", "april":              monthstr = "04"
  of "may":                       monthstr = "05"
  of "jun", "june":               monthstr = "06"
  of "jul", "july":               monthstr = "07"
  of "aug", "august":             monthstr = "08"
  of "sep", "sept", "september":  monthstr = "09"
  of "oct", "october":            monthstr = "10"
  of "nov", "november":           monthstr = "11"
  of "dec", "december":           monthstr = "12"
  else:                           return none(Con4mDate)

  try:
    if len(daypart) != 0:
      discard daypart.parseInt(day, 0)
    if len(yearpart) != 0:
      discard yearpart.parseInt(year, 0)
  except:
    return none(Con4mDate)

  if day > 31: return none(Con4mDate)
  if monthstr == "02" and day >= 30:
    return none(Con4mDate)
  if day == 31 and monthstr in ["04", "06", "09", "11"]:
    return none(Con4mDate)
  if year != 0:
    var res = $(year)
    while len(res) != 4:
      res = "0" & res
    res &= "-" & monthstr
    if day != 0:
      if day < 10:
        res &= "-0" & $(day)
      else:
        res &= "-" & $(day)
    return some(res)
  else:
    if day == 0: return some("--" & monthstr)
    elif day >= 10:
      return some("--" & monthstr & "-" & $(day))
    else:
      return some("--" & monthstr & "-0" & $(day))

proc otherWrittenDate(lit: string): Option[Con4mDate] =
  var
    dayPart   = ""
    s         = lit.strip()
    ix        = 0
    startix   = 0

  while ix < len(s):
    if s[ix] notin '0'..'9':
      break
    ix += 1
  if ix == 0:
    return none(Con4mDate)
  dayPart = s[0 ..< ix]
  while ix < len(s):
    if s[ix] != ' ':
      break
    ix += 1
  startix = ix
  while ix < len(s):
    if s[ix] notin 'a' .. 'z' and s[ix] notin 'A' .. 'Z':
      break
    ix += 1
  if startix == ix:
    return none(Con4mDate)

  return usWrittenDate(s[startix ..< ix] & " " & dayPart & s[ix .. ^1])

proc isoDateTime(lit: string): Option[Con4mDate] =
  var
    s = lit.strip()
    m = 0
    d = 0

  if len(s) == 4:
    if s[0] != '-' or s[1] != '-': return none(Con4mDate)
    if s[2] notin '0' .. '1' or s[3] notin '0' .. '9': return none(Con4mDate)
    m = (int(s[2]) - int('0')) * 10 + int(s[3]) - int('0')
    if m > 12: return none(Con4mDate)
    return some(s)
  elif len(s) == 7:
    if s[0] != '-' or s[1] != '-' or s[4] != '-': return none(Con4mDate)
    if s[2] notin '0' .. '1' or s[3] notin '0' .. '9': return none(Con4mDate)
    m = (int(s[2]) - int('0')) * 10 + int(s[3]) - int('0')
    if m > 12: return none(Con4mDate)
    if s[5] notin '0' .. '3' or s[6] notin '0' .. '9': return none(Con4mDate)
    d = (int(s[5]) - int('0')) * 10 + int(s[6]) - int('0')
    if d > 31: return none(Con4mDate)
    if m == 2 and d > 29: return none(Con4mDate)
    if d == 31 and m in [0, 6, 9, 11]: return none(Con4mDate)
    return some(s)
  elif len(s) == 8:
    # This should be the more rare case, and the format we return.
    s = s[0 .. 3] & '-' & s[4 .. 5] & '-' & s[6 .. 7]
  elif len(s) != 10:
    return none(Con4mDate)
  if s[4] != '-' or s[7] != '-':
    return none(Con4mDate)
  for i in 0 .. 3:
    if s[0] notin '0' .. '9':
      return none(Con4mDate)
  if s[5] notin '0' .. '1' or s[6] notin '0' .. '9':
    return none(Con4mDate)
  m = (int(s[5]) - int('0')) * 10 + int(s[6]) - int('0')
  if m > 12:
    return none(Con4mDate)
  if s[8] notin '0' .. '3' or s[9] notin '0' .. '9':
    return none(Con4mDate)
  d = (int(s[8]) - int('0')) * 10 + int(s[9]) - int('0')
  if d > 31: return none(Con4mDate)
  if m == 2 and d > 29: return none(Con4mDate)
  if d == 31 and m in [0, 6, 9, 11]: return none(Con4mDate)

  return some(s)

proc otherLitToNativeDate*(lit: string): Option[Con4mDate] =
  result = lit.isoDateTime()
  if result.isNone():
    result = lit.usWrittenDate()
  if result.isNone():
    result = lit.otherWrittenDate()

proc otherLitToNativeTime*(lit: string): Option[Con4mTime] =
  var
    hr, min, sec:   int
    s:              string = lit.strip()
    fracsec:        string = ""
    offset:         string = ""
    n:              int

  # We'll tolerate missing leading zeros, but only for the hours field.
  if len(s) < 2 or s[1] == ':':
    s = "0" & s
  if len(s) < 5:
    return none(Con4mTime)
  if s[0] notin '0' .. '2':
    return none(Con4mTime)
  if s[1] notin '0' .. '9' or s[2] != ':':
    return none(Con4mTime)
  if s[3] notin '0' .. '5' or s[4] notin '0' .. '9':
    return none(Con4mTime)
  hr  = (int(s[0]) - int('0')) * 10 + int(s[1]) - int('0')
  min = (int(s[3]) - int('0')) * 10 + int(s[4]) - int('0')
  sec = 0
  block iso:
    if len(s) > 5:
      s = s[5 .. ^1]
      case s[0]
      of ':':
        s = s[1 .. ^1]
        if len(s) == 0: return none(Con4mTime)
        elif len(s) == 1: s = "0" & s
        if s[0] notin '0' .. '6' or s[1] notin '0' .. '9':
          return none(Con4mTime)
        sec = (int(s[0]) - int('0')) * 10 + int(s[1]) - int('0')
        s   = s[2 .. ^1]
        if len(s) != 0:
          # We will accept EITHER a real standard fractsec OR a more
          # coloquial AM/PM, but not both.
          case s[0]
          of 'a', 'A', 'p', 'P':
            break iso
          of '.':
            if len(s) == 1: return none(Con4mTime)
            s = s[1 .. ^1]
            while len(s) > 0 and s[0] in '0' .. '9':
              fracsec.add(s[0])
              s = s[1 .. ^1]
          else:
            discard
          if len(s) != 0:
            if len(s) == 1:
              if s[0] notin ['Z', 'z']:
                return none(Con4mTime)
              offset = "Z"
              s      = ""
            elif len(s) != 6:
              return none(Con4mTime)
            elif s[0] notin ['+', '-']:
              return none(Con4mTime)
            elif s[3] != ':':
              return none(Con4mTime)
            elif s[4] notin '0' .. '5' or s[5] notin '0' .. '9':
              return none(Con4mTime)
            elif s[1] notin '0' .. '2' or s[2] notin '0' .. '9':
              return none(Con4mTime)
            else:
              n = (int(s[1]) - int('0')) * 10 + int(s[2]) - int('0')
              if n > 23: return none(Con4mTime)
              offset = s  # Offset string is validated.
              s      = ""
      else:
        case s[0]
        of 'Z', 'z':
          offset = "Z"
          s = s[1 .. ^1]
        of '+', '-':
          if len(s) != 6:
            return none(Con4mTime)
          elif s[3] != ':':
            return none(Con4mTime)
          elif s[4] notin '0' .. '5' or s[5] notin '0' .. '9':
            return none(Con4mTime)
          elif s[1] notin '0' .. '2' or s[2] notin '0' .. '9':
            return none(Con4mTime)
          else:
            n = (int(s[1]) - int('0')) * 10 + int(s[2]) - int('0')
            if n > 23: return none(Con4mTime)
            offset = s  # Offset string is validated.
            s      = ""
        else:
          return none(Con4mTime)
    else:
      s = ""
  if len(s) > 0:
    if len(s) != 2 or s[1] notin ['m', 'M']:
      return none(Con4mTime)
    case s[0]
    of 'p', 'P':
      hr += 12
    of 'a', 'A':
      discard
    else:
      return none(Con4mTime)
  if hr > 23 or min > 59 or sec > 60:
    return none(Con4mTime)
  if hr < 10:
    s = "0" & $(hr) & ":"
  else:
    s = $(hr) & ":"
  if min < 10:
    s &= "0"
  s &= $(min) & ":"
  if sec < 10:
    s &= "0"
  s &= $(sec)
  if fracsec != "":
    s &= "." & fracsec
  if offset != "":
    s &= offset

  result = some(s)

proc otherLitToNativeDateTime*(lit: string): Option[Con4mDateTime] =
  var
    ix0 = lit.find('T')
    ix1 = lit.find('t')

  if ix0 == ix1:
    return none(Con4mDateTime)
  if ix0 >= 0 and ix1 >= 0:
    return none(Con4mDateTime)
  if ix1 > ix0:
    ix0 = ix1
  if ix0 == len(lit) - 1:
      return none(Con4mDateTime)
  let
    datePart = lit[0 ..< ix0]
    timePart = lit[ix0 + 1 .. ^1]
    dateRes  = datePart.otherLitToNativeDate()
    timeRes  = timePart.otherLitToNativeTime()

  if dateRes.isNone() or timeRes.isNone():
    return none(Con4mDateTime)

  return some(dateRes.get() & "T" & timeRes.get())

proc otherLitToValue*(lit: string): Option[(Box, Con4mType)] =
  var dt = lit.otherLitToNativeDateTime()
  if dt.isSome():
    return some((pack(dt.get()), dateTimeType))

  var date = lit.otherLitToNativeDate()
  if date.isSome():
    return some((pack(date.get()), dateType))

  var time = lit.otherLitToNativeTime()
  if time.isSome():
    return some((pack(time.get()), timeType))

  var duration = lit.otherLitToNativeDuration()
  if duration.isSome():
    return some((pack(int64(duration.get())), durationType))

  var size = lit.otherLitToNativeSize()
  if size.isSome():
    return some((pack(int64(size.get())), sizeType))

  var ip = lit.otherLitToIpAddr()
  if ip.isSome():
    return some((pack(ip.get()), ipAddrType))

  var cidr = lit.otherLitToCIDR()
  if cidr.isSome():
    return some((pack(cidr.get()), cidrType))

when isMainModule:
  import dollars

  echo otherLitToValue("2 k")
  echo otherLitToValue("15 Tb")
  echo otherLitToValue("1 Gb")
  echo nativeSizeToStrBase2(Con4mSize(16492674416640 + 1073741824 + 2048 + 10))
  echo otherLitToValue("10.228.143.7")
  echo otherLitToValue("::")
  echo otherLitToValue("2001:db8:3333:4444:5555:6666:7777:8888")
  echo otherLitToValue("2001:db8:1::ab9:C0A8:102")
  echo otherLitToValue("192.168.0.0/16")
  echo otherLitToValue("2001:db8:1::ab9:C0A8:102/127")
  echo otherLitToValue("1 hr 6 min 22s")
  echo otherLitToValue("10usec")
  echo otherLitToValue("4yrs 2 days 4 hours 6 min 7sec")
  echo nativeDurationToStr(Con4mDuration(126331567000010))
  echo otherLitToValue("Jan 7, 2007")
  echo otherLitToValue("Jan 18 2027")
  echo otherLitToValue("Jan 2027")
  echo otherLitToValue("Mar 0600")
  echo otherLitToValue("2 Mar 1401")
  echo otherLitToValue("2 Mar")
  echo otherLitToValue("2004-01-06")
  echo otherLitToValue("--03-02")
  echo otherLitToValue("--03")
  echo otherLitToValue("12:23:01.13131423424214214-12:00")
  echo otherLitToValue("12:23:01.13131423424214214Z")
  echo otherLitToValue("12:23:01+23:00")
  echo otherLitToValue("2:03:01+23:00")
  echo otherLitToValue("02:03+23:00")
  echo otherLitToValue("2:03+23:00")
  echo otherLitToValue("2:03")
  echo otherLitToValue("2004-01-06T12:23:01+23:00")
  echo otherLitToValue("--03T2:03")
  echo otherLitToValue("2 Jan, 2004 T 12:23:01+23:00")
  echo "The rest should all fail"
  echo otherLitToValue("2:3:01+23:00")
  echo otherLitToValue("10.228.143")
  echo otherLitToValue("10.283.143.7")   # Should fail
  echo otherLitToValue("2001:db8:3333:4444:5555:6666:7777:8888:9999") #fail
  echo otherLitToValue(":") # Should fail
  echo otherLitToValue("192.168.0.0/33")
  echo otherLitToValue("2001:db8:1::ab9:C0A8:102/129")
  echo otherLitToValue("4yrs 2 days 4 hours 6 min 7 sec2years")
  echo otherLitToValue("Mar 600")
