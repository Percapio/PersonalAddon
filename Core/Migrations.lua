-- Core/Migrations.lua
-- One step per version transition, ascending (§5.3). A step does not stamp
-- schemaVersion; Apply stamps it after the step returns cleanly, which is what
-- lets a partially-applied chain resume at the right place rather than at the
-- version a step claimed to have reached.

local ADDON_NAME, ns = ...

local Migrations = {}
ns.Migrations = Migrations

local type, format = type, string.format

Migrations.steps = {
    {
        fromVersion = 0,
        description = "seed the v1 shape: feature table present",
        apply = function(store)
            if type(store.features) ~= "table" then
                store.features = {}
            end
        end,
    },
}

function Migrations.Apply(store, currentSchemaVersion)
    local byFromVersion = {}
    for index = 1, #Migrations.steps do
        local step = Migrations.steps[index]
        if byFromVersion[step.fromVersion] then
            return nil, {
                reason = "DUPLICATE_STEP",
                version = step.fromVersion,
                detail = format("two steps declare fromVersion %d", step.fromVersion),
            }
        end
        byFromVersion[step.fromVersion] = step
    end

    while store.schemaVersion < currentSchemaVersion do
        local fromVersion = store.schemaVersion
        local step = byFromVersion[fromVersion]

        if not step then
            return nil, {
                reason = "MISSING_STEP",
                version = fromVersion,
                detail = format("no migration step declared for v%d -> v%d",
                    fromVersion, fromVersion + 1),
            }
        end

        local ok, err = ns.Isolation.Call(step.apply, store)
        if not ok then
            return nil, {
                reason = "STEP_RAISED",
                version = fromVersion,
                description = step.description,
                detail = err,
            }
        end

        store.schemaVersion = fromVersion + 1
    end

    return store, nil
end
