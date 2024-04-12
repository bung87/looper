
##
## This module implements a stream http multipart parser
## depends on chronos StreamTransport
##
## Copyright (c) 2020 Bung

import streams, os, oids, strformat
import chronos, ptr_math
import parseutils, strutils # parseBoundary
include ./ constant
import ./sbmh 

const ContentDispoitionFlagLen = "Content-Disposition:".len
const FormDataFlagLen = "form-data;".len

type
  BoundaryMissingError* = object of CatchableError
  BoundaryInvalidError* = object of CatchableError
  BodyIncompleteError* = object of CatchableError
  MultipartState* = enum
    boundaryBegin, boundaryEnd, contentEnd, extroHeader, disposition, contentBegin
  MultipartParser* = ref object
    boundaryBegin, boundaryEnd: string
    boundaryBeginLen, boundaryEndLen: int
    state*: MultipartState
    preState: MultipartState
    dispositionIndex: int
    contentLength: int
    transp: StreamTransport
    aSlice: Slice[int] # store name,value pair indexes
    bSlice: Slice[int]
    read: int
    buf: ptr char
    src: ptr array[HttpRequestBufferSize, char]
    dispositions*: seq[ContentDisposition]

  ContentDispositionKind* = enum
    data, file
  ContentDisposition* = ref object
    name*: string
    case kind*: ContentDispositionKind
      of data:
        value*: string
      of file:
        filename*, filepath*, contentType*: string
        file: FileStream

proc `$`*(x: ContentDisposition): string =
  if x.kind == data:
    result = fmt"""{{"name":"{x.name}", "value": "{x.value}"}}"""
  elif x.kind == file:
    result = fmt"""{{"name":"{x.name}", "filename":"{x.filename}", "contentType": "{x.contentType}", "filepath": {x.filepath} }}"""

template debug(a: varargs[untyped]) =
  when defined(DebugMultipartParser):
    echo a

proc parseBoundary*(line: string): tuple[i: int, boundary: string] =
  # retrieve boundary from Content-Type
  # consists of 1 to 70 characters
  # https://tools.ietf.org/html/rfc7578#section-4.1
  const Flag = "multipart/form-data;"
  const BoundaryFlag = "boundary="
  result.i = line.find(Flag)
  if result.i > -1:
    if line.find('"', result.i) == -1:
      result.i = line.find(BoundaryFlag, result.i)
      if result.i != -1:
        result.boundary = line[result.i + BoundaryFlag.len ..< line.len]
    else:
      result.i = line.find(BoundaryFlag, result.i)
      if result.i != -1:
        result.boundary = captureBetween(line, '"', '"', result.i + BoundaryFlag.len)
  if result.i == -1:
    raise newException(BoundaryMissingError, "Boundary missing")
  elif result.boundary.len == 0 or result.boundary.len > 70:
    raise newException(BoundaryInvalidError, "Boundary invalid")

proc newMultipartParser*(boundary: string, transp: StreamTransport, src: ptr array[HttpRequestBufferSize, char],
    contentLength: int): MultipartParser =
  new result
  result.state = boundaryBegin
  result.boundaryBegin = "--" & boundary
  result.boundaryEnd = "--" & boundary & "--"
  result.boundaryBeginLen = result.boundaryBegin.len
  result.boundaryEndLen = result.boundaryEnd.len
  result.transp = transp
  result.src = src
  result.buf = src[0].addr
  result.contentLength = contentLength

proc remainLen(parser: MultipartParser): int {.inline.} =
  parser.contentLength - parser.read

proc needReadLen(parser: MultipartParser): int {.inline.} =
  min(parser.remainLen, HttpRequestBufferSize)

proc currentDisposition(parser: MultipartParser): ContentDisposition{.inline.} =
  parser.dispositions[parser.dispositionIndex]

proc skipWhiteSpace(parser: MultipartParser) {.inline.} =
  # skip possible whitespace between value's fields
  if parser.buf[] == ' ':
    parser.buf += 1

proc isBoundaryBegin(parser: MultipartParser): bool{.inline.} =
  result = true
  for i in 0 ..< parser.boundaryBeginLen:
    if (parser.buf + i)[] != parser.boundaryBegin[i]:
      return false

proc isBoundaryEnd(parser: MultipartParser): bool {.inline.} =
  result = true
  for i in 0 ..< parser.boundaryEndLen:
    if (parser.buf + i)[] != parser.boundaryEnd[i]:
      return false

proc skipContentDispositionFlag(parser: MultipartParser) {.inline.} =
  # Content-Disposition (case senstitive)
  parser.buf += ContentDispoitionFlagLen

proc skipFormDataFlag(parser: MultipartParser) =
  parser.buf += FormDataFlagLen

proc skipLineEnd(parser: MultipartParser) {.inline.} =
  if parser.buf[] == '\c' and (parser.buf + 1)[] == '\l':
    parser.buf += 2

proc skipBeginTok(parser: MultipartParser) {.inline.} =
  parser.buf += parser.boundaryBeginLen

proc validateBoundary(parser: MultipartParser, line: string): bool =
  # https://tools.ietf.org/html/rfc2046#section-5.1
  # NOTE TO IMPLEMENTORS:  Boundary string comparisons must compare the
  # boundary value with the beginning of each candidate line.  An exact
  # match of the entire candidate line is not required; it is sufficient
  # that the boundary appear in its entirety following the CRLF.
  line == parser.boundaryBegin

proc skipEndTok(parser: MultipartParser) {.inline.} =
  parser.buf += parser.boundaryEndLen

proc aStr(parser: MultipartParser;data:openArray[char]): string {.inline.} =
  parser.aSlice.b -= 1
  cast[string](data[parser.aSlice])

proc bStr(parser: MultipartParser;data:openArray[char]): string {.inline.} =
  parser.bSlice.b -= 1
  cast[string](data[parser.bSlice])

proc takeASlice(parser: MultipartParser) {.inline.} =
  parser.bSlice.a = parser.aSlice.b
  parser.bSlice.b = parser.aSlice.b

proc incBSlice(parser: MultipartParser, n: int = 1) {.inline.} =
  inc parser.bSlice.a, n
  inc parser.bSlice.b, n

proc resetSlices(parser: MultipartParser) {.inline.} =
  parser.aSlice = default(Slice[int])
  parser.bSlice = default(Slice[int])

proc skipWhiteSpaceAndIncBSlice(parser: MultipartParser) {.inline.} =
  # skip possible whitespace between value's fields
  if parser.buf[] == ' ':
    parser.buf += 1
    parser.incBSlice

proc processName(parser: MultipartParser) {.inline.} =
  # skip name="
  parser.buf += 6
  parser.incBSlice 6
  while parser.buf[] != '"':
    parser.buf += 1
    parser.bSlice.b += 1
  parser.buf += 1

proc hasMoreField(parser: MultipartParser): bool {.inline.} =
  result = parser.buf[] == ';'
  if result:
    parser.buf += 1

proc processFileName(parser: MultipartParser) =
  # skip filename="
  parser.buf += 10
  parser.incBSlice 10
  while parser.buf[] != '"':
    parser.buf += 1
    parser.bSlice.b += 1
  parser.buf += 1

proc parseParam(parser: MultipartParser;data:openArray[char]){.inline.} =
  # parse http request multipart headers
  debug "dispositionIndex:" & $parser.dispositionIndex
  # skip " and line end
  parser.incBSlice 4
  parser.aSlice.a = parser.bSlice.b 
  parser.aSlice.b = parser.bSlice.b 
  while parser.buf[] != ':':
    parser.buf += 1
    parser.incBSlice
    parser.aSlice.b += 1
  parser.takeASlice
  parser.buf += 1
  parser.incBSlice
  parser.skipWhiteSpaceAndIncBSlice
  if parser.buf[] == '"':
    parser.buf += 1
    parser.incBSlice
    while parser.buf[] != '"':
      parser.buf += 1
      parser.bSlice.b += 1
    parser.buf += 1
    parser.incBSlice
  else:
    while parser.buf[] != '\c' and (parser.buf + 1)[] != '\l' and parser.buf[] != ';':
      if parser.buf[] == '"':
        parser.buf += 1
        parser.incBSlice
        while parser.buf[] != '"':
          parser.buf += 1
          parser.bSlice.b += 1
        parser.buf += 1
        parser.incBSlice
      else:
        parser.buf += 1
        parser.bSlice.b += 1
  case parser.aStr(data):
    of "Content-Type":
      parser.currentDisposition.contentType = parser.bStr(data)
    else:
      # TODO: handle custom headers
      discard
  debug "disposition kind:" & $parser.dispositions[parser.dispositionIndex]

proc toString(str: seq[char]): string =
  result = newStringOfCap(len(str))
  for ch in str:
    add(result, ch)

proc parse*(parser: MultipartParser) {.async.} =

  let boundaryDeli = newStreamSearcher()
  let beginSep = parser.boundaryBegin
  
  let boundaryDeliCallback = proc (isMatch: bool; data: openArray[char]; start: int; e: int;
      isSafeData: bool) {.raises: [CatchableError].} =
    debug "boundaryDeliCallback"
    if start == e : return

    parser.buf = data[start].unsafeAddr
    if isMatch and parser.buf[] == '-' and (parser.buf + 1)[] == '-':
      parser.state = boundaryEnd
      return
    # echo repr data[start ..< e]

    while true:
      debug "boundaryDeliCallback state:", parser.state
      debug "boundaryDeliCallback isMatch:", isMatch
      
      case parser.state
      of boundaryBegin:
        # assert parser.isBoundaryBegin
        # parser.skipBeginTok
        parser.state = disposition
        
      of disposition:
        parser.resetSlices
        parser.skipLineEnd
        parser.incBSlice 2
        # https://www.ietf.org/rfc/rfc1806.txt
        # skip Content-Disposition:
        
        parser.skipContentDispositionFlag
        parser.incBSlice ContentDispoitionFlagLen
        parser.skipWhiteSpaceAndIncBSlice
        # skip form-data;
        parser.skipFormDataFlag
        parser.incBSlice FormDataFlagLen
        parser.skipWhiteSpaceAndIncBSlice

        parser.processName
        if parser.hasMoreField:
          var disposition = ContentDisposition(kind: ContentDispositionKind.file)
          disposition.name = parser.bStr(data[start  ..< e])
          parser.incBSlice # for end quote
          parser.bSlice.a = parser.bSlice.b
          parser.incBSlice # for ;
          parser.incBSlice # next pos
          parser.skipWhiteSpaceAndIncBSlice
          parser.processFileName
          disposition.filename = parser.bStr(data[start  ..< e])
          disposition.filepath = getTempDir() / $genOid()
          disposition.file = openFileStream(disposition.filepath, fmWrite)
          parser.dispositions.add disposition
        else:
          parser.dispositions.add ContentDisposition(kind: ContentDispositionKind.data, name: parser.bStr(data[start  ..< e]))
        parser.skipLineEnd
        if parser.buf[] == '\c' and (parser.buf + 1)[] == '\l':
          parser.skipLineEnd
          parser.preState = disposition
          parser.state = contentBegin
          # content followed
        else:
          # extro meta data
          parser.preState = disposition
          parser.state = extroHeader

      of extroHeader:
        parser.parseParam(data[start ..< e])
        parser.skipLineEnd
        parser.preState = extroHeader
        parser.state = contentBegin
      of contentBegin:
        
        if parser.currentDisposition.kind == ContentDispositionKind.data:
          if isMatch:
            parser.currentDisposition.value.add data[(start + parser.bSlice.b + 4 + 2) ..< e - 2].toString
          else:
            parser.currentDisposition.value.add data[start ..< e].toString
        elif parser.currentDisposition.kind == file:
          if parser.preState == extroHeader:
            let mStart = start + parser.bSlice.b + 2 + 2 + 1
            parser.currentDisposition.file.writeData data[mStart].unsafeAddr, e - mStart
          else:
            if isMatch:
              parser.currentDisposition.file.writeData data[start].unsafeAddr, e - start - 2
            else:
              parser.currentDisposition.file.writeData data[start].unsafeAddr, e - start
        parser.preState = contentBegin
        if isMatch:
          parser.state = contentEnd
        else:
          break
      of contentEnd:
        if parser.currentDisposition.kind == file:
          parser.currentDisposition.file.flush
          try:
            parser.currentDisposition.file.close
          except Exception as e:
            raise newException(IOError, e.msg)

        if parser.remainLen != 0:
          inc parser.dispositionIndex
          parser.preState = contentEnd
          parser.state = disposition
          break
        else:
          parser.preState = contentEnd
          parser.state = boundaryEnd
      of boundaryEnd:
        parser.buf += 2
        break

  boundaryDeli.init(beginSep, boundaryDeliCallback)
  var needed:int
  while not parser.transp.atEof():
    needed = parser.needReadLen
    if parser.read < parser.contentLength:
      await parser.transp.readExactly(parser.src[0].addr, needed)
      parser.read += needed
    else:
      parser.state = boundaryEnd
      break
    {.cast(gcSafe).}:
      discard boundaryDeli.push(parser.src[0 ..< needed])

when isMainModule:
  let a = parseBoundary("""multipart/form-data; boundary="---- next message ----"""")
  doAssert a.i != -1 and a.boundary.len > 0
  let b = parseBoundary("""multipart/form-data;boundary=---- next message ----""")
  doAssert b.i != -1 and b.boundary.len > 0
