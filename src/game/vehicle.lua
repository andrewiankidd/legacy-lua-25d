-- vehicle.lua -- Game-specific vehicle presets for G-Town.
-- Registers types with the submodule's Vehicle system.

local Vehicle = require("love2d4me").vehicle

Vehicle.register("car",  { speed = 22, turn = 1.5, w = 4.0, h = 8.0, color = { 0.75, 0.22, 0.20 }, weight = 1200 })
Vehicle.register("sedan", { speed = 18, turn = 1.2, w = 4.5, h = 9.0, color = { 0.20, 0.40, 0.75 }, weight = 1600 })
Vehicle.register("bike", { speed = 18, turn = 2.4, w = 1.4, h = 4.0, color = { 0.20, 0.20, 0.26 }, weight = 200 })

return Vehicle
