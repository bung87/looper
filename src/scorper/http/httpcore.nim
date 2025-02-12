
import tables, strutils, parseutils
import ./httptypes
import std/cookies
import std/strtabs
export httptypes
when not isMainModule:
  import ./httpcommonheaders
  export httpcommonheaders
const HttpDateFormat* = "ddd',' dd MMM yyyy HH:mm:ss 'GMT'"

const
  Http100* = HttpCode(100)
  Http101* = HttpCode(101)
  Http200* = HttpCode(200)
  Http201* = HttpCode(201)
  Http202* = HttpCode(202)
  Http203* = HttpCode(203)
  Http204* = HttpCode(204)
  Http205* = HttpCode(205)
  Http206* = HttpCode(206)
  Http300* = HttpCode(300)
  Http301* = HttpCode(301)
  Http302* = HttpCode(302)
  Http303* = HttpCode(303)
  Http304* = HttpCode(304)
  Http305* = HttpCode(305)
  Http307* = HttpCode(307)
  Http308* = HttpCode(308)
  Http400* = HttpCode(400)
  Http401* = HttpCode(401)
  Http403* = HttpCode(403)
  Http404* = HttpCode(404)
  Http405* = HttpCode(405)
  Http406* = HttpCode(406)
  Http407* = HttpCode(407)
  Http408* = HttpCode(408)
  Http409* = HttpCode(409)
  Http410* = HttpCode(410)
  Http411* = HttpCode(411)
  Http412* = HttpCode(412)
  Http413* = HttpCode(413)
  Http414* = HttpCode(414)
  Http415* = HttpCode(415)
  Http416* = HttpCode(416)
  Http417* = HttpCode(417)
  Http418* = HttpCode(418)
  Http421* = HttpCode(421)
  Http422* = HttpCode(422)
  Http426* = HttpCode(426)
  Http428* = HttpCode(428)
  Http429* = HttpCode(429)
  Http431* = HttpCode(431)
  Http451* = HttpCode(451)
  Http500* = HttpCode(500)
  Http501* = HttpCode(501)
  Http502* = HttpCode(502)
  Http503* = HttpCode(503)
  Http504* = HttpCode(504)
  Http505* = HttpCode(505)

const CRLF* = "\c\L"

func toTitleCase(s: string): string =
  result = newString(len(s))
  var upper = true
  for i in 0..len(s) - 1:
    result[i] = if upper: toUpperAscii(s[i]) else: toLowerAscii(s[i])
    upper = s[i] == '-'

func toCaseInsensitive*(headers: HttpHeaders, s: string): string {.inline.} =
  return toTitleCase(s)

func newHttpHeaders*(): HttpHeaders =
  ## Returns a new ``HttpHeaders`` object. if ``titleCase`` is set to true,
  ## headers are passed to the server in title case (e.g. "Content-Length")
  new result
  result.table = newTable[string, seq[string]]()

func newHttpHeaders*(keyValuePairs:
    openArray[tuple[key: string, val: string]]): HttpHeaders =
  ## Returns a new ``HttpHeaders`` object from an array. if ``titleCase`` is set to true,
  ## headers are passed to the server in title case (e.g. "Content-Length")
  new result
  result.table = newTable[string, seq[string]]()

  for pair in keyValuePairs:
    let key = result.toCaseInsensitive(pair.key)
    {.cast(noSideEffect).}:
      if key in result.table:
        result.table[key].add(pair.val)
      else:
        result.table[key] = @[pair.val]


func `$`*(headers: HttpHeaders): string {.inline.} =
  $headers.table

proc clear*(headers: HttpHeaders) {.inline.} =
  headers.table.clear()

func `[]`*(headers: HttpHeaders, key: string): HttpHeaderValues =
  ## Returns the values associated with the given ``key``. If the returned
  ## values are passed to a procedure expecting a ``string``, the first
  ## value is automatically picked. If there are
  ## no values associated with the key, an exception is raised.
  ##
  ## To access multiple values of a key, use the overloaded ``[]`` below or
  ## to get all of them access the ``table`` field directly.
  {.cast(noSideEffect).}:
    return headers.table[headers.toCaseInsensitive(key)].HttpHeaderValues

converter toString*(values: HttpHeaderValues): string =
  if seq[string](values).len > 0:
    return seq[string](values)[0]

func `[]`*(headers: HttpHeaders, key: string, i: int): string =
  ## Returns the ``i``'th value associated with the given key. If there are
  ## no values associated with the key or the ``i``'th value doesn't exist,
  ## an exception is raised.
  {.cast(noSideEffect).}:
    return headers.table[headers.toCaseInsensitive(key)][i]

proc `[]=`*(headers: HttpHeaders, key, value: string) =
  ## Sets the header entries associated with ``key`` to the specified value.
  ## Replaces any existing values.
  headers.table[headers.toCaseInsensitive(key)] = @[value]

proc `[]=`*(headers: HttpHeaders, key: string, value: seq[string]) =
  ## Sets the header entries associated with ``key`` to the specified list of
  ## values. Replaces any existing values. If ``value`` is empty,
  ## deletes the header entries associated with ``key``.
  if value.len > 0:
    headers.table[headers.toCaseInsensitive(key)] = value
  else:
    headers.table.del(headers.toCaseInsensitive(key))

template hasKeyOrPut*(headers: HttpHeaders, key: string, body) =
  let tKey = headers.toCaseInsensitive(key)
  let hasKey = headers.table.hasKey(tKey)
  if not hasKey:
    headers.table[tKey] = @[body]

proc add*(headers: HttpHeaders, key, value: string) =
  ## Adds the specified value to the specified key. Appends to any existing
  ## values associated with the key.
  let tKey = headers.toCaseInsensitive(key)
  if not headers.table.hasKey(tKey):
    headers.table[tKey] = @[value]
  else:
    headers.table[tKey].add(value)

proc del*(headers: HttpHeaders, key: string) =
  ## Deletes the header entries associated with ``key``
  headers.table.del(headers.toCaseInsensitive(key))

iterator pairs*(headers: HttpHeaders): tuple[key, value: string] =
  ## Yields each key, value pair.
  for k, v in headers.table:
    for value in v:
      yield (k, value)

func contains*(values: HttpHeaderValues, value: string): bool =
  ## Determines if ``value`` is one of the values inside ``values``. Comparison
  ## is performed without case sensitivity.
  for val in seq[string](values):
    if val.toLowerAscii == value.toLowerAscii: return true

func hasKey*(headers: HttpHeaders, key: string): bool =
  return headers.table.hasKey(headers.toCaseInsensitive(key))

func getOrDefault*(headers: HttpHeaders, key: string,
    default = @[""].HttpHeaderValues): HttpHeaderValues =
  ## Returns the values associated with the given ``key``. If there are no
  ## values associated with the key, then ``default`` is returned.
  if headers.hasKey(key):
    return headers.table.getOrDefault(headers.toCaseInsensitive(key)).HttpHeaderValues
  else:
    return default

func len*(headers: HttpHeaders): int {.inline.} = headers.table.len

func parseList(line: string, list: var seq[string], start: int): int =
  var i = 0
  var current = ""
  while start+i < line.len and line[start + i] notin {'\c', '\l'}:
    i += line.skipWhitespace(start + i)
    i += line.parseUntil(current, {'\c', '\l', ','}, start + i)
    list.add(current)
    if start+i < line.len and line[start + i] == ',':
      i.inc # Skip ,
    current.setLen(0)

func parseHeader*(line: string): tuple[key: string, value: seq[string]] =
  ## Parses a single raw header HTTP line into key value pairs.
  ##
  ## Used by ``asynchttpserver`` and ``httpclient`` internally and should not
  ## be used by you.
  result.value = @[]
  var i = 0
  i = line.parseUntil(result.key, ':')
  inc(i) # skip :
  if i < len(line):
    if cmpIgnoreCase(result.key, "cookie") == 0:
      i += line.skipWhitespace(i)
      result.value.add line.substr(i)
    else:
      i += parseList(line, result.value, i)
  elif result.key.len > 0:
    result.value = @[""]
  else:
    result.value = @[]

func `==`*(protocol: tuple[major, minor: int],
           ver: HttpVersion): bool =
  let major =
    case ver
    of HttpVer11, HttpVer10: 1
    of HttpVer20: 2
  let minor =
    case ver
    of HttpVer11: 1
    of HttpVer10: 0
    of HttpVer20: 0
  result = protocol.major == major and protocol.minor == minor

func contains*(methods: set[HttpMethod], x: string): bool =
  return parseEnum[HttpMethod](x) in methods

func `$`*(code: HttpCode): string =
  ## Converts the specified ``HttpCode`` into a HTTP status.
  runnableExamples:
    doAssert($Http404 == "404 Not Found")
  case code.int
  of 100: "100 Continue"
  of 101: "101 Switching Protocols"
  of 200: "200 OK"
  of 201: "201 Created"
  of 202: "202 Accepted"
  of 203: "203 Non-Authoritative Information"
  of 204: "204 No Content"
  of 205: "205 Reset Content"
  of 206: "206 Partial Content"
  of 300: "300 Multiple Choices"
  of 301: "301 Moved Permanently"
  of 302: "302 Found"
  of 303: "303 See Other"
  of 304: "304 Not Modified"
  of 305: "305 Use Proxy"
  of 307: "307 Temporary Redirect"
  of 308: "308 Permanent Redirect"
  of 400: "400 Bad Request"
  of 401: "401 Unauthorized"
  of 403: "403 Forbidden"
  of 404: "404 Not Found"
  of 405: "405 Method Not Allowed"
  of 406: "406 Not Acceptable"
  of 407: "407 Proxy Authentication Required"
  of 408: "408 Request Timeout"
  of 409: "409 Conflict"
  of 410: "410 Gone"
  of 411: "411 Length Required"
  of 412: "412 Precondition Failed"
  of 413: "413 Request Entity Too Large"
  of 414: "414 Request-URI Too Long"
  of 415: "415 Unsupported Media Type"
  of 416: "416 Requested Range Not Satisfiable"
  of 417: "417 Expectation Failed"
  of 418: "418 I'm a teapot"
  of 421: "421 Misdirected Request"
  of 422: "422 Unprocessable Entity"
  of 426: "426 Upgrade Required"
  of 428: "428 Precondition Required"
  of 429: "429 Too Many Requests"
  of 431: "431 Request Header Fields Too Large"
  of 451: "451 Unavailable For Legal Reasons"
  of 500: "500 Internal Server Error"
  of 501: "501 Not Implemented"
  of 502: "502 Bad Gateway"
  of 503: "503 Service Unavailable"
  of 504: "504 Gateway Timeout"
  of 505: "505 HTTP Version Not Supported"
  else: $(int(code))

func `==`*(a, b: HttpCode): bool {.borrow.}

func is2xx*(code: HttpCode): bool {.inline.} =
  ## Determines whether ``code`` is a 2xx HTTP status code.
  code.int in 200 .. 299

func is3xx*(code: HttpCode): bool {.inline.} =
  ## Determines whether ``code`` is a 3xx HTTP status code.
  code.int in 300 .. 399

func is4xx*(code: HttpCode): bool {.inline.} =
  ## Determines whether ``code`` is a 4xx HTTP status code.
  code.int in 400 .. 499

func is5xx*(code: HttpCode): bool {.inline.} =
  ## Determines whether ``code`` is a 5xx HTTP status code.
  code.int in 500 .. 599

func `$`*(httpMethod: HttpMethod): string =
  return (system.`$`(httpMethod))[4 .. ^1].toUpperAscii()

proc generateHeaders*(headers: HttpHeaders,
                       code: HttpCode = Http200,
                       ver: HttpVersion = HttpVer11
                     ): string =
  # generate meta line and headers
  result = $ver & " " & $code & CRLF
  for key, val in headers:
    add(result, key & ": " & val & CRLF)

  add(result, CRLF)

proc cookies*(headers: HttpHeaders): StringTableRef =
  result = parseCookies headers.getOrDefault("Cookie")

proc getCookie*(headers: HttpHeaders, key: string): string = headers.cookies.getOrDefault(key)

when isMainModule:
  from sequtils import map, concat
  from re import re, split, findAll
  import macros, os
  const TPL = """

proc $1*(headers: HttpHeaders, value: string) {.inline.} =
  headers.table["$2"] = @[value]

proc $1*(headers: HttpHeaders, value: seq[string]) {.inline.} =
  if value.len > 0:
    headers.table["$2"] = value
  else:
    headers.table.del("$2")

proc $1*(headers: HttpHeaders): HttpHeaderValues {.inline.} =
  if headers.table.hasKey("$2"):
    return headers.table["$2"].HttpHeaderValues

"""
  proc splitByDelimiter(key: string): seq[string] =
    return split(key, re"(-|_|/|\s)")
  proc camelize(key: string): string =
    let parts = key.splitByDelimiter
    let capitalizedParts = map(parts[1..parts.len - 1], capitalizeAscii)
    return join(concat([parts[0..0], capitalizedParts]))

  template genCommonHttpHeaderProcs =
    var f = open(currentSourcePath.parentDir / "httpcommonheaders.nim", fmWrite)
    f.writeLine "## generated through ./httpcore"
    f.writeLine "{.push hint[Name]: off.}"
    f.writeLine "import ./httptypes"
    f.writeLine "import tables"
    for x in ["Accept", "WWW-Authenticate", "X-Frame-Options", "Content-Encoding", "Last-Modified", "Accept-Ranges",
        "Accept-Charset", "Accept-Encoding", "Accept-Language", "Accept-Datetime", "Authorization", "Cache-Control",
        "Server", "Connection", "Cookie", "Content-Length",
        "Content-MD5", "Content-Type", "Date", "Expect",
        "From", "Host", "If-Match", "If-Modified-Since", "If-None-Match", "If-Range", "If-Unmodified-Since",
        "Max-Forwards", "Pragma", "Proxy-Authorization", "Range", "Referer", "TE", "Upgrade", "User-Agent", "Via", "Warning"]:
      let key = toTitleCase(x)
      let temp = TPL % [camelize x, key]
      f.write temp
    f.writeLine "{.pop.}"
    f.close

  genCommonHttpHeaderProcs()
