"""Unit tests for bookdrop.koplugin/bookdrop_provider.lua (Internet Archive).

The provider is plain Lua against KOReader's LuaSocket/rapidjson C modules.
lupa runs the module with those modules stubbed and a canned HTTP route
table, exercising the real search/metadata parsing and acquisition logic.
"""

import json
from pathlib import Path

from lupa import LuaRuntime

SEARCH_DOCS = [
    {
        "identifier": "great_expectations",
        "title": "Great Expectations",
        "creator": "Charles Dickens",
        "description": "A novel.",
        "language": ["eng"],
        "date": "1861-01-01T00:00:00Z",
        "downloads": 123456,
        "subject": ["Fiction", "Classics"],
        "publisher": "Chapman & Hall",
        "format": ["EPUB", "PDF"],
        "isbn": "9780141439563",
    },
    {
        "identifier": "olivertwist",
        "title": "Oliver Twist",
        "creator": "Charles Dickens",
        "language": ["eng"],
        "date": "1838",
        "format": ["DjVu", "DjVuTXT"],
    },
]

SEARCH_RESPONSE = {
    "response": {
        "numFound": 2345,
        "start": 0,
        "docs": SEARCH_DOCS,
    }
}

METADATA_RESPONSE = {
    "metadata": {
        "title": "Great Expectations: The Complete Novel",
        "creator": "Charles Dickens",
        "description": "<p>A longer description.</p>",
        "language": ["English"],
        "date": "1861",
        "publisher": "Chapman & Hall",
        "isbn": "9780141439563",
        "subject": ["Fiction", "Classics"],
        "rights": "Public domain in the USA",
        "downloads": 123456,
        "access-restricted-item": False,
    },
    "files": [
        {"name": "great_expectations.epub", "size": 1048576, "md5": "abc123",
         "source": "original", "format": "EPUB", "private": False},
        {"name": "great_expectations.pdf", "size": 2097152,
         "source": "derivative", "format": "Text PDF", "private": False},
        {"name": "great_expectations_private.pdf", "size": 999,
         "source": "original", "format": "PDF", "private": True},
    ],
}

RESTRICTED_RESPONSE = {
    "metadata": {"access-restricted-item": True, "title": "Restricted"},
    "files": [],
}

ROUTES = [
    ("/advancedsearch.php", json.dumps(SEARCH_RESPONSE)),
    ("/metadata/great_expectations", json.dumps(METADATA_RESPONSE)),
    ("/metadata/restricted_item", json.dumps(RESTRICTED_RESPONSE)),
]

lua = LuaRuntime(unpack_returned_tuples=True)


def to_lua(value):
    """Recursively convert JSON (dict/list/str/int/float/bool) to Lua values.

    lupa's lua.table_from() only converts the top level, leaving nested
    Python objects as userdata that Lua cannot safely index or iterate.
    """
    if isinstance(value, dict):
        table = lua.table()
        for key, item in value.items():
            table[key] = to_lua(item)
        return table
    if isinstance(value, (list, tuple)):
        table = lua.table()
        for index, item in enumerate(value, start=1):
            table[index] = to_lua(item)
        return table
    return value


def python_json_decode(text):
    return to_lua(json.loads(text))


requested_bodies = []
redirect_cookie_requests = []
redirect_loop_requests = []
unexpected_response_requests = []


def python_http_request(arg):
    url = arg["url"]
    # Drain the POST body (an ltn12 source generator) so tests can assert on the
    # request parameters the provider sent.
    source = arg["source"]
    if source is not None:
        chunk = source()
        requested_bodies.append(chunk if isinstance(chunk, str) else "")
    else:
        requested_bodies.append("")
    if "redirect-cookie.test" in url:
        cookie = arg["headers"]["Cookie"]
        redirect_cookie_requests.append(cookie)
        if not cookie or "challenge=passed" not in cookie:
            return (True, 307, to_lua({
                "location": url,
                "set-cookie": "challenge=passed; Path=/; HttpOnly",
            }), "Temporary Redirect")
        arg["sink"](json.dumps(SEARCH_Z))
        return (True, 200, to_lua({}), "OK")
    if "redirect-loop.test" in url:
        redirect_loop_requests.append(url)
        return (True, 307, to_lua({"location": url}), "Temporary Redirect")
    if "unexpected-response.test" in url:
        unexpected_response_requests.append(url)
        arg["sink"]("<html><title>Just a moment</title></html>")
        return (True, 200, to_lua({"content-type": "text/html"}), "OK")
    for marker, body in ROUTES:
        if marker in url:
            arg["sink"](body)
            return (True, 200, None, "OK")
    return (None, None, None, "no fixture for " + url)


lua.globals()["python_json_decode"] = python_json_decode
lua.globals()["python_http_request"] = python_http_request

lua.execute(
    r'''
    package.preload["socketutil"] = function()
        return { set_timeout = function() end, reset_timeout = function() end }
    end
    package.preload["socket.url"] = function()
        return {
            escape = function(value) return value end,
            absolute = function(base, location)
                if location:match("^%a[%w+.-]*://") then return location end
                local scheme, host = base:match("^(%a[%w+.-]*)://([^/]+)")
                if not scheme or not host then return nil end
                if location:sub(1, 2) == "//" then return scheme .. ":" .. location end
                if location:sub(1, 1) == "/" then
                    return scheme .. "://" .. host .. location
                end
                return base:match("^(.*)/") .. "/" .. location
            end,
            parse = function(s)
                local scheme, rest = s:match("^(%a[%w+.-]*)://(.*)$")
                if not scheme then return nil end
                local host = rest:match("^([^/]+)")
                return host and { scheme = scheme, host = host } or { scheme = scheme }
            end,
        }
    end
    package.preload["ltn12"] = function()
        return {
            sink = { file = function() return function() end end },
            source = { string = function(s)
                local sent = false
                return function()
                    if not sent then sent = true return s end
                end
            end },
        }
    end
    package.preload["rapidjson"] = function()
        return { decode = function(text) return python_json_decode(text) end }
    end
    package.preload["json"] = function()
        -- Lua 5.4+ functions cannot carry fields, and the provider reads
        -- json.decode.simple, so decode is a callable table instead.
        local decode = setmetatable({ simple = true }, {
            __call = function(_, text, simple) return python_json_decode(text) end,
        })
        return { decode = decode }
    end
    package.preload["datastorage"] = function()
        return { getSettingsDir = function() return "" end }
    end
    package.preload["luasettings"] = function()
        return { open = function(path)
            local data = {}
            return {
                data = data,
                readSetting = function(_, key) return data[key] end,
                saveSetting = function(_, key, value) data[key] = value end,
                flush = function() end,
            }
        end }
    end
    package.preload["util"] = function()
        return {
            trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
            urlEncode = function(s)
                return (s:gsub("([^%w%-%._~])", function(c)
                    return string.format("%%%02X", string.byte(c))
                end))
            end,
        }
    end
    package.preload["socket.http"] = function()
        return { request = function(arg) return python_http_request(arg) end }
    end
    '''
)

provider = lua.execute(Path("bookdrop.koplugin/bookdrop_provider.lua").read_text())
lua.globals()["provider"] = provider

lua.execute(
    r'''
    page = provider:search("dickens", 1, {})
    hydrated, hydrate_err = provider:hydrate({ provider_id = "great_expectations" })
    restricted, restricted_err = provider:hydrate({ provider_id = "restricted_item" })
    '''
)

page = lua.globals().page
books = page["books"]
assert len(books) == 2, f"expected 2 records, got {len(books)}"

first = books[1]
assert first["title"] == "Great Expectations"
assert first["author"] == "Charles Dickens"
assert first["id"] == "great_expectations"
assert first["provider_id"] == "great_expectations"
assert first["cover_url"].startswith("https://covers.openlibrary.org/")
assert first["year"] == "1861"
assert first["format"] == "EPUB"
assert first["available_formats"] == "EPUB · PDF"
assert first["content_type"] == "Book (fiction)"

second = books[2]
assert second["id"] == "olivertwist"
assert second["cover_url"] == "https://archive.org/services/img/olivertwist"

assert page["total"] == 2345
assert page["page"] == 1
assert page["has_next"] is True

hydrated = lua.globals().hydrated
restricted = lua.globals().restricted
restricted_err = lua.globals().restricted_err

assert hydrated is not None
assert hydrated["title"] == "Great Expectations: The Complete Novel"
assert hydrated["year"] == "1861"
acquisitions = hydrated["acquisitions"]
assert len(acquisitions) == 2, f"expected 2 public files, got {len(acquisitions)}"
assert acquisitions[1]["extension"] == "epub"
assert acquisitions[1]["format"] == "EPUB"
assert acquisitions[1]["url"] == (
    "https://archive.org/download/great_expectations/great_expectations.epub")
assert acquisitions[2]["extension"] == "pdf"
assert hydrated["format"] == "EPUB"
assert hydrated["size"] == "1.0 MB"

assert restricted is None
assert "restricted" in restricted_err.lower()

# ==================================================== Z-Library provider

# Fixtures for the Z-Library eAPI routes. The /file route must be listed before
# the book-details route so the marker matching picks the longer path.
SEARCH_Z = {
    "books": [
        {"id": 42, "hash": "abc123", "title": "Crime and Punishment",
         "author": "Fyodor Dostoevsky", "year": "1866", "language": "english",
         "extension": "epub", "filesizeString": "1.2 MB", "filesize": 1258291,
         "interestScore": "98", "cover": "https://z-lib.fo/covers/42.jpg",
         "description": "A novel."},
    ],
    "pagination": {"total_items": 321},
}
DETAILS_Z = {"success": 1, "book": {
    "id": 42, "hash": "abc123", "title": "Crime and Punishment",
    "extension": "epub", "filesizeString": "1.2 MB", "filesize": 1258291,
    "description": "A longer description."}}
LINK_Z = {"success": 1, "file": {
    "downloadLink": "https://z-lib.fo/dl/42", "extension": "epub",
    "allowDownload": True}}
LOGIN_OK = {"success": 1, "user": {"id": 123, "remix_userkey": "key456"}}

ROUTES.extend([
    ("/eapi/user/login", json.dumps(LOGIN_OK)),
    ("/eapi/book/search", json.dumps(SEARCH_Z)),
    ("/eapi/book/42/abc123/file", json.dumps(LINK_Z)),
    ("/eapi/book/42/abc123", json.dumps(DETAILS_Z)),
])

zprovider = lua.execute(Path("bookdrop.koplugin/bookdrop_zlibrary_provider.lua").read_text())
lua.globals()["zprovider"] = zprovider

lua.execute(
    r'''
    zpage = zprovider:search("dostoevsky", 1, {})
    zfiltered, zfiltered_err = zprovider:search("x", 1, {
        language = "es", formats = { epub = true, mobi = true }, sort = "" })
    zlogin_ok, zlogin_err = zprovider.login("user@example.com", "secret")
    zsigned_in = zprovider:isSignedIn()
    zcredentials = zprovider:getCredentials()
    zhydrated, zhydrated_err = zprovider:hydrate({
        provider_id = "42", hash = "abc123", title = "Crime and Punishment",
        author = "Fyodor Dostoevsky" })
    zresolved, zresolved_err = zprovider.resolveDownload({
        provider_id = "42", hash = "abc123", title = "Crime and Punishment",
        format = "EPUB" })
    zprovider:signOut()
    zsignout, zsignout_err = zprovider:hydrate({
        provider_id = "42", hash = "abc123" })
    '''
)

zpage = lua.globals().zpage
zbooks = zpage["books"]
assert len(zbooks) == 1, f"expected 1 z-library record, got {len(zbooks)}"
zfirst = zbooks[1]
assert zfirst["title"] == "Crime and Punishment"
assert zfirst["author"] == "Fyodor Dostoevsky"
assert zfirst["id"] == "zlibrary-42-abc123"
assert zfirst["provider"] == "zlibrary"
assert zfirst["provider_id"] == "42"
assert zfirst["hash"] == "abc123"
assert zfirst["format"] == "EPUB"
assert zfirst["cover_url"] == "https://z-lib.fo/covers/42.jpg"
assert zfirst["cover_fallback_url"] == "https://covers.articles.sk/covers/42.jpg"
assert zfirst["source"] == "Z-Library"
assert zpage["total"] == 321
assert zpage["has_next"] is True

zfiltered = lua.globals().zfiltered
assert zfiltered is not None, f"filtered search failed: {lua.globals().zfiltered_err}"
# The filter request is the last POST carrying a search message. Brackets in
# the parameter keys are literal (only values are URL-encoded, as upstream);
# extensions order is nondeterministic (pairs iteration).
filtered_body = [b for b in requested_bodies if "message=" in b][-1]
assert "languages[0]=spanish" in filtered_body, filtered_body
assert "extensions[0]=" in filtered_body and "extensions[1]=" in filtered_body, filtered_body
assert "epub" in filtered_body and "mobi" in filtered_body, filtered_body
assert "order=bestmatch" in filtered_body, filtered_body

assert lua.globals().zlogin_ok is True, f"login failed: {lua.globals().zlogin_err}"
assert lua.globals().zsigned_in is True
assert lua.globals().zcredentials["user_id"] == "123"
assert lua.globals().zcredentials["user_key"] == "key456"
lua.execute(r'''
zprovider.saveCredentials("user@example.com", "secret", "123", "key456")
zdownload_headers = zprovider.getDownloadHeaders("https://example.test/book")
''')
assert "remix_userid=123" in lua.globals().zdownload_headers["Cookie"]
assert "remix_userkey=key456" in lua.globals().zdownload_headers["Cookie"]
assert lua.globals().zdownload_headers["Referer"] == "https://example.test/book"

zhydrated = lua.globals().zhydrated
assert zhydrated is not None, f"hydrate failed: {lua.globals().zhydrated_err}"
zacquisitions = zhydrated["acquisitions"]
assert len(zacquisitions) == 1
assert zacquisitions[1]["url"] == "https://z-lib.fo/dl/42"
assert zacquisitions[1]["extension"] == "epub"
assert zacquisitions[1]["format"] == "EPUB"
assert zacquisitions[1]["referer"].endswith("/eapi/book/42/abc123")
assert lua.globals().zresolved is not None, lua.globals().zresolved_err
assert lua.globals().zresolved["url"] == "https://z-lib.fo/dl/42"
assert lua.globals().zresolved["referer"].endswith("/eapi/book/42/abc123")

assert lua.globals().zsignout is None
assert "sign-in" in lua.globals().zsignout_err.lower()

# Regression: credentials live in a provider-private settings file, so they
# survive Bookdrop's own settings handle being flushed with stale data (a
# filter/view/recent-books change would otherwise overwrite the shared file
# with a table that has no credentials in it).
lua.execute(
    r'''
    local luasettings = require("luasettings")
    zprovider.saveCredentials("isolated@example.com", "pw", "7", "key7")
    -- Bookdrop's main settings file is flushed independently, as any filter or
    -- view change does; it must not touch the provider's own file.
    local main_settings = luasettings.open("bookdrop.lua")
    main_settings:saveSetting("filters", { content = "book_fiction" })
    main_settings:flush()
    zisolated_creds = zprovider.getCredentials()
    zisolated_signed_in = zprovider.isSignedIn()
    '''
)
assert lua.globals().zisolated_creds["user_id"] == "7"
assert lua.globals().zisolated_creds["user_key"] == "key7"
assert lua.globals().zisolated_signed_in is True

# A mirror may redirect a POST back to the same URL while setting a short-lived
# challenge cookie. The client must return that cookie instead of exhausting
# its redirect budget.
lua.execute(
    r'''
    zprovider.setBaseUrl("https://redirect-cookie.test")
    zcookie_page, zcookie_err = zprovider:search("cookie", 1, {})
    '''
)
assert lua.globals().zcookie_page is not None, lua.globals().zcookie_err
assert len(redirect_cookie_requests) == 2
assert not redirect_cookie_requests[0] or "challenge=passed" not in redirect_cookie_requests[0]
assert "challenge=passed" in redirect_cookie_requests[1]

# A genuine same-URL loop has no new cookie and should immediately advance to
# another seed rather than surfacing "Too many redirects" as a catalog error.
lua.execute(
    r'''
    zprovider.setBaseUrl("https://redirect-loop.test")
    zloop_page, zloop_err = zprovider:search("loop", 1, {})
    '''
)
assert lua.globals().zloop_page is not None, lua.globals().zloop_err
assert len(redirect_loop_requests) == 1
assert lua.globals().zprovider.getBaseUrl() != "https://redirect-loop.test"

# A host can be reachable while returning a landing page or bot challenge
# instead of the JSON API. That host is not usable and must not stop fallback.
lua.execute(
    r'''
    zprovider.setBaseUrl("https://unexpected-response.test")
    zhtml_page, zhtml_err = zprovider:search("html", 1, {})
    '''
)
assert lua.globals().zhtml_page is not None, lua.globals().zhtml_err
assert len(unexpected_response_requests) == 1

print(f"parsed {len(books)} catalog records with cover metadata")
print(f"hydrated {len(acquisitions)} public acquisitions; "
      f"restricted item rejected: {restricted is None}")
print(f"z-library: searched, signed in, hydrated {len(zacquisitions)} acquisition; "
      f"sign-out blocks hydrate: {lua.globals().zsignout is None}")
print(f"z-library credentials survive a settings flush: "
      f"{lua.globals().zisolated_signed_in}")
print("z-library redirect cookies retained; true loops fall back immediately")
print("z-library non-JSON responses fall back to another mirror")
