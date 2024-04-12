
##
## This module implements a stream http server
## depends on chronos
##
## Copyright (c) 2020 Bung

import chronos except Moment
import mofuparser
import npeg/codegen
import urlencodedparser, multipartparser, acceptparser, rangeparser, oids, httpform, httpdate, httpcore, router,
    netunit, httperror
import std/mimetypes
import urlly
include constant
import std / [os, streams, options, strformat, json, sequtils, parseutils, strutils, macros, macrocache]
import ./ rxnim / rxnim
from std/times import Time, parseTime, utc, `<`, now, `$`, initDuration
import zippy
from httprequest import Request
import ../ scorpermacros

when defined(ssl):
  import chronos / streams/tlsstream
else:
  type
    TLSVersion* {.pure.} = enum
      TLS10 = 0x0301, TLS11 = 0x0302, TLS12 = 0x0303

    TLSFlags* {.pure.} = enum
      NoVerifyHost,         # Client: Skip remote certificate check
      NoVerifyServerName,   # Client: Skip Server Name Indication (SNI) check
      EnforceServerPref,    # Server: Enforce server preferences
      NoRenegotiation,      # Server: Reject renegotiations ImpRequests
      TolerateNoClientAuth, # Server: Disable strict client authentication
      FailOnAlpnMismatch    # Server: Fail on application protocol mismatch
    TLSSessionCache* = ref object
      # storage: seq[byte]
      # context: SslSessionCacheLru
import chronos / sendfile

when defined(windows):
  import winlean
const MethodNeedsBody = {HttpPost, HttpPut, HttpConnect, HttpPatch}

type
  ImpRequest = ref object of typeof(Request()[])
    transp: StreamTransport
    buf: array[HttpRequestBufferSize, char]
    contentLength: BiggestUInt # as RFC no limit
    contentType: string
    server: Scorper
    prefix: string
    parsedJson: Option[JsonNode]
    parsedForm: Option[Form]
    parsed: bool               # indicate http body parsed
    rawBody: Option[string]
    responded: bool
    when defined(ssl):
      tlsStream: TLSAsyncStream
    reader: AsyncStreamReader
    writer: AsyncStreamWriter

  ScorperCallback* = proc (req: Request): Future[void] {.closure, gcsafe.}
  CbKind {.pure.} = enum
    cb, router
  Scorper* = ref object of StreamServer
    case kind: CbKind
    of CbKind.cb:
      callback: ScorperCallback
    of CbKind.router:
      router: Router[ScorperCallback]
    maxBody: int
    mimeDb: MimeDB
    httpParser: MofuParser
    privAccpetParser: Parser[char, seq[tuple[mime: string, q: float, extro: int, typScore: int]]]
    when defined(ssl):
      secureFlags: set[TLSFlags]
      tlsPrivateKey: TLSPrivateKey
      tlsCertificate: TLSCertificate
      tlsMinVersion: TLSVersion
      tlsMaxVersion: TLSVersion
    isSecurity: bool
    logSub: Observer[string]

converter toImpRequest*(a: Request): ImpRequest = cast[ImpRequest](a)

proc `$`*(r: ImpRequest): string =
  var j = newJObject()
  j["url"] = % $r.url
  j["method"] = % $r.meth
  j["hostname"] = % r.hostname
  j["headers"] = %* r.headers.table
  result = $j

func len*(r: ImpRequest): BiggestUInt = r.contentLength

proc formatCommon*(r: ImpRequest, status: HttpCode, size: int): string =
  # LogFormat "%h %l %u %t \"%r\" %>s %b" common
  # LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-agent}i\"" combined
  let remoteUser = os.getEnv("REMOTE_USER", "-")
  result = fmt"""{r.hostname} - {remoteUser} {$now()} "{r.meth} {r.url.path} HTTP/{r.protocol.major}.{r.protocol.minor}" {status} {size}"""

var serverDate {.threadvar.}: string

proc genericHeaders(headers = newHttpHeaders()): lent HttpHeaders {.tags: [TimeEffect].} =
  ## genericHeaders contains Date,X-Frame-Options
  # Date: https://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.18
  headers.Date serverDate
  headers.XFrameOptions "SAMEORIGIN"
  when HttpServer.len > 0:
    headers.Server HttpServer
  return headers

func getExt*(req: ImpRequest, mime: string): string {.inline.} =
  result = req.server.mimeDb.getExt(mime, default = "")

func getMimetype*(req: ImpRequest, ext: string): string {.inline.} =
  result = req.server.mimeDb.getMimetype(ext, default = "")

macro acceptMime*(req: ImpRequest, ext: untyped, headers: HttpHeaders, body: untyped) =
  ## Responds to the req respect client's accept
  ## Automatically set headers content type to corresponding accept mime, when none matched, change it to other mime yourself
  result = quote do:
    var mimes = newSeq[tuple[mime: string, q: float, extro: int, typScore: int]]()
    let accept: string = req.headers.getOrDefault("accept", @["text/plain"].HttpHeaderValues)
    var r: MatchResult[char]
    try:
      {.cast(gcsafe).}:
        r = req.server.privAccpetParser.match(accept, mimes)
    except CatchableError, Exception:
      await req.respError(Http500, headers)
      return
    var ext {.inject.}: string
    if r.ok:
      for item in mimes.mitems:
        ext = req.getExt(item.mime)
        headers.ContentType item.mime
        `body`
    else:
      `body`

func gzip*(req: ImpRequest): bool {.inline.} = GzipEnable and req.headers.getOrDefault("Accept-Encoding").contains("gzip")

template devLog(req: ImpRequest, content: untyped) =
  when not defined(release):
    try:
      req.server.logSub.next(`content`)
    except CatchableError:
      discard

template handleCompress(needCompress: bool; content: string; ctn: var string; length: var int) =
  if needCompress:
    headers.ContentEncoding "gzip"
    ctn = compress(content, BestSpeed, dfGzip)
    length = ctn.len
  else:
    when defined(gcArc) or defined(gcOrc):
      ctn = move(content)
    else:
      shallowCopy(ctn, content)
    length = originalLen

proc resp*(req: ImpRequest, content: sink string,
              headers: HttpHeaders = newHttpHeaders(), code: HttpCode = Http200): Future[void] {.async.} =
  ## Responds to the req with the specified ``HttpCode``, headers and
  ## content.
  # If the headers did not contain a Content-Length use our own
  if req.responded == true:
    return
  let originalLen = content.len
  let needCompress = req.gzip() and originalLen >= gzipMinLength
  var ctn: string
  var length: int
  handleCompress(needCompress, content, ctn, length)
  let flen = $length
  headers.hasKeyOrPut("Content-Length"):
    flen
  headers.hasKeyOrPut("Date"):
    serverDate
  when HttpServer.len > 0:
    headers.hasKeyOrPut("Server"):
      HttpServer
  var msg = generateHeaders(headers, code)
  msg.add(ctn)
  await req.writer.write(msg)
  req.devLog(req.formatCommon(code, length))
  req.responded = true

proc resp*(req: ImpRequest, content: sink string,
              headers: seq[(string, string)], code: HttpCode = Http200): Future[void] {.inline, async.} =
  await resp(req, content, headers.newHttpHeaders())

proc respError*(req: ImpRequest, code: HttpCode, content: sink string, headers = newHttpHeaders()): Future[
    void] {.async:(raises:[]).} =
  ## Responds to the req with the specified ``HttpCode``.
  if req.responded == true:
    return
  var headers = genericHeaders(headers)
  let originalLen = content.len
  let needCompress = req.gzip() and originalLen >= gzipMinLength
  var ctn: string
  var length: int
  handleCompress(needCompress, content, ctn, length)
  let flen = $length
  headers.hasKeyOrPut("Content-Length"):
    flen
  var msg = generateHeaders(headers, code)
  msg.add(ctn)
  await req.writer.write(msg)
  req.devLog(req.formatCommon(code, length))
  req.responded = true

proc respError*(req: ImpRequest, code: HttpCode, content: sink string,
              headers: seq[(string, string)]): Future[void] {.inline, async: (raises:[]).} =
  await respError(req, code, content, headers.newHttpHeaders())

proc respError*(req: ImpRequest, code: HttpCode, headers = newHttpHeaders()): Future[void] {.async:(raises: []).} =
  ## Responds to the req with the specified ``HttpCode``.
  if req.responded == true:
    return
  var headers = genericHeaders(headers)
  var content = $code
  let originalLen = content.len
  let needCompress = req.gzip() and content.len >= gzipMinLength
  var ctn: string
  var length: int
  handleCompress(needCompress, content, ctn, length)
  let flen = $length
  headers.hasKeyOrPut("Content-Length"):
    flen
  var msg = generateHeaders(headers, code)
  msg.add(content)
  await req.writer.write(msg)
  req.devLog(req.formatCommon(code, length))
  req.responded = true

proc respError*(req: ImpRequest, code: HttpCode,
              headers: seq[(string, string)]): Future[void] {.inline, async.} =
  await respError(req, code, headers.newHttpHeaders())

func pairParam(x: tuple[key: string, value: string]): string =
  result = x[0] & '=' & '"' & x[1] & '"'

proc respBasicAuth*(req: ImpRequest, scheme = "Basic", realm = "Scorper", params: seq[tuple[key: string,
    value: string]] = @[], code = Http401): Future[void] {.async.} =
  ## Responds to the req with the specified ``HttpCode``.
  if req.responded == true:
    return
  var headers = genericHeaders()
  let extro = if params.len > 0: "," & params.map(pairParam).join(",") else: ""
  headers.WWWAuthenticate &"{scheme} realm={realm}" & extro
  let msg = generateHeaders(headers, code)
  await req.writer.write(msg)
  req.devLog(req.formatCommon(code, 0))
  req.responded = true

proc respStatus*(req: ImpRequest, code: HttpCode, ver = HttpVer11): Future[void] {.async.} =
  if req.responded == true:
    return
  await req.writer.write($ver & " " & $code & "Date: " & httpDate() & CRLF & CRLF)
  req.devLog(req.formatCommon(code, 0))
  req.responded = true

proc respStatus*(req: ImpRequest, code: HttpCode, msg: string, ver = HttpVer11): Future[void] {.async.} =
  if req.responded == true:
    return
  await req.writer.write($ver & " " & $code.int & msg & "Date: " & httpDate() & CRLF & CRLF)
  req.devLog(req.formatCommon(code, 0))
  req.responded = true

template writeFileFull(req: ImpRequest, file: File, size: int) =
  const bufSize = 8192
  if size < bufSize:
    await req.writer.write(file.readAll)
  else:
    var buf {.noinit.}: array[bufSize, char]
    while true:
      var readBytes = file.readBuffer(buf[0].addr, bufSize)
      await req.writer.write(buf.addr, readBytes)
      if readBytes != bufSize: break

proc writeFile(req: ImpRequest, fname: string, size: int): Future[void] {.async.} =
  var handle = 0
  var file: File
  try:
    file = open(fname)
  except CatchableError as e:
    try:
      req.server.logSub.next(e.msg)
    except CatchableError:
      discard
    return
  when defined(windows):
    handle = int(getOsFileHandle(file))
  else:
    handle = int(getFileHandle(file))
  if req.server.isSecurity:
    writeFileFull(req, file, size)
  else:
    var s = size
    when compiles(sendfile(req.writer.tsource.fd.FileHandle.int, handle, 0, s)):
      discard sendfile(req.writer.tsource.fd.FileHandle.int, handle, 0, s)
    else:
      writeFileFull(req, file, size)
  close(file)

template writeFileStream(req: ImpRequest, fname: string, offset: int, size: int) =
  const bufSize = 8192
  var buf {.noinit.}: array[bufSize, char]
  var totalRead = 0
  let fs = openFileStream(fname, fmRead, bufSize)
  fs.setPosition(offset)
  let rlen = min(size, bufSize)
  while true:
    var readBytes = fs.readData(buf[0].addr, rlen)
    if readBytes == 0:
      break
    await req.writer.write(buf[0].addr, readBytes)
    totalRead.inc readBytes
    if totalRead == rlen:
      break
  fs.close

proc writePartialFile(req: ImpRequest, fname: string, ranges: seq[tuple[starts: int, ends: int]], meta: Option[tuple[
    info: FileInfo, headers: HttpHeaders]], boundary: string, mime: string) {.async.} =
  let fullSize = meta.unsafeGet.info.size.int
  var handle = 0
  var file: File
  if not req.server.isSecurity:
    try:
      file = open(fname)
    except CatchableError as e:
      try:
        req.server.logSub.next(e.msg)
      except Defect, CatchableError:
        await req.respError(Http500)
      return
    when defined(windows):
      handle = int(getOsFileHandle(file))
    else:
      handle = int(getFileHandle(file))
  for b in ranges:
    await req.writer.write(boundary & CRLF)
    await req.writer.write(fmt"Content-Type: {mime}" & CRLF)
    if b.ends > 0:
      await req.writer.write(fmt"Content-Range: bytes {b.starts}-{b.ends}/{fullSize}" & CRLF & CRLF)
    elif b.ends == 0:
      await req.writer.write(fmt"Content-Range: bytes {b.starts}-{fullSize - 1}/{fullSize}" & CRLF & CRLF)
    else:
      await req.writer.write(fmt"Content-Range: bytes {b.ends}/{fullSize}" & CRLF & CRLF)
    let offset = if b.ends >= 0: b.starts else: fullSize + b.ends
    let size = if b.ends > 0: b.ends - b.starts + 1 elif b.ends == 0: fullSize - b.starts else: abs(b.ends)
    if req.server.isSecurity:
      try:
        writeFileStream(req, fname, offset, size)
      except Defect, CatchableError:
        await req.respError(Http500)
        return
    else:
      var written = size
      when compiles(sendfile(req.writer.tsource.fd.FileHandle.int, handle, offset, written)):
        let ret = sendfile(req.writer.tsource.fd.FileHandle.int, handle, offset, written)
      else:
        try:
          writeFileStream(req, fname, offset, size)
        except Defect, CatchableError:
          await req.respError(Http500)
          return
  await req.writer.write(CRLF & boundary & "--")
  if handle != 0:
    close(file)

proc fileGuard(req: ImpRequest, filepath: string): Future[Option[FileInfo]] {.async.} =
  # If-Modified-Since: https://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.25
  # The result of a req having both an If-Modified-Since header field and either an If-Match or an If-Unmodified-Since header fields is undefined by this specification.
  if not fileExists(filepath):
    return none(FileInfo)
  var info: FileInfo
  try:
    info = getFileInfo(filepath)
  except CatchableError:
    return none(FileInfo)
  if fpOthersRead notin info.permissions:
    await req.respError(Http403)
    return none(FileInfo)
  if req.headers.hasKey("If-Modified-Since"):
    var ifModifiedSince: times.Time
    try:
      ifModifiedSince = parseTime(req.headers["If-Modified-Since"], HttpDateFormat, utc())
    except CatchableError:
      await req.respError(Http400)
      return none(FileInfo)
    if info.lastWriteTime == ifModifiedSince:
      await req.respStatus(Http304)
      return none(FileInfo)
  elif req.headers.hasKey("If-Unmodified-Since"):
    var ifUnModifiedSince: times.Time
    try:
      ifUnModifiedSince = parseTime(req.headers["If-Unmodified-Since"], HttpDateFormat, utc())
    except CatchableError:
      await req.respError(Http400)
      return none(FileInfo)
    if info.lastWriteTime > ifUnModifiedSince:
      await req.respStatus(Http412)
      return none(FileInfo)
  return some(info)

proc fileMeta(req: ImpRequest, filepath: string): Future[Option[tuple[info: FileInfo, headers: HttpHeaders]]]{.async, inline.} =
  let info = await fileGuard(req, filepath)
  if not info.isSome():
    return none(tuple[info: FileInfo, headers: HttpHeaders])
  var size = info.get.size
  var headers = genericHeaders()
  headers.ContentLength $size
  headers.LastModified httpDate(info.get.lastWriteTime)
  return some((info: info.get, headers: headers))

func calcContentLength(ranges: seq[tuple[starts: int, ends: int]], size: int): int =
  for b in ranges:
    if b[1] > 0:
      result = result + b[1] - b[0] + 1
    elif b[1] == 0:
      result = result + size - b[0]
    else:
      result = result + abs(b[1])

proc sendFile*(req: ImpRequest, filepath: string, extroHeaders: HttpHeaders = newHttpHeaders()) {.gcsafe, async.} =
  ## send file for display
  # Last-Modified: https://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.29
  var meta = await fileMeta(req, filepath)
  if meta.isNone:
    await req.respError(Http404)
    return
  for key, val in extroHeaders:
    meta.unsafeGet.headers[key] = val
  var (_, _, ext) = splitFile(filepath)
  let mime = req.server.mimeDb.getMimetype(ext)
  let rangeImpRequest = req.headers.hasKey("Range")
  var parseRangeOk = false
  var ranges = newSeq[tuple[starts: int, ends: int]]()
  if rangeImpRequest:
    let parser = rangeParser()
    let rng: string = req.headers["Range"]
    var r: MatchResult[char]
    try:
      {.cast(gcsafe).}:
        r = parser.match(rng, ranges)
    except Exception:
      discard
    parseRangeOk = r.ok
  if not rangeImpRequest or not parseRangeOk:
    meta.unsafeGet.headers.ContentType mime
    var msg = generateHeaders(meta.unsafeGet.headers, Http200)
    await req.writer.write(msg)
    await req.writeFile(filepath, meta.unsafeGet.info.size.int)
    req.devLog(req.formatCommon(Http200, meta.unsafeGet.info.size.int))
  else:
    let boundary = "--" & $genOid()
    meta.unsafeGet.headers.ContentType "multipart/byteranges; " & boundary
    var contentLength = calcContentLength(ranges, meta.unsafeGet.info.size.int)
    for b in ranges:
      contentLength = contentLength + len(boundary & CRLF)
      contentLength = contentLength + len(fmt"Content-Type: {mime}" & CRLF)
      if b.ends > 0:
        contentLength = contentLength + len(fmt"Content-Range: bytes {b.starts}-{b.ends}/{meta.unsafeGet.info.size}" &
            CRLF & CRLF)
      elif b.ends == 0:
        contentLength = contentLength + len(fmt"Content-Range: bytes {b.starts}-{meta.unsafeGet.info.size - 1}/{meta.unsafeGet.info.size}" &
            CRLF & CRLF)
      else:
        contentLength = contentLength + len(fmt"Content-Range: bytes {b.ends}/{meta.unsafeGet.info.size}" & CRLF & CRLF)
      contentLength = contentLength + len(CRLF & boundary & "--")
      meta.unsafeGet.headers.ContentLength $contentLength
      var msg = generateHeaders(meta.unsafeGet.headers, Http206)
      await req.writer.write(msg)
      await req.writePartialFile(filepath, ranges, meta, boundary, mime)
      req.devLog(req.formatCommon(Http206, contentLength))

proc sendDownload*(req: ImpRequest, filepath: string) {.async.} =
  ## send file directly without mime type , downloaded file name same as original
  # Last-Modified: https://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.29
  var meta = await fileMeta(req, filepath)
  if meta.isNone:
    await req.respError(Http404)
    return
  meta.unsafeGet.headers.ContentType "application/x-download"
  var msg = generateHeaders(meta.unsafeGet.headers, Http200)
  await req.writer.write(msg)
  await req.writeFile(filepath, meta.unsafeGet.info.size.int)
  req.devLog(req.formatCommon(Http200, meta.unsafeGet.info.size.int))
  req.responded = true

proc sendAttachment*(req: ImpRequest, filepath: string, asName: string = "") {.async.} =
  let filename = if asName.len == 0: filepath.extractFilename else: asName
  let encodedFilename = &"filename*=UTF-8''{encodeUrlComponent(filename)}"
  let extroHeaders = newHttpHeaders({
    "Content-Disposition": &"""attachment;filename="{filename}";{encodedFilename}"""
  })
  await sendFile(req, filepath, extroHeaders)
  req.responded = true

proc hasSuffix(s: string): bool =
  let sLen = s.len - 1
  var i = sLen
  while i != 0:
    if s[i] == '.':
      return true
    dec i

proc serveStatic*(req: Request) {.async.} =
  ## Relys on `StaticDir` environment variable
  if req.meth != HttpGet and req.meth != HttpHead:
    await req.respError(Http405)
    return
  var relPath: string
  try:
    relPath = decodeUrlComponent(req.url.path.relativePath(cast[ImpRequest](req).prefix))
  except Exception:
    discard
  if not hasSuffix(relPath):
    relPath = relPath / "index.html"
  let absPath = absolutePath(os.getEnv("StaticDir") / relPath)
  if not absPath.fileExists:
    await req.respError(Http404)
    return
  if req.meth == HttpHead:
    var meta = await fileMeta(req, absPath)
    if meta.isNone:
      await req.respError(Http404)
      return
    var (_, _, ext) = splitFile(absPath)
    let mime = cast[ImpRequest](req).server.mimeDb.getMimetype(ext)
    meta.unsafeGet.headers.ContentType mime
    meta.unsafeGet.headers.AcceptRanges "bytes"
    var msg = generateHeaders(meta.unsafeGet.headers, Http200)
    discard await cast[ImpRequest](req).transp.write(msg)
    cast[ImpRequest](req).responded = true
    return
  await req.sendFile(absPath)
  cast[ImpRequest](req).responded = true


proc json*(req: ImpRequest): Future[JsonNode] {.async.} =
  if req.parsedJson.isSome:
    return req.parsedJson.unSafeGet
  var str = newString(req.contentLength)
  result = newJNull()
  try:
    await req.reader.readExactly(str[0].addr, req.contentLength.int)
  except AsyncStreamIncompleteError:
    await req.respStatus(Http400, ContentLengthMismatch)
    req.parsedJson = some(result)
    req.parsed = true
    return result
  try:
    result = parseJson(str)
  except CatchableError as e:
    raise newHttpError(Http400, e.msg)
  req.parsedJson = some(result)
  req.parsed = true

proc body*(req: ImpRequest): Future[string] {.async.} =
  if req.rawBody.isSome:
    return req.rawBody.unSafeGet
  result = newString(req.contentLength)
  try:
    await req.reader.readExactly(result[0].addr, req.contentLength.int)
  except AsyncStreamIncompleteError:
    await req.respStatus(Http400, ContentLengthMismatch)
  req.rawBody = some(result)
  req.parsed = true

proc stream*(req: ImpRequest): AsyncStreamReader =
  doAssert req.transp.closed == false
  req.reader

proc form*(req: ImpRequest): Future[Form] {.async.} =
  if req.parsedForm.isSome:
    return req.parsedForm.unSafeGet
  result = newForm()
  case req.contentType:
    of "application/x-www-form-urlencoded":
      var parser = newUrlEncodedParser(req.transp, req.buf.addr, req.contentLength.int)
      var parsed = await parser.parse()
      for (key, value) in parsed:
        let v = if value.len > 0: decodeUrlComponent(value) else: ""
        let k = decodeUrlComponent key
        result.data.add ContentDisposition(kind: ContentDispositionKind.data, name: k, value: v)
    else:
      if req.contentType.len > 0:
        var parsed: tuple[i: int, boundary: string]
        try:
          parsed = parseBoundary(req.contentType)
        except BoundaryMissingError as e:
          await req.respError(Http400, e.msg)
          return
        except BoundaryInvalidError as e:
          await req.respError(Http400, e.msg)
          return
        var parser = newMultipartParser(parsed.boundary, req.transp, req.buf.addr, req.contentLength.int)
        try:
          await parser.parse()
        except BodyIncompleteError as e:
          await req.respError(Http400, e.msg)
          return
        if parser.state == boundaryEnd:
          for disp in parser.dispositions:
            if disp.kind == ContentDispositionKind.data:
              result.data.add disp
            elif disp.kind == ContentDispositionKind.file:
              result.files.add disp
        else:
          try:
            req.server.logSub.next("form parse error: " & $parser.state)
          except CatchableError:
            discard
      else:
        discard
  req.parsedForm = some(result)
  req.parsed = true

proc postCheck(req: ImpRequest): Future[int]{.async, inline.} =
  if req.meth in MethodNeedsBody and req.parsed == false:
    result = await req.reader.consume(req.contentLength.int)

proc defaultErrorHandle(req: ImpRequest, err: ref Exception | HttpError; headers = newHttpHeaders()){.async: (raises: []), gcsafe.} =
  if req.responded:
    return
  let code = when err is HttpError: err.code.HttpCode else: Http500 #
  acceptMime(req, ext, headers):
    case ext
    of "json":
      var s: string
      toUgly(s, %* {"error": err.msg})
      await req.respError(code, s, headers)
    of "js":
      let cbName: string = req.url.query["callback"]
      var s: string
      toUgly(s, %* {"error": err.msg})
      await req.respError(code, fmt"""{cbName}({s});""", headers)
    of "html": await req.respError(code, err.msg, headers)
    of "txt": await req.respError(code, err.msg, headers)
    else:
      headers.ContentType "text/plain"
      await req.respError(Http400, err.msg, headers)

template tryHandle(req: ImpRequest, fut: untyped, keep: var bool) =
  mixin defaultErrorHandle
  try:
    await chronos.wait(fut, chronos.seconds(TimeOut))
  except AsyncTimeoutError:
    if not req.responded:
      let err = newHttpError(408.HttpCode)
      var headers = {"Connection": "close"}.newHttpHeaders()
      await req.defaultErrorHandle(err, headers)
      keep = false
  except HttpError as err:
    if not req.responded:
      await req.defaultErrorHandle(err)
  except Exception:
    if not req.responded:
      let err = getCurrentException()
      await req.defaultErrorHandle(err)

proc processRequest(
  scorper: Scorper,
  req: ImpRequest,
  isSecurity: static[bool]
): Future[bool] {.async.} =
  req.responded = false
  req.parsed = false
  req.parsedJson = none(JsonNode)
  req.parsedForm = none(Form)
  req.headers.clear()
  # receivce untill http header end
  # note: headers field name is case-insensitive, field value is case sensitive
  const HeaderSep = @[byte('\c'), byte('\L'), byte('\c'), byte('\L')]
  var count: int
  try:
    count = await req.reader.readUntil(req.buf[0].addr, len(req.buf), sep = HeaderSep)
  except AsyncStreamIncompleteError:
    return true
  except AsyncStreamLimitError:
    await req.respStatus(Http400, BufferLimitExceeded)
    return false
  except AsyncStreamError as e:
    await req.respStatus(Http400, e.msg)
    return false
  # Headers
  let headerEnd = scorper.httpParser.parseHeader(addr req.buf[0], req.buf.len)
  if headerEnd == -1:
    await req.respError(Http400)
    return true
  scorper.httpParser.toHttpHeaders(req.headers)
  case scorper.httpParser.getMethod
    of "GET": req.meth = HttpGet
    of "POST": req.meth = HttpPost
    of "HEAD": req.meth = HttpHead
    of "PUT": req.meth = HttpPut
    of "DELETE": req.meth = HttpDelete
    of "PATCH": req.meth = HttpPatch
    of "OPTIONS": req.meth = HttpOptions
    of "CONNECT": req.meth = HttpConnect
    of "TRACE": req.meth = HttpTrace
    else:
      await req.respError(Http501)
      return true

  let path = scorper.httpParser.getPath()
  const prefix = "http" & (when isSecurity: "s" else: "") & "://"
  try:
    req.url = parseUrl(prefix & req.hostname & path)[]
  except ValueError as e:
    scorper.logSub.next(e.msg)
    asyncSpawn req.respError(Http400)
    return true
  case scorper.httpParser.major[]:
    of '1':
      req.protocol.major = 1
    of '2':
      req.protocol.major = 2
    else:
      discard
  case scorper.httpParser.minor[]:
    of '0':
      req.protocol.minor = 0
    of '1':
      req.protocol.minor = 1
    else:
      discard
  if req.protocol == HttpVer20:
    await req.respStatus(Http505)
    return false

  if req.meth == HttpPost:
    # Check for Expect header
    if req.headers.hasKey("Expect"):
      if "100-continue" in req.headers["Expect"]:
        await req.respStatus(Http400)
      else:
        await req.respStatus(Http417)

  # Read the body
  # - Check for Content-length header
  if unlikely(req.meth in MethodNeedsBody):
    if req.headers.hasKey("Content-Length"):
      try:
        discard parseBiggestUInt(req.headers["Content-Length"], req.contentLength)
      except ValueError:
        await req.respStatus(Http400, "Invalid Content-Length.")
        return true
      if req.contentLength.int > scorper.maxBody:
        await req.respStatus(Http413)
        return false
      if req.headers.hasKey("Content-Type"):
        req.contentType = req.headers["Content-Type"]
    else:
      await req.respStatus(Http411)
      return true
  # Call the user's callback.
  var keep = true
  case scorper.kind
  of CbKind.cb:
    handlePreProcessMiddlewares(req)
    tryHandle(req, scorper.callback(req), keep)
    if not keep:
      return false
    discard await postCheck(req)
  of CbKind.router:
    let matched = scorper.router.match($req.meth, req.url.path)
    if matched.success:
      req.params = matched.route.params[]
      req.prefix = matched.route.prefix
      handlePreProcessMiddlewares(req)
      tryHandle(req, matched.handler(req), keep)
      if not keep:
        return false
      discard await postCheck(req)
    else:
      await req.respError(Http404)

  if "upgrade" in req.headers.getOrDefault("connection"):
    return false

  # The req has been served, from this point on returning `true` means the
  # connection will not be closed and will be kept in the connection pool.

  # Persistent connections
  if (req.protocol == HttpVer11 and
      cmpIgnoreCase(req.headers.getOrDefault("connection"), "close") != 0) or
     (req.protocol == HttpVer10 and
      cmpIgnoreCase(req.headers.getOrDefault("connection"), "keep-alive") == 0):
    # In HTTP 1.1 we assume that connection is persistent. Unless connection
    # header states otherwise.
    # In HTTP 1.0 we assume that the connection should not be persistent.
    # Unless the connection header states otherwise.
    return true
  else:
    return false

template processClientImpl(isSecurity: bool): proc (server: StreamServer, transp: StreamTransport) {.async.} = 
  proc processClient(server: StreamServer, transp: StreamTransport) {.async.} =
    var req = ImpRequest()
    req.headers = newHttpHeaders()
    req.server = cast[Scorper](server)
    req.transp = transp
    try:
      req.hostname = $req.transp.localAddress
    except TransportError:
      discard
    try:
      req.ip = $req.transp.remoteAddress
    except TransportError:
      discard

    when defined(ssl):
      when isSecurity:
        req.tlsStream =
          newTLSServerAsyncStream(req.transp.newAsyncStreamReader, req.transp.newAsyncStreamWriter,
                                  req.server.tlsPrivateKey,
                                  req.server.tlsCertificate,
                                  minVersion = req.server.tlsMinVersion,
                                  maxVersion = req.server.tlsMaxVersion,
                                  flags = req.server.secureFlags)
        req.reader = req.tlsStream.reader
        req.writer = req.tlsStream.writer
        await handshake(req.tlsStream)
      else:
        req.reader = req.transp.newAsyncStreamReader
        req.writer = req.transp.newAsyncStreamWriter
    else:
      req.reader = req.transp.newAsyncStreamReader
      req.writer = req.transp.newAsyncStreamWriter

    while not transp.atEof():
      let retry = await processRequest(req.server, req, isSecurity)
      handlePostProcessMiddlewares(req)
      if not retry:
        await req.reader.closeWait
        await req.writer.closeWait
        await transp.closeWait
        break
  processClient

proc logSubOnNext(v: string) =
  echo v

template initSecurityScorper(scorper: var Scorper; secureFlags: set[TLSFlags]; privateKey, certificate: string;
    tlsMinVersion, tlsMaxVersion: TLSVersion) =
  scorper.isSecurity = true
  scorper.secureFlags = secureFlags
  scorper.tlsPrivateKey = TLSPrivateKey.init(privateKey)
  scorper.tlsCertificate = TLSCertificate.init(certificate)
  scorper.tlsMinVersion = tlsMinVersion
  scorper.tlsMaxVersion = tlsMaxVersion

proc newScorperMimetypes(): MimeDB {.inline.} =
  result = newMimetypes()
  result.register(ext = "jsonp", mimetype = "application/javascript")
  return result

template initScorper(server: Scorper, isSecurity: static[bool]) =
  server.privAccpetParser = accpetParser()
  server.httpParser = MofuParser()
  var pipeContinuation: proc (udata: pointer) {.gcsafe, raises: [].}
  const Du = chronos.microseconds(1000)
  pipeContinuation= proc (udata: pointer) {.gcsafe, raises: [].} =
    serverDate = httpDate()
    discard setTimer(Moment.fromNow(Du),
                            pipeContinuation, nil)
  serverDate = httpDate()
  discard setTimer(Moment.fromNow(Du),
                            pipeContinuation, nil)
  var onError = proc(error: Exception): void =
    debugEcho $error
  var onCompleted = proc(): void =
    debugEcho "done"
  server.logSub = newObserver[string](logSubOnNext, onError, onCompleted)
  case server.kind
  of CbKind.router:
    server.router.compress()
  of CbKind.cb:
    discard
  when not defined(release):
    var obs = newObservable[string]()
    try:
      discard subscribe[string](obs, server.logSub)
    except CatchableError:
      discard
  try:
    server.logSub.next("Scorper serve at http" & (when isSecurity: "s" else: "") & "://" & $server.local)
  except CatchableError:
    discard

proc serve*(address: string,
            callback: ScorperCallback,
            flags: set[ServerFlags] = {ReuseAddr},
            maxBody = 8.Mb,
            isSecurity: static[bool] = false,
            privateKey: string = "",
            certificate: string = "",
            secureFlags: set[TLSFlags] = {},
            tlsMinVersion = TLSVersion.TLS11,
            tlsMaxVersion = TLSVersion.TLS12,
            cache: TLSSessionCache = nil,
            ) {.async.} =
  var server = Scorper(kind: CbKind.cb)
  server.mimeDb = newScorperMimetypes()
  server.callback = callback
  server.maxBody = maxBody
  let address = initTAddress(address)
  server = cast[Scorper](createStreamServer(address, processClientImpl(isSecurity), flags, child = cast[StreamServer](server)))
  server.initScorper(isSecurity)
  when defined(ssl):
    when isSecurity:
      server.initSecurityScorper(secureFlags, privateKey, certificate, tlsMinVersion, tlsMaxVersion)
  server.start()

  await server.join()

proc setHandler*(self: Scorper, handler: ScorperCallback) {.inline, raises: [].} =
  case self.kind
  of CbKind.cb:
    self.callback = handler
  else:
    discard

proc newScorper*(address: string, handler: ScorperCallback | Router[ScorperCallback] = default(ScorperCallback),
                flags: set[ServerFlags] = {ReuseAddr},
                maxBody = 8.Mb,
                isSecurity: static[bool] = false,
                privateKey: string = "",
                certificate: string = "",
                secureFlags: set[TLSFlags] = {},
                tlsMinVersion = TLSVersion.TLS11,
                tlsMaxVersion = TLSVersion.TLS12,
                cache: TLSSessionCache = nil,
                ): Scorper =
  when handler is ScorperCallback:
    result = Scorper(kind: CbKind.cb)
    result.callback = handler
  elif handler is Router[ScorperCallback]:
    result = Scorper(kind: CbKind.router)
    result.router = handler
  result.mimeDb = newScorperMimetypes()
  result.maxBody = maxBody
  let address = initTAddress(address)
  result = cast[Scorper](createStreamServer(address, processClientImpl(isSecurity), flags, child = cast[StreamServer](result)))
  result.initScorper(isSecurity)
  when defined(ssl):
    when isSecurity:
      result.initSecurityScorper(secureFlags, privateKey, certificate, tlsMinVersion, tlsMaxVersion)

func isClosed*(server: Scorper): bool =
  server.status == ServerStatus.Closed

