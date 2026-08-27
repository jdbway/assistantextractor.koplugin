-- Bounded recursive directory walk.
--
-- Deliberately narrow: this is a generic "find files matching a predicate,
-- safely" utility, not a design for how Extractors should locate their data.
-- Different sources need genuinely different discovery strategies (this
-- plugin's own extractor_assistant.lua needs a walk at all only because
-- assistant.koplugin's per-book notebooks default to sitting next to their
-- book, wherever that is -- VocabDeck's extractor needed none of this, one
-- fixed directory was enough). Kept separate and this narrow so it can be
-- promoted into a shared suite-level utility later without redesigning it,
-- once a third extractor's needs actually show what else, if anything, is
-- common across them.
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local FSWalk = {}

-- @param root         directory to start from
-- @param match_fn     function(path) -> bool, called for every regular file found
-- @param skip_dir_fn  optional function(dirname) -> bool; true skips descending into it
-- @param file_limit   safety valve: stop after visiting this many entries total (default 20000)
-- @return matches (array of paths), visited_count
function FSWalk.find(root, match_fn, skip_dir_fn, file_limit)
    file_limit = file_limit or 20000
    local matches = {}

    local function walk(dir, visited)
        if visited >= file_limit then return visited end
        if not dir or lfs.attributes(dir, "mode") ~= "directory" then return visited end
        for name in lfs.dir(dir) do
            if visited >= file_limit then break end
            if name ~= "." and name ~= ".." then
                local path = ffiUtil.joinPath(dir, name)
                local mode = lfs.attributes(path, "mode")
                visited = visited + 1
                if mode == "directory" then
                    if not (skip_dir_fn and skip_dir_fn(name)) then
                        visited = walk(path, visited)
                    end
                elseif mode == "file" then
                    if match_fn(path) then
                        matches[#matches + 1] = path
                    end
                end
            end
        end
        return visited
    end

    local visited_count = walk(root, 0)
    return matches, visited_count
end

return FSWalk
