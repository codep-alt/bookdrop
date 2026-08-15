-- Z-Library catalog provider for Bookdrop.
--
-- Ported from the Z-Library plugin for KOReader (ZlibraryKO/zlibrary.koplugin,
-- AGPL-3.0; https://github.com/ZlibraryKO/zlibrary.koplugin). Only the parts
-- that matter for browsing, covers and downloads are carried over: the eAPI
-- client (login, search, book details, download-link resolution), the base-URL
-- and session handling, and the error classification that tells a wrong
-- password apart from a dead mirror. The Bookdrop-facing surface is the same
-- provider interface as the other sources (search / hydrate), so Z-Library
-- behaves like any other library in the store, and the standalone Z-Library
-- plugin is never needed.
--
-- Requires a Z-Library account: searching works signed out, but downloading
-- (and therefore hydrate, which resolves the download link) needs a session.
-- Credentials and the base URL live in Bookdrop's own settings file.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")
local json = require("json")

local ZlibraryProvider = {
    name = "Z-Library",
    page_size = 10,
    max_response_bytes = 4 * 1024 * 1024,
    timeout = { 10, 20 },
    -- Short timeout used while probing fallback mirrors: a live mirror answers
    -- fast, and a dead one must not stall the whole catalog search.
    probe_timeout = { 5, 8 },
}

local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36"

-- Known Z-Library base URLs, taken from the upstream plugin's seed list. The
-- operator rotates these; a dead one is changed in Bookdrop settings (or the
-- provider falls through to the next seed when the configured URL fails).
local SEED_URLS = {
    "https://z-library.sk/",
    "https://z-lib.gl/",
    "https://z-lib.fm/",
    "https://z-lib.gd/",
    "https://z-lib.fo/",
    "https://library-oceania.sk/",
    "https://library-latin.sk/",
    "https://library-asia.sk/",
    "https://lib-africa.sk/",
    "https://z-library.do/",
    "https://1lib.sk/",
    "https://z-library.rs/",
    "https://z-lib.do/",
    "https://z-lib.gs/",
}

-- Bookdrop filter language code -> Z-Library API language key.
local LANGUAGE_MAP = {
    en = "english", es = "spanish", fr = "french", de = "german",
    ru = "russian", pt = "portuguese", it = "italian", zh = "chinese",
    ja = "japanese",
}

-- Bookdrop format filter -> Z-Library extension key.
local FORMAT_MAP = {
    epub = "epub", pdf = "pdf", mobi = "mobi", djvu = "djvu",
    cbz = "cbz", txt = "txt",
}

-- Bookdrop sort -> Z-Library order key (bestmatch / date / titleA / year).
local SORT_MAP = {
    [""] = "bestmatch",
    title = "titleA",
    newest = "date",
    oldest = "year",
}

local SETTINGS_BASE_URL_KEY = "zlibrary_base_url"
local SETTINGS_EMAIL_KEY = "zlibrary_email"
local SETTINGS_PASSWORD_KEY = "zlibrary_password"
local SETTINGS_USER_ID_KEY = "zlib_user_id"
local SETTINGS_USER_KEY_KEY = "zlib_user_key"

-- ---------------------------------------------------------------- settings

local _lua_settings = nil
local function settings()
    if not _lua_settings then
        -- Provider-private settings file, on purpose: Bookdrop's own settings
        -- handle is instantiated once per UI, and LuaSettings:flush() writes the
        -- whole in-memory table, so any other handle with stale data would
        -- silently drop the credentials on its next flush. This file is opened
        -- only here (the module is required once per session), so nothing else
        -- can clobber it.
        _lua_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/bookdrop_zlibrary.lua")
    end
    return _lua_settings
end

function ZlibraryProvider.getBaseUrl()
    local configured = settings():readSetting(SETTINGS_BASE_URL_KEY)
    if configured and configured ~= "" then
        return configured:gsub("/$", "")
    end
    return SEED_URLS[1]:gsub("/$", "")
end

-- ---------------------------------------------------------------- settings
function ZlibraryProvider.setBaseUrl(url_string)
    if not url_string or url_string == "" then
        return false, "URL cannot be empty."
    end
    url_string = util.trim(url_string)
    if not (url_string:sub(1, 8) == "https://" or url_string:sub(1, 7) == "http://") then
        url_string = "https://" .. url_string
    end
    url_string = url_string:gsub("/$", "")
    if url_string:find("%s") then
        return false, "URL must be a valid domain, e.g. example.com."
    end
    local parsed = url.parse(url_string)
    if not (parsed and parsed.scheme and parsed.host and parsed.host:find("%."))
            or parsed.path or parsed.params or parsed.query or parsed.fragment or parsed.userinfo then
        return false, "URL must be a valid domain, e.g. example.com."
    end
    settings():saveSetting(SETTINGS_BASE_URL_KEY, url_string)
    settings():flush()
    return true, nil
end

function ZlibraryProvider.getCredentials()
    return {
        email = settings():readSetting(SETTINGS_EMAIL_KEY),
        password = settings():readSetting(SETTINGS_PASSWORD_KEY),
        user_id = settings():readSetting(SETTINGS_USER_ID_KEY),
        user_key = settings():readSetting(SETTINGS_USER_KEY_KEY),
    }
end

function ZlibraryProvider.isSignedIn()
    local credentials = ZlibraryProvider.getCredentials()
    return credentials.user_id ~= nil and credentials.user_id ~= ""
        and credentials.user_key ~= nil and credentials.user_key ~= ""
end

function ZlibraryProvider.saveCredentials(email, password, user_id, user_key)
    local storage = settings()
    storage:saveSetting(SETTINGS_EMAIL_KEY, email)
    storage:saveSetting(SETTINGS_PASSWORD_KEY, password)
    storage:saveSetting(SETTINGS_USER_ID_KEY, user_id)
    storage:saveSetting(SETTINGS_USER_KEY_KEY, user_key)
    storage:flush()
end

function ZlibraryProvider.signOut()
    local storage = settings()
    storage:saveSetting(SETTINGS_EMAIL_KEY, nil)
    storage:saveSetting(SETTINGS_PASSWORD_KEY, nil)
    storage:saveSetting(SETTINGS_USER_ID_KEY, nil)
    storage:saveSetting(SETTINGS_USER_KEY_KEY, nil)
    storage:flush()
end

-- ---------------------------------------------------------------- http

local function authedHeaders(user_id, user_key, body)
    local headers = {
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["User-Agent"] = USER_AGENT,
    }
    if body then
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        headers["Content-Length"] = tostring(#body)
    end
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end
    return headers
end

-- One request with bounded redirect following (the operator redirects mirror
-- hosts to their live domain; socket.http's own redirect would not re-issue a
-- POST body correctly, so the hop is done by hand, like the upstream plugin).
local function httpRequest(url_string, method, headers, body, timeout)
    timeout = timeout or ZlibraryProvider.timeout
    local hops = 0
    while hops < 3 do
        hops = hops + 1
        local chunks, received, too_large = {}, 0, false
        local sink = function(chunk)
            if chunk then
                received = received + #chunk
                if received > ZlibraryProvider.max_response_bytes then
                    too_large = true
                    return nil, "response is too large"
                end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end

        socketutil:set_timeout(timeout[1], timeout[2])
        local ok, code, response_headers, _, status = http.request{
            url = url_string,
            method = method or "GET",
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = sink,
        }
        socketutil:reset_timeout()

        if too_large then return nil, "Z-Library response exceeded 4 MiB", false end

        local response_body = table.concat(chunks)

        if not ok or tonumber(code) ~= 200 then
            local location = response_headers and response_headers.location
            if location and code and tonumber(code) >= 300 and tonumber(code) < 400 then
                -- Resolve relative redirects against the current URL.
                local parsed = url.parse(location)
                if not (parsed and parsed.host) then
                    local base = url.parse(url_string)
                    if base then
                        location = (base.scheme or "https") .. "://" .. base.host .. location
                    end
                end
                url_string = location
            elseif not ok or tonumber(code) == nil then
                -- Transport-level failure (timeout, connection reset, DNS...).
                -- code holds the LuaSocket error string, not an HTTP status.
                -- Third return value marks this as a transport error so the
                -- seed fallback can advance to the next mirror.
                local msg = tostring(code)
                if msg:find("timeout") or msg:find("wantread") or msg:find("wantwrite") then
                    return nil, "Z-Library did not respond in time", true
                elseif msg:find("closed") or msg:find("reset") then
                    return nil, "Connection to Z-Library was interrupted", true
                else
                    return nil, "Could not reach Z-Library: " .. msg, true
                end
            else
                -- Z-Library often returns non-200 with a JSON error body
                -- (e.g. HTTP 400 + {"success":0,"error":"..."}).  Return the
                -- body so callers can surface the real error message.
                if response_body and response_body ~= "" then
                    return response_body, nil, false
                end
                return nil, status or ("HTTP " .. tostring(code)), false
            end
        else
            return response_body, nil, false
        end
    end
    return nil, "Too many redirects", false
end

-- GET/POST that returns the parsed JSON payload (or nil, err, transport_error).
local function requestJson(url_string, method, headers, body, timeout)
    local response_body, err, transport_error = httpRequest(url_string, method, headers, body, timeout)
    if not response_body then return nil, err, transport_error end
    local ok, payload = pcall(json.decode, response_body, json.decode.simple)
    if not ok or type(payload) ~= "table" then
        -- The mirror answered but not with JSON (e.g. a rate-limit page).
        -- Not a transport failure: don't fall back to the next mirror.
        return nil, "Z-Library returned an unexpected response", false
    end
    return payload, nil, false
end

-- Make a request, falling back to the next seed URL only when the previous one
-- failed at the transport level (timeout, DNS, reset).  A mirror that answers
-- — even with an error payload or a rate-limit page — stops the loop, because
-- that host is reachable and trying more mirrors would only waste time.
--
-- Seed probes use a short timeout so a dead mirror fails fast instead of
-- stalling the whole (blocking) catalog search.  Only the user's configured
-- URL gets the full timeout.
local function requestWithSeedFallback(path, method, headers, body)
    local bases = {}
    local seen = {}
    local function add(base)
        if base and base ~= "" then
            local cleaned = base:gsub("/$", "")
            if not seen[cleaned] then
                seen[cleaned] = true
                bases[#bases + 1] = cleaned
            end
        end
    end
    local configured = settings():readSetting(SETTINGS_BASE_URL_KEY)
    add(configured)
    for _, seed in ipairs(SEED_URLS) do add(seed) end

    local last_err = "All Z-Library mirrors are unreachable"
    local max_attempts = configured and (1 + 3) or 4
    for index, base in ipairs(bases) do
        if index > max_attempts then break end
        local timeout = (configured and index == 1)
            and ZlibraryProvider.timeout or ZlibraryProvider.probe_timeout
        local payload, err, transport_error = requestJson(base .. path, method, headers, body, timeout)
        if payload then
            -- Third return value: the full URL that worked, for callers that
            -- need a referer on the same host (e.g. the download request).
            return payload, nil, base .. path
        end
        last_err = err
        -- Only advance to another mirror on a transport failure.  A reachable
        -- mirror that returns an error (rate limit, service down) is the real
        -- answer — stop probing.
        if not transport_error then
            break
        end
    end
    return nil, last_err
end

-- ---------------------------------------------------------------- api

-- Signs in and stores the session. Returns true, or nil, err.
function ZlibraryProvider.login(email, password)
    local body_parts = {}
    for key, value in pairs({ email = email or "", password = password or "" }) do
        body_parts[#body_parts + 1] = util.urlEncode(key) .. "=" .. util.urlEncode(value)
    end
    local body = table.concat(body_parts, "&")
    local payload, err = requestWithSeedFallback("/eapi/user/login", "POST", {
        ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["User-Agent"] = USER_AGENT,
        ["X-Requested-With"] = "XMLHttpRequest",
        ["Content-Length"] = tostring(#body),
    }, body)
    if not payload then return nil, err end

    if tonumber(payload.success) ~= 1 then
        local api_message = (type(payload.error) == "table" and payload.error.message)
            or payload.error or payload.message
        return nil, api_message and tostring(api_message) or "Login failed"
    end

    local session = payload.user or payload.response or {}
    local user_id = tostring(session.id or session.user_id or "")
    local user_key = session.remix_userkey or session.user_key or ""
    if user_id == "" or user_key == "" then
        return nil, "Credentials rejected or invalid response"
    end
    ZlibraryProvider.saveCredentials(email, password, user_id, user_key)
    return true
end

-- ---------------------------------------------------------------- book mapping

local function scalar(value, fallback)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    end
    return fallback
end

-- A cover that has no host (the API's "/img/cover-not-exists.png" placeholder)
-- is treated as absent so Bookdrop never fetches it.
local function usableCoverUrl(cover)
    if type(cover) ~= "string" or cover == "" then return nil end
    local parsed = url.parse(cover)
    if not (parsed and parsed.host) then return nil end
    return cover
end

local function bookFromApi(api_book, page)
    if not api_book or not api_book.id then return nil end
    local extension = scalar(api_book.extension, "")
    return {
        id = "zlibrary-" .. tostring(api_book.id) .. (api_book.hash and ("-" .. api_book.hash) or ""),
        provider = "zlibrary",
        provider_id = tostring(api_book.id),
        hash = api_book.hash,
        title = scalar(api_book.title, "Unknown Title"),
        author = scalar(api_book.author, "Unknown Author"),
        year = scalar(api_book.year, ""),
        language = scalar(api_book.language, ""),
        format = extension ~= "" and extension:upper() or "EBOOK",
        available_formats = extension ~= "" and extension:upper() or nil,
        size = scalar(api_book.filesizeString or api_book.filesize, nil),
        rating = scalar(api_book.interestScore, nil),
        description = scalar(api_book.description, nil),
        cover_url = usableCoverUrl(api_book.cover),
        source = "Z-Library",
        acquisitions = {},
    }
end

-- ---------------------------------------------------------------- provider api

-- Bookdrop provider interface: search(query, page, filters) ->
-- { books, total, page, has_previous, has_next } or nil, err.
function ZlibraryProvider:search(query, page, filters)
    filters = filters or {}
    local current_page = math.max(1, tonumber(page) or 1)

    local credentials = ZlibraryProvider.getCredentials()
    local body_parts = {
        "message=" .. util.urlEncode(query or ""),
        "page=" .. util.urlEncode(tostring(current_page)),
        "limit=" .. util.urlEncode(tostring(self.page_size)),
    }
    local language = filters.language
    if language and language ~= "" and LANGUAGE_MAP[language] then
        body_parts[#body_parts + 1] = "languages[0]=" .. util.urlEncode(LANGUAGE_MAP[language])
    end
    if type(filters.formats) == "table" then
        local index = 0
        for format_key, extension in pairs(FORMAT_MAP) do
            if filters.formats[format_key] then
                body_parts[#body_parts + 1] = string.format("extensions[%d]=%s", index, util.urlEncode(extension))
                index = index + 1
            end
        end
    end
    local sort = SORT_MAP[filters.sort]
    if sort then
        body_parts[#body_parts + 1] = "order=" .. util.urlEncode(sort)
    end

    local body = table.concat(body_parts, "&")
    local payload, err = requestWithSeedFallback("/eapi/book/search", "POST",
        authedHeaders(credentials.user_id, credentials.user_key, body), body)
    if not payload then return nil, err end

    if payload.error then
        return nil, "Z-Library search error: " .. tostring(payload.error)
    end

    local api_books = {}
    if type(payload.books) == "table" then
        api_books = payload.books
    elseif payload.exactMatch and type(payload.exactMatch.books) == "table" then
        api_books = payload.exactMatch.books
    end

    local books = {}
    for _, api_book in ipairs(api_books) do
        local book = bookFromApi(api_book, current_page)
        if book then books[#books + 1] = book end
    end

    local total = tonumber(payload.pagination and payload.pagination.total_items)
        or tonumber(payload.exactBooksCount) or #books
    return {
        books = books,
        total = total,
        page = current_page,
        has_previous = current_page > 1,
        has_next = current_page * self.page_size < total,
    }
end

-- Bookdrop provider interface: hydrate(book) -> enriched book (or nil, err).
-- Resolves the download link, which requires a signed-in session.
function ZlibraryProvider:hydrate(book)
    if not book or not book.provider_id or not book.hash then
        return nil, "Book identifiers missing"
    end
    local credentials = ZlibraryProvider.getCredentials()
    if not credentials.user_id or not credentials.user_key then
        return nil, "Z-Library sign-in required to download. Sign in in Bookdrop settings."
    end

    local details_path = string.format("/eapi/book/%s/%s", book.provider_id, book.hash)
    local link_path = string.format("/eapi/book/%s/%s/file", book.provider_id, book.hash)

    local details, err, details_url = requestWithSeedFallback(details_path, "GET", authedHeaders(credentials.user_id, credentials.user_key))
    if not details then return nil, err end
    if tonumber(details.success) ~= 1 or not details.book then
        return nil, details.message or "Z-Library could not load this book's details."
    end
    local api_book = details.book
    if api_book.title then book.title = scalar(api_book.title, book.title) end
    if api_book.author then book.author = scalar(api_book.author, book.author) end
    if api_book.description then book.description = scalar(api_book.description, nil) end
    if api_book.extension then
        book.format = api_book.extension:upper()
        book.available_formats = api_book.extension:upper()
    end
    if api_book.filesizeString then book.size = scalar(api_book.filesizeString, nil) end

    local link_result, link_err = requestWithSeedFallback(link_path, "GET",
        authedHeaders(credentials.user_id, credentials.user_key))
    if not link_result then return nil, link_err end
    if tonumber(link_result.success) ~= 1 or not link_result.file then
        return nil, link_result.message or "Z-Library could not resolve a download link."
    end

    local file_data = link_result.file
    local download_link = file_data.downloadLink
    if not download_link then
        if file_data.allowDownload == false then
            return nil, "Download limit reached. Please try again later or check your account."
        end
        return nil, "No download link provided."
    end

    local extension = file_data.extension or (book.format ~= "EBOOK" and book.format:lower()) or "epub"
    book.format = extension:upper()
    book.available_formats = extension:upper()
    book.acquisitions = {{
        url = download_link,
        extension = extension,
        format = extension:upper(),
        size = api_book.filesize,
        referer = details_url,
    }}
    return book
end

return ZlibraryProvider
