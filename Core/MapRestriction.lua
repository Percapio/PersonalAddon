-- Core/MapRestriction.lua
-- Whether the current map restricts addons: a dungeon or a raid, on this client
-- (Architecture/20261002-Phase10.md section 7.1).
--
-- Nameplates owned this read in Phase 9 (section 4.2). Toasts needs it too, and
-- reading it through Nameplates would tie Toasts to a feature that can be off, so it
-- lives in core. The enum is resolved through ClientRead once per UI load and
-- reused; nothing is indexed outside ClientRead, so a client without
-- Enum.AddOnRestrictionType cannot raise here (Phase 9 audit finding 4).

local ADDON_NAME, ns = ...

local MapRestriction = {}
ns.MapRestriction = MapRestriction

local ClientRead = ns.ClientRead
local PLAIN = ClientRead.PLAIN

MapRestriction.RESTRICTED = "Restricted"
MapRestriction.UNRESTRICTED = "Unrestricted"
MapRestriction.UNREADABLE = "Unreadable"

local resolved = { done = false, kind = nil, value = nil }

local function resolveMapType()
    if not resolved.done then
        local typesKind, types = ClientRead.Field(_G.Enum, "AddOnRestrictionType", "table")
        if typesKind == PLAIN then
            resolved.kind, resolved.value = ClientRead.Field(types, "Map", "number")
        else
            resolved.kind, resolved.value = typesKind, types
        end
        resolved.done = true
    end
    return resolved.kind, resolved.value
end

-- Returns the reading, and for Unreadable the reason. Unreadable comes back without
-- a client call when the enum or the API is absent. Treat it as "could not tell",
-- never as "no" (README rule 10).
function MapRestriction.Read()
    local kind, mapType = resolveMapType()
    if kind ~= PLAIN then
        return MapRestriction.UNREADABLE, mapType
    end
    local readKind, active = ClientRead.Call(C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive, "boolean", mapType)
    if readKind ~= PLAIN then
        return MapRestriction.UNREADABLE, active
    end
    return active and MapRestriction.RESTRICTED or MapRestriction.UNRESTRICTED
end
