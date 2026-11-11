--[[
    MokuroCatalog - Client for browsing and downloading from Mokuro Bunko Catalog
    Handles API communication, JSON decoding, file streaming, and sidecar management
]]--

local DataStorage = require("datastorage")
local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local ltn12 = require("ltn12")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local MokuroCatalog = {
    default_server_url = "https://mokuro.moe",
    cache_ttl = 86400, -- 24 hours
}

local redirect_codes = {
    [301] = true,
    [302] = true,
    [303] = true,
    [307] = true,
    [308] = true,
}

-- Sanitize filenames to prevent illegal characters on FAT32/Windows/Linux filesystems
local function sanitize_filename(name)
    if not name then return "unknown" end
    -- Replace illegal filename characters: / \ : * ? " < > |
    local clean = name:gsub('[/\\:*?"<>|]', "_")
    -- Strip trailing spaces or dots which are illegal on FAT/Windows
    clean = clean:gsub("[%.%s]+$", "")
    return clean
end

-- Recursively remove JSON nulls (which rapidjson decodes as userdata)
local function sanitize_nulls(t)
    if type(t) ~= "table" then return t end
    for k, v in pairs(t) do
        local tv = type(v)
        if tv == "userdata" then
            t[k] = nil
        elseif tv == "table" then
            sanitize_nulls(v)
        end
    end
    return t
end

-- Helper to safely parse JSON using rapidjson (fastest) or fallback to json
local function parse_json(str)
    if not str or str == "" then
        return nil, "empty input"
    end
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson and rapidjson.decode then
        local ok, data = pcall(rapidjson.decode, str)
        if ok and data then
            return sanitize_nulls(data)
        end
    end
    local ok_j, json = pcall(require, "json")
    if ok_j and json and json.decode then
        local ok, data = pcall(json.decode, str)
        if ok and data then
            return sanitize_nulls(data)
        end
    end
    return nil, "failed to parse JSON"
end

-- Helper to encode URL components safely
local function url_encode(str)
    if not str then return "" end
    return url.escape(str)
end

-- Format bytes into human-readable size
local function format_size(bytes)
    if not bytes or type(bytes) ~= "number" or bytes <= 0 then return "0 B" end
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1048576 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1073741824 then
        return string.format("%.1f MB", bytes / 1048576)
    else
        return string.format("%.2f GB", bytes / 1073741824)
    end
end

MokuroCatalog.format_size = format_size
MokuroCatalog.sanitize_filename = sanitize_filename

function MokuroCatalog:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function MokuroCatalog:getServerUrl()
    local saved = G_reader_settings:readSetting("mokuro_server_url")
    if saved and saved ~= "" then
        return saved:gsub("/+$", "")
    end
    return self.default_server_url
end

function MokuroCatalog:setServerUrl(server_url)
    if server_url and server_url ~= "" then
        local clean = server_url:gsub("/+$", "")
        G_reader_settings:saveSetting("mokuro_server_url", clean)
    else
        G_reader_settings:saveSetting("mokuro_server_url", nil)
    end
end

function MokuroCatalog:getDownloadDir()
    local saved = G_reader_settings:readSetting("mokuro_download_dir")
    if saved and saved ~= "" then
        return saved:gsub("/+$", "")
    end
    -- Standard user storage directories by platform
    if util.pathExists("/mnt/us") then
        return "/mnt/us/manga" -- Kindle user partition
    elseif util.pathExists("/mnt/onboard") then
        return "/mnt/onboard/manga" -- Kobo user partition
    elseif util.pathExists("/sdcard") then
        return "/sdcard/manga" -- Android storage
    end
    -- Default to user's home/books directory or DataStorage directory
    local base_dir = G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir() or "."
    base_dir = base_dir:gsub("/+$", "")
    return base_dir .. "/manga"
end

function MokuroCatalog:setDownloadDir(path)
    if path and path ~= "" then
        local clean = path:gsub("/+$", "")
        G_reader_settings:saveSetting("mokuro_download_dir", clean)
    end
end

function MokuroCatalog:getTitleLang()
    return G_reader_settings:readSetting("mokuro_title_lang") or "native"
end

function MokuroCatalog:setTitleLang(lang)
    G_reader_settings:saveSetting("mokuro_title_lang", lang)
end

function MokuroCatalog:getCacheFilePath()
    local cache_dir = DataStorage:getSettingsDir() .. "/cache"
    util.makePath(cache_dir)
    return cache_dir .. "/mokuro_catalog_library.json"
end

function MokuroCatalog:clearCache()
    local cache_file = self:getCacheFilePath()
    if util.pathExists(cache_file) then
        os.remove(cache_file)
    end
end

-- Title language formatting (matches web catalog progressions)
function MokuroCatalog:formatSeriesTitle(series_item)
    if not series_item then return "" end
    local pref = self:getTitleLang()
    local titles = (type(series_item.titles) == "table") and series_item.titles or {}
    local tag = (type(series_item.tag) == "string") and series_item.tag or nil
    local title = nil

    local function get_str(val)
        if type(val) == "string" and val ~= "" then
            return val
        end
        return nil
    end

    if pref == "native" then
        title = get_str(titles.native) or get_str(titles.romaji) or get_str(titles.english) or series_item.name
    elseif pref == "english" then
        title = get_str(titles.english) or get_str(titles.romaji) or get_str(titles.native) or series_item.name
    elseif pref == "romaji" then
        title = get_str(titles.romaji) or get_str(titles.native) or get_str(titles.english) or series_item.name
    else -- folder
        title = series_item.name
    end

    if not title or type(title) ~= "string" then
        title = tostring(series_item.name or "Untitled")
    end

    if tag and tag ~= "" and not title:find(tag, 1, true) then
        title = title .. " (" .. tag .. ")"
    end

    return title
end

-- Internal network request wrapper supporting HTTPS and redirects
function MokuroCatalog:httpRequest(options)
    local target_url = options.url
    local method = options.method or "GET"
    local headers = options.headers or {}
    local sink = options.sink
    local source = options.source

    -- Ensure User-Agent is set
    if not headers["User-Agent"] then
        headers["User-Agent"] = "MokuroReader-KOReader/1.0"
    end

    local is_https = target_url:match("^https://")
    local req_module = http
    if is_https then
        local ok_ssl, ssl_https = pcall(require, "ssl.https")
        if ok_ssl and ssl_https then
            req_module = ssl_https
        end
    end

    for attempt = 1, 5 do -- follow up to 5 redirects
        local response_body = {}
        local actual_sink = sink
        if not actual_sink then
            actual_sink = ltn12.sink.table(response_body)
        end

        local req_params = {
            url = target_url,
            method = method,
            headers = headers,
            sink = actual_sink,
            source = source,
            redirect = false,
        }

        local code, resp_headers, status = socket.skip(1, req_module.request(req_params))
        
        -- Retry on SSL handshake code if idempotent
        if code == socketutil.SSL_HANDSHAKE_CODE and (method == "GET" or method == "HEAD") then
            code, resp_headers, status = socket.skip(1, req_module.request(req_params))
        end

        if redirect_codes[code] and resp_headers and resp_headers.location then
            target_url = url.absolute(target_url, resp_headers.location)
            logger.info("MokuroCatalog: Redirecting to", target_url)
        else
            local body_str = nil
            if not sink then
                body_str = table.concat(response_body)
            end
            return code, resp_headers, status, body_str
        end
    end

    return nil, nil, "Too many redirects", nil
end

-- Fetch complete library catalog
function MokuroCatalog:fetchLibrary(force_refresh, callback, error_callback)
    local cache_file = self:getCacheFilePath()

    -- Try loading from cache first if not forcing refresh
    if not force_refresh and util.pathExists(cache_file) then
        local f = io.open(cache_file, "r")
        if f then
            local cached_str = f:read("*a")
            f:close()
            local cached_data = parse_json(cached_str)
            if cached_data and cached_data.series and #cached_data.series > 0 then
                logger.info("MokuroCatalog: Loaded", #cached_data.series, "series from local cache")
                if callback then
                    callback(cached_data.series, true)
                end
                return
            end
        end
    end

    -- Fetch from remote server
    local api_url = self:getServerUrl() .. "/catalog/api/library"
    logger.info("MokuroCatalog: Fetching library from", api_url)

    socketutil:set_timeout(30, 90)
    local code, resp_headers, status, body = self:httpRequest{
        url = api_url,
        method = "GET",
    }
    socketutil:reset_timeout()

    if code == 200 and body and body ~= "" then
        local data, err = parse_json(body)
        if data and data.series then
            -- Save to cache
            local cf = io.open(cache_file, "w")
            if cf then
                cf:write(body)
                cf:close()
            end
            logger.info("MokuroCatalog: Fetched and cached", #data.series, "series")
            if callback then
                callback(data.series, false)
            end
            return
        else
            logger.err("MokuroCatalog: Failed to parse library JSON:", err)
        end
    end

    -- If remote fetch failed, try fallback to cached copy
    if util.pathExists(cache_file) then
        local f = io.open(cache_file, "r")
        if f then
            local cached_str = f:read("*a")
            f:close()
            local cached_data = parse_json(cached_str)
            if cached_data and cached_data.series and #cached_data.series > 0 then
                logger.warn("MokuroCatalog: Network failed, using cached catalog")
                if callback then
                    callback(cached_data.series, true)
                end
                return
            end
        end
    end

    local err_msg = status or tostring(code) or _("Failed to connect to Mokuro catalog server")
    logger.err("MokuroCatalog: fetchLibrary error:", err_msg)
    if error_callback then
        error_callback(err_msg)
    end
end

-- Fetch volumes for a single series
function MokuroCatalog:fetchSeries(series_name, callback, error_callback)
    local api_url = self:getServerUrl() .. "/catalog/api/series?name=" .. url_encode(series_name)
    logger.info("MokuroCatalog: Fetching series details from", api_url)

    socketutil:set_timeout(20, 60)
    local code, resp_headers, status, body = self:httpRequest{
        url = api_url,
        method = "GET",
    }
    socketutil:reset_timeout()

    if code == 200 and body and body ~= "" then
        local data, err = parse_json(body)
        if data and data.volumes then
            if callback then
                callback(data)
            end
            return
        else
            logger.err("MokuroCatalog: Failed to parse series JSON:", err)
        end
    end

    local err_msg = status or tostring(code) or _("Failed to load series details")
    if error_callback then
        error_callback(err_msg)
    end
end

-- Fetch manifest for a volume
function MokuroCatalog:fetchManifest(series_name, volume_name, callback, error_callback)
    local api_url = self:getServerUrl() .. "/catalog/api/manifest?series=" .. url_encode(series_name) .. "&volume=" .. url_encode(volume_name)
    logger.info("MokuroCatalog: Fetching manifest from", api_url)

    socketutil:set_timeout(20, 45)
    local code, resp_headers, status, body = self:httpRequest{
        url = api_url,
        method = "GET",
    }
    socketutil:reset_timeout()

    if code == 200 and body and body ~= "" then
        local data, err = parse_json(body)
        if data and (data.archive or data.ocr) then
            if callback then
                callback(data)
            end
            return
        end
    end

    -- Fallback: generate default manifest paths
    local server_base = self:getServerUrl()
    local fallback_manifest = {
        archive = {
            url = "/mokuro-reader/" .. url_encode(series_name) .. "/" .. url_encode(volume_name) .. ".cbz",
            size = 0,
        },
        ocr = {
            url = "/mokuro-reader/" .. url_encode(series_name) .. "/" .. url_encode(volume_name) .. ".mokuro",
            size = 0,
        },
    }
    if callback then
        callback(fallback_manifest)
    end
end

-- Get local file paths for a series volume
function MokuroCatalog:getVolumeLocalPaths(series_name, volume_name)
    local download_dir = self:getDownloadDir()
    local series_folder = sanitize_filename(series_name)
    local volume_stem = sanitize_filename(volume_name)
    local series_dir = download_dir .. "/" .. series_folder

    local cbz_path = series_dir .. "/" .. volume_stem .. ".cbz"
    local mokuro_path = series_dir .. "/" .. volume_stem .. ".mokuro"

    return cbz_path, mokuro_path, series_dir
end

-- Check if a volume is downloaded locally
function MokuroCatalog:isVolumeDownloaded(series_name, volume_name)
    local cbz_path, mokuro_path = self:getVolumeLocalPaths(series_name, volume_name)
    if util.pathExists(cbz_path) and util.pathExists(mokuro_path) then
        return true, cbz_path, mokuro_path
    end
    -- If CBZ exists and is > 1MB, consider it downloaded even if mokuro sidecar is inside archive
    if util.pathExists(cbz_path) then
        local f = io.open(cbz_path, "rb")
        if f then
            local size = f:seek("end")
            f:close()
            if size and size > 1024 * 1024 then
                return true, cbz_path, mokuro_path
            end
        end
    end
    return false, cbz_path, mokuro_path
end

-- Count how many volumes are already downloaded for a series
function MokuroCatalog:getDownloadedVolumesCount(series_name, volume_list)
    if not volume_list then return 0 end
    local count = 0
    for i, v in ipairs(volume_list) do
        if self:isVolumeDownloaded(series_name, v.name) then
            count = count + 1
        end
    end
    return count
end

-- Stream download a single file with throttled progress and cancellation support
function MokuroCatalog:downloadFile(remote_url, local_path, expected_size, progress_cb, callback, error_cb, cancel_token)
    local dir = local_path:match("^(.-)[^/]+$")
    if dir and dir ~= "" then
        util.makePath(dir)
    end

    local part_path = local_path .. ".part"
    local f, err = io.open(part_path, "wb")
    if not f then
        if error_cb then error_cb(_("Failed to open file for writing:\n") .. tostring(err)) end
        return false
    end

    local downloaded = 0
    local last_progress_bytes = 0
    local last_progress_time = os.time()

    local function custom_sink(chunk, sink_err)
        if cancel_token and cancel_token.cancelled then
            f:close()
            return nil, "cancelled"
        end
        if chunk == nil then
            f:close()
            return 1
        elseif chunk == "" then
            return 1
        else
            local ok, write_err = f:write(chunk)
            if not ok then
                f:close()
                return nil, write_err or "disk write error"
            end
            downloaded = downloaded + #chunk
            local now = os.time()
            -- Throttle progress callback to at most once per second or when complete
            if progress_cb and (now ~= last_progress_time or (expected_size and expected_size > 0 and downloaded >= expected_size)) then
                last_progress_bytes = downloaded
                last_progress_time = now
                progress_cb(downloaded, expected_size or 0)
            end
            return 1
        end
    end

    local full_url = remote_url
    if remote_url:sub(1, 1) == "/" then
        full_url = self:getServerUrl() .. remote_url
    end

    logger.info("MokuroCatalog: Downloading from", full_url, "to", part_path)

    -- Large files: 30s block timeout, -1 disables total timeout so transfers never cut off
    socketutil:set_timeout(30, -1)
    local code, resp_headers, status = self:httpRequest{
        url = full_url,
        method = "GET",
        headers = {
            ["Accept-Encoding"] = "identity",
        },
        sink = custom_sink,
    }
    socketutil:reset_timeout()

    -- Ensure file handle is closed
    pcall(function() f:close() end)

    if cancel_token and cancel_token.cancelled then
        if util.pathExists(part_path) then os.remove(part_path) end
        if error_cb then error_cb(_("Download cancelled")) end
        return false
    end

    if code == 200 then
        -- Final 100% progress notification
        if progress_cb then
            progress_cb(downloaded, downloaded)
        end
        -- Atomic rename from .part to final file
        if util.pathExists(local_path) then
            os.remove(local_path)
        end
        local ok, ren_err = os.rename(part_path, local_path)
        if not ok then
            -- Fallback copy if rename fails
            local rf = io.open(part_path, "rb")
            local wf = io.open(local_path, "wb")
            if rf and wf then
                wf:write(rf:read("*a"))
                rf:close()
                wf:close()
                os.remove(part_path)
            else
                if rf then rf:close() end
                if wf then wf:close() end
                if error_cb then error_cb(_("Failed to finalize downloaded file:\n") .. tostring(ren_err)) end
                return false
            end
        end
        logger.info("MokuroCatalog: Successfully saved", local_path, "size:", downloaded)
        if callback then
            callback(local_path, downloaded)
        end
        return true
    else
        if util.pathExists(part_path) then os.remove(part_path) end
        local err_msg = status or tostring(code) or _("Network download failed")
        logger.err("MokuroCatalog: Download failed for", full_url, "code:", code, "error:", err_msg)
        if error_cb then
            error_cb(err_msg)
        end
        return false
    end
end

-- Download complete volume: both CBZ archive and Mokuro OCR metadata
function MokuroCatalog:downloadVolume(series_name, volume_name, progress_cb, callback, error_cb, cancel_token)
    local cbz_path, mokuro_path, series_dir = self:getVolumeLocalPaths(series_name, volume_name)
    util.makePath(series_dir)

    -- Step 1: Fetch manifest to get exact archive and OCR URLs
    self:fetchManifest(series_name, volume_name, function(manifest)
        if cancel_token and cancel_token.cancelled then
            if error_cb then error_cb(_("Download cancelled")) end
            return
        end

        local archive_info = manifest.archive or {}
        local ocr_info = manifest.ocr or {}

        local archive_url = archive_info.url or ("/mokuro-reader/" .. url_encode(series_name) .. "/" .. url_encode(volume_name) .. ".cbz")
        local ocr_url = ocr_info.url or ("/mokuro-reader/" .. url_encode(series_name) .. "/" .. url_encode(volume_name) .. ".mokuro")

        local cbz_size = archive_info.size or 0
        local ocr_size = ocr_info.size or 0

        -- Step 2: Download CBZ archive
        self:downloadFile(archive_url, cbz_path, cbz_size, function(dl_bytes, tot_bytes)
            if progress_cb then
                progress_cb("cbz", dl_bytes, tot_bytes > 0 and tot_bytes or cbz_size)
            end
        end, function()
            if cancel_token and cancel_token.cancelled then
                if util.pathExists(cbz_path) then os.remove(cbz_path) end
                if error_cb then error_cb(_("Download cancelled")) end
                return
            end

            -- Step 3: Download Mokuro OCR file
            self:downloadFile(ocr_url, mokuro_path, ocr_size, function(dl_bytes, tot_bytes)
                if progress_cb then
                    progress_cb("ocr", dl_bytes, tot_bytes > 0 and tot_bytes or ocr_size)
                end
            end, function()
                logger.info("MokuroCatalog: Volume download complete:", series_name, volume_name)
                if callback then
                    callback(cbz_path, mokuro_path)
                end
            end, function(err)
                -- If OCR file download fails, warn but CBZ is still usable if internal mokuro exists
                logger.warn("MokuroCatalog: OCR download failed:", err)
                if callback then
                    callback(cbz_path, nil)
                end
            end, cancel_token)

        end, function(err)
            if error_cb then error_cb(err) end
        end, cancel_token)

    end, function(err)
        if error_cb then error_cb(err) end
    end)
end

return MokuroCatalog
