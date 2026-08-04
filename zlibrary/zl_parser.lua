-- zl_parser.lua — Z-Library HTML parser
-- Parses HTML responses from Z-Library mirror sites using Lua pattern matching.
-- No external HTML parsing library is required (KOReader does not provide one).

local _ = require("sui_i18n").translate

local ZLParser = {}

-- ---------------------------------------------------------------------------
-- Utility helpers
-- ---------------------------------------------------------------------------

--- Decode common HTML entities in a string
-- @param s string: input with HTML entities
-- @return string with entities replaced
local function _decodeEntities(s)
    if not s then return "" end
    s = s:gsub("&amp;",  "&")
    s = s:gsub("&lt;",   "<")
    s = s:gsub("&gt;",   ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#(%d+);", function(n) return string.char(tonumber(n) or 63) end)
    s = s:gsub("&#x(%x+);", function(n) return string.char(tonumber(n, 16) or 63) end)
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&#39;", "'")
    s = s:gsub("&apos;", "'")
    return s
end

--- Trim whitespace from both ends of a string
-- @param s string
-- @return string
local function _trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

--- Extract text content from a simple HTML tag
-- Strips all inner tags and returns the text content
-- @param html string: HTML fragment
-- @return string: plain text
local function _stripTags(html)
    if not html then return "" end
    -- Replace <br> and <br/> with newline
    html = html:gsub("<br%s*/?>", "\n")
    -- Remove all other tags
    html = html:gsub("<[^>]+>", "")
    -- Decode entities
    html = _decodeEntities(html)
    -- Collapse whitespace but preserve newlines
    html = html:gsub("[^\n%S]+", " ")
    return _trim(html)
end

-- ---------------------------------------------------------------------------
-- Search results parsing
-- ---------------------------------------------------------------------------

--- Parse search results HTML page
-- @param html string: full HTML response
-- @return table of book entries: { {title, author, format, size, url, cover_url}, ... }
--         or nil if no results found
function ZLParser.parseSearchResults(html)
    if not html or html == "" then return nil end

    local results = {}

    -- Match each bookRow block
    for book_block in html:gmatch('<div class="bookRow">(.-)</div>%s*</div>%s*</div>') do
        local book = {}

        -- Extract title and book URL from the heading link
        -- Pattern: <h3><a href="/book/...">Title</a></h3>
        local href, title = book_block:match('<h3><a href="([^"]+)">(.-)</a></h3>')
        if not href then
            -- Try alternative pattern with additional attributes
            href, title = book_block:match('<h3[^>]*>%s*<a href="([^"]+)">(.-)</a>')
        end
        if title then
            book.title = _decodeEntities(_trim(title))
        end
        if href then
            book.url = href
        end

        -- Extract cover image URL
        -- Pattern: <img src="..." />
        local cover = book_block:match('<img%s+src="([^"]+)"')
        if cover then
            book.cover_url = cover
        end

        -- Extract author
        -- Pattern: <div class="authors"><a href="...">Author</a></div>
        local author = book_block:match('class="authors"><a[^>]*>(.-)</a>')
        if author then
            book.author = _decodeEntities(_trim(author))
        else
            book.author = _("Unknown")
        end

        -- Extract format and size from bookDetails
        -- Pattern: <div class="bookDetails"><span>EPUB</span><span>2.3 MB</span>
        local details_block = book_block:match('class="bookDetails">(.-)</div>')
        if details_block then
            local spans = {}
            for span_text in details_block:gmatch("<span>(.-)</span>") do
                spans[#spans + 1] = _trim(span_text)
            end
            -- First span is typically the format
            book.format = spans[1] or ""
            -- Second span is typically the file size
            book.size = spans[2] or ""
        else
            book.format = ""
            book.size = ""
        end

        -- Only add if we have at least a title and URL
        if book.title and book.title ~= "" and book.url then
            results[#results + 1] = book
        end
    end

    -- Alternative parsing: try a more lenient pattern if the strict one found nothing
    if #results == 0 then
        -- Try matching book rows with a looser pattern
        -- Some mirror sites use different class names or structures
        for href, title in html:gmatch('<a[^>]+href="(/book/%d+/[^"]+)"[^>]*>([^<]+)</a>') do
            -- Skip navigation links
            if not title:match("^%s*$") then
                results[#results + 1] = {
                    title  = _decodeEntities(_trim(title)),
                    url    = href,
                    author = _("Unknown"),
                    format = "",
                    size   = "",
                    cover_url = "",
                }
            end
        end
    end

    if #results == 0 then return nil end
    return results
end

-- ---------------------------------------------------------------------------
-- Book detail parsing
-- ---------------------------------------------------------------------------

--- Parse book detail HTML page
-- @param html string: full HTML response from a book page
-- @return table with book details: { title, author, description, formats,
--         cover_url, year, publisher, language } or nil
function ZLParser.parseBookDetail(html)
    if not html or html == "" then return nil end

    local info = {}

    -- Extract title
    -- Pattern: <h1> or <h2> with class containing "title" or "bookTitle"
    info.title = html:match('<h1[^>]*>(.-)</h1>')
        or html:match('<h2[^>]*>(.-)</h2>')
        or ""
    info.title = _stripTags(info.title)
    if info.title == "" then
        info.title = html:match('<title>(.-)</title>') or _("Unknown")
        info.title = _stripTags(info.title)
    end

    -- Extract author
    -- Pattern: class="authors" or similar
    info.author = html:match('class="authors"[^>]*>(.-)</div>')
        or html:match('class="author"[^>]*>(.-)</div>')
        or _("Unknown")
    info.author = _stripTags(info.author)

    -- Extract description
    -- Pattern: class="description" or "bookDescription"
    local desc_block = html:match('class="description"[^>]*>(.-)</div>')
        or html:match('class="bookDescription"[^>]*>(.-)</div>')
        or ""
    info.description = _stripTags(desc_block)

    -- Extract cover image
    info.cover_url = html:match('class="bookCover"%s+src="([^"]+)"')
        or html:match('itemprop="image"%s+src="([^"]+)"')
        or html:match('class="z-book%-cover"%s+src="([^"]+)"')
        or ""

    -- Extract available download formats
    -- Pattern: links with /dl/ or download buttons
    info.formats = {}
    for fmt_url, fmt_name in html:gmatch('href="(/dl/%d+/%w+)"[^>]*>([^<]+)') do
        info.formats[#info.formats + 1] = {
            name = _trim(fmt_name),
            url  = fmt_url,
        }
    end

    -- If no /dl/ links found, try matching download buttons
    if #info.formats == 0 then
        for dl_url in html:gmatch('href="([^"]*/dl/%d+/[^"]+)"') do
            local fmt = dl_url:match("/dl/%d+/(%w+)")
            info.formats[#info.formats + 1] = {
                name = fmt and fmt:upper() or "Download",
                url  = dl_url,
            }
        end
    end

    -- Extract metadata fields (year, publisher, language)
    -- These are typically in a details section with property attributes
    info.year = html:match('itemprop="datePublished"[^>]*>([^<]+)<')
        or html:match('class="propertyYear"[^>]*>([^<]+)<')
        or ""
    info.year = _trim(info.year)

    info.publisher = html:match('itemprop="publisher"[^>]*>([^<]+)<')
        or html:match('class="propertyPublisher"[^>]*>([^<]+)<')
        or ""
    info.publisher = _trim(info.publisher)

    info.language = html:match('itemprop="inLanguage"[^>]*>([^<]+)<')
        or html:match('class="propertyLanguage"[^>]*>([^<]+)<')
        or ""
    info.language = _trim(info.language)

    return info
end

-- ---------------------------------------------------------------------------
-- Pagination parsing
-- ---------------------------------------------------------------------------

--- Parse the total number of pages from search results
-- @param html string: full HTML response
-- @return number or nil
function ZLParser.parseTotalPages(html)
    if not html or html == "" then return nil end

    -- Pattern 1: pagination with "page=X" links
    local max_page = 0
    for p in html:gmatch('page=(%d+)') do
        local n = tonumber(p)
        if n and n > max_page then
            max_page = n
        end
    end
    if max_page > 0 then return max_page end

    -- Pattern 2: pagination with class="pagination" or similar
    local pag_block = html:match('class="pagination"(.-)</div>')
        or html:match('class="pager"(.-)</div>')
    if pag_block then
        for p in pag_block:gmatch(">(%d+)<") do
            local n = tonumber(p)
            if n and n > max_page then
                max_page = n
            end
        end
    end
    if max_page > 0 then return max_page end

    return nil
end

-- ---------------------------------------------------------------------------
-- Login response parsing
-- ---------------------------------------------------------------------------

--- Parse the login response (JSON or HTML)
-- @param html_or_json string: response body
-- @return table with { success=bool, message=string } or nil, error string
function ZLParser.parseLoginResponse(html_or_json)
    if not html_or_json or html_or_json == "" then
        return nil, _("Empty response")
    end

    -- Try JSON response first (Z-Library rpc.php typically returns JSON)
    local ok_j, json = pcall(require, "json")
    if ok_j and json then
        local ok_d, data = pcall(json.decode, html_or_json)
        if ok_d and type(data) == "table" then
            local success = data.success or data.response == 1
            local message = data.message or data.error or ""
            return {
                success = success == true or success == 1,
                message = message,
            }
        end
    end

    -- JSON fallback: try simple pattern matching on JSON string
    local success_val = html_or_json:match('"success"%s*:%s*(true)')
        or html_or_json:match('"response"%s*:%s*1')
    if success_val then
        local message = html_or_json:match('"message"%s*:%s*"([^"]*)"')
            or html_or_json:match('"error"%s*:%s*"([^"]*)"')
            or ""
        return {
            success = true,
            message = _decodeEntities(message),
        }
    end

    -- Check for failure indicators in JSON
    local fail_val = html_or_json:match('"success"%s*:%s*false')
        or html_or_json:match('"response"%s*:%s*0')
    if fail_val then
        local message = html_or_json:match('"message"%s*:%s*"([^"]*)"')
            or html_or_json:match('"error"%s*:%s*"([^"]*)"')
            or _("Login failed")
        return {
            success = false,
            message = _decodeEntities(message),
        }
    end

    -- HTML response: check for redirect or error indicators
    if html_or_json:match("login%-error") or html_or_json:match("invalid") then
        return {
            success = false,
            message = _("Invalid credentials"),
        }
    end

    -- If we cannot determine the result, assume failure
    return {
        success = false,
        message = _("Unknown response format"),
    }
end

return ZLParser
