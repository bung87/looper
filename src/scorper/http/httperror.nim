import ./httpcore

type
  HttpErrorCode* = range[400 .. 599]
  HttpError* = ref object of CatchableError
    code*: HttpErrorCode

proc newHttpError*(code: HttpErrorCode|HttpCode = 500.HttpErrorCode; msg = ""): HttpError =
  result = new HttpError
  result.code = code.HttpErrorCode
  if msg.len > 0:
    result.msg = msg
  else:
    result.msg = $HttpCode(code)

proc `$`*(s: HttpError): string = s.msg

when isMainModule:
  echo newHttpError()
