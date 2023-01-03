import nimutils/box

import tables
import options
import streams
import config

type
  SamiDict* = TableRef[string, Box] ## \
     ## Representation of the abstract SAMI's fields. If the SAMI
     ## was read from a file, this will include any embeds / nests.
     ## If, however, it is a "new" SAMI, then any embeds or
     ## SAMIs that were there when we first loaded the file
     ## will end up in the FileOfInterest object.

  FileFlags* = enum
    Binary, BigEndian, Arch64Bit

  SamiPoint* = ref object
    ## The SamiPoints object encodes all info known about a single point
    ## for a SAMI, such as whether there's currently a SAMI object
    ## there.
    samiFields*: Option[SamiDict] ## The SAMI fields found at a point.
    startOffset*: int ## When we're inserting SAMI, where does it go?
    endOffset*: int ## When we're inserting SAMI, where does the file resume?
    present*: bool ## Flag to indicate whether there's magic at the location.
    valid*: bool
    err*: seq[string]

  SamiObj* = ref object
    ## The SAMI point info for a single artifact.
    fullpath*: string    ## The path to the file we've hit on the walk.
    toplevel*: string    ## The toplevel path under which we found this file.
    stream*: FileStream  ## The open file.
    newFields*: SamiDict ## What we're adding during insertion.
    primary*: SamiPoint  ## This represents the location of a SAMI's
                         ## insertion, and also holds any SAMI fields
                         ## extracted from this position.
    flags*: set[FileFlags]
    embeds*: seq[(string, SamiPoint)]

  Plugin* = ref object of RootObj
    configInfo*: SamiPluginSection

  PluginInfo* = tuple[priority: int, name: string, plugin: Plugin]
  Codec* = ref object of Plugin
    samis*: seq[SamiObj]
    magic*: string
    searchPath*: seq[string]

  ExternalPlugin* = ref object of Plugin
    command*: string


  KeyInfo* = TableRef[string, Box]

proc samiHasExisting*(sami: SamiObj): bool {.inline.} =
  return sami.primary.valid

proc samiIsEmpty*(sami: SamiObj): bool {.inline.} =
  return if (sami.embeds.len() > 0) or sami.samiHasExisting(): false else: true

# For use in binary JSON encoding.
const
  binTypeNull* = 0'u8
  binTypeString* = 1'u8
  binTypeInteger* = 2'u8
  binTypeBool* = 3'u8
  binTypeArray* = 5'u8
  binTypeObj* = 6'u8



