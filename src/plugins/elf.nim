##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##
import std/[
  algorithm,
]
import ".."/[
  types,
  utils/files,
]

# We've got a lot of ELF-specific defines we're not using but we
# want to keep around, so silence any warnings.
{.hint[XDeclaredButNotUsed]: off.}

const
  NOT8                       = uint64(0) - 9
  NULLBYTE                   = '\x00'
  ELF_CLASS_ELF64            = "\x02"
  ELF_MACHINE_AMD64          = "\x3E\x00"
  ELF_MAGIC_BYTES*           = "\x7F\x45\x4C\x46"
  ELF_LITTLE_ENDIAN          = "\x01"
  ELF_VERSION1               = "\x01\x00\x00\x00"
  ELF64_HEADER_SIZE          = 0x40
  ELF64_PROGRAM_HEADER_SIZE  = 0x38
  ELF64_SECTION_HEADER_SIZE  = 0x40

# The following declaration structure conforms to <prefix>_<name>_<bitwidth>,
# where prefix is `ELF` for fields which are universal regardless of ALU size,
# or `ELF<bits>` for ALU-size-specific offsets and sizes (i.e. 32bit vs 64bit)

# The universal ELF header fields: same offset and size regardless of arch/ALU
const
  ELF_MAGIC_32               = 0x00
  ELF_CLASS_8                = 0x04
  ELF_ENDIAN_8               = 0x05
  ELF_TYPE_16                = 0x10
  ELF_MACHINE_16             = 0x12
  ELF_VERSION_32             = 0x14

  # ELF header 64bit-only field offsets
  ELF64_ENTRY_64             = 0x18
  ELF64_PH_TABLE_64          = 0x20
  ELF64_SH_TABLE_64          = 0x28
  ELF64_PH_SIZE_16           = 0x36
  ELF64_PH_COUNT_16          = 0x38
  ELF64_SH_SIZE_16           = 0x3A
  ELF64_SH_COUNT_16          = 0x3C
  ELF64_SH_STRIDX_16         = 0x3E

  # Program header 64bit-only field offsets
  ELF64_PROGRAM_TYPE_32      = 0x00
  ELF64_PROGRAM_FLAGS_32     = 0x04
  ELF64_PROGRAM_OFFSET_64    = 0x08
  ELF64_PROGRAM_VIRTADDR_64  = 0x10
  ELF64_PROGRAM_FILESIZE_64  = 0x20
  ELF64_PROGRAM_MEMSIZE_64   = 0x28
  ELF64_PROGRAM_ALIGN_64     = 0x30

  # Section header
  ELF64_SECTION_NAME_32      = 0x00
  ELF64_SECTION_TYPE_32      = 0x04
  ELF64_SECTION_FLAGS_64     = 0x08
  ELF64_SECTION_ADDR_64      = 0x10
  ELF64_SECTION_OFFSET_64    = 0x18
  ELF64_SECTION_SIZE_64      = 0x20
  ELF64_SECTION_ALIGN_64     = 0x30
  ELF64_SECTION_ENTRYSIZE_64 = 0x38

  # Section header string table index special value
  SHN_UNDEF                  = 0x00
  SHN_LORESERVE              = 0xFF00

  # ELF header types
  ET_NONE                    = 0x00
  ET_REL                     = 0x01
  ET_EXEC                    = 0x02
  ET_DYN                     = 0x03
  ET_CORE                    = 0x04
  ET_LOOS                    = 0xFE00
  ET_HIOS                    = 0xFEFF
  ET_LOPROC                  = 0xFF00
  ET_HIPROC                  = 0xFFFF

  PT_NULL                    = 0x00
  PT_LOAD                    = 0x01
  PT_DYNAMIC                 = 0x02
  PT_INTERP                  = 0x03
  PT_NOTE                    = 0x04
  PT_SHLIB                   = 0x05
  PT_PHDR                    = 0x06
  PT_TLS                     = 0x07
  PT_LOOS                    = 0x60000000
  PT_HIOS                    = 0x6FFFFFFF
  PT_LOPROC                  = 0x70000000
  PT_HIPROC                  = 0x7FFFFFFF

  PN_XNUM                    = 0xFFFF

  SHT_NULL                   = 0x00
  SHT_PROGBITS               = 0x01
  SHT_SYMTAB                 = 0x02
  SHT_STRTAB                 = 0x03
  SHT_RELA                   = 0x04
  SHT_HASH                   = 0x05
  SHT_DYNAMIC                = 0x06
  SHT_NOTE                   = 0x07
  SHT_NOBITS                 = 0x08
  SHT_REL                    = 0x09
  SHT_SHLIB                  = 0x0A
  SHT_DYNSYM                 = 0x0B
  SHT_INIT_ARRAY             = 0x0E
  SHT_FINI_ARRAY             = 0x0F
  SHT_PREINIT_AT             = 0x10
  SHT_GROUP                  = 0x11
  SHT_SYMTABL_SHNDX          = 0x12
  SHT_NUM                    = 0x13
  SHT_LOOS                   = 0x60000000

  # errors
  ERR_ELF_PARSE_GENERAL      = "could not parse ELF"
  ERR_ELF_HEADER_READ        = "failed to read enough data for ELF header"
  ERR_BAD_ELF_MAGIC          = "incorrect ELF magic bytes"
  ERR_ONLY_VERSION1          = "only ELF version 1 is supported"
  ERR_ONLY_LITTLE_ENDIAN     = "only little-endian is supported"
  ERR_ONLY_CLASS_ELF64       = "only ELF 64-bit is supported"
  ERR_PROGRAM_OUT_OF_RANGE   = "program header table or entry beyond EOF"
  ERR_NO_SECTION_TABLE       = "no section table defined"
  ERR_SECTION_TABLE_ELF_HDR  = "table offset points inside ELF header"
  ERR_SECTION_OUT_OF_RANGE   = "section header table or entry beyond EOF"
  ERR_INVALID_FIELD          = "invalid size/count field"
  ERR_PROGRAM_HEADER_SIZE    = "program header too small"
  ERR_SECTION_HEADER_SIZE    = "section header too small"
  ERR_SHSTRTAB_UNIMPLEMENTED = "unimplemented: missing shstrtab"
  ERR_SHLINK_UNIMPLEMENTED   = "unimplemented: shstrtab uses sh_link"
  ERR_SHTABLE_NOT_LAST       = "unsupported: SH table not at end"
  ERR_SHSTRTAB_ADDRESS       = "unsupported: string section has address"
  ERR_INVALID_SHSTRTAB       = "string section type is invalid (NOBITS)"
  ERR_INVALID_STRTAB_INDEX   = "section name index beyond sizeof strtab"
  ERR_SETCHALK_MISSING_CHALK = "setChalkSection(): no chalk section present"
  ERR_SETCHALK_INVALID_NAME  = "setChalkSection(): invalid name length"
  ERR_SETCHALK_INTERSECT     = "setChalkSection(): unexpected ELF structure"
  ERR_SECTION_COUNT_LIMIT    = "unimplemented: section count hit SHN_LORESERVE"
  ERR_PN_XNUM                = "unimplemented: support for PN_XNUM"

  # Chalk strings for the section header names
  SH_NAME_CHALKMARK*         = ".chalk.mark"
  SH_NAME_CHALKFREE*         = ".chalk.free"
  SHA256_BYTE_LENGTH*        = 32

  # range names
  ELF_HEADER_NAME            = "ELF Header"
  PROGRAM_TABLE_NAME         = "Program Header Table"
  SECTION_TABLE_NAME         = "Section Header Table"

  # logging strings for errors and testing
  LOG_SECTION_TABLE_OFFSET   = "section table offset 0x"
  LOG_SECTION_TABLE_SIZE     = "section table size 0x"
  LOG_SECTION_HEADER         = "section header index 0x"
  LOG_SECTION_OFFSET         = "section offset 0x"
  LOG_SECTION_SIZE           = "section size 0x"
  LOG_SECTION_NAME           = "section name "
  LOG_PROGRAM_OFFSET         = "program offset 0x"
  LOG_PROGRAM_SIZE           = "program size 0x"
  LOG_PROGRAM_TYPE           = "program type 0x"
  LOG_FILE_SIZE              = "file size 0x"
  LOG_BEGIN_RANGE            = "BEGIN: "
  LOG_END_RANGE              = "END:   "

type
  fixedElfBytesCheck         = ref object of RootRef
    whence:                  int
    value:                   string
    error:                   string

  ElfIntValue*[T]            = ref object of RootRef
    whence*:                 uint64
    value*:                  T

  ElfHeader*                 = ref object of RootRef
    elfType*:                ElfIntValue[uint16]
    entrypoint*:             ElfIntValue[uint64]
    programTable*:           ElfIntValue[uint64]
    sectionTable*:           ElfIntValue[uint64]
    programHeaderSize*:      ElfIntValue[uint16]
    programCount*:           ElfIntValue[uint16]
    sectionHeaderSize*:      ElfIntValue[uint16]
    sectionCount*:           ElfIntValue[uint16]
    sectionStringIndex*:     ElfIntValue[uint16]

  ElfProgramHeader*          = ref object of RootRef
    headerType*:             ElfIntValue[uint32]
    flags*:                  ElfIntValue[uint32]
    offset*:                 ElfIntValue[uint64]
    virtualAddress*:         ElfIntValue[uint64]
    sizeInFile*:             ElfIntValue[uint64]
    sizeInMemory*:           ElfIntValue[uint64]
    align*:                  ElfIntValue[uint64]

  ElfSectionHeader*          = ref object of RootRef
    name*:                   string
    nameIndex*:              ElfIntValue[uint32]
    headerType*:             ElfIntValue[uint32]
    flags*:                  ElfIntValue[uint64]
    virtualAddress*:         ElfIntValue[uint64]
    offset*:                 ElfIntValue[uint64]
    size*:                   ElfIntValue[uint64]
    align*:                  ElfIntValue[uint64]
    entrySize*:              ElfIntValue[uint64]

  IntervalTable              = TableRef[uint64, ref seq[RootRef]]
  Intersector                = ref object of RootRef
    starts:                  IntervalTable
    stops:                   IntervalTable
    keys:                    ref seq[uint64]
    sorted:                  bool

  ElfElement                 = ref object of RootRef
    name:                    string

  ElfFile*                   = ref object of RootRef
    fileData*:               FileStringStream
    header*:                 ElfHeader
    programHeaders*:         seq[ElfProgramHeader]
    sectionHeaders*:         seq[ElfSectionHeader]
    errors*:                 seq[string]
    entryProgramHeader*:     ElfProgramHeader
    chalkSectionHeader*:     ElfSectionHeader
    nameSectionHeader*:      ElfSectionHeader
    hasBeenUnchalked*:       bool
    ranges*:                 Intersector

proc pad8(offset: uint64): uint64 =
  # out of caution we align everything we write to a 64bit boundary
  # pad8() returns to us how many bytes to pad for 64bit alignment
  return uint64((8 - (offset and 7)) and NOT8)

proc getInt[T](data: FileStringStream, whence: int = 0): T =
  result = readInt[T](data, whence)

proc setInt[T](data: var (string | FileStringStream), whence: uint64, value: T) =
  for byteIndex in 0 ..< sizeof(T):
    var newValue = (uint(value) shr uint(byteIndex * 8)) and uint(0xFF)
    data[int(whence) + byteIndex] = char(newValue)

proc showItem*(item: RootRef, prefix: string="") =
  if item of ElfSectionHeader:
    var sectionHeader = ElfSectionHeader(item)
    echo prefix &
      LOG_SECTION_OFFSET & sectionHeader.offset.value.toHex() &
      LOG_SECTION_SIZE   & sectionHeader.size.value.toHex()   &
      LOG_SECTION_NAME   & sectionHeader.name
  elif item of ElfProgramHeader:
    var programHeader = ElfProgramHeader(item)
    echo prefix &
      LOG_PROGRAM_OFFSET & programHeader.offset.value.toHex()     &
      LOG_PROGRAM_SIZE   & programHeader.sizeInFile.value.toHex() &
      LOG_PROGRAM_TYPE   & programHeader.headerType.value.toHex()
  elif item of ElfElement:
    var element = ElfElement(item)
    echo prefix & element.name

proc insert(self: IntervalTable, whence: uint64, item: RootRef): bool =
  var intervals: ref seq[RootRef]
  result = self.hasKey(whence)
  if result:
    intervals = self[whence]
  else:
    intervals    = new seq[RootRef]
    self[whence] = intervals
  intervals[].add(item)
  return result

proc NewIntersector*(): Intersector =
  return Intersector(starts: newTable[uint64, ref seq[RootRef]](),
                     stops:  newTable[uint64, ref seq[RootRef]](),
                     keys:   new seq[uint64],
                     sorted: true)

proc insert*(self: Intersector, whence: uint64, size: uint64, item: RootRef) =
  var starts = self.starts
  var stops  = self.stops
  var keys   = self.keys
  var key    = whence
  if not starts.insert(key, item) and not stops.hasKey(key):
    keys[].add(key)
  key += size
  if not stops.insert(key, item) and not starts.hasKey(key):
    keys[].add(key)
  self.sorted = false

proc insertString*(self: Intersector, whence: uint64, size: uint64, s: string) =
  let name = s & " 0x" & whence.toHex() & " 0x" & size.toHex()
  self.insert(whence, size, ElfElement(name:name))

proc sort*(self: Intersector) =
  if not self.sorted:
    sort[uint64](self.keys[])
    self.sorted = true

proc highest*(self: Intersector): uint64 =
  if len(self.keys[]) == 0:
    return 0
  self.sort()
  return self.keys[][^1]

# NOTE on room for improvement: intersection is really only used as a count
# right now, it might make sense to add a function which returns a count
# instead of an array

proc intersect*(self: Intersector, whence: uint64, size: uint64): seq[RootRef] =
  var starts     = self.starts
  var stops      = self.stops
  var beginIndex = whence
  var endIndex   = beginIndex + size
  var state:       seq[RootRef]
  self.sort()
  for key in self.keys[]:
    if key >= endIndex:
      break
    if key <= beginIndex and stops.hasKey(key):
      for removal in stops[key][]:
        for index in low(state) .. high(state):
          if state[index] == removal:
            state.delete(index)
            break
    if starts.hasKey(key):
      for addition in starts[key][]:
        state.add(addition)
  return state

proc show*(self: Intersector) =
  var starts     = self.starts
  var stops      = self.stops
  var depth      = 0
  self.sort()
  for key in self.keys[]:
    if stops.hasKey(key):
      var endPoints = stops[key][]
      for index in countdown(high(endPoints), 0):
        var elfObject = endPoints[index]
        showItem(elfObject, LOG_END_RANGE & align("", depth, '-'))
        depth -= 2
    if starts.hasKey(key):
      for elfObject in starts[key][]:
        depth += 2
        showItem(elfObject, LOG_BEGIN_RANGE & align("", depth, '-'))

proc addElfIntValue[T](self:       ElfFile,
                       elfValue:   var ElfIntValue[T],
                       addend:     T) =
  elfValue.value += addend
  setInt[T](self.fileData, elfValue.whence, elfValue.value)

proc setElfIntValue[T](self:       ElfFile,
                       elfValue:   var ElfIntValue[T],
                       newValue:   T) =
  elfValue.value = newValue
  setInt[T](self.fileData, elfValue.whence, newValue)

proc getValue[T](data: FileStringStream, whence: uint64): ElfIntValue[T] =
  return ElfIntValue[T](whence: whence, value: getInt[T](data, int(whence)))

proc locateChalkSection(self: ElfFile) =
  for header in self.sectionHeaders:
    if header.headerType.value != uint32(SHT_PROGBITS):
      continue
    case header.name
    of SH_NAME_CHALKMARK:
      self.chalkSectionHeader = header
      break
    of SH_NAME_CHALKFREE:
      self.chalkSectionHeader = header
      self.hasBeenUnchalked   = true
      break
    else:
      discard

proc parseHeader*(self: ElfFile): bool =
  let
    # skipping many fields for now, but these are necessary
    checks = @[fixedElfBytesCheck(whence: ELF_MAGIC_32,
                                  value:  ELF_MAGIC_BYTES,
                                  error:  ERR_BAD_ELF_MAGIC),
               fixedElfBytesCheck(whence: ELF_CLASS_8,
                                  value:  ELF_CLASS_ELF64,
                                  error:  ERR_ONLY_CLASS_ELF64),
               fixedElfBytesCheck(whence: ELF_ENDIAN_8,
                                  value:  ELF_LITTLE_ENDIAN,
                                  error:  ERR_ONLY_LITTLE_ENDIAN),
               fixedElfBytesCheck(whence: ELF_VERSION_32,
                                  value:  ELF_VERSION1,
                                  error:  ERR_ONLY_VERSION1)]
  var data = self.fileData
  # note on the below: ELF64_HEADER_SIZE is a weird one, because there is also
  # a field in the header to specify ELF64_HEADER_SIZE, I guess because it can
  # be larger than the 64 bytes? Although 32bit and 64bit ELF headers differ in
  # size, the only datapoint which should be required to distinguish them is the
  # value at ELF_CLASS_OFFSET. Anyway here we use the fixed size 64 to ensure
  # at least that much data is present
  if len(data) <= ELF64_HEADER_SIZE:
    self.errors.add(ERR_ELF_HEADER_READ)
    return false
  for index in low(checks) .. high(checks):
    var check = checks[index]
    if data[check.whence ..< check.whence+len(check.value)] != check.value:
      self.errors.add(check.error)
  if len(self.errors) > 0:
    return false
  self.header           = ElfHeader(
    elfType:            getValue[uint16](data, ELF_TYPE_16),
    entrypoint:         getValue[uint64](data, ELF64_ENTRY_64),
    programTable:       getValue[uint64](data, ELF64_PH_TABLE_64),
    sectionTable:       getValue[uint64](data, ELF64_SH_TABLE_64),
    programHeaderSize:  getValue[uint16](data, ELF64_PH_SIZE_16),
    programCount:       getValue[uint16](data, ELF64_PH_COUNT_16),
    sectionHeaderSize:  getValue[uint16](data, ELF64_SH_SIZE_16),
    sectionCount:       getValue[uint16](data, ELF64_SH_COUNT_16),
    sectionStringIndex: getValue[uint16](data, ELF64_SH_STRIDX_16),
  )
  # ELF is not either executable or a shared object (lib)
  if int(self.header.elfType.value) notin [ET_REL, ET_EXEC, ET_DYN]:
    return false
  self.ranges.insertString(0, ELF64_HEADER_SIZE, ELF_HEADER_NAME)
  let shStrTabIndex = self.header.sectionStringIndex.value
  if shStrTabIndex == 0:
    self.errors.add(ERR_SHSTRTAB_UNIMPLEMENTED)
    return false
  if shStrTabIndex >= SHN_LORESERVE:
    self.errors.add(ERR_SHLINK_UNIMPLEMENTED)
    return false
  if shStrTabIndex >= self.header.sectionCount.value:
    self.errors.add(ERR_SECTION_OUT_OF_RANGE)
    return false
  return true

proc parseProgramTable(self: ElfFile): bool =
  var data        = self.fileData
  var dataLen     = uint64(len(data))
  var elfHeader   = self.header
  var tableOffset = elfHeader.programTable.value
  if tableOffset < ELF64_HEADER_SIZE:
    trace("elf: missing program table. skipping")
    return false
  if tableOffset > dataLen:
    # we could add range intersection checks here but for now
    # just doing a basic bounds check
    self.errors.add(ERR_PROGRAM_OUT_OF_RANGE)
    return false
  let programHeaderSize = elfHeader.programHeaderSize.value
  if programHeaderSize != ELF64_PROGRAM_HEADER_SIZE:
    self.errors.add(ERR_PROGRAM_HEADER_SIZE)
    return false

  # If ELF header e_phnum is is PN_XNUM, it means the actual count of entries
  # in the PHTAB is stored in the sh_info member of the initial entry in the
  # section header table. This is rare, and so unsupported for now.
  if elfHeader.programCount.value == PN_XNUM:
    self.errors.add(ERR_PN_XNUM)
    return false

  let programTableSize = programHeaderSize * elfHeader.programCount.value
  if programTableSize < programHeaderSize: # catches int wrap and programCount=0
    self.errors.add(ERR_INVALID_FIELD)
    return false
  if uint64(programTableSize) > dataLen:
    self.errors.add(ERR_PROGRAM_OUT_OF_RANGE)
    return false
  let ranges = self.ranges
  ranges.insertString(tableOffset, programTableSize, PROGRAM_TABLE_NAME)
  var offset = tableOffset
  while offset < tableOffset + uint64(programTableSize):
    var programHeader = ElfProgramHeader(
      offset:         getValue[uint64](data, offset+ELF64_PROGRAM_OFFSET_64),
      headerType:     getValue[uint32](data, offset+ELF64_PROGRAM_TYPE_32),
      flags:          getValue[uint32](data, offset+ELF64_PROGRAM_FLAGS_32),
      virtualAddress: getValue[uint64](data, offset+ELF64_PROGRAM_VIRTADDR_64),
      sizeInFile:     getValue[uint64](data, offset+ELF64_PROGRAM_FILESIZE_64),
      sizeInMemory:   getValue[uint64](data, offset+ELF64_PROGRAM_MEMSIZE_64),
      align:          getValue[uint64](data, offset+ELF64_PROGRAM_ALIGN_64))
    var programOffset = programHeader.offset.value
    var programSize   = programHeader.sizeInFile.value
    if programOffset > dataLen:
      self.errors.add(ERR_PROGRAM_OUT_OF_RANGE)
      return false
    if programSize > dataLen or programOffset + programSize > dataLen:
      self.errors.add(ERR_PROGRAM_OUT_OF_RANGE)
      return false
    if programSize > 0:
      ranges.insert(programOffset, programSize, programHeader)
    self.programHeaders.add(programHeader)
    offset += uint64(programHeaderSize)
  return true

proc parseSectionHeader(self: ElfFile, offset: uint64): ElfSectionHeader =
    var data = self.fileData
    return ElfSectionHeader(
      offset:         getValue[uint64](data, offset+ELF64_SECTION_OFFSET_64),
      headerType:     getValue[uint32](data, offset+ELF64_SECTION_TYPE_32),
      nameIndex:      getValue[uint32](data, offset+ELF64_SECTION_NAME_32),
      flags:          getValue[uint64](data, offset+ELF64_SECTION_FLAGS_64),
      virtualAddress: getValue[uint64](data, offset+ELF64_SECTION_ADDR_64),
      size:           getValue[uint64](data, offset+ELF64_SECTION_SIZE_64),
      entrySize:      getValue[uint64](data, offset+ELF64_SECTION_ENTRYSIZE_64),
      align:          getValue[uint64](data, offset+ELF64_SECTION_ALIGN_64))

proc logInvalidSection(self: ElfFile, header: ElfSectionHeader, index: int) =
  self.errors.add(LOG_SECTION_HEADER & index.toHex())
  self.errors.add(LOG_SECTION_OFFSET & header.offset.value.toHex())
  self.errors.add(LOG_SECTION_SIZE   & header.size.value.toHex())
  self.errors.add(LOG_FILE_SIZE      & len(self.fileData).toHex())

proc parseSectionTable(self: ElfFile): bool =
  var data        = self.fileData
  var dataLen     = uint64(len(data))
  var elfHeader   = self.header
  var tableOffset = elfHeader.sectionTable.value
  if tableOffset > dataLen or tableOffset < ELF64_HEADER_SIZE:
    self.errors.add(ERR_SECTION_OUT_OF_RANGE)
    self.errors.add(LOG_SECTION_TABLE_OFFSET & tableOffset.toHex())
    if tableOffset > dataLen:
      self.errors.add(LOG_FILE_SIZE & dataLen.toHex())
    elif tableOffset == 0:
      #FIXME: file this as a known bug, and write an issue for
      # supporting this. It is possible to produce an ELF without
      # defining a section table, and in that case we could simply
      # add a section table, strtab, and chalk section
      self.errors.add(ERR_NO_SECTION_TABLE)
    else:
      self.errors.add(ERR_SECTION_TABLE_ELF_HDR)
    return false
  let sectionHeaderSize = elfHeader.sectionHeaderSize.value
  if sectionHeaderSize != ELF64_SECTION_HEADER_SIZE:
    self.errors.add(ERR_SECTION_HEADER_SIZE)
    return false
  let sectionTableSize = sectionHeaderSize * elfHeader.sectionCount.value
  if sectionTableSize < sectionHeaderSize: # catches int wrap and sectionCount=0
    self.errors.add(ERR_INVALID_FIELD)
    self.errors.add(LOG_SECTION_TABLE_SIZE & sectionTableSize.toHex())
    return false
  if uint64(sectionTableSize) > dataLen:
    self.errors.add(ERR_SECTION_OUT_OF_RANGE)
    self.errors.add(LOG_SECTION_TABLE_SIZE & sectionTableSize.toHex())
    self.errors.add(LOG_FILE_SIZE          & dataLen.toHex())
    return false
  let ranges = self.ranges
  ranges.insertString(tableOffset, sectionTableSize, SECTION_TABLE_NAME)
  var offset = tableOffset
  var sectionHeaders = self.sectionHeaders
  while offset < tableOffset + uint64(sectionTableSize):
    var sectionHeader = self.parseSectionHeader(offset)
    var sectionOffset = sectionHeader.offset.value
    var sectionSize   = sectionHeader.size.value
    if sectionOffset > dataLen:
      self.errors.add(ERR_SECTION_OUT_OF_RANGE)
      self.logInvalidSection(sectionHeader, len(sectionHeaders))
      return false
    if sectionHeader.headerType.value != uint32(SHT_NOBITS):
      if sectionSize > dataLen:
        self.errors.add(ERR_SECTION_OUT_OF_RANGE)
        self.logInvalidSection(sectionHeader, len(sectionHeaders))
        return false
        # Not checking for int wrap here since it would mean len(data)>=2**63
        # in process memory. That being said, this does check that offset+size
        # is not more than the available data
      if sectionOffset + sectionSize > dataLen:
        self.errors.add(ERR_SECTION_OUT_OF_RANGE)
        self.logInvalidSection(sectionHeader, len(sectionHeaders))
        return false
      if sectionSize > 0:
        ranges.insert(sectionOffset, sectionSize, sectionHeader)
    sectionHeaders.add(sectionHeader)
    offset += uint64(sectionHeaderSize)
  self.sectionHeaders   = sectionHeaders
  var nameSectionHeader = sectionHeaders[self.header.sectionStringIndex.value]
  if nameSectionHeader.headerType.value == uint32(SHT_NOBITS):
    self.errors.add(ERR_INVALID_SHSTRTAB)
    return false
  var startIndex        = int(nameSectionHeader.offset.value)
  var endIndex          = startIndex + int(nameSectionHeader.size.value)
  var nameSection       = self.fileData[startIndex .. endIndex]
  var maxNameIndex      = uint32(len(nameSection) - 1)
  # validation, and storing names
  for sectionIndex in 0 ..< len(sectionHeaders):
    var sectionHeader = sectionHeaders[sectionIndex]
    var nameIndex     = sectionHeader.nameIndex.value
    if nameIndex > maxNameIndex:
      self.errors.add(ERR_SECTION_OUT_OF_RANGE)
      self.errors.add(ERR_INVALID_STRTAB_INDEX)
      return false
    sectionHeader.name = $(cstring(nameSection[int(nameIndex) .. ^1]))
  self.nameSectionHeader = nameSectionHeader
  return true

proc showErrors(self: ElfFile) =
  for e in self.errors:
    error("elf @ " & self.fileData.path & ": " & e)

proc parse*(self: ElfFile): bool =
  ## parse the ELF and return true if everything went OK,
  ## where failure is indicative of a malformed ELF, or maybe
  ## a nuance of ELF that was unknown at time of writng :)
  self.ranges         = NewIntersector()
  self.programHeaders = @[]
  self.sectionHeaders = @[]
  result = self.parseHeader() and
     self.parseProgramTable() and
     self.parseSectionTable()
  if result:
    self.locateChalkSection()
  else:
    self.showErrors()

proc setChalkSection*(self: ElfFile, name, data: string): bool =
  # NOTE!
  # this function should only be called from a parsed state, where there is
  # a properly formed and named chalk section, and no insertions or
  # modifications have been made (as of time of writing this, the range
  # tracking isn't updated by modifications), and the order of the end of the
  # file is: chalk section + strtab section + sh table
  let chalkHeader = self.chalkSectionHeader
  if chalkHeader == nil:
    self.errors.add(ERR_SETCHALK_MISSING_CHALK)
    return false

  # for now just support the case of uniform length chalk section names,
  # this can be updated in the future for others but it's not needed now
  # see `IMPORTANT` comment referring to this check further down in this
  # function
  if len(chalkHeader.name) != len(name):
    self.errors.add(ERR_SETCHALK_INVALID_NAME)
    return false

  let eof                    = uint64(len(self.fileData))
  let chalkSectionOffset     = chalkHeader.offset.value
  var sectionTableOffset     = self.header.sectionTable.value
  var stringTableOffset      = self.nameSectionHeader.offset.value
  let stringTableSize        = self.nameSectionHeader.size.value
  let sectionTableIntersects = self.ranges.intersect(sectionTableOffset,
                                                     eof - sectionTableOffset)
  let stringTableIntersects  = self.ranges.intersect(stringTableOffset,
                                                     eof - stringTableOffset)
  let chalkSectionIntersects = self.ranges.intersect(chalkSectionOffset,
                                                     eof - chalkSectionOffset)

  if len(sectionTableIntersects) != 1 or
     len(stringTableIntersects)  != 2 or
     len(chalkSectionIntersects) != 3:
    # this case shouldn't happen, it indicates a modification of a chalked
    # ELF by something which has reordered sections or segments. While `strip`
    # does do some reordering, the reordering is in accordance with how chalk
    # marks are inserted--tl;dr this should be a rare (or never) case, and if
    # we find we need to support it we can revisit this
    self.errors.add(ERR_SETCHALK_INTERSECT)
    return false

  # update the chalk header
  var dataLen = uint64(len(data))
  self.setElfIntValue(chalkHeader.size, dataLen)

  # record the string table data at existing offset
  var stringTableData = self.fileData[stringTableOffset ..<
                                      stringTableOffset + stringTableSize]

  # go ahead and change the chalk section name
  # IMPORTANT this relies on a check earlier in the function which compared
  # the new name to existing name
  var nameOffset = chalkHeader.nameIndex.value
  stringTableData     = stringTableData[0 ..< nameOffset] &
                        name                              &
                        stringTableData[nameOffset + uint64(len(name)) .. ^1]

  # calculate new string table offset
  stringTableOffset   = chalkSectionOffset + dataLen
  var alignmentNeeded = pad8(stringTableOffset)
  stringTableOffset  += alignmentNeeded
  stringTableData     = align(stringTableData,
                              stringTableSize + alignmentNeeded,
                              NULLBYTE)

  # set the string table's new offset into its header in section table
  self.setElfIntValue(self.nameSectionHeader.offset, stringTableOffset)

  # collect the section table data now because we'll move it around
  var sectionTableData = self.fileData[sectionTableOffset .. ^1]

  # calculate new section table offset
  sectionTableOffset = stringTableOffset + stringTableSize
  alignmentNeeded    = pad8(sectionTableOffset)
  sectionTableData   = align(sectionTableData,
                             uint64(len(sectionTableData)) + alignmentNeeded,
                             NULLBYTE)
  sectionTableOffset += alignmentNeeded
  self.setElfIntValue(self.header.sectionTable, sectionTableOffset)
  self.fileData[chalkSectionOffset] = (
    data &
    stringTableData &
    sectionTableData
  )
  return self.parse()

proc insertChalkSection*(self: ElfFile, name: string, data: string): bool =
  let elfHeader          = self.header
  let eof                = uint64(len(self.fileData))
  let dataLen            = uint64(len(data))
  let sectionCount       = elfHeader.sectionCount.value
  var sectionTableOffset = elfHeader.sectionTable.value
  let sectionTableSize   = uint64(ELF64_SECTION_HEADER_SIZE * sectionCount)
  let stringHeader       = self.nameSectionHeader
  var stringTableOffset  = stringHeader.offset.value
  var stringTableSize    = stringHeader.size.value
  var nameData           = name & NULLBYTE
  var nameLen            = uint64(len(nameData))
  let ranges             = self.ranges

  if stringHeader.virtualAddress.value != 0:
    # for now we don't support this: it's in a segment and we don't know
    # what the program requirements are for "knowing" about it
    self.errors.add(ERR_SHSTRTAB_ADDRESS)
    return false

  # We shouldn't increment the section count if it's >= SHN_LORESERVE-1,
  # because once the section count hits SHN_LORESERVE, the section count
  # is supposed to be moved to the sh_size member of the initial entry of
  # the section table, and the ELF Header e_shnum is supposed to become 0.
  # We could add support for this but it's an uncommon scenario, so support
  # can be added if we begin encountering it
  if sectionCount >= SHN_LORESERVE - 1:
    self.errors.add(ERR_SECTION_COUNT_LIMIT)
    return false

  let sectionTableIntersections = ranges.intersect(sectionTableOffset,
                                                   eof - sectionTableOffset)

  let stringTableIntersections  = ranges.intersect(stringTableOffset,
                                                   eof - stringTableOffset)

  # The default assumption is we can only place the new or extended contents
  # (chalk section, updated string section, updated section table) at EOF
  var truncateOffset = eof

  # But we might be able to slice off the data we're replacing if it's at
  # the end and doesn't intersect.

  # If the sectiontable is last and nothing else intersects it:
  if len(sectionTableIntersections) == 1:
    # if stringtable is before the sectiontable and nothing intersects it:
    if len(stringTableIntersections) == 2:
      truncateOffset = stringTableOffset
    else:
      truncateOffset = sectionTableOffset
  elif len(stringTableIntersections) == 1:
    truncateOffset   = stringTableOffset
  # else truncateOffset is eof

  # Now begin calculating the changes.
  # Setup the first (in order of lowest-to-highest) data: the chalk section
  var alignmentNeeded    = pad8(truncateOffset)
  var chalkSectionData   = align(data, dataLen + alignmentNeeded, NULLBYTE)
  let chalkSectionOffset = truncateOffset + alignmentNeeded

  # next setup the string table string table
  # first store the original string data
  var stringTableData    = self.fileData[stringTableOffset ..<
                                         stringTableOffset + stringTableSize]

  # save the old string table offset, which we'll need to use a few lines down,
  # the explanation for which is given when we use it
  let originalStringTableOffset = stringTableOffset

  # now calculate the new offset for the string data to be after chalk section
  stringTableOffset    = chalkSectionOffset + dataLen
  # align the string section offset and stored data
  alignmentNeeded      = pad8(stringTableOffset)
  stringTableOffset   += alignmentNeeded
  stringTableData      = align(stringTableData,
                               stringTableSize + alignmentNeeded,
                               NULLBYTE)
  # our name string will be appended to the current string section data,
  # so record our name index as the size of the string section
  let nameIndex        = stringTableSize
  # add our string
  stringTableData     &= nameData
  # increment the string section size
  stringTableSize     += nameLen
  # save this data in the string header: we haven't copied any of the
  # section table data out of the filedata buffer yet, which is important
  # because updating it now means it will be reflected when we do copy it
  self.setElfIntValue(stringHeader.offset, stringTableOffset)
  self.setElfIntValue(stringHeader.size,   stringTableSize)

  # Now that we have made any changes to existing headers in the section table,
  # we make a copy of the data and calculate the new offset + padding
  var sectionTableData = self.fileData[sectionTableOffset ..<
                                       sectionTableOffset + sectionTableSize]

  # Before we calculate the new offset and padding, write back the original
  # string table offset to its original location: this is to leave the original
  # contents intact for the case that the string table was earlier in the file
  # (vs being the last section, which is most common but not always). The reason
  # is to avoid disrupting potentially jettisoned data which remains and impacts
  # the prechalked hash
  self.setElfIntValue(stringHeader.offset, originalStringTableOffset)

  sectionTableOffset   = stringTableOffset + stringTableSize
  alignmentNeeded      = pad8(sectionTableOffset)
  sectionTableOffset  += alignmentNeeded
  sectionTableData     = align(sectionTableData,
                               sectionTableSize + alignmentNeeded,
                               NULLBYTE)

  # Now it's time to fix up the ELF header itself
  # Update where the section table is
  self.setElfIntValue(elfHeader.sectionTable, sectionTableOffset)
  # Update the count of sections
  self.addElfIntValue(elfHeader.sectionCount, 1)
  # Determine if we are inserting the chalk section header before the string
  # section header, in which case we will need to increment the string section
  # index
  var insertChalkSectionHeaderBeforeStringTable = false
  if elfHeader.sectionStringIndex.value + 1 == sectionCount:
    # the shstrtab is the last header, so we will insert right before it
    # note that the shstrtab header might not be the last of the headers
    # even though we ensure that the shstrtab itself is the last section
    self.addElfIntValue(elfHeader.sectionStringIndex, 1)
    insertChalkSectionHeaderBeforeStringTable = true

  var sectionHeader = newString(ELF64_SECTION_HEADER_SIZE)
  setInt(sectionHeader, ELF64_SECTION_OFFSET_64, chalkSectionOffset)
  setInt(sectionHeader, ELF64_SECTION_NAME_32,   uint32(nameIndex))
  setInt(sectionHeader, ELF64_SECTION_TYPE_32,   uint32(SHT_PROGBITS))
  setInt(sectionHeader, ELF64_SECTION_SIZE_64,   dataLen)
  if insertChalkSectionHeaderBeforeStringTable:
    sectionTableData = sectionTableData[0 ..< ^ELF64_SECTION_HEADER_SIZE] &
                       sectionHeader                                      &
                       sectionTableData[^ELF64_SECTION_HEADER_SIZE .. ^1]
  else:
    sectionTableData &= sectionHeader

  self.fileData[truncateOffset] = (
    chalkSectionData &
    stringTableData &
    sectionTableData
  )
  return self.parse()

proc insertOrSetChalkSection*(self: ElfFile, name: string, data: string): bool =
  if self.chalkSectionHeader == nil:
    result = self.insertChalkSection(name, data)
  else:
    result = self.setChalkSection(name, data)
  if not result:
    self.showErrors()

proc unchalk*(self: ElfFile): bool =
  if not self.insertOrSetChalkSection(SH_NAME_CHALKFREE, newString(SHA256_BYTE_LENGTH)):
    return false
  let
    chalkOffset = self.chalkSectionHeader.offset.value
    suffix      = self.fileData[chalkOffset + SHA256_BYTE_LENGTH .. ^1]
  var hash = initSha256()
  for c in self.fileData.chunks(0 ..< chalkOffset, 4096):
    hash.update(@c)
  hash.update(@suffix)
  let sha256 = hash.final()
  self.fileData[chalkOffset] = sha256 & suffix
  return true

proc getChalkSectionData*(self: ElfFile): (string, int, int) =
  let chalkHeader = self.chalkSectionHeader
  if chalkHeader == nil:
    return ("", 0, 0)
  let
    start = chalkHeader.offset.value
    done  = start + chalkHeader.size.value - 1
    data  = self.fileData[start .. done]
  return (data, int(start), int(done))

proc copy*(self: ElfFile): ElfFile =
  return ElfFile(
    fileData: self.fileData.reset(),
  )

proc getUnchalkedHash*(self: ElfFile): string =
  let copy = self.copy()
  if copy.parse() and copy.unchalk():
    let (data, _, _) = copy.getChalkSectionData()
    return data.hex()
  # there was an error parsing or unchalking elf
  # so we compute hash of the raw file
  let fileData = self.fileData.reset()
  var hash = initSha256()
  for c in fileData.chunks(0 .. ^1, 4096):
    hash.update(@c)
  return hash.finalHex()

proc newElfFileFromData*(fileData: FileStringStream): ElfFile =
  return ElfFile(
    fileData: fileData,
  )
