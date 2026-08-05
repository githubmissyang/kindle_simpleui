-- zl_config.lua — Z-Library configuration management
-- Manages domain list, login credentials, download path, and recent downloads.

local _ = require("sui_i18n").translate
local SUISettings = require("sui_store")
local ok_ds, DataStorage = pcall(require, "datastorage")

-- Default domains (known Chinese mirror sites)
local DEFAULT_DOMAINS = {
    { name = "z-lib.org",      url = "https://z-lib.org" },
    { name = "singlelogin.re", url = "https://singlelogin.re" },
    { name = "z-library.sk",   url = "https://z-library.sk" },
}

local ZLConfig = {}

-- Settings keys
local KEY_DOMAINS       = "simpleui_zl_domains"
local KEY_ACTIVE_DOMAIN = "simpleui_zl_active_domain"
local KEY_COOKIES       = "simpleui_zl_cookies"
local KEY_DOWNLOAD_DIR  = "simpleui_zl_download_dir"
local KEY_RECENT        = "simpleui_zl_recent"
local KEY_USER_REMINDER = "simpleui_zl_user_reminder"

--- Get the list of configured domains
function ZLConfig.getDomains()
    local domains = SUISettings:readSetting(KEY_DOMAINS)
    if not domains or #domains == 0 then
        -- Return a copy of DEFAULT_DOMAINS, not the original
        local copy = {}
        for _, d in ipairs(DEFAULT_DOMAINS) do
            copy[#copy + 1] = { name = d.name, url = d.url }
        end
        return copy
    end
    return domains
end

--- Set the list of domains
function ZLConfig.setDomains(domains)
    SUISettings:saveSetting(KEY_DOMAINS, domains)
end

--- Get the active domain URL
function ZLConfig.getActiveDomain()
    local url = SUISettings:readSetting(KEY_ACTIVE_DOMAIN)
    if not url then
        local domains = ZLConfig.getDomains()
        return domains[1] and domains[1].url or "https://z-lib.org"
    end
    return url
end

--- Set the active domain URL
function ZLConfig.setActiveDomain(url)
    SUISettings:saveSetting(KEY_ACTIVE_DOMAIN, url)
end

--- Get the active domain name
function ZLConfig.getActiveDomainName()
    local url = ZLConfig.getActiveDomain()
    for _, d in ipairs(ZLConfig.getDomains()) do
        if d.url == url then return d.name end
    end
    return url
end

--- Get the download directory
function ZLConfig.getDownloadDir()
    local dir = SUISettings:readSetting(KEY_DOWNLOAD_DIR)
    if not dir then
        if ok_ds and DataStorage then
            dir = DataStorage:getDataDir() .. "/Z-Library"
        else
            dir = "/mnt/us/books/Z-Library"
        end
    end
    return dir
end

--- Set the download directory
function ZLConfig.setDownloadDir(dir)
    SUISettings:saveSetting(KEY_DOWNLOAD_DIR, dir)
end

--- Ensure download directory exists
function ZLConfig.ensureDownloadDir()
    local dir = ZLConfig.getDownloadDir()
    local lfs = require("lfs")
    local ok, err = lfs.mkdir(dir)
    if not ok and err and err ~= "File exists" then
        return nil, err
    end
    return dir
end

--- Get stored cookies for a domain
function ZLConfig.getCookies(domain_url)
    local cookies = SUISettings:readSetting(KEY_COOKIES) or {}
    return cookies[domain_url]
end

--- Set cookies for a domain
function ZLConfig.setCookies(domain_url, cookie_str)
    local cookies = SUISettings:readSetting(KEY_COOKIES) or {}
    cookies[domain_url] = cookie_str
    SUISettings:saveSetting(KEY_COOKIES, cookies)
end

--- Clear cookies for a domain (logout)
function ZLConfig.clearCookies(domain_url)
    local cookies = SUISettings:readSetting(KEY_COOKIES) or {}
    cookies[domain_url] = nil
    SUISettings:saveSetting(KEY_COOKIES, cookies)
end

--- Clear all cookies
function ZLConfig.clearAllCookies()
    SUISettings:saveSetting(KEY_COOKIES, {})
end

--- Get the list of recently downloaded books
function ZLConfig.getRecent()
    return SUISettings:readSetting(KEY_RECENT) or {}
end

--- Add a book to the recent downloads list
function ZLConfig.addRecent(book_info)
    local recent = ZLConfig.getRecent()
    -- Insert at the beginning
    table.insert(recent, 1, {
        title     = book_info.title or _("Unknown"),
        author    = book_info.author or _("Unknown"),
        format    = book_info.format or "",
        path      = book_info.path or "",
        time      = os.time(),
        cover_url = book_info.cover_url or "",
    })
    -- Keep only last 20 entries
    while #recent > 20 do
        table.remove(recent)
    end
    SUISettings:saveSetting(KEY_RECENT, recent)
end

--- Clear the recent downloads list
function ZLConfig.clearRecent()
    SUISettings:saveSetting(KEY_RECENT, {})
end

--- Save user reminder (email or username for display)
function ZLConfig.setUserReminder(domain_url, reminder)
    local reminders = SUISettings:readSetting(KEY_USER_REMINDER) or {}
    reminders[domain_url] = reminder
    SUISettings:saveSetting(KEY_USER_REMINDER, reminders)
end

--- Get user reminder for a domain
function ZLConfig.getUserReminder(domain_url)
    local reminders = SUISettings:readSetting(KEY_USER_REMINDER) or {}
    return reminders[domain_url] or ""
end

return ZLConfig
