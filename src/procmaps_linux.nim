import strutils
import sugar

#FIXME: this needs OS checks to know when it's not on Linux

const
  # these mirror the values in sys/mman.h
  PROT_READ         = 0x1
  PROT_WRITE        = 0x2
  PROT_EXEC         = 0x4
  MAP_SHARED        = 0x1
  MAP_PRIVATE       = 0x2
  # the followinng are fields from proc
  ADDRESS_INDEX     = 0x0
  PERMS_FLAGS_INDEX = 0x1
  OFFSET_INDEX      = 0x2
  DEV_INDEX         = 0x3
  INODE_INDEX       = 0x4
  PATHNAME_INDEX    = 0x5
let
  permStrings       = ["-", "r", "w", "", "x"]
  flagStrings       = ["s", "p"]
type 
  procMapping*     = ref object of RootRef
    addressLow*:   uint64
    addressHigh*:  uint64
    permissions*:  int
    offset*:       uint64
    flags*:        int
    deviceMajor*:  int
    deviceMinor*:  int
    inode*:        int # this is presented in decimal
    pathname*:     string
  procReader*      = ref object of RootRef
    maps*:         seq[procMapping]

proc permsAndFlagStr(self: procMapping): string =
  let permissions = self.permissions
  result = permStrings[PROT_READ  and permissions] &
           permStrings[PROT_WRITE and permissions] &
           permStrings[PROT_EXEC  and permissions] &
           flagStrings[self.flags - 1]

proc `$`*(self: procMapping): string =
  result  = self.addressLow.toHex()   & "-" & self.addressHigh.toHex() & " " &
            self.permsAndFlagStr()    & " " & self.offset.toHex()      & " " &
            self.pathname

proc parseMapLine*(data: string): procMapping =
  var elements       = data.splitWhitespace()
  var addresses      = elements[ADDRESS_INDEX].split('-')
  var addressLow     = uint64(parseHexInt(addresses[0]))
  var addressHigh    = uint64(parseHexInt(addresses[1]))
  var permsAndFlags  = elements[PERMS_FLAGS_INDEX]
  var permissions:   int
  var flags:         int
  let translatePerms = @[PROT_READ, PROT_WRITE, PROT_EXEC]
  for index, bits in translatePerms:
    if permsAndFlags[index] != '-':
      permissions = permissions or bits
  if permsAndFlags[3] == 'p':
    flags = MAP_PRIVATE
  else:
    flags = MAP_SHARED
  var device = elements[DEV_INDEX].split(':')
  var pathname: string
  if len(elements) > PATHNAME_INDEX:
    pathname = elements[PATHNAME_INDEX]
  return procMapping(addressLow:  addressLow,
                     addressHigh: addressHigh,
                     permissions: permissions,
                     flags:       flags,
                     offset:      uint64(parseHexInt(elements[OFFSET_INDEX])),
                     deviceMajor: parseHexInt(device[0]), # hex
                     deviceMinor: parseHexInt(device[1]), # hex
                     inode:       parseInt(elements[INODE_INDEX]), # decimal
                     pathname:    pathname)

proc parseMaps*(self: procReader, path: string="/proc/self/maps"): bool =
  try:
    self.maps = collect:
      for line in open(path).readAll().splitLines():
        if len(line) > 0: parseMapLine(line)
  except:
    return false
  return true

proc showMaps*(self: procReader) =
  for mapping in self.maps:
    echo $mapping

when isMainModule:
  var reader = procReader()
  if not reader.parseMaps():
    echo "failed to parse"
    quit(1)
  reader.showMaps()
