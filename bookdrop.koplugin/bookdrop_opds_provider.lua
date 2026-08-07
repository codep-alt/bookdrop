local ffi = require("ffi")
local http = require("socket.http")
local luxl = require("luxl")
local socketutil = require("socketutil")
local url = require("socket.url")

local OPDS = {
    page_size = 10,
    max_response_bytes = 6 * 1024 * 1024,
}

OPDS.sources = {
    gutenberg = {
        name = "Project Gutenberg",
        home = "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads",
        newest = "https://www.gutenberg.org/ebooks/search.opds/?sort_order=release_date",
        title = "https://www.gutenberg.org/ebooks/search.opds/?sort_order=title",
        search = "https://www.gutenberg.org/ebooks/search.opds/?query=%s",
    },
    standardebooks = {
        name = "Standard Ebooks",
        home = "https://standardebooks.org/feeds/opds/all?per-page=10&page=%d",
        search = "https://standardebooks.org/feeds/opds/all?query=%s&per-page=10&page=%d",
        default_language = "en",
        direct_page = true,
    },
    textos = {
        name = "textos.info",
        home = "https://www.textos.info/populares.atom",
        newest = "https://www.textos.info/novedades.atom",
        search = "https://www.textos.info/busqueda.atom?query=%s",
        default_language = "es",
    },
    gallica = {
        name = "Gallica",
        home = "https://gallica.bnf.fr/services/engine/search/opds?operation=searchRetrieve&version=1.2&exactSearch=false&query=dc.formatspecific%20all%20%22epub%22%20sortby%20indexationdate%2Fsort.descending&filter=provenance%20all%20%22bnf.fr%22",
        search = "https://gallica.bnf.fr/services/engine/search/opds?operation=searchRetrieve&version=1.2&exactSearch=false&query=%s&filter=provenance%%20all%%20%%22bnf.fr%%22",
        default_language = "fr",
    },
}

local FORMAT_ORDER = { "epub", "azw3", "mobi", "pdf", "djvu", "cbz", "txt" }
local FORMAT_LABELS = {
    epub = "EPUB", azw3 = "AZW3", mobi = "MOBI", pdf = "PDF",
    djvu = "DJVU", cbz = "CBZ", txt = "TXT",
}

local entities = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
}

local function decodeEntities(value)
    value = tostring(value or "")
    value = value:gsub("&#x([%da-fA-F]+);", function(number)
        local codepoint = tonumber(number, 16)
        return codepoint and require("util").unicodeCodepointToUtf8(codepoint) or ""
    end)
    value = value:gsub("&#(%d+);", function(number)
        local codepoint = tonumber(number)
        return codepoint and require("util").unicodeCodepointToUtf8(codepoint) or ""
    end)
    return value:gsub("&([%a]+);", function(entity)
        return entities[entity] or ("&" .. entity .. ";")
    end)
end

local function parseXml(xml)
    xml = tostring(xml or "")
        :gsub("<%?xml.-%?>", "")
        :gsub("<%?xml%-stylesheet.-%?>", "")
        :gsub("<!%-%-.-%-%->", "")
    xml = xml:gsub("<!%[CDATA%[(.-)%]%]>", function(value)
        return value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    end)

    local lexer = luxl.new(xml, #xml)
    local root = { name = "_root", attributes = {}, children = {}, text = "" }
    local stack = { root }
    local attribute_name
    for event, offset, size in lexer:Lexemes() do
        local value = ffi.string(lexer.buf + offset, size)
        if event == luxl.EVENT_START then
            local node = { name = value, attributes = {}, children = {}, text = "" }
            local parent = stack[#stack]
            parent.children[#parent.children + 1] = node
            stack[#stack + 1] = node
        elseif event == luxl.EVENT_ATTR_NAME then
            attribute_name = decodeEntities(value)
        elseif event == luxl.EVENT_ATTR_VAL then
            if attribute_name then
                stack[#stack].attributes[attribute_name] = decodeEntities(value)
                attribute_name = nil
            end
        elseif event == luxl.EVENT_TEXT then
            local current = stack[#stack]
            current.text = current.text .. decodeEntities(value)
        elseif event == luxl.EVENT_END and #stack > 1 then
            stack[#stack] = nil
        end
    end
    return root.children[1]
end

local function children(node, name)
    local found = {}
    for _, child in ipairs(node and node.children or {}) do
        if child.name == name then found[#found + 1] = child end
    end
    return found
end

local function child(node, ...)
    for name_number = 1, select("#", ...) do
        local name = select(name_number, ...)
        for _, candidate in ipairs(node and node.children or {}) do
            if candidate.name == name then return candidate end
        end
    end
end

local function nodeText(node)
    if not node then return "" end
    local pieces = { node.text or "" }
    for _, nested in ipairs(node.children or {}) do
        pieces[#pieces + 1] = nodeText(nested)
    end
    local cleaned = table.concat(pieces, " "):gsub("<.->", " "):gsub("%s+", " ")
        :gsub("^%s+", ""):gsub("%s+$", "")
    return cleaned
end

local function requestPayload(request_url, accept)
    local chunks, received, too_large = {}, 0, false
    local sink = function(chunk)
        if chunk then
            received = received + #chunk
            if received > OPDS.max_response_bytes then
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
            ["Accept"] = accept or "application/atom+xml, application/xml",
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader Bookdrop/0.6",
        },
        sink = sink,
    }
    socketutil:reset_timeout()
    if too_large then return nil, "OPDS response exceeded 6 MiB" end
    if not ok or tonumber(code) ~= 200 then return nil, status or ("HTTP " .. tostring(code)) end
    local payload = table.concat(chunks)
    if payload == "" then return nil, "Catalog returned an empty response" end
    return payload
end

local function requestXml(request_url)
    local payload, err = requestPayload(request_url)
    if not payload then return nil, err end
    local parsed_ok, document = pcall(parseXml, payload)
    if not parsed_ok or type(document) ~= "table" or document.name ~= "feed" then
        return nil, "Server did not return an OPDS feed"
    end
    return document
end

local function stableId(source_id, raw_id)
    local hash = 5381
    for character_number = 1, #raw_id do
        hash = (hash * 33 + raw_id:byte(character_number)) % 2147483647
    end
    return source_id .. "-" .. tostring(hash)
end

local function absolute(base_url, href)
    if not href or href == "" then return nil end
    local resolved = url.absolute(base_url, href)
    return resolved:gsub("^http://gallica%.bnf%.fr", "https://gallica.bnf.fr")
end

local function extensionFromLink(link)
    local mime = tostring(link.attributes.type or ""):lower()
    local href = tostring(link.attributes.href or ""):lower():gsub("[?#].*$", "")
    local title = tostring(link.attributes.title or ""):lower()
    if mime:find("epub", 1, true) then return "epub" end
    if mime:find("pdf", 1, true) then return "pdf" end
    if mime:find("djvu", 1, true) then return "djvu" end
    if mime:find("comicbook", 1, true) or href:match("%.cbz$") then return "cbz" end
    if mime:find("text/plain", 1, true) or href:match("%.txt$") then return "txt" end
    if mime:find("mobipocket", 1, true) then
        if href:match("%.azw3$") or title:find("azw3", 1, true) then return "azw3" end
        return "mobi"
    end
    return nil
end

local function acquisitionScore(link, extension)
    local title = tostring(link.attributes.title or ""):lower()
    local score = 1
    if title:find("recommended", 1, true) then score = score + 8 end
    if title:find("epub3", 1, true) then score = score + 6 end
    if title:find("images", 1, true) and not title:find("no images", 1, true) then score = score + 4 end
    if title:find("no images", 1, true) then score = score - 1 end
    if extension == "epub" then score = score + 2 end
    return score
end

local function acquisitionAllowed(extension, formats)
    if type(formats) ~= "table" then return true end
    if extension == "azw3" then return formats.mobi == true end
    return formats[extension] == true
end

local function collectAcquisitions(entry, base_url, formats)
    local selected = {}
    for _, link in ipairs(children(entry, "link")) do
        local relation = tostring(link.attributes.rel or "")
        local extension = relation:find("acquisition", 1, true) and extensionFromLink(link)
        local href = absolute(base_url, link.attributes.href)
        if extension and href and acquisitionAllowed(extension, formats) then
            local candidate = {
                type = link.attributes.type,
                format = FORMAT_LABELS[extension],
                extension = extension,
                url = href,
                size = tonumber(link.attributes.length),
                source = "catalog",
                label = link.attributes.title,
                score = acquisitionScore(link, extension),
            }
            if not selected[extension] or candidate.score > selected[extension].score then
                selected[extension] = candidate
            end
        end
    end
    local acquisitions = {}
    for _, extension in ipairs(FORMAT_ORDER) do
        if selected[extension] then acquisitions[#acquisitions + 1] = selected[extension] end
    end
    return acquisitions
end

local function availableFormats(acquisitions)
    local formats = {}
    for _, acquisition in ipairs(acquisitions or {}) do formats[#formats + 1] = acquisition.format end
    return table.concat(formats, " · ")
end

local function hasAllowedAcquisition(acquisitions, formats)
    if type(formats) ~= "table" then return #acquisitions > 0 end
    for _, acquisition in ipairs(acquisitions) do
        if acquisitionAllowed(acquisition.extension, formats) then return true end
    end
    return false
end

local function gutenbergFormatAllowed(formats)
    if type(formats) ~= "table" then return true end
    return formats.epub == true or formats.mobi == true or formats.txt == true
end

local function entryCategories(entry)
    local categories = {}
    for _, category in ipairs(children(entry, "category")) do
        local term = category.attributes.label or category.attributes.term
        if term and term ~= "" then categories[#categories + 1] = term end
    end
    return table.concat(categories, " · ")
end

local function contentType(subjects)
    local value = tostring(subjects or ""):lower()
    if value:find("comic", 1, true) then return "Comic" end
    if value:find("magazine", 1, true) or value:find("periodical", 1, true) then return "Magazine" end
    if value:find("fiction", 1, true) or value:find("novela", 1, true)
        or value:find("cuento", 1, true) then return "Book (fiction)" end
    return "Book (non-fiction)"
end

local function matchesContent(book, requested)
    if not requested or requested == "" or not book.subjects or book.subjects == "" then return true end
    local actual = tostring(book.content_type or ""):lower()
    if requested == "book_fiction" then return actual == "book (fiction)" end
    if requested == "book_nonfiction" then return actual == "book (non-fiction)" end
    if requested == "book_comic" then return actual == "comic" end
    if requested == "magazine" then return actual == "magazine" end
    return true
end

local LANGUAGE_ALIASES = {
    en = "en", eng = "en", english = "en",
    es = "es", spa = "es", spanish = "es",
    fr = "fr", fre = "fr", fra = "fr", french = "fr",
    de = "de", ger = "de", deu = "de", german = "de",
    it = "it", ita = "it", italian = "it",
    pt = "pt", por = "pt", portuguese = "pt",
}

local function normalizedLanguage(language)
    local first = tostring(language or ""):lower():match("^%s*([%a]+)")
    return first and (LANGUAGE_ALIASES[first] or first) or nil
end

local function entryToBook(entry, base_url, source_id, source, filters)
    local title = nodeText(child(entry, "title"))
    local raw_id = nodeText(child(entry, "id", "dc:identifier", "dcterms:identifier"))
    if title == "" or raw_id == "" then return nil end

    local detail_url
    local cover_url, fallback_cover
    for _, link in ipairs(children(entry, "link")) do
        local relation = tostring(link.attributes.rel or "")
        local href = absolute(base_url, link.attributes.href)
        if href and not href:match("^https?://") then href = nil end
        if relation:find("image/thumbnail", 1, true) then
            cover_url = href
        elseif relation:find("/image", 1, true) then
            fallback_cover = href
        elseif source_id == "gutenberg" and relation == "subsection"
            and href and href:match("/ebooks/%d+%.opds") then
            detail_url = href
        end
    end

    local author_names = {}
    for _, author in ipairs(children(entry, "author")) do
        local name = nodeText(child(author, "name"))
        if name ~= "" then author_names[#author_names + 1] = name end
    end
    local description = nodeText(child(entry, "summary", "content"))
    local author = table.concat(author_names, ", ")
    if author == "" and source_id == "gutenberg" and description ~= "" then
        author, description = description, ""
    end

    local acquisitions = collectAcquisitions(entry, base_url)
    if #acquisitions == 0 and not detail_url then return nil end
    if source_id == "gutenberg" and detail_url
        and not gutenbergFormatAllowed(filters and filters.formats) then return nil end
    if #acquisitions > 0 and filters and type(filters.formats) == "table"
        and not hasAllowedAcquisition(acquisitions, filters.formats) then return nil end
    local language = nodeText(child(entry, "dcterms:language", "dc:language", "language"))
    if language == "" then language = source.default_language or "" end
    if filters and filters.language and normalizedLanguage(language) ~= filters.language then return nil end

    local subjects = entryCategories(entry)
    local published = nodeText(child(entry, "published", "dc:issued", "dcterms:issued"))
    local book = {
        id = stableId(source_id, raw_id),
        provider = source_id,
        provider_id = raw_id,
        detail_url = detail_url,
        title = title,
        author = author ~= "" and author or "Unknown author",
        description = description,
        language = language,
        published_date = published,
        year = published:match("(%d%d%d%d)"),
        publisher = nodeText(child(entry, "dc:publisher", "dcterms:publisher", "publisher")),
        subjects = subjects,
        rights = nodeText(child(entry, "rights", "dc:rights", "dcterms:rights")),
        size = nodeText(child(entry, "dcterms:extent")),
        format = acquisitions[1] and acquisitions[1].format or "EBOOK",
        available_formats = availableFormats(acquisitions),
        allowed_formats = filters and filters.formats,
        content_type = contentType(subjects),
        source = source.name,
        cover_url = cover_url or fallback_cover,
        cover_fallback_url = cover_url and fallback_cover or nil,
        acquisitions = acquisitions,
    }
    if source_id == "gutenberg" and not book.cover_url then
        local ebook_number = (detail_url or raw_id):match("/ebooks/(%d+)")
        if ebook_number then
            book.cover_url = "https://www.gutenberg.org/cache/epub/" .. ebook_number
                .. "/pg" .. ebook_number .. ".cover.medium.jpg"
        end
    end
    if source_id == "gutenberg" and #acquisitions == 0 then
        book.available_formats = "EPUB · MOBI · TXT"
        if filters and filters.formats and filters.formats.epub then
            book.format = "EPUB"
        elseif filters and filters.formats and filters.formats.mobi then
            book.format = "MOBI"
        elseif filters and filters.formats and filters.formats.txt then
            book.format = "TXT"
        end
    end
    return matchesContent(book, filters and filters.content) and book or nil
end

local function feedInfo(document, request_url, source_id, source, filters)
    local books = {}
    for _, entry in ipairs(children(document, "entry")) do
        local book = entryToBook(entry, request_url, source_id, source, filters)
        if book then books[#books + 1] = book end
    end
    local total = tonumber(nodeText(child(document, "opensearch:totalResults"))) or #books
    local next_url
    for _, link in ipairs(children(document, "link")) do
        if link.attributes.rel == "next" then
            next_url = absolute(request_url, link.attributes.href)
            break
        end
    end
    return books, total, next_url
end

local function sourceUrl(source_id, source, query, page, filters)
    local escaped_query = url.escape(query or "")
    if source_id == "gallica" and query and query:match("%S") then
        local clauses = {}
        for word in query:gsub('"', ""):gmatch("%S+") do
            clauses[#clauses + 1] = '(gallica all "' .. word .. '")'
        end
        local expression = table.concat(clauses, " and ")
            .. ' and dc.formatspecific all "epub"'
        return string.format(source.search, url.escape(expression))
    end
    if query and query:match("%S") then
        if source.direct_page then return string.format(source.search, escaped_query, page) end
        return string.format(source.search, escaped_query)
    end
    if filters and source[filters.sort] then
        return source[filters.sort]
    end
    if source.direct_page then return string.format(source.home, page) end
    return source.home
end

-- textos.info's multi-word search occasionally omits books whose titles are an
-- obvious match (for example, "el gato" does not return "El Gato Negro", while
-- "gato" does).  Keep the catalog as the source of truth, but supplement a bad
-- multi-word response with a small number of single-term catalog searches.
local SEARCH_STOP_WORDS = {
    a = true, al = true, de = true, del = true, el = true, en = true,
    la = true, las = true, los = true, un = true, una = true, y = true,
}

local function normalizeSearchText(value)
    value = tostring(value or "")
    local replacements = {
        { "[ÁÀÂÄÃáàâäã]", "a" }, { "[ÉÈÊËéèêë]", "e" },
        { "[ÍÌÎÏíìîï]", "i" }, { "[ÓÒÔÖÕóòôöõ]", "o" },
        { "[ÚÙÛÜúùûü]", "u" }, { "[Ññ]", "n" }, { "[Çç]", "c" },
    }
    for _, replacement in ipairs(replacements) do
        value = value:gsub(replacement[1], replacement[2])
    end
    return value:lower():gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function significantSearchTerms(query)
    local terms, seen = {}, {}
    for term in normalizeSearchText(query):gmatch("%S+") do
        if #term > 1 and not SEARCH_STOP_WORDS[term] and not seen[term] then
            seen[term] = true
            terms[#terms + 1] = term
            if #terms == 3 then break end
        end
    end
    return terms
end

local function titleContainsTerms(book, terms)
    if #terms == 0 then return false end
    local title = " " .. normalizeSearchText(book.title) .. " "
    for _, term in ipairs(terms) do
        if not title:find(" " .. term .. " ", 1, true) then return false end
    end
    return true
end

local function mergeBooks(target, additions, seen)
    for _, book in ipairs(additions or {}) do
        local key = tostring(book.provider_id or book.id)
        if not seen[key] then
            seen[key] = true
            target[#target + 1] = book
        end
    end
end

local function rankTextosBooks(books, query, terms)
    local phrase = normalizeSearchText(query)
    for position, book in ipairs(books) do
        local title = normalizeSearchText(book.title)
        book._textos_search_position = position
        if title == phrase then
            book._textos_search_rank = 0
        elseif phrase ~= "" and (title .. " "):find(phrase .. " ", 1, true) == 1 then
            book._textos_search_rank = 1
        elseif titleContainsTerms(book, terms) then
            book._textos_search_rank = 2
        else
            book._textos_search_rank = 3
        end
    end
    table.sort(books, function(left, right)
        if left._textos_search_rank ~= right._textos_search_rank then
            return left._textos_search_rank < right._textos_search_rank
        end
        return left._textos_search_position < right._textos_search_position
    end)
    for _, book in ipairs(books) do
        book._textos_search_rank = nil
        book._textos_search_position = nil
    end
end

local function textosAuthorBooks(query, source, filters)
    local search_url = "https://www.textos.info/buscar/" .. url.escape(query)
    local html = requestPayload(search_url, "text/html, application/xhtml+xml")
    if not html then return {} end
    local terms = significantSearchTerms(query)
    local books, seen_slugs, candidates = {}, {}, 0
    for slug, label in html:gmatch('<h3[^>]*>%s*<a%s+href="%.?/([^"/?#]+)"[^>]*>(.-)</a>') do
        label = decodeEntities(label:gsub("<.->", " "):gsub("%s+", " "))
        local normalized_label = normalizeSearchText(label)
        local matches = #terms > 0
        for _, term in ipairs(terms) do
            if not normalized_label:find(term, 1, true) then matches = false break end
        end
        if matches and not seen_slugs[slug] then
            seen_slugs[slug] = true
            candidates = candidates + 1
            local author_url = "https://www.textos.info/autor.atom&author=" .. url.escape(slug)
            local document = requestXml(author_url)
            if document then
                local author_books = feedInfo(document, author_url, "textos", source, filters)
                for _, book in ipairs(author_books) do books[#books + 1] = book end
            end
            if candidates == 3 then break end
        end
    end
    return books
end

local function gallicaSearchUrl(source, field, query)
    local cleaned = tostring(query or ""):gsub('["\\]', " "):gsub("%s+", " ")
        :gsub("^%s+", ""):gsub("%s+$", "")
    local expression = field .. ' all "' .. cleaned
        .. '" and dc.formatspecific all "epub"'
    return string.format(source.search, url.escape(expression))
end

local function pagedFeed(first_url, page, source_id, source, filters)
    local request_url, document, err = first_url
    local books, total, next_url
    for page_number = 1, page do
        document, err = requestXml(request_url)
        if not document then return nil, err end
        books, total, next_url = feedInfo(document, request_url, source_id, source, filters)
        if page_number < page then
            if not next_url then return {}, total, nil end
            request_url = next_url
        end
    end
    return books, total, next_url
end

local function searchGallica(source, query, page, filters)
    if filters and type(filters.formats) == "table" and not filters.formats.epub then
        return { books = {}, total = 0, page = page, has_previous = page > 1, has_next = false }
    end
    local merged, seen, totals, has_next, errors = {}, {}, {}, false, {}
    for _, field in ipairs({ "dc.title", "dc.creator" }) do
        local request_url = gallicaSearchUrl(source, field, query)
        local books, total, next_url = pagedFeed(request_url, page, "gallica", source, filters)
        if books then
            totals[#totals + 1] = tonumber(total) or #books
            mergeBooks(merged, books, seen)
            has_next = has_next or next_url ~= nil
        else
            errors[#errors + 1] = tostring(total)
        end
    end
    if #totals == 0 then return nil, table.concat(errors, "\n") end
    local total = #merged
    for _, candidate_total in ipairs(totals) do total = math.max(total, candidate_total) end
    return {
        books = merged,
        total = total,
        page = page,
        has_previous = page > 1,
        has_next = has_next,
    }
end

function OPDS:searchSource(source_id, query, page, filters)
    local source = self.sources[source_id]
    if not source then return nil, "Unknown OPDS source" end
    page = math.max(1, tonumber(page) or 1)
    if source_id == "gallica" and query and query:match("%S") then
        return searchGallica(source, query, page, filters)
    end
    local request_url = sourceUrl(source_id, source, query, page, filters)
    local document, err = requestXml(request_url)
    if not document then return nil, source.name .. ": " .. tostring(err) end

    local books, total, next_url = feedInfo(document, request_url, source_id, source, filters)
    if source_id == "textos" and page == 1 and query and query:match("%S") then
        local terms = significantSearchTerms(query)
        local word_count = 0
        for _ in normalizeSearchText(query):gmatch("%S+") do word_count = word_count + 1 end
        local has_title_match = false
        for _, book in ipairs(books) do
            if titleContainsTerms(book, terms) then
                has_title_match = true
                break
            end
        end
        if word_count > 1 and #terms > 0 and not has_title_match then
            local seen = {}
            for _, book in ipairs(books) do
                seen[tostring(book.provider_id or book.id)] = true
            end
            for _, term in ipairs(terms) do
                local fallback_url = string.format(source.search, url.escape(term))
                local fallback_document = requestXml(fallback_url)
                if fallback_document then
                    local fallback_books = feedInfo(
                        fallback_document, fallback_url, source_id, source, filters)
                    mergeBooks(books, fallback_books, seen)
                end
            end
            rankTextosBooks(books, query, terms)
            total = #books
        end
        local seen = {}
        for _, book in ipairs(books) do seen[tostring(book.provider_id or book.id)] = true end
        local author_books = textosAuthorBooks(query, source, filters)
        local before = #books
        mergeBooks(books, author_books, seen)
        if #books > before then
            rankTextosBooks(books, query, terms)
            total = #books
        end
    end
    if not source.direct_page and page > 1 then
        for page_number = 2, page do
            if not next_url then
                books = {}
                break
            end
            request_url = next_url
            document, err = requestXml(request_url)
            if not document then return nil, source.name .. ": " .. tostring(err) end
            books, total, next_url = feedInfo(document, request_url, source_id, source, filters)
        end
    end
    return {
        books = books,
        total = total,
        page = page,
        has_previous = page > 1,
        has_next = next_url ~= nil or (source.direct_page and #books >= self.page_size),
    }
end

function OPDS:hydrate(book)
    if not book then return nil, "Book is missing" end
    if book.acquisitions and #book.acquisitions > 0 then return book end
    if not book.detail_url then return nil, "This catalog did not provide a book detail feed" end
    local source = self.sources[book.provider]
    if not source then return nil, "Unknown OPDS source" end
    local document, err = requestXml(book.detail_url)
    if not document then return nil, err end
    local books = feedInfo(document, book.detail_url, book.provider, source, {})
    if #books == 0 then return nil, "No compatible public file was listed" end

    local selected = {}
    for _, edition in ipairs(books) do
        for _, acquisition in ipairs(edition.acquisitions or {}) do
            local existing = selected[acquisition.extension]
            if not existing or (acquisition.score or 0) > (existing.score or 0) then
                selected[acquisition.extension] = acquisition
            end
        end
        for key, value in pairs(edition) do
            if (book[key] == nil or book[key] == "") and value ~= nil and value ~= "" then
                book[key] = value
            end
        end
    end
    book.acquisitions = {}
    for _, extension in ipairs(FORMAT_ORDER) do
        if selected[extension] then book.acquisitions[#book.acquisitions + 1] = selected[extension] end
    end
    book.available_formats = availableFormats(book.acquisitions)
    if book.acquisitions[1] then
        book.format = book.acquisitions[1].format
        local size = tonumber(book.acquisitions[1].size)
        if size then book.size = string.format("%.1f MB", size / 1024 / 1024) end
    end
    return book
end

return OPDS
