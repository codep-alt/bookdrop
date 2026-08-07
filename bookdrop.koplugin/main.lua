local CoverCache = require("bookdrop_covercache")
local CuratedHome = require("bookdrop_curated_home")
local BookView = require("bookdrop_bookview")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local LoadingView = require("bookdrop_loadingview")
local NetworkMgr = require("ui/network/manager")
local Provider = require("bookdrop_catalog_provider")
local StoreMenu = require("bookdrop_storemenu")
local StoreHome = require("bookdrop_home")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local Bookdrop = WidgetContainer:extend{ name = "bookdrop", settings = nil }
local CHECKED = "✓"
local UNCHECKED = "□"

local content_options = {
    { "", "All content" }, { "book_fiction", "Fiction" },
    { "book_nonfiction", "Non-fiction" },
    { "book_comic", "Comics" }, { "magazine", "Magazines" },
}
local format_options = {
    { "epub", "EPUB" }, { "pdf", "PDF" }, { "mobi", "MOBI" },
    { "djvu", "DJVU" }, { "cbz", "CBZ" }, { "txt", "TXT" },
}
local library_options = {
    { "gutenberg", "Project Gutenberg" },
    { "standardebooks", "Standard Ebooks" },
    { "textos", "textos.info" },
    { "gallica", "Gallica" },
    { "internet_archive", "Internet Archive" },
}
local language_options = {
    { "", "All languages" }, { "en", "English" }, { "es", "Spanish" },
    { "fr", "French" }, { "de", "German" }, { "ru", "Russian" },
    { "pt", "Portuguese" }, { "it", "Italian" }, { "zh", "Chinese" },
    { "ja", "Japanese" },
}
local sort_options = {
    { "", "Best match" }, { "title", "Title A–Z" },
    { "newest", "Newest publication" }, { "oldest", "Oldest publication" },
}
local valid_sorts = { title = true, newest = true, oldest = true }
local valid_contents = {
    book_fiction = true, book_nonfiction = true, book_comic = true, magazine = true,
}

function Bookdrop:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/bookdrop.lua")
    if not self.settings:readSetting("isolated_shelf_filters_v1", false) then
        local filters = self.settings:readSetting("filters", {})
        -- Older shelf callbacks modified the live settings table. Clear the
        -- leaked content constraint once; future explicit filter choices are
        -- stored normally, while shelf filters use copies.
        filters.content = nil
        self.settings:saveSetting("filters", filters)
        self.settings:saveSetting("isolated_shelf_filters_v1", true)
        self.settings:flush()
    end
    if not self.settings:readSetting("homepage_search_decoupled_v2", false) then
        local filters = self.settings:readSetting("filters", {})
        -- Category navigation used to share the persistent content field with
        -- normal searches. Remove that one stale value during this upgrade;
        -- category shelves now operate on independent copies.
        filters.content = nil
        self.settings:saveSetting("filters", filters)
        self.settings:saveSetting("homepage_search_decoupled_v2", true)
        self.settings:flush()
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Bookdrop:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookdrop_show", {
        category = "none", event = "ShowBookdrop", title = _("Bookdrop"), filemanager = true,
    })
end

function Bookdrop:addToMainMenu(menu_items)
    if not self.ui.document then
        menu_items.bookdrop = {
            text = _("Bookdrop store"),
            sorting_hint = "search",
            callback = function() self:showStoreHome() end,
        }
    end
end

function Bookdrop:onShowBookdrop() self:showStoreHome() end

function Bookdrop:getFilters()
    local filters = self.settings:readSetting("filters", {})
    local changed = false
    if type(filters.formats) ~= "table" then
        filters.formats = {}
        if filters.extension then
            for option_number, option in ipairs(format_options) do
                if option[1] == filters.extension then
                    filters.formats[option[1]] = true
                    break
                end
            end
        end
        if not next(filters.formats) then
            for option_number, option in ipairs(format_options) do
                filters.formats[option[1]] = true
            end
        end
        filters.extension = nil
        changed = true
    end
    if type(filters.libraries) ~= "table" then
        filters.libraries = {}
        for option_number, option in ipairs(library_options) do
            filters.libraries[option[1]] = true
        end
        changed = true
    end
    if filters.libraries.manybooks ~= nil then
        filters.libraries.manybooks = nil
        changed = true
    end
    if filters.sort and not valid_sorts[filters.sort] then
        filters.sort = nil
        changed = true
    end
    if filters.content and not valid_contents[filters.content] then
        filters.content = nil
        changed = true
    end
    if changed then
        self.settings:saveSetting("filters", filters)
        self.settings:flush()
    end
    return filters
end

function Bookdrop:setFilter(key, value)
    local filters = self:getFilters()
    filters[key] = value ~= "" and value or nil
    self.settings:saveSetting("filters", filters)
    self.settings:flush()
end

function Bookdrop:resetFilters()
    local formats = {}
    for option_number, option in ipairs(format_options) do
        formats[option[1]] = true
    end
    local libraries = {}
    for option_number, option in ipairs(library_options) do
        libraries[option[1]] = true
    end
    self.settings:saveSetting("filters", { formats = formats, libraries = libraries })
    self.settings:flush()
    self:refreshSettingsMenu()
end

local function selectedOptionLabel(options, value)
    for option_number, option in ipairs(options) do
        if option[1] == value then return _(option[2]) end
    end
end

function Bookdrop:filterSummary(filters)
    filters = filters or {}
    local labels = {}
    local content = selectedOptionLabel(content_options, filters.content)
    if content and filters.content then labels[#labels + 1] = content end
    local language = selectedOptionLabel(language_options, filters.language)
    if language and filters.language then labels[#labels + 1] = language end

    if type(filters.formats) == "table" then
        local selected, total = {}, #format_options
        for option_number, option in ipairs(format_options) do
            if filters.formats[option[1]] then selected[#selected + 1] = _(option[2]) end
        end
        if #selected < total then labels[#labels + 1] = table.concat(selected, "/") end
    end
    if type(filters.libraries) == "table" then
        local selected = {}
        for option_number, option in ipairs(library_options) do
            if filters.libraries[option[1]] then selected[#selected + 1] = _(option[2]) end
        end
        if #selected == 1 then
            labels[#labels + 1] = selected[1]
        elseif #selected < #library_options then
            labels[#labels + 1] = T(_("%1 libraries"), #selected)
        end
    end
    return table.concat(labels, " · ")
end

function Bookdrop:refreshSettingsMenu()
    local menu = self.bookdrop_settings_menu
    if not menu then return end
    menu:updateItems(menu.itemnumber or 1, true)
    UIManager:setDirty(menu, "ui")
end

function Bookdrop:allFormatsEnabled()
    local formats = self:getFilters().formats
    for option_number, option in ipairs(format_options) do
        if not formats[option[1]] then return false end
    end
    return true
end

function Bookdrop:selectAllFormats()
    local filters = self:getFilters()
    for option_number, option in ipairs(format_options) do
        filters.formats[option[1]] = true
    end
    self.settings:saveSetting("filters", filters)
    self.settings:flush()
    self:refreshSettingsMenu()
end

function Bookdrop:toggleFormat(format)
    local filters = self:getFilters()
    if filters.formats[format] then
        local enabled = 0
        for format_name, is_enabled in pairs(filters.formats) do
            if is_enabled then enabled = enabled + 1 end
        end
        if enabled <= 1 then
            UIManager:show(InfoMessage:new{ text = _("At least one format must remain selected.") })
            return
        end
        filters.formats[format] = nil
    else
        filters.formats[format] = true
    end
    self.settings:saveSetting("filters", filters)
    self.settings:flush()
    self:refreshSettingsMenu()
end

function Bookdrop:formatMenu()
    local items = {
        {
            text = _("Select all formats"),
            checked_func = function() return self:allFormatsEnabled() end,
            mandatory_func = function()
                return self:allFormatsEnabled() and CHECKED or UNCHECKED
            end,
            callback = function() self:selectAllFormats() end,
        },
    }
    for option_number, option in ipairs(format_options) do
        local value, label = option[1], option[2]
        items[#items + 1] = {
            text = _(label),
            checked_func = function() return self:getFilters().formats[value] == true end,
            mandatory_func = function()
                return self:getFilters().formats[value] and CHECKED or UNCHECKED
            end,
            callback = function() self:toggleFormat(value) end,
        }
    end
    return items
end

function Bookdrop:allLibrariesEnabled()
    local libraries = self:getFilters().libraries
    for option_number, option in ipairs(library_options) do
        if not libraries[option[1]] then return false end
    end
    return true
end

function Bookdrop:selectAllLibraries()
    local filters = self:getFilters()
    for option_number, option in ipairs(library_options) do
        filters.libraries[option[1]] = true
    end
    self.settings:saveSetting("filters", filters)
    self.settings:flush()
    self:refreshSettingsMenu()
end

function Bookdrop:toggleLibrary(library)
    local filters = self:getFilters()
    if filters.libraries[library] then
        local enabled = 0
        for library_name, is_enabled in pairs(filters.libraries) do
            if is_enabled then enabled = enabled + 1 end
        end
        if enabled <= 1 then
            UIManager:show(InfoMessage:new{ text = _("At least one library must remain selected.") })
            return
        end
        filters.libraries[library] = nil
    else
        filters.libraries[library] = true
    end
    self.settings:saveSetting("filters", filters)
    self.settings:flush()
    self:refreshSettingsMenu()
end

function Bookdrop:libraryMenu()
    local items = {
        {
            text = _("Select all libraries"),
            checked_func = function() return self:allLibrariesEnabled() end,
            mandatory_func = function()
                return self:allLibrariesEnabled() and CHECKED or UNCHECKED
            end,
            callback = function() self:selectAllLibraries() end,
        },
    }
    for option_number, option in ipairs(library_options) do
        local value, label = option[1], option[2]
        items[#items + 1] = {
            text = _(label),
            checked_func = function() return self:getFilters().libraries[value] == true end,
            mandatory_func = function()
                return self:getFilters().libraries[value] and CHECKED or UNCHECKED
            end,
            callback = function() self:toggleLibrary(value) end,
        }
    end
    return items
end

function Bookdrop:loadCoversProgressively(books, widget, limit)
    if not CoverCache:prefetchInBackground(books, limit or 12) then return end

    local function poll()
        local changed = false
        for _, book in ipairs(books) do
            local path = CoverCache:get(book)
            if path and book.cover_path ~= path then
                book.cover_path = path
                changed = true
            end
        end
        if changed and not widget._bookdrop_closed and widget.refreshCovers then
            widget:refreshCovers()
        end
        if CoverCache:isPrefetching() then
            UIManager:scheduleIn(0.25, poll)
        end
    end
    UIManager:scheduleIn(0.1, poll)
end

function Bookdrop:optionMenu(key, options, on_select)
    local items = {}
    for option_index, option in ipairs(options) do
        local value, label = option[1], option[2]
        items[#items + 1] = {
            text = _(label),
            checked_func = function() return (self:getFilters()[key] or "") == value end,
            mandatory_func = function()
                return (self:getFilters()[key] or "") == value and CHECKED or ""
            end,
            callback = function()
                self:setFilter(key, value)
                self:refreshSettingsMenu()
                if on_select then on_select(value, _(label)) end
            end,
        }
    end
    return items
end

function Bookdrop:openShelf(title, content, sort)
    local filters = {}
    for key, value in pairs(self:getFilters()) do filters[key] = value end
    filters.content = content
    filters.sort = sort
    self:runSearch("", 1, filters, title)
end

function Bookdrop:openFilteredShelf(title, overrides)
    local filters = {}
    for key, value in pairs(self:getFilters()) do filters[key] = value end
    for key, value in pairs(overrides or {}) do filters[key] = value end
    self:runSearch("", 1, filters, title)
end

function Bookdrop:homeCategoryDefinitions()
    return {
        {
            key = "fiction",
            title = _("Fiction & Literature"),
            callback = function()
                self:openShelf(_("Fiction"), "book_fiction", "")
            end,
        },
        {
            key = "nonfiction",
            title = _("Non-fiction"),
            callback = function()
                self:openShelf(_("Non-fiction"), "book_nonfiction", "")
            end,
        },
        {
            key = "comics",
            title = _("Comics & Graphic Novels"),
            callback = function()
                self:openShelf(_("Comics"), "book_comic", "")
            end,
        },
        {
            key = "magazines",
            title = _("Magazines"),
            callback = function()
                self:openShelf(_("Magazines"), "magazine", "")
            end,
        },
        {
            key = "spanish",
            title = _("Spanish Books"),
            callback = function()
                self:openFilteredShelf(_("Spanish Books"), {
                    language = "es", content = "",
                })
            end,
        },
        {
            key = "french",
            title = _("French Books"),
            callback = function()
                self:openFilteredShelf(_("French Books"), {
                    language = "fr", content = "",
                })
            end,
        },
    }
end

function Bookdrop:presentStoreHome(featured_books, shelf_books)
    shelf_books = shelf_books or {}
    local category_cards = {}
    for _, definition in ipairs(self:homeCategoryDefinitions()) do
        category_cards[#category_cards + 1] = {
            title = definition.title,
            books = shelf_books[definition.key] or {},
            callback = definition.callback,
        }
    end

    local home = StoreHome:new{
        featured_books = featured_books,
        category_cards = category_cards,
        has_recent = #(self.settings:readSetting("recent_books", {})) > 0,
        on_book = function(book) self:showBook(book) end,
        on_search = function(home) self:showSearchDialog(home) end,
        on_fiction = function() self:openShelf(_("Fiction"), "book_fiction", "") end,
        on_nonfiction = function() self:openShelf(_("Non-fiction"), "book_nonfiction", "") end,
        on_comics = function() self:openShelf(_("Comics"), "book_comic", "") end,
        on_magazines = function() self:openShelf(_("Magazines"), "magazine", "") end,
        on_new_arrivals = function() self:openShelf(_("New arrivals"), nil, "newest") end,
        on_all_books = function() self:openShelf(_("All books"), nil, "") end,
        on_recent = function() self:showRecentBooks() end,
        settings_builder = function(home) return self:settingsDropdownEntries(home) end,
    }
    UIManager:show(home)
    local all_home_books, seen = {}, {}
    local function appendBooks(books)
        for _, book in ipairs(books or {}) do
            if book.id and not seen[book.id] then
                all_home_books[#all_home_books + 1], seen[book.id] = book, true
            end
        end
    end
    appendBooks(featured_books)
    for _, card in ipairs(category_cards) do appendBooks(card.books) end
    self:loadCoversProgressively(all_home_books, home, #all_home_books)
end

local function safeFilename(value)
    value = tostring(value or "book"):gsub("[%z\1-\31/\\:*?\"<>|]", "-")
    value = value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or "book"
end

function Bookdrop:downloadBook(book, acquisition)
    if not acquisition or not acquisition.url then
        UIManager:show(InfoMessage:new{ text = _("No downloadable file is available.") })
        return
    end
    local download_dir = G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("home_dir")
        or G_reader_settings:readSetting("lastdir")
        or Device.home_dir
        or "."
    local extension = acquisition.extension or "epub"
    local destination = download_dir .. "/" .. safeFilename(book.title)
        .. " - " .. safeFilename(book.author) .. "." .. extension

    local existing = io.open(destination, "rb")
    if existing then
        existing:close()
        UIManager:show(InfoMessage:new{
            text = T(_("Already downloaded to:\n%1"), destination),
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Download %1 (%2) from %3?"), book.title,
            acquisition.format or extension:upper(), book.source or _("the catalog")),
        ok_text = _("DOWNLOAD"),
        ok_callback = function() self:startBookDownload(book, acquisition, destination) end,
    })
end

function Bookdrop:startBookDownload(book, acquisition, destination)
    local part_path = destination .. ".part"
    os.remove(part_path)
    local size_text = acquisition.size and string.format("%.1f MB", acquisition.size / 1024 / 1024)
        or _("unknown size")

    Trapper:wrap(function()
        Trapper:setPausedText(
            T(_("Downloading %1 is paused."), book.title),
            _("Cancel download"), _("Continue")
        )
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            local http = require("socket.http")
            local ltn12 = require("ltn12")
            local socketutil = require("socketutil")
            local ok, err = pcall(function()
                local output, open_err = io.open(part_path, "wb")
                if not output then error(open_err or "cannot create destination") end
                socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
                local _, download_code = http.request{
                    url = acquisition.url,
                    method = "GET",
                    redirect = true,
                    headers = {
                        ["Accept-Encoding"] = "identity",
                        ["User-Agent"] = "KOReader Bookdrop/0.5",
                    },
                    sink = ltn12.sink.file(output),
                }
                socketutil:reset_timeout()
                if tonumber(download_code) ~= 200 then
                    error("download server returned HTTP " .. tostring(download_code))
                end
                if acquisition.md5 and acquisition.md5 ~= "" then
                    local md5 = require("ffi/MD5")
                    if md5.sumFile(part_path) ~= acquisition.md5 then
                        error("file integrity check failed")
                    end
                end
                if not os.rename(part_path, destination) then
                    error("could not save the completed file")
                end
            end)
            if not ok then os.remove(part_path) end
            return ok and "ok" or ("error:" .. tostring(err))
        end, T(_("Downloading %1\n%2 · %3\n\nTap to pause or cancel."),
            book.title, acquisition.format or _("EBOOK"), size_text), true)

        if not completed then
            os.remove(part_path)
            UIManager:show(InfoMessage:new{ text = _("Download cancelled.") })
        elseif result == "ok" then
            if self.ui and self.ui.onRefresh then self.ui:onRefresh() end
            UIManager:show(InfoMessage:new{
                text = T(_("Downloaded successfully to:\n%1"), destination),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed: %1"),
                    tostring(result or "download ended unexpectedly"):gsub("^error:", "")),
            })
        end
    end)
end

function Bookdrop:showStoreHome()
    local filters = self:getFilters()
    local home_catalog = CuratedHome.build(self.path, filters.formats)
    self:presentStoreHome(home_catalog.featured, home_catalog.shelves)
end

local function selectedCount(values, options)
    local count = 0
    for _, option in ipairs(options) do
        if values and values[option[1]] then count = count + 1 end
    end
    return count
end

function Bookdrop:choiceDropdownEntries(home, title, key, options)
    local entries = {
        { text = "‹  " .. title, bold = true,
            callback = function() home:showSettings(self:settingsDropdownEntries(home)) end },
    }
    local selected_value = self:getFilters()[key] or ""
    for option_number, option in ipairs(options) do
        local value, label = option[1], _(option[2])
        entries[#entries + 1] = {
            text = (selected_value == value and CHECKED or UNCHECKED) .. "  " .. label,
            callback = function()
                self:setFilter(key, value)
                home:showSettings(self:choiceDropdownEntries(home, title, key, options))
            end,
        }
    end
    return entries
end

function Bookdrop:formatDropdownEntries(home)
    local entries = {
        { text = "‹  " .. _("Format"), bold = true,
            callback = function() home:showSettings(self:settingsDropdownEntries(home)) end },
        { text = (self:allFormatsEnabled() and CHECKED or UNCHECKED)
                .. "  " .. _("Select all formats"),
            callback = function()
                self:selectAllFormats()
                home:showSettings(self:formatDropdownEntries(home))
            end },
    }
    local formats = self:getFilters().formats
    for option_number, option in ipairs(format_options) do
        local value, label = option[1], _(option[2])
        entries[#entries + 1] = {
            text = (formats[value] and CHECKED or UNCHECKED) .. "  " .. label,
            callback = function()
                self:toggleFormat(value)
                home:showSettings(self:formatDropdownEntries(home))
            end,
        }
    end
    return entries
end

function Bookdrop:libraryDropdownEntries(home)
    local entries = {
        { text = "‹  " .. _("Libraries"), bold = true,
            callback = function() home:showSettings(self:settingsDropdownEntries(home)) end },
        { text = (self:allLibrariesEnabled() and CHECKED or UNCHECKED)
                .. "  " .. _("Select all libraries"),
            callback = function()
                self:selectAllLibraries()
                home:showSettings(self:libraryDropdownEntries(home))
            end },
    }
    local libraries = self:getFilters().libraries
    for option_number, option in ipairs(library_options) do
        local value, label = option[1], _(option[2])
        entries[#entries + 1] = {
            text = (libraries[value] and CHECKED or UNCHECKED) .. "  " .. label,
            callback = function()
                self:toggleLibrary(value)
                home:showSettings(self:libraryDropdownEntries(home))
            end,
        }
    end
    return entries
end

function Bookdrop:settingsDropdownEntries(home)
    local filters = self:getFilters()
    local format_count = selectedCount(filters.formats, format_options)
    local library_count = selectedCount(filters.libraries, library_options)
    local content = selectedOptionLabel(content_options, filters.content or "") or _("All content")
    local language = selectedOptionLabel(language_options, filters.language or "") or _("All languages")
    local sort = selectedOptionLabel(sort_options, filters.sort or "") or _("Best match")
    local format_summary = format_count == #format_options and _("All")
        or T(_("%1 selected"), format_count)
    local library_summary = library_count == #library_options and _("All")
        or T(_("%1 selected"), library_count)
    return {
        { text = _("Settings"), bold = true },
        { text = _("Reset all filters"), callback = function()
            self:resetFilters()
            home:showSettings(self:settingsDropdownEntries(home))
        end },
        { text = _("Content") .. "  ·  " .. content .. "  ›", callback = function()
            home:showSettings(self:choiceDropdownEntries(
                home, _("Content (best effort)"), "content", content_options))
        end },
        { text = _("Format") .. "  ·  " .. format_summary .. "  ›", callback = function()
            home:showSettings(self:formatDropdownEntries(home))
        end },
        { text = _("Libraries") .. "  ·  " .. library_summary .. "  ›", callback = function()
            home:showSettings(self:libraryDropdownEntries(home))
        end },
        { text = _("Language") .. "  ·  " .. language .. "  ›", callback = function()
            home:showSettings(self:choiceDropdownEntries(
                home, _("Language"), "language", language_options))
        end },
        { text = _("Sort order") .. "  ·  " .. sort .. "  ›", callback = function()
            home:showSettings(self:choiceDropdownEntries(
                home, _("Sort order"), "sort", sort_options))
        end },
        { text = _("Clear cover cache"), callback = function()
            CoverCache:clear()
            UIManager:show(InfoMessage:new{ text = _("Cached covers cleared.") })
        end },
    }
end

function Bookdrop:showSearchDialog(parent_widget, initial_query)
    local dialog
    local active_filters = self:filterSummary(self:getFilters())
    local dialog_title = _("Find your next book")
    if active_filters ~= "" then
        dialog_title = T(_("Search · %1"), active_filters)
    end
    dialog = InputDialog:new{
        title = dialog_title,
        input = initial_query or "",
        input_hint = _("Title, author, ISBN, or keyword"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                if not parent_widget then self:showStoreHome() end
            end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = dialog:getInputText()
                if query and query:match("%S") then
                    UIManager:close(dialog)
                    if parent_widget then UIManager:close(parent_widget) end
                    self:runSearch(query, 1, self:getFilters(), query)
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function appendUniqueBooks(target, additions, seen)
    for _, book in ipairs(additions or {}) do
        local key = tostring(book.provider or "") .. ":" .. tostring(book.provider_id or book.id)
        if not seen[key] then
            seen[key] = true
            target[#target + 1] = book
        end
    end
end

function Bookdrop:runSearch(query, page_number, filters, title, continuation)
    local loading = LoadingView:new{
        text = T(_("Searching %1…"), title),
    }
    UIManager:show(loading, "full")
    UIManager:forceRePaint()
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local page, err = Provider:search(
                query, page_number, filters
            )
            if not page then
                UIManager:close(loading, "full")
                UIManager:show(InfoMessage:new{ text = T(_("Catalog error: %1"), err) })
                return
            end
            for _, book in ipairs(page.books) do
                book.cover_path = CoverCache:get(book)
            end
            if continuation and continuation.books then
                local merged, seen = {}, {}
                appendUniqueBooks(merged, continuation.books, seen)
                appendUniqueBooks(merged, page.books, seen)
                page.books = merged
                page.total = math.max(tonumber(page.total) or 0, #merged)
                page.has_previous = false
                -- Each catalog page is already ordered by the selected sort.
                -- Re-sorting the combined list moved newly fetched records in
                -- front of records the reader had already seen, which made
                -- LOAD MORE appear to grow upward. Keep pagination append-only.
            end
            UIManager:close(loading)
            self:showResults(query, filters, title, page,
                continuation and continuation.visible_count,
                continuation and continuation.scroll_offset)
        end)
    end)
end

function Bookdrop:showResults(query, filters, title, page, visible_count, scroll_offset)
    local batch_size = 10
    visible_count = math.max(0, math.min(visible_count or batch_size, #page.books))
    local visible_books = {}
    for index = 1, visible_count do visible_books[#visible_books + 1] = page.books[index] end

    for index, book in ipairs(visible_books) do
        book.result_number = index
    end

    local function loadMore(next_scroll_offset)
        if visible_count < #page.books then
            self:showResults(query, filters, title, page,
                math.min(visible_count + batch_size, #page.books), next_scroll_offset)
        elseif page.has_next then
            self:runSearch(query, page.page + 1, filters, title, {
                books = page.books,
                visible_count = visible_count + batch_size,
                scroll_offset = next_scroll_offset,
            })
        end
    end

    local active_filters = self:filterSummary(filters)
    local total = page.total or #page.books
    local shown_first = #visible_books > 0 and 1 or 0
    local shown_last = #visible_books
    local results_title = query and query:match("%S")
        and T(_("Results for \"%1\""), query) or title
    local results_subtitle = T(_("%1–%2 of %3 titles"), shown_first, shown_last, total)
    if active_filters ~= "" then
        results_subtitle = T(_("%1 · %2"), results_subtitle, active_filters)
    end
    if page.source_errors and #page.source_errors > 0 then
        results_subtitle = T(_("%1 · %2 libraries unavailable"),
            results_subtitle, #page.source_errors)
    end
    local view_mode = self.settings:readSetting("results_view", "list")
    local sort_value = filters.sort or ""
    local results = StoreMenu:new{
        title = results_title,
        subtitle = results_subtitle,
        query = query,
        books = visible_books,
        view_mode = view_mode,
        sort_value = sort_value,
        sort_label = selectedOptionLabel(sort_options, sort_value) or _("Best match"),
        sort_options = sort_options,
        has_more = visible_count < #page.books or page.has_next,
        scroll_offset = scroll_offset,
        on_close = function() self:showStoreHome() end,
        on_search = function(widget) self:showSearchDialog(widget, query) end,
        on_book = function(book) self:showBook(book) end,
        on_load_more = loadMore,
        on_view = function(mode)
            self.settings:saveSetting("results_view", mode)
            self.settings:flush()
            self:showResults(query, filters, title, page, visible_count)
        end,
        on_sort = function(value)
            self:setFilter("sort", value)
            self:runSearch(query, 1, self:getFilters(), title)
        end,
    }
    UIManager:show(results, "full")
    self:loadCoversProgressively(visible_books, results, visible_count)
end

function Bookdrop:rememberBook(book)
    local recent, stored = self.settings:readSetting("recent_books", {}), {}
    for key, value in pairs(book) do
        if type(value) == "string" then stored[key] = value end
    end
    if type(book.acquisitions) == "table" then
        stored.acquisitions = {}
        for _, acquisition in ipairs(book.acquisitions) do
            local acquisition_copy = {}
            for key, value in pairs(acquisition) do
                if type(value) == "string" or type(value) == "number" then
                    acquisition_copy[key] = value
                end
            end
            stored.acquisitions[#stored.acquisitions + 1] = acquisition_copy
        end
    end
    local updated = { stored }
    for _, previous in ipairs(recent) do
        if previous.id ~= book.id and #updated < 12 then updated[#updated + 1] = previous end
    end
    self.settings:saveSetting("recent_books", updated)
    self.settings:flush()
end

function Bookdrop:showRecentBooks()
    local books = self.settings:readSetting("recent_books", {})
    for _, book in ipairs(books) do book.cover_path = CoverCache:get(book) end
    self:showResults("", {}, _("Recently viewed"), {
        books = books, page = 1, last_page = 1, has_previous = false, has_next = false,
    })
end

function Bookdrop:showBook(book)
    self:rememberBook(book)
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            Trapper:info(_("Loading book details…"))
            local hydrated, err = Provider:hydrate(book)
            Trapper:clear()
            if not hydrated then
                UIManager:show(InfoMessage:new{ text = T(_("Could not load book: %1"), err) })
                return
            end
            hydrated.cover_path = CoverCache:get(hydrated) or CoverCache:fetch(hydrated)
                or book.cover_path
            UIManager:show(BookView:new{
                book = hydrated,
                download_callback = hydrated.acquisitions and hydrated.acquisitions[1] and function(acquisition)
                    self:downloadBook(hydrated, acquisition)
                end or nil,
            })
        end)
    end)
end

return Bookdrop
