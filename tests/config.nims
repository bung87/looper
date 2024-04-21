switch("path", "$projectDir/../src")
switch("mm", "refc")
import std/os

const explicitSourcePath {.strdefine.} = getCurrentCompilerExe().parentDir.parentDir
switch "path", explicitSourcePath