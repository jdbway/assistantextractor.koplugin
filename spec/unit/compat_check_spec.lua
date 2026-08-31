-- Behavioral compatibility test.
--
-- Unlike a source-diff check (does upstream's FILE still look the same?),
-- this constructs a real KOReader ReaderUI against a real test document,
-- constructs the REAL upstream assistant.koplugin plugin instance pointed
-- at it, and calls its REAL QuickNote:saveNote() the way a user's tap would
-- -- through the actual object graph (self.assistant.ui.bookinfo,
-- self.assistant.ui.doc_settings, etc.), not a hand-rolled stub of it. Then
-- it runs this extractor's own Extractor.extractFile() against the real
-- notebook file that produced, and asserts the note round-trips.
--
-- Pattern lifted from dani84bs/AnnotationSync.koplugin's own
-- spec/unit/test_utils.lua (real ReaderUI + real DocumentRegistry, no
-- Xvfb, no display -- KOReader's own "front" test mode via
-- require("commonrequire") provides an emulated Device/Screen backend for
-- exactly this). Faking the object graph ourselves instead would just
-- relocate the original problem (silent, undetected drift) into our own
-- stub rather than fixing it -- if upstream changes what it reads off
-- `ui`, a hand-rolled fake keeps passing right through that change.
--
-- Run via KOReader's own test runner: `./kodev test front compat_check`
-- from the koreader_core checkout, with this repo and a fresh clone of
-- assistant.koplugin both present under koreader_core/plugins/. See
-- .github/workflows/check-upstream-compat.yml for the full setup.

describe("assistantextractor compatibility", function()
    local DataStorage, ReaderUI, DocumentRegistry, Geom, UIManager
    local QuickNoteModule, Extractor
    local readerui, assistant_instance, quicknote
    local test_data_dir = (os.getenv("PWD") or ".") .. "/test_assistantextractor_compat_tmp"
    local old_getDataDir
    local sample_epub

    setup(function()
        require("commonrequire")

        -- Both plugin directories go on package.path so their sibling
        -- modules resolve via bare require() the same way they would when
        -- KOReader's PluginLoader loads them for real.
        --
        -- Order here is NOT cosmetic. Both plugins ship a main.lua, and
        -- Lua's require() resolves against package.path in order and
        -- caches by the module name string, not the resolved path (the
        -- same _meta.lua collision documented in this repo's own README).
        -- assistant.koplugin's directory MUST come first: require("main")
        -- below needs to resolve to the real Assistant plugin class, not
        -- this extractor's own main.lua. Getting this backwards was a real
        -- bug caught live: with the order reversed, require("main") silently
        -- returned this extractor's own AssistantExtractor class instead,
        -- so assistant_instance:init() ran the wrong init() entirely (one
        -- that never sets self.config), and the failure surfaced several
        -- calls later as "attempt to index field 'config' (a nil value)"
        -- deep inside upstream's real saveToNotebookFile -- a confusing
        -- symptom for what was actually a test-setup mistake, not a real
        -- upstream incompatibility.
        package.path = "plugins/assistant.koplugin/?.lua;plugins/assistantextractor.koplugin/?.lua;" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))

        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        DocumentRegistry = require("document/documentregistry")
        UIManager = require("ui/uimanager")
        DataStorage = require("datastorage")

        old_getDataDir = DataStorage.getDataDir
        DataStorage.getDataDir = function() return test_data_dir end
        os.execute("mkdir -p " .. test_data_dir)

        sample_epub = test_data_dir .. "/compat_check.epub"
        require("ffi/util").copyFile("spec/front/unit/data/juliet.epub", sample_epub)

        local AssistantPlugin = require("main") -- assistant.koplugin's real plugin class
        QuickNoteModule = require("assistant_quicknote")
        Extractor = require("extractor_assistant")

        readerui = ReaderUI:new{
            dimen = Geom:new{ w = 1200, h = 1600 },
            document = DocumentRegistry:openDocument(sample_epub),
        }

        assistant_instance = AssistantPlugin:new{ ui = readerui }
        -- Narrow, mechanical mock matching test_utils.lua's own pattern --
        -- avoids a real menu-registration side effect during init, doesn't
        -- touch any business logic.
        local old_register = readerui.menu.registerToMainMenu
        readerui.menu.registerToMainMenu = function() end
        assistant_instance:init()
        readerui.menu.registerToMainMenu = old_register

        quicknote = QuickNoteModule:new(assistant_instance)
    end)

    teardown(function()
        if readerui then readerui:onClose() end
        if old_getDataDir then DataStorage.getDataDir = old_getDataDir end
        os.execute("rm -rf " .. test_data_dir)
        UIManager:quit()
        package.loaded["main"] = nil
        package.loaded["assistant_quicknote"] = nil
        package.loaded["extractor_assistant"] = nil
    end)

    it("round-trips a quick note through upstream's real save path and this extractor's parser", function()
        local NOTE_TEXT = "compat-check note body"
        local HIGHLIGHT_TEXT = "compat-check highlighted passage"

        -- The real save call -- same function a real "Quick Note" tap runs,
        -- with a real ui/document/doc_settings/bookinfo behind self.assistant.
        quicknote:saveNote(NOTE_TEXT, HIGHLIGHT_TEXT)

        -- Ask upstream's own real code where it just wrote the note, rather
        -- than assuming a path -- exercises the same accessor
        -- saveToNotebookFile() itself uses.
        local notebookfile = readerui.bookinfo:getNotebookFile(readerui.doc_settings)
        assert.is_not_nil(notebookfile)

        local records, err = Extractor.extractFile(notebookfile, true)
        assert.is_nil(err)
        assert.are.equal(1, #records)

        local fields = records[1].fields
        assert.is_not_nil(fields.body)
        assert.is_not_nil(fields.body.value:find(NOTE_TEXT, 1, true))
        assert.is_not_nil(fields.body.value:find(HIGHLIGHT_TEXT, 1, true))
        assert.is_not_nil(fields.title)
        assert.is_true(#fields.title.value > 0)
        assert.is_not_nil(fields.timestamp)
        assert.is_not_nil(fields.timestamp.value)
    end)
end)
