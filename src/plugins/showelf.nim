##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##
import elf, os

var cmdline = os.commandLineParams()
if len(cmdline) == 0:
  echo "specify a file to elf parse + show!"
  quit(1)

var ourFile = newElfFileFromFilename(cmdline[0])
#echo "before anytyhing else:"
#parseAndShow(ourFile.fileData)
if not ourFile.parse():
  echo "failed to parse"
  quit(2)

if ourFile.header == nil:
  echo "what?!?!?!?!?!"
  quit(3)

if not ourFile.insertChalkSection(SH_NAME_CHALKMARK, "scoobyscoobyscoobyscoobyscooby"):
  echo "failed to insert a section"
  quit(4)

let chalkName = "examine.chalked"
writeFile(chalkName, ourFile.fileData)

if not ourFile.unchalk():
  echo "writing to examine.busted" 
  writeFile("examine.busted", ourFile.fileData)
  echo "failed to unchalk"
  quit(5)
  
let unchalkedName = "examine.unchalked"
writeFile(unchalkedName, ourFile.fileData)

var freshStart = newElfFileFromFilename(cmdline[0])
if not freshStart.parse():
  echo "failed to parse new one?"
  quit(6)

if not freshStart.unchalk():
  echo "failed to unchalk fresh start?!"
  quit(7)


let neverChalked = "examine.neverchalked"
writeFile(neverChalked, freshStart.fileData)

echo "OKAY!"


#if ourFile.chalkSectionHeader == nil:
#  let hashPlaceholder = newString(SHA256_BYTE_LENGTH)
#  echo "calling insertChalkSection"
#  if ourFile.insertChalkSection(SH_NAME_CHALKFREE, hashPlaceholder):
#    echo "calling setUnchalkedHash"
#    echo ourFile.setUnchalkedHash()
