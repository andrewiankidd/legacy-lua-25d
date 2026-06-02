-- movement.lua -- Camera control, walking/driving physics, collision.
-- Driving state lives in the submodule's Vehicle module; this just drives it.

local Love2D4Me = require("love2d4me")
local Input = Love2D4Me.input
local Polygon = Love2D4Me.polygon
local Interactable = Love2D4Me.interactable
local Vehicle = Love2D4Me.vehicle

local Movement = {}

local MOVE_SPEED = 5
local SPRINT_MULT = 2.5
local TURN_SPEED = 1.9

local vel = 0
local prev_interact = false

local function blocked(px, py, data)
    for _, b in ipairs(data.buildings) do
        local dx, dy = px - b.cx, py - b.cy
        if dx * dx + dy * dy < b.radius * b.radius and Polygon.contains(b.ring, px, py) then
            return true
        end
    end
    local driving = Vehicle.get_current()
    for _, o in ipairs(Interactable.all()) do
        if o.driveable and o ~= driving and Vehicle.contains(o, px, py, 0.5) then
            return true
        end
    end
    return false
end

function Movement.update(dt, cam, player, data)
    local pivot = cam:ground_distance() -- forward distance to the player's ground point
    local driving = Vehicle.get_current()

    local speed, turnsp
    if driving then
        speed, turnsp = driving.speed, driving.turn
    else
        speed = Input.held("sprint") and MOVE_SPEED * SPRINT_MULT or MOVE_SPEED
        turnsp = TURN_SPEED
    end

    -- turn: rotate the eye AROUND the player's ground point, so you pivot in place
    local turn = 0
    if Input.held("move_left") then turn = turn + turnsp * dt end
    if Input.held("move_right") then turn = turn - turnsp * dt end
    if turn ~= 0 then
        local fx, fy = cam:forward_dir()
        local px, py = cam.x + fx * pivot, cam.y + fy * pivot
        cam.angle = cam.angle + turn
        fx, fy = cam:forward_dir()
        cam.x, cam.y = px - fx * pivot, py - fy * pivot
    end

    local fx, fy = cam:forward_dir()
    local ppx, ppy = cam.x + fx * pivot, cam.y + fy * pivot -- player's ground point

    -- enter / exit a vehicle on Interact (edge-detected so it toggles once per press)
    local interact = Input.held("interact")
    if interact and not prev_interact then
        local was_driving = Vehicle.is_driving()
        if not was_driving then
            local target_vehicle = Interactable.nearest(ppx, ppy, function(o) return o.driveable end)
            if target_vehicle then
                local was_ai = target_vehicle.traffic == "driving"
                local vx, vy = target_vehicle.x, target_vehicle.y
                Vehicle.enter(target_vehicle)
                cam.x = target_vehicle.x - fx * pivot
                cam.y = target_vehicle.y - fy * pivot
                cam.angle = target_vehicle.angle
                target_vehicle.traffic = "stolen"
                if was_ai then
                    local Map = require("game.map")
                    local ca = math.cos(target_vehicle.angle)
                    local offset_x = vx + ca * 3
                    local offset_y = vy + math.sin(target_vehicle.angle) * 3
                    Map.spawn_pedestrian(offset_x, offset_y, {
                        aggro = 15,
                        aggro_decay = 0.5,
                        chase_speed = 4,
                        follow_distance = 3,
                        speed = 2.5,
                    })
                end
            end
        else
            local ok, exit_x, exit_y = Vehicle.exit(ppx, ppy, cam.angle, function(qx, qy)
                return blocked(qx, qy, data)
            end)
            if ok and exit_x then
                cam.x = exit_x - fx * pivot
                cam.y = exit_y - fy * pivot
            end
        end
    end
    prev_interact = interact
    driving = Vehicle.get_current()

    -- accelerate / brake
    local target = 0
    if Input.held("move_up") then target = speed end
    if Input.held("move_down") then target = -speed * 0.6 end
    vel = lerp(vel, target, clamp(dt * 5, 0, 1))
    local nx, ny = cam.x + fx * vel * dt, cam.y + fy * vel * dt
    -- check the leading bumper (front going forward, back reversing); on foot it's the point
    local lead = driving and (vel >= 0 and driving.h / 2 or -driving.h / 2) or 0
    if blocked(nx + fx * (pivot + lead), ny + fy * (pivot + lead), data) then
        vel = 0
    else
        cam.x, cam.y = nx, ny
    end

    Vehicle.check_collisions(dt, function(px, py) return blocked(px, py, data) end)

    -- AI traffic: drive along roads, stop for pedestrians/player
    local Map = require("game.map")
    local all_roads = Map.road_paths or {}
    local peds = Map.pedestrians or {}
    local JUNCTION_RADIUS = 25
    local STOP_DIST = 6

    local function path_blocked_by_ped(veh_x, veh_y, veh_angle)
        local fwd_x = -math.sin(veh_angle)
        local fwd_y = math.cos(veh_angle)
        -- Check player
        local pdx, pdy = ppx - veh_x, ppy - veh_y
        local along = pdx * fwd_x + pdy * fwd_y
        local perp = math.abs(pdx * fwd_y - pdy * fwd_x)
        if along > 0 and along < STOP_DIST and perp < 3 then return true end
        -- Check pedestrians
        for _, ped in ipairs(peds) do
            if ped.alive ~= false then
                local pedx, pedy = ped.x - veh_x, ped.y - veh_y
                along = pedx * fwd_x + pedy * fwd_y
                perp = math.abs(pedx * fwd_y - pedy * fwd_x)
                if along > 0 and along < STOP_DIST and perp < 3 then return true end
            end
        end
        return false
    end

    for _, v in ipairs(Interactable.all()) do
        if v.driveable and v.traffic == "driving" and v ~= driving and v.path then
            local target_pt = v.path[v.path_index + 1]
            if target_pt then
                local dx = target_pt.x - v.x
                local dy = target_pt.y - v.y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist < 3 then
                    v.path_index = v.path_index + 1
                    if v.path_index >= #v.path then
                        local end_pt = v.path[#v.path]
                        local best_path, best_idx, best_dist = nil, 1, math.huge
                        local attempts = math.min(#all_roads, 50)
                        local search_start = ((v._road_seed or 0) * 13) % #all_roads
                        for j = 1, attempts do
                            local ri = ((search_start + j * 7) % #all_roads) + 1
                            local candidate = all_roads[ri]
                            if candidate ~= v.path and #candidate >= 3 then
                                local first = candidate[1]
                                local ddx, ddy = first.x - end_pt.x, first.y - end_pt.y
                                local dist_sq = ddx * ddx + ddy * ddy
                                if dist_sq < JUNCTION_RADIUS * JUNCTION_RADIUS and dist_sq < best_dist then
                                    best_path = candidate
                                    best_idx = 1
                                    best_dist = dist_sq
                                end
                                local last = candidate[#candidate]
                                ddx, ddy = last.x - end_pt.x, last.y - end_pt.y
                                local end_dist_sq = ddx * ddx + ddy * ddy
                                if end_dist_sq < JUNCTION_RADIUS * JUNCTION_RADIUS and end_dist_sq < best_dist then
                                    best_path = candidate
                                    best_idx = #candidate - 1
                                    best_dist = end_dist_sq
                                end
                            end
                        end
                        if best_path then
                            v.path = best_path
                            v.path_index = best_idx
                            v._road_seed = (v._road_seed or 0) + 1
                        else
                            v.path_index = 1
                        end
                    end
                elseif not path_blocked_by_ped(v.x, v.y, v.angle) then
                    local spd = (v.drive_speed or 10) * dt
                    v.x = v.x + (dx / dist) * spd
                    v.y = v.y + (dy / dist) * spd
                    v.angle = math.atan2(-dx, dy)
                end
            end
        end
    end

    if driving then
        driving.x, driving.y, driving.angle = cam.x + fx * pivot, cam.y + fy * pivot, cam.angle
    elseif math.abs(vel) > 0.3 then
        player.anim:update(dt * math.abs(vel) / MOVE_SPEED)
        local frame = player.anim:getCurrentFrame()
        if frame < player.walk[1] or frame > player.walk[2] then player.anim:seek(player.walk[1]) end
    else
        player.anim:seek(player.walk[1])
    end
end

function Movement.reset()
    Vehicle.reset()
    vel = 0
    prev_interact = false
end

return Movement
