local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")

local Screen = Device.screen

local LoadingView = InputContainer:extend{
    covers_fullscreen = true,
    text = nil,
}

function LoadingView:init()
    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self[1] = FrameContainer:new{
        dimen = self.dimen:copy(),
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = self.dimen:copy(),
            TextBoxWidget:new{
                text = self.text,
                width = math.floor(self.dimen.w * 0.72),
                alignment = "center",
                face = Font:getFace("cfont", 18),
                bold = true,
            },
        },
    }
end

return LoadingView
