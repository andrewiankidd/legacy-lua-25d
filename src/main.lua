-- "G-Town": drive an oblique pseudo-3D city centre built from
-- real OpenStreetMap geometry.
--
-- Entry paths:
--   love src          normal: splash -> menu -> Play -> drive
--   love src play     skip splash/menu, straight to gameplay
--   love src auto     synthetic keypresses for CI smoke-test
--   (append `shot` to any of the above for a headless screenshot)

local Love2D4Me = require("love2d4me")
local GameState = Love2D4Me.gamestate
local Game = nil

local function has_arg(name)
    for _, a in ipairs(arg or {}) do
        if a == name then return true end
    end
    return false
end

function love.load()
    GameState.init({
        on_gameplay_init = function()
            Game = require("game.map")
            Game.load({ shot = has_arg("shot") })
        end,
        on_gameplay_update = function(dt) Game.update(dt) end,
        on_gameplay_draw = function() Game.draw() end,
    })

    if has_arg("play") then
        Game = require("game.map")
        Game.load({ shot = has_arg("shot") })
        GameState.set_state("gameplay")
    end
end

local auto = { t = 0, fired = 0 }

function love.update(dt)
    GameState.update(dt)
    if has_arg("auto") then
        auto.t = auto.t + dt
        if auto.fired < 4 and auto.t > 0.5 + auto.fired * 0.7 then
            auto.fired = auto.fired + 1
            love.keypressed("return")
        end
    end
end

function love.draw()
    GameState.draw()
end

function love.keypressed(key)
    GameState.keypressed(key)
end

function love.keyreleased(key)
    GameState.keyreleased(key)
end
