-- Splits one of assistant.koplugin's notebook markdown files into its
-- individual entries.
--
-- Every entry assistant.koplugin writes (assistant_quicknote.lua,
-- assistant_viewer.lua's saveToNotebook) has the same shape:
--   # [YYYY-MM-DD HH:MM:SS]<page info>
--   ## <title>
--
--   <body, may itself contain markdown -- headings, blockquotes, bold>
--
-- Entries are pure content otherwise -- no other delimiter, no per-entry id
-- beyond the timestamp baked into the heading. Markdown inside the body
-- (blockquoted highlighted text, bold, etc.) is preserved verbatim rather
-- than stripped or re-parsed into sub-fields: the point is round-tripping
-- exactly what a future renderer needs, not restructuring it here.
local Parser = {}

-- Finds every line starting with "# [" -- the one delimiter these files
-- reliably use to separate entries. Anchored to true line starts (position 1
-- or right after a "\n") so a note's own body text can't accidentally look
-- like a new entry unless it independently reproduces that exact line start.
local function findEntryStarts(content)
    local starts = {}
    local pos = 1
    while true do
        local s = content:find("# %[", pos, false)
        if not s then break end
        if s == 1 or content:sub(s - 1, s - 1) == "\n" then
            starts[#starts + 1] = s
        end
        pos = s + 1
    end
    return starts
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Local time, matching os.date("%Y-%m-%d %H:%M:%S") (no "!" prefix) used to
-- write these headers -- fine as an ordering/identity aid on the same
-- device's own clock, not meant as an authoritative cross-timezone value.
local function parseTimestamp(str)
    local year, month, day, hour, min, sec =
        str:match("(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)")
    if not year then return nil end
    return os.time{
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    }
end

-- Parses one already-isolated entry block (from one "# [" line up to just
-- before the next one, or end of file). Returns nil if it doesn't actually
-- match the expected header shape (defensive -- a genuinely malformed or
-- hand-edited file shouldn't crash extraction, just skip that block).
local function parseEntry(raw, source_file)
    local first_line, rest = raw:match("^([^\n]*)\n?(.*)$")
    first_line = first_line or ""
    rest = rest or ""

    local timestamp_str, page_info = first_line:match("^# %[(.-)%](.*)$")
    if not timestamp_str then return nil end
    local timestamp = parseTimestamp(timestamp_str)
    if not timestamp then return nil end

    local title, body = rest:match("^%s*## ([^\n]*)\n?(.*)$")

    local entry = {
        timestamp = timestamp,
        page_info = trim(page_info or ""),
        title = trim(title or ""),
        body = trim(body or rest), -- fall back to the whole remainder if no "## " line was found
        source_file = source_file,
    }
    -- Same-second saves are rare but possible; body length is a cheap,
    -- dependency-free disambiguator (no hash library needed for this).
    -- Only needs to be unique within this one file's push, not globally --
    -- see ARCHITECTURE.md on why cross-extractor/cross-file uniqueness
    -- isn't required here.
    entry.merge_key = timestamp_str .. "#" .. tostring(#entry.body)
    return entry
end

-- Returns a list of entries, in file order. `source_file` is attached to
-- every entry as-is (a plain filename, not a full path) for display context.
function Parser.parse(content, source_file)
    if type(content) ~= "string" or content == "" then
        return {}
    end
    local starts = findEntryStarts(content)
    local entries = {}
    for i, s in ipairs(starts) do
        local e = (starts[i + 1] or (#content + 1)) - 1
        local raw = trim(content:sub(s, e))
        local entry = parseEntry(raw, source_file)
        if entry then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

return Parser
