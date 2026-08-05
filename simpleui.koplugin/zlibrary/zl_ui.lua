-- zl_ui.lua — Z-Library UI interface
-- Provides all UI windows for Z-Library integration:
--   search, book detail, login, settings, download progress.

local _          = require("sui_i18n").translate
local ZLConfig   = require("zlibrary/zl_config")
local ZLClient   = require("zlibrary/zl_client")
local logger     = require("logger")

local UIManager   = require("ui/uimanager")
local Device      = require("device")
local Screen      = Device.screen
local Font        = require("ui/font")
local Blitbuffer  = require("ffi/blitbuffer")
local Geom        = require("ui/geometry")
local GestureRange = require("ui/gesturerange")

local Menu             = require("ui/widget/menu")
local ok_id, InputDialog      = pcall(require, "ui/widget/inputdialog")
if not ok_id then InputDialog = nil end
local ok_mid, MultiInputDialog = pcall(require, "ui/widget/multiinputdialog")
if not ok_mid then MultiInputDialog = nil end
local InfoMessage      = require("ui/widget/infomessage")
local ConfirmBox       = require("ui/widget/confirmbox")
local TextBoxWidget    = require("ui/widget/textboxwidget")
local TextWidget       = require("ui/widget/textwidget")
local Button           = require("ui/widget/button")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local FrameContainer   = require("ui/widget/container/framecontainer")
local CenterContainer  = require("ui/widget/container/centercontainer")
local InputContainer   = require("ui/widget/container/inputcontainer")
local ImageWidget      = require("ui/widget/imagewidget")

-- Layout constants
local PAD  = Screen:scaleBySize(14)

local ZLUI = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Sanitize a string for use as a filename component.
local function _sanitizeFilename(s)
    if not s or s == "" then return "unknown" end
    s = s:gsub("[/\\:*?\"<>|]", "_")
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or s
    return s ~= "" and s or "unknown"
end

--- Build the destination path for a downloaded book.
local function _buildDestPath(book_info)
    local dir = ZLConfig.ensureDownloadDir()
    if not dir then
        dir = ZLConfig.getDownloadDir()
    end
    local author  = _sanitizeFilename(book_info.author or _("Unknown"))
    local title   = _sanitizeFilename(book_info.title or _("Unknown"))
    local ext = ""
    if book_info.format and book_info.format ~= "" then
        ext = book_info.format:lower()
        ext = ext:gsub("^%.", "")
    elseif book_info.download_url then
        ext = book_info.download_url:match("%.([%w]+)$") or ""
    end
    if ext == "" then ext = "epub" end
    return dir .. "/" .. author .. " - " .. title .. "." .. ext
end

--- Open a book file in KOReader's ReaderUI.
local function _openBook(file_path)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI then
        pcall(function() ReaderUI:showReader(file_path) end)
        return
    end
    local ok2, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok2 and FileManager and FileManager.instance then
        pcall(function() FileManager.instance:openFile(file_path) end)
    end
end

-- ---------------------------------------------------------------------------
-- Search window
-- ---------------------------------------------------------------------------

function ZLUI.showSearchWindow()
    if not InputDialog then
        UIManager:show(InfoMessage:new{
            text = _("Search not available (InputDialog missing)."),
            timeout = 3,
        })
        return
    end

    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search Z-Library"),
        input = "",
        input_hint = _("Enter book title or author"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = input_dialog:getInputText()
                        if not query or query:match("^%s*$") then return end
                        UIManager:close(input_dialog)
                        ZLUI._doSearch(query, 1)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function ZLUI._doSearch(query, page)
    local domain = ZLConfig.getActiveDomain()
    local loading_msg = InfoMessage:new{
        text = _("Searching…"),
        timeout = 0,
    }
    UIManager:show(loading_msg)

    UIManager:scheduleIn(0.1, function()
        local result, err = ZLClient.search(domain, query, page)

        UIManager:scheduleIn(0.1, function()
            pcall(function() UIManager:close(loading_msg) end)

            if not result then
                UIManager:show(InfoMessage:new{
                    text = _("Search failed: ") .. tostring(err),
                    timeout = 5,
                })
                return
            end

            if not result.books or #result.books == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("No results found."),
                    timeout = 3,
                })
                return
            end

            ZLUI._showSearchResults(query, result, page)
        end)
    end)
end

function ZLUI._showSearchResults(query, result, page)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = PAD

    local item_table = {}
    for i, book in ipairs(result.books) do
        local fmt = book.format and book.format ~= "" and book.format or "?"
        local size = book.size and book.size ~= "" and book.size or ""
        local detail = string.format("(%s", fmt)
        if size ~= "" then
            detail = detail .. ", " .. size
        end
        detail = detail .. ")"

        item_table[#item_table + 1] = {
            text = string.format("%s - %s %s", book.title or _("Unknown"), book.author or _("Unknown"), detail),
            book = book,
        }
    end

    local title_text = _("Search Results")
    if result.total_pages and result.total_pages > 1 then
        title_text = title_text .. string.format(" (%d/%d)", page, result.total_pages)
    end

    local menu
    menu = Menu:new{
        title = title_text,
        item_table = item_table,
        width = screen_w - padding * 2,
        height = screen_h - padding * 2,
        is_popout = false,
        onMenuSelect = function(self_menu, item)
            if item and item.book then
                ZLUI.showBookDetail(item.book)
            end
        end,
    }

    -- Add pagination buttons as a footer
    local has_prev = page > 1
    local has_next = result.total_pages and page < result.total_pages

    if has_prev or has_next then
        local btn_row = HorizontalGroup:new{ align = "center" }

        if has_prev then
            local prev_btn = Button:new{
                text = _("Previous"),
                width = math.floor((screen_w - padding * 4) / 2),
                callback = function()
                    UIManager:close(menu)
                    ZLUI._doSearch(query, page - 1)
                end,
            }
            btn_row:add(prev_btn)
        end

        if has_next then
            if has_prev then
                btn_row:add(HorizontalSpan:new{ width = padding })
            end
            local next_btn = Button:new{
                text = _("Next"),
                width = math.floor((screen_w - padding * 4) / 2),
                callback = function()
                    UIManager:close(menu)
                    ZLUI._doSearch(query, page + 1)
                end,
            }
            btn_row:add(next_btn)
        end
    end

    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Book detail window
-- ---------------------------------------------------------------------------

function ZLUI.showBookDetail(book_info)
    local domain = ZLConfig.getActiveDomain()

    -- Check login status first
    if not ZLClient.isLoggedIn(domain) then
        ZLUI.showLoginWindow(function()
            ZLUI.showBookDetail(book_info)
        end)
        return
    end

    local loading_msg = InfoMessage:new{
        text = _("Loading book details…"),
        timeout = 0,
    }
    UIManager:show(loading_msg)

    UIManager:scheduleIn(0.1, function()
        local info, err = ZLClient.getBookInfo(domain, book_info.url)

        UIManager:scheduleIn(0.1, function()
            pcall(function() UIManager:close(loading_msg) end)

            if not info then
                UIManager:show(InfoMessage:new{
                    text = _("Failed to load book details: ") .. tostring(err),
                    timeout = 5,
                })
                return
            end

            for k, v in pairs(book_info) do
                if info[k] == nil or info[k] == "" then
                    info[k] = v
                end
            end

            ZLUI._showBookDetailMenu(info)
        end)
    end)
end

function ZLUI._showBookDetailMenu(info)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = PAD

    local item_table = {}

    item_table[#item_table + 1] = {
        text = info.title or _("Unknown Title"),
        font_bold = true,
    }

    item_table[#item_table + 1] = {
        text = _("Author: ") .. (info.author or _("Unknown")),
    }

    local fmt = info.format or ""
    local size = info.size or ""
    if fmt ~= "" or size ~= "" then
        local fmt_text = _("Format: ")
        if fmt ~= "" then fmt_text = fmt_text .. fmt end
        if size ~= "" then
            if fmt ~= "" then
                fmt_text = fmt_text .. ", " .. size
            else
                fmt_text = fmt_text .. size
            end
        end
        item_table[#item_table + 1] = { text = fmt_text }
    end

    if info.year and info.year ~= "" then
        item_table[#item_table + 1] = { text = _("Year: ") .. info.year }
    end

    if info.publisher and info.publisher ~= "" then
        item_table[#item_table + 1] = { text = _("Publisher: ") .. info.publisher }
    end

    if info.language and info.language ~= "" then
        item_table[#item_table + 1] = { text = _("Language: ") .. info.language }
    end

    item_table[#item_table + 1] = {
        text = "───",
        enabled = false,
    }

    if info.description and info.description ~= "" then
        item_table[#item_table + 1] = {
            text = _("Description"),
            callback = function()
                ZLUI._showDescription(info.description)
            end,
        }
    end

    if info.formats and #info.formats > 0 then
        item_table[#item_table + 1] = { text = "───", enabled = false }

        for _, fmt_entry in ipairs(info.formats) do
            local fmt_name = fmt_entry.name or _("Download")
            local fmt_url = fmt_entry.url
            item_table[#item_table + 1] = {
                text = _("Download: ") .. fmt_name,
                callback = function()
                    local download_info = {}
                    for k, v in pairs(info) do download_info[k] = v end
                    download_info.download_url = fmt_url
                    download_info.format = fmt_name
                    ZLUI.showDownloadProgress(download_info)
                end,
            }
        end
    else
        item_table[#item_table + 1] = { text = "───", enabled = false }
        item_table[#item_table + 1] = {
            text = _("Download"),
            callback = function()
                ZLUI.showDownloadProgress(info)
            end,
        }
    end

    local menu
    menu = Menu:new{
        title = info.title or _("Book Detail"),
        item_table = item_table,
        width = screen_w - padding * 2,
        height = screen_h - padding * 2,
        is_popout = false,
        onMenuSelect = function(self_menu, item)
            if item.callback then
                local cb = item.callback
                if item.text == _("Description") then
                    cb()
                else
                    UIManager:close(menu)
                    cb()
                end
            end
        end,
    }

    UIManager:show(menu)
end

function ZLUI._showDescription(description)
    if not description or description == "" then return end

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = PAD
    local text_w = screen_w - padding * 4

    local desc_widget = InputContainer:new{ modal = true }

    local text_box = TextBoxWidget:new{
        text = description,
        face = Font:getFace("cfont", 18),
        width = text_w,
        height = screen_h - padding * 6,
        alignment = "left",
        line_height = 0.3,
    }

    local close_btn = Button:new{
        text = _("Close"),
        callback = function()
            UIManager:close(desc_widget)
        end,
    }

    local vg = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = padding },
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = Screen:scaleBySize(24) },
            TextWidget:new{
                text = _("Description"),
                face = Font:getFace("cfont", 22),
                bold = true,
            },
        },
        VerticalSpan:new{ width = padding },
        text_box,
        VerticalSpan:new{ width = padding },
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = Screen:scaleBySize(40) },
            close_btn,
        },
    }

    desc_widget[1] = FrameContainer:new{
        bordersize = 1,
        padding = padding,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w - padding * 2, h = screen_h - padding * 2 },
            vg,
        },
    }

    desc_widget.dimen = desc_widget[1]:getSize()
    desc_widget.covers_fullscreen = true

    desc_widget.ges_events = {
        TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
            },
        },
    }
    desc_widget.onTapClose = function()
        UIManager:close(desc_widget)
    end

    UIManager:show(desc_widget)
end

-- ---------------------------------------------------------------------------
-- Login window
-- ---------------------------------------------------------------------------

function ZLUI.showLoginWindow(callback)
    if not MultiInputDialog then
        UIManager:show(InfoMessage:new{
            text = _("Login not available (MultiInputDialog missing)."),
            timeout = 3,
        })
        return
    end

    local domain = ZLConfig.getActiveDomain()
    local saved_user = ZLConfig.getUserReminder(domain) or ""

    local dialog
    dialog = MultiInputDialog:new{
        title = _("Login to Z-Library"),
        fields = {
            {
                text = saved_user,
                hint = _("Email"),
            },
            {
                text = "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Switch Domain"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:scheduleIn(0.05, function()
                            ZLUI._showDomainPicker(function()
                                ZLUI.showLoginWindow(callback)
                            end)
                        end)
                    end,
                },
                {
                    text = _("Login"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local username = fields[1] or ""
                        local password = fields[2] or ""

                        if username == "" or password == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter both email and password."),
                                timeout = 3,
                            })
                            return
                        end

                        UIManager:close(dialog)
                        ZLUI._doLogin(username, password, callback)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ZLUI._doLogin(username, password, callback)
    local domain = ZLConfig.getActiveDomain()
    local loading_msg = InfoMessage:new{
        text = _("Logging in…"),
        timeout = 0,
    }
    UIManager:show(loading_msg)

    UIManager:scheduleIn(0.1, function()
        local ok, err = ZLClient.login(domain, username, password)

        UIManager:scheduleIn(0.1, function()
            pcall(function() UIManager:close(loading_msg) end)

            if ok then
                UIManager:show(InfoMessage:new{
                    text = _("Login successful!"),
                    timeout = 2,
                })
                if callback then callback() end
            else
                UIManager:show(InfoMessage:new{
                    text = _("Login failed: ") .. tostring(err),
                    timeout = 5,
                })
            end
        end)
    end)
end

function ZLUI._showDomainPicker(callback)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local item_table = {}
    local domains = ZLConfig.getDomains()
    local active_url = ZLConfig.getActiveDomain()

    -- Default (built-in) domains that cannot be deleted
    local DEFAULT_URLS = {
        ["https://z-lib.org"] = true,
        ["https://singlelogin.re"] = true,
        ["https://z-library.sk"] = true,
    }

    for _, d in ipairs(domains) do
        local is_active = active_url == d.url
        local is_builtin = DEFAULT_URLS[d.url] == true
        item_table[#item_table + 1] = {
            text = d.name .. (is_active and "  ✓" or ""),
            callback = function()
                if not is_active then
                    ZLConfig.setActiveDomain(d.url)
                end
                if callback then callback() end
            end,
        }
        -- Add a "Delete" entry for non-builtin domains
        if not is_builtin then
            item_table[#item_table + 1] = {
                text = "  " .. _("Delete: ") .. d.name,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete domain?") .. "\n" .. d.name .. " (" .. d.url .. ")",
                        ok_text = _("Delete"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            local current_domains = ZLConfig.getDomains()
                            local new_domains = {}
                            for _, dd in ipairs(current_domains) do
                                if dd.url ~= d.url then
                                    new_domains[#new_domains + 1] = dd
                                end
                            end
                            ZLConfig.setDomains(new_domains)
                            -- If deleted the active domain, switch to first remaining
                            if d.url == active_url and #new_domains > 0 then
                                ZLConfig.setActiveDomain(new_domains[1].url)
                            end
                            -- Refresh the domain picker
                            ZLUI._showDomainPicker(callback)
                        end,
                    })
                end,
            }
        end
    end

    -- Separator
    item_table[#item_table + 1] = {
        text = "───",
        enabled = false,
    }

    -- Add domain entry
    item_table[#item_table + 1] = {
        text = _("Add domain…"),
        callback = function()
            ZLUI._showAddDomainDialog(callback)
        end,
    }

    local menu
    menu = Menu:new{
        title = _("Select Domain"),
        item_table = item_table,
        width = screen_w - PAD * 2,
        height = screen_h - PAD * 2,
        is_popout = false,
        onMenuSelect = function(self_menu, item)
            if item.callback then
                local cb = item.callback
                UIManager:close(menu)
                UIManager:scheduleIn(0.05, function() cb() end)
            end
        end,
    }

    UIManager:show(menu)
end

function ZLUI._showAddDomainDialog(callback)
    if MultiInputDialog then
        ZLUI._showAddDomainMultiInput(callback)
    elseif InputDialog then
        ZLUI._showAddDomainStepByStep(callback, 1, {}, nil)
    else
        UIManager:show(InfoMessage:new{
            text = _("Input dialog not available."),
            timeout = 3,
        })
    end
end

function ZLUI._showAddDomainMultiInput(callback)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Add Domain"),
        fields = {
            {
                text = "",
                hint = _("Domain name (e.g. My Z-Library)"),
            },
            {
                text = "https://",
                hint = _("Domain URL (e.g. https://z-lib.org)"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local name = fields[1] or ""
                        local url = fields[2] or ""

                        -- Strip trailing slash from URL
                        url = url:gsub("/+$", "")

                        if name == "" or url == "" or not url:match("^https?://") then
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a valid name and URL (must start with http:// or https://)."),
                                timeout = 3,
                            })
                            return
                        end

                        -- Check for duplicate
                        local current_domains = ZLConfig.getDomains()
                        for _, d in ipairs(current_domains) do
                            if d.url == url then
                                UIManager:show(InfoMessage:new{
                                    text = _("This domain URL already exists."),
                                    timeout = 3,
                                })
                                return
                            end
                        end

                        -- Add the new domain
                        current_domains[#current_domains + 1] = {
                            name = name,
                            url = url,
                        }
                        ZLConfig.setDomains(current_domains)
                        ZLConfig.setActiveDomain(url)

                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Domain added: ") .. name,
                            timeout = 2,
                        })
                        if callback then callback() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ZLUI._showAddDomainStepByStep(callback, step, partial, input_dialog)
    -- Fallback when MultiInputDialog is not available:
    -- step 1 = ask for domain name, step 2 = ask for URL
    if step == 1 then
        local dialog
        dialog = InputDialog:new{
            title = _("Add Domain"),
            input = "",
            input_hint = _("Domain name (e.g. My Z-Library)"),
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                    {
                        text = _("Next"),
                        is_enter_default = true,
                        callback = function()
                            local name = dialog:getInputText()
                            if not name or name:match("^%s*$") then
                                UIManager:show(InfoMessage:new{
                                    text = _("Please enter a domain name."),
                                    timeout = 3,
                                })
                                return
                            end
                            UIManager:close(dialog)
                            ZLUI._showAddDomainStepByStep(callback, 2, { name = name })
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    elseif step == 2 then
        local dialog
        dialog = InputDialog:new{
            title = _("Add Domain") .. " — " .. partial.name,
            input = "https://",
            input_hint = _("Domain URL (e.g. https://z-lib.org)"),
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                    {
                        text = _("Add"),
                        is_enter_default = true,
                        callback = function()
                            local url = dialog:getInputText() or ""

                            -- Strip trailing slash from URL
                            url = url:gsub("/+$", "")

                            if url == "" or not url:match("^https?://") then
                                UIManager:show(InfoMessage:new{
                                    text = _("Please enter a valid name and URL (must start with http:// or https://)."),
                                    timeout = 3,
                                })
                                return
                            end

                            -- Check for duplicate
                            local current_domains = ZLConfig.getDomains()
                            for _, d in ipairs(current_domains) do
                                if d.url == url then
                                    UIManager:show(InfoMessage:new{
                                        text = _("This domain URL already exists."),
                                        timeout = 3,
                                    })
                                    return
                                end
                            end

                            -- Add the new domain
                            current_domains[#current_domains + 1] = {
                                name = partial.name,
                                url = url,
                            }
                            ZLConfig.setDomains(current_domains)
                            ZLConfig.setActiveDomain(url)

                            UIManager:close(dialog)
                            UIManager:show(InfoMessage:new{
                                text = _("Domain added: ") .. partial.name,
                                timeout = 2,
                            })
                            if callback then callback() end
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
end

-- ---------------------------------------------------------------------------
-- Settings menu
-- ---------------------------------------------------------------------------

function ZLUI.showSettingsMenu()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local domain = ZLConfig.getActiveDomain()
    local is_logged_in = ZLClient.isLoggedIn(domain)
    local user_hint = ZLConfig.getUserReminder(domain)

    local item_table = {}

    item_table[#item_table + 1] = {
        text = _("Domain: ") .. ZLConfig.getActiveDomainName(),
        callback = function()
            ZLUI._showDomainPicker()
        end,
    }

    if is_logged_in then
        local user_text = user_hint and user_hint ~= "" and user_hint or _("logged in")
        item_table[#item_table + 1] = {
            text = _("Logged in as: ") .. user_text,
            callback = function()
                ZLUI._showLogoutConfirm()
            end,
        }
    else
        item_table[#item_table + 1] = {
            text = _("Not logged in"),
            callback = function()
                ZLUI.showLoginWindow()
            end,
        }
    end

    item_table[#item_table + 1] = {
        text = _("Download directory: ") .. ZLConfig.getDownloadDir(),
        callback = function()
            ZLUI._showDownloadDirPicker()
        end,
    }

    item_table[#item_table + 1] = {
        text = _("Clear recent downloads"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear the recent downloads list?"),
                ok_text = _("Clear"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    ZLConfig.clearRecent()
                    UIManager:show(InfoMessage:new{
                        text = _("Recent downloads cleared."),
                        timeout = 2,
                    })
                end,
            })
        end,
    }

    item_table[#item_table + 1] = {
        text = _("Clear login cookies"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all stored login cookies? You will need to log in again."),
                ok_text = _("Clear"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    ZLConfig.clearAllCookies()
                    UIManager:show(InfoMessage:new{
                        text = _("Cookies cleared."),
                        timeout = 2,
                    })
                end,
            })
        end,
    }

    item_table[#item_table + 1] = { text = "───", enabled = false }
    item_table[#item_table + 1] = {
        text = _("About Z-Library"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Z-Library search integration for KOReader.\nSearch and download books from Z-Library mirror sites."),
                timeout = 5,
            })
        end,
    }

    local menu
    menu = Menu:new{
        title = _("Z-Library Settings"),
        item_table = item_table,
        width = screen_w - PAD * 2,
        height = screen_h - PAD * 2,
        is_popout = false,
        onMenuSelect = function(self_menu, item)
            if item.callback then
                local cb = item.callback
                UIManager:close(menu)
                UIManager:scheduleIn(0.05, function() cb() end)
            end
        end,
    }

    UIManager:show(menu)
end

function ZLUI._showLogoutConfirm()
    UIManager:show(ConfirmBox:new{
        text = _("Log out of Z-Library?"),
        ok_text = _("Log Out"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            ZLConfig.clearCookies(ZLConfig.getActiveDomain())
            UIManager:show(InfoMessage:new{
                text = _("Logged out."),
                timeout = 2,
            })
        end,
    })
end

function ZLUI._showDownloadDirPicker()
    local ok, Dialog = pcall(require, "ui/widget/directorychooser")
    if not ok or not Dialog then
        local input
        input = InputDialog:new{
            title = _("Download Directory"),
            input = ZLConfig.getDownloadDir(),
            input_hint = _("Enter download directory path"),
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(input)
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local dir = input:getInputText()
                            if dir and dir ~= "" then
                                ZLConfig.setDownloadDir(dir)
                            end
                            UIManager:close(input)
                        end,
                    },
                },
            },
        }
        UIManager:show(input)
        input:onShowKeyboard()
        return
    end

    local chooser = Dialog:new{
        title = _("Select Download Directory"),
        path = ZLConfig.getDownloadDir(),
        onConfirm = function(dir)
            ZLConfig.setDownloadDir(dir)
        end,
    }
    UIManager:show(chooser)
end

-- ---------------------------------------------------------------------------
-- Download progress
-- ---------------------------------------------------------------------------

function ZLUI.showDownloadProgress(book_info)
    local domain = ZLConfig.getActiveDomain()

    local download_url = book_info.download_url
    if not download_url or download_url == "" then
        if book_info.url then
            download_url = book_info.url
        end
    end

    if not download_url or download_url == "" then
        UIManager:show(InfoMessage:new{
            text = _("No download URL available for this book."),
            timeout = 3,
        })
        return
    end

    local dest_path = _buildDestPath(book_info)

    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs and lfs.attributes(dest_path, "mode") == "file" then
        UIManager:show(ConfirmBox:new{
            text = _("File already exists:") .. "\n" .. dest_path .. "\n" .. _("Download again?"),
            ok_text = _("Download"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                ZLUI._startDownload(domain, download_url, dest_path, book_info)
            end,
        })
        return
    end

    ZLUI._startDownload(domain, download_url, dest_path, book_info)
end

function ZLUI._startDownload(domain, download_url, dest_path, book_info)
    local loading_msg = InfoMessage:new{
        text = _("Downloading…") .. "\n" .. (book_info.title or ""),
        timeout = 0,
    }
    UIManager:show(loading_msg)

    UIManager:scheduleIn(0.1, function()
        local ok, err = ZLClient.downloadBook(domain, download_url, dest_path)

        UIManager:scheduleIn(0.1, function()
            pcall(function() UIManager:close(loading_msg) end)

            if ok then
                ZLConfig.addRecent({
                    title  = book_info.title or _("Unknown"),
                    author = book_info.author or _("Unknown"),
                    format = book_info.format or "",
                    path   = dest_path,
                })

                UIManager:show(ConfirmBox:new{
                    text = _("Download complete!") .. "\n" .. dest_path .. "\n" .. _("Read now?"),
                    ok_text = _("Read"),
                    cancel_text = _("Later"),
                    ok_callback = function()
                        _openBook(dest_path)
                    end,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Download failed: ") .. tostring(err),
                    timeout = 5,
                })
                pcall(function()
                    local lfs = require("libs/libkoreader-lfs")
                    if lfs.attributes(dest_path, "mode") then
                        os.remove(dest_path)
                    end
                end)
            end
        end)
    end)
end

return ZLUI
