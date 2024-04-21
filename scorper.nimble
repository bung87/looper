# Package

version       = "1.2.4"
author        = "bung87"
description   = "micro and elegant web framework"
license       = "Apache License 2.0"
srcDir        = "src"
skipDirs      = @["tests","examples","experiments","benchmark","artwork"]
installExt = @["nim"]
# namedbin = {"scorper/http/routermacros":"routermacros" }.toTable()
# Dependencies

requires "nim >= 2.0.0" # initial 1.3.1
# requires "chronos >= 3.0.2" # initial 2.6.1
requires "chronos"
requires "npeg"
requires "zippy"
requires "jsony"
requires "urlly >= 0.2.0 & < 0.3.0"
requires "ptr_math"


task docs,"a":
  exec "nim doc --project src/scorper.nim"

task ghpage,"gh page":
  cd "src/htmldocs" 
  exec "git init"
  exec "git add ."
  exec "git config user.name \"bung87\""
  exec "git config user.email \"crc32@qq.com\""
  exec "git commit -m \"docs(docs): update gh-pages\""
  let url = "\"https://bung87@github.com/bung87/scorper.git\""
  exec "git push --force --quiet " & url & " master:gh-pages"

task bench_j,"benchmark with jest":
  requires "jester"
  exec "nim c -r -d:release --threads:on -d:port=8888 benchmark/benchmark.nim"
  exec "nim c -r -d:release --threads:on -d:port=9999 -d:demoPath=benchmark/tjester.nim benchmark/benchmark.nim"

task bench_s,"benchmark with std server":
  exec "nim c -r -d:release --threads:on -d:port=7777 -d:serverTest -d:demoPath=examples/hello_world.nim benchmark/benchmark.nim"
  exec "nim c -r -d:release --threads:on -d:port=6666 -d:serverTest -d:demoPath=benchmark/tstdserver.nim benchmark/benchmark.nim"

task bench_p,"benchmark simple responses with prologue":
  requires "prologue"
  exec "nim c -r -d:release --threads:on -d:port=7777 -d:demoPath=benchmark/simple_resp.nim benchmark/benchmark_resp.nim"
  exec "nim c -r -d:release --threads:on -d:port=6666 -d:demoPath=benchmark/simple_resp_prologue.nim benchmark/benchmark_resp.nim"

task bench_h,"benchmark simple responses with httpbeast":
  requires "httpbeast"
  exec "nim c -r -d:release --threads:on -d:port=7777 -d:demoPath=benchmark/simple_resp.nim benchmark/benchmark_resp.nim"
  exec "nim c -r -d:release --threads:on -d:port=6666 -d:demoPath=benchmark/simple_resp_httpbeast.nim benchmark/benchmark_resp.nim"


# before test:
#   requires "asynctest >= 0.3.2 & < 0.4.0"

task profile,"profiling":
  let c = readFile("benchmark/simple_resp.nim")
  let c2 = "import nimprof\n" & c
  writeFile("benchmark/simple_resp2.nim",c2)
  exec "nim c --profiler:on --stacktrace:on -d:release benchmark/simple_resp2.nim"
  exec "nohup ./benchmark/simple_resp2 &"
  exec "curl http://localhost:8080/json"
  rmFile("benchmark/simple_resp2.nim")
  exec "pkill simple_resp2"
