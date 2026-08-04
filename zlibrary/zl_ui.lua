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

-- Lazy-loaded widgets to avoid circular requires at module load time.
local _Menu, _InputDialog, _MultiInputDialog, _InfoMessage, _ConfirmBox
local _TextBoxWidget, _VerticalGroup, _VerticalSpan, _FrameContainer
local _CenterContainer, _TextWidget, _Button, _ProgressBarWidget
local _Geom, _Blitbuffer, _InputContainer, _GestureRange, _HorizontalGroup

local function Menu()            _Menu = _Menu or require("ui/widget/menu"); return _Menu end
local function InputDialog()     _InputDialog = _InputDialog or require("ui/widget/inputdialog"); return _InputDialog end
local function MultiInputDialog() _MultiInputDialog = _MultiInputDialog or require("ui/widget/multiinputdialog"); return _MultiInputDialog end
local function InfoMessage()     _InfoMessage = _InfoMessage or require("ui/widget/infomessage"); return _InfoMessage end
local function ConfirmBox()      _ConfirmBox = _ConfirmBox or require("ui/widget/confirmbox"); return _ConfirmBox end
local function TextBoxWidget()   _TextBoxWidget = _TextBoxWidget or require("ui/widget/textboxwidget"); return _TextBoxWidget end
local function VerticalGroup()   _VerticalGroup = _VerticalGroup or require("ui/widget/verticalgroup"); return _VerticalGroup end
local function VerticalSpan()    _VerticalSpan = _VerticalSpan or require("ui/widget/verticalspan"); return _VerticalSpan end
local function FrameContainer()  _FrameContainer = _FrameContainer or require("ui/widget/container/framecontainer"); return _FrameContainer end
local function CenterContainer() _CenterContainer = _CenterContainer or require("ui/widget/container/centercontainer"); return _CenterContainer end
local function TextWidget()      _TextWidget = _TextWidget or require("ui/widget/textwidget"); return _TextWidget end
local function Button()          _Button = _Button or require("ui/widget/button"); return _Button end
local function Geom()            _Geom = _Geom or require("ui/geometry"); return _Geom end
local function Blitbuffer()      _Blitbuffer = _Blitbuffer or require("ffi/blitbuffer"); return _Blitbuffer end
local function InputContainer()  _InputContainer = _InputContainer or require("ui/widget/container/inputcontainer"); return _InputContainer end
local function GestureRange()    _GestureRange = _GestureRange or require("ui/gesturerange"); return _GestureRange end
local function HorizontalGroup() _HorizontalGroup = _HorizontalGroup or require("ui/widget/horizontalgroup"); return _HorizontalGroup end

-- Layout constants
local PAD  = Screen:scaleBySize(14)
local PAD2 = Screen:scaleBySize(8)

local ZLUI = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Sanitize a string for use as a filename component.
-- Replaces characters that are invalid or problematic in filenames.
-- @param s string
-- @return string
local function _sanitizeFilename(s)
    if not s or s == "" then return "unknown" end
    -- Remove/replace characters not safe in filenames
    s = s:gsub("[/\\:*?\"<>|]", "_")
    -- Collapse consecutive spaces
    s = s:gsub("%s+", " ")
    -- Trim
    s = s:match("^%s*(.-)%s*$") or s
    return s ~= "" and s or "unknown"
end

--- Build the destination path for a downloaded book.
-- @param book_info table: must have author, title, and format or a download URL
-- @return string: absolute file path
local function _buildDestPath(book_info)
    local dir = ZLConfig.ensureDownloadDir()
    if not dir then
        dir = ZLConfig.getDownloadDir()
    end
    local author  = _sanitizeFilename(book_info.author or _("Unknown"))
    local title   = _sanitizeFilename(book_info.title or _("Unknown"))
    -- Determine file extension from format name or download URL
    local ext = ""
    if book_info.format and book_info.format ~= "" then
        ext = book_info.format:lower()
        -- Remove any leading dot
        ext = ext:gsub("^%.", "")
    elseif book_info.download_url then
        ext = book_info.download_url:match("%.([%w]+)$") or ""
    end
    if ext == "" then ext = "epub" end
    return dir .. "/" .. author .. " - " .. title .. "." .. ext
end

--- Open a book file in KOReader's ReaderUI.
-- @param file_path string: absolute path to the book file
local function _openBook(file_path)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI then
        pcall(function() ReaderUI:showReader(file_path) end)
        return
    end
    -- Fallback: try opening via the document registry
    local ok2, DocSettings = pcall(require, "docsettings")
    if ok2 and DocSettings then
        local ok3, FileManager = pcall(require, "apps/filemanager/filemanager")
        if ok3 and FileManager and FileManager.instance then
            pcall(function() FileManager.instance:openFile(file_path) end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Search window
-- ---------------------------------------------------------------------------

--- Show the search window
-- @param plugin table: the plugin instance
function ZLUI.showSearchWindow(plugin)
    local input_dialog
    input_dialog = InputDialog():new{
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
                        ZLUI._doSearch(plugin, query, 1)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Execute a search and display results.
-- @param plugin table
-- @param query string
-- @param page number
function ZLUI._doSearch(plugin, query, page)
    local domain = ZLConfig.getActiveDomain()
    local loading_msg = InfoMessage():new{
        text = _("Searching…"),
        timeout = 0,
    }
    UIManager:show(loading_msg)

    UIManager:scheduleIn(0.1, function()
        local result, err = ZLClient.search(domain, query, page)

        UIManager:scheduleIn(0.1, function()
            -- Close the loading message
            pcall(function() UIManager:close(loading_msg) end)

            if not result then
                UIManager:show(InfoMessage():new{
                    text = _("Search failed: ") .. tostring(err),
                    timeout = 5,
                })
                return
            end

            if not result.books or #result.books == 0 then
                UIManager:show(InfoMessage():new{
                    text = _("No results found."),
                    timeout = 3,
                })
                return
            end

            ZLUI._showSearchResults(plugin, query, result, page)
        end)
    end)
end

--- Display search results in a Menu.
-- @param plugin table
-- @param query string: original search query (for pagination)
-- @param result table: from ZLClient.search
-- @param page number: current page number
function ZLUI._showSearchResults(plugin, query, result, page)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = PAD

    -- Build menu items from search results
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

    -- Title with page info
    local title_text = _("Search Results")
    if result.total_pages and result.total_pages > 1 then
        title_text = title_text .. string.format(" (%d/%d)", page, result.total_pages)
    end

    local menu
    menu = Menu():new{
        title = title_text,
        item_table = item_table,
        width = screen_w - padding * 2,
        height = screen_h - padding * 2,
        is_popout = false,
        onMenuSelect = function(self_menu, item)
            if item and item.book then
                ZLUI.showBookDetail(plugin, item.book)
            end
        end,
    }

    -- Add pagination buttons as a footer
    local has_prev = page > 1
    local has_next = result.total_pages and page < result.total_pages

    if has_prev or has_next then
        local prev_btn, next_btn
        local btn_row = HorizontalGroup():new{ align = "center" }

        if has_prev then
            prev_btn = Button():new{
                text = _("Previous"),
                width = math.floor((screen_w - padding * 4) / 2),
                callback = function()
                    UIManager:close(menu)
                    ZLUI._doSearch(plugin, query, page - 1)
                end,
            }
            btn_row[#btn_row + 1] = prev_btn
        end

        if has_next then
            next_btn = Button():new{
                text = _("Next"),
                width = math.floor((screen_w - padding * 4) / 2),
                callback = function()
                    UIManager:close(menu)
                    ZLUI._doSearch(plugin, query, page + 1)
                end,
            }
            if has_prev then
                -- Add spacing between buttons
                local HorizontalSpan = require("ui/widget/horizontalspan")
                btn_row[#btn_row + 1] = HorizontalSpan:new{ width = padding }
            end
            btn_row[#btn_row + 1] = next_btn
        end
    end

    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Book detail window
-- ---------------------------------------------------------------------------

--- Show book detail window
-- @param plugin table: the plugin instance
-- @param book_info table: book information with at least title, author, url
function ZLUI.showBookDetail(plugin, book_info)
    local domain = ZLConfig.getActiveDomain()

    -- Check login status first
    if not ZLClient.isLoggedIn(domain) then
        ZLUI.showLoginWindow(plugin, function()
            -- After successful login, retry showing the detail
            ZLUI.showBookDetail(plugin, book_info)
        end)
        return
    end

    -- Show loading while fetching detail
    local loading_msg = InfoMessage():new{
        text = _("Loading book details…"),
        timeout = 0,
    }
    UIManager:show(loading_msg)

    UIManager:scheduleIn(0.1, function()
        local info, err = ZLClient.getBookInfo(domain, book_info.url)

        UIManager:scheduleIn(0.1, function()
            pcall(function() UIManager:close(loading_msg) end)

            if not info then
                UIManager:show(InfoMessage():new{
                    text = _("Failed to load book details: ") .. tostring(err),
                    timeout = 5,
                })
                return
            end

            -- Merge original book_info fields into the detail response
            -- (the detail page may not include format/size from the search result)
            for k, v in pairs(book_info) do
                if info[k] == nil or info[k] == "" then
                    info[k] = v
                end
            end

            ZLUI._showBookDetailMenu(plugin, info)
        end)
    end)
end

--- Display the book detail menu.
-- @param plugin table
-- @param info table: book detail from ZLClient.getBookInfo
function ZLUI._showBookDetailMenu(plugin, info)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = PAD

    local item_table = {}

    -- Title
    item_table[#item_table + 1] = {
        text = info.title or _("Unknown Title"),
        font_bold = true,
    }

    -- Author
    item_table[#item_table + 1] = {
        text = _("Author: ") .. (info.author or _("Unknown")),
    }

    -- Format & size (from the search result if not in detail)
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
        item_table[#item_table + 1] = {
            text = fmt_text,
        }
    end

    -- Year
    if info.year and info.year ~= "" then
        item_table[#item_table + 1] = {
            text = _("Year: ") .. info.year,
        }
    end

    -- Publisher
    if info.publisher and info.publisher ~= "" then
        item_table[#item_table + 1] = {
            text = _("Publisher: ") .. info.publisher,
        }
    end

    -- Language
    if info.language and info.language ~= "" then
        item_table[#item_table + 1] = {
            text = _("Language: ") .. info.language,
        }
    end

    -- Separator
    item_table[#item_table + 1] = {
        text = "───",
        enabled = false,
    }

    -- Description (truncated for menu display; full view via separate option)
    if info.description and info.description ~= "" then
        -- Truncate description for menu item
        local desc_short = info.description
        if #desc_short > 120 then
            desc_short = desc_short:sub(1, 117) .. "..."
        end
        item_table[#item_table + 1] = {
            text = _("Description"),
            callback = function()
                ZLUI._showDescription(info.description)
            end,
        }
    end

    -- Download formats
    if info.formats and #info.formats > 0 then
        item_table[#item_table + 1] = {
            text = "───",
            enabled = false,
        }

        for _, fmt_entry in ipairs(info.formats) do
            local fmt_name = fmt_entry.name or _("Download")
            local fmt_url = fmt_entry.url
            item_table[#item_table + 1] = {
                text = _("Download: ") .. fmt_name,
                callback = function()
                    -- Build a book_info table with the download URL
                    local download_info = {}
                    for k, v in pairs(info) do download_info[k] = v end
                    download_info.download_url = fmt_url
                    download_info.format = fmt_name
                    ZLUI.showDownloadProgress(plugin, download_info)
                end,
            }
        end
    else
        -- No parsed formats — offer a generic download using the book URL
        item_table[#item_table + 1] = {
            text = "───",
            enabled = false,
        }
        item_table[#item_table + 1] = {
            text = _("Download"),
            callback = function()
                ZLUI.showDownloadProgress(plugin, info)
            end,
        }
    end

    local menu
    menu = Menu():new{
        title = info.title or _("Book Detail"),
        item_table = item_table,
        width = screen_w - padding * 2,
        height = screen_h - padding * 2,
        is_popout = false,
        onMenuSelect = function(self_menu, item)
            if item.callback then
                -- Close the detail menu before performing the action
                -- (download or description view)
                local cb = item.callback
                -- Don't close for description viewing — keep it open behind
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

--- Show the full book description in a scrollable TextBoxWidget.
-- @param description string
function ZLUI._showDescription(description)
    if not description or description == "" then return end

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = PAD
    local text_w = screen_w - padding * 4

    local TextBoxWidget = TextBoxWidget()
    local Font = require("ui/font")

    local desc_widget
    desc_widget = InputContainer():new{
        modal = true,
    }

    local text_box = TextBoxWidget:new{
        text = description,
        face = Font:getFace("cfont", 18),
        width = text_w,
        height = screen_h - padding * 6,
        alignment = "left",
        line_height = 0.3,
    }

    local close_btn = Button():new{
        text = _("Close"),
        callback = function()
            UIManager:close(desc_widget)
        end,
    }

    local vg = VerticalGroup():new{
        align = "left",
        VerticalSpan():new{ width = padding },
        CenterContainer():new{
            dimen = Geom():new{ w = screen_w, h = Screen:scaleBySize(24) },
            TextWidget():new{
                text = _("Description"),
                face = Font:getFace("cfont", 22),
                bold = true,
            },
        },
        VerticalSpan():new{ width = padding },
        text_box,
        VerticalSpan():new{ width = padding },
        CenterContainer():new{
            dimen = Geom():new{ w = screen_w, h = Screen:scaleBySize(40) },
            close_btn,
        },
    }

    desc_widget[1] = FrameContainer():new{
        bordersize = 1,
        padding = padding,
        background = Blitbuffer().COLOR_WHITE,
        CenterContainer():new{
            dimen = Geom():new{ w = screen_w - padding * 2, h = screen_h - padding * 2 },
            vg,
        },
    }

    desc_widget.dimen = desc_widget[1]:getSize()
    desc_widget.covers_fullscreen = true

    -- Handle back key / tap outside to close
    desc_widget.ges_events = {
        TapClose = {
            GestureRange():new{
                ges = "tap",
                range = Geom():new{
                    x = 0, y = 0,
                    w = screen_w,
                    h = screen_h,
                },
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

--- Show the login window
-- @param plugin table: the plugin instance
-- @param callback function|nil: called after successful login
function ZLUI.showLoginWindow(plugin, callback)
    local domain = ZLConfig.getActiveDomain()
    local saved_user = ZLConfig.getUserReminder(domain) or ""

    local domain_items = {}
    local domains = ZLConfig.getDomains()
    for _, d in ipairs(domains) do
        domain_items[#domain_items + 1] = {
            text = d.name .. " (" .. d.url .. ")",
            checked_func = function()
                return ZLConfig.getActiveDomain() == d.url
            end,
            keep_menu_open = true,
            callback = function()
                ZLConfig.setActiveDomain(d.url)
                -- Close and reopen the login dialog with the new domain
                -- (the domain_items list will reflect the change on next open)
            end,
        }
    end

    local dialog
    dialog = MultiInputDialog():new{
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
                        -- Close login dialog, show domain picker
                        UIManager:close(dialog)
                        ZLUI._showDomainPicker(function()
                            -- Reopen login dialog with new domain
                            ZLUI.showLoginWindow(plugin, callback)
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
                            UIManager:show(InfoMessage():new{
                                text = _("Please enter both email and password."),
                                timeout = 3,
                            })
                            return
                        end

                        UIManager:close(dialog)
                        ZLUI._doLogin(plugin, username, password, callback)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Execute login asynchronously.
-- @param plugin table
-- @param username string
-- @param password string
-- @param callback function|nil
function ZLUI._doLogin(plugin, username, password, callback)
    local domain = ZLConfig.getActiveDomain()
    local loading_msg = InfoMessage():new{
        text = _("Logging in…"),
        timeout = 0,
    }
    UIManager:show(loading_msg)

    UIManager:scheduleIn(0.1, function()
        local ok, err = ZLClient.login(domain, username, password)

        UIManager:scheduleIn(0.1, function()
            pcall(function() UIManager:close(loading_msg) end)

            if ok then
                UIManager:show(InfoMessage():new{
                    text = _("Login successful!"),
                    timeout = 2,
                })
                if callback then
                    callback()
                end
            else
                UIManager:show(InfoMessage():new{
                    text = _("Login failed: ") .. tostring(err),
                    timeout = 5,
                })
            end
        end)
    end)
end

--- Show a domain picker menu.
-- @param callback function|nil: called after selection
function ZLUI._showDomainPicker(callback)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local item_table = {}
    local domains = ZLConfig.getDomains()

    for _, d in ipairs(domains) do
        local is_active = ZLConfig.getActiveDomain() == d.url
        item_table[#item_table + 1] = {
            text = d.name .. (is_active and "  ✓" or ""),
            callback = function()
                if not is_active then
                    ZLConfig.setActiveDomain(d.url)
                end
                if callback then callback() end
            end,
        }
    end

    local menu
    menu = Menu():new{
        title = _("Select Domain"),
        item_table = item_table,
        width = screen_w - PAD * 2,
        height = screen_h - PAD * 2,
        is_popout = false,
        onMenuSelect = function(self_menu, item)
            if item.callback then
                UIManager:close(menu)
                item.callback()
            end
        end,
    }

    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Settings menu
-- ---------------------------------------------------------------------------

--- Show the settings menu
-- @param plugin table: the plugin instance
function ZLUI.showSettingsMenu(plugin)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local domain = ZLConfig.getActiveDomain()
    local is_logged_in = ZLClient.isLoggedIn(domain)
    local user_hint = ZLConfig.getUserReminder(domain)

    local item_table = {}

    -- Domain selection
    item_table[#item_table + 1] = {
        text = _("Domain: ") .. ZLConfig.getActiveDomainName(),
        callback = function()
            ZLUI._showDomainPicker()
        end,
    }

    -- Login status
    if is_logged_in then
        local user_text = user_hint and user_hint ~= "" and user_hint or _("logged in")
        item_table[#item_table + 1] = {
            text = _("Logged in as: ") .. user_text,
            callback = function()
                ZLUI._showLogoutConfirm(plugin)
            end,
        }
    else
        item_table[#item_table + 1] = {
            text = _("Not logged in"),
            callback = function()
                ZLUI.showLoginWindow(plugin)
            end,
        }
    end

    -- Download directory
    item_table[#item_table + 1] = {
        text = _("Download directory: ") .. ZLConfig.getDownloadDir(),
        callback = function()
            ZLUI._showDownloadDirPicker()
        end,
    }

    -- Clear recent downloads
    item_table[#item_table + 1] = {
        text = _("Clear recent downloads"),
        callback = function()
            UIManager:show(ConfirmBox():new{
                text = _("Clear the recent downloads list?"),
                ok_text = _("Clear"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    ZLConfig.clearRecent()
                    UIManager:show(InfoMessage():new{
                        text = _("Recent downloads cleared."),
                        timeout = 2,
                    })
                end,
            })
        end,
    }

    -- Clear cache (cookies)
    item_table[#item_table + 1] = {
        text = _("Clear login cookies"),
        callback = function()
            UIManager:show(ConfirmBox():new{
                text = _("Clear all stored login cookies? You will need to log in again."),
                ok_text = _("Clear"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    ZLConfig.clearAllCookies()
                    UIManager:show(InfoMessage():new{
                        text = _("Cookies cleared."),
                        timeout = 2,
                    })
                end,
            })
        end,
    }

    -- About
    item_table[#item_table + 1] = {
        text = "───",
        enabled = false,
    }
    item_table[#item_table + 1] = {
        text = _("About Z-Library"),
        callback = function()
            UIManager:show(InfoMessage():new{
                text = _("Z-Library search integration for KOReader.\nSearch and download books from Z-Library mirror sites."),
                timeout = 5,
            })
        end,
    }

    local menu
    menu = Menu():new{
        title = _("Z-Library Settings"),
        item_table = item_table,
        width = screen_w - PAD * 2,
        height = screen_h - PAD * 2,
        is_popout = false,
        onMenuSelect = function(self_menu, item)
            if item.callback then
                UIManager:close(menu)
                item.callback()
            end
        end,
    }

    UIManager:show(menu)
end

--- Show a logout confirmation.
-- @param plugin table
function ZLUI._showLogoutConfirm(plugin)
    UIManager:show(ConfirmBox():new{
        text = _("Log out of Z-Library?"),
        ok_text = _("Log Out"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            ZLConfig.clearCookies(ZLConfig.getActiveDomain())
            UIManager:show(InfoMessage():new{
                text = _("Logged out."),
                timeout = 2,
            })
        end,
    })
end

--- Show a download directory picker.
function ZLUI._showDownloadDirPicker()
    local ok, Dialog = pcall(require, "ui/widget/directorychooser")
    if not ok or not Dialog then
        -- Fallback: use InputDialog
        local input
        input = InputDialog():new{
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

    -- Use DirectoryChooser if available
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

--- Show a download progress indicator and start downloading.
-- @param plugin table: the plugin instance
-- @param book_info table: must have download_url, title, author, format
function ZLUI.showDownloadProgress(plugin, book_info)
    local domain = ZLConfig.getActiveDomain()

    -- Ensure we have a download URL
    local download_url = book_info.download_url
    if not download_url or download_url == "" then
        -- Try to construct from the book URL (may be a /dl/ path)
        if book_info.url then
            download_url = book_info.url
        end
    end

    if not download_url or download_url == "" then
        UIManager:show(InfoMessage():new{
            text = _("No download URL available for this book."),
            timeout = 3,
        })
        return
    end

    -- Build destination path
    local dest_path = _buildDestPath(book_info)

    -- Check if file already exists
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs and lfs.attributes(dest_path, "mode") == "file" then
        UIManager:show(ConfirmBox():new{
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

--- Start the actual download asynchronously.
-- @param domain string
-- @param download_url string
-- @param dest_path string
-- @param book_info table
function ZLUI._startDownload(domain, download_url, dest_path, book_info)
    local loading_msg = InfoMessage():new{
        text = _("Downloading…") .. "\n" .. (book_info.title or ""),
        timeout = 0,
    }
    UIManager:show(loading_msg)

    UIManager:scheduleIn(0.1, function()
        local ok, err = ZLClient.downloadBook(domain, download_url, dest_path)

        UIManager:scheduleIn(0.1, function()
            pcall(function() UIManager:close(loading_msg) end)

            if ok then
                -- Add to recent downloads
                ZLConfig.addRecent({
                    title  = book_info.title or _("Unknown"),
                    author = book_info.author or _("Unknown"),
                    format = book_info.format or "",
                    path   = dest_path,
                })

                -- Ask if the user wants to open the book
                UIManager:show(ConfirmBox():new{
                    text = _("Download complete!") .. "\n" .. dest_path .. "\n" .. _("Read now?"),
                    ok_text = _("Read"),
                    cancel_text = _("Later"),
                    ok_callback = function()
                        _openBook(dest_path)
                    end,
                })
            else
                UIManager:show(InfoMessage():new{
                    text = _("Download failed: ") .. tostring(err),
                    timeout = 5,
                })
                -- Clean up partial file
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
