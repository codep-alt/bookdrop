local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen

local BookCell = InputContainer:extend{
    book = nil,
    callback = nil,
    widget = nil,
    width = nil,
    height = nil,
}

function BookCell:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = self.widget
    self.ges_events = {
        TapBook = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function BookCell:onTapBook()
    if self.callback then self.callback(self.book) end
    return true
end

local SortPopup = InputContainer:extend{
    entries = nil,
    top = nil,
}

function SortPopup:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local border = Size.border.thin
    local panel_w = math.floor(screen_w * 0.48)
    local panel_x = math.floor(screen_w * 0.49)
    local available_h = screen_h - self.top - Screen:scaleBySize(22)
    local row_h = math.min(Screen:scaleBySize(48),
        math.floor((available_h - 2 * border) / #self.entries))
    local panel_h = #self.entries * row_h + 2 * border
    local inner_w = panel_w - 2 * border
    local rows = VerticalGroup:new{ align = "left" }

    for _, entry in ipairs(self.entries) do
        local value, callback = entry.value, entry.callback
        rows[#rows + 1] = Button:new{
            text = (entry.selected and "✓  " or "    ") .. entry.text,
            width = inner_w,
            height = row_h,
            align = "left",
            padding_h = Screen:scaleBySize(18),
            bordersize = 0,
            radius = 0,
            text_font_size = 15,
            text_font_bold = entry.selected == true,
            callback = function()
                UIManager:close(self)
                callback(value)
            end,
            show_parent = self,
        }
    end

    self.panel_dimen = Geom:new{
        x = panel_x, y = self.top, w = panel_w, h = panel_h,
    }
    local panel = FrameContainer:new{
        padding = 0, margin = 0, bordersize = border, radius = 0,
        background = Blitbuffer.COLOR_WHITE,
        rows,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    self[1] = OverlapGroup:new{
        dimen = self.dimen:copy(),
        WidgetContainer:new{ dimen = self.dimen:copy() },
        WidgetContainer:new{ dimen = self.panel_dimen:copy(), panel },
    }
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen:copy() } },
    }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
end

function SortPopup:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.panel_dimen) then UIManager:close(self) end
    return true
end

function SortPopup:onShow()
    UIManager:setDirty(self, function() return "ui", self.panel_dimen end)
    return true
end

function SortPopup:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.panel_dimen end)
end

function SortPopup:onClose()
    UIManager:close(self)
    return true
end

local StoreMenu = InputContainer:extend{
    name = "bookdrop_results",
    covers_fullscreen = true,
    books = nil,
    title = nil,
    subtitle = nil,
    view_mode = "list",
    sort_value = "",
    sort_label = nil,
    sort_options = nil,
    query = nil,
    on_book = nil,
    on_close = nil,
    on_search = nil,
    on_view = nil,
    on_sort = nil,
    on_load_more = nil,
    has_more = false,
    scroll_offset = nil,
}

local function nonempty(value)
    return value and value ~= "" and value
end

local function bookDetails(book)
    local details = {}
    for _, value in ipairs({ book.available_formats or book.format,
            book.language, book.year, book.size }) do
        if nonempty(value) then details[#details + 1] = value end
    end
    return table.concat(details, "  ·  ")
end

function StoreMenu:rule(width)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = Size.line.thin },
        background = Blitbuffer.COLOR_GRAY,
    }
end

function StoreMenu:createCover(book, width, height, placeholder_size)
    if book.cover_path then
        return ImageWidget:new{
            file = book.cover_path,
            width = width,
            height = height,
            scale_factor = 0,
            alpha = true,
        }
    end
    return FrameContainer:new{
        padding = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = width - 2 * Size.border.thin,
                h = height - 2 * Size.border.thin },
            TextBoxWidget:new{
                text = (book.title or _("Untitled")) .. "\n\n"
                    .. (book.author or _("Unknown author")),
                width = width - 2 * Size.padding.large,
                alignment = "center",
                face = Font:getFace("cfont", placeholder_size or 10),
                bold = true,
            },
        },
    }
end

function StoreMenu:createListRow(book, width)
    local row_h = Screen:scaleBySize(78)
    local gap = Size.padding.default
    local rank_w = Screen:scaleBySize(25)
    local cover_h = row_h - Screen:scaleBySize(9)
    local cover_w = math.floor(cover_h * 0.68)
    local text_w = width - rank_w - cover_w - 3 * gap
    local row = HorizontalGroup:new{
        CenterContainer:new{
            dimen = Geom:new{ w = rank_w, h = cover_h },
            TextWidget:new{
                text = tostring(book.result_number or ""),
                face = Font:getFace("cfont", 10),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        },
        HorizontalSpan:new{ width = gap },
        self:createCover(book, cover_w, cover_h, 8),
        HorizontalSpan:new{ width = gap },
        VerticalGroup:new{
            TextBoxWidget:new{
                text = book.title or _("Untitled"), width = text_w,
                height = Screen:scaleBySize(30),
                face = Font:getFace("cfont", 14), bold = true,
                height_overflow_show_ellipsis = true,
            },
            TextBoxWidget:new{
                text = book.author or _("Unknown author"), width = text_w,
                height = Screen:scaleBySize(18),
                face = Font:getFace("cfont", 12),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                height_overflow_show_ellipsis = true,
            },
            TextBoxWidget:new{
                text = bookDetails(book), width = text_w,
                height = Screen:scaleBySize(15),
                face = Font:getFace("cfont", 10),
                fgcolor = Blitbuffer.COLOR_GRAY,
                height_overflow_show_ellipsis = true,
            },
            TextBoxWidget:new{
                text = (book.source or _("Catalog")):upper(), width = text_w,
                height = Screen:scaleBySize(13),
                face = Font:getFace("cfont", 8), bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                height_overflow_show_ellipsis = true,
            },
        },
    }
    return BookCell:new{
        book = book, callback = self.on_book, width = width, height = row_h,
        widget = VerticalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = row_h - Size.line.thin }, row,
            },
            self:rule(width),
        },
    }
end

function StoreMenu:createGridCell(book, width)
    local cover_h = math.floor(width * 1.46)
    local label_h = Screen:scaleBySize(26)
    local cell_h = cover_h + label_h
    local metadata = table.concat({
        (book.source or _("Catalog")):upper(),
        book.available_formats or book.format or "",
    }, "  ·  ")
    return BookCell:new{
        book = book, callback = self.on_book, width = width, height = cell_h,
        widget = VerticalGroup:new{
            self:createCover(book, width, cover_h, 12),
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = label_h },
                TextBoxWidget:new{
                    text = metadata, width = width,
                    height = label_h, alignment = "center",
                    face = Font:getFace("cfont", 8), bold = true,
                    height_overflow_show_ellipsis = true,
                },
            },
        },
    }
end

function StoreMenu:createList(width)
    local list = VerticalGroup:new{ align = "left" }
    for _, book in ipairs(self.books) do list[#list + 1] = self:createListRow(book, width) end
    return list
end

function StoreMenu:createGrid(width)
    local gap = Screen:scaleBySize(18)
    local cell_w = math.floor((width - 2 * gap) / 3)
    local grid = VerticalGroup:new{ align = "left" }
    for first = 1, #self.books, 3 do
        local row = HorizontalGroup:new{ align = "top" }
        for column = 0, 2 do
            if column > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
            local book = self.books[first + column]
            if book then
                row[#row + 1] = self:createGridCell(book, cell_w)
            else
                row[#row + 1] = HorizontalSpan:new{ width = cell_w }
            end
        end
        grid[#grid + 1] = row
        grid[#grid + 1] = VerticalSpan:new{ width = gap }
    end
    return grid
end

function StoreMenu:leave(callback, value)
    UIManager:close(self)
    if callback then callback(value) end
end

function StoreMenu:showSortPopup()
    local entries = {}
    for option_number, option in ipairs(self.sort_options or {}) do
        local value, label = option[1], option[2]
        entries[#entries + 1] = {
            value = value,
            text = _(label),
            selected = (self.sort_value or "") == value,
            callback = function(selected) self:leave(self.on_sort, selected) end,
        }
    end
    UIManager:show(SortPopup:new{
        entries = entries,
        top = self.title_bar:getSize().h + Screen:scaleBySize(47),
    })
end

function StoreMenu:build()
    local outer = Screen:scaleBySize(22)
    local content_w = self.dimen.w - 2 * outer
    self.title_bar = TitleBar:new{
        fullscreen = true, width = self.dimen.w, align = "left",
        title = _("Bookdrop"), title_face = Font:getFace("cfont", 20),
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local summary_h = Screen:scaleBySize(48)
    local controls_h = Screen:scaleBySize(40)
    local sort_w = math.floor(content_w * 0.30)
    local summary_w = content_w - sort_w
    local half_controls = math.floor(content_w * 0.20)
    local content = self.view_mode == "covers"
        and self:createGrid(content_w) or self:createList(content_w)

    local navigation = VerticalGroup:new{ align = "left" }
    if self.has_more then
        navigation[#navigation + 1] = VerticalSpan:new{ width = Size.padding.default }
        navigation[#navigation + 1] = Button:new{
            text = _("LOAD MORE"), width = content_w,
            height = Screen:scaleBySize(46),
            bordersize = Size.border.thin, radius = 0, text_font_size = 13,
            callback = function()
                self:leave(self.on_load_more, self.cropping_widget:getScrolledOffset())
            end,
            show_parent = self,
        }
    end
    content[#content + 1] = navigation
    content[#content + 1] = VerticalSpan:new{ width = outer }

    local header = VerticalGroup:new{ align = "left" }
    if self.query and self.query:match("%S") then
        header[#header + 1] = VerticalSpan:new{ width = Size.padding.default }
        header[#header + 1] = Button:new{
            text = _("Search") .. "  ·  " .. self.query,
            width = content_w, height = Screen:scaleBySize(42),
            align = "left", padding_h = Screen:scaleBySize(16),
            bordersize = Size.border.thin, radius = Screen:scaleBySize(18),
            text_font_size = 13, text_font_bold = false,
            callback = function()
                if self.on_search then self.on_search(self) end
            end,
            show_parent = self,
        }
        header[#header + 1] = VerticalSpan:new{ width = Size.padding.default }
    end
    header[#header + 1] = HorizontalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{ w = summary_w, h = summary_h },
                TextBoxWidget:new{
                    text = self.title, width = summary_w,
                    face = Font:getFace("cfont", 16), bold = true,
                    height_overflow_show_ellipsis = true,
                },
            },
            Button:new{
                text = _("SORT  ▾"), width = sort_w, height = summary_h,
                bordersize = 0, radius = 0, text_font_size = 14,
                callback = function() self:showSortPopup() end,
                show_parent = self,
            },
        }
    header[#header + 1] = self:rule(content_w)
    header[#header + 1] = HorizontalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{ w = content_w - 2 * half_controls, h = controls_h },
                TextBoxWidget:new{
                    text = self.subtitle .. "  ·  " .. (self.sort_label or _("Best match")),
                    width = content_w - 2 * half_controls,
                    face = Font:getFace("cfont", 11),
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                    height_overflow_show_ellipsis = true,
                },
            },
            Button:new{
                text = _("LIST"), width = half_controls, height = controls_h,
                preselect = self.view_mode ~= "covers",
                bordersize = Size.border.thin, radius = 0, text_font_size = 11,
                callback = function()
                    if self.view_mode ~= "list" then self:leave(self.on_view, "list") end
                end,
                show_parent = self,
            },
            Button:new{
                text = _("COVERS"), width = half_controls, height = controls_h,
                preselect = self.view_mode == "covers",
                bordersize = Size.border.thin, radius = 0, text_font_size = 11,
                callback = function()
                    if self.view_mode ~= "covers" then self:leave(self.on_view, "covers") end
                end,
                show_parent = self,
            },
        }
    header[#header + 1] = self:rule(content_w)

    local body_h = self.dimen.h - self.title_bar:getSize().h - header:getSize().h
    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = body_h },
        show_parent = self,
        HorizontalGroup:new{
            HorizontalSpan:new{ width = outer }, content, HorizontalSpan:new{ width = outer },
        },
    }
    if self.scroll_offset then
        self.cropping_widget:setScrolledOffset(self.scroll_offset)
    end
    local padded_header = HorizontalGroup:new{
        HorizontalSpan:new{ width = outer }, header, HorizontalSpan:new{ width = outer },
    }
    self[1] = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ self.title_bar, padded_header, self.cropping_widget },
    }
end

function StoreMenu:init()
    self.books = self.books or {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self:build()
end

function StoreMenu:refreshCovers()
    local scroll_offset = self.cropping_widget and self.cropping_widget:getScrolledOffset()
    self[1]:free(true)
    self.scroll_offset = scroll_offset
    self:build()
    UIManager:setDirty(self, "full")
end

function StoreMenu:onClose()
    self:leave(self.on_close)
    return true
end

function StoreMenu:onCloseWidget()
    self._bookdrop_closed = true
end

return StoreMenu
