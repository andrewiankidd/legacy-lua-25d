-- renderer.lua -- Oblique 2.5D city rendering.
-- Draws roads, buildings (extruded + depth-sorted), vehicles, player sprite, HUD.

local Love2D4Me = require("love2d4me")
local Polygon = Love2D4Me.polygon
local Interactable = Love2D4Me.interactable

local Renderer = {}

local NEAR_CLIP = 3.5
local FAR = 650
local SCREEN_PADDING = 8
local LIGHT_X, LIGHT_Y = 0.53, 0.85

local function road_style(kind)
    if kind == "motorway" or kind == "trunk" or kind == "primary" then
        return 12, { 0.26, 0.26, 0.29 }
    elseif kind == "secondary" or kind == "tertiary" then
        return 9, { 0.23, 0.23, 0.26 }
    elseif kind == "footway" or kind == "path" or kind == "pedestrian" then
        return 3, { 0.18, 0.19, 0.18 }
    end
    return 7, { 0.21, 0.21, 0.23 }
end

local function clip_ring_near(ring, clip, camera_space_fn)
    return Polygon.clip_near(ring, camera_space_fn, clip)
end

local function draw_road_segment(ax, ay, bx, by, w, col, project_fn, camera_space_fn)
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then return end
    local px, py = -dy / len * (w / 2), dx / len * (w / 2)
    local quad = { ax + px, ay + py, bx + px, by + py, bx - px, by - py, ax - px, ay - py }
    local poly = clip_ring_near(quad, NEAR_CLIP, camera_space_fn)
    if not poly then return end
    local flat = {}
    for i = 1, #poly do
        local sx, sy = project_fn(poly[i][1], poly[i][2], 0)
        if not sx then return end
        flat[#flat + 1] = sx
        flat[#flat + 1] = sy
    end
    love.graphics.setColor(col[1], col[2], col[3])
    pcall(love.graphics.polygon, "fill", flat)
end

local function draw_building(b, project_fn, camera_space_fn, cam_x, cam_y)
    local poly = clip_ring_near(b.ring, NEAR_CLIP, camera_space_fn)
    if not poly then return end
    local h, m = b.height, #poly

    local base, top = {}, {}
    local all_valid = true
    for i = 1, m do
        local vert = poly[i]
        local bx, byp = project_fn(vert[1], vert[2], 0)
        local tx, ty = project_fn(vert[1], vert[2], h)
        if not bx or not tx then all_valid = false; break end
        base[i] = { bx, byp, vert[3] }
        top[i] = { tx, ty }
    end
    if not all_valid then return end

    local order = {}
    for i = 1, m do
        local j = i % m + 1
        order[i] = { i = i, j = j, d = (base[i][3] + base[j][3]) * 0.5 }
    end
    table.sort(order, function(p, q) return p.d > q.d end)
    for _, e in ipairs(order) do
        local i, j = e.i, e.j
        local x1, y1, x2, y2 = poly[i][1], poly[i][2], poly[j][1], poly[j][2]
        local mx, my = (x1 + x2) * 0.5, (y1 + y2) * 0.5
        local nx, ny = y2 - y1, -(x2 - x1)
        if nx * (mx - b.cx) + ny * (my - b.cy) < 0 then nx, ny = -nx, -ny end
        if nx * (cam_x - mx) + ny * (cam_y - my) > 0 then
            local nl = math.sqrt(nx * nx + ny * ny)
            local lit = nl > 0 and (nx / nl * LIGHT_X + ny / nl * LIGHT_Y) or 0
            local shade = 0.6 + 0.4 * clamp((lit + 1) * 0.5, 0, 1)
            love.graphics.setColor(b.wall[1] * shade, b.wall[2] * shade, b.wall[3] * shade)
            love.graphics.polygon("fill",
                base[i][1], base[i][2], base[j][1], base[j][2],
                top[j][1], top[j][2], top[i][1], top[i][2])
        end
    end

    love.graphics.setColor(b.roof[1], b.roof[2], b.roof[3])
    local flat = {}
    local valid_roof = true
    for i = 1, m do
        if top[i] and top[i][1] and top[i][2] then
            flat[#flat + 1] = top[i][1]
            flat[#flat + 1] = top[i][2]
        else
            valid_roof = false
            break
        end
    end
    if valid_roof and #flat >= 6 then
        -- Defensive: love.math.triangulate can fail on degenerate projected polygons
        -- (collinear/self-intersecting near-edge cases) and under love.js pthread builds
        -- has been observed to return values that crash the iteration loop.
        local ok, tris = pcall(love.math.triangulate, flat)
        if ok and type(tris) == "table" then
            for _, tri in ipairs(tris) do
                if type(tri) == "table" and #tri >= 6 then
                    pcall(love.graphics.polygon, "fill", tri)
                end
            end
        end
    end
end

local function draw_vehicle(v, project_fn, camera_space_fn)
    local ca, sa = math.cos(v.angle), math.sin(v.angle)
    local fxv, fyv = -sa, ca
    local rxv, ryv = ca, sa
    local hl, hw = v.h / 2, v.w / 2
    local quad = {
        v.x + fxv * hl + rxv * hw, v.y + fyv * hl + ryv * hw,
        v.x + fxv * hl - rxv * hw, v.y + fyv * hl - ryv * hw,
        v.x - fxv * hl - rxv * hw, v.y - fyv * hl - ryv * hw,
        v.x - fxv * hl + rxv * hw, v.y - fyv * hl + ryv * hw,
    }
    local poly = clip_ring_near(quad, NEAR_CLIP, camera_space_fn)
    if not poly then return end
    local flat = {}
    for i = 1, #poly do
        local sx, sy = project_fn(poly[i][1], poly[i][2], 0)
        if not sx then return end
        flat[#flat + 1] = sx
        flat[#flat + 1] = sy
    end
    love.graphics.setColor(v.color[1], v.color[2], v.color[3])
    pcall(love.graphics.polygon, "fill", flat)
end

local function draw_money(drop, project_fn)
    local sx, sy, fwd = project_fn(drop.x, drop.y, 0.3)
    if not sx or fwd <= 0.5 then return end
    local scale = math.max(0.4, 400 / fwd * 0.05)
    local size = 10 * scale
    local cosr, sinr = math.cos(drop.rot), math.sin(drop.rot)
    local hw = size / 2
    local hh = size / 3
    local pts = {
        sx + cosr * -hw - sinr * -hh, sy + sinr * -hw + cosr * -hh,
        sx + cosr *  hw - sinr * -hh, sy + sinr *  hw + cosr * -hh,
        sx + cosr *  hw - sinr *  hh, sy + sinr *  hw + cosr *  hh,
        sx + cosr * -hw - sinr *  hh, sy + sinr * -hw + cosr *  hh,
    }
    love.graphics.setColor(0, 0, 0, 0.35)
    love.graphics.ellipse("fill", sx, sy + size * 0.4, size * 0.5, size * 0.18)
    love.graphics.setColor(0.25, 0.85, 0.35, 1)
    pcall(love.graphics.polygon, "fill", pts)
    love.graphics.setColor(0.05, 0.4, 0.1, 1)
    pcall(love.graphics.polygon, "line", pts)
    love.graphics.setColor(1, 1, 1, 1)
end

function Renderer.draw(data, cam, player, driving, pedestrians, money_drops)
    local sw, sh = love.graphics.getDimensions()
    local horizon = sh * cam.horizon_frac
    local project_fn = function(wx, wy, wz) return cam:project(wx, wy, wz) end
    local camera_space_fn = function(wx, wy) return cam:camera_space(wx, wy) end

    love.graphics.clear(0.20, 0.23, 0.28)
    love.graphics.setColor(0.12, 0.13, 0.13)
    love.graphics.rectangle("fill", 0, horizon, sw, sh - horizon)

    for _, r in ipairs(data.roads) do
        local w, col = road_style(r.kind)
        local points = r.pts
        for i = 1, #points - 2, 2 do
            draw_road_segment(points[i], points[i + 1], points[i + 2], points[i + 3], w, col, project_fn, camera_space_fn)
        end
    end

    local vis = {}
    for _, b in ipairs(data.buildings) do
        local right, fwd = camera_space_fn(b.cx, b.cy)
        local inside = (right * right + fwd * fwd) < b.radius * b.radius
            and Polygon.contains(b.ring, cam.x, cam.y)
        if fwd < FAR and fwd > NEAR_CLIP - b.radius
            and math.abs(right) < fwd * 2.2 + b.radius + 60 and not inside then
            local nearfwd = fwd
            for i = 1, #b.ring, 2 do
                local _, f = camera_space_fn(b.ring[i], b.ring[i + 1])
                if f < nearfwd then nearfwd = f end
            end
            vis[#vis + 1] = { b = b, d = nearfwd }
        end
    end
    table.sort(vis, function(p, q) return p.d > q.d end)
    for _, v in ipairs(vis) do draw_building(v.b, project_fn, camera_space_fn, cam.x, cam.y) end

    for _, o in ipairs(Interactable.all()) do
        if o.driveable then draw_vehicle(o, project_fn, camera_space_fn) end
    end

    -- Pedestrians: projected sprites on the ground
    if pedestrians then
        for _, ped in ipairs(pedestrians) do
            if ped.alive ~= false then
                local sx, sy, fwd = cam:project(ped.x, ped.y, 0)
                if sx and fwd > 5 and ped.anim then
                    local scale = math.max(0.2, 400 / fwd * 0.03)
                    local fs = ped.frame_size * scale
                    love.graphics.setColor(0, 0, 0, 0.25)
                    love.graphics.ellipse("fill", sx, sy, fs * 0.4, fs * 0.15)
                    local flashing = ped.hit_flash and ped.hit_flash > 0
                    love.graphics.setColor(1, 1, 1, 1)
                    ped.anim:draw(sx - fs / 2, sy - fs, 0, scale, scale)
                    if flashing then
                        love.graphics.setColor(1, 1, 1, 0.7)
                        love.graphics.rectangle("fill", sx - fs / 2, sy - fs, fs, fs)
                    end
                    -- Health bar (only when damaged)
                    if ped.hp and ped.max_hp and ped.hp < ped.max_hp then
                        local bar_w = fs * 0.8
                        local bar_h = math.max(2, scale * 8)
                        local bx = sx - bar_w / 2
                        local by = sy - fs - bar_h - 2
                        local ratio = ped.hp / ped.max_hp
                        love.graphics.setColor(0, 0, 0, 0.6)
                        love.graphics.rectangle("fill", bx - 1, by - 1, bar_w + 2, bar_h + 2)
                        love.graphics.setColor(0.8, 0.1, 0.1, 1)
                        love.graphics.rectangle("fill", bx, by, bar_w, bar_h)
                        love.graphics.setColor(0.1, 0.8, 0.1, 1)
                        love.graphics.rectangle("fill", bx, by, bar_w * ratio, bar_h)
                    end
                    love.graphics.setColor(1, 1, 1, 1)
                end
            end
        end
    end

    -- Money drops: rotating green rectangles hovering above the ground
    if money_drops then
        for _, drop in ipairs(money_drops) do
            draw_money(drop, project_fn)
        end
    end

    local px, py = sw / 2, sh * cam.anchor
    if not driving then
        local player_depth = cam:ground_distance()
        local player_scale = math.max(0.2, 400 / player_depth * 0.03)
        local player_fs = player.frame * player_scale
        love.graphics.setColor(0, 0, 0, 0.25)
        love.graphics.ellipse("fill", px, py, player_fs * 0.4, player_fs * 0.15)
        love.graphics.setColor(1, 1, 1, 1)
        player.anim:draw(px - player_fs / 2, py - player_fs, 0, player_scale, player_scale)
    end

    local prompt
    if driving then
        prompt = "[E] get out"
    else
        local pivot = cam:ground_distance()
        local fx, fy = cam:forward_dir()
        local near = Interactable.nearest(cam.x + fx * pivot, cam.y + fy * pivot, function(o) return o.driveable end)
        if near then prompt = "[E] take the " .. (near.kind or "motor") end
    end
    if prompt then
        love.graphics.setColor(1, 0.9, 0.4, 1)
        local font = love.graphics.getFont()
        love.graphics.print(prompt, (sw - font:getWidth(prompt)) / 2, sh * 0.66)
    end

    -- Attribution
    love.graphics.setColor(1, 1, 1, 0.35)
    local attribution_font = love.graphics.getFont()
    love.graphics.print(data.attribution or "", SCREEN_PADDING, sh - attribution_font:getHeight() - SCREEN_PADDING)
    love.graphics.setColor(1, 1, 1, 1)
end

return Renderer
