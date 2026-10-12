-- Offline stand-ins for a font string's font (Architecture/20261011-Phase18.md
-- section 11.1).
--
-- Until Phase 18 nothing read or wrote a font, so stubs8's newRegion returned a
-- no-op for GetFont -- which answers nil, so the outline silently fell back in
-- every session. That is exactly the shape of defect section 2 is about, so the
-- font has to be a real, controllable thing here.
--
-- Three knobs, because the design has three distinct failure arms and they behave
-- differently:
--
--   HARNESS.fontFileMode  "plain"  GetFont answers a usable file name
--                         "nil"    GetFont answers nil, which the docs permit
--                                  (fontFile is Nilable) and which SetFont would
--                                  refuse via RequiresValidFontAsset
--                         "secret" GetFont answers a withheld value
--                         "raise"  GetFont raises
--   HARNESS.setFontResult   what SetFont RETURNS. false is a refusal that does
--                           not raise, which is how the real call reports a gate
--                           refusal or a tainted caller
--   HARNESS.setFontRaises   SetFont raises instead of returning

-- No backslash in the stub's font name on purpose: the real path has them, this
-- does not need them, and a half-escaped path is its own class of silent bug
-- (Phase 17 found one in QUEST_MARKER_TEXTURE).
HARNESS.fontFile = "FrizQuadrataTT"
HARNESS.fontFileMode = "plain"
HARNESS.setFontResult = true
HARNESS.setFontRaises = false

-- Every SetFont this session saw, so a check can assert the arguments rather than
-- just the outcome.
HARNESS.setFontCalls = {}

local function resetFontState()
    HARNESS.fontFileMode = "plain"
    HARNESS.setFontResult = true
    HARNESS.setFontRaises = false
    HARNESS.setFontCalls = {}
end
HARNESS.resetFontState = resetFontState

-- Wraps whatever CreateFontString the earlier stub files left in place, so this
-- file composes with stubs11's SetFormattedText rather than replacing it.
local function wrapFontString(region)
    rawset(region, "GetFont", function(self)
        if HARNESS.fontFileMode == "raise" then
            error("GetFont refused")
        end
        if HARNESS.fontFileMode == "nil" then
            return nil, self.fontHeight or 10, self.fontFlags
        end
        if HARNESS.fontFileMode == "secret" then
            return HARNESS.SECRET, self.fontHeight or 10, self.fontFlags
        end
        return HARNESS.fontFile, self.fontHeight or 10, self.fontFlags
    end)
    rawset(region, "SetFont", function(self, file, height, flags)
        HARNESS.setFontCalls[#HARNESS.setFontCalls + 1] = {
            region = self, file = file, height = height, flags = flags,
        }
        if HARNESS.setFontRaises then
            error("SetFont refused")
        end
        if HARNESS.setFontResult ~= true then
            return HARNESS.setFontResult
        end
        self.fontFile, self.fontHeight, self.fontFlags = file, height, flags
        return true
    end)
    return region
end

local function install(target)
    local inner = target.CreateFontString
    rawset(target, "CreateFontString", function(self, ...)
        return wrapFontString(inner(self, ...))
    end)
end

-- CreateFrame is already wrapped by stubs11; wrap the frames it yields.
local createFrame = CreateFrame
function CreateFrame(...)
    local frame = createFrame(...)
    install(frame)
    return frame
end

-- UIParent and anything else already built before this file ran.
for _, frame in ipairs(HARNESS.frames or {}) do
    install(frame)
end
if UIParent then
    install(UIParent)
end
