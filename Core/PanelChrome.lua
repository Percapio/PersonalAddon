-- Core/PanelChrome.lua
-- The look of this addon's panels, in one place (Phase 8 section 4.2). Moved out
-- of the damage breakdown when the skills window became its second consumer: the
-- window has to look like the breakdown panel, and two copies of the border chain
-- would drift apart the first time either changed.
--
-- Every panel built here is parented to UIParent, never to a Blizzard frame.
-- SmartNavigation post-hooks CreateFrame and rebuilds a panel's navigation state,
-- in the caller's execution, when a new frame's parent chain reaches a panel it
-- tracks (Patch 01 section 0.2). A child of ours under a Blizzard panel would put
-- our taint there.

local ADDON_NAME, ns = ...

local PanelChrome = {}
ns.PanelChrome = PanelChrome

local format, pcall = string.format, pcall

-- Last resort: four thin edge textures we draw ourselves. Not an in-game border,
-- but it always works, and a visible edge beats none.
local function buildManualBorder(panel)
    local function edge(firstPoint, secondPoint, width, height)
        local texture = panel:CreateTexture(nil, "BORDER")
        if texture.SetColorTexture then
            texture:SetColorTexture(0.55, 0.55, 0.55, 0.9)
        else
            texture:SetTexture(0.55, 0.55, 0.55, 0.9)
        end
        texture:SetPoint(firstPoint, panel, firstPoint, 0, 0)
        texture:SetPoint(secondPoint, panel, secondPoint, 0, 0)
        if width then texture:SetWidth(width) end
        if height then texture:SetHeight(height) end
        return texture
    end

    panel.borderTop = edge("TOPLEFT", "TOPRIGHT", nil, 1)
    panel.borderBottom = edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    panel.borderLeft = edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    panel.borderRight = edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
end

-- Phase 4's first revision guarded this with `if panel.SetBackdrop then`, which on
-- this client is false -- so the border was skipped SILENTLY and no border appeared
-- with no message saying why. The guard was right; failing quietly was not.
--
-- SetBackdrop needs the frame to be created with BackdropTemplate on modern
-- clients, so the frame itself is created through a chain and the border through a
-- second one. Whichever works is reported by the owner's /pa command.
local FRAME_TEMPLATES = { "BackdropTemplate" }
local BORDER_TEMPLATES = {
    "TooltipBorderedFrameTemplate",
    "DialogBorderTemplate",
    "ThinBorderTemplate",
    "InsetFrameTemplate3",
}

local function createPanelFrame(frameName)
    for index = 1, #FRAME_TEMPLATES do
        local ok, frame = pcall(CreateFrame, "Frame", frameName,
            _G.UIParent, FRAME_TEMPLATES[index])
        if ok and frame then
            return frame, FRAME_TEMPLATES[index]
        end
    end
    return CreateFrame("Frame", frameName, _G.UIParent), nil
end

local function applyBorder(panel, ownerKey, ownerLabel)
    if panel.SetBackdrop then
        local ok = pcall(panel.SetBackdrop, panel, {
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        if ok then
            if panel.SetBackdropBorderColor then
                pcall(panel.SetBackdropBorderColor, panel, 1, 1, 1, 0.7)
            end
            return "backdrop"
        end
    end

    -- A bordered child frame stretched over the panel. This is how the client's own
    -- windows get their edges, so it is the closest thing to "any border currently
    -- in game". The child's parent is our panel, so SmartNavigation's CreateFrame
    -- hook finds no Blizzard panel above it.
    for index = 1, #BORDER_TEMPLATES do
        local ok, child = pcall(CreateFrame, "Frame", nil, panel, BORDER_TEMPLATES[index])
        if ok and child then
            local anchored = pcall(child.SetAllPoints, child, panel)
            if anchored then
                panel.borderFrame = child
                return BORDER_TEMPLATES[index]
            end
            pcall(child.Hide, child)
        end
    end

    buildManualBorder(panel)
    ns.Log.Once(ownerKey .. ":manualborder", format(
        "no in-game border template was available on this client; %s draws a plain edge instead",
        ownerLabel))
    return "manual"
end

-- Builds a panel frame styled as the damage breakdown panel is. The frame comes
-- back hidden and unanchored; the owner anchors it.
--
-- spec.frameName   global name, or nil
-- spec.width       width in pixels
-- spec.height      initial height in pixels
-- spec.alpha       background opacity, 0 to 1
-- spec.strata      frame strata, or nil to inherit UIParent's
-- spec.ownerKey    prefix for this panel's once-only notices
-- spec.ownerLabel  how a notice names the panel, e.g. "the breakdown panel"
--
-- Returns { frame, background, borderStyle }.
function PanelChrome.Build(spec)
    local panel, frameTemplate = createPanelFrame(spec.frameName)
    panel:SetWidth(spec.width)
    panel:SetHeight(spec.height)

    -- The strata to put back after the preview raises this panel (Phase 13
    -- section 3.3). A spec that names one gives us the literal; a spec that does
    -- not leaves the panel on whatever it inherits from UIParent, and UIParent is
    -- created in C++ so the export cannot tell us what that is. So it is read
    -- ONCE, here, from our own brand-new frame, before anything of ours has
    -- written it -- not read back later to recover a value we already had.
    --
    -- The read goes through ClientRead because GetFrameStrata is secret-capable
    -- in the docs, and Phase 12's review recorded that a hidden value marks the
    -- strata hidden. Withheld means "could not tell", so no literal is recorded
    -- and Restore falls back (rule 10).
    local baseStrata = spec.strata
    if baseStrata then
        panel:SetFrameStrata(baseStrata)
    else
        local kind, current = ns.ClientRead.Call(panel.GetFrameStrata, "string", panel)
        if kind == ns.ClientRead.PLAIN then
            baseStrata = current
        end
    end
    -- Never a mouse target: with no mouse and no buttons, the Gamepad UI's
    -- navigation has nothing to find in the panel.
    panel:EnableMouse(false)

    local background = panel:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(panel)
    if background.SetColorTexture then
        background:SetColorTexture(0, 0, 0, 1)
    else
        background:SetTexture(0, 0, 0, 1)
    end
    panel.background = background

    local borderStyle = applyBorder(panel, spec.ownerKey, spec.ownerLabel)
    if frameTemplate then
        borderStyle = borderStyle .. " via " .. frameTemplate
    end

    -- Opacity applies to the background texture alone. Setting it on the frame
    -- faded the rows, icons and border with it, so a readable panel and a subtle one
    -- were the same slider and could not both be had.
    panel:SetAlpha(1)
    background:SetAlpha(spec.alpha)
    panel:Hide()

    return {
        frame = panel,
        background = background,
        borderStyle = borderStyle,
        baseStrata = baseStrata,
    }
end

-- Raising a panel over Blizzard's Options window, and putting it back (Phase 13
-- section 3). Both write a fixed strata name and neither reads one: Phase 12's
-- patch review recorded that SetFrameStrata accepts hidden values only when
-- called untainted, and that a hidden value marks the strata hidden.
--
-- Returns false rather than raising, so one refused panel does not take the
-- others down with it.
function PanelChrome.Raise(frame)
    if not frame or type(frame.SetFrameStrata) ~= "function" then
        return false
    end
    return (pcall(frame.SetFrameStrata, frame, ns.PREVIEW_STRATA))
end

function PanelChrome.Restore(frame, baseStrata)
    if not frame or type(frame.SetFrameStrata) ~= "function" then
        return false
    end
    if type(baseStrata) ~= "string" or baseStrata == "" then
        -- Build could not read one. Leaving the panel raised would be worse than
        -- a guess, and MEDIUM is the client's own default for a frame with no
        -- strata of its own.
        baseStrata = "MEDIUM"
    end
    return (pcall(frame.SetFrameStrata, frame, baseStrata))
end

function PanelChrome.SetAlpha(chrome, alpha)
    if chrome and chrome.background then
        chrome.background:SetAlpha(alpha)
    end
end

-- Scales a panel and anchors it (Phase 12 section 4). A frame's anchor offsets are
-- measured in its own scaled units, so the offsets are divided by the scale: they
-- stay screen pixels, and the anchored corner stays put while the panel grows.
--
-- placement.scale     1 is the panel's natural size
-- placement.offsetX   pixels from the anchor point, at any scale
-- placement.offsetY   likewise
function PanelChrome.Place(panel, anchorFrame, panelPoint, anchorPoint, placement)
    local scale = placement.scale
    if type(scale) ~= "number" or scale <= 0 then
        scale = 1
    end
    panel:SetScale(scale)
    panel:ClearAllPoints()
    panel:SetPoint(panelPoint, anchorFrame, anchorPoint,
        placement.offsetX / scale, placement.offsetY / scale)
end
