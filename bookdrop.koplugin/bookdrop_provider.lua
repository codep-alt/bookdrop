local JSON = require("rapidjson")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")

local Provider = {
    name = "Internet Archive",
    page_size = 10,
    max_response_bytes = 4 * 1024 * 1024,
}

local API_BASE = "https://archive.org"
local SUPPORTED_FORMATS = {
    epub = { mime = "application/epub+zip", rank = 1 },
    azw3 = { mime = "application/vnd.amazon.ebook", rank = 2 },
    mobi = { mime = "application/x-mobipocket-ebook", rank = 3 },
    pdf = { mime = "application/pdf", rank = 4 },
    djvu = { mime = "image/vnd.djvu", rank = 5 },
    cbz = { mime = "application/vnd.comicbook+zip", rank = 6 },
    txt = { mime = "text/plain", rank = 7 },
}

-- Internet Archive's indexed format names do not always match the file
-- extensions exposed by its metadata endpoint. Keep these expressions
-- explicit so the filter only offers choices that return useful results.
local FORMAT_SEARCH = {
    epub = "format:EPUB",
    mobi = "format:MOBI",
    pdf = '(format:PDF OR format:"Text PDF")',
    djvu = "format:DjVu",
    cbz = 'format:"Comic Book ZIP"',
    txt = "format:DjVuTXT",
}
local FORMAT_ORDER = { "epub", "pdf", "mobi", "djvu", "cbz", "txt" }

local SORTS = {
    newest = "date desc",
    oldest = "date asc",
    title = "titleSorter asc",
}

local SUBJECTS = {
    book_fiction = "fiction",
    book_nonfiction = "nonfiction",
    book_comic = "comic books",
    magazine = "periodicals",
}

local LANGUAGES = {
    en = "English", es = "Spanish", fr = "French", de = "German",
    ru = "Russian", pt = "Portuguese", it = "Italian", zh = "Chinese",
    ja = "Japanese",
}

local function scalar(value, fallback)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    elseif type(value) == "table" then
        for _, item in ipairs(value) do
            if type(item) == "string" or type(item) == "number" then
                return tostring(item)
            end
        end
    end
    return fallback
end

local function listText(value, separator)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    elseif type(value) == "table" then
        local values = {}
        for _, item in ipairs(value) do
            if type(item) == "string" or type(item) == "number" then
                values[#values + 1] = tostring(item)
            end
        end
        return table.concat(values, separator or ", ")
    end
    return ""
end

local function requestJson(request_url)
    local chunks, received, too_large = {}, 0, false
    local sink = function(chunk)
        if chunk then
            received = received + #chunk
            if received > Provider.max_response_bytes then
                too_large = true
                return nil, "response is too large"
            end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, _, status = http.request{
        url = request_url,
        method = "GET",
        redirect = true,
        headers = {
            ["Accept"] = "application/json",
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader Bookdrop/0.5",
        },
        sink = sink,
    }
    socketutil:reset_timeout()
    if too_large then return nil, "Internet Archive response exceeded 4 MiB" end
    if not ok or tonumber(code) ~= 200 then
        return nil, status or ("HTTP " .. tostring(code))
    end
    local parsed_ok, payload = pcall(JSON.decode, table.concat(chunks))
    if not parsed_ok or type(payload) ~= "table" then
        return nil, "Internet Archive returned invalid JSON"
    end
    return payload
end

local function quoted(value)
    value = tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. value .. '"'
end

local function searchExpression(query, filters)
    local clauses = {
        "mediatype:texts",
        "NOT access-restricted-item:true",
        '(format:EPUB OR format:MOBI OR format:PDF OR format:DjVu '
            .. 'OR format:"Text PDF" OR format:"Comic Book ZIP" OR format:DjVuTXT)',
    }
    if query and query:match("%S") then
        local term = quoted(query)
        clauses[#clauses + 1] = "(title:" .. term .. " OR creator:" .. term .. " OR subject:" .. term .. ")"
    end
    filters = filters or {}
    if SUBJECTS[filters.content] then
        clauses[#clauses + 1] = "subject:" .. quoted(SUBJECTS[filters.content])
    end
    if filters.language and LANGUAGES[filters.language] then
        clauses[#clauses + 1] = "language:" .. quoted(LANGUAGES[filters.language])
    end
    if type(filters.formats) == "table" then
        local selected = {}
        for _, format_name in ipairs(FORMAT_ORDER) do
            if filters.formats[format_name] then
                selected[#selected + 1] = FORMAT_SEARCH[format_name]
            end
        end
        if #selected == 0 then
            clauses[#clauses + 1] = 'identifier:""'
        elseif #selected < #FORMAT_ORDER then
            clauses[#clauses + 1] = "(" .. table.concat(selected, " OR ") .. ")"
        end
    elseif FORMAT_SEARCH[filters.extension] then
        -- Read old saved settings created before format filters became
        -- multi-select checkboxes.
        clauses[#clauses + 1] = FORMAT_SEARCH[filters.extension]
    end
    return table.concat(clauses, " AND ")
end

local function searchUrl(query, page, filters)
    filters = filters or {}
    local parts = {
        API_BASE .. "/advancedsearch.php?q=" .. url.escape(searchExpression(query, filters)),
        "rows=" .. tostring(Provider.page_size),
        "page=" .. tostring(math.max(1, tonumber(page) or 1)),
        "output=json",
        "sort%5B%5D=" .. url.escape(SORTS[filters.sort] or "downloads desc"),
    }
    for _, field in ipairs({
        "identifier", "title", "creator", "description", "language", "date",
        "downloads", "subject", "publisher", "format", "isbn",
    }) do
        parts[#parts + 1] = "fl%5B%5D=" .. url.escape(field)
    end
    return table.concat(parts, "&")
end

local function hasIndexedFormat(formats, format_name)
    local text = listText(formats, " "):lower()
    if format_name == "epub" then return text:find("epub", 1, true) ~= nil end
    if format_name == "mobi" then return text:find("mobi", 1, true) ~= nil end
    if format_name == "pdf" then return text:find("pdf", 1, true) ~= nil end
    if format_name == "cbz" then
        return text:find("comic book zip", 1, true) ~= nil or text:find("cbz", 1, true) ~= nil
    end
    if format_name == "djvu" or format_name == "txt" then
        local indexed_formats = type(formats) == "table" and formats or { formats }
        for _, indexed_format in ipairs(indexed_formats) do
            local normalized = tostring(indexed_format):lower()
            if format_name == "djvu" and normalized == "djvu" then return true end
            if format_name == "txt" and normalized == "djvutxt" then return true end
        end
    end
    return false
end

local function displayFormat(formats, selected_formats)
    if type(selected_formats) == "table" then
        for _, format_name in ipairs(FORMAT_ORDER) do
            if selected_formats[format_name] and hasIndexedFormat(formats, format_name) then
                return format_name:upper()
            end
        end
    end
    local text = listText(formats, " "):lower()
    if text:find("epub", 1, true) then return "EPUB" end
    if text:find("mobi", 1, true) then return "MOBI" end
    if text:find("pdf", 1, true) then return "PDF" end
    if text:find("djvu", 1, true) then return "DJVU" end
    return "EBOOK"
end

local function availableIndexedFormats(formats)
    local available = {}
    for format_number = 1, #FORMAT_ORDER do
        local format_name = FORMAT_ORDER[format_number]
        if hasIndexedFormat(formats, format_name) then
            available[#available + 1] = format_name:upper()
        end
    end
    return table.concat(available, " · ")
end

local function contentType(subjects)
    local text = listText(subjects, " "):lower()
    if text:find("comic", 1, true) then return "Comic" end
    if text:find("periodical", 1, true) or text:find("magazine", 1, true) then return "Magazine" end
    if text:find("fiction", 1, true) then return "Book (fiction)" end
    return "Book (non-fiction)"
end

local function bookFromDoc(doc, filters)
    local identifier = scalar(doc.identifier)
    if not identifier then return nil end
    local date = scalar(doc.date, "")
    local isbn = scalar(doc.isbn)
    local archive_cover = API_BASE .. "/services/img/" .. url.escape(identifier)
    local selected_formats
    if filters and type(filters.formats) == "table" then
        selected_formats = {}
        for format_name, enabled in pairs(filters.formats) do
            if enabled then selected_formats[format_name] = true end
        end
    end
    return {
        id = identifier,
        provider_id = identifier,
        title = scalar(doc.title, "Untitled"),
        author = scalar(doc.creator, "Unknown author"),
        description = listText(doc.description, "\n\n"),
        language = listText(doc.language),
        published_date = date,
        year = date:match("^(%d%d%d%d)"),
        publisher = listText(doc.publisher),
        isbn = listText(doc.isbn),
        subjects = listText(doc.subject, " · "),
        format = displayFormat(doc.format, selected_formats),
        available_formats = availableIndexedFormats(doc.format),
        allowed_formats = selected_formats,
        content_type = contentType(doc.subject),
        source = "Internet Archive",
        cover_url = isbn and ("https://covers.openlibrary.org/b/isbn/"
            .. url.escape(isbn) .. "-M.jpg?default=false") or archive_cover,
        cover_fallback_url = isbn and archive_cover or nil,
        downloads = scalar(doc.downloads),
    }
end

local function fileExtension(filename)
    local extension = tostring(filename or ""):match("%.([%w]+)$")
    return extension and extension:lower() or nil
end

local function acquisitions(identifier, files, allowed_formats)
    local selected = {}
    for _, file in ipairs(files or {}) do
        local extension = fileExtension(file.name)
        local format = extension and SUPPORTED_FORMATS[extension]
        local public = file.private ~= true and file.private ~= "true"
        local allowed = not allowed_formats or allowed_formats[extension]
        if format and allowed and public and file.name and file.name ~= "" then
            local score = file.source == "original" and 2 or 1
            if not selected[extension] or score > selected[extension].score then
                selected[extension] = { file = file, format = format, extension = extension, score = score }
            end
        end
    end
    local ordered = {}
    for _, candidate in pairs(selected) do ordered[#ordered + 1] = candidate end
    table.sort(ordered, function(a, b) return a.format.rank < b.format.rank end)
    local result = {}
    for _, candidate in ipairs(ordered) do
        result[#result + 1] = {
            type = candidate.format.mime,
            format = candidate.extension:upper(),
            extension = candidate.extension,
            url = API_BASE .. "/download/" .. url.escape(identifier) .. "/" .. url.escape(candidate.file.name),
            size = tonumber(candidate.file.size),
            md5 = candidate.file.md5,
            source = candidate.file.source,
            archive_format = candidate.file.format,
        }
    end
    return result
end

function Provider:search(query, page, filters)
    local current_page = math.max(1, tonumber(page) or 1)
    local payload, err = requestJson(searchUrl(query, current_page, filters))
    if not payload then return nil, err end
    local response = payload.response
    if type(response) ~= "table" or type(response.docs) ~= "table" then
        return nil, "Internet Archive search response was incomplete"
    end
    local books = {}
    for _, doc in ipairs(response.docs) do
        local book = bookFromDoc(doc, filters)
        if book then books[#books + 1] = book end
    end
    local found = tonumber(response.numFound) or 0
    return {
        books = books,
        total = found,
        page = current_page,
        last_page = math.max(1, math.ceil(found / self.page_size)),
        has_previous = current_page > 1,
        has_next = current_page * self.page_size < found,
    }
end

function Provider:hydrate(book)
    if not book or not book.provider_id then return nil, "Book identifier is missing" end
    local payload, err = requestJson(API_BASE .. "/metadata/" .. url.escape(book.provider_id))
    if not payload then return nil, err end
    local metadata = type(payload.metadata) == "table" and payload.metadata or {}
    if metadata["access-restricted-item"] == true or metadata["access-restricted-item"] == "true" then
        return nil, "This Internet Archive item is restricted"
    end
    book.title = scalar(metadata.title, book.title)
    book.subtitle = scalar(metadata.subtitle, book.subtitle)
    book.author = scalar(metadata.creator, book.author)
    local description = listText(metadata.description, "\n\n")
    if description ~= "" then book.description = description end
    local language = listText(metadata.language)
    if language ~= "" then book.language = language end
    local date = scalar(metadata.date, "")
    if date ~= "" then book.published_date = date end
    book.year = date:match("^(%d%d%d%d)") or book.year
    book.publisher = listText(metadata.publisher) ~= "" and listText(metadata.publisher) or book.publisher
    book.publication_place = scalar(metadata.place, book.publication_place)
    book.original_publication_date = scalar(metadata.originaldate, book.original_publication_date)
    book.edition = scalar(metadata.edition, book.edition)
    book.series = scalar(metadata.series, book.series)
    book.volume = scalar(metadata.volume, book.volume)
    book.isbn = listText(metadata.isbn) ~= "" and listText(metadata.isbn) or book.isbn
    book.subjects = listText(metadata.subject, " · ") ~= ""
        and listText(metadata.subject, " · ") or book.subjects
    book.contributors = listText(metadata.contributor)
    book.notes = listText(metadata.notes, "\n")
    book.page_count = scalar(metadata.pages,
        scalar(metadata.page_count, scalar(metadata.imagecount, book.page_count)))
    book.rights = scalar(metadata.rights, scalar(metadata.licenseurl, book.rights))
    book.collection = listText(metadata.collection)
    book.downloads = scalar(metadata.downloads, book.downloads)
    local all_acquisitions = acquisitions(book.provider_id, payload.files)
    local available_formats = {}
    for _, acquisition in ipairs(all_acquisitions) do
        available_formats[#available_formats + 1] = acquisition.format
    end
    book.available_formats = table.concat(available_formats, " · ")
    -- Filters decide which records appear in results. Once a record is open,
    -- expose every compatible public file attached to it.
    book.acquisitions = all_acquisitions
    local preferred_acquisition
    for _, acquisition in ipairs(book.acquisitions) do
        if not book.allowed_formats or book.allowed_formats[acquisition.extension] then
            preferred_acquisition = acquisition
            break
        end
    end
    preferred_acquisition = preferred_acquisition or book.acquisitions[1]
    if preferred_acquisition then
        book.format = preferred_acquisition.format
        if preferred_acquisition.size then
            book.size = string.format("%.1f MB", preferred_acquisition.size / 1024 / 1024)
        end
    end
    return book
end

return Provider
