-- Assistant Extractor plugin entry point.
--
-- Second Extractor built against the design proposed in
-- AnnotationSync.koplugin#93 (the first is vocabdeckextractor.koplugin).
-- Reads assistant.koplugin's notebook markdown files directly -- see
-- extractor_assistant.lua and ARCHITECTURE.md for how and why.
--
-- Status: extraction is real and testable today. The push-to-AnnotationSync
-- half is a stub for the same reason as the VocabDeck extractor: that
-- interface doesn't exist in AnnotationSync's code yet. See
-- onPushToAnnotationSync() below.
local _ = require("gettext")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local dump = require("dump")

local Extractor = require("extractor_assistant")

local AssistantExtractor = InputContainer:extend{
    name = "assistantextractor",
    is_doc_only = false,
}

local ASSISTANT_PLUGIN_DIR = ffiUtil.joinPath(DataStorage:getDataDir(), "plugins/assistant.koplugin")

-- A cheap presence check, not a data-discovery walk -- listNotebookFiles()
-- can trigger a full filesystem scan on first use (see
-- extractor_assistant.lua), which is too expensive to run just to decide
-- whether to show a menu entry, since KOReader rebuilds this menu often.
local function assistantPluginInstalled()
    return lfs.attributes(ASSISTANT_PLUGIN_DIR, "mode") == "directory"
end

local function summarize(by_file)
    local lines = {}
    local total_new, total_errors = 0, 0
    for filename, records in pairs(by_file) do
        if records.error then
            lines[#lines + 1] = string.format("%s: error -- %s", filename, records.error)
            total_errors = total_errors + 1
        elseif #records > 0 then
            lines[#lines + 1] = string.format("%s: %d new entr%s", filename, #records, #records == 1 and "y" or "ies")
            total_new = total_new + #records
        end
    end
    table.sort(lines)
    local file_count = 0
    for _ in pairs(by_file) do file_count = file_count + 1 end
    table.insert(lines, 1, string.format("%d new entries across %d notebook file(s)%s",
        total_new, file_count, total_errors > 0 and (", " .. total_errors .. " error(s)") or ""))
    if #lines == 1 then
        lines[#lines + 1] = "(nothing new since last extraction)"
    end
    return table.concat(lines, "\n")
end

function AssistantExtractor:runExtractionDebug()
    local ok, by_file = pcall(Extractor.extractAll)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Extraction failed:\n%s"), tostring(by_file)),
            timeout = 6,
        })
        return
    end
    UIManager:show(InfoMessage:new{ text = summarize(by_file), timeout = 8 })
end

-- The cached filesystem walk (extractor_assistant.lua) won't notice a
-- notebook for a newly-added book on its own -- this forces a fresh scan.
function AssistantExtractor:rescanAndExtract()
    local ok, by_file = pcall(Extractor.extractAll, true)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Rescan failed:\n%s"), tostring(by_file)),
            timeout = 6,
        })
        return
    end
    UIManager:show(InfoMessage:new{ text = summarize(by_file), timeout = 8 })
end

-- Shows every known entry, not just what's new since the last run -- see
-- extractor_assistant.lua's extractFile() comment on want_all.
function AssistantExtractor:dumpExtractionToFile()
    local ok, by_file = pcall(Extractor.extractAll, false, true)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Extraction failed:\n%s"), tostring(by_file)),
            timeout = 6,
        })
        return
    end
    local path = DataStorage:getDataDir() .. "/assistantextractor_dump.lua"
    local file = io.open(path, "w")
    if not file then
        UIManager:show(InfoMessage:new{ text = _("Could not open dump file for writing."), timeout = 4 })
        return
    end
    file:write("return ", dump(by_file), "\n")
    file:close()
    UIManager:show(InfoMessage:new{
        text = string.format(_("Wrote extraction dump to:\n%s"), path),
        timeout = 6,
    })
end

-- See the header comment -- deferred until AnnotationSync's side of the
-- interface exists.
function AssistantExtractor:onPushToAnnotationSync()
    UIManager:show(InfoMessage:new{
        text = _("Not implemented yet: AnnotationSync doesn't have a pushExtractorData interface to call. See AnnotationSync.koplugin issue #93."),
        timeout = 5,
    })
end

function AssistantExtractor:addToMainMenu(menu_items)
    if not assistantPluginInstalled() then
        return
    end
    menu_items.assistantextractor = {
        sorting_hint = "tools",
        text = _("Assistant Extractor"),
        sub_item_table = {
            {
                text = _("Extract now (debug)"),
                keep_menu_open = true,
                callback = function() self:runExtractionDebug() end,
            },
            {
                text = _("Rescan for notebooks (debug)"),
                keep_menu_open = true,
                callback = function() self:rescanAndExtract() end,
            },
            {
                text = _("Dump extraction to file (debug)"),
                keep_menu_open = true,
                callback = function() self:dumpExtractionToFile() end,
            },
            {
                text = _("Push to AnnotationSync"),
                keep_menu_open = true,
                callback = function() self:onPushToAnnotationSync() end,
            },
        },
    }
end

function AssistantExtractor:init()
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

return AssistantExtractor
