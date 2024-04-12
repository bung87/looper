include ./constant
import chronos,ptr_math

type
  UrlEncodedParserState* = enum
    nameBegin, nameEnd, valueBegin, valueEnd, allEnd
  UrlEncodedParser* = ref object
    buf: ptr char
    src: ptr array[HttpRequestBufferSize, char]
    transp: StreamTransport
    contentLength: int
    read: int
    state*: UrlEncodedParserState
    aSlice: Slice[int] # store name,value pair indexes
    bSlice: Slice[int]
    tmpRead: int

proc newUrlEncodedParser*(transp: StreamTransport, src: ptr array[HttpRequestBufferSize, char],
    contentLength: int): UrlEncodedParser =
  new result
  result.transp = transp
  result.src = src
  result.buf = src[0].addr
  result.contentLength = contentLength

proc remainLen(parser: UrlEncodedParser): int {.inline.} =
  parser.contentLength - parser.read

proc needReadLen(parser: UrlEncodedParser): int {.inline.} =
  min(parser.remainLen, HttpRequestBufferSize)

proc readOnce(parser: UrlEncodedParser): Future[int] {.async.} =
  result = await parser.transp.readOnce(parser.src[0].addr, nbytes = parser.needReadLen)
  parser.buf = parser.src[0].addr

proc resetSlices(parser: UrlEncodedParser) {.inline.} =
  parser.aSlice = default(Slice[int])
  parser.bSlice = default(Slice[int])

proc aStr(parser: UrlEncodedParser): string {.inline.} =
  parser.aSlice.b -= 1
  cast[string](parser.src[parser.aSlice])

proc bStr(parser: UrlEncodedParser): string {.inline.} =
  parser.bSlice.b -= 1
  cast[string](parser.src[parser.bSlice])

template debug(a: varargs[untyped]) =
  when defined(DebugUrlEncodedParser):
    echo a

template `-`[T](p: ptr T, p2: ptr T): int =
  cast[int](p) - cast[int](p2)

proc processChar(parser: UrlEncodedParser, o: var seq[tuple[key, value: string]]) =
  var name, value: string
  var old = parser.buf
  while true:
    case parser.state:
      of nameBegin:
        debug "nameBegin"
        while parser.buf[] != '=':
          parser.buf += 1
          inc parser.aSlice.b
        parser.state = nameEnd
      of nameEnd:
        parser.bSlice.a = parser.aSlice.b + 1
        parser.bSlice.b = parser.aSlice.b + 1
        name = parser.aStr
        debug "name:" & name
        if parser.buf[] == '=':
          parser.buf += 1
          parser.state = valueBegin
      of valueBegin:
        debug "value begin"
        while parser.buf[] != '&':
          if parser.buf - old < parser.tmpRead:
            parser.buf += 1
            inc parser.bSlice.b
          else:
            break
        parser.aSlice.a = parser.bSlice.b + 1
        parser.aSlice.b = parser.bSlice.b + 1
        parser.state = valueEnd
      of valueEnd:
        value = parser.bStr
        debug "value:" & value
        o.add (key: name, value: value)
        if parser.buf[] == '&':
          parser.buf += 1
          parser.state = nameBegin
        else:
          parser.state = allEnd
      of allEnd:
        debug "allEnd"
        break

proc parse*(parser: UrlEncodedParser): Future[seq[tuple[key, value: string]]] {.async.} =
  while not parser.transp.atEof():
    if parser.needReadLen == 0:
      break
    parser.tmpRead = await parser.readOnce
    parser.read += parser.tmpRead
    parser.processChar(result)
