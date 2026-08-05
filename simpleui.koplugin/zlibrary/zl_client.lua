-- zl_client.lua — Z-Library HTTP client
-- Handles all network communication with Z-Library mirror sites,
-- including login, search, book info retrieval, and file download.

local logger  = require("logger")
local _       = require("sui_i18n").translate
local ZLConfig = require("zlibrary/zl_config")

local ZLClient = {}

-- ---------------------------------------------------------------------------
-- Internal HTTP helpers
-- ---------------------------------------------------------------------------

--- HTTP GET request
-- @param url string: target URL
-- @param headers table|nil: optional extra headers
-- @return body string or nil, response headers or error string, HTTP status
function ZLClient.httpGet(url, headers)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    if ok_su then
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local req_headers = {
        ["User-Agent"] = "KOReader-SimpleUI-ZLib/1.0",
        ["Accept"]     = "*/*",
    }
    if headers then
        for k, v in pairs(headers) do
            req_headers[k] = v
        end
    end

    local chunks = {}
    local code, resp_headers, status = socket.skip(1, http.request({
        url     = url,
        method  = "GET",
        headers = req_headers,
        sink    = ltn12.sink.table(chunks),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if resp_headers == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then
        return table.concat(chunks), resp_headers, code
    end
    return nil, string.format("HTTP %s", tostring(code)), code, resp_headers
end

--- HTTP POST request
-- @param url string: target URL
-- @param body string: request body (URL-encoded form data)
-- @param headers table|nil: optional extra headers
-- @return body string or nil, response headers or error string, HTTP status
function ZLClient.httpPost(url, body, headers)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    if ok_su then
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local req_headers = {
        ["User-Agent"]     = "KOReader-SimpleUI-ZLib/1.0",
        ["Content-Type"]   = "application/x-www-form-urlencoded",
        ["Content-Length"] = tostring(#body),
    }
    if headers then
        for k, v in pairs(headers) do
            req_headers[k] = v
        end
    end

    local chunks = {}
    local code, resp_headers, status = socket.skip(1, http.request({
        url     = url,
        method  = "POST",
        headers = req_headers,
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(chunks),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if resp_headers == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then
        return table.concat(chunks), resp_headers, code
    end
    return nil, string.format("HTTP %s", tostring(code)), code, resp_headers
end

--- HTTP download to file
-- @param url string: target URL
-- @param dest_path string: local file path to write to
-- @param headers table|nil: optional extra headers
-- @return true or nil, error string
function ZLClient.httpDownload(url, dest_path, headers)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    local fh, err_open = io.open(dest_path, "wb")
    if not fh then return nil, "cannot create file: " .. tostring(err_open) end

    if ok_su then
        socketutil:set_timeout(
            socketutil.FILE_BLOCK_TIMEOUT,
            socketutil.FILE_TOTAL_TIMEOUT
        )
    end

    local req_headers = {
        ["User-Agent"] = "KOReader-SimpleUI-ZLib/1.0",
    }
    if headers then
        for k, v in pairs(headers) do
            req_headers[k] = v
        end
    end

    local code, resp_headers, status = socket.skip(1, http.request({
        url      = url,
        method   = "GET",
        headers  = req_headers,
        sink     = ltn12.sink.file(fh),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end
    -- ltn12.sink.file closes fh automatically

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        pcall(os.remove, dest_path)
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if resp_headers == nil then
        pcall(os.remove, dest_path)
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then return true end
    pcall(os.remove, dest_path)
    return nil, string.format("HTTP %s", tostring(code))
end

-- ---------------------------------------------------------------------------
-- Cookie helpers
-- ---------------------------------------------------------------------------

--- Build a Cookie header string for the given domain
local function _getCookieHeader(domain_url)
    local cookie_str = ZLConfig.getCookies(domain_url)
    if cookie_str and cookie_str ~= "" then
        return cookie_str
    end
    return nil
end

--- Extract cookies from response headers and persist them
local function _saveCookiesFromResponse(domain_url, resp_headers)
    if not resp_headers then return end
    -- socket/http returns set-cookie as either a single string or a
    -- table of strings depending on the number of values.
    local set_cookie = resp_headers["set-cookie"]
    if not set_cookie then return end

    local cookies = {}
    if type(set_cookie) == "string" then
        cookies = { set_cookie }
    elseif type(set_cookie) == "table" then
        cookies = set_cookie
    end

    -- Extract only the name=value part (before the first semicolon)
    local parts = {}
    for _, c in ipairs(cookies) do
        local nv = c:match("^([^;]+)")
        if nv then
            parts[#parts + 1] = nv
        end
    end

    if #parts > 0 then
        local existing = ZLConfig.getCookies(domain_url) or ""
        if existing ~= "" then
            ZLConfig.setCookies(domain_url, existing .. "; " .. table.concat(parts, "; "))
        else
            ZLConfig.setCookies(domain_url, table.concat(parts, "; "))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Z-Library API operations
-- ---------------------------------------------------------------------------

--- Login using the HTML form used by newer Z-Library domains.
-- @param domain string: domain URL
-- @param username string: email address
-- @param password string: password
-- @return true or nil, error string
function ZLClient.loginNewDomain(domain, username, password)
    local ok, result, err = pcall(function()
        local login_url = domain .. "/login"
        local extra_headers = {}
        local cookie_header = _getCookieHeader(domain)
        if cookie_header then
            extra_headers["Cookie"] = cookie_header
        end

        local login_page, get_headers_or_err = ZLClient.httpGet(login_url, extra_headers)
        if not login_page then
            return nil, get_headers_or_err
        end

        if type(get_headers_or_err) == "table" then
            _saveCookiesFromResponse(domain, get_headers_or_err)
        end

        -- Attribute order on the current form is type, name, value. Keep this a
        -- deliberately small pattern rather than pulling in an HTML parser.
        local token = login_page:match(
            '<input[^>]-type=["\']hidden["\'][^>]-name=["\']_token["\'][^>]-value=["\']([^"\']+)["\']'
        )
        if not token then
            return nil, _("Login failed: CSRF token not found")
        end

        cookie_header = _getCookieHeader(domain)
        extra_headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        }
        if cookie_header then
            extra_headers["Cookie"] = cookie_header
        end

        local url = require("socket.url")
        local body = "_token=" .. url.escape(token)
            .. "&email=" .. url.escape(username)
            .. "&password=" .. url.escape(password)
        local resp_body, post_headers_or_err, status_code, error_headers =
            ZLClient.httpPost(login_url, body, extra_headers)
        local response_headers = type(post_headers_or_err) == "table"
            and post_headers_or_err or error_headers
        if type(response_headers) == "table" then
            _saveCookiesFromResponse(domain, response_headers)
        end

        -- This also supports HTTP helpers configured not to follow redirects.
        if status_code and status_code >= 300 and status_code < 400 then
            ZLConfig.setUserReminder(domain, username)
            logger.info("zl_client: new-domain login redirected for", username)
            return true
        end
        if not resp_body then
            return nil, post_headers_or_err
        end

        -- httpPost follows redirects. A successful login therefore normally
        -- arrives here as the final 200 page; a returned login form means the
        -- credentials were rejected and the user was not logged in.
        local still_on_login = resp_body:match('<input[^>]-name=["\']password["\']')
            or resp_body:match('<form[^>]-action=["\'][^"\']*/login["\']')
        if still_on_login then
            return nil, _("Login failed")
        end

        ZLConfig.setUserReminder(domain, username)
        logger.info("zl_client: new-domain login successful for", username)
        return true
    end)

    if not ok then
        logger.err("zl_client: new-domain login error:", result)
        return nil, _("Login failed") .. ": " .. tostring(result)
    end
    return result, err
end

--- Login to Z-Library
-- @param domain string: domain URL (e.g. "https://z-lib.org")
-- @param username string: email address
-- @param password string: password
-- @return true or nil, error string
function ZLClient.login(domain, username, password)
    local login_url = domain .. "/rpc.php"
    local body = "isModal=true&email=" .. require("socket.url").escape(username)
        .. "&password=" .. require("socket.url").escape(password)

    local cookie_header = _getCookieHeader(domain)
    local extra_headers = {}
    if cookie_header then
        extra_headers["Cookie"] = cookie_header
    end

    local resp_body, resp_headers_or_err, status_code = ZLClient.httpPost(login_url, body, extra_headers)

    if not resp_body then
        if status_code == 404 or resp_headers_or_err == "HTTP 404" then
            return ZLClient.loginNewDomain(domain, username, password)
        end
        return nil, resp_headers_or_err
    end

    -- Save any cookies from the response
    if type(resp_headers_or_err) == "table" then
        _saveCookiesFromResponse(domain, resp_headers_or_err)
    end

    -- Parse the login response
    local ZLParser = require("zlibrary/zl_parser")
    local result, parse_err = ZLParser.parseLoginResponse(resp_body)
    if not result then
        return nil, parse_err or _("Login failed")
    end

    if result.success then
        ZLConfig.setUserReminder(domain, username)
        logger.info("zl_client: login successful for", username)
        return true
    end

    return nil, result.message or _("Login failed")
end

--- Search for books
-- @param domain string: domain URL
-- @param query string: search query
-- @param page number|nil: page number (default 1)
-- @return table of book results or nil, error string
function ZLClient.search(domain, query, page)
    page = page or 1
    local search_url = domain .. "/s/" .. require("socket.url").escape(query)
        .. "?page=" .. tostring(page)

    local extra_headers = {}
    local cookie_header = _getCookieHeader(domain)
    if cookie_header then
        extra_headers["Cookie"] = cookie_header
    end

    local body, err = ZLClient.httpGet(search_url, extra_headers)
    if not body then
        return nil, err
    end

    local ZLParser = require("zlibrary/zl_parser")
    local results = ZLParser.parseSearchResults(body)
    if not results then
        return nil, _("Failed to parse search results")
    end

    local total_pages = ZLParser.parseTotalPages(body) or 1

    return {
        books       = results,
        page        = page,
        total_pages = total_pages,
    }
end

--- Get detailed book information
-- @param domain string: domain URL
-- @param book_url string: relative or absolute book URL
-- @return table with book details or nil, error string
function ZLClient.getBookInfo(domain, book_url)
    -- Handle relative URLs
    local full_url = book_url
    if book_url:sub(1, 1) == "/" then
        full_url = domain .. book_url
    elseif not book_url:match("^https?://") then
        full_url = domain .. "/" .. book_url
    end

    local extra_headers = {}
    local cookie_header = _getCookieHeader(domain)
    if cookie_header then
        extra_headers["Cookie"] = cookie_header
    end

    local body, err = ZLClient.httpGet(full_url, extra_headers)
    if not body then
        return nil, err
    end

    local ZLParser = require("zlibrary/zl_parser")
    local info = ZLParser.parseBookDetail(body)
    if not info then
        return nil, _("Failed to parse book detail")
    end

    return info
end

--- Download a book file
-- @param domain string: domain URL
-- @param book_url string: download URL (format: /dl/{book_id}/{hash})
-- @param dest_path string: local file path to save the download
-- @return true or nil, error string
function ZLClient.downloadBook(domain, book_url, dest_path)
    -- Build the full download URL
    local full_url = book_url
    if book_url:sub(1, 1) == "/" then
        full_url = domain .. book_url
    elseif not book_url:match("^https?://") then
        full_url = domain .. "/" .. book_url
    end

    local extra_headers = {}
    local cookie_header = _getCookieHeader(domain)
    if cookie_header then
        extra_headers["Cookie"] = cookie_header
    end

    -- Ensure the destination directory exists
    local dest_dir = dest_path:match("^(.*)/[^/]+$")
    if dest_dir then
        local lfs = require("lfs")
        lfs.mkdir(dest_dir)
    end

    return ZLClient.httpDownload(full_url, dest_path, extra_headers)
end

--- Check if the user is logged in for a given domain
-- @param domain string: domain URL
-- @return boolean
function ZLClient.isLoggedIn(domain)
    local cookies = ZLConfig.getCookies(domain)
    return cookies ~= nil and cookies ~= ""
end

return ZLClient
