local _ = require("gettext")
return {
    name = "assistantextractor",
    fullname = _("Assistant Extractor"),
    description = _([[Reads assistant.koplugin's notebook markdown files and prepares them for cross-device sync via AnnotationSync's Extractor interface. Requires assistant.koplugin to be installed.]]),
    -- Bump on every functionally meaningful change -- lets a deployed copy's
    -- version be checked with one grep (main.lua logs it at init) instead of
    -- diffing every file against the repo. 1.0.0 = first version with a real
    -- writeback implementation (previously extraction/push only).
    version = "1.0.0",
}
