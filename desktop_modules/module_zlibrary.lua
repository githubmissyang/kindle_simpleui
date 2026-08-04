-- module_zlibrary.lua — Simple UI Z-Library module
-- Home screen module: search entry point + recent downloads.
-- Tapping the search bar opens the Z-Library search window.
-- Tapping a recent download opens the book in ReaderUI.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _  = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext

local UI           = require("sui_core")
local SUISettings  = require("sui_store")
local SUIStyle     = require("sui_style")
local Config       = require("sui_config")
local ZLConfig     = require("zlibrary/zl_config")
local ZLClient     = require("zlibrary/zl_client")
local ZLUI         = require("zlibrary/zl_ui")

local PAD          = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Pixel constants (base values at 100 % scale)
-- ---------------------------------------------------------------------------

local _BASE_SEARCH_H   = Screen:scaleBySize(44)
local _BASE_SEARCH_FS  = SUIStyle.FS_BODY          -- 18
local _BASE_RECENT_H   = Screen:scaleBySize(36)
local _BASE_RECENT_FS  = SUIStyle.FS_DETAIL         -- 15
local _BASE_LABEL_FS   = SUIStyle.FS_CAPTION        -- 13
local _BASE_ICON_SZ    = Screen:scaleBySize(20)
local _BASE_MODULE_H   = Screen:scaleBySize(200)
local _BASE_CORNER_R   = Screen:scaleBySize(10)
local _BASE_FRAME_PAD  = Screen:scaleBySize(10)

-- ---------------------------------------------------------------------------
-- Module descriptor
-- ---------------------------------------------------------------------------

local M = {}
M.id          = "zlibrary"
M.name        = _("Z-Library")
M.label       = _("Z-Library")
M.enabled_key = "zlibrary_enabled"
M.default_on  = true
M.has_covers  = true

function M.isEnabled(pfx)
    -- nilOrTrue: default enabled when key not set (matches default_on = true)
    return SUISettings:nilOrTrue(pfx .. M.enabled_key)
end

-- ---------------------------------------------------------------------------
-- Search bar widget
-- ---------------------------------------------------------------------------

local function _buildSearchBar(w, ctx, scale)
    scale = scale or 1.0
    local h       = math.max(20, math.floor(_BASE_SEARCH_H * scale))
    local fs      = math.max(8,  math.floor(_BASE_SEARCH_FS * scale))
    local corner  = math.max(4,  math.floor(_BASE_CORNER_R * scale))
    local fpad    = math.max(4,  math.floor(_BASE_FRAME_PAD * scale))
    local icon_sz = math.max(10, math.floor(_BASE_ICON_SZ * scale))

    local domain = ZLConfig.getActiveDomainName()
    local hint_text = _("Search Z-Library") .. " (" .. domain .. ")"

    -- Determine icon path: look for the SVG next to this module file
    local src = debug.getinfo(1, "S").source or ""
    local p_root = src:match("^@?(.+)/[^/]+$")
    local icon_path
    if p_root then
        icon_path = p_root:match("^(.+/desktop_modules)$")
            and (p_root:match("^(.+/desktop_modules)$"):gsub("/desktop_modules$", "") .. "/icons/zlibrary.svg")
            or nil
    end

    local search_inner = HorizontalGroup:new{
        align = "center",
        dimen = Geom:new{ w = w - fpad * 2, h = h - fpad * 2 },
    }

    -- Icon (if found)
    if icon_path then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(icon_path, "mode") == "file" then
            search_inner:add(CenterContainer:new{
                dimen = Geom:new{ w = icon_sz + fpad, h = h - fpad * 2 },
                ImageWidget:new{
                    file = icon_path,
                    width = icon_sz,
                    height = icon_sz,
                    alpha = true,
                },
            })
        end
    end

    -- Hint text
    local text_w = w - fpad * 2
    if icon_path then text_w = text_w - icon_sz - fpad end
    search_inner:add(CenterContainer:new{
        dimen = Geom:new{ w = text_w, h = h - fpad * 2 },
        TextWidget:new{
            text    = hint_text,
            face    = Font:getFace(SUIStyle.FACE_REGULAR, fs),
            fgcolor = CLR_TEXT_SUB,
        },
    })

    local search_tap = InputContainer:new{}
    search_tap[1] = FrameContainer:new{
        background = Blitbuffer.gray(0.06),
        radius     = corner,
        padding    = fpad,
        bordersize = 0,
        search_inner,
    }
    search_tap.dimen = search_tap[1]:getSize()
    search_tap.ges_events = {
        TapSearch = {
            GestureRange:new{
                ges = "tap",
                range = search_tap.dimen,
            },
        },
    }
    search_tap.onTapSearch = function()
        ZLUI.showSearchWindow()
    end

    return search_tap
end

-- ---------------------------------------------------------------------------
-- Recent downloads list widget
-- ---------------------------------------------------------------------------

local function _buildRecentList(w, ctx, scale)
    scale = scale or 1.0
    local recent = ZLConfig.getRecent()

    if not recent or #recent == 0 then
        -- No recent downloads — show a subtle hint
        local fs = math.max(8, math.floor(_BASE_LABEL_FS * scale))
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = math.max(16, math.floor(_BASE_RECENT_H * scale)) },
            TextWidget:new{
                text    = _("No recent downloads"),
                face    = Font:getFace(SUIStyle.FACE_REGULAR, fs),
                fgcolor = CLR_TEXT_SUB,
            },
        }
    end

    local item_fs = math.max(8, math.floor(_BASE_RECENT_FS * scale))
    local max_items = math.min(#recent, 3)

    local items = VerticalGroup:new{ align = "left" }

    for i = 1, max_items do
        local entry = recent[i]
        local title  = entry.title or _("Unknown")
        local author = entry.author or ""
        local text = title
        if author and author ~= "" and author ~= _("Unknown") then
            text = title .. " — " .. author
        end

        local item_widget = InputContainer:new{}
        local item_content = FrameContainer:new{
            background = Blitbuffer.gray(0.04),
            radius     = math.max(2, math.floor(_BASE_CORNER_R * scale * 0.6)),
            padding    = math.max(2, math.floor(_BASE_FRAME_PAD * scale * 0.6)),
            bordersize = 0,
            TextWidget:new{
                text    = text,
                face    = Font:getFace(SUIStyle.FACE_REGULAR, item_fs),
                fgcolor = Blitbuffer.COLOR_BLACK,
                width   = w - PAD * 2 - math.max(2, math.floor(_BASE_FRAME_PAD * scale)),
            },
        }
        item_widget[1] = item_content
        item_widget.dimen = item_content:getSize()

        local book_path = entry.path
        if book_path and book_path ~= "" then
            item_widget.ges_events = {
                TapBook = {
                    GestureRange:new{
                        ges = "tap",
                        range = item_widget.dimen,
                    },
                },
            }
            item_widget.onTapBook = function()
                local ok, ReaderUI = pcall(require, "apps/reader/readerui")
                if ok and ReaderUI then
                    pcall(function() ReaderUI:showReader(book_path) end)
                end
            end
        end

        items:add(item_widget)

        if i < max_items then
            items:add(VerticalSpan:new{ width = math.max(2, math.floor(4 * scale)) })
        end
    end

    return items
end

-- ---------------------------------------------------------------------------
-- Module interface
-- ---------------------------------------------------------------------------

function M.build(w, ctx)
    local scale = Config:getModuleScale(ctx, M.id) or 1.0

    local vg = VerticalGroup:new{
        align = "left",
    }

    -- Section label
    if M.label then
        local label_fs = math.max(6, math.floor(SUIStyle.FS_CAPTION * scale))
        vg:add(TextWidget:new{
            text    = M.label,
            face    = Font:getFace(SUIStyle.FACE_BOLD, label_fs),
            fgcolor = CLR_TEXT_SUB,
            width   = w,
        })
        vg:add(VerticalSpan:new{ width = math.max(2, math.floor(6 * scale)) })
    end

    -- Search bar
    local ok_search, search_bar = pcall(_buildSearchBar, w, ctx, scale)
    if ok_search and search_bar then
        vg:add(search_bar)
    else
        -- Fallback: simple text button if search bar fails
        logger.warn("module_zlibrary: search bar build failed, using fallback")
        vg:add(TextWidget:new{
            text    = _("Search Z-Library"),
            face    = Font:getFace(SUIStyle.FACE_REGULAR, math.max(8, math.floor(_BASE_SEARCH_FS * scale))),
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
    end
    vg:add(VerticalSpan:new{ width = math.max(2, math.floor(8 * scale)) })

    -- Recent downloads
    local ok_recent, recent_list = pcall(_buildRecentList, w, ctx, scale)
    if ok_recent and recent_list then
        vg:add(recent_list)
    end

    -- Wrap in an InputContainer for long-press to open settings
    local module_widget = InputContainer:new{}
    module_widget[1] = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        vg,
    }
    module_widget.dimen = module_widget[1]:getSize()

    -- Long press opens Z-Library settings
    module_widget.ges_events = {
        HoldSettings = {
            GestureRange:new{
                ges  = "hold",
                range = module_widget.dimen,
            },
        },
    }
    module_widget.onHoldSettings = function()
        ZLUI.showSettingsMenu()
    end

    return module_widget
end

function M.getHeight(ctx)
    local scale = Config:getModuleScale(ctx, M.id) or 1.0
    return math.max(40, math.floor(_BASE_MODULE_H * scale))
end

function M.getMenuItems(ctx_menu)
    local domain = ZLConfig.getActiveDomainName()
    local is_logged_in = ZLClient.isLoggedIn(ZLConfig.getActiveDomain())

    return {
        {
            text = _("Z-Library: Search"),
            callback = function()
                ZLUI.showSearchWindow()
            end,
        },
        {
            text = _("Z-Library: Login"),
            callback = function()
                ZLUI.showLoginWindow()
            end,
        },
        {
            text = _("Z-Library: Settings"),
            callback = function()
                ZLUI.showSettingsMenu()
            end,
        },
        {
            text = is_logged_in
                and _("Z-Library: Logged in (%s)"):format(domain)
                or  _("Z-Library: Not logged in (%s)"):format(domain),
            callback = function()
                if is_logged_in then
                    ZLUI.showSettingsMenu()
                else
                    ZLUI.showLoginWindow()
                end
            end,
        },
    }
end

return M
