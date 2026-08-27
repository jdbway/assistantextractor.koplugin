local _ = require("gettext")
return {
    name = "assistantextractor",
    fullname = _("Assistant Extractor"),
    description = _([[Reads assistant.koplugin's notebook markdown files and prepares them for cross-device sync via AnnotationSync's Extractor interface. Requires assistant.koplugin to be installed.]]),
}
