import net, strutils, sequtils, urlly, parseutils, base64, os,
  math, random, ./httpcore, tables, std/monotimes
import chronos, ./futurestream, asyncresponse, multipart
import nativesockets
export asyncresponse
export multipart
export httpcore except parseHeader
import logging
from exts/resumable import newResumableKeys
import oids
when defined(ssl):
  import chronos / streams/tlsstream

type R = results.Result[int, string]

when defined(windows):
  import winlean
const headerLimit = 10_000

type
  ProgressChangedProc*[ReturnType] =
    proc (total, progress, speed: BiggestInt):
      ReturnType {.closure, gcsafe.}

type
  Proxy* = ref object
    url*: typeof(Url()[])
    auth*: string

type
  AsyncHttpClient* = ref object
    connected: bool
    currentURL: typeof(Url()[]) ## Where we are currently connected.
    headers*: HttpHeaders       ## Headers to send in requests.
    maxRedirects: Natural       ## Maximum redirects, set to ``0`` to disable.
    userAgent: string
    timeout*: int               ## Only used for blocking HttpClient for now.
    proxy: Proxy
    ## ``nil`` or the callback to call when request progress changes.
    onProgressChanged*: ProgressChangedProc[Future[void]]
    when defined(ssl):
      tlsstream: TLSAsyncStream
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    contentTotal: BiggestInt
    contentProgress: BiggestInt
    oneSecondProgress: BiggestInt
    lastProgressReport: int64
    transp: StreamTransport
    getBody: bool               ## When `false`, the body is never read in requestAux.
    bodyStream: FutureStream[string]
    parseBodyFut: Future[void]
    buf: array[net.BufferSize, char]
    logger: ConsoleLogger

const defUserAgent* = "Nim httpclient/" & NimVersion

proc log(client: AsyncHttpClient, level: Level, args: varargs[string]) =
  try:
    client.log level, args
  except CatchableError:
    discard

proc newProxy*(url: string, auth = ""): Proxy =
  ## Constructs a new ``TProxy`` object.
  result = Proxy(url: parseUrl(url)[], auth: auth)

proc redirection(status: string): bool =
  const redirectionNRs = ["301", "302", "303", "307", "308"]
  for i in items(redirectionNRs):
    if status.startsWith(i):
      return true

proc getNewLocation(client: AsyncHttpClient, lastURL: string, headers: HttpHeaders): string =
  result = headers.getOrDefault"Location"
  if result == "": client.log lvlError, "location header expected"
  # Relative URLs. (Not part of the spec, but soon will be.)
  let r = parseUrl(result)
  if r.hostname == "" and r.path != "":
    var parsed = parseUrl(lastURL)
    parsed.path = r.path
    parsed.query = r.query
    parsed.fragment = r.fragment
    result = $ parsed[]

proc generateHeaders(requestUrl: typeof(Url()[]), httpMethod: string, headers: HttpHeaders,
                     proxy: Proxy): string =
  # GET
  let upperMethod = httpMethod.toUpperAscii()
  result = upperMethod
  result.add ' '

  if proxy.isNil or requestUrl.scheme == "https":
    # /path?query
    if not requestUrl.path.startsWith("/"): result.add '/'
    result.add(requestUrl.path)
    if requestUrl.query.len > 0:
      result.add("?")
      result.add requestUrl.query.mapIt(it[0] & "=" & it[1]).join("&")
  else:
    # Remove the 'http://' from the URL for CONNECT requests for TLS connections.
    var modifiedUrl = requestUrl
    if requestUrl.scheme == "https": modifiedUrl.scheme = ""
    result.add($modifiedUrl)

  # HTTP/1.1\c\l
  result.add(" HTTP/1.1" & CRLF)

  # Host header.
  if not headers.hasKey("Host"):
    if requestUrl.port == "":
      add(result, "Host: " & requestUrl.hostname & CRLF)
    else:
      add(result, "Host: " & requestUrl.hostname & ":" & requestUrl.port & CRLF)

  # Connection header.
  if not headers.hasKey("Connection"):
    add(result, "Connection: Keep-Alive" & CRLF)

  # Proxy auth header.
  if not proxy.isNil and proxy.auth != "":
    let auth = base64.encode(proxy.auth)
    add(result, "Proxy-Authorization: basic " & auth & CRLF)

  for key, val in headers:
    add(result, key & ": " & val & CRLF)

  add(result, CRLF)


proc sendFile(transp: StreamTransport, fname: string) {.async.} =
  var handle = 0
  var size = int(getFileSize(fname))
  var fhandle: File = open(fname)
  when defined(windows):
    handle = int(getOsFileHandle(fhandle))
  else:
    handle = int(getFileHandle(fhandle))
  var checksize = await transp.writeFile(handle, 0'u, size)
  doAssert(checksize == size)
  close(fhandle)

proc sendFile(transp: StreamTransport,
              entry: MultipartEntry) {.async.} =
  await sendFile(transp, entry.content)

proc newAsyncHttpClient*(userAgent = defUserAgent, maxRedirects = 5,
                         proxy: Proxy = nil,
                         headers = newHttpHeaders()): AsyncHttpClient =
  ## Creates a new AsyncHttpClient instance.
  ##
  ## ``userAgent`` specifies the user agent that will be used when making
  ## requests.
  ##
  ## ``maxRedirects`` specifies the maximum amount of redirects to follow,
  ## default is 5.
  ##
  ##
  ## ``proxy`` specifies an HTTP proxy to use for this HTTP client's
  ## connections.
  ##
  ## ``headers`` specifies the HTTP Headers.
  new result
  result.headers = headers
  result.userAgent = userAgent
  result.maxRedirects = maxRedirects
  result.proxy = proxy
  result.timeout = -1 # TODO
  result.onProgressChanged = nil
  result.bodyStream = newFutureStream[string]("newAsyncHttpClient")
  result.getBody = true
  result.logger = newConsoleLogger()

proc close*(client: AsyncHttpClient) {.async.} =
  ## Closes any connections held by the HTTP client.
  if client.connected:
    await client.transp.closeWait()
    await client.reader.closeWait()
    await client.writer.closeWait()
    client.connected = false

proc reportProgress(client: AsyncHttpClient,
                    progress: BiggestInt) {.async.} =
  client.contentProgress += progress
  client.oneSecondProgress += progress
  if (getMonoTime().ticks - client.lastProgressReport).nanoseconds.seconds > 1:
    if not client.onProgressChanged.isNil:
      await client.onProgressChanged(client.contentTotal,
                                     client.contentProgress,
                                     client.oneSecondProgress)
      client.oneSecondProgress = 0
      client.lastProgressReport = getMonoTime().ticks


proc recvFull(client: AsyncHttpClient, size: int, timeout: int,
              keep: bool): Future[R] {.async.} =
  ## Ensures that all the data requested is read and returned.
  var readLen = 0
  while true:
    if client.reader.atEof(): break
    if size == readLen: break
    let remainingSize = size - readLen
    let sizeToRecv = min(remainingSize, net.BufferSize)
    var hasError = false
    try:
      await client.reader.readExactly(client.buf[0].addr, sizeToRecv)
    except AsyncStreamIncompleteError as e:
      client.log lvlError, $AsyncStreamIncompleteError & ":" & e.msg
      result.err e.msg
      hasError = true
      await client.close()
    except AsyncStreamReadError as e:
      client.log lvlError, $type(e) & ":" & e.msg
      result.err e.msg
      hasError = true
      await client.close()
    except CatchableError as e:
      client.log lvlError, $type(e) & ":" & e.msg
      result.err e.msg
      hasError = true
      await client.close()
    if not hasError:
      readLen.inc(sizeToRecv)
      if keep:
        await client.bodyStream.write(cast[string](client.buf[0 ..< sizeToRecv]))

      await reportProgress(client, sizeToRecv)
  return R.ok readLen

proc parseChunks(client: AsyncHttpClient): Future[void]
                 {.async.} =
  while true:
    var chunkSize = 0
    var chunkSizeStr = await client.reader.readLine()
    var i = 0
    if chunkSizeStr == "":
      try:
        client.log lvlError, "Server terminated connection prematurely"
      except CatchableError:
        discard
    while i < chunkSizeStr.len:
      case chunkSizeStr[i]
      of '0'..'9':
        chunkSize = chunkSize shl 4 or (ord(chunkSizeStr[i]) - ord('0'))
      of 'a'..'f':
        chunkSize = chunkSize shl 4 or (ord(chunkSizeStr[i]) - ord('a') + 10)
      of 'A'..'F':
        chunkSize = chunkSize shl 4 or (ord(chunkSizeStr[i]) - ord('A') + 10)
      of ';':
        # http://tools.ietf.org/html/rfc2616#section-3.6.1
        # We don't care about chunk-extensions.
        break
      else:
        client.log lvlError, "Invalid chunk size: " & chunkSizeStr
      inc(i)
    if chunkSize <= 0:
      discard await recvFull(client, 2, client.timeout, false) # Skip \c\L
      break
    var r = await recvFull(client, chunkSize, client.timeout, true)
    var bytesRead: int
    if r.isOk():
      bytesRead = r.get()
    else:
      client.log lvlError, "Server terminated connection prematurely"
    if bytesRead != chunkSize:
      client.log lvlError, "Server terminated connection prematurely"

    let r2 = await recvFull(client, 2, client.timeout, false) # Skip \c\L
    if r2.isOk:
      bytesRead = r.get()
    else:
      client.log lvlError, "Server terminated connection prematurely"

    if bytesRead != 2:
      client.log lvlError, "Server terminated connection prematurely"

    # Trailer headers will only be sent if the request specifies that we want
    # them: http://tools.ietf.org/html/rfc2616#section-3.6.1

proc parseBody(client: AsyncHttpClient, headers: HttpHeaders,
               httpVersion: string): Future[void] {.async.} =
  # Reset progress from previous requests.
  client.contentTotal = 0
  client.contentProgress = 0
  client.oneSecondProgress = 0
  client.lastProgressReport = MonoTime().ticks

  assert(not client.bodyStream.finished)

  if headers.getOrDefault"Transfer-Encoding" == "chunked":
    await parseChunks(client)
  else:
    # -REGION- Content-Length
    # (http://tools.ietf.org/html/rfc2616#section-4.4) NR.3
    var contentLengthHeader = headers.getOrDefault"Content-Length"
    if contentLengthHeader != "":
      var length = contentLengthHeader.parseInt()
      client.contentTotal = length
      var r: R
      if length > 0:
        r = await client.recvFull(length, client.timeout, true)
        var recvLen: int
        if r.isOk():
          recvLen = r.get()
        else:
          client.log lvlError, "Got disconnected while trying to read body."
        if recvLen == 0:
          await client.close()
          client.log lvlError, "Got disconnected while trying to read body."
          return
        if recvLen != length:
          client.log lvlError, "Received length doesn't match expected length. Wanted " &
                  $length & " got " & $recvLen
          return
    else:
      # (http://tools.ietf.org/html/rfc2616#section-4.4) NR.4 TODO

      # -REGION- Connection: Close
      # (http://tools.ietf.org/html/rfc2616#section-4.4) NR.5
      let implicitConnectionClose =
        httpVersion == "1.0" #or
                             # This doesn't match the HTTP spec, but it fixes issues for non-conforming servers.
                             #(httpVersion == "1.1" and headers.getOrDefault"Connection" == "")
      if headers.getOrDefault"Connection" == "close" or implicitConnectionClose:
        while true:
          let r = await client.recvFull(net.BufferSize, client.timeout, true)
          var recvLen: int
          if r.isOk:
            recvLen = r.get
          else:
            client.log lvlError, "Got disconnected while trying to read body."
            return
          if recvLen != net.BufferSize:
            client.log lvlError, "Got disconnected while trying to read body."
            await client.close()
            break

  client.bodyStream.complete()

  # If the server will close our connection, then no matter the method of
  # reading the body, we need to close our socket.
  if headers.getOrDefault"Connection" == "close":
    await client.close()

proc parseResponse*(client: AsyncHttpClient,
                   getBody: bool): Future[AsyncResponse]
                   {.async.} =
  new result
  var parsedStatus = false
  var linei = 0
  var fullyRead = false
  var line = ""
  result.headers = newHttpHeaders()
  while not client.reader.atEof():
    linei = 0
    try:
      line = await client.reader.readLine()
    except CatchableError:
      line = ""
      await sleepAsync(0.milliseconds)
      continue
    if line == "":
      fullyRead = true
      break
    if not parsedStatus:
      # Parse HTTP version info and status code.
      var le = skip(line, "HTTP/", linei)
      if le <= 0:
        client.log lvlError, "invalid http version, `" & line & "`"
      inc(linei, le)
      le = skip(line, "1.1", linei)
      if le > 0: result.version = "1.1"
      else:
        le = skip(line, "1.0", linei)
        if le <= 0:
          client.log lvlError, "unsupported http version"
        result.version = "1.0"
      inc(linei, le)
      # Status code
      linei.inc skipWhitespace(line, linei)
      result.status = line[linei .. ^1]
      parsedStatus = true
    else:
      # Parse headers
      var name = ""
      if line.len > 0:
        var le = parseUntil(line, name, ':', linei)
        if le <= 0: client.log lvlError, "invalid headers"
        inc(linei, le)
        if line[linei] != ':': client.log lvlError, "invalid headers"
        inc(linei) # Skip :

        result.headers.add(name, line[linei .. ^1].strip())
        if result.headers.len > headerLimit:
          client.log lvlError, "too many headers"
  if not fullyRead:
    client.log lvlError, "Connection was closed before full request has been made"
  result.bodyStream = newFutureStream[string]("parseResponse") #client.bodyStream
  if getBody and result.code != Http204:
    client.bodyStream = result.bodyStream
    assert(client.parseBodyFut.isNil or client.parseBodyFut.finished)
    client.parseBodyFut = parseBody(client, result.headers, result.version)
    await client.parseBodyFut
    # client.parseBodyFut.addCallback do():
    #     if client.parseBodyFut.failed:
    #       client.bodyStream.fail(client.parseBodyFut.error)

proc newConnection(client: AsyncHttpClient,
                   url: typeof(Url()[])) {.async.} =
  if client.currentURL == default(typeof(Url()[])) or client.currentURL.hostname !=
      url.hostname or client.currentURL.scheme != url.scheme or
      client.currentURL.port != url.port or
      (not client.connected):
    # Connect to proxy if specified
    let connectionUrl =
      if client.proxy.isNil: url else: client.proxy.url

    let isSsl = connectionUrl.scheme.toLowerAscii() == "https"

    if isSsl and not defined(ssl):
      raise newException(HttpRequestError,
        "SSL support is not available. Cannot connect over SSL. Compile with -d:ssl to enable.")

    if client.connected:
      await client.close()
      client.connected = false

    let port =
      if connectionUrl.port == "":
        if isSsl:
          443
        else:
          80
      else: connectionUrl.port.parseInt
    client.transp = await connect(initTAddress(connectionUrl.hostname, port))
    when defined(ssl):
      if isSsl:
        let flags: set[TLSFlags] = {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName}
        client.tlsstream = newTLSClientAsyncStream(newAsyncStreamReader(client.transp), newAsyncStreamWriter(
            client.transp), connectionUrl.hostname, flags = flags) # flags = flags
        client.reader = client.tlsstream.reader
        client.writer = client.tlsstream.writer
        await client.tlsstream.handshake()
      else:
        client.reader = newAsyncStreamReader(client.transp)
        client.writer = newAsyncStreamWriter(client.transp)
    else:
      client.reader = newAsyncStreamReader(client.transp)
      client.writer = newAsyncStreamWriter(client.transp)
    # If need to CONNECT through proxy
    if isSsl and not client.proxy.isNil:
      when defined(ssl):
        # Pass only host:port for CONNECT
        var connectUrl = Url()
        connectUrl.hostname = url.hostname
        connectUrl.port = if url.port != "": url.port else: "443"

        let proxyHeaderString = generateHeaders(connectUrl[], $HttpConnect,
            newHttpHeaders(), client.proxy)
        await client.writer.write(proxyHeaderString)
        let proxyResp = await parseResponse(client, false)

        if not proxyResp.status.startsWith("200"):
          raise newException(HttpRequestError,
                            "The proxy server rejected a CONNECT request, " &
                            "so a secure connection could not be established.")
      else:
        raise newException(HttpRequestError,
        "SSL support is not available. Cannot connect over SSL. Compile with -d:ssl to enable.")

    # May be connected through proxy but remember actual URL being accessed
    client.currentURL = url
    client.connected = true

proc readFileSizes(client: AsyncHttpClient,
                   multipart: MultipartData) {.async.} =
  for entry in multipart.entries.mitems():
    if not entry.isFile: continue
    if not entry.isStream:
      entry.fileSize = entry.content.len
      continue

    # TODO: look into making getFileSize work with async
    entry.fileSize = getFileSize(entry.content)

proc getBoundary(p: MultipartData): string =
  if p == nil or p.entries.len == 0: return
  while true:
    result = $rand(int.high)
    for i, entry in p.entries:
      if result in entry.content: break
      elif i == p.entries.high: return

proc format(client: AsyncHttpClient,
            multipart: MultipartData): Future[seq[string]] {.async.} =
  let bound = getBoundary(multipart)
  client.headers["Content-Type"] = "multipart/form-data; boundary=" & bound

  await client.readFileSizes(multipart)

  var length: int64
  for entry in multipart.entries:
    result.add(format(entry, bound) & CRLF)
    if entry.isFile:
      length += entry.fileSize + CRLF.len

  result.add "--" & bound & "--"

  for s in result: length += s.len
  client.headers["Content-Length"] = $length

proc override(fallback, override: HttpHeaders): HttpHeaders =
  # Right-biased map union for `HttpHeaders`
  if override.isNil:
    return fallback

  result = newHttpHeaders()
  # Copy by value
  result.table[] = fallback.table[]
  for k, vs in override.table:
    result[k] = vs

proc requestAux(client: AsyncHttpClient, url, httpMethod: string,
                body = "", headers: HttpHeaders = nil,
                multipart: MultipartData = nil): Future[AsyncResponse]
                {.async.} =
  # Helper that actually makes the request. Does not handle redirects.
  let requestUrl = parseUrl(url)[]
  if requestUrl.scheme == "":
    raise newException(ValueError, "No uri scheme supplied.")

  var data: seq[string]
  if multipart != nil and multipart.entries.len > 0:
    data = await client.format(multipart)
  else:
    client.headers["Content-Length"] = $body.len

  # if not client.parseBodyFut.isNil:
  #   # let the current operation finish before making another request
  #   await client.parseBodyFut
  #   client.parseBodyFut = nil
  await newConnection(client, requestUrl)
  let newHeaders = client.headers.override(headers)
  if not newHeaders.hasKey("user-agent") and client.userAgent.len > 0:
    newHeaders["User-Agent"] = client.userAgent

  let headerString = generateHeaders(requestUrl, httpMethod, newHeaders,
                                     client.proxy)
  await client.writer.write(headerString)
  if data.len > 0:
    var buffer: string
    for i, entry in multipart.entries:
      buffer.add data[i]
      if not entry.isFile: continue
      if buffer.len > 0:
        await client.writer.write(buffer)
        buffer.setLen(0)
      if entry.isStream:
        await client.transp.sendFile(entry)
      else:
        await client.writer.write(entry.content)
      buffer.add CRLF
    # send the rest and the last boundary
    await client.writer.write(buffer & data[^1])
  elif body.len > 0:
    await client.writer.write(body)
  let getBody = httpMethod.toLowerAscii() notin ["head", "connect"] and
                client.getBody
  result = await parseResponse(client, getBody)

proc request*(client: AsyncHttpClient, url: string,
              httpMethod: string, body = "", headers: HttpHeaders = nil,
              multipart: MultipartData = nil): Future[AsyncResponse]
              {.async.} =
  ## Connects to the hostname specified by the URL and performs a request
  ## using the custom method string specified by ``httpMethod``.
  ##
  ## Connection will be kept alive. Further requests on the same ``client`` to
  ## the same hostname will not require a new connection to be made. The
  ## connection can be closed by using the ``close`` procedure.
  ##
  ## This procedure will follow redirects up to a maximum number of redirects
  ## specified in ``client.maxRedirects``.
  ##
  ## You need to make sure that the ``url`` doesn't contain any newline
  ## characters. Failing to do so will raise ``AssertionDefect``.
  doAssert(not url.contains({'\c', '\L'}), "url shouldn't contain any newline characters")

  result = await client.requestAux(url, httpMethod, body, headers, multipart)

  var lastURL = url
  for i in 1..client.maxRedirects:
    if result.status.redirection():
      let redirectTo = getNewLocation(client, lastURL, result.headers)
      # Guarantee method for HTTP 307: see https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/307
      var meth = if result.status == "307": httpMethod else: "GET"
      result = await client.requestAux(redirectTo, meth, body, headers, multipart)
      lastURL = redirectTo

proc sendJson*(client: AsyncHttpClient, url: string,
              httpMethod = HttpPost, body = "",
                  headers: HttpHeaders = newHttpHeaders([(key: "Content-Type",
                  val: "application/json")])): Future[AsyncResponse]
              {.async.} =
  result = await client.requestAux(url, $httpMethod, body, headers, nil)

proc request*(client: AsyncHttpClient, url: string,
              httpMethod = HttpGet, body = "", headers: HttpHeaders = nil,
              multipart: MultipartData = nil): Future[AsyncResponse]
              {.async.} =
  ## Connects to the hostname specified by the URL and performs a request
  ## using the method specified.
  ##
  ## Connection will be kept alive. Further requests on the same ``client`` to
  ## the same hostname will not require a new connection to be made. The
  ## connection can be closed by using the ``close`` procedure.
  ##
  ## When a request is made to a different hostname, the current connection will
  ## be closed.
  result = await request(client, url, $httpMethod, body, headers, multipart)

proc responseContent(resp: AsyncResponse): Future[string] {.async.} =
  ## Returns the content of a response as a string.
  ##
  ## A ``HttpRequestError`` will be raised if the server responds with a
  ## client error (status code 4xx) or a server error (status code 5xx).
  if resp.code.is4xx or resp.code.is5xx:
    raise newException(HttpRequestError, resp.status)
  else:
    return await resp.bodyStream.readAll()

proc head*(client: AsyncHttpClient,
          url: string): Future[AsyncResponse] {.async.} =
  ## Connects to the hostname specified by the URL and performs a HEAD request.
  ##
  ## This procedure uses httpClient values such as ``client.maxRedirects``.
  result = await client.request(url, HttpHead)

proc get*(client: AsyncHttpClient,
          url: string): Future[AsyncResponse] {.async.} =
  ## Connects to the hostname specified by the URL and performs a GET request.
  ##
  ## This procedure uses httpClient values such as ``client.maxRedirects``.
  result = await client.request(url, HttpGet)

proc getContent*(client: AsyncHttpClient,
                 url: string): Future[string] {.async.} =
  ## Connects to the hostname specified by the URL and returns the content of a GET request.
  let resp = await get(client, url)
  return await responseContent(resp)

proc delete*(client: AsyncHttpClient,
             url: string): Future[AsyncResponse] {.async.} =
  ## Connects to the hostname specified by the URL and performs a DELETE request.
  ## This procedure uses httpClient values such as ``client.maxRedirects``.
  result = await client.request(url, HttpDelete)

proc deleteContent*(client: AsyncHttpClient,
                    url: string): Future[string] {.async.} =
  ## Connects to the hostname specified by the URL and returns the content of a DELETE request.
  let resp = await delete(client, url)
  return await responseContent(resp)

proc post*(client: AsyncHttpClient, url: string, body = "",
           multipart: MultipartData = nil): Future[AsyncResponse]
           {.async.} =
  ## Connects to the hostname specified by the URL and performs a POST request.
  ## This procedure uses httpClient values such as ``client.maxRedirects``.
  result = await client.request(url, $HttpPost, body, multipart = multipart)

proc postContent*(client: AsyncHttpClient, url: string, body = "",
                  multipart: MultipartData = nil): Future[string]
                  {.async.} =
  ## Connects to the hostname specified by the URL and returns the content of a POST request.
  let resp = await post(client, url, body, multipart)
  return await responseContent(resp)

proc put*(client: AsyncHttpClient, url: string, body = "",
          multipart: MultipartData = nil): Future[AsyncResponse]
          {.async.} =
  ## Connects to the hostname specified by the URL and performs a PUT request.
  ## This procedure uses httpClient values such as ``client.maxRedirects``.
  result = await client.request(url, $HttpPut, body, multipart = multipart)

proc putContent*(client: AsyncHttpClient, url: string, body = "",
                 multipart: MultipartData = nil): Future[string] {.async.} =
  ## Connects to the hostname specified by the URL andreturns the content of a PUT request.
  let resp = await put(client, url, body, multipart)
  return await responseContent(resp)

proc patch*(client: AsyncHttpClient, url: string, body = "",
            multipart: MultipartData = nil): Future[AsyncResponse]
            {.async.} =
  ## Connects to the hostname specified by the URL and performs a PATCH request.
  ## This procedure uses httpClient values such as ``client.maxRedirects``.
  result = await client.request(url, $HttpPatch, body, multipart = multipart)

proc patchContent*(client: AsyncHttpClient, url: string, body = "",
                   multipart: MultipartData = nil): Future[string]
                  {.async.} =
  ## Connects to the hostname specified by the URL and returns the content of a PATCH request.
  let resp = await patch(client, url, body, multipart)
  return await responseContent(resp)

proc writeFromStream*(f: File, fs: FutureStream[string]) {.async.} =
  ## Reads data from the specified future stream until it is completed.
  ## The data which is read is written to the file immediately and
  ## freed from memory.
  ##
  ## This procedure is perfect for saving streamed data to a file without
  ## wasting memory.
  while true:
    let (hasValue, value) = await fs.read()
    if hasValue:
      # await f.write(value)
      f.write(value)
    else:
      break

proc downloadFileEx(client: AsyncHttpClient,
                    url, filename: string): Future[void] {.async.} =
  ## Downloads ``url`` and saves it to ``filename``.
  client.getBody = false
  let resp = await client.get(url)

  client.bodyStream = newFutureStream[string]("downloadFile")
  # var file = openAsync(filename, fmWrite)
  var file = open(filename, fmWrite)
  # Let `parseBody` write response data into client.bodyStream in the
  # background.
  asyncSpawn parseBody(client, resp.headers, resp.version)
  # The `writeFromStream` proc will complete once all the data in the
  # `bodyStream` has been written to the file.
  await file.writeFromStream(client.bodyStream)
  file.close()

  if resp.code.is4xx or resp.code.is5xx:
    raise newException(HttpRequestError, resp.status)

proc downloadFile*(client: AsyncHttpClient, url: string,
                   filename: string): Future[void] =
  result = newFuture[void]("downloadFile")
  try:
    result = downloadFileEx(client, url, filename)
  except CatchableError as exc:
    result.fail(exc)
  finally:
    result.addCallback(
      proc (arg: pointer = nil) {.closure, gcsafe.} = client.getBody = true
    )

proc uploadResumable*(client: AsyncHttpClient, filepath: string, url: string,
              httpMethod = HttpPost, chunkSize = 1*1024*1024, headers: HttpHeaders = nil,
              resumableKeys = newResumableKeys()): Future[void]
              {.async.} =
  var parsedUrl = parseUrl(url)
  let totalSize = int(getFileSize(filepath))
  parsedUrl.query.add (encodeUrlComponent(resumableKeys.totalSize), encodeUrlComponent($totalSize))
  let identifier = $genOid()
  parsedUrl.query.add (encodeUrlComponent(resumableKeys.identifier), encodeUrlComponent(identifier))
  let (path, fName, ext) = splitFile(filepath)
  let fileName = fName & ext
  parsedUrl.query.add (encodeUrlComponent(resumableKeys.filename), encodeUrlComponent(fileName))
  parsedUrl.query.add (encodeUrlComponent(resumableKeys.relativePath), encodeUrlComponent(path))
  var tseq = newSeq[Future[AsyncResponse]]()
  let maxOffset = max(round(totalSize / chunkSize), 1).int
  var i = 0
  var bin: File
  if not open(bin, filepath): return
  var buf = newSeq[uint](chunkSize)
  parsedUrl.query[encodeUrlComponent(resumableKeys.totalChunks)] = encodeUrlComponent($maxOffset)
  while i < maxOffset:
    parsedUrl.query[encodeUrlComponent(resumableKeys.chunkIndex)] = encodeUrlComponent($(i + 1))
    var readBytes = bin.readBuffer(buf[0].addr, chunkSize)
    parsedUrl.query[encodeUrlComponent(resumableKeys.currentChunkSize)] = encodeUrlComponent($readBytes)
    tseq.add client.request($(parsedUrl[]), httpMethod, cast[string](buf[0 ..< readBytes]), headers)
    if readBytes != chunkSize: break
    inc i
  let a = allFutures(tseq)
  a.addCallback proc (arg: pointer = nil) {.closure, gcsafe.} = close(bin)
  await a

