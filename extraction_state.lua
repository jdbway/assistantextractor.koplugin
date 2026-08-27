-- Tracks, per notebook file, how much of it has already been extracted.
--
-- Unlike VocabDeck's cards, notebook entries are append-only and never
-- mutate once written -- there's no per-field diffing question here, only
-- "have I already emitted this entry." State per file is just the file size
-- last seen (a cheap gate: unchanged size means nothing new, since nothing
-- ever shrinks or rewrites an append-only file) and the set of merge keys
-- already emitted (so a full re-parse after a real change only yields the
-- genuinely new entries).
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local STATE_FILE = DataStorage:getSettingsDir() .. "/assistantextractor_state.lua"

local State = {}

local settings

local function ensureOpen()
    if not settings then
        settings = LuaSettings:open(STATE_FILE)
    end
    return settings
end

function State.forFile(path)
    return ensureOpen():readSetting(path) or { size = 0, known_keys = {} }
end

function State.saveForFile(path, file_state)
    ensureOpen():saveSetting(path, file_state)
end

-- Cache of what the (expensive) filesystem walk found last time, so it only
-- needs to run again on an explicit rescan, not on every extraction. Stored
-- under its own key so it can't collide with a real notebook file path.
local DISCOVERED_FILES_KEY = "_discovered_files"

function State.getDiscoveredFiles()
    return ensureOpen():readSetting(DISCOVERED_FILES_KEY)
end

function State.saveDiscoveredFiles(paths)
    ensureOpen():saveSetting(DISCOVERED_FILES_KEY, paths)
end

function State.flush()
    if settings then
        settings:flush()
    end
end

return State
