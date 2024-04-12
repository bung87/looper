import ./httpcore
import times

type
  SameSite* = enum
    None, Lax, Strict

# name, value, Expires, Max-Age, Domain, Path, Secure, HttpOnly, SameSite
proc makeCookie*(key, value, maxAge, expires, domain, path:string;
                 secure = false; httpOnly = false;
                 sameSite = Lax): string =
  # If both Expires and Max-Age are set, Max-Age has precedence.
  # https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie
  result = ""
  result.add key & "=" & value
  if domain != "": result.add("; Domain=" & domain)
  if path != "": result.add("; Path=" & path)
  if maxAge != "": result.add("; Max-Age=" & maxAge)
  if expires != "": result.add("; Expires=" & expires)
  if secure or sameSite == None: result.add("; Secure")
  if httpOnly: result.add("; HttpOnly")
  if sameSite != None:
    result.add("; SameSite=" & $sameSite)

proc addCookie*(headers: HttpHeaders, name, value, maxAge, expires, domain, path: string;
                 secure = false; httpOnly = false;
                 sameSite = Lax) =
  # https://tools.ietf.org/html/draft-west-first-party-cookies-06
  headers.add("Set-Cookie", makeCookie(name, value, maxAge, expires, domain, path, secure, httpOnly, sameSite))

proc addCookie*(headers: HttpHeaders, name, value: string, maxAge = default(Duration), expires = default(DateTime), domain = "", path = "",
                secure = false, httpOnly = false,
                sameSite = Lax) =
  let maxAge = if maxAge != default(Duration): $maxAge.inSeconds else: ""
  let expires = if expires != default(DateTime): format(expires.utc, "ddd',' dd MMM yyyy HH:mm:ss 'GMT'") else: ""
  addCookie(headers, name, value, maxAge, expires, domain, path, secure, httpOnly, sameSite)

proc addSession*(headers: HttpHeaders, name, value: string, domain = "", path = "",
                secure = false, httpOnly = false,
                sameSite = Lax) =
  addCookie(headers, name, value, "", "", domain, path, secure, httpOnly, sameSite)

when isMainModule:
  var test = newHttpHeaders()
  # test.addCookie("test","onlykv") match semantics but cause Error: ambiguous call;
  test.addCookie("id", "a3fWa", expires = now().utc + 30.days, httpOnly = true, domain = "nim-lang.org", path = "/")
  test.addCookie("id", "a3fWa", maxAge = initDuration(days = 30), expires = now().utc + 30.days, httpOnly = true,
      domain = "nim-lang.org", path = "/")
  test.addCookie("id", "a3fWa", maxAge = initDuration(days = 30))
  test.addSession("sessionid", "123")
  echo generateHeaders(test)
