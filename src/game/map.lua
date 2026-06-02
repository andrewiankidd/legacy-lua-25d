-- map.lua -- G-Town game orchestrator.
-- Loads city data, initializes camera + vehicles, delegates to movement + renderer.

local Love2D4Me = require("love2d4me")
local Input = Love2D4Me.input
local Projection = Love2D4Me.projection
local Polygon = Love2D4Me.polygon
local Interactable = Love2D4Me.interactable
local NPC = Love2D4Me.npc
local Equipment = Love2D4Me.equipment
local HUD = Love2D4Me.hud
local Vehicle = require("game.vehicle")
local Movement = require("game.movement")
local Renderer = require("game.renderer")

local Map = {}

local data
local oblique_cam = nil
local player = nil
local pedestrians = {}
Map.road_paths = {}
Map.pedestrians = pedestrians

local FOCAL = 400
local CAM_HEIGHT = 9
local HORIZON_FRAC = 0.40
local PLAYER_SPRITE = "game/npcs/protag/sprite.png"
local PLAYER_FRAME = 50

local shot = { want = false, t = 0, done = false }

function Map.load(opts)
    shot.want = opts and opts.shot or false
    oblique_cam = Projection.oblique_camera({
        x = 0, y = 0, angle = 0, height = CAM_HEIGHT,
        focal = FOCAL, horizon = HORIZON_FRAC, near = 3, anchor = 0.84,
    })
    Input.init()
    Input.bind("attack", { keys = {"f", "space"} })

    HUD.set_controls({
        "W/S: Move",
        "A/D: Turn",
        "Shift: Sprint",
        "E: Enter/Exit vehicle",
        "F: Attack",
        "Esc: Pause",
    })
    Equipment.register("fist", { damage = 5, range = 4, cooldown = 0.6, type = "melee" })
    Equipment.register("bat", { damage = 12, range = 5, cooldown = 0.9, type = "melee" })
    Equipment.equip("fist")

    player = {
        anim = newAnimation(love.graphics.newImage(PLAYER_SPRITE), PLAYER_FRAME, PLAYER_FRAME, 0.1, 0),
        frame = PLAYER_FRAME, walk = { 25, 30 },
        hp = 100, max_hp = 100,
    }
    player.anim:seek(player.walk[1])
    data = require("game.maps.city.data")

    for _, b in ipairs(data.buildings) do
        b.ring = Polygon.open_ring(b.pts)
        b.cx, b.cy = Polygon.centroid(b.ring)
        b.radius = Polygon.bounding_radius(b.ring, b.cx, b.cy)
        local height_t = clamp(b.height / 45, 0, 1)
        b.roof = { lerp(0.46, 0.82, height_t), lerp(0.48, 0.50, height_t), lerp(0.46, 0.34, height_t) }
        b.wall = { b.roof[1] * 0.72, b.roof[2] * 0.72, b.roof[3] * 0.72 }
    end

    local drivable = {
        primary = true, secondary = true, tertiary = true, residential = true,
        unclassified = true, living_street = true, tertiary_link = true, secondary_link = true,
    }
    local road_points = {}
    for _, r in ipairs(data.roads) do
        if drivable[r.kind] then
            local points = r.pts
            for i = 1, #points - 2, 2 do
                local ax, ay, bx, by = points[i], points[i + 1], points[i + 2], points[i + 3]
                local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
                if len > 20 then
                    road_points[#road_points + 1] = {
                        x = (ax + bx) / 2, y = (ay + by) / 2,
                        angle = math.atan2(-(bx - ax), (by - ay)),
                    }
                end
            end
        end
    end

    local best, spawn = math.huge, road_points[1]
    for _, q in ipairs(road_points) do
        local dist_sq = q.x * q.x + q.y * q.y
        if dist_sq < best then best, spawn = dist_sq, q end
    end
    oblique_cam.x, oblique_cam.y, oblique_cam.angle = spawn.x, spawn.y, spawn.angle

    -- Collect full road polylines for AI traffic
    local road_paths = {}
    for _, r in ipairs(data.roads) do
        if drivable[r.kind] then
            local points = r.pts
            if #points >= 4 then
                local path = {}
                for i = 1, #points, 2 do
                    path[#path + 1] = { x = points[i], y = points[i + 1] }
                end
                if #path >= 2 then
                    road_paths[#road_paths + 1] = path
                end
            end
        end
    end

    Map.road_paths = road_paths

    -- Collect pedestrian paths (footways + pavement-offset from roads)
    local walkable = {
        footway = true, path = true, pedestrian = true, living_street = true,
    }
    local ped_paths = {}
    for _, r in ipairs(data.roads) do
        if walkable[r.kind] then
            local points = r.pts
            if #points >= 4 then
                local path = {}
                for i = 1, #points, 2 do path[#path + 1] = { x = points[i], y = points[i + 1] } end
                if #path >= 3 then ped_paths[#ped_paths + 1] = path end
            end
        elseif drivable[r.kind] then
            local points = r.pts
            if #points >= 4 then
                local path = {}
                for i = 1, #points - 2, 2 do
                    local ax, ay, bx, by = points[i], points[i + 1], points[i + 2], points[i + 3]
                    local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
                    if len > 1 then
                        local nx, ny = -(by - ay) / len, (bx - ax) / len
                        local off = 8
                        path[#path + 1] = { x = (ax + bx) / 2 + nx * off, y = (ay + by) / 2 + ny * off }
                    end
                end
                if #path >= 3 then ped_paths[#ped_paths + 1] = path end
            end
        end
    end

    -- Sort pedestrian paths by closest point to player spawn
    local spawn_x, spawn_y = spawn.x, spawn.y
    local function path_min_dist(path)
        local min_d = math.huge
        for _, pt in ipairs(path) do
            local dx, dy = pt.x - spawn_x, pt.y - spawn_y
            local dist_sq = dx * dx + dy * dy
            if dist_sq < min_d then min_d = dist_sq end
        end
        return min_d
    end
    table.sort(ped_paths, function(a, b) return path_min_dist(a) < path_min_dist(b) end)

    -- Spawn pedestrians — first batch on the closest paths, rest spread out
    pedestrians = {}
    local n_ped_paths = #ped_paths
    local ped_npc = NPC.load("pedestrian")
    local PED_FRAME = 50
    local PED_WALK = { south = {1, 6}, east = {13, 18}, north = {25, 30}, west = {37, 42} }
    if n_ped_paths > 0 and ped_npc.sprite then
        local PED_COUNT = 80
        for k = 1, PED_COUNT do
            local idx
            if k <= 40 then
                idx = ((k - 1) % math.min(n_ped_paths, 20)) + 1
            else
                idx = ((k * 23) % n_ped_paths) + 1
            end
            local path = ped_paths[idx]
            local start_idx = ((k * 11) % (#path - 1)) + 1
            local anim = newAnimation(ped_npc.sprite, PED_FRAME, PED_FRAME, 0.1, 0)
            anim:seek(PED_WALK.south[1])
            pedestrians[k] = {
                path = path,
                path_index = start_idx,
                x = path[start_idx].x,
                y = path[start_idx].y,
                speed = 1.2 + (k % 5) * 0.4,
                anim = anim,
                walk_frames = PED_WALK,
                frame_size = PED_FRAME,
                dir = "south",
                alive = true,
                hp = 30,
                max_hp = 30,
                hit_flash = 0,
            }
        end
    end

    Map.pedestrians = pedestrians
    Interactable.reset()
    Movement.reset()
    local nrp = #road_points

    -- Parked vehicles: offset perpendicular to road (half on pavement)
    if nrp > 0 then
        local parked_types = { "car", "sedan", "car", "bike", "sedan", "car", "sedan", "bike", "car", "sedan", "bike", "sedan" }
        for k = 1, 12 do
            local road_pt = road_points[((k * 41) % nrp) + 1]
            local perp_x = math.cos(road_pt.angle)
            local perp_y = math.sin(road_pt.angle)
            local offset = 5
            local vehicle = Vehicle.spawn(parked_types[k], road_pt.x + perp_x * offset, road_pt.y + perp_y * offset, road_pt.angle)
            vehicle.traffic = "parked"
        end
    end

    -- Sort road paths by closest point to player spawn
    local function road_min_dist(path)
        local min_d = math.huge
        for _, pt in ipairs(path) do
            local dx, dy = pt.x - spawn_x, pt.y - spawn_y
            local dist_sq = dx * dx + dy * dy
            if dist_sq < min_d then min_d = dist_sq end
        end
        return min_d
    end
    table.sort(road_paths, function(a, b) return road_min_dist(a) < road_min_dist(b) end)

    -- Active traffic: first batch near spawn, rest spread out
    local n_paths = #road_paths
    if n_paths > 0 then
        local traffic_types = { "car", "sedan", "car", "sedan", "car", "sedan", "car", "car", "sedan", "car" }
        local TRAFFIC_COUNT = 35
        for k = 1, TRAFFIC_COUNT do
            local pool_idx
            if k <= 15 then
                pool_idx = ((k - 1) % math.min(n_paths, 10)) + 1
            else
                pool_idx = ((k * 17) % n_paths) + 1
            end
            local path = road_paths[pool_idx]
            if #path >= 3 then
                local start_idx = ((k * 7) % (#path - 1)) + 1
                local start = path[start_idx]
                local next_pt = path[start_idx + 1] or path[1]
                local dx = next_pt.x - start.x
                local dy = next_pt.y - start.y
                local angle = math.atan2(-dx, dy)
                local vehicle = Vehicle.spawn(traffic_types[((k - 1) % #traffic_types) + 1], start.x, start.y, angle)
                vehicle.traffic = "driving"
                vehicle.path = path
                vehicle.path_index = start_idx
                vehicle.drive_speed = 6 + (k % 8) * 2
            end
        end
    end
end

function Map.spawn_pedestrian(world_x, world_y, opts)
    opts = opts or {}
    local ped_npc = NPC.load("pedestrian")
    if not ped_npc.sprite then return nil end
    local PED_FRAME = 50
    local PED_WALK = { south = {1, 6}, east = {13, 18}, north = {25, 30}, west = {37, 42} }
    local anim = newAnimation(ped_npc.sprite, PED_FRAME, PED_FRAME, 0.1, 0)
    anim:seek(PED_WALK.south[1])
    local ped = {
        path = opts.path or {{ x = world_x, y = world_y }},
        path_index = 1,
        x = world_x,
        y = world_y,
        speed = opts.speed or 2.0,
        anim = anim,
        walk_frames = PED_WALK,
        frame_size = PED_FRAME,
        dir = "south",
        alive = true,
        hp = opts.hp or 30,
        max_hp = opts.hp or 30,
        hit_flash = 0,
        aggro = opts.aggro or 0,
        aggro_decay = opts.aggro_decay or 0.3,
        aggro_threshold = opts.aggro_threshold or 1,
        chase_speed = opts.chase_speed or 3,
        follow_distance = opts.follow_distance or 5,
    }
    pedestrians[#pedestrians + 1] = ped
    return ped
end

function Map.update(dt)
    Movement.update(dt, oblique_cam, player, data)
    Equipment.update(dt)
    HUD.update(dt)

    -- Player ground position
    local pivot = oblique_cam:ground_distance()
    local cam_fx, cam_fy = oblique_cam:forward_dir()
    local player_wx = oblique_cam.x + cam_fx * pivot
    local player_wy = oblique_cam.y + cam_fy * pivot

    -- Player attack
    if Input.held("attack") and Equipment.can_attack() then
        local hit = Equipment.attack()
        if hit then
            for _, ped in ipairs(pedestrians) do
                if ped.alive ~= false then
                    local dx = ped.x - player_wx
                    local dy = ped.y - player_wy
                    if dx * dx + dy * dy < hit.range * hit.range then
                        ped.hp = (ped.hp or 30) - hit.damage
                        ped.max_hp = ped.max_hp or 30
                        ped.hit_flash = 0.15
                        NPC.aggro(ped, 10)
                        if ped.hp <= 0 then ped.alive = false end
                    end
                end
            end
        end
    end

    -- Aggro'd pedestrians damage player on proximity
    for _, ped in ipairs(pedestrians) do
        if ped.alive ~= false and (ped.aggro or 0) >= (ped.aggro_threshold or 1) then
            local dx = ped.x - player_wx
            local dy = ped.y - player_wy
            if dx * dx + dy * dy < 9 then
                if not ped._attack_cd or ped._attack_cd <= 0 then
                    player.hp = player.hp - 2
                    HUD.flash_damage()
                    ped._attack_cd = 1.0
                end
            end
            if ped._attack_cd then ped._attack_cd = ped._attack_cd - dt end
        end
    end

    HUD.set_health(player.hp, player.max_hp)
    local weapon = Equipment.get_equipped()
    HUD.set_weapon(weapon and weapon.name or nil, Equipment.get_cooldown_ratio())

    -- Update pedestrians (reuses pivot, cam_fx/fy, player_wx/wy from above)
    for _, ped in ipairs(pedestrians) do
        if ped.alive ~= false then

        -- Hit flash decay
        if ped.hit_flash and ped.hit_flash > 0 then
            ped.hit_flash = ped.hit_flash - dt
        end

        -- Aggro decay
        if (ped.aggro or 0) > 0 then
            ped.aggro = ped.aggro - (ped.aggro_decay or 0.3) * dt
            if ped.aggro < 0 then ped.aggro = 0 end
        end

        local aggro_active = (ped.aggro or 0) >= (ped.aggro_threshold or 1)
        local move_dx, move_dy = 0, 0
        local move_speed = ped.speed

        if aggro_active then
            -- Chase the player
            local dx = player_wx - ped.x
            local dy = player_wy - ped.y
            local dist = math.sqrt(dx * dx + dy * dy)
            local follow = ped.follow_distance or 5
            if dist > follow then
                move_speed = ped.chase_speed or 3
                move_dx = (dx / dist) * move_speed * dt
                move_dy = (dy / dist) * move_speed * dt
            end
        else
            -- Follow path
            local target = ped.path[ped.path_index + 1]
            if target then
                local dx = target.x - ped.x
                local dy = target.y - ped.y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist < 1 then
                    ped.path_index = ped.path_index + 1
                    if ped.path_index >= #ped.path then
                        ped.path_index = 1
                    end
                else
                    move_dx = (dx / dist) * move_speed * dt
                    move_dy = (dy / dist) * move_speed * dt
                end
            end
        end

        if math.abs(move_dx) > 0.001 or math.abs(move_dy) > 0.001 then
            ped.x = ped.x + move_dx
            ped.y = ped.y + move_dy
            local cam_angle = oblique_cam.angle
            local world_angle = math.atan2(move_dy, move_dx)
            local rel = world_angle - cam_angle
            local dir
            if rel > -0.785 and rel <= 0.785 then dir = "east"
            elseif rel > 0.785 and rel <= 2.356 then dir = "south"
            elseif rel > -2.356 and rel <= -0.785 then dir = "north"
            else dir = "west" end
            if dir ~= ped.dir and ped.walk_frames[dir] then
                ped.dir = dir
            end
            if ped.anim then
                ped.anim:update(dt * move_speed / 2)
                local frame = ped.anim:getCurrentFrame()
                local range = ped.walk_frames[ped.dir]
                if range and (frame < range[1] or frame > range[2]) then
                    ped.anim:seek(range[1])
                end
            end
        end
        end
    end

    if shot.want and not shot.done then
        local fx, fy = oblique_cam:forward_dir()
        oblique_cam.x = oblique_cam.x + fx * 55 * dt
        oblique_cam.y = oblique_cam.y + fy * 55 * dt
        oblique_cam.angle = oblique_cam.angle + 0.7 * dt
        shot.t = shot.t + dt
        if shot.t > 0.9 then
            shot.done = true
            love.graphics.captureScreenshot(function(img)
                local fd = img:encode("png")
                love.filesystem.write("mapshot.png", fd:getString())
                print("SHOT_SAVED " .. love.filesystem.getSaveDirectory() .. "/mapshot.png")
                love.event.quit()
            end)
        end
    end
end

function Map.draw()
    Renderer.draw(data, oblique_cam, player, Vehicle.get_current(), pedestrians)
    HUD.draw()
end

return Map
