-- Applies AnnotationSync's merged notebook records back into the real
-- notebook file -- the other half of extractor_assistant's read pipeline.
-- Every field here is write_once and entries are append-only (see
-- ARCHITECTURE.md), so there's no update-in-place case: an entry either
-- already exists locally (skip it) or it doesn't (append it).
local lfs = require("libs/libkoreader-lfs")

local State = require("extraction_state")

local Writeback = {}

-- Matches assistant_viewer.lua's ChatGPTViewer:saveToNotebook() /
-- assistant_quicknote.lua's own log_entry format
-- (string.format("# [%s]%s\n## %s\n\n%s\n\n", timestamp, page_info, title, body)) --
-- close enough for notebook_parser.lua to re-parse into the exact same
-- timestamp/title/body/merge_key, which is what actually matters for
-- round-tripping; a leading "\n" is added defensively so the new entry
-- always starts at a true line boundary regardless of the file's existing
-- trailing whitespace, matching the parser's "# [" line-start anchor.
local function formatEntry(fields)
    local timestamp = fields.timestamp and fields.timestamp.value
    local page_info = (fields.page_info and fields.page_info.value) or ""
    local title = (fields.title and fields.title.value) or ""
    local body = (fields.body and fields.body.value) or ""
    local date_str = os.date("%Y-%m-%d %H:%M:%S", timestamp)
    return "\n# [" .. date_str .. "]" .. page_info .. "\n## " .. title .. "\n\n" .. body .. "\n\n"
end

-- Applies merged_records for one notebook file: appends any entry whose
-- merge_key isn't already known locally, then updates extraction_state.lua
-- so the next extraction pass doesn't treat these as new (they're already on
-- disk) and doesn't re-parse the whole file unnecessarily.
function Writeback.apply(path, merged_records)
    if not merged_records or #merged_records == 0 then return end

    local state = State.forFile(path)
    local known_keys = state.known_keys or {}

    local new_records = {}
    for _, record in ipairs(merged_records) do
        if not known_keys[record.merge_key] then
            new_records[#new_records + 1] = record
        end
    end
    if #new_records == 0 then return end

    local file = io.open(path, "a")
    if not file then return end
    for _, record in ipairs(new_records) do
        file:write(formatEntry(record.fields))
        known_keys[record.merge_key] = record.fields
    end
    file:close()

    local attr = lfs.attributes(path)
    State.saveForFile(path, { size = attr and attr.size or state.size, known_keys = known_keys })
end

return Writeback
