# SCORPER  ![Build Status](https://github.com/bung87/scorper/workflows/Test/badge.svg)  

![scorper](artwork/scorper.png)  


[travis]: https://travis-ci.org/bung87/scorper.svg?branch=master

**Elegant, performant, asynchronous micro web framework written in Nim**  

Built using [chronos](https://github.com/status-im/nim-chronos.git) and other powerful libraries.


**Note**: `scorper` is built using `chronos` which implements an `async`/`await` paradigm that is, at its core, different and therefore incompatible with the nim std library `asyncdispatch`'s `async`; this conflict is irresolvable and you will have to ensure your project dependencies support chronos async/await (note: many libraries do offer this, often using a compiler switch).     

> `scorper` will self contain manageable dependency source code for accelerated development.  

## Compiler flags  

### -ssl

Compile with: `-d:ssl`  

Then, using the proc `newScorper`, you will need to pass `isSecurity = true`,`privateKey`, `certificate` 

### Other

``` nim
const GzipEnable {.booldefine.} = true 
const HttpRequestBufferSize* {.intdefine.} = 2.Kb
const HttpServer {.strdefine.} = "scorper"
const TimeOut {.intdefine.} = 300 # in seconds  
const HttpHeadersLength* {.intdefine.} = int(HttpRequestBufferSize / 32) 
# 32 is sizeof MofuHeader
const gzipMinLength* {.intdefine.} = 20
```

## Usage  

details see here [usage](./USAGE.md)  

### hello world  

### `serve` with callback  

``` nim
import scorper

const port{.intdefine.} = 8888

proc cb(req: Request) {.async.} =
  ## See Request type to see fields accessible by callbacks

  let headers = {"Content-type": "text/plain"}
  await req.resp("Hello, World!", headers.newHttpHeaders())

when isMainModule:
  let address = "127.0.0.1:" & $port

  waitFor serve(address, cb)
  ## waitFor is a chronos implementation
  ## See chronos for options around executing async procs
```

### `newScorper` with router or callback  

<!---
Requires a more specific example aimed specifically at introducing router;
simultaneous introduction of the serve static and flags {ReuseAddr} require
documentation/explanation
--->

<!---
neatify example
--->

``` nim
when isMainModule:
  let r = newRouter[ScorperCallback]()
  # Relys on `StaticDir` environment variable
  r.addRoute(serveStatic, "get", "/static/*$")
  let address = "127.0.0.1:8888"
  let flags = {ReuseAddr}
  var server = newScorper(address, r, flags)
  server.start()
  waitFor server.join()
``` 

### use `route` pragma

<!---
Chore: requires better documentation and explanation
--->
``` nim
proc handler(req: Request) {.route("get","/one"),async.} = discard
proc handler2(req: Request) {.route(["get","post"],"/multi"),async.} = discard
let r = newRouter[ScorperCallback]()
r.addRoute(handler)
r.addRoute(handler2)
```

### responds depends on request mime  

``` nim
import scorper

proc cb(req: Request) {.async.} =
  var headers = newHttpHeaders()
  acceptMime(req, ext, headers):
    ## The template will automatically define the second parameter

    case ext
    of "html": await req.resp("Hello World", headers)
    of "txt": await req.resp("Hello World", headers)
    else:
      headers["Content-Type"] = "text/html"
      await req.resp("Hello World", headers)

when isMainModule:
  let address = "127.0.0.1:8888"
  waitFor serve(address, cb)
```

### Middleware  

<!---
Chore: include a bit more 
--->

Middleware can be implemented by importing `scorper/scorpermacros` (the import and definition of your middleware procedures **MUST** occur before importing scorper; see the note labeled *IMPORTANT* below)

>#### preMiddleware
>
>Procedure that is injected after the Request object fields are filled but BEFORE your callback.
>
>#### postMiddleware
>
>Procedure that is injected AFTER your callback (and therefore after your *response*).

#### Declaring middleware:

```nim
import scorper/scorpermacros

proc middleWare(req: Request): Future[bool] {.async, postMiddleware.} =
  ## Do things here
  return false
  ## return false to prevent calling the next middleware
```

Middleware procedures return `bool` to indicate whether to continue the call-chain to the next middleware.  

see [tmiddleware.nim](tests/tmiddleware.nim) for more

## Types  

``` nim 
type
  Request* = ref object
    meth*: HttpMethod
    headers*: HttpHeaders
    protocol*: tuple[major, minor: int]
    url*: Url
    hostname*: string
    ip*: string
    params*: Table[string, string]

  ScorperCallback* = proc (req: Request): Future[void] {.closure, gcsafe.}
  Scorper* = ref object of StreamServer
    # inherited (partial)
    sock*: AsyncFD                # Socket
    local*: TransportAddress      # Address
    status*: ServerStatus         # Current server status
    flags*: set[ServerFlags]      # Flags
    errorCode*: OSErrorCode
  MiddlewareProc* = proc (req: Request): Future[bool]
```

## Error handling & Exception effects

As [`scorper`](https://github.com/bung87/scorper) make use of [`chronos`](https://github.com/status-im/nim-chronos) for asynchronous procedures, the handling of errors and exceptions within this paradigm are of relevance.

> `chronos` currently offers minimal support for exception effects and `raises`
annotations. In general, during the `async` transformation, a generic
`except CatchableError` handler is added around the entire function being
transformed, in order to catch any exceptions and transfer them to the `Future`.
>
> Effectively, this means that while code can be compiled with
`{.push raises: [Defect]}`, the intended effect propagation and checking is
**disabled** for `async` functions.

## Todos  

- [ ] Parse JSON streamingly.  
- [ ] CLI tool generate object oriented controller and routes.  
- [x] Parse http request streamingly.  
- [x] Parse form streamingly and lazyly.  
- [x] Send file and attachement streamingly.  
- [x] Http Basic auth, Bearer auth , Digest auth(planed).  
- [x] Serve static files (env:StaticDir)  
- [x] Parse JSON lazyly.  
- [x] cookies module.  
- [x] Better error control flow.  
- [x] Auto render response respect client accepted content (acceptMime macro)type.  
- [x] Chuncked file upload handle for large file. 
- [x] https support 
- [x] handle Resumable upload

## Contribution  
check Todo list upon and [issues](https://github.com/bung87/scorper/issues)  

clone this repository, run `nimble install stage` , if you already have `stage` installed, run `stage init`  
`stage` is used for integrating with git commit hook, doing checking and code formatting.  

## Benchmark

[Web Frameworks Benchmark](https://web-frameworks-benchmark.netlify.app/result?l=nim)  

[TechEmpower benchmarks](https://www.techempower.com/benchmarks/)  

requires `wrk`  

`nimble benchmark`  
`nimble benchmarkserver` 

### Report  
runs on my MBP Dual-Core Intel Core i5 2.7 GHz ,8 GB memory.  
scorper: `1.0.2`  
chronos: `3.0.1`  
nim version: `1.5.1`, `1.4.4`  
```
Running 30s test @ http://127.0.0.1:8888/
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     3.51ms    1.00ms  66.66ms   92.16%
    Req/Sec     7.15k   518.66    10.94k    85.67%
  854619 requests in 30.05s, 93.73MB read
Requests/sec:  28441.14
Transfer/sec:      3.12MB
```
### Conclusion

*Scorper* is almost ten thousands faster than `jester` with stdlib.  It is even a thousand times faster than `asynchttpserver`

## Misc features/limitations  

The `mofuparser` use `SIMD` which relys on cpu support `SSE` or `AVX` instructions  

## Related projects  

[amysql](https://github.com/bung87/amysql)  Async MySQL Connector write in pure Nim. (support chronos with compile flag `-d:ChronosAsync`)

## License  

Apache License 2.0  

The Scorper logo was created and released to the Scorper project under the CC BY-SA 4.0 by [https://ITwrx.org](https://ITwrx.org) and [https://LuciusRafi.com](https://LuciusRafi.com)  