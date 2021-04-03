
import ./scorper/http/streamserver
import ./scorper/http/streamclient
import ./scorper/http/httpform
import ./scorper/http/multipartparser
import ./scorper/http/httpcore, chronos, os

let Sample = """multipart/form-data;boundary="sample_boundary""""

doAssert parseBoundary(Sample).boundary == "sample_boundary"

const TestUrl = "http://127.0.0.1:64124/foo?bar=qux"

proc runTest(
    handler: proc (request: Request): Future[void] {.gcsafe.},
    request: proc (server: Scorper): Future[AsyncResponse],
    test: proc (response: AsyncResponse, body: string): Future[void]) {.async.} =

  let address = "127.0.0.1:64124"
  let flags = {ReuseAddr}
  var server = newScorper(address, handler, flags)
  server.start()
  let
    response = await(request(server))
    body = await(response.readBody())

  await test(response, body)
  server.stop()
  server.close()
  await server.join()

proc testMultipart() {.async.} =
  proc handler(request: Request) {.async.} =
    let form = await request.form
    doAssert $form is string
    echo $form
    doAssert form.data["author"] == "bung"
    let x: FormFile = form.files["uploaded_file"]
    let c = x.open().readAll
    let e = readFile getCurrentDir() / "README.md"
    doAssert c == e
    doAssert x.filename == "README.md"
    await request.resp("Hello World, 200")

  proc request(server: Scorper): Future[AsyncResponse] {.async.} =
    let
      client = newAsyncHttpClient()
    var data = newMultipartData()
    data["author"] = "bung"
    data["uploaded_file"] = ("README.md", "text/markdown", readFile getCurrentDir() / "README.md")
    let clientResponse = await client.post(TestUrl, multipart = data)
    await client.close()

    return clientResponse

  proc test(response: AsyncResponse, body: string) {.async.} =
    doAssert(response.code == Http200)
    doAssert(body == "Hello World, 200")
    doAssert(response.headers.hasKey("Content-Length"))
    doAssert(response.headers["Content-Length"] == "16")

  await runTest(handler, request, test)
waitfor(testMultipart())

echo "OK"
