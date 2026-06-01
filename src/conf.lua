-- Dev override: set LOVE2D4ME_DEV=C:\git\love2d4me to use a local
-- working copy instead of the embedded submodule. No push needed.
local dev = os.getenv("LOVE2D4ME_DEV")
if dev then
    dev = dev:gsub("\\", "/"):gsub("/$", "")
    local searchers = package.loaders or package.searchers
    table.insert(searchers, 2, function(mod)
        if not mod:match("^love2d4me") then return end
        local rel = mod:gsub("^love2d4me%.?", ""):gsub("%.", "/")
        local path = rel == "" and dev .. "/init.lua" or dev .. "/" .. rel .. ".lua"
        local file = io.open(path, "r")
        if not file then return end
        local src = file:read("*a"); file:close()
        return assert(loadstring(src, "@" .. path))
    end)
end

local Conf = require("love2d4me.src.conf")
function love.conf(t) Conf.apply(t) end
