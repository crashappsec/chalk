##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  options,
]
import pkg/[
  con4m,
  nimutils,
]
import "."/[
  utils/strings,
  utils/tables,
]

export con4m

var con4mRuntime*: ConfigStack # can be nil

proc getChalkConfigState(): ConfigState =
  con4mRuntime.configState

proc getChalkScope*(): AttrScope =
  getChalkConfigState().attrs

proc sectionExists*(c: ConfigState, s: string): bool =
  c.attrs.getObjectOpt(s).isSome()

proc sectionExists*(s: string): bool =
  sectionExists(getChalkConfigState(), s)

proc attrGet*[T](c: ConfigState, fqn: string): T =
  get[T](c.attrs, fqn)

proc attrGet*[T](fqn: string): T =
  attrGet[T](getChalkConfigState(), fqn)

proc attrGetOpt*[T](c: ConfigState, fqn: string): Option[T] =
  getOpt[T](c.attrs, fqn)

proc attrGetOpt*[T](fqn: string): Option[T] =
  attrGetOpt[T](getChalkConfigState(), fqn)

proc attrGetObject*(c: ConfigState, fqn: string): AttrScope =
  getObject(c.attrs, fqn)

proc attrGetObject*(fqn: string): AttrScope =
  attrGetObject(getChalkConfigState(), fqn)

iterator getChalkSubsections*(s: string): string =
  ## Walks the contents of the given chalk config section, and yields the
  ## names of the subsections.
  for k, v in attrGetObject(s).contents:
    if v.isA(AttrScope):
      yield k

proc con4mAttrSet*(ctx: ConfigState, fqn: string, value: Box) =
  ## Sets the value of the `fqn` attribute in `ctx.attrs` to `value`, raising
  ## `AssertionDefect` if unsuccessful.
  ##
  ## This proc must only be used if the attribute is already set. If the
  ## attribute isn't already set, use the other `con4mAttrSet` overload instead.
  doAssert attrSet(ctx, fqn, value).code == errOk

proc con4mAttrSet*(c: ConfigState, fqn: string, value: Box, attrType: Con4mType) =
  ## Sets the value of the `fqn` attribute to `value`, raising `AssertionDefect`
  ## if unsuccessful.
  ##
  ## This proc may be used if the attribute is not already set.
  doAssert attrSet(c.attrs, fqn, value, attrType).code == errOk

proc con4mAttrSet*(fqn: string, value: Box, attrType: Con4mType) =
  ## Sets the value of the `fqn` attribute to `value`, raising `AssertionDefect`
  ## if unsuccessful.
  ##
  ## This proc may be used if the attribute is not already set.
  con4mAttrSet(getChalkConfigState(), fqn, value, attrType)

proc con4mSectionCreate*(c: ConfigState, fqn: string) =
  discard attrLookup(c.attrs, fqn.split('.'), ix = 0, op = vlSecDef)

proc con4mSectionCreate*(fqn: string) =
  con4mSectionCreate(con4mRuntime.configState, fqn)
