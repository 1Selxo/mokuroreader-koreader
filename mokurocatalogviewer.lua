--[[
    MokuroCatalogViewer - Interactive catalog browser and downloader UI for KOReader
    Allows users to search, filter, sort, browse, and download manga volumes for offline reading
]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local MokuroCatalog = require("mokurocatalog")

local MokuroCatalogViewer = {
    catalog = nil,
    current_series_list = nil,
    active_search_query = nil,
    current_sort_mode = "title", -- 'title', 'rating', 'chars', 'volumes', 'newest'
}

function MokuroCatalogViewer:getCatalog()
    if not self.catalog then
        self.catalog = MokuroCatalog:new()
    end
    return self.catalog
end

-- Entry point: checks network and opens catalog
function MokuroCatalogViewer:show(force_refresh)
    local function fetch_and_display()
        local info = Notification:new{ text = _("Fetching Mokuro catalog…") }
        UIManager:show(info)
        UIManager:forceRePaint()

        local catalog = self:getCatalog()
        catalog:fetchLibrary(force_refresh or false, function(series_list, from_cache)
            UIManager:close(info)
            self.current_series_list = series_list
            if from_cache then
                UIManager:show(Notification:new{
                    text = _("Loaded catalog from offline cache"),
                    timeout = 3,
                })
            end
            self:showSeriesMenu()
        end, function(err_msg)
            UIManager:close(info)
            UIManager:show(InfoMessage:new{
                text = _("Failed to load Mokuro catalog:\n\n") .. tostring(err_msg),
            })
        end)
    end

    if NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(fetch_and_display)
    else
        fetch_and_display()
    end
end

-- Filter series by search query
local function filter_series(series_list, query, catalog)
    if not query or query == "" then
        return series_list
    end

    local q = query:lower()
    local filtered = {}

    for i, s in ipairs(series_list) do
        local matched = false

        -- Check folder name
        if s.name and s.name:lower():find(q, 1, true) then
            matched = true
        end

        -- Check titles (native, romaji, english)
        if not matched and s.titles then
            for lang_k, t in pairs(s.titles) do
                if type(t) == "string" and t:lower():find(q, 1, true) then
                    matched = true
                    break
                end
            end
        end

        -- Check tag (e.g. "Upscaled")
        if not matched and s.tag and s.tag:lower():find(q, 1, true) then
            matched = true
        end

        -- Check community genres & tags
        if not matched and s.community then
            if s.community.genres then
                for gi, g in ipairs(s.community.genres) do
                    if g:lower():find(q, 1, true) then
                        matched = true
                        break
                    end
                end
            end
            if not matched and s.community.tags then
                for ti, tg in ipairs(s.community.tags) do
                    if tg:lower():find(q, 1, true) then
                        matched = true
                        break
                    end
                end
            end
        end

        if matched then
            table.insert(filtered, s)
        end
    end

    return filtered
end

-- Sort series list according to mode
local function sort_series(series_list, mode, catalog)
    local sorted = {}
    for i, s in ipairs(series_list) do
        table.insert(sorted, s)
    end

    if mode == "rating" then
        table.sort(sorted, function(a, b)
            local score_a = (a.community and type(a.community.score) == "number") and a.community.score or 0
            local score_b = (b.community and type(b.community.score) == "number") and b.community.score or 0
            return score_a > score_b
        end)
    elseif mode == "chars" then
        table.sort(sorted, function(a, b)
            local ca = (type(a.total_chars) == "number") and a.total_chars or 0
            local cb = (type(b.total_chars) == "number") and b.total_chars or 0
            return ca > cb
        end)
    elseif mode == "volumes" then
        table.sort(sorted, function(a, b)
            local va = (type(a.volume_count) == "number") and a.volume_count or 0
            local vb = (type(b.volume_count) == "number") and b.volume_count or 0
            return va > vb
        end)
    elseif mode == "newest" then
        table.sort(sorted, function(a, b)
            local ma = (type(a.latest_volume_modified) == "number") and a.latest_volume_modified or 0
            local mb = (type(b.latest_volume_modified) == "number") and b.latest_volume_modified or 0
            return ma > mb
        end)
    else -- 'title' (alphabetical by formatted display title)
        table.sort(sorted, function(a, b)
            local title_a = catalog:formatSeriesTitle(a):lower()
            local title_b = catalog:formatSeriesTitle(b):lower()
            return title_a < title_b
        end)
    end

    return sorted
end

-- Display main Series List Menu
function MokuroCatalogViewer:showSeriesMenu()
    if not self.current_series_list then return end

    local catalog = self:getCatalog()
    local filtered = filter_series(self.current_series_list, self.active_search_query, catalog)
    local sorted = sort_series(filtered, self.current_sort_mode, catalog)

    local item_table = {}

    -- Top toolbar items
    if self.active_search_query and self.active_search_query ~= "" then
        table.insert(item_table, {
            text = string.format(_("❌ Clear search: \"%s\" (%d found)"), self.active_search_query, #sorted),
            bold = true,
            callback = function()
                self.active_search_query = nil
                self:showSeriesMenu()
            end,
        })
    else
        table.insert(item_table, {
            text = _("🔍 Search series (English, Romaji, Japanese, Genre)"),
            callback = function()
                self:promptSearch()
            end,
        })
    end

    local sort_names = {
        title = _("Title A–Z"),
        rating = _("Highest Rated"),
        chars = _("Wordiest"),
        volumes = _("Most Volumes"),
        newest = _("Recently Added"),
    }

    table.insert(item_table, {
        text = _("↕️ Sort: ") .. (sort_names[self.current_sort_mode] or _("Title A–Z")),
        callback = function()
            self:promptSort()
        end,
    })

    table.insert(item_table, {
        text = _("⚙️ Catalog Settings"),
        callback = function()
            self:showSettingsDialog()
        end,
    })

    -- Series list entries
    for i, s in ipairs(sorted) do
        local display_title = catalog:formatSeriesTitle(s)
        local vol_count = (type(s.volume_count) == "number") and s.volume_count or 0
        local badge = string.format(_("%d vols"), vol_count)

        if s.community and type(s.community.score) == "number" then
            badge = string.format("★%.0f | %s", s.community.score, badge)
        end

        local series_item = s
        table.insert(item_table, {
            text = display_title,
            mandatory = badge,
            callback = function()
                self:showSeriesDetail(series_item)
            end,
        })
    end

    local menu_title = _("Mokuro Catalog")
    if self.active_search_query then
        menu_title = string.format(_("Mokuro: \"%s\""), self.active_search_query)
    end

    local menu = Menu:new{
        title = menu_title,
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
end

-- Search Prompt dialog
function MokuroCatalogViewer:promptSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Mokuro Catalog"),
        input_hint = _("e.g. Yotsuba, 恋, Zombie, Romance"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        if query and query:gsub("%s+", "") ~= "" then
                            self.active_search_query = query:match("^%s*(.-)%s*$")
                        else
                            self.active_search_query = nil
                        end
                        self:showSeriesMenu()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Sort Prompt dialog
function MokuroCatalogViewer:promptSort()
    local dialog
    local sort_options = {
        { id = "title", text = _("Title A–Z") },
        { id = "rating", text = _("Highest Rated (Anilist)") },
        { id = "chars", text = _("Wordiest (Total Characters)") },
        { id = "volumes", text = _("Most Volumes") },
        { id = "newest", text = _("Recently Added / Updated") },
    }

    local buttons = {}
    for i, opt in ipairs(sort_options) do
        local is_current = (self.current_sort_mode == opt.id)
        table.insert(buttons, {{
            text = (is_current and "● " or "○ ") .. opt.text,
            bold = is_current,
            callback = function()
                UIManager:close(dialog)
                self.current_sort_mode = opt.id
                self:showSeriesMenu()
            end,
            align = "left",
        }})
    end

    dialog = ButtonDialog:new{
        title = _("Sort Series By"),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

-- Series Detail Menu (volumes, download all, status)
function MokuroCatalogViewer:showSeriesDetail(series)
    local catalog = self:getCatalog()
    local info = Notification:new{ text = _("Fetching series volumes…") }
    UIManager:show(info)
    UIManager:forceRePaint()

    catalog:fetchSeries(series.name, function(series_data)
        UIManager:close(info)
        self:renderSeriesDetailMenu(series, series_data.volumes or {})
    end, function(err_msg)
        UIManager:close(info)
        UIManager:show(InfoMessage:new{
            text = _("Failed to load volumes:\n\n") .. tostring(err_msg),
        })
    end)
end

-- Render the volumes menu for a series
function MokuroCatalogViewer:renderSeriesDetailMenu(series, volumes)
    local catalog = self:getCatalog()
    local display_title = catalog:formatSeriesTitle(series)
    local item_table = {}

    -- Series overview badge
    local info_parts = {}
    table.insert(info_parts, string.format(_("%d volumes"), #volumes))
    if series.total_chars and type(series.total_chars) == "number" and series.total_chars > 0 then
        table.insert(info_parts, string.format(_("%dK chars"), math.floor(series.total_chars / 1000)))
    end
    if series.community and type(series.community.score) == "number" then
        table.insert(info_parts, string.format(_("Rating: %.0f"), series.community.score))
    end

    local genres_str = ""
    if series.community and series.community.genres and #series.community.genres > 0 then
        genres_str = table.concat(series.community.genres, ", ")
    end

    table.insert(item_table, {
        text = "ℹ️ " .. table.concat(info_parts, " | "),
        mandatory = genres_str ~= "" and genres_str or nil,
        dim = true,
    })

    -- Check downloaded status for all volumes
    local missing_volumes = {}
    for i, v in ipairs(volumes) do
        if not catalog:isVolumeDownloaded(series.name, v.name) then
            table.insert(missing_volumes, v)
        end
    end

    -- Download All button
    if #missing_volumes > 0 then
        table.insert(item_table, {
            text = string.format(_("📥 Download All Missing Volumes (%d)"), #missing_volumes),
            bold = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Download all %d missing volumes for:\n\n%s\n\n(Each volume includes CBZ archive + Mokuro OCR data)"), #missing_volumes, display_title),
                    ok_text = _("Download All"),
                    ok_callback = function()
                        self:downloadBatchVolumes(series.name, missing_volumes, function()
                            -- Re-render series menu on finish
                            self:renderSeriesDetailMenu(series, volumes)
                        end)
                    end,
                })
            end,
        })
    else
        table.insert(item_table, {
            text = _("✓ All volumes are downloaded locally!"),
            bold = true,
            dim = true,
        })
    end

    -- Individual volumes list
    for idx, v in ipairs(volumes) do
        local is_dl, cbz_path, mokuro_path = catalog:isVolumeDownloaded(series.name, v.name)
        local vol_name = v.name
        local page_str = (type(v.page_count) == "number" and v.page_count > 0) and string.format(_("%d pgs"), v.page_count) or _("Download")
        local badge = is_dl and _("✓ Local") or page_str

        local vol_entry = v
        table.insert(item_table, {
            text = vol_name,
            mandatory = badge,
            bold = not is_dl,
            callback = function()
                if is_dl then
                    self:promptDownloadedVolumeAction(series.name, vol_entry, cbz_path, function()
                        self:renderSeriesDetailMenu(series, volumes)
                    end)
                else
                    self:promptDownloadSingleVolume(series.name, vol_entry, function()
                        self:renderSeriesDetailMenu(series, volumes)
                    end)
                end
            end,
        })
    end

    local detail_menu = Menu:new{
        title = display_title,
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    UIManager:show(detail_menu)
end

-- Action prompt when tapping an already downloaded volume
function MokuroCatalogViewer:promptDownloadedVolumeAction(series_name, volume, cbz_path, on_change)
    local dialog
    dialog = ButtonDialog:new{
        title = volume.name,
        buttons = {
            {{
                text = _("📖 Open in Reader"),
                bold = true,
                callback = function()
                    UIManager:close(dialog)
                    ReaderUI:showReader(cbz_path)
                end,
            }},
            {{
                text = _("🔄 Re-download (Overwrite)"),
                callback = function()
                    UIManager:close(dialog)
                    self:downloadSingleVolumeWithProgress(series_name, volume.name, on_change)
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }},
        },
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

-- Prompt before downloading a single volume
function MokuroCatalogViewer:promptDownloadSingleVolume(series_name, volume, on_finish)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Download volume:\n\n%s\n\n(Includes CBZ images + Mokuro OCR sidecar for offline reading)"), volume.name),
        ok_text = _("Download"),
        ok_callback = function()
            self:downloadSingleVolumeWithProgress(series_name, volume.name, on_finish)
        end,
    })
end

-- Download single volume with live progress dialog
function MokuroCatalogViewer:downloadSingleVolumeWithProgress(series_name, volume_name, on_finish)
    local catalog = self:getCatalog()
    local cancel_token = { cancelled = false }

    local progress_info = InfoMessage:new{
        text = string.format(_("Downloading:\n%s\n\nConnecting to server…"), volume_name),
        timeout = 0,
        dismissable = false,
        no_refresh_on_close = true,
    }
    UIManager:show(progress_info)
    UIManager:forceRePaint()

    local last_update_sec = 0
    local last_phase = nil

    local function update_progress(phase, downloaded, total)
        local now = os.time()
        if phase ~= last_phase or (now - last_update_sec >= 1) or (total and total > 0 and downloaded >= total) then
            last_phase = phase
            last_update_sec = now

            local phase_label = (phase == "cbz") and _("CBZ archive") or _("Mokuro OCR metadata")
            local pct = (total and type(total) == "number" and total > 0) and math.floor((downloaded / total) * 100) or 0
            local txt = string.format(_("Downloading %s:\n%s\n\n%s / %s (%d%%)"),
                phase_label,
                volume_name,
                catalog.format_size(downloaded),
                catalog.format_size(total),
                pct
            )

            if progress_info then
                UIManager:close(progress_info)
                progress_info = nil
            end
            progress_info = InfoMessage:new{
                text = txt,
                timeout = 0,
                dismissable = false,
                no_refresh_on_close = true,
            }
            UIManager:show(progress_info)
            UIManager:forceRePaint()
        end
    end

    catalog:downloadVolume(series_name, volume_name, update_progress, function(cbz_path, mokuro_path)
        if progress_info then
            UIManager:close(progress_info)
            progress_info = nil
        end
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Download complete!\n\n%s\n\nWould you like to open it now?"), volume_name),
            ok_text = _("Open in Reader"),
            cancel_text = _("Stay in Catalog"),
            ok_callback = function()
                ReaderUI:showReader(cbz_path)
            end,
            cancel_callback = function()
                if on_finish then on_finish() end
            end,
        })
    end, function(err_msg)
        if progress_info then
            UIManager:close(progress_info)
            progress_info = nil
        end
        UIManager:show(InfoMessage:new{
            text = _("Download failed:\n\n") .. tostring(err_msg),
        })
        if on_finish then on_finish() end
    end, cancel_token)
end

-- Batch download multiple volumes sequentially
function MokuroCatalogViewer:downloadBatchVolumes(series_name, volume_list, on_finish)
    local catalog = self:getCatalog()
    local total_count = #volume_list
    local current_idx = 1
    local completed_count = 0
    local cancel_token = { cancelled = false }

    local progress_info = InfoMessage:new{
        text = string.format(_("Batch downloading %d volumes…\n\nStarting…"), total_count),
        timeout = 0,
        dismissable = false,
        no_refresh_on_close = true,
    }
    UIManager:show(progress_info)
    UIManager:forceRePaint()

    local function download_next()
        if cancel_token.cancelled or current_idx > total_count then
            if progress_info then
                UIManager:close(progress_info)
                progress_info = nil
            end
            UIManager:show(InfoMessage:new{
                text = string.format(_("Batch download finished!\n\nDownloaded %d of %d volumes."), completed_count, total_count),
            })
            if on_finish then on_finish() end
            return
        end

        local vol = volume_list[current_idx]
        local vol_name = vol.name
        local last_update_sec = 0
        local last_phase = nil

        local function update_batch_progress(phase, downloaded, total)
            local now = os.time()
            if phase ~= last_phase or (now - last_update_sec >= 1) or (total and total > 0 and downloaded >= total) then
                last_phase = phase
                last_update_sec = now
                local pct = (total and type(total) == "number" and total > 0) and math.floor((downloaded / total) * 100) or 0
                local txt = string.format(_("Downloading volume %d of %d:\n%s\n\n%s: %s / %s (%d%%)"),
                    current_idx,
                    total_count,
                    vol_name,
                    (phase == "cbz" and _("CBZ archive") or _("Mokuro OCR metadata")),
                    catalog.format_size(downloaded),
                    catalog.format_size(total),
                    pct
                )
                if progress_info then
                    UIManager:close(progress_info)
                    progress_info = nil
                end
                progress_info = InfoMessage:new{
                    text = txt,
                    timeout = 0,
                    dismissable = false,
                    no_refresh_on_close = true,
                }
                UIManager:show(progress_info)
                UIManager:forceRePaint()
            end
        end

        catalog:downloadVolume(series_name, vol_name, update_batch_progress, function()
            completed_count = completed_count + 1
            current_idx = current_idx + 1
            download_next()
        end, function(err_msg)
            logger.err("MokuroCatalog: Error in batch download:", vol_name, err_msg)
            current_idx = current_idx + 1
            download_next()
        end, cancel_token)
    end

    download_next()
end

-- Settings Dialog
function MokuroCatalogViewer:showSettingsDialog()
    local catalog = self:getCatalog()
    local dialog
    local buttons = {
        {{
            text = _("📁 Set Download Folder: ") .. catalog:getDownloadDir(),
            callback = function()
                UIManager:close(dialog)
                self:chooseDownloadDir()
            end,
            align = "left",
        }},
        {{
            text = _("🌐 Series Title Language: ") .. catalog:getTitleLang():upper(),
            callback = function()
                UIManager:close(dialog)
                self:chooseTitleLang()
            end,
            align = "left",
        }},
        {{
            text = _("🔗 Server URL: ") .. catalog:getServerUrl(),
            callback = function()
                UIManager:close(dialog)
                self:changeServerUrl()
            end,
            align = "left",
        }},
        {{
            text = _("🔄 Refresh Catalog Cache"),
            callback = function()
                UIManager:close(dialog)
                catalog:clearCache()
                self:show(true)
            end,
            align = "left",
        }},
        {{
            text = _("Close"),
            callback = function()
                UIManager:close(dialog)
            end,
        }},
    }

    dialog = ButtonDialog:new{
        title = _("Mokuro Catalog Settings"),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

-- Download directory chooser via KOReader's DownloadMgr
function MokuroCatalogViewer:chooseDownloadDir()
    local catalog = self:getCatalog()
    local ok, DownloadMgr = pcall(require, "ui/downloadmgr")
    if ok and DownloadMgr then
        DownloadMgr:new{
            onConfirm = function(chosen_path)
                catalog:setDownloadDir(chosen_path)
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Download folder set to:\n\n%s"), chosen_path),
                })
            end,
        }:chooseDir()
    else
        UIManager:show(InfoMessage:new{
            text = _("Download directory manager is not available."),
        })
    end
end

-- Title language preference dialog
function MokuroCatalogViewer:chooseTitleLang()
    local catalog = self:getCatalog()
    local dialog
    local langs = {
        { id = "native", text = _("Native (Japanese)") },
        { id = "english", text = _("English") },
        { id = "romaji", text = _("Romaji") },
        { id = "folder", text = _("Folder Name") },
    }

    local buttons = {}
    local current_lang = catalog:getTitleLang()
    for i, l in ipairs(langs) do
        local is_sel = (current_lang == l.id)
        table.insert(buttons, {{
            text = (is_sel and "● " or "○ ") .. l.text,
            bold = is_sel,
            callback = function()
                UIManager:close(dialog)
                catalog:setTitleLang(l.id)
                self:showSeriesMenu()
            end,
            align = "left",
        }})
    end

    dialog = ButtonDialog:new{
        title = _("Series Title Language"),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

-- Change server URL dialog
function MokuroCatalogViewer:changeServerUrl()
    local catalog = self:getCatalog()
    local dialog
    dialog = InputDialog:new{
        title = _("Mokuro Server URL"),
        input = catalog:getServerUrl(),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Default"),
                    callback = function()
                        UIManager:close(dialog)
                        catalog:setServerUrl(nil)
                        UIManager:show(InfoMessage:new{ text = _("Reset to default: https://mokuro.moe") })
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_url = dialog:getInputText()
                        UIManager:close(dialog)
                        if new_url and new_url:gsub("%s+", "") ~= "" then
                            catalog:setServerUrl(new_url:match("^%s*(.-)%s*$"))
                            UIManager:show(InfoMessage:new{ text = _("Server URL saved:\n") .. new_url })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return MokuroCatalogViewer
