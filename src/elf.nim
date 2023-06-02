import os
import std/math
import std/strutils

const
# note on the below: ELF64_HEADER_SIZE is a weird one, because there is also
# a field in the header to specify ELF64_HEADER_SIZE, I guess because it can
# be larger than the 64 bytes? Although 32bit and 64bit ELF headers differ in
# size, the only datapoint which should be required to distinguish them is the
# value at ELF_CLASS_OFFSET. Anyway here we use the fixed size 64 to ensure
# at least that much data is present
  ELF_CLASS_ELF64            = "\x02"
  ELF_MACHINE_AMD64          = "\x3E\x00"
  ELF_MAGIC_BYTES            = "\x7F\x45\x4C\x46"
  ELF_LITTLE_ENDIAN          = "\x01"
  ELF_VERSION1               = "\x01\x00\x00\x00"
  ELF_PROGRAM_FLAG_EXEC      = 0x01
  ELF_PROGRAM_FLAG_WRITE     = 0x02
  ELF_PROGRAM_FLAG_READ      = 0x04
  ELF64_HEADER_SIZE          = 0x40
  ELF64_PROGRAM_HEADER_SIZE  = 0x38
  ELF64_SECTION_HEADER_SIZE  = 0x40
  X86_64_ENDBR64             = "\xF3\x0F\x1E\xFA" # standard x86_64 intercal op
  X86_64_JMP_IMM32           = "\xE9"
                               # push operations:
                               # regs are 0x50-0x57 for general (rax, rcx, etc.)
                               # and 0x41,0x50-0x41,0x57 for r8 through r15
  X86_64_PUSH_GENERAL        = "\x50\x51\x52\x53\x54\x55\x56\x57" &
                               "\x41\x50\x41\x51\x41\x52\x41\x53" &
                               "\x41\x54\x41\x55\x41\x56\x41\x57"
                               # pop regs are 0x58-0x5F for rax and friends
                               # and 0x41,0x58-0x41,0x5F for r8 through r15
                               # so we do them in reverse
  X86_64_POP_GENERAL         = "\x41\x5F\x41\x5E\x41\x5D\x41\x5C" &
                               "\x41\x5B\x41\x5A\x41\x59\x41\x58" &
                               "\x5F\x5E\x5D\x5C\x5B\x5A\x59\x58"

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

# ElfHeader 64bit-only field offsets
const
  ELF64_ENTRY_64             = 0x18
  ELF64_PH_TABLE_64          = 0x20
  ELF64_SH_TABLE_64          = 0x28
  ELF64_PH_SIZE_16           = 0x36
  ELF64_PH_COUNT_16          = 0x38
  ELF64_SH_SIZE_16           = 0x3A
  ELF64_SH_COUNT_16          = 0x3C
  ELF64_SH_STRIDX_16         = 0x3E

# Program Header 64bit-only field offsets
const
  ELF64_PROGRAM_TYPE_32      = 0x00
  ELF64_PROGRAM_FLAGS_32     = 0x04
  ELF64_PROGRAM_OFFSET_64    = 0x08
  ELF64_PROGRAM_VIRTADDR_64  = 0x10
  ELF64_PROGRAM_FILESIZE_64  = 0x20
  ELF64_PROGRAM_MEMSIZE_64   = 0x28
  ELF64_PROGRAM_ALIGN_64     = 0x30

# Section Header
const
  ELF64_SECTION_NAME_32      = 0x00
  ELF64_SECTION_TYPE_32      = 0x04
  ELF64_SECTION_FLAGS_64     = 0x08
  ELF64_SECTION_ADDR_64      = 0x10
  ELF64_SECTION_OFFSET_64    = 0x18
  ELF64_SECTION_SIZE_64      = 0x20
  ELF64_SECTION_ALIGN_64     = 0x30
  ELF64_SECTION_ENTRYSIZE_64 = 0x38

# errors
const 
  ERR_FAILED_ELF_HEADER_READ = "failed to read enough data for ELF64 header"
  ERR_BAD_ELF_MAGIC          = "incorrect ELF magic bytes"
  ERR_ONLY_VERSION1          = "only ELF version 1 is supported"
  ERR_ONLY_LITTLE_ENDIAN     = "only little-endian is supported"
  ERR_ONLY_MACHINE_AMD64     = "only AMD64 architecture is supported"
  ERR_ONLY_CLASS_ELF64       = "only ELF 64-bit is supported"
  ERR_PROGRAM_OUT_OF_RANGE   = "program header table or entry beyond EOF"
  ERR_SECTION_OUT_OF_RANGE   = "section header table or entry beyond EOF"
  ERR_INVALID_FIELD          = "invalid size/count field"
  ERR_PROGRAM_HEADER_SIZE    = "program header too small"
  ERR_SECTION_HEADER_SIZE    = "section header too small"

const defaultMinAlignedLen   = 0x1000

type
  ElfType*                   = enum 
    ET_NONE                  = 0x00,
    ET_REL                   = 0x01,
    ET_EXEC                  = 0x02,
    ET_DYN                   = 0x03,
    ET_CORE                  = 0x04,
    ET_LOOS                  = 0xFE00,
    ET_HIOS                  = 0xFEFF,
    ET_LOPROC                = 0xFF00,
    ET_HIPROC                = 0xFFFF

  ProgramHeaderType*         = enum 
    PT_NULL                  = 0x00,
    PT_LOAD                  = 0x01,
    PT_DYNAMIC               = 0x02,
    PT_INTERP                = 0x03,
    PT_NOTE                  = 0x04,
    PT_SHLIB                 = 0x05,
    PT_PHDR                  = 0x06,
    PT_TLS                   = 0x07,
    PT_LOOS                  = 0x60000000,
    PT_HIOS                  = 0x6FFFFFFF,
    PT_LOPROC                = 0x70000000,
    PT_HIPROC                = 0x7FFFFFFF
                                      
  SectionHeaderType*         = enum 
    SHT_NULL                 = 0x00,
    SHT_PROGBITS             = 0x01,
    SHT_SYMTAB               = 0x02,
    SHT_STRTAB               = 0x03,
    SHT_RELA                 = 0x04,
    SHT_HASH                 = 0x05,
    SHT_DYNAMIC              = 0x06,
    SHT_NOTE                 = 0x07,
    SHT_NOBITS               = 0x08,
    SHT_REL                  = 0x09,
    SHT_SHLIBa               = 0x0A,
    SHT_DYNSYM               = 0x0B,
    SHT_INIT_ARRAY           = 0x0E,
    SHT_FINI_ARRAY           = 0x0F,
    SHT_PREINIT_AT           = 0x10,
    SHT_GROUP                = 0x11,
    SHT_SYMTABL_SHNDX        = 0x12,
    SHT_NUM                  = 0x13,
    SHT_LOOS                 = 0x60000000
    #FIXME Wikipedia ended here, find headerfile!

  SectionHeaderFlags*        = enum
    SHF_WRITE                = 0x01,
    SHF_ALLOC                = 0x02,
    SHF_EXECINSTR            = 0x04,
    SHF_MERGE                = 0x10,
    SHF_STRINGS              = 0x20,
    SHF_INFO_LINK            = 0x40,
    SHF_LINK_ORDER           = 0x80,
    SHF_OS_NONCONFORMING     = 0x100,
    SHF_GROUP                = 0x200,
    SHF_TLS                  = 0x400,
    SHF_ORDERED              = 0x4000000,
    SHF_EXCLUDE              = 0x8000000,
    SHF_MASKOS               = 0x0FF00000,
    SHF_MASKPROC             = 0xF0000000

  fixedElfBytesCheck         = ref object of RootRef
    whence:                  int
    value:                   string
    error:                   string

  ElfIntValue*[T]            = ref object of RootRef
    whence:                  uint64
    value:                   T
    ignore:                  bool

  ElfHeader*                 = ref object of RootRef
    elfType*:                ElfIntValue[uint16]
    entryPoint*:             ElfIntValue[uint64]
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

  Operation*                 = ref object of RootRef
    whence*:                 uint64
    size*:                   uint64
    value*:                  uint64

  ElfFile*                   = ref object of RootRef
    fileData*:               string
    offsets:                 seq[ElfIntValue[uint64]]
    header*:                 ElfHeader
    operations*:             seq[Operation]
    programHeaders*:         seq[ElfProgramHeader]
    sectionHeaders*:         seq[ElfSectionHeader]
    errors*:                 seq[string]
    entryProgramHeader*:     ElfProgramHeader
    isParsed:                bool

proc getInt[T](data: var string, whence: int = 0): T =
  return cast[ref [T]](addr data[whence])[]

proc setInt[T](data: var string, whence: uint64, value: T) =
  for byteIndex in 0 ..< sizeof(T):
    var newValue = (uint(value) shr uint(byteIndex * 8)) and uint(0xFF)
    data[int(whence) + byteIndex] = char(newValue)

method getMinAlignedLength*(self: ElfFile): uint64 =
  result = uint64(defaultMinAlignedLen)
  var sectionHeaders  = self.sectionHeaders
  for index in 0 ..< len(sectionHeaders):
    var sectionHeader = sectionHeaders[index]
    if sectionHeader.align.value > result:
      result          = sectionHeader.align.value
  var programHeaders  = self.programHeaders
  for index in 0 ..< len(programHeaders):
    var programHeader = programHeaders[index]
    if programHeader.align.value > result:
      result          = programHeader.align.value
  return result

method getAlignedData*(self: ElfFile, data: string, padByte: char): string =
  var dataLen       = uint64(len(data))
  var alignedLength = self.getMinAlignedLength()
  if dataLen > alignedLength:
    if dataLen mod alignedLength != 0:
      alignedLength *= uint64((dataLen div alignedLength) + 1)
    else:
      alignedLength *= uint64(dataLen div alignedLength)
  return alignLeft(data, alignedLength, padByte)

method addElfIntValue[T](self:       ElfFile,
                         elfValue:   var ElfIntValue[T],
                         addend:     T) =
  ## Adds (arithmetic sum) the supplied addend to the specified elfValuem
  ## and records the modification in the operations table for future reversal
  if elfValue.ignore:
    # something else has already set this value. This is mostly to save the
    # extra step of reparsing when a modification is happening where it 
    # *looks like* this offset needs updating but has already been manually
    # updated
    return
  if addend == 0:
    # no op, it's important we don't do anything, because
    # an operation value of 0 implies a transformation/insertion
    # so if we see an addition for 0, just ignore it
    return
  elfValue.value += addend
  setInt[T](self.fileData, elfValue.whence, elfValue.value)
  self.operations.add(Operation(
    whence: elfValue.whence,
    size:   uint64(sizeof(addend)),
    value:  uint64(addend)))
  #FIXME entirely delete the commented line below after confirming
  #self.isParsed = false

method insertAlignedData(self: ElfFile, whence: uint64, data: string) =
  ## Inserts the already-aligned data at a given offset
  var dataLen = uint64(len(data))
  for index in 0..< len(self.offsets):
    var elfOffset = self.offsets[index]
    if elfOffset.value >= whence:
      self.addElfIntValue(elfOffset, dataLen)
  var fileData  = self.fileData
  self.fileData = fileData[0 ..< whence] & data & fileData[whence .. ^1]
  self.operations.add(Operation(whence: whence, size: dataLen))
  self.isParsed = false

proc getValue[T](data: var string, whence: uint64): ElfIntValue[T] =
  return ElfIntValue[T](whence: whence, value: getInt[T](data, int(whence)))

method readOffset(self: ElfFile, whence: uint64): ElfIntValue[uint64] {.base.} =
  result = getValue[uint64](self.fileData, whence)
  self.offsets.add(result)
  return result

method parseHeader*(self: ElfFile): bool {.base.} =
  let 
    # skipping as many fields as I can for now, but these are necessary
    checks = @[fixedElfBytesCheck(whence: ELF_MAGIC_32,
                                  value:  ELF_MAGIC_BYTES,
                                  error:  ERR_BAD_ELF_MAGIC),
               fixedElfBytesCheck(whence: ELF_CLASS_8,
                                  value:  ELF_CLASS_ELF64,
                                  error:  ERR_ONLY_CLASS_ELF64),
               fixedElfBytesCheck(whence: ELF_ENDIAN_8,
                                  value:  ELF_LITTLE_ENDIAN,
                                  error:  ERR_ONLY_LITTLE_ENDIAN),
               fixedElfBytesCheck(whence: ELF_MACHINE_16,
                                  value:  ELF_MACHINE_AMD64,
                                  error:  ERR_ONLY_MACHINE_AMD64),
               fixedElfBytesCheck(whence: ELF_VERSION_32,
                                  value:  ELF_VERSION1,
                                  error:  ERR_ONLY_VERSION1)]
  var data = self.fileData
  var errors = self.errors
  if len(data) <= ELF64_HEADER_SIZE:
    errors.add(ERR_FAILED_ELF_HEADER_READ)
    return false
  for i in low(checks) .. high(checks):
    var check = checks[i]
    if data[check.whence ..< check.whence+len(check.value)] != check.value:
      errors.add(check.error)
  if len(errors) > 0:
    return false
  self.header           = ElfHeader(
    elfType:            getValue[uint16](data, ELF_TYPE_16),
    entryPoint:         self.readOffset(ELF64_ENTRY_64),
    programTable:       self.readOffset(ELF64_PH_TABLE_64),
    sectionTable:       self.readOffset(ELF64_SH_TABLE_64),
    programHeaderSize:  getValue[uint16](data, ELF64_PH_SIZE_16),
    programCount:       getValue[uint16](data, ELF64_PH_COUNT_16),
    sectionHeaderSize:  getValue[uint16](data, ELF64_SH_SIZE_16),
    sectionCount:       getValue[uint16](data, ELF64_SH_COUNT_16),
    sectionStringIndex: getValue[uint16](data, ELF64_SH_STRIDX_16),
  )
  if self.header.sectionStringIndex.value >= self.header.sectionCount.value:
    errors.add(ERR_SECTION_OUT_OF_RANGE)
    return false
  return true

method parseProgramTable(self: ElfFile): bool {.base.} =
  var data        = self.fileData
  var dataLen     = uint64(len(data))
  var elfHeader   = self.header
  var tableOffset = elfHeader.programTable.value
  if tableOffset > dataLen or tableOffset < ELF64_HEADER_SIZE:
    # for more thorough checks we could add an interval tree, but not today
    self.errors.add(ERR_PROGRAM_OUT_OF_RANGE)
    return false
  let programHeaderSize = elfHeader.programHeaderSize.value
  if programHeaderSize < ELF64_PROGRAM_HEADER_SIZE:
    self.errors.add(ERR_PROGRAM_HEADER_SIZE)
    return false
  let programTableSize = programHeaderSize * elfHeader.programCount.value
  if programTableSize < programHeaderSize: # catches int wrap and programCount=0
    self.errors.add(ERR_INVALID_FIELD)
    return false
  if uint64(programTableSize) > dataLen:
    self.errors.add(ERR_PROGRAM_OUT_OF_RANGE)
    return false
  var offset = tableOffset
  while offset < tableOffset + uint64(programTableSize):
    var programHeader = ElfProgramHeader(
      offset:         self.readOffset(offset+ELF64_PROGRAM_OFFSET_64),
      headerType:     getValue[uint32](data, offset+ELF64_PROGRAM_TYPE_32),
      flags:          getValue[uint32](data, offset+ELF64_PROGRAM_FLAGS_32),
      virtualAddress: getValue[uint64](data, offset+ELF64_PROGRAM_VIRTADDR_64),
      sizeInFile:     getValue[uint64](data, offset+ELF64_PROGRAM_FILESIZE_64),
      sizeInMemory:   getValue[uint64](data, offset+ELF64_PROGRAM_MEMSIZE_64),
      align:          getValue[uint64](data, offset+ELF64_PROGRAM_ALIGN_64))
    if programHeader.offset.value > dataLen:
      self.errors.add(ERR_SECTION_OUT_OF_RANGE)
      return false
    if programHeader.offset.value + uint64(programHeaderSize) > dataLen:
      self.errors.add(ERR_PROGRAM_OUT_OF_RANGE)
      return false
    self.programHeaders.add(programHeader)
    offset += uint64(programHeaderSize)
  return true

method parseSectionTable(self: ElfFile): bool {.base.} =
  var data        = self.fileData
  var dataLen     = uint64(len(data))
  var elfHeader   = self.header
  var tableOffset = elfHeader.sectionTable.value
  if tableOffset > dataLen or tableOffset < ELF64_HEADER_SIZE:
    # for more thorough checks we could add an interval tree, but not today
    self.errors.add(ERR_SECTION_OUT_OF_RANGE)
    return false
  let sectionHeaderSize = elfHeader.sectionHeaderSize.value
  if sectionHeaderSize < ELF64_SECTION_HEADER_SIZE:
    self.errors.add(ERR_SECTION_HEADER_SIZE)
    return false
  let sectionTableSize = sectionHeaderSize * elfHeader.sectionCount.value
  if sectionTableSize < sectionHeaderSize: # catches int wrap and sectionCount=0
    self.errors.add(ERR_INVALID_FIELD)
    return false
  if uint64(sectionTableSize) > dataLen:
    self.errors.add(ERR_SECTION_OUT_OF_RANGE)
    return false
  var offset = tableOffset
  var sectionHeaders = self.sectionHeaders
  while offset < tableOffset + uint64(sectionTableSize):
    var sectionHeader = ElfSectionHeader(
      offset:         self.readOffset(offset+ELF64_SECTION_OFFSET_64),
      headerType:     getValue[uint32](data, offset+ELF64_SECTION_TYPE_32),
      nameIndex:      getValue[uint32](data, offset+ELF64_SECTION_NAME_32),
      flags:          getValue[uint64](data, offset+ELF64_SECTION_FLAGS_64),
      virtualAddress: getValue[uint64](data, offset+ELF64_SECTION_ADDR_64),
      size:           getValue[uint64](data, offset+ELF64_SECTION_SIZE_64),
      entrySize:      getValue[uint64](data, offset+ELF64_SECTION_ENTRYSIZE_64),
      align:          getValue[uint64](data, offset+ELF64_SECTION_ALIGN_64))
    if sectionHeader.offset.value > dataLen:
      self.errors.add(ERR_SECTION_OUT_OF_RANGE)
      return false
    if sectionHeader.size.value > dataLen:
      self.errors.add(ERR_SECTION_OUT_OF_RANGE)
      return false
    # not checking for int wrap since it would mean len(data)>=2**63 (in mem!)
    # which, I mean amazing, but, *unlikely* ;) That being said, we should
    # check if offset+size > data
    if sectionHeader.offset.value + sectionHeader.size.value > dataLen:
      if SectionHeaderType(sectionHeader.headerType.value) != SHT_NOBITS:
        self.errors.add(ERR_SECTION_OUT_OF_RANGE)
        return false
    sectionHeaders.add(sectionHeader)
    offset += uint64(sectionHeaderSize)
  self.sectionHeaders = sectionHeaders
  var nameSectionHeader = sectionHeaders[self.header.sectionStringIndex.value]
  var startIndex = int(nameSectionHeader.offset.value)
  var endIndex = startIndex + int(nameSectionHeader.size.value)
  var nameSection = self.fileData[startIndex .. endIndex]
  var maxNameIndex = uint32(len(nameSection) - 1)
  # validation, and storing names
  for sectionIndex in 0 ..< len(sectionHeaders):
    var sectionHeader = sectionHeaders[sectionIndex]
    var nameIndex = sectionHeader.nameIndex.value
    if nameIndex > maxNameIndex:
      self.errors.add(ERR_SECTION_OUT_OF_RANGE)
      return false
    sectionHeader.name = $(cstring(nameSection[int(nameIndex) .. ^1]))
  return true

method getEntryProgramHeader*(self: ElfFile): ElfProgramHeader =
  ## Returns the ElfProgramHeader responsible for the entrypoint.
  ## This was broken into its own function when multiple approaches
  ## were being tested for entrypoint injection, it could possibly
  ## be recombined with the injectEntry function
  var entryAddress    = self.header.entryPoint.value
  var programHeaders  = self.programHeaders
  for index in 0..< len(programHeaders):
    var programHeader = programHeaders[index]
    if ProgramHeaderType(programHeader.headerType.value) != PT_LOAD:
      continue
    if programHeader.flags.value != (ELF_PROGRAM_FLAG_EXEC or
                                     ELF_PROGRAM_FLAG_READ):
      continue
    var startAddress = programHeader.virtualAddress.value
    var endAddress = startAddress + programHeader.sizeInMemory.value
    if entryAddress >= startAddress and entryAddress <= endAddress:
      return programHeader
  return nil

method parse*(self: ElfFile): bool {.base.} =
  ## parse the ELF and return true if everything went OK,
  ## where failure is indicative of a malformed ELF, or maybe
  ## a nuance of ELF that was unknown at time of writng :)
  if self.isParsed:
    return true
  self.offsets = @[]
  self.programHeaders = @[]
  self.sectionHeaders = @[]
  result = self.parseHeader() and
     self.parseProgramTable() and
     self.parseSectionTable()
  self.isParsed = not result
  return result

method injectEntry*(self: ElfFile, data: string, setEntryPoint: bool): bool =
  ## injectEntry(): 
  ## injects data (code) into the program defined as containing the entrypoint,
  ## and update the appropriate ELF section, and update offsets of all subsequent
  ## sections in the ELF.
  ##   data: data (code) to inject
  ##   setEntryPoint: if true, we redirect the entrypoint to the new code
  if not self.parse():
    return false
  var programHeader = self.getEntryProgramHeader()
  if programHeader == nil:
    return false

  # Here we get the endSectionAddress: the virtual address representing the 
  # end of data mapped from the file into memory. Note that we use the filesize
  # from the programHeader, not the memorysize, because the memorysize can be
  # synthetically larger than the data available in the file, which is to
  # indicate that more memory should be allocated and filled with nullbytes
  var endSectionAddress = programHeader.virtualAddress.value +
                          programHeader.sizeInFile.value
  var insertOffset      = programHeader.offset.value +
                          programHeader.sizeInFile.value
  var dataLen           = uint64(len(data))
  self.addElfIntValue(programHeader.sizeInFile,   dataLen)
  self.addElfIntValue(programHeader.sizeInMemory, dataLen)
  var sectionHeaders = self.sectionHeaders
  for index in 0 ..< len(sectionHeaders):
    var section = sectionHeaders[index]
    if section.virtualAddress.value + section.size.value == endSectionAddress:
      self.addElfIntValue(section.size, dataLen)
  if setEntryPoint:
    var entryPoint = self.header.entryPoint
    self.addElfIntValue(entryPoint, uint64(insertOffset - entryPoint.value))
    entryPoint.ignore = true
  self.insertAlignedData(insertOffset, self.getAlignedData(data, '\x00'))
  return true

method printOperations(self: ElfFile) =
  ## Prints the ordered operations recorded during transforms performed
  ## on this ELF
  var operations = self.operations
  for index in low(operations) .. high(operations):
    var op = operations[index]
    if op.value == 0: #value of 0 means insertion
      echo "data = data[0 ..< 0x" &
             op.whence.tohex()    &
             " & [0x"             &
             op.size.tohex()      &
             " bytes] & data[0x"  &
             op.whence.tohex()    &
             " .. ^1]"
    else: # this is an addition
      echo "*(uint"          &
           $(op.size * 8)    &
           " *)(&data[0x"    &
           op.whence.tohex() &
           "]) += 0x"        &
           op.value.tohex()


method injectDataAfterElfHeader*(self: ElfFile, data: string): bool =
  # a little experiment: can we just insert data and update the offsets?
  # if it works, will the loader care? will `strip` care?
  if not self.parse():
    return false
  var alignedData = self.getAlignedData(data, '\x00')
  self.insertAlignedData(ELF64_HEADER_SIZE, alignedData)
  return true

method findChalkSection*(self: ElfFile): string =
  if not self.parse():
   return ""
  var sectionHeaders = self.sectionHeaders
  var fileData = self.fileData
  var dataLen = uint64(len(fileData))
  for index in low(sectionHeaders) .. high(sectionHeaders):
    var header = sectionHeaders[index]
    var begindex = header.offset.value
    if begindex > dataLen:
      continue
    var endex    = begindex + header.size.value
    if endex == 0:
      continue
    if endex > dataLen:
      continue
    var section  = fileData[begindex ..< endex]
    if len(section) < 20:
      continue
    if section[0 ..< 11] == "{ \"MAGIC\" :":
      return section
  return ""

method injectSectionAtEnd*(self: ElfFile, data: string): bool =
  if not self.parse():
    return false
  var header  = self.header
  var offset  = header.sectionTable.value
  # calculate the end of the section header table where we will insert
  offset     += (header.sectionHeaderSize.value * header.sectionCount.value)
  # increment the section header count
  self.addElfIntValue(header.sectionCount, 1)

  # our new section header is brutishly raised in size to the mininimum
  # alignment supported across the whole ELF file, because this requires
  # less work than calculating the minimum viable across the remaining and
  # then checking if we already have gap space to fill.. we can revisit but
  # for now this is to get stuff working.
  var sectionHeader = newString(self.getMinAlignedLength())

  # set section flags to PROGBITS to scare `strip` away from removing it
  setInt[uint32](sectionHeader,
                 uint64(ELF64_SECTION_TYPE_32),
                 uint32(SHT_PROGBITS))
  # the datasize we are adding is *not* aligned, as we intend to append
  # this section at the very end, and if anything else comes along and appends
  # itself to this file, it better be aware enough to know to how to align
  # itself as necessary (also an extremely unlikely scenario)
  setInt[uint64](sectionHeader,
                 uint64(ELF64_SECTION_SIZE_64),
                 uint64(len(data)))

  # now we insert the heckin-chonker-size-aligned sectionHeader
  # the insertAlignedData function will handle fixing up other offsets
  self.insertAlignedData(offset, sectionHeader)
  
  # this next bit is just lazy: we could have calculated the offset/delta
  # with consideration for the alignment and so on, but here we just look
  # at the length of the resulting filedata and use that as our offset in
  # the section header, after which we simply append our data
  var endOfFile = uint64(len(self.fileData))
  setInt[uint64](self.fileData,
                 offset + ELF64_SECTION_OFFSET_64,
                 endOfFile)
  self.fileData &= data
  return true

method printTableOffsets*(self: ElfFile) =
  var header = self.header
  echo "entryPoint:     0x" & header.entryPoint.value.tohex()
  echo "programTable:   0x" & header.programTable.value.tohex()
  echo "sectionTable:   0x" & header.sectionTable.value.tohex()
  echo "sectionCount:   0x" & header.sectionCount.value.tohex()
  echo "sectionHdrSize: 0x" & header.sectionHeaderSize.value.tohex()
  

method injectEntryCodeCave*(self: ElfFile, code: string): bool =
  ## Injects entry point code prefixed with `endbr64` instruction, and suffixed
  ## with a branch back to the original entry point.
  var entryProgramHeader = self.getEntryProgramHeader()
  var entryAddress       = self.header.entryPoint.value
  var startAddress       = entryProgramHeader.virtualAddress.value
  var endAddress         = startAddress + entryProgramHeader.sizeInMemory.value
  var insertedCode       = X86_64_ENDBR64      &
                           X86_64_PUSH_GENERAL &
                           code                &
                           X86_64_POP_GENERAL  &
                           X86_64_JMP_IMM32
  var displacement       = uint32(endAddress - entryAddress)
  displacement          += uint32(len(insertedCode) + 4)
  displacement           = uint32(0 - displacement)
  insertedCode          &= char(displacement  and 0xFF)
  insertedCode          &= char((displacement shr 0x08) and 0xFF)
  insertedCode          &= char((displacement shr 0x10) and 0xFF)
  insertedCode          &= char((displacement shr 0x18) and 0xFF)
  return self.injectEntry(insertedCode, true)

proc newElfFile(filename: string): ElfFile =
  var elfDataFile = open(filename, fmRead)
  return ElfFile(
    fileData: elfDataFile.readAll(),
  )

proc restoreData(data: var string, operations: seq[Operation]): bool =
  ## Restored the original pre-image of data before the transformations
  ## described by the ordered operations sequence.
  ## This is for un-chalking ELF binaries :)
  var index = len(operations)
  while index > 0:
    index -= 1
    var op = operations[index]
    var dataLen = uint64(len(data))
    if op.whence > dataLen or op.size > dataLen or op.whence+op.size > dataLen:
      return false
    if op.value == 0:
      data = data[0 ..< int(op.whence)] &
             data[int(op.whence + op.size) .. ^1]
    else:
      var value = uint64(0) - 1
      var length = op.size - 1
      for index in 0 .. length:
        value = value shl 8
        value = value or uint64(data[op.whence + (length - index)])
      value -= op.value
      for bytes in 0 ..< op.size:
        data[op.whence + bytes] = char((value shr (bytes * 8)) and 0xFF)
  return true

let args = commandLineParams()
if len(args) < 2:
  echo "usage: " & "elfchalk" & " <insert | beacon | extract> <filename> <output>"
  quit(1)

var action       = args[0]
var inputFile    = args[1]
var outputFile   = "outputfile"
if action != "extract":
  if len(args) < 3:
    echo "usage: " & "elfchalk" & " <insert | beacon | extract> <filename> <output>"
    quit(1)
  outputFile = args[2]

var elfFile      = newElfFile(inputFile)
if not elfFile.parse():
  echo "errors!"
  echo $elfFile.errors
  quit(1)

#elfFile.printTableOffsets()

#if elfFile.injectEntry(injectString, false):

# bored? have fun with code injection!
# ./elf `which ls` ./foo "`perl -e 'print "\xeb\x02\xeb\x11\xe8\xf9\xff\xff\xff\x68\x65\x6c\x6c\x6f\x20\x77\x6f\x72\x6c\x64\x0a\x5e\x48\x31\xff\x48\xff\xc7\x48\x89\xfa\x48\xc1\xe2\x02\x48\x89\xd0\x48\xd1\xe2\x48\x01\xc2\x48\x89\xf8\x0f\x05"'`"
# ^ that's hello world, and it's long because it doesn't have contain
# nullbytes and i'm old so i'm bad at shellcode

# if you want a basic ASCII printable/typable NO-OP: 
# ./elf anyprogram ./whereitwillbeouttput PX
#                                         | `--pop  rax
#                                         `----push rax


# the string 'beacon home':
# 
var beaconHome = "\xeb\x02\xeb\x11\xe8\xf9\xff\xff\xff\x62\x65\x61\x63\x6f\x6e\x20\x68\x6f\x6d\x65\x0a\x5e\x48\x31\xff\x48\xff\xc7\x48\x89\xfa\x48\xc1\xe2\x02\x48\x89\xd0\x48\xd1\xe2\x48\x01\xc2\x48\x89\xf8\x0f\x05"

var chalkData = "" &
"""{ "MAGIC" : "dadfedabbadabbed", "CHALK_ID" : "RTYCQC-2Y71-3XGT-AX3HBD", "CHALK_VERSION" : "0.5.0", "DATETIME" : "2023-06-02T11:28:57.247+00:00", "INSERTION_HOSTINFO" : "#79-Ubuntu SMP Wed Apr 19 08:22:18 UTC 2023", "ARTIFACT_PATH" : "/home/user/repos/chalk-internal/raidfolklore/example_chalk/exampleprogram/exampleprogram", "HASH" : "c6bccbb05e3847d8695d1c56d0ed76930da29ff422bf39c6e67db5bdfc10a5cb", "HASH_FILES" : ["/home/user/repos/chalk-internal/raidfolklore/example_chalk/exampleprogram/exampleprogram"], "ORIGIN_URI" : "git@github.com:crashappsec/chalk-internal.git", "BRANCH" : "drraid/jermainedupri", "COMMIT_ID" : "8ed5e84da325dd7cdcdc2d954fcba9cc56e56732", "CODE_OWNERS" : "@viega", "INJECTOR_ID" : "JJ4054-Z0Q1-XNE5-6K4JY9", "INJECTOR_VERSION" : "0.4.0", "INJECTOR_PLATFORM" : "GNU/Linux x86_64", "INJECTOR_COMMIT_ID" : "8ed5e84da325dd7cdcdc2d954fcba9cc56e56732", "CHALK_RAND" : "900832427c95e4f8", "METADATA_HASH" : "11992f2e0c86ff9d97e8d86e03c288e789fa58845cf4531729cf96f51bd262c2", "METADATA_ID" : "26CJYB-GCGV-ZSV5-Z8V1Q0" }"""

#elfFile.printOperations()
#if elfFile.injectEntryCodeCave(injectString):
#if elfFile.injectDataAfterElfHeader("ChalkyMcJson"):
var allGood = false
case action:
  of "insert":
    if elfFile.injectSectionAtEnd(chalkData):
      allGood = true
  of "beacon":
    if elfFile.findChalkSection() == "":
      if elfFile.injectSectionAtEnd(chalkData):
        if elfFile.injectEntryCodeCave(beaconHome):
          allGood = true
    else:
      if elfFile.injectEntryCodeCave(beaconHome):
        allGood = true
  of "extract":
    var fileChalk = elfFile.findChalkSection()
    if fileChalk != "":
      echo fileChalk
      quit(1)
if allGood:
  writeFile(outputFile, elfFile.fileData)
  echo "written to " & outputFile
else:
  echo "no operation was performed"
