import ./mimport
import os
# from os import nil
import compiler / parser
import compiler / llstream
import compiler / idents
import compiler / options
import compiler / pathutils
import compiler / lineinfos
import compiler / ast
export ast

type ParseError = ref object of CatchableError

proc parsePNodeStr*(str: string): PNode =
  let cache: IdentCache = newIdentCache()
  let config: ConfigRef = newPartialConfigRef()
  var pars: Parser

  config.verbosity = 0
  config.options.excl optHints
  when defined(nimpretty):
    const DevNullDir = when defined(windows):"c:\\" else: "/dev"
    const DevNullFile = when defined(windows):"nul" else: "null"
    config.outDir = toAbsoluteDir(DevNullDir)
    config.outFile = RelativeFile(DevNullFile)
  openParser(
    p = pars,
    filename = AbsoluteFile(currentSourcePath),
    inputStream = llStreamOpen(str),
    cache = cache,
    config = config
  )

  pars.lex.errorHandler =
    proc(conf: ConfigRef; info: TLineInfo; msg: TMsgKind; arg: string) =
      when declared(hintLineTooLong):
        if msg notin {hintLineTooLong}:
          raise ParseError(msg: arg)

  try:
    result = parseAll(pars)
    closeParser(pars)

  except ParseError:
    return nil
