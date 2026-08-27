-- Assistant Extractor plugin entry point.
--
-- Second Extractor built against AnnotationSync's Extractor interface (see
-- AnnotationSync.koplugin#93 and its docs/writing-an-extractor.md; the first
-- is vocabdeckextractor.koplugin). Reads assistant.koplugin's notebook
-- markdown files directly -- see extractor_assistant.lua and ARCHITECTURE.md
-- for how and why.
--
-- Status: extraction, the sync-event hook, and the real pushExtractorData
-- call are all live. writeback_fn (appending merged-in entries this device
-- hasn't seen yet -- the only way a note written on another device shows up
-- here) is still a stub -- see stubWriteback() below.
local _ = require("gettext")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local dump = require("dump")
local PluginShare = require("pluginshare")

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

-- Not built yet -- next task. pushExtractorData always calls this, whether
-- or not anything changed, so it's safe to call unconditionally; it just
-- doesn't persist anything into the notebook file yet. The real version
-- needs to: for any entry in merged_records not already in this file (by
-- merge_key), append it -- that's the only way a note written on another
-- device shows up here. Every field is write_once, so there's no per-field
-- merging to do on entries this device already has.
local function stubWriteback(filename, merged_records)
    logger.info("assistantextractor: writeback stub for", filename,
        "-- got", #merged_records, "merged record(s), not yet persisted")
end

-- One pushExtractorData call per notebook file, matching this Extractor's
-- <extractor_id>/<filename> namespacing.
function AssistantExtractor:pushFile(path)
    local records, err = Extractor.extractFile(path)
    local filename = path:match("([^/\\]+)$") or path
    if err then
        logger.warn("assistantextractor: extraction failed for", filename, "--", err)
        return
    end
    PluginShare.AnnotationSync.pushExtractorData("assistant", filename, records, function(merged_records)
        stubWriteback(filename, merged_records)
    end)
end

function AssistantExtractor:pushAll()
    for _, path in ipairs(Extractor.listNotebookFiles()) do
        self:pushFile(path)
    end
end

-- AnnotationSyncRequested fires once per sync episode (manual "Sync Now" or
-- a background reconnect), not per document -- correct here, since notebook
-- entries aren't scoped to any one open book at sync time.
function AssistantExtractor:onAnnotationSyncRequested()
    if not PluginShare.AnnotationSync then return end
    self:pushAll()
end

-- Manual trigger, kept alongside the automatic event hook above -- useful
-- for testing without waiting for a real sync episode.
function AssistantExtractor:onPushToAnnotationSync()
    if not PluginShare.AnnotationSync then
        UIManager:show(InfoMessage:new{
            text = _("AnnotationSync isn't installed or enabled."),
            timeout = 4,
        })
        return
    end
    self:pushAll()
    UIManager:show(InfoMessage:new{
        text = _("Push started. writeback isn't implemented yet, so nothing will be written back locally -- check the log for what came back."),
        timeout = 6,
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
