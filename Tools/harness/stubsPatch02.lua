-- Offline stand-ins for Patch 02 (Architecture/20261104-Patch02.md section 9.1).
--
-- Loaded by every session, like every stubs file, so everything here is inert until a
-- test turns it on:
--
--   HARNESS.questieShape          nil leaves stubs17's QuestieDB as it is, which is
--                                 1.0.6's shape: classKeys under
--                                 Enum.byExpansion.Forever and nothing published.
--                                 "1.0.10" is the live provider's shape (section 4.3):
--                                 Forever carries no classKeys and the rules flavour's
--                                 keys are published as Enum.classKeys. "none" leaves
--                                 neither; "enumNotTable" makes Enum a string.
--   HARNESS.setSourceLocation(frame, answer)
--                                 gives one frame a GetSourceLocation answering
--                                 `answer` (a string, HARNESS.SECRET, a number or nil),
--                                 raising when answer is "raise", or absent when it is
--                                 false. Without it, stubs8's frames answer any unknown
--                                 method with nil, which is the NoLocation arm.

HARNESS.questieShape = nil

local priorBuildQuestie = HARNESS.buildQuestie
HARNESS.buildQuestie = function()
    priorBuildQuestie()
    local lib = LibQuestieDB
    if type(lib) ~= "table" or HARNESS.questieShape == nil then
        return
    end
    local enum = lib.Enum
    local byExpansion = enum and enum.byExpansion
    local forever = byExpansion and byExpansion.Forever
    local keys = forever and forever.classKeys
    if HARNESS.questieShape == "1.0.10" then
        -- QuestieDB 1.0.10: src/corrections/enum/expansions.lua gives Forever npcFlags
        -- and raceKeys only, and src/api.lua:66-76 publishes the rules flavour's keys.
        lib.flavor.rules = "Classic"
        byExpansion.Classic = { classKeys = keys }
        forever.classKeys = nil
        enum.classKeys = keys
    elseif HARNESS.questieShape == "none" then
        forever.classKeys = nil
        enum.classKeys = nil
    elseif HARNESS.questieShape == "enumNotTable" then
        lib.Enum = "not a table"
    end
end

function HARNESS.setSourceLocation(frame, answer)
    if answer == false then
        rawset(frame, "GetSourceLocation", false)
    elseif answer == "raise" then
        rawset(frame, "GetSourceLocation", function()
            error("GetSourceLocation raised")
        end)
    else
        rawset(frame, "GetSourceLocation", function()
            return answer
        end)
    end
    return frame
end
