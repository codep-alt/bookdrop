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
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen

local BookView = InputContainer:extend{
    modal = true,
    book = nil,
    download_callback = nil,
}

local function join(values)
    local present = {}
    for _, value in ipairs(values) do
        if value and value ~= "" then present[#present + 1] = value end
    end
    return table.concat(present, "  ·  ")
end

local function cleanDescription(value)
    value = value or ""
    value = value:gsub("\r\n?", "\n")
    value = value:gsub("<[bB][rR]%s*/?>", "\n")
    value = value:gsub("</[pP]%s*>", "\n\n")
    value = value:gsub("<[^>]+>", "")
    local entities = {
        amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    }
    value = value:gsub("&([%a]+);", function(entity)
        return entities[entity] or ("&" .. entity .. ";")
    end)
    value = value:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
    value = value:gsub("%[([^%]]+)%]%[%d+%]", "%1")
    value = value:gsub("%[%d+%]:%s*https?://%S+", "")
    value = value:gsub("^SUMMARY:%s*", "")
    value = value:gsub("[ \t]+", " ")
    value = value:gsub(" *\n *", "\n")
    value = value:gsub("\n\n\n+", "\n\n")
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function concise(value, maximum)
    if value == nil then return nil end
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    if maximum and #value > maximum then
        return value:sub(1, maximum - 1):gsub("%s+%S*$", "") .. "…"
    end
    return value
end

local function addMetadata(lines, label, value, maximum)
    value = concise(value, maximum)
    if value then lines[#lines + 1] = label .. ":  " .. value end
end

local function acquisitionSize(acquisition)
    if not acquisition or not acquisition.size then return _("unknown size") end
    local bytes = tonumber(acquisition.size)
    if not bytes then return _("unknown size") end
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / 1024 / 1024) end
    return string.format("%.0f KB", bytes / 1024)
end

function BookView:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end

    local panel_w = math.floor(screen_w * 0.94)
    local panel_h = math.floor(screen_h * 0.88)
    local panel_x = math.floor((screen_w - panel_w) / 2)
    local panel_y = math.floor((screen_h - panel_h) / 2)
    local border = Size.border.thin
    local inner_w = panel_w - 2 * border
    local outer = Screen:scaleBySize(16)
    local gap = Size.padding.large
    local content_w = inner_w - 2 * outer
    local function separator()
        return LineWidget:new{
            dimen = Geom:new{ w = content_w, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        }
    end
    local close_w = Screen:scaleBySize(52)
    local header_h = Screen:scaleBySize(48)
    local header_title_w = inner_w - close_w
    local header = VerticalGroup:new{
        HorizontalGroup:new{
            Button:new{
                text = _("Book details"), width = header_title_w, height = header_h,
                align = "left", padding_h = outer, bordersize = 0, radius = 0,
                text_font_size = 17, text_font_bold = true,
                callback = function() end, show_parent = self,
            },
            Button:new{
                text = "×", width = close_w, height = header_h,
                bordersize = 0, radius = 0, text_font_size = 26,
                callback = function() self:onClose() end, show_parent = self,
            },
        },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = Size.line.thin },
            background = Blitbuffer.COLOR_DARK_GRAY,
        },
    }

    local cover_w = math.min(Screen:scaleBySize(112), math.floor(content_w * 0.24))
    local cover_h = math.floor(cover_w * 1.44)
    local cover
    if self.book.cover_path then
        cover = ImageWidget:new{
            file = self.book.cover_path,
            width = cover_w,
            height = cover_h,
            scale_factor = 0,
            alpha = true,
        }
    else
        cover = CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            TextBoxWidget:new{
                text = (self.book.title or _("Untitled")) .. "\n\n" ..
                    (self.book.author or _("Unknown author")),
                width = cover_w - 2 * outer,
                alignment = "center",
                face = Font:getFace("cfont", 15),
                bold = true,
            },
        }
    end
    cover = FrameContainer:new{
        padding = 0, bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_LIGHT_GRAY, cover,
    }

    local info_w = content_w - cover:getSize().w - gap
    local facts = join({ self.book.available_formats or self.book.format,
        self.book.language, self.book.year })
    local hero = HorizontalGroup:new{
        align = "top",
        cover,
        HorizontalSpan:new{ width = gap },
        VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text = self.book.title or _("Untitled"), width = info_w,
                face = Font:getFace("cfont", 21), bold = true,
            },
            self.book.subtitle and TextBoxWidget:new{
                text = self.book.subtitle, width = info_w,
                face = Font:getFace("cfont", 14),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            } or VerticalSpan:new{ width = 0 },
            VerticalSpan:new{ width = Size.padding.default },
            TextBoxWidget:new{
                text = _("by") .. " " .. (self.book.author or _("Unknown author")), width = info_w,
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = Size.padding.default },
            TextBoxWidget:new{
                text = (self.book.source or _("Catalog edition")):upper(), width = info_w,
                face = Font:getFace("cfont", 11), bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
            VerticalSpan:new{ width = Size.padding.default },
            TextBoxWidget:new{
                text = facts, width = info_w,
                face = Font:getFace("cfont", 13),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        },
    }

    local description = cleanDescription(self.book.description)
    if not description or description == "" then description = _("No description supplied for this edition.") end
    local metadata_lines = {}
    addMetadata(metadata_lines, _("Source"), self.book.source)
    addMetadata(metadata_lines, _("Publisher"), self.book.publisher)
    addMetadata(metadata_lines, _("Published"), self.book.published_date or self.book.year)
    addMetadata(metadata_lines, _("Originally published"), self.book.original_publication_date)
    addMetadata(metadata_lines, _("Publication place"), self.book.publication_place)
    addMetadata(metadata_lines, _("Edition"), self.book.edition)
    addMetadata(metadata_lines, _("Series"), self.book.series)
    addMetadata(metadata_lines, _("Volume"), self.book.volume)
    addMetadata(metadata_lines, _("Language"), self.book.language)
    addMetadata(metadata_lines, _("Pages / scanned images"), self.book.page_count)
    addMetadata(metadata_lines, _("ISBN"), self.book.isbn, 180)
    addMetadata(metadata_lines, _("Available formats"), self.book.available_formats)
    addMetadata(metadata_lines, _("Subjects"), self.book.subjects, 500)
    addMetadata(metadata_lines, _("Contributors"), self.book.contributors, 300)
    addMetadata(metadata_lines, _("Notes"), self.book.notes, 800)
    addMetadata(metadata_lines, _("Downloads"), self.book.downloads)
    addMetadata(metadata_lines, _("Rights / license"), self.book.rights, 400)
    local metadata_text = table.concat(metadata_lines, "\n")
    local availability
    if self.download_callback and self.book.acquisitions and #self.book.acquisitions > 0 then
        local download_choices = VerticalGroup:new{ align = "left" }
        local button_gap = Size.padding.default
        local button_w = math.floor((content_w - button_gap) / 2)
        for acquisition_number = 1, #self.book.acquisitions, 2 do
            local row = HorizontalGroup:new{ align = "top" }
            for offset = 0, 1 do
                local acquisition = self.book.acquisitions[acquisition_number + offset]
                if not acquisition then
                    row[#row + 1] = HorizontalSpan:new{ width = button_w }
                    break
                end
                local selected = acquisition
                row[#row + 1] = Button:new{
                    text = _("DOWNLOAD") .. " " .. (selected.format or _("EBOOK"))
                        .. "  ·  " .. acquisitionSize(selected),
                    width = button_w,
                    height = Screen:scaleBySize(48),
                    callback = function() self.download_callback(selected) end,
                    bordersize = Size.border.thin,
                    radius = 0,
                    preselect = true,
                    show_parent = self,
                }
                if offset == 0 then
                    row[#row + 1] = HorizontalSpan:new{ width = button_gap }
                end
            end
            download_choices[#download_choices + 1] = row
            download_choices[#download_choices + 1] = VerticalSpan:new{
                width = Size.padding.default,
            }
        end
        availability = VerticalGroup:new{
            TextBoxWidget:new{
                text = _("Download this book"),
                width = content_w,
                face = Font:getFace("cfont", 18), bold = true,
            },
            VerticalSpan:new{ width = Size.padding.default },
            download_choices,
        }
    else
        availability = VerticalGroup:new{
            TextBoxWidget:new{
                text = _("Available formats"), width = content_w,
                face = Font:getFace("cfont", 18), bold = true,
            },
            VerticalSpan:new{ width = Size.padding.default },
            TextBoxWidget:new{
                text = _("This library did not return a compatible public file."),
                width = content_w,
                face = Font:getFace("cfont", 14),
            },
        }
    end

    local fact_gap = Size.padding.large
    local fact_w = math.floor((content_w - 2 * fact_gap) / 3)
    local function fact(label, value)
        return VerticalGroup:new{
            TextBoxWidget:new{
                text = label:upper(), width = fact_w,
                face = Font:getFace("cfont", 10), bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
            TextBoxWidget:new{
                text = concise(value) or "—", width = fact_w,
                face = Font:getFace("cfont", 13), bold = true,
            },
        }
    end
    local facts_strip = HorizontalGroup:new{
        align = "top",
        fact(_("Published"), self.book.published_date or self.book.year),
        HorizontalSpan:new{ width = fact_gap },
        fact(_("Language"), self.book.language),
        HorizontalSpan:new{ width = fact_gap },
        fact(_("Source"), self.book.source),
    }

    local content = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = outer },
        hero,
        VerticalSpan:new{ width = outer },
        separator(),
        VerticalSpan:new{ width = gap },
        availability,
        VerticalSpan:new{ width = gap },
        separator(),
        VerticalSpan:new{ width = gap },
        facts_strip,
        VerticalSpan:new{ width = gap },
        separator(),
        VerticalSpan:new{ width = gap },
        TextBoxWidget:new{
            text = _("About this book"), width = content_w,
            face = Font:getFace("cfont", 19), bold = true,
        },
        VerticalSpan:new{ width = gap },
        TextBoxWidget:new{
            text = description, width = content_w,
            alignment = "left",
            face = Font:getFace("cfont", 15),
        },
        #metadata_lines > 0 and VerticalSpan:new{ width = outer } or VerticalSpan:new{ width = 0 },
        #metadata_lines > 0 and separator() or VerticalSpan:new{ width = 0 },
        #metadata_lines > 0 and VerticalSpan:new{ width = gap } or VerticalSpan:new{ width = 0 },
        #metadata_lines > 0 and TextBoxWidget:new{
            text = _("Edition information"), width = content_w,
            face = Font:getFace("cfont", 19), bold = true,
        } or VerticalSpan:new{ width = 0 },
        #metadata_lines > 0 and VerticalSpan:new{ width = gap } or VerticalSpan:new{ width = 0 },
        #metadata_lines > 0 and TextBoxWidget:new{
            text = metadata_text, width = content_w,
            alignment = "left",
            face = Font:getFace("cfont", 14),
        } or VerticalSpan:new{ width = 0 },
        VerticalSpan:new{ width = gap },
        TextBoxWidget:new{
            text = _("Catalog record") .. ":  " .. (self.book.id or ""),
            width = content_w,
            face = Font:getFace("cfont", 12),
            fgcolor = Blitbuffer.COLOR_GRAY,
        },
        VerticalSpan:new{ width = outer },
    }

    local body_h = panel_h - 2 * border - header:getSize().h
    local padded = HorizontalGroup:new{
        HorizontalSpan:new{ width = outer }, content, HorizontalSpan:new{ width = outer },
    }
    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = inner_w, h = body_h },
        show_parent = self,
        padded,
    }
    local panel = FrameContainer:new{
        padding = 0, margin = 0, bordersize = border, radius = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ header, self.cropping_widget },
    }
    self.panel_dimen = Geom:new{ x = panel_x, y = panel_y, w = panel_w, h = panel_h }
    self[1] = OverlapGroup:new{
        dimen = self.dimen:copy(),
        WidgetContainer:new{ dimen = self.dimen:copy() },
        WidgetContainer:new{ dimen = self.panel_dimen:copy(), panel },
    }
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen:copy() } },
    }
end

function BookView:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.panel_dimen) then UIManager:close(self) end
    return true
end

function BookView:onShow()
    UIManager:setDirty(self, function() return "ui", self.panel_dimen end)
    return true
end

function BookView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.panel_dimen end)
end

function BookView:onClose()
    UIManager:close(self)
    return true
end

return BookView
