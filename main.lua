--[[
    Mokuro Reader Plugin for KOReader - VERSION 7
    Using ScrollHtmlWidget with CJK space cleanup for Japanese support
    + Dual page mode support
    + Sentence mining support for VocabBuilder and Anki plugins
]]--

local logger = require("logger")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local util = require("util")
local _ = require("gettext")

-- G_reader_settings is a global variable, no need to require it

logger.info("MokuroReader: Loading plugin module...")

local MokuroParser = require("mokuroparser")

local MokuroReader = WidgetContainer:extend{
    name = "Mokuro",  -- Capital M for Anki plugin compatibility (self.ui['Mokuro'])
    is_doc_only = false, -- Active in both File Manager and Reader view
    mokuro_data = nil,
    parser = nil,
    current_page = nil,
    enabled = true,
}

function MokuroReader:init()
    logger.info("MokuroReader: init() called")
    
    self.ui.menu:registerToMainMenu(self)
    self.parser = MokuroParser:new()
    
    logger.info("MokuroReader: Parser created")
    
    -- Hook into document ready
    self.onReaderReady = function()
        logger.info("MokuroReader: onReaderReady triggered")
        UIManager:scheduleIn(0.5, function()
            self:checkAndLoadMokuro()
        end)
    end
    
    logger.info("MokuroReader: init() complete")
end

function MokuroReader:hookTouchZones()
    if self._touch_zones_hooked then return end
    self._touch_zones_hooked = true
    
    if self.ui.paging then
        local orig_paging_setup = self.ui.paging.setupTouchZones
        self.ui.paging.setupTouchZones = function(paging_self)
            orig_paging_setup(paging_self)
            if self.mokuro_data and self.enabled then
                self:registerTouchZones()
            end
        end
    end
    
    if self.ui.rolling then
        local orig_rolling_setup = self.ui.rolling.setupTouchZones
        self.ui.rolling.setupTouchZones = function(rolling_self)
            orig_rolling_setup(rolling_self)
            if self.mokuro_data and self.enabled then
                self:registerTouchZones()
            end
        end
    end
end

function MokuroReader:onPageUpdate()
    if self.mokuro_data and self.enabled then
        self:registerTouchZones()
    end
end

function MokuroReader:registerTouchZones()
    if not self.ui or not self.ui.registerTouchZones then
        return
    end
    
    logger.info("MokuroReader: Registering touch zones")
    
    self.ui:registerTouchZones({
        {
            id = "mokuro_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_tap",
                "readerhighlight_tap_select_mode",
                "tap_forward",
                "tap_backward",
                "readermenu_tap",
                "readermenu_ext_tap",
                "readerconfigmenu_tap",
                "readerconfigmenu_ext_tap",
            },
            handler = function(ges)
                return self:onMokuroTap(ges)
            end
        },
        {
            id = "mokuro_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_hold",
            },
            handler = function(ges)
                return self:onMokuroTap(ges)
            end
        },
    })
    
    logger.info("MokuroReader: Touch zones registered!")
end

function MokuroReader:checkAndLoadMokuro()
    logger.info("MokuroReader: checkAndLoadMokuro() called")
    
    if not self.ui.document or not self.ui.document.file then
        logger.dbg("MokuroReader: No document file")
        return
    end
    
    local file_path = self.ui.document.file
    local ext = file_path:match("^.+%.([^.]+)$")
    
    if not ext or (ext:lower() ~= "cbz" and ext:lower() ~= "zip") then
        logger.dbg("MokuroReader: Not a CBZ file")
        return
    end
    
    logger.info("MokuroReader: CBZ detected, loading mokuro data")
    
    local success = self:loadMokuroData()
    
    if success then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Mokuro: Loaded %d pages with OCR!"), #self.mokuro_data.pages),
            timeout = 3,
        })
        
        -- Disable KOReader's panel zoom for this manga so long-presses don't blow up the comic panels
        if self.ui.highlight then
            self._orig_panel_zoom = self.ui.highlight.panel_zoom_enabled
            self.ui.highlight.panel_zoom_enabled = false
        end
        
        -- Hook and register touch zones after data is loaded
        self:hookTouchZones()
        self:registerTouchZones()
    else
        logger.dbg("MokuroReader: No mokuro data in this CBZ")
    end
end

function MokuroReader:loadMokuroData()
    local file_path = self.ui.document.file
    logger.info("MokuroReader: loadMokuroData from:", file_path)
    
    -- 1. Check for external sidecar .mokuro file first (e.g. Volume.mokuro or Volume.cbz.mokuro)
    local sidecar_path1 = file_path:gsub("%.[^.]+$", ".mokuro")
    local sidecar_path2 = file_path .. ".mokuro"
    local sidecar = nil
    
    local f1 = io.open(sidecar_path1, "r")
    if f1 then
        f1:close()
        sidecar = sidecar_path1
    else
        local f2 = io.open(sidecar_path2, "r")
        if f2 then
            f2:close()
            sidecar = sidecar_path2
        end
    end
    
    if sidecar then
        logger.info("MokuroReader: Found sidecar mokuro file:", sidecar)
        local sf = io.open(sidecar, "r")
        if sf then
            local content = sf:read("*a")
            sf:close()
            if content and content ~= "" then
                self.mokuro_data = self.parser:parse(content)
                if self.mokuro_data then
                    logger.info("MokuroReader: Loaded", #self.mokuro_data.pages, "pages from sidecar")
                    return true
                end
            end
        end
    end
    
    -- 2. Fall back to reading .mokuro file inside the CBZ archive
    -- Use KOReader's archiver module (supports all compression types)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    
    -- Open the CBZ archive
    if not reader:open(file_path) then
        logger.warn("MokuroReader: Could not open CBZ:", reader.err or "unknown error")
        return false
    end
    
    -- Find the .mokuro file
    local mokuro_entry = nil
    for entry in reader:iterate() do
        if entry.path:match("%.mokuro$") and entry.mode == "file" then
            mokuro_entry = entry
            logger.info("MokuroReader: Found mokuro file:", entry.path)
            break
        end
    end
    
    if not mokuro_entry then
        logger.warn("MokuroReader: No .mokuro file found in CBZ")
        reader:close()
        return false
    end
    
    -- Read the .mokuro file content
    local content = reader:extractToMemory(mokuro_entry.path)
    reader:close()
    
    if not content or content == "" then
        logger.warn("MokuroReader: Could not read .mokuro file content")
        return false
    end
    
    -- Parse the JSON content
    self.mokuro_data = self.parser:parse(content)
    
    if self.mokuro_data then
        logger.info("MokuroReader: Loaded", #self.mokuro_data.pages, "pages")
        return true
    end
    
    return false
end

-- Function to remove spaces between CJK characters (like the patch)
local function strip_cjk_spaces(s)
    if not s then return s end
    -- Pattern matches CJK character + space + CJK character
    local pattern = "([\227-\239][\128-\191][\128-\191])%s+([\227-\239][\128-\191][\128-\191])"
    local result = s
    local count
    repeat
        result, count = result:gsub(pattern, "%1%2")
    until count == 0
    return result
end

--[[
    Calculate context from full block text and selected word
    Returns prev_context, next_context (always strings, never nil)
]]--
local function calculateContext(full_text, selected_text)
    if not full_text or not selected_text then
        return "", ""
    end
    
    -- Clean both texts for comparison (remove CJK spaces)
    local clean_full = strip_cjk_spaces(full_text)
    local clean_selected = strip_cjk_spaces(selected_text)
    
    if not clean_full or clean_full == "" or not clean_selected or clean_selected == "" then
        return "", ""
    end
    
    -- Find the selected text in the full text
    local start_pos, end_pos = clean_full:find(clean_selected, 1, true)
    
    if start_pos then
        local prev_context = ""
        local next_context = ""
        
        if start_pos > 1 then
            prev_context = clean_full:sub(1, start_pos - 1)
        end
        
        if end_pos < #clean_full then
            next_context = clean_full:sub(end_pos + 1)
        end
        
        logger.info("MokuroReader: calculated context")
        logger.info("  prev_context:", prev_context)
        logger.info("  next_context:", next_context)
        
        return prev_context, next_context
    end
    
    logger.warn("MokuroReader: could not find selected text in block, returning empty context")
    return "", ""
end

function MokuroReader:onMokuroTap(ges)
    if not self.mokuro_data or not self.enabled then
        return false
    end
    
    logger.info(string.format("MokuroReader: ✓✓✓ TAP DETECTED at (%d, %d) ✓✓✓", math.floor(ges.pos.x), math.floor(ges.pos.y)))
    
    -- Convert screen tap position to document page coordinates
    local page_pos
    if self.ui.view and self.ui.view.screenToPageTransform then
        page_pos = self.ui.view:screenToPageTransform(ges.pos)
    elseif self.ui.view and self.ui.view.getSinglePagePosition then
        page_pos = self.ui.view:getSinglePagePosition(ges.pos)
    end
    
    local page_no = (page_pos and page_pos.page) or self.ui:getCurrentPage()
    logger.info("MokuroReader: Target page:", page_no)
    
    local page_data = self.parser:getPageData(self.mokuro_data, page_no)
    if not page_data or not page_data.blocks or #page_data.blocks == 0 then
        logger.info("MokuroReader: No text blocks on page " .. tostring(page_no) .. ", passing tap through")
        return false
    end
    
    logger.info("MokuroReader: Page has " .. tostring(#page_data.blocks) .. " text blocks, checking hit...")
    local tapped_block = self:findBlockAtPosition(page_data, ges.pos, page_no, page_pos)
    if not tapped_block then
        logger.info("MokuroReader: Tap did not hit any block on page " .. tostring(page_no) .. ", passing tap through")
        return false
    end
    
    return self:showMokuroPopup(tapped_block)
end

function MokuroReader:showMokuroPopup(block)
    -- Get the text from the block
    local block_text = self.parser:getBlockText(block)
    
    if not block_text or block_text == "" then
        logger.warn("MokuroReader: Block has no text")
        return false
    end
    
    return self:showMokuroPopupWithText(block, block_text)
end

function MokuroReader:showMokuroPopupWithText(block, block_text)
    logger.info("MokuroReader: Showing text popup for block:", block_text)
    
    if self.mokuro_popup then
        UIManager:close(self.mokuro_popup)
        self.mokuro_popup = nil
    end
    
    -- CRITICAL: Capture self references before creating callbacks
    -- Inside callbacks, 'self' will be mokuro_popup, not MokuroReader!
    local ui = self.ui
    local reader = self  -- Capture MokuroReader instance
    local captured_block = block  -- Capture the block for later use
    local captured_block_text = block_text  -- Also capture the text
    local mokuro_popup  -- Forward declaration, will be set below
    
    -- Use ScrollTextWidget like DictQuickLookup does - it handles everything internally
    local ScrollTextWidget = require("ui/widget/scrolltextwidget")
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Size = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")
    local GestureRange = require("ui/gesturerange")
    local Geom = require("ui/geometry")
    local Device = require("device")
    local Screen = Device.screen
    local Event = require("ui/event")
    local Font = require("ui/font")
    
    -- Get user's preferred font size (default 48 for easy selection)
    local font_size = G_reader_settings:readSetting("mokuro_font_size") or 48
    
    -- Calculate dimensions (bottom 1/3 of screen like footnotes)
    local width = Screen:getWidth()
    local height = math.floor(Screen:getHeight() * 1/3)
    
    local padding = Size.padding.large
    local content_width = width - 2 * padding
    local content_height = height - 2 * padding
    
    -- Get font face
    local face = Font:getFace("cfont", font_size)
    
    -- Create the popup container first (we need it as parent for text_widget)
    mokuro_popup = InputContainer:new{
        modal = false,  -- Non-modal so dictionary can open on top
    }
    self.mokuro_popup = mokuro_popup  -- Keep reference in MokuroReader too
    
    -- Create ScrollTextWidget (like DictQuickLookup does)
    -- ScrollTextWidget wraps TextBoxWidget internally and handles scrolling
    -- CRITICAL: dialog must point to the popup itself for proper event handling!
    -- Add padding spaces at the start to make first character selectable
    local padded_text = "  " .. block_text  -- Two spaces for easy tap on first char
    local text_widget = ScrollTextWidget:new{
        text = padded_text,
        face = face,
        width = content_width,
        height = content_height,
        dialog = mokuro_popup,  -- CRITICAL: parent is the popup
        justified = false,  -- CRITICAL: no justification for better CJK selection
        para_direction_rtl = false,
        auto_para_direction = false,
        alignment = "left",
        highlight_text_selection = true,  -- Enable text selection highlighting
    }
    
    -- Wrap in frame
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = padding,
        margin = 0,
        text_widget,
    }
    
    -- Put in bottom container
    local bottom_container = BottomContainer:new{
        dimen = Screen:getSize(),
        frame,
    }
    
    -- Add the bottom_container to the popup we created earlier
    mokuro_popup[1] = bottom_container
    
    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        
        local hold_pan_rate = G_reader_settings:readSetting("hold_pan_rate")
        if not hold_pan_rate then
            hold_pan_rate = Screen.low_pan_rate and 5.0 or 30.0
        end
        
        self.mokuro_popup.ges_events = {
            -- Tap outside to close
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight(),
                    },
                },
            },
            -- All three Hold events are needed for text selection to work with TextBoxWidget!
            HoldStartText = {
                GestureRange:new{
                    ges = "hold",
                    range = range,
                },
            },
            HoldPanText = {
                GestureRange:new{
                    ges = "hold_pan",
                    range = range,
                    rate = hold_pan_rate,
                },
            },
            HoldReleaseText = {
                GestureRange:new{
                    ges = "hold_release",
                    range = range,
                },
            },
        }
        
        -- Connect gestures to the internal TextBoxWidget of ScrollTextWidget (like DictQuickLookup does)
        -- CRITICAL: ScrollTextWidget.text_widget is the internal TextBoxWidget that has the onHold methods!
        function self.mokuro_popup:onHoldStartText(_, ges)
            return text_widget.text_widget:onHoldStartText(_, ges)
        end
        
        function self.mokuro_popup:onHoldPanText(_, ges)
            return text_widget.text_widget:onHoldPanText(_, ges)
        end
        
        function self.mokuro_popup:onHoldReleaseText(_, ges)
            -- CRITICAL: callback is the FIRST parameter, ges is the second!
            return text_widget.text_widget:onHoldReleaseText(function(selected_text, hold_duration)
                if selected_text and selected_text ~= "" then
                    -- CRITICAL: Clean up CJK spaces before dictionary lookup!
                    local cleaned_text = strip_cjk_spaces(selected_text)
                    
                    logger.info("MokuroReader: Selected text:", selected_text)
                    logger.info("MokuroReader: Cleaned text:", cleaned_text)
                    logger.info("MokuroReader: Block text:", block_text)
                    
                    -- Calculate context (block_text is captured in this closure)
                    local prev_context, next_context = calculateContext(block_text, cleaned_text)
                    
                    -- Set ui.highlight.selected_text for VocabBuilder's "highlight" field
                    if ui.highlight then
                        ui.highlight.selected_text = {
                            text = cleaned_text,
                        }
                        
                        -- Inject our context into the highlight module
                        -- VocabBuilder calls ui.highlight:getSelectedWordContext(15) to get context
                        ui.highlight.getSelectedWordContext = function(self_highlight, nb_words)
                            logger.info("MokuroReader: getSelectedWordContext called, returning mokuro context")
                            return prev_context or "", next_context or ""
                        end
                    end
                    
                    -- DON'T close the popup - let the dictionary open on top of it
                    -- The popup stays underneath, like with footnotes
                    
                    -- Trigger dictionary lookup
                    local lookup_target = hold_duration < require("ui/time").s(3) and "LookupWord" or "LookupWikipedia"
                    ui:handleEvent(
                        Event:new(lookup_target, cleaned_text)
                    )
                    
                    -- No need to reopen - the popup never closed!
                end
            end, ges)
        end
    end
    
    function self.mokuro_popup:onTapClose()
        UIManager:close(mokuro_popup)
        return true
    end
    
    UIManager:show(mokuro_popup)
    UIManager:forceRePaint()
    
    return true  -- Consume the tap
end

function MokuroReader:findBlockAtPosition(page_data, tap_pos, page_no, page_pos)
    local img_w = page_data.img_width
    local img_h = page_data.img_height
    
    local mokuro_x, mokuro_y
    
    if page_pos and page_pos.x and page_pos.y then
        -- Native transformed page coordinates (accounts for all zoom, crop, and pan modes)
        local doc_dimen = self.ui.document and self.ui.document.getNativePageDimensions and self.ui.document:getNativePageDimensions(page_no)
        local doc_w = (doc_dimen and (doc_dimen.w or doc_dimen.width)) or img_w
        local doc_h = (doc_dimen and (doc_dimen.h or doc_dimen.height)) or img_h
        
        local scale_x = (doc_w > 0) and (img_w / doc_w) or 1
        local scale_y = (doc_h > 0) and (img_h / doc_h) or 1
        
        mokuro_x = page_pos.x * scale_x
        mokuro_y = page_pos.y * scale_y
        logger.info(string.format("MokuroReader: Transformed tap to Mokuro coords (%d, %d) [img: %dx%d, doc: %dx%d]",
            math.floor(mokuro_x), math.floor(mokuro_y), img_w, img_h, doc_w, doc_h))
    else
        -- Fallback: screen fit
        local Screen = require("device").screen
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        local scale = math.min(screen_w / img_w, screen_h / img_h)
        local offset_x = (screen_w - img_w * scale) / 2
        local offset_y = (screen_h - img_h * scale) / 2
        mokuro_x = (tap_pos.x - offset_x) / scale
        mokuro_y = (tap_pos.y - offset_y) / scale
        logger.info(string.format("MokuroReader: Fallback tap to Mokuro coords (%d, %d)",
            math.floor(mokuro_x), math.floor(mokuro_y)))
    end
    
    -- Check each block with a generous touch tolerance pad (35px in image space)
    local pad = 35
    local best_block = nil
    local best_dist = math.huge
    
    for i, block in ipairs(page_data.blocks) do
        local box = block.box
        if box and #box >= 4 then
            local x1, y1, x2, y2 = box[1], box[2], box[3], box[4]
            if mokuro_x >= (x1 - pad) and mokuro_x <= (x2 + pad) and
               mokuro_y >= (y1 - pad) and mokuro_y <= (y2 + pad) then
                local cx = (x1 + x2) / 2
                local cy = (y1 + y2) / 2
                local dist = (mokuro_x - cx)^2 + (mokuro_y - cy)^2
                if dist < best_dist then
                    best_dist = dist
                    best_block = block
                end
            end
        end
    end
    
    if best_block then
        local text = self.parser:getBlockText(best_block)
        logger.info(string.format("MokuroReader: Matched block text: '%s'", text:sub(1, 40)))
    end
    
    return best_block
end

function MokuroReader:addToMainMenu(menu_items)
    menu_items.mokuro = {
        text = _("Mokuro Reader"),
        sub_item_table = {
            {
                text = _("Browse Mokuro Catalog"),
                callback = function()
                    local MokuroCatalogViewer = require("mokurocatalogviewer")
                    MokuroCatalogViewer:show()
                end,
            },
            {
                text = _("Mokuro Catalog Settings"),
                sub_item_table = {
                    {
                        text = _("Download Folder"),
                        callback = function()
                            local MokuroCatalogViewer = require("mokurocatalogviewer")
                            MokuroCatalogViewer:chooseDownloadDir()
                        end,
                    },
                    {
                        text = _("Series Title Language"),
                        sub_item_table = {
                            {
                                text = _("Native (Japanese)"),
                                checked_func = function()
                                    return (G_reader_settings:readSetting("mokuro_title_lang") or "native") == "native"
                                end,
                                callback = function()
                                    G_reader_settings:saveSetting("mokuro_title_lang", "native")
                                end,
                            },
                            {
                                text = _("English"),
                                checked_func = function()
                                    return G_reader_settings:readSetting("mokuro_title_lang") == "english"
                                end,
                                callback = function()
                                    G_reader_settings:saveSetting("mokuro_title_lang", "english")
                                end,
                            },
                            {
                                text = _("Romaji"),
                                checked_func = function()
                                    return G_reader_settings:readSetting("mokuro_title_lang") == "romaji"
                                end,
                                callback = function()
                                    G_reader_settings:saveSetting("mokuro_title_lang", "romaji")
                                end,
                            },
                            {
                                text = _("Folder / Original"),
                                checked_func = function()
                                    return G_reader_settings:readSetting("mokuro_title_lang") == "folder"
                                end,
                                callback = function()
                                    G_reader_settings:saveSetting("mokuro_title_lang", "folder")
                                end,
                            },
                        },
                    },
                    {
                        text = _("Server URL"),
                        callback = function()
                            local MokuroCatalogViewer = require("mokurocatalogviewer")
                            MokuroCatalogViewer:changeServerUrl()
                        end,
                    },
                    {
                        text = _("Refresh / Clear Catalog Cache"),
                        callback = function()
                            local MokuroCatalog = require("mokurocatalog")
                            MokuroCatalog:clearCache()
                            UIManager:show(InfoMessage:new{
                                text = _("Catalog cache cleared. It will be refreshed on next browse."),
                            })
                        end,
                    },
                },
            },
            {
                text = _("Enable Mokuro"),
                checked_func = function()
                    return self.enabled
                end,
                callback = function()
                    self.enabled = not self.enabled
                    UIManager:show(InfoMessage:new{
                        text = self.enabled and _("Mokuro enabled") or _("Mokuro disabled"),
                    })
                end,
            },
            {
                text = _("Font Size"),
                sub_item_table = {
                    {
                        text = _("Medium (32)"),
                        checked_func = function()
                            return G_reader_settings:readSetting("mokuro_font_size") == 32
                        end,
                        callback = function()
                            G_reader_settings:saveSetting("mokuro_font_size", 32)
                        end,
                    },
                    {
                        text = _("Large (48) - Default"),
                        checked_func = function()
                            local size = G_reader_settings:readSetting("mokuro_font_size")
                            return size == 48 or size == nil  -- Default
                        end,
                        callback = function()
                            G_reader_settings:saveSetting("mokuro_font_size", 48)
                        end,
                    },
                    {
                        text = _("Extra Large (64)"),
                        checked_func = function()
                            return G_reader_settings:readSetting("mokuro_font_size") == 64
                        end,
                        callback = function()
                            G_reader_settings:saveSetting("mokuro_font_size", 64)
                        end,
                    },
                    {
                        text = _("Huge (80)"),
                        checked_func = function()
                            return G_reader_settings:readSetting("mokuro_font_size") == 80
                        end,
                        callback = function()
                            G_reader_settings:saveSetting("mokuro_font_size", 80)
                        end,
                    },
                },
            },
            {
                text = _("Status"),
                callback = function()
                    local msg = self.mokuro_data and 
                        string.format(_("Loaded: %d pages"), #self.mokuro_data.pages) or
                        _("No mokuro data loaded")
                    UIManager:show(InfoMessage:new{
                        text = msg,
                    })
                end,
            },
            {
                text = _("About"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _([[Mokuro Reader adds support for manga processed with mokuro OCR.

Tap on text bubbles to see the OCR'd text in a popup at the bottom.

Hold and drag your finger to select text, then release to look it up in your dictionaries.
For Japanese: Spaces between characters are automatically removed for proper dictionary lookup!

NEW: Sentence mining support! When you add words to VocabBuilder, the surrounding text from the bubble is saved as context.

Font size can be adjusted in the Mokuro Reader menu.]]),
                        timeout = 10,
                    })
                end,
            },
        },
    }
end

function MokuroReader:onCloseDocument()
    self.mokuro_data = nil
    self.current_page = nil
    if self.mokuro_popup then
        UIManager:close(self.mokuro_popup)
        self.mokuro_popup = nil
    end
end

logger.info("MokuroReader: Module loaded successfully")

return MokuroReader
