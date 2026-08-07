local DataStorage = require("datastorage")
local ffiutil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local socketutil = require("socketutil")

local CoverCache = {
    directory = DataStorage:getSettingsDir() .. "/bookdrop_covers",
    max_entries = 80,
    max_bytes = 1536 * 1024,
    background_pid = nil,
}

local function ensure_directory()
    if not lfs.attributes(CoverCache.directory, "mode") then
        lfs.mkdir(CoverCache.directory)
    end
end

local function image_extension(data)
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
end

local function candidate_paths(id)
    return {
        CoverCache.directory .. "/" .. id .. ".jpg",
        CoverCache.directory .. "/" .. id .. ".png",
    }
end

function CoverCache:get(book)
    ensure_directory()
    for _, path in ipairs(candidate_paths(book.id)) do
        local attributes = lfs.attributes(path)
        if attributes and attributes.size and attributes.size > 0 then
            return path
        end
    end
end

function CoverCache:prune()
    ensure_directory()
    local files = {}
    for filename in lfs.dir(self.directory) do
        if filename ~= "." and filename ~= ".." then
            local path = self.directory .. "/" .. filename
            local attributes = lfs.attributes(path)
            if attributes and attributes.mode == "file" then
                files[#files + 1] = {
                    path = path,
                    modified = attributes.modification or 0,
                }
            end
        end
    end
    table.sort(files, function(a, b) return a.modified < b.modified end)
    for index = 1, math.max(0, #files - self.max_entries) do
        os.remove(files[index].path)
    end
end

function CoverCache:fetch(book)
    local cached = self:get(book)
    if cached then return cached end
    if not book.cover_url or not book.cover_url:match("^https://") then return nil end

    local candidates = { book.cover_url, book.cover_fallback_url }
    for _, cover_url in ipairs(candidates) do
        if cover_url and cover_url:match("^https://") then
            local chunks = {}
            local received = 0
            local oversized = false
            local sink = function(chunk)
                if chunk then
                    received = received + #chunk
                    if received > self.max_bytes then
                        oversized = true
                        return nil, "cover too large"
                    end
                    chunks[#chunks + 1] = chunk
                end
                return 1
            end

            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local _, code = http.request{
                url = cover_url,
                method = "GET",
                redirect = true,
                headers = {
                    ["Accept"] = "image/jpeg, image/png",
                    ["Accept-Encoding"] = "identity",
                    ["User-Agent"] = "KOReader Bookdrop/0.5",
                },
                sink = sink,
            }
            socketutil:reset_timeout()

            local data = table.concat(chunks)
            local extension = not oversized and tonumber(code) == 200 and image_extension(data)
            -- archive.org/services/img uses this 3,777-byte PNG for items
            -- without a cover. It is a source logo, not a book image.
            local generic_archive_tile = extension == "png" and #data == 3777
            if extension and not generic_archive_tile then
                ensure_directory()
                local path = self.directory .. "/" .. book.id .. "." .. extension
                local temporary_path = path .. ".part"
                local file = io.open(temporary_path, "wb")
                if file then
                    local ok = file:write(data)
                    file:close()
                    if ok and os.rename(temporary_path, path) then
                        self:prune()
                        return path
                    end
                    os.remove(temporary_path)
                end
            end
        end
    end
    return nil
end

function CoverCache:prefetch(books, limit)
    local fetched = 0
    limit = limit or 4
    for _, book in ipairs(books) do
        if book.cover_url and self:fetch(book) then
            fetched = fetched + 1
            if fetched >= limit then break end
        end
    end
    return fetched
end

function CoverCache:prefetchInBackground(books, limit)
    if self.background_pid and not ffiutil.isSubProcessDone(self.background_pid) then
        ffiutil.terminateSubProcess(self.background_pid)
        ffiutil.isSubProcessDone(self.background_pid, true)
    end
    self.background_pid = nil

    local queue = {}
    limit = limit or 12
    for _, book in ipairs(books) do
        if book.cover_url and not self:get(book) then
            queue[#queue + 1] = {
                id = book.id,
                cover_url = book.cover_url,
                cover_fallback_url = book.cover_fallback_url,
            }
            if #queue >= limit then break end
        end
    end
    if #queue == 0 then return false end

    self.background_pid = ffiutil.runInSubProcess(function()
        for _, book in ipairs(queue) do self:fetch(book) end
    end)
    return self.background_pid ~= nil
end

function CoverCache:isPrefetching()
    if not self.background_pid then return false end
    if ffiutil.isSubProcessDone(self.background_pid) then
        self.background_pid = nil
        return false
    end
    return true
end

function CoverCache:clear()
    ensure_directory()
    for filename in lfs.dir(self.directory) do
        if filename ~= "." and filename ~= ".." then
            os.remove(self.directory .. "/" .. filename)
        end
    end
end

return CoverCache
