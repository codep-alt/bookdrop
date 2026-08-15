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
local QRWidget = require("ui/widget/qrwidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen

local CategoryPopup = InputContainer:extend{
    modal = true,
    entries = nil,
    top = nil,
    align_right = false,
}

function CategoryPopup:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local border = Size.border.thin
    local panel_w = math.floor(screen_w * (self.align_right and 0.64 or 0.52))
    local inner_w = panel_w - 2 * border
    local panel_x = self.align_right and (screen_w - panel_w - Screen:scaleBySize(18))
        or math.floor(screen_w * 0.23)
    local panel_y = self.top
    local bottom_margin = Screen:scaleBySize(24)
    local available_h = screen_h - panel_y - bottom_margin
    local row_h = math.min(
        Screen:scaleBySize(48),
        math.floor((available_h - 2 * border) / #self.entries)
    )
    local rows = VerticalGroup:new{ align = "left" }
    for _, entry in ipairs(self.entries) do
        local callback = entry.callback
        rows[#rows + 1] = Button:new{
            text = entry.text,
            width = inner_w,
            height = row_h,
            align = "left",
            padding_h = Screen:scaleBySize(20),
            padding_v = 0,
            bordersize = 0,
            radius = 0,
            text_font_size = 16,
            text_font_bold = entry.bold == true,
            callback = function()
                if callback then
                    UIManager:close(self)
                    -- Let KOReader finish dispatching the tap to this popup's
                    -- button before constructing its replacement. Showing a
                    -- submenu synchronously here leaves the old button event
                    -- active against a popup that has already been removed.
                    UIManager:nextTick(callback)
                end
            end,
            show_parent = self,
        }
    end
    local panel_h = rows:getSize().h + 2 * border

    self.panel_dimen = Geom:new{ x = panel_x, y = panel_y, w = panel_w, h = panel_h }
    local panel = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = border,
        radius = 0,
        background = Blitbuffer.COLOR_WHITE,
        rows,
    }
    local positioned_panel = WidgetContainer:new{
        dimen = self.panel_dimen:copy(),
        panel,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    self[1] = OverlapGroup:new{
        dimen = self.dimen:copy(),
        WidgetContainer:new{ dimen = self.dimen:copy() },
        positioned_panel,
    }
    self.ges_events = {
        TapClose = {
            GestureRange:new{ ges = "tap", range = self.dimen:copy() },
        },
    }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
end

function CategoryPopup:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.panel_dimen) then UIManager:close(self) end
    return true
end

function CategoryPopup:onShow()
    UIManager:setDirty(self, function() return "ui", self.panel_dimen end)
    return true
end

function CategoryPopup:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.panel_dimen end)
end

function CategoryPopup:onClose()
    UIManager:close(self)
    return true
end

local BookTile = InputContainer:extend{
    book = nil,
    callback = nil,
    width = nil,
    height = nil,
}

function BookTile:buildCover()
    if self.book.cover_path then
        return ImageWidget:new{
            file = self.book.cover_path,
            width = self.width,
            height = self.height,
            scale_factor = 0,
            alpha = true,
        }
    end

    return FrameContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        padding = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{
                w = self.width - 2 * Size.border.thin,
                h = self.height - 2 * Size.border.thin,
            },
            TextBoxWidget:new{
                text = (self.book.title or _("Untitled")) .. "\n\n"
                    .. (self.book.author or _("Unknown author")),
                width = self.width - 4 * Size.padding.large,
                alignment = "center",
                face = Font:getFace("cfont", 13),
                bold = true,
            },
        },
    }
end

function BookTile:init()
    self.rendered_path = self.book.cover_path
    self[1] = self:buildCover()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapBook = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function BookTile:updateCover(path)
    if not path or self.rendered_path == path then return false end
    self.book.cover_path = path
    self.rendered_path = path
    self[1]:free(true)
    self[1] = self:buildCover()
    return true
end

function BookTile:onTapBook()
    if self.callback then self.callback(self.book) end
    return true
end

local DonationDialog = InputContainer:extend{
    modal = true,
}

function DonationDialog:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self.ges_events = {
        TapClose = {
            GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h } },
        },
    }

    local qr_size = math.floor(math.min(screen_w, screen_h) * 0.5)
    local text_w = math.floor(screen_w * 0.8)

    local content = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = _("Enjoying Bookdrop?\nScan the code with your phone to support the project."),
            alignment = "center",
            face = Font:getFace("cfont", 16),
            width = text_w,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(24) },
        QRWidget:new{
            text = "https://ko-fi.com/davidc465",
            width = qr_size,
            height = qr_size,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
        TextBoxWidget:new{
            text = "ko-fi.com/davidc465",
            alignment = "center",
            face = Font:getFace("cfont", 13),
            width = text_w,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(24) },
        TextBoxWidget:new{
            text = _("Tap anywhere to close"),
            alignment = "center",
            face = Font:getFace("cfont", 12),
            width = text_w,
        },
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            padding = Screen:scaleBySize(24),
            bordersize = 0,
            radius = Size.radius.window,
            content,
        },
    }
end

function DonationDialog:onTapClose()
    UIManager:close(self)
    return true
end

function DonationDialog:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function DonationDialog:onClose()
    UIManager:close(self)
    return true
end

local StoreHome = InputContainer:extend{
    name = "bookdrop_home",
    covers_fullscreen = true,
    featured_books = nil,
    category_cards = nil,
    on_book = nil,
    on_search = nil,
    on_fiction = nil,
    on_nonfiction = nil,
    on_comics = nil,
    on_magazines = nil,
    on_new_arrivals = nil,
    on_all_books = nil,
    on_recent = nil,
    settings_builder = nil,
    has_recent = false,
}

function StoreHome:run(callback, value)
    UIManager:close(self)
    if callback then callback(value) end
end

function StoreHome:rule(width)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = Size.line.thin },
        background = Blitbuffer.COLOR_GRAY,
    }
end

function StoreHome:link(text, callback, width, height, bold, keep_home_open)
    return Button:new{
        text = text,
        width = width,
        height = height,
        align = "left",
        padding_h = Size.padding.default,
        bordersize = 0,
        radius = 0,
        text_font_size = 14,
        text_font_bold = bold == true,
        callback = function()
            if callback then
                if keep_home_open then callback() else self:run(callback) end
            end
        end,
        show_parent = self,
    }
end

function StoreHome:showCategories()
    local entries = {
        { text = _("Top categories") },
    }
    for _, card in ipairs(self.category_cards) do
        local card_callback = card.callback
        entries[#entries + 1] = {
            text = card.title,
            callback = function() self:run(card_callback) end,
        }
    end
    entries[#entries + 1] = {
        text = _("See all book categories"),
        bold = true,
        callback = function() self:run(self.on_all_books or self.on_new_arrivals) end,
    }
    entries[#entries + 1] = {
        text = _("New arrivals"),
        callback = function() self:run(self.on_new_arrivals) end,
    }
    if self.has_recent then
        entries[#entries + 1] = {
            text = _("Recently viewed"),
            callback = function() self:run(self.on_recent) end,
        }
    end
    UIManager:show(CategoryPopup:new{
        entries = entries,
        top = self.title_bar:getSize().h + Screen:scaleBySize(40),
    })
end

function StoreHome:showSettings(entries)
    entries = entries or (self.settings_builder and self.settings_builder(self))
    if not entries or #entries == 0 then return end
    UIManager:show(CategoryPopup:new{
        entries = entries,
        top = self.title_bar:getSize().h + Screen:scaleBySize(40),
        align_right = true,
    })
end

function StoreHome:showDonation()
    UIManager:show(DonationDialog:new{})
end

function StoreHome:donationBanner(width)
    local banner_h = Screen:scaleBySize(38)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = banner_h },
        Button:new{
            text = _("♥  Tap here to support Bookdrop on Ko-fi"),
            width = width,
            height = banner_h,
            bordersize = 0,
            radius = Size.radius.button,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            text_font_size = 13,
            text_font_bold = true,
            callback = function() self:showDonation() end,
            show_parent = self,
        },
    }
end

function StoreHome:bookShelf(title, books, callback, width)
    local gap = Screen:scaleBySize(18)
    local visible = math.min(3, #books)
    local cover_w = math.floor(width * 0.27)
    local cover_h = math.floor(cover_w * 1.46)
    local shelf_w = visible * cover_w + math.max(0, visible - 1) * gap
    local title_w = math.floor(width * 0.72)
    local action_w = width - title_w
    local header_h = Screen:scaleBySize(42)
    local shelf = HorizontalGroup:new{ align = "top" }

    for index = 1, visible do
        if index > 1 then shelf[#shelf + 1] = HorizontalSpan:new{ width = gap } end
        local tile = BookTile:new{
            book = books[index],
            width = cover_w,
            height = cover_h,
            callback = function(book) self:run(self.on_book, book) end,
        }
        self.book_tiles[#self.book_tiles + 1] = tile
        shelf[#shelf + 1] = tile
    end

    local header = HorizontalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{ w = title_w, h = header_h },
                TextBoxWidget:new{
                    text = title,
                    width = title_w,
                    face = Font:getFace("cfont", 18),
                    height_overflow_show_ellipsis = true,
                },
            },
            Button:new{
                text = _("See more  ›"),
                width = action_w,
                height = header_h,
                bordersize = 0,
                radius = 0,
                text_font_size = 13,
                text_font_bold = false,
                callback = function() self:run(callback) end,
                show_parent = self,
            },
        }
    if visible == 0 then return header end

    return VerticalGroup:new{
        header,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = cover_h },
            CenterContainer:new{
                dimen = Geom:new{ w = shelf_w, h = cover_h },
                shelf,
            },
        },
    }
end

function StoreHome:init()
    self.featured_books = self.featured_books or {}
    self.category_cards = self.category_cards or {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end

    local outer = Screen:scaleBySize(24)
    local section_gap = Screen:scaleBySize(18)
    local content_w = self.dimen.w - 2 * outer

    self.title_bar = TitleBar:new{
        fullscreen = true,
        width = self.dimen.w,
        align = "left",
        title = _("Bookdrop"),
        title_face = Font:getFace("cfont", 20),
        left_icon = "appbar.search",
        left_icon_tap_callback = function()
            if self.on_search then self.on_search(self) end
        end,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    self.book_tiles = {}
    local nav_h = Screen:scaleBySize(42)
    -- Three top-level tabs: categories, libraries, and the bundled manga app.
    local nav_left_w = math.floor(content_w * 0.36)
    local nav_mid_w = math.floor(content_w * 0.30)
    local content = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            self:link(_("BROWSE CATEGORIES  ▾"), function() self:showCategories() end,
                nav_left_w, nav_h, true, true),
            self:link(_("LIBRARIES  ▾"), function() self:showSettings() end,
                nav_mid_w, nav_h, true, true),
            self:link(_("MANGA"), function()
                if self.on_manga then self.on_manga(self) end
            end, content_w - nav_left_w - nav_mid_w, nav_h, true, true),
        },
        self:rule(content_w),
        VerticalSpan:new{ width = section_gap },
    }

    content[#content + 1] = self:donationBanner(content_w)
    content[#content + 1] = VerticalSpan:new{ width = section_gap }
    content[#content + 1] = self:rule(content_w)

    if #self.featured_books > 0 then
        content[#content + 1] = self:bookShelf(
            _("New and noteworthy"), self.featured_books, self.on_new_arrivals, content_w)
    end

    for _, card in ipairs(self.category_cards) do
        content[#content + 1] = VerticalSpan:new{ width = section_gap }
        content[#content + 1] = self:rule(content_w)
        content[#content + 1] = self:bookShelf(card.title, card.books, card.callback, content_w)
    end
    content[#content + 1] = VerticalSpan:new{ width = outer }

    local body_h = self.dimen.h - self.title_bar:getSize().h
    local padded_content = HorizontalGroup:new{
        HorizontalSpan:new{ width = outer },
        content,
        HorizontalSpan:new{ width = outer },
    }
    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = body_h },
        show_parent = self,
        padded_content,
    }
    self[1] = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ self.title_bar, self.cropping_widget },
    }
end

function StoreHome:refreshCovers()
    local changed = false
    for _, tile in ipairs(self.book_tiles) do
        if tile:updateCover(tile.book.cover_path) then changed = true end
    end
    if changed then UIManager:setDirty(self, "ui") end
end

function StoreHome:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "ui")
    return true
end

function StoreHome:onCloseWidget()
    self._bookdrop_closed = true
end

return StoreHome
