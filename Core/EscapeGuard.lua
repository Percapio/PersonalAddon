-- Core/EscapeGuard.lua
-- The addon's trust boundary (§9). Server-sourced strings -- unit names, guild
-- names, pet names, and from Phase 5 gossip and quest bodies -- are influenced
-- by parties other than the user and must not reach a font string with their
-- escape sequences live.

local ADDON_NAME, ns = ...

local EscapeGuard = {}
ns.EscapeGuard = EscapeGuard

local gsub, format, select, type = string.gsub, string.format, select, type

-- Doubling the pipe is what makes |c, |T, |H, |A and |n inert: the client
-- renders "||" as a literal pipe and stops parsing what follows as a code.
function EscapeGuard.Neutralize(sourceText)
    if type(sourceText) ~= "string" then
        return ""
    end
    return (gsub(sourceText, "|", "||"))
end

-- Substitution where the format string is always ours and the substituted
-- values are always neutralized. Externally-sourced text is never the format
-- argument -- a name containing a percent sign would raise inside an event
-- handler.
function EscapeGuard.Format(formatString, ...)
    local count = select("#", ...)
    if count == 0 then
        return formatString
    end

    local args = {}
    for index = 1, count do
        local value = select(index, ...)
        if type(value) == "string" then
            args[index] = EscapeGuard.Neutralize(value)
        else
            args[index] = value
        end
    end

    return format(formatString, unpack(args, 1, count))
end
