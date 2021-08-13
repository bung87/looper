<!---
Motivation:
Write examples/usage api as I try to better understand the available api of Scorper that can also be added to the main docs
--->

![scorper](artwork/scorper.png)

---

- [Examples](#examples)
  - [Serve w/ Callback - Hello World](#serve-w-callback---hello-world)
  - [Scorper w/ Router - Hello World, Goodbye World](#scorper-w-router---hello-world-goodbye-world)
  - [Route & Mount pragma](#route--mount-pragma)
  - [Header magic](#header-magic)
  - [Response HttpCodes](#response-httpcodes)
  - [Basic Authentication](#basic-authentication)
  - [Template responses](#template-responses)
  - [Request JSON](#request-json)
  - [Request Route Params/Query](#request-route-paramsquery)
  - [URL Encoding/Decoding](#url-encodingdecoding)
  - [Form Decoding](#form-decoding)
- [Types](#types)
  - [ServerFlags](#serverflags)
  - [Request](#request)
  - [HttpHeaders](#httpheaders)
  - [HttpCode](#httpcode)
  - [ScorperCallback](#scorpercallback)
  - [Scorper](#scorper)
  - [MiddlewareProc](#middlewareproc)
  - [HttpVersion](#httpversion)
  - [HttpMethod](#httpmethod)
  - [HttpBasicAuthValidator](#httpbasicauthvalidator)
  - [HttpError](#httperror)
  - [HttpVerb](#httpverb)
  - [Router](#router)
  - [Route](#route)
- [Consts](#consts)
  - [HttpCodes](#httpcodes)
  - [CRLF](#crlf)

# Examples

## Serve w/ Callback - Hello World

```nim
import scorper

proc myCallback(req: Request) {.async.} =
  let headers = {"Content-Type": "text/plain"}
  await req.resp("Hello World!", headers.newHttpHeaders())

waitFor serve("127.0.0.1:8888", myCallback)
```

## Scorper w/ Router - Hello World, Goodbye World

```nim
import scorper

proc helloWorld(req: Request) {.async.} =
  let headers = {"Content-Type": "text/plain"}
  await req.resp("Hello World!", headers.newHttpHeaders())

proc goodbyeWorld(req: Request) {.async.} =
  let headers = {"Content-Type": "text/plain"}
  await req.resp("Goodbye World!", headers.newHttpHeaders())

# Create router
let router = newRouter[ScorperCallback]()
router.addRoute(helloWorld, "get", "/hello")
router.addRoute(goodbyeWorld, "get", "/goodbye")

# Create Scorper
let address = "127.0.0.1:8888"
let flags = {ReuseAddr}         # flags defined by chronos
var server = newScorper(address, router, flags)
# You can pass a callback to a Scorper instead of a Router as we did before

# Start Scorper
server.start()
waitFor server.join()
```

*Note: The difference between the serve and newScorper proc is that serve cannot handle routers, has no return value and automatically calls the start and join procs; see below*

```nim
proc serve*(address: string,
            callback: ScorperCallback,
            flags: set[ServerFlags] = {ReuseAddr},
            maxBody = 8.Mb,
            isSecurity = false,
            privateKey: string = "",
            certificate: string = "",
            secureFlags: set[TLSFlags] = {},
            tlsMinVersion = TLSVersion.TLS11,
            tlsMaxVersion = TLSVersion.TLS12,
            cache: TLSSessionCache = nil,
            ) {.async.} =
  #...
  server.start()
  await server.join()

proc newScorper*(address: string, handler: ScorperCallback | Router[ScorperCallback] = default(ScorperCallback),
                flags: set[ServerFlags] = {ReuseAddr},
                maxBody = 8.Mb,
                isSecurity = false,
                privateKey: string = "",
                certificate: string = "",
                secureFlags: set[TLSFlags] = {},
                tlsMinVersion = TLSVersion.TLS11,
                tlsMaxVersion = TLSVersion.TLS12,
                cache: TLSSessionCache = nil,
                ): Scorper =
  #...
```

## Route & Mount pragma

The route pragma can be used on handlers to then mounted to a Router in bulk for enhanced development efficiency.

First we define our routes:
```nim
# routemount.nim

import chronos
import scorper

proc handlerA*(req: Request) {.route("get", "/a"), async.} =
  # do things here if `get` request comes to {SERVERADDRESS}/a
  let headers = {"Content-type": "text/plain"}
  await req.resp("There's no helping you here", headers.newHttpHeaders())

proc handlerB*(req: Request) {.route(["get", "post"], "/b"), async.} =
  # do things here if a `get` or `post` request comes to {SERVERADDRESS}/b
  let headers = {"Content-type": "text/plain"}
  await req.resp("There's no help here either", headers.newHttpHeaders())
```

And then we mount them.
```nim
# main.nim

import chronos
import scorper
import ./routemount # file defined above

let router = newRouter[ScorperCallback]()
router.mount(routemount)    # Mounting will bulk add the routes; you can use addRoute()
doAssert(router.len == 2)   # and pass the handler names to add them manually instead
                            # eg: router.addRoute(handlerA)

# Can pass the router loaded with the routes specified in the routemount
# file to a Scorper as normal

let flags = {ReuseAddr}
var server = newScorper("127.0.0.1:8888", router, flags)
server.start()
waitFor server.join()
```

## Header magic

Content-length etc will be autofilled in the response by the server if empty headers are passed

```nim
proc handler(request: Request) {.async.} =
  await request.resp("Hello World, 200", newHttpHeaders())

# The client response headers will include Content-Length of 16
```

Content-Length will be enforced in the response by the server if headers with the key are passed

```nim
proc handler(request: Request) {.async.} =
  let headers = {"Content-Length": "0"}
  await request.resp("Hello World, 200", headers.newHttpHeaders())

# The client response body will be empty
```

## Response HttpCodes
```nim
proc handler(request: Request) {.async.} =
  await request.resp("Oops!, 404", code = Http404)
```

## Basic Authentication

Incomplete API. This is subject to change. See src/scorper/http/httpbasicauth

A request can have authorization basic headers automatically decoded and then passed to a validator for verification.

```nim
# Create validator
# Must take a Request and two string params and return a Future[bool]

proc basicValidation(request: Request, user, pass: string): Future[bool] {.async.} =
  # Check the decoded user and pass against your database/whatever
  # return true for authentication to be accepted and for the calling callback to continue
  # return false for automatic Http401 response
  return true

# Create your callback
proc handler(request: Request) {.async.} =
  # Create validation object and pass to request method basicAuth
  var validator = HttpBasicAuthValidator(basicValidation) # our validator proc
  if await request.basicAuth(validator):
    # Do things because request is validified
  else:
    # Do things here because request was invalid
    # RESPONSE UNNECESSARY; see note below

  # basicAuth proc returns a bool; however any failure to validate the auth header
  # will result in an automatic response of either Http400 or Http401. An if/else
  # statement can be used however responses for failure are unnecessary.
  # Using the statement below is therefore perfectly valid
  #
  #   if not await request.basicAuth(validator): return

# Can create router here or set server handler directly
let address, flags = "127.0.0.1:8888", {ReuseAddr}
let server = newScorper(address, handler, flags)
server.start()
waitFor server.join()
```

## Template responses

A variety of procs can be used to generate responses to requests. The procedures and their parameters are listed below; please see src/scorper/http/streamserver for their implementations.

Listed below are some common response procs.

```nim
proc respBasicAuth*(req: ImpRequest, scheme = "Basic", realm = "Scorper", params: seq[tuple[key: string,
    value: string]] = @[], code = Http401): Future[void] {.async.}
    ## Responds to the req with the specified ``HttpCode``; defaults to Http401

proc respError*(req: ImpRequest, code: HttpCode, content: sink string, headers = newHttpHeaders()): Future[
    void] {.async.}
proc respError*(req: ImpRequest, code: HttpCode, headers = newHttpHeaders()): Future[void] {.async.}
  ## Responds to the req with the specified ``HttpCode``.

proc respStatus*(req: ImpRequest, code: HttpCode, ver = HttpVer11): Future[void] {.async.}
proc respStatus*(req: ImpRequest, code: HttpCode, msg: string, ver = HttpVer11): Future[void] {.async.}

## Chore: include responses related to files/downloads etc
```

<!--- Note: request default respError codes --->

## Request JSON

```nim
proc handler(request: Request) {.async.} =
  let j = await request.json()              # If the request does not include valid
  await request.resp($j)                    #   JSON then a Http400 is returned with
                                            #   "Error" body
```


## Request Route Params/Query

Route variables and queries can be accessed by the request `params` and `query` table fields.

```nim
import scorper

proc handler(request: Request) {.async.} =
  doAssert request.params["author"] == "bung87"   # Access parsed param in route
  doAssert request.params["module"] == "scorper"
  doAssert request.query["q"] == "is_amazing"     # Access parsed query

  await request.resp("")

# Create router
let address, flags = "127.0.0.1:8888", {ReuseAddr}
let router = newRouter[ScorperCallback]()

# Add route with params
router.addRoute(handler, "get", "/nim/{author}/{module}")

# Start server
let server = newScorper(address, router, flags)
server.start()
waitFor server.join()

# curl 127.0.0.1:8888/nim/bung87/scorper?q=is_amazing
```

## URL Encoding/Decoding

<!---
If the header for content type is set to url-encoded messages, will the
body automatically be url encoded?
--->

Encoded uri requests are decoded automatically.

When handling Request Route params etc; the decoding occurs before the tables are populated. This means when accessing the route variable, you will receive the decoded input.

```nim
proc handler(request: Request) {.async.} =
  doAssert request.params["decoded"] == "ß"   # Decoded from %C3%9F
  
  await request.resp("")

# Create router
let address, flags = "127.0.0.1:8888", {ReuseAddr}
let router = newRouter[ScorperCallback]()

#Add route with params
router.addRoute(handler, "get", "/scorper/{decoded}")

# Start server
let server = newScorper(address, router, flags)
server.start()
waitFor server.join()

# curl 127.0.0.1:8888/scorper/%C3%9F
```

## Form Decoding

Requests with content-types of url encoded forms will automatically be decoded. Lets look at the following example where a client posts the following message:

> `UserName=test&UserNameKana=%E3%83%86%E3%82%B9%E3%83%88&MailAddress=test%40example.com`

With headers `Content-Type` of `application/x-www-form-urlencoded`.

The content of the form is accessible from the request as follows:

```nim
proc handler(request: Request) {.async.} =
  let form = await request.form
  doAssert $form is string
  doAssert form.data["UserName"] == "test"
  doAssert form.data["UserNameKana"] == "テスト"
  doAssert form.data["MailAddress"] == "test@example.com"
  await request.resp("")
```

<!---
## Static files
TODO
--->

<!---
## Form handling
TODO
--->

<!---
## Cookies
TODO
--->

# Types

## ServerFlags

from [chronos](https://github.com/status-im/nim-chronos)

```nim
type
  ServerFlags* = enum
    ## Server's flags
    ReuseAddr, ReusePort, TcpNoDelay, NoAutoRead, GCUserData, FirstPipe,
    NoPipeFlash, Broadcast
```

## Request

```nim 
type Request* = ref object
  meth*: HttpMethod
  headers*: HttpHeaders
  protocol*: tuple[major, minor: int]
  url*: Url                  # from urlly
  path*: string              # http req path
  hostname*: string
  ip*: string
  params*: Table[string, string]
  query*: seq[(string, string)]
```

## HttpHeaders
```nim
type
  HttpHeaders* = ref object
    table*: TableRef[string, seq[string]]
  HttpHeaderValues* = distinct seq[string]
```

## HttpCode
```nim
type
  HttpCode* = distinct range[0 .. 599]
```

>Predefined for the following:
> ```nim
>const
>  Http100* = HttpCode(100)
 > #... 101, 200, 201, 202, 203, 204, 205, 206, 300, 301, 302, 303, 304, 305, 307, 308, 400, 401, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 421, 422, 426, 428, 429, 431, 451, 500, 501, 502, 503, 504
>  Http505* = HttpCode(505)
>```

## ScorperCallback
```nim
type ScorperCallback* = proc (req: Request): Future[void] {.closure, gcsafe.}
```

## Scorper
```nim
type Scorper* = ref object of StreamServer
# inherited (partial)
  sock*: AsyncFD                # Socket
  local*: TransportAddress      # Address
  status*: ServerStatus         # Current server status
  flags*: set[ServerFlags]      # Flags
  errorCode*: OSErrorCode
```

## MiddlewareProc

```nim
type MiddlewareProc* = proc (req: Request): Future[bool]
```

## HttpVersion
```nim
type
  HttpVersion* = enum
    HttpVer11 = "HTTP/1.1",
    HttpVer10 = "HTTP/1.0"
    HttpVer20 = "HTTP/2.0"
```

## HttpMethod
```nim
type
  HttpMethod* = enum ## the requested HttpMethod
    HttpHead,        ## Asks for the response identical to the one that would
                     ## correspond to a GET request, but without the response
                     ## body.
    HttpGet,         ## Retrieves the specified resource.
    HttpPost,        ## Submits data to be processed to the identified
                     ## resource. The data is included in the body of the
                     ## request.
    HttpPut,         ## Uploads a representation of the specified resource.
    HttpDelete,      ## Deletes the specified resource.
    HttpTrace,       ## Echoes back the received request, so that a client
                     ## can see what intermediate servers are adding or
                     ## changing in the request.
    HttpOptions,     ## Returns the HTTP methods that the server supports
                     ## for specified address.
    HttpConnect,     ## Converts the request connection to a transparent
                     ## TCP/IP tunnel, usually used for proxies.
    HttpPatch        ## Applies partial modifications to a resource.

```

## HttpBasicAuthValidator
<!--- King of confused with using this one --->
```nim
type HttpBasicAuthValidator* = ref object
  validate: proc (request: Request, user, pass: string): Future[bool] {.closure, gcsafe.}
```

## HttpError

```nim
type
  HttpErrorCode* = range[400 .. 599]
  HttpError* = ref object of CatchableError # See chronos error handling
    code*: HttpErrorCode
```

## HttpVerb

see router

```nim
type
  HttpVerb* = enum ## Available methods to associate a mapped handler with
    GET = "get"
    HEAD = "head"
    OPTIONS = "options"
    PUT = "put"
    POST = "post"
    DELETE = "delete"
```

## Router

Internal implementation

```nim
type Router*[H] = ref object
  verbTrees: CritBitTree[PatternNode[H]]
```

## Route
```nim
type
  Route* = object ## Arguments extracted from a request while routing it
    params*: TableRef[string, string]
    prefix*: string
```

# Consts

## HttpCodes

see [HttpCode type](#httpcode)

## CRLF
```nim
const CRLF* = "\c\L"
```
