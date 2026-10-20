-- mod_manager: /manage <mod|modpack> on|off turns mods on or off by editing
-- the world's world.mt (the `load_mod_<name>` lines). Luanti reads it at
-- startup, so a change takes effect after the next restart.
--
-- A modpack's name (a folder with a modpack.conf or modpack.txt) covers every
-- mod inside it, also in nested modpacks: `/manage 3d_armor off` turns off the
-- whole pack, even if it holds a mod of the same name.
--
-- Mods of the running game are always loaded, so they can't be switched; they
-- count as enabled when checking dependencies. Needs no insecure environment:
-- mods may write to the world's folder.

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local game = core.get_game_info()
local WORLD_MT = core.get_worldpath() .. "/world.mt"

local USAGE = "Usage: /manage list | /manage <mod|modpack> [on|off [force]]"

core.register_privilege("mod_manager", {
    description = "Can turn mods on and off with /manage",
    give_to_singleplayer = false,
    give_to_admin = true,
})

---------------------------------------------------------------------------
-- Finding mods
---------------------------------------------------------------------------

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function has_file(path, file)
    for _, f in ipairs(core.get_dir_list(path, false)) do
        if f == file then return true end
    end
    return false
end

local function split_list(s)
    local list = {}
    for item in (s or ""):gmatch("[^,%s]+") do
        list[#list + 1] = item
    end
    return list
end

-- A mod's real name and its (hard) dependencies, from mod.conf or the older
-- depends.txt (where an optional dependency ends with `?`).
local function read_mod(path, folder)
    local m = { name = folder, path = path, deps = {} }
    local conf = read_file(path .. "/mod.conf")
    if conf then
        for line in conf:gmatch("[^\r\n]+") do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key == "name" and value:match("^[%w_]+$") then
                m.name = value
            elseif key == "depends" then
                m.deps = split_list(value)
            end
        end
    else
        for line in (read_file(path .. "/depends.txt") or ""):gmatch("[^\r\n]+") do
            local dep = line:match("^%s*([%w_]+)%s*$")
            if dep then m.deps[#m.deps + 1] = dep end
        end
    end
    return m
end

-- Scans a folder of mods and modpacks. Fills `index.mods` (name -> mod) and
-- `index.packs` (folder name -> list of the mods inside, nested ones too);
-- returns the mods found. `fixed` marks mods that are always loaded.
local function scan(dir, index, fixed)
    local found = {}
    for _, folder in ipairs(core.get_dir_list(dir, true)) do
        local path = dir .. "/" .. folder
        if has_file(path, "modpack.conf") or has_file(path, "modpack.txt") then
            local inner = scan(path, index, fixed)
            index.packs[folder] = inner
            for _, m in ipairs(inner) do found[#found + 1] = m end
        elseif has_file(path, "init.lua") or has_file(path, "mod.conf") then
            local m = read_mod(path, folder)
            m.fixed = fixed
            index.mods[m.name] = index.mods[m.name] or m
            found[#found + 1] = m
        end
    end
    return found
end

local function build_index()
    local index = { mods = {}, packs = {} }
    local user_mods = modpath:match("^(.*)/[^/]+$") -- the folder this mod is in
    scan(game.path .. "/mods", index, true)
    scan(core.get_worldpath() .. "/worldmods", index, false)
    scan(user_mods, index, false)
    return index
end

---------------------------------------------------------------------------
-- world.mt
---------------------------------------------------------------------------

local function read_world()
    return read_file(WORLD_MT)
end

-- name -> true/false for every load_mod_ line.
local function enabled_in(world)
    local state = {}
    for line in world:gmatch("[^\r\n]+") do
        local name, value = line:match("^%s*load_mod_([%w_]+)%s*=%s*(.-)%s*$")
        if name then state[name] = value ~= "false" end
    end
    return state
end

-- world.mt with the given mods set to true/false (name -> bool).
local function with_changes(world, changes)
    local out, done = {}, {}
    for line in (world .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local name = line:match("^%s*load_mod_([%w_]+)%s*=")
        if name and changes[name] ~= nil then
            out[#out + 1] = ("load_mod_%s = %s"):format(name, tostring(changes[name]))
            done[name] = true
        else
            out[#out + 1] = line
        end
    end
    while out[#out] == "" do out[#out] = nil end
    local added = {}
    for name in pairs(changes) do
        if not done[name] then added[#added + 1] = name end
    end
    table.sort(added)
    for _, name in ipairs(added) do
        out[#out + 1] = ("load_mod_%s = %s"):format(name, tostring(changes[name]))
    end
    return table.concat(out, "\n") .. "\n"
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

-- The mods a name stands for: a modpack (preferred), or one mod.
local function resolve(index, name)
    if index.packs[name] then
        return index.packs[name], true
    end
    local m = index.mods[name]
    return m and { m } or nil, false
end

local function is_enabled(m, state)
    return m.fixed or state[m.name] == true
end

local function describe(m, state)
    if m.fixed then return "always on (part of the game)" end
    local listed, loaded = state[m.name], core.get_modpath(m.name) ~= nil
    if listed and loaded then return "on" end
    if listed then return "on after a restart" end
    if loaded then return "off after a restart (still running)" end
    return "off"
end

local function names_of(mods)
    local names = {}
    for _, m in ipairs(mods) do names[#names + 1] = m.name end
    table.sort(names)
    return names
end

local function list(index, state)
    local lines = {}
    local packs = {}
    for pack in pairs(index.packs) do packs[#packs + 1] = pack end
    table.sort(packs)
    local in_pack = {}
    for _, pack in ipairs(packs) do
        local mods = index.packs[pack]
        local on = 0
        for _, m in ipairs(mods) do
            in_pack[m.name] = true
            if is_enabled(m, state) then on = on + 1 end
        end
        if not (mods[1] and mods[1].fixed) then
            lines[#lines + 1] = ("%s (modpack): %d of %d mods on"):format(pack, on, #mods)
        end
    end
    local names = {}
    for name, m in pairs(index.mods) do
        if not m.fixed and not in_pack[name] then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        lines[#lines + 1] = ("%s: %s"):format(name, describe(index.mods[name], state))
    end
    return true, table.concat(lines, "\n")
end

local function status(index, state, name)
    local mods, pack = resolve(index, name)
    if not mods then
        return false, "No mod or modpack '" .. name .. "' here"
    end
    if not pack then
        return true, ("%s: %s"):format(name, describe(mods[1], state))
    end
    local lines = { ("%s (modpack, %d mods):"):format(name, #mods) }
    table.sort(mods, function(a, b) return a.name < b.name end)
    for _, m in ipairs(mods) do
        lines[#lines + 1] = ("  %s: %s"):format(m.name, describe(m, state))
    end
    return true, table.concat(lines, "\n")
end

local function set(player, index, state, name, on, force)
    local mods, pack = resolve(index, name)
    if not mods then
        return false, "No mod or modpack '" .. name .. "' here"
    end
    local target = {}
    local changes, changed, fixed = {}, {}, {}
    for _, m in ipairs(mods) do
        target[m.name] = true
        if m.fixed then
            fixed[#fixed + 1] = m.name
        elseif m.name == modname and not on then
            return false, "mod_manager can't turn itself off (edit world.mt by hand)"
        elseif is_enabled(m, state) ~= on then
            changes[m.name] = on
            changed[#changed + 1] = m.name
        end
    end
    if #changed == 0 then
        if #fixed > 0 and #fixed == #mods then
            return false, name .. " is part of the game and is always on"
        end
        return true, ("%s is already %s"):format(name, on and "on" or "off")
    end
    table.sort(changed)

    -- A mod that depends on a missing or disabled mod stops the server from
    -- starting, so check both ways first.
    local problems = {}
    if on then
        for _, m in ipairs(mods) do
            for _, dep in ipairs(m.deps) do
                local d = index.mods[dep]
                if not target[dep] and not (d and is_enabled(d, state)) then
                    problems[#problems + 1] = ("%s needs %s (%s)"):format(m.name, dep,
                        d and "off" or "not installed")
                end
            end
        end
    else
        for other_name, other in pairs(index.mods) do
            if not target[other_name] and is_enabled(other, state) then
                for _, dep in ipairs(other.deps) do
                    if target[dep] then
                        problems[#problems + 1] = ("%s needs %s"):format(other_name, dep)
                    end
                end
            end
        end
    end
    table.sort(problems)
    if #problems > 0 and not force then
        return false, ("Not turning %s %s, the server wouldn't start:\n  %s\n"
            .. "Fix that first, or add 'force'."):format(name, on and "on" or "off",
            table.concat(problems, "\n  "))
    end

    local world = read_world()
    if not world then
        return false, "Can't read " .. WORLD_MT
    end
    if not core.safe_file_write(WORLD_MT, with_changes(world, changes)) then
        return false, "Can't write " .. WORLD_MT
    end
    core.log("action", ("[%s] %s turned %s %s: %s%s"):format(modname, player, name,
        on and "on" or "off", table.concat(changed, ", "),
        #problems > 0 and (" (forced: " .. table.concat(problems, "; ") .. ")") or ""))
    local msg = ("%s %s: %s. Restart the server for it to take effect."):format(
        pack and "Modpack" or "Mod", name, on and "turned on" or "turned off")
    if pack then
        msg = msg .. (" (%d mods: %s)"):format(#changed, table.concat(changed, ", "))
    end
    if #problems > 0 then
        msg = msg .. "\nForced past: " .. table.concat(problems, "; ")
    end
    if #fixed > 0 then
        msg = msg .. "\nAlready always on (game): " .. table.concat(fixed, ", ")
    end
    return true, msg
end

core.register_chatcommand("manage", {
    params = "list | <mod|modpack> [on|off [force]]",
    description = "Turn a mod, or every mod of a modpack, on or off in world.mt"
        .. " (takes effect after a restart)",
    privs = { mod_manager = true },
    func = function(player, param)
        local words = {}
        for w in param:gmatch("%S+") do words[#words + 1] = w end
        local name, action, force = words[1], words[2], words[3]
        if not name or #words > 3 then return false, USAGE end
        if not name:match("^[%w_]+$") then return false, "Invalid name: " .. name end
        if action and action ~= "on" and action ~= "off" then return false, USAGE end
        if force and (force ~= "force" or not action) then return false, USAGE end

        local world = read_world()
        if not world then return false, "Can't read " .. WORLD_MT end
        local state = enabled_in(world)
        local index = build_index()
        if name == "list" and not action then
            return list(index, state)
        elseif not action then
            return status(index, state, name)
        end
        return set(player, index, state, name, action == "on", force == "force")
    end,
})
