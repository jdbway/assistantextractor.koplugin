-- Finds assistant.koplugin's notebook markdown files and turns new entries
-- into Extractor Records.
--
-- This module only reads files assistant.koplugin already writes -- it never
-- requires assistant.koplugin's plugin code to be loaded, only that its
-- notebook files exist on disk, same reasoning as the VocabDeck extractor.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local FSWalk = require("fs_walk")
local NotebookParser = require("notebook_parser")
local State = require("extraction_state")

local Extractor = {}

local ASSISTANT_SETTINGS_FILE = DataStorage:getSettingsDir() .. "/assistant.lua"
local ASSISTANT_CONFIG_FILE = ffiUtil.joinPath(DataStorage:getDataDir(), "plugins/assistant.koplugin/configuration.lua")

-- Every field here comes from a notebook entry that, once written, never
-- changes -- see notebook_parser.lua's header comment. write_once for
-- everything is correct, not a simplification: there is no "latest value"
-- to prefer, because there is only ever one value.
local FIELD_POLICY = {
    timestamp = "write_once",
    page_info = "write_once",
    title = "write_once",
    body = "write_once",
    source_file = "write_once",
}
Extractor.FIELD_POLICY = FIELD_POLICY

local function readAssistantSettings()
    local ok, result = pcall(LuaSettings.open, LuaSettings, ASSISTANT_SETTINGS_FILE)
    if not ok then return nil end
    return result
end

-- configuration.lua is a private, gitignored file (same pattern as
-- VocabDeck's vocabdeck_configuration.lua) -- may not exist at all.
local function readAssistantConfig()
    if lfs.attributes(ASSISTANT_CONFIG_FILE, "mode") ~= "file" then
        return nil
    end
    local ok, result = pcall(dofile, ASSISTANT_CONFIG_FILE)
    if not ok or type(result) ~= "table" then return nil end
    return result
end

-- Mirrors assistant_notebook.lua's getCurrentBaseDirectory(), minus the
-- file_chooser/UI fallbacks that only make sense for the live "create a new
-- notebook" flow -- this runs headless, not from an open reader UI.
local function getBaseDir(config)
    local default_folder = config and config.features and config.features.default_folder_for_logs
    if default_folder and default_folder ~= "" and lfs.attributes(default_folder, "mode") == "directory" then
        return default_folder
    end
    local home_dir = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home_dir and home_dir ~= "" and lfs.attributes(home_dir, "mode") == "directory" then
        return home_dir
    end
    return DataStorage:getDataDir()
end

-- Per-book notebooks default to sitting right next to their book (KOReader
-- core's BookInfo:getNotebookFile() resolves to the book's own doc_path plus
-- an extension unless overridden), wherever that book happens to live --
-- there's no single folder to check the way general notebooks have one.
-- Rather than resolving each book's doc_settings to find its exact notebook
-- path, this walks the filesystem for .md files and confirms each one is
-- actually a notebook by content (starts with the "# [" entry header
-- notebook_parser.lua also keys on), not by guessing at library layout.
--
-- Skips dot-directories, any *.sdr folder (KOReader's per-document settings
-- sidecar -- never contains notebook content itself), and, only when
-- falling back to the broad DataStorage root (home_dir unset), a few of
-- KOReader's own known internal subfolders that are large and never hold
-- user content.
local WALK_SKIP_SUFFIXES = { ".sdr" }
local WALK_SKIP_ROOT_SUBDIRS = { frontend = true, l10n = true, resources = true, fonts = true, base = true, rocks = true, spec = true }

local function looksLikeNotebook(path)
    if path:lower():sub(-3) ~= ".md" then return false end
    local file = io.open(path, "r")
    if not file then return false end
    local head = file:read(64) or ""
    file:close()
    return head:match("^%s*# %[") ~= nil
end

local function makeSkipDirFn(is_root_fallback_dir)
    return function(name)
        if name:sub(1, 1) == "." then return true end
        for _, suffix in ipairs(WALK_SKIP_SUFFIXES) do
            if name:sub(-#suffix) == suffix then return true end
        end
        return is_root_fallback_dir and WALK_SKIP_ROOT_SUBDIRS[name] or false
    end
end

-- Every fixed, always-cheap-to-check location: the general-notebooks folder
-- (configured or default), its legacy single-file predecessor, and the
-- default_folder_for_logs redirect target if configured.
local function listFixedLocationFiles(settings, config, base_dir)
    local files = {}
    local seen = {}
    local function addFile(path)
        if path and not seen[path] and lfs.attributes(path, "mode") == "file" then
            seen[path] = true
            files[#files + 1] = path
        end
    end
    local function addDir(dir)
        if not dir or lfs.attributes(dir, "mode") ~= "directory" then return end
        for name in lfs.dir(dir) do
            if name:lower():sub(-3) == ".md" then
                addFile(ffiUtil.joinPath(dir, name))
            end
        end
    end

    local configured_folder = settings and settings:readSetting("general_notebooks_folder")
    if configured_folder and configured_folder ~= "" then
        addDir(configured_folder)
    else
        addDir(ffiUtil.joinPath(base_dir, "general_notebooks"))
    end
    addFile(ffiUtil.joinPath(base_dir, "general_notebook.md")) -- legacy, pre-multi-notebook

    local default_folder = config and config.features and config.features.default_folder_for_logs
    if default_folder and default_folder ~= "" then
        addDir(default_folder)
    end
    return files
end

-- The filesystem walk is the expensive part -- its result is cached in
-- extraction_state.lua and only redone when explicitly asked (the "Rescan
-- for notebooks" debug action, or force=true), not on every extraction.
-- The fixed-location check above is always redone fresh regardless, since
-- it's a handful of specific paths, not a walk.
function Extractor.listNotebookFiles(force_rescan)
    local settings = readAssistantSettings()
    local config = readAssistantConfig()
    local base_dir = getBaseDir(config)

    local files = listFixedLocationFiles(settings, config, base_dir)
    local seen = {}
    for _, path in ipairs(files) do seen[path] = true end

    local cached = State.getDiscoveredFiles()
    if cached and not force_rescan then
        for _, path in ipairs(cached) do
            if not seen[path] and lfs.attributes(path, "mode") == "file" then
                seen[path] = true
                files[#files + 1] = path
            end
        end
        return files
    end

    local home_dir = G_reader_settings and G_reader_settings:readSetting("home_dir")
    local walk_root = (home_dir and home_dir ~= "" and lfs.attributes(home_dir, "mode") == "directory")
        and home_dir or DataStorage:getDataDir()
    local root_is_fallback = walk_root ~= home_dir

    local found = FSWalk.find(walk_root, looksLikeNotebook, makeSkipDirFn(root_is_fallback))
    State.saveDiscoveredFiles(found)

    for _, path in ipairs(found) do
        if not seen[path] then
            seen[path] = true
            files[#files + 1] = path
        end
    end
    return files
end

-- `known_keys` stores each entry's full fields table, not just a seen-flag
-- -- cheap for text this size, and it's what lets `want_all` reconstruct the
-- complete picture (including entries from a previous run) without
-- re-reading files that haven't changed.
--
-- By default returns only entries new since the last extraction (what an
-- actual push to AnnotationSync should send). Pass want_all=true to get
-- every known entry instead, including previously-extracted ones -- what
-- "Dump extraction to file" uses, since a debug/inspection tool should show
-- the whole current picture, not just today's delta.
function Extractor.extractFile(path, want_all)
    local attr = lfs.attributes(path)
    if not attr then
        return {}, "File not found: " .. tostring(path)
    end
    local size = attr.size or 0

    local state = State.forFile(path)
    if state.size == size then
        if not want_all then
            return {} -- append-only: unchanged size means nothing new
        end
        local all_records = {}
        for key, fields in pairs(state.known_keys or {}) do
            all_records[#all_records + 1] = { merge_key = key, fields = fields }
        end
        return all_records
    end

    local file = io.open(path, "r")
    if not file then
        return {}, "Could not open: " .. tostring(path)
    end
    local content = file:read("*a")
    file:close()

    local filename = path:match("([^/\\]+)$") or path
    local entries = NotebookParser.parse(content, filename)

    local known_keys = state.known_keys or {}
    local new_records, all_records = {}, {}
    for _, entry in ipairs(entries) do
        local fields = known_keys[entry.merge_key]
        local is_new = fields == nil
        if is_new then
            fields = {}
            for name, policy in pairs(FIELD_POLICY) do
                fields[name] = {
                    value = entry[name],
                    policy = policy,
                    changed_at = entry.timestamp or os.time(),
                }
            end
            known_keys[entry.merge_key] = fields
        end
        local record = { merge_key = entry.merge_key, fields = fields }
        if is_new then new_records[#new_records + 1] = record end
        all_records[#all_records + 1] = record
    end

    State.saveForFile(path, { size = size, known_keys = known_keys })
    return want_all and all_records or new_records
end

-- Extracts every discoverable notebook file. Returns { [filename] = records }.
-- force_rescan bypasses the cached filesystem-walk result (see
-- listNotebookFiles) to pick up newly-added books' notebooks. want_all is
-- passed straight through to extractFile -- see its comment.
function Extractor.extractAll(force_rescan, want_all)
    local by_file = {}
    for _, path in ipairs(Extractor.listNotebookFiles(force_rescan)) do
        local filename = path:match("([^/\\]+)$") or path
        local records, err = Extractor.extractFile(path, want_all)
        if err then
            by_file[filename] = { error = err }
        else
            by_file[filename] = records
        end
    end
    State.flush()
    return by_file
end

return Extractor
