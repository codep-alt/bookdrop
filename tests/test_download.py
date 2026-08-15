"""Regression tests for Bookdrop's streamed book-download path."""

from pathlib import Path
from tempfile import TemporaryDirectory

from lupa import LuaRuntime


lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(
    r'''
    local passthrough = { new = function(self, value) return value or {} end }
    local widget = {}
    function widget:extend(value)
        value.extend = self.extend
        value.new = function(self, args) return args or {} end
        return value
    end

    package.preload["ui/widget/container/widgetcontainer"] = function() return widget end
    package.preload["gettext"] = function() return function(value) return value end end
    package.preload["ffi/util"] = function()
        return { template = function(text, ...)
            local values = {...}
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end }
    end
    package.preload["device"] = function() return {} end
    package.preload["ui/widget/infomessage"] = function() return passthrough end
    package.preload["ui/widget/confirmbox"] = function() return passthrough end
    package.preload["ui/widget/inputdialog"] = function() return passthrough end
    package.preload["ui/uimanager"] = function()
        return {
            shown = {},
            show = function(self, message) self.shown[#self.shown + 1] = message end,
        }
    end
    package.preload["ui/language"] = function()
        return { getLanguageName = function(_, locale) return locale end }
    end
    package.preload["datastorage"] = function()
        return { getSettingsDir = function() return "" end }
    end
    package.preload["luasettings"] = function()
        return { open = function() return {} end }
    end
    package.preload["dispatcher"] = function() return {} end
    package.preload["ui/network/manager"] = function() return {} end
    package.preload["ui/trapper"] = function()
        return {
            wrap = function(_, fn) return fn() end,
            setPausedText = function() end,
            dismissableRunInSubprocess = function(_, fn) return true, fn() end,
        }
    end
    for _, name in ipairs({
        "bookdrop_covercache", "bookdrop_curated_home", "bookdrop_bookview",
        "bookdrop_loadingview", "bookdrop_catalog_provider",
        "bookdrop_zlibrary_provider", "bookdrop_storemenu", "bookdrop_home"
    }) do package.preload[name] = function() return {} end end

    request_mode = "success"
    package.preload["socketutil"] = function()
        return {
            FILE_BLOCK_TIMEOUT = 15,
            FILE_TOTAL_TIMEOUT = 60,
            LARGE_BLOCK_TIMEOUT = 10,
            LARGE_TOTAL_TIMEOUT = 30,
            set_timeout = function(self, block, total)
                selected_block_timeout, selected_total_timeout = block, total
            end,
            reset_timeout = function() end,
            file_sink = function(handle)
                macos_bounded_sink_used = true
                return require("ltn12").sink.file(handle)
            end,
        }
    end
    package.preload["ltn12"] = function()
        return { sink = { file = function(handle)
            return function(chunk)
                if chunk then return handle:write(chunk) end
                handle:close()
                return 1
            end
        end } }
    end
    package.preload["socket.http"] = function()
        return { request = function(request)
            if request_mode == "timeout" then return nil, "sink timeout" end
            request.sink("BOOKDROP-DOWNLOAD")
            request.sink(nil)
            return 1, 200, { ["content-type"] = "application/epub+zip" }, "OK"
        end }
    end
    G_reader_settings = { readSetting = function() return nil end }
    jit = { os = "Linux" }
    '''
)
lua.execute(
    f'package.path = {str(Path.cwd() / "bookdrop.koplugin" / "?.lua")!r}'
    ' .. ";" .. package.path'
)
bookdrop = lua.eval('require("main")')[0]


with TemporaryDirectory(prefix="bookdrop-download-test-") as temp_dir:
    root = Path(temp_dir)
    destination = root / "book.epub"
    book = lua.table_from({"title": "Slow archive book", "provider": "internet_archive"})
    acquisition = lua.table_from({
        "url": "https://archive.org/download/example/book.epub",
        "extension": "epub",
        "format": "EPUB",
        "size": 112_145_832,
    })

    bookdrop.downloadBook(bookdrop, book, acquisition)
    messages = lua.eval('require("ui/uimanager").shown')
    assert "large file (107.0 MB)" in messages[len(messages)]["text"]

    bookdrop.startBookDownload(bookdrop, book, acquisition, str(destination))
    assert destination.read_bytes() == b"BOOKDROP-DOWNLOAD"
    assert lua.globals().selected_block_timeout == 15
    assert lua.globals().selected_total_timeout == 60
    assert not Path(str(destination) + ".part").exists()

    lua.globals().jit["os"] = "OSX"
    mac_destination = root / "mac.epub"
    bookdrop.startBookDownload(bookdrop, book, acquisition, str(mac_destination))
    assert mac_destination.read_bytes() == b"BOOKDROP-DOWNLOAD"
    assert lua.globals().macos_bounded_sink_used is True
    assert lua.globals().selected_block_timeout == 15
    assert lua.globals().selected_total_timeout == 15 * 60

    lua.globals().jit["os"] = "Linux"
    lua.globals().request_mode = "timeout"
    failed_destination = root / "failed.epub"
    bookdrop.startBookDownload(bookdrop, book, acquisition, str(failed_destination))
    assert not failed_destination.exists()
    assert not Path(str(failed_destination) + ".part").exists()
    messages = lua.eval('require("ui/uimanager").shown')
    error_text = messages[len(messages)]["text"]
    assert "server was too slow" in error_text
    assert "stack traceback" not in error_text
    assert "main.lua:" not in error_text

print("book downloads use KOReader file-transfer timeouts and streaming sink")
print("large downloads warn first; macOS transfers retain a 15-minute safety ceiling")
print("failed downloads remove partial files and show concise errors")
