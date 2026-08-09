local InternetArchive = require("bookdrop_provider")
local OPDS = require("bookdrop_opds_provider")
local ZlibraryProvider = require("bookdrop_zlibrary_provider")

local CatalogProvider = { page_size = 10 }

CatalogProvider.source_order = {
    "gutenberg", "standardebooks", "textos", "gallica", "internet_archive", "zlibrary",
}

CatalogProvider.sources = {
    gutenberg = "Project Gutenberg",
    standardebooks = "Standard Ebooks",
    textos = "textos.info",
    gallica = "Gallica",
    internet_archive = "Internet Archive",
    zlibrary = "Z-Library",
}

local SOURCE_PRIORITY = {
    standardebooks = 1,
    gutenberg = 2,
    textos = 3,
    gallica = 4,
    internet_archive = 5,
    zlibrary = 6,
}

local function normalize(value)
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

local function words(value)
    local result, seen = {}, {}
    for word in normalize(value):gmatch("%S+") do
        if #word > 1 and not seen[word] then
            seen[word] = true
            result[#result + 1] = word
        end
    end
    return result
end

local QUERY_STOP_WORDS = {
    a = true, al = true, de = true, del = true, el = true, en = true,
    la = true, las = true, los = true, un = true, una = true, y = true,
    the = true, of = true, ["and"] = true, le = true, les = true, des = true, et = true,
}

local function queryWords(value)
    local filtered = {}
    for _, word in ipairs(words(value)) do
        if not QUERY_STOP_WORDS[word] then filtered[#filtered + 1] = word end
    end
    return #filtered > 0 and filtered or words(value)
end

local function withinOneEdit(left, right)
    if left == right then return true end
    if #left < 5 or #right < 5 or math.abs(#left - #right) > 1 then return false end
    local left_index, right_index, edits = 1, 1, 0
    while left_index <= #left and right_index <= #right do
        if left:byte(left_index) == right:byte(right_index) then
            left_index, right_index = left_index + 1, right_index + 1
        else
            edits = edits + 1
            if edits > 1 then return false end
            if #left > #right then
                left_index = left_index + 1
            elseif #right > #left then
                right_index = right_index + 1
            else
                left_index, right_index = left_index + 1, right_index + 1
            end
        end
    end
    if left_index <= #left or right_index <= #right then edits = edits + 1 end
    return edits <= 1
end

local function fieldMatchesTerms(value, terms, fuzzy)
    local field_words = words(value)
    for _, term in ipairs(terms) do
        local matched = false
        for _, field_word in ipairs(field_words) do
            if field_word == term or (fuzzy and withinOneEdit(field_word, term)) then
                matched = true
                break
            end
        end
        if not matched then return false end
    end
    return #terms > 0
end

local function containsPhrase(haystack, phrase)
    return (" " .. normalize(haystack) .. " "):find(" " .. phrase .. " ", 1, true) ~= nil
end

local function matchesQuery(book, query)
    local phrase = normalize(query)
    if phrase == "" then return true end
    local title_author = tostring(book.title or "") .. " " .. tostring(book.author or "")
    local terms = queryWords(query)
    if containsPhrase(title_author, phrase) then return true end
    if fieldMatchesTerms(title_author, terms, true) then return true end
    local isbn = normalize(book.isbn):gsub(" ", "")
    local normalized_query = phrase:gsub(" ", "")
    if isbn ~= "" and isbn == normalized_query then return true end
    -- Subjects remain useful for genuine keyword searches, but only as exact
    -- whole-word matches; descriptions and full book text never qualify alone.
    return fieldMatchesTerms(book.subjects, terms, false)
end

local function containsAll(haystack, needles)
    haystack = " " .. normalize(haystack) .. " "
    for _, needle in ipairs(needles) do
        if not haystack:find(" " .. needle .. " ", 1, true) then return false end
    end
    return #needles > 0
end

local function relevance(book, query, filters)
    local phrase = normalize(query)
    local title, author = normalize(book.title), normalize(book.author)
    local combined = title .. " " .. author .. " " .. normalize(book.subjects)
    local tokens = queryWords(query)
    local score = 60 - 8 * (SOURCE_PRIORITY[book.provider] or 6)
    if filters and filters.libraries and filters.libraries.zlibrary
        and book.provider == "zlibrary" then
        score = score + 48
    end
    if phrase == "" then return score end
    if title == phrase then score = score + 1200
    elseif (title .. " "):find(phrase .. " ", 1, true) == 1 then score = score + 1000
    elseif containsPhrase(title, phrase) then score = score + 850
    elseif containsAll(title, tokens) then score = score + 700 end
    if author == phrase then score = score + 900
    elseif containsPhrase(author, phrase) then score = score + 650
    elseif containsAll(author, tokens) then score = score + 500 end
    if containsAll(combined, tokens) then score = score + 180 end
    return score
end

local function publicationYear(book)
    return tonumber(book.year) or tonumber(tostring(book.published_date or ""):match("(%d%d%d%d)"))
end

function CatalogProvider:sortBooks(books, query, sort, filters)
    for position, book in ipairs(books or {}) do
        book._catalog_position = position
        book._catalog_relevance = relevance(book, query, filters)
        book._catalog_title = normalize(book.title)
        book._catalog_year = publicationYear(book)
    end
    table.sort(books, function(left, right)
        local left_is_archive = left.provider == "internet_archive"
        local right_is_archive = right.provider == "internet_archive"
        if left_is_archive ~= right_is_archive then
            return not left_is_archive
        end
        if sort == "title" and left._catalog_title ~= right._catalog_title then
            return left._catalog_title < right._catalog_title
        elseif (sort == "newest" or sort == "oldest")
            and left._catalog_year ~= right._catalog_year then
            if not left._catalog_year then return false end
            if not right._catalog_year then return true end
            if sort == "newest" then return left._catalog_year > right._catalog_year end
            return left._catalog_year < right._catalog_year
        end
        if left._catalog_relevance ~= right._catalog_relevance then
            return left._catalog_relevance > right._catalog_relevance
        end
        if left._catalog_title ~= right._catalog_title then
            return left._catalog_title < right._catalog_title
        end
        return left._catalog_position < right._catalog_position
    end)
    for _, book in ipairs(books or {}) do
        book._catalog_position = nil
        book._catalog_relevance = nil
        book._catalog_title = nil
        book._catalog_year = nil
    end
    return books
end

local function enabled(filters, source_id)
    return not filters or type(filters.libraries) ~= "table" or filters.libraries[source_id] == true
end

function CatalogProvider:search(query, page, filters)
    filters = filters or {}
    page = math.max(1, tonumber(page) or 1)
    local books, errors, total, has_next = {}, {}, 0, false
    local successful_sources = 0

    for _, source_id in ipairs(self.source_order) do
        if enabled(filters, source_id) then
            local result, err
            if source_id == "internet_archive" then
                result, err = InternetArchive:search(query, page, filters)
                if result then
                    for _, book in ipairs(result.books) do book.provider = source_id end
                end
            elseif source_id == "zlibrary" then
                result, err = ZlibraryProvider:search(query, page, filters)
            else
                result, err = OPDS:searchSource(source_id, query, page, filters)
            end
            if result then
                successful_sources = successful_sources + 1
                total = total + (tonumber(result.total) or #result.books)
                has_next = has_next or result.has_next == true
                for _, book in ipairs(result.books) do books[#books + 1] = book end
            else
                errors[#errors + 1] = tostring(err or self.sources[source_id])
            end
        end
    end

    if successful_sources == 0 then
        return nil, #errors > 0 and table.concat(errors, "\n") or "No libraries are selected"
    end
    if query and query:match("%S") then
        local relevant = {}
        for _, book in ipairs(books) do
            if matchesQuery(book, query) then relevant[#relevant + 1] = book end
        end
        books = relevant
        total = #books
    end
    self:sortBooks(books, query, filters.sort, filters)
    return {
        books = books,
        total = math.max(total, #books),
        page = page,
        has_previous = page > 1,
        has_next = has_next,
        source_errors = errors,
    }
end

function CatalogProvider:hydrate(book)
    if book and (book.provider == "internet_archive" or not book.provider) then
        return InternetArchive:hydrate(book)
    elseif book and book.provider == "zlibrary" then
        return ZlibraryProvider:hydrate(book)
    end
    return OPDS:hydrate(book)
end

return CatalogProvider
