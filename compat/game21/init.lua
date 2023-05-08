-- 2.1.X compatibility mode
local Timeline = require("compat.game21.timeline")
local Quads = require("compat.game21.dynamic_quads")
local Tris = require("compat.game21.dynamic_tris")
local set_color = require("compat.game21.color_transform")
local Particles = require("compat.game21.particles")
local game = {
    config = require("compat.game21.config"),
    assets = require("compat.game21.assets"),
    lua_runtime = require("compat.game21.lua_runtime"),
    level_status = require("compat.game21.level_status"),
    running = false,
    level_data = nil,
    pack_data = nil,
    difficulty_mult = nil,
    music = nil,
    seed = nil,
    message_text = "",
    last_move = 0,
    must_change_sides = false,
    current_rotation = 0,
    status = require("compat.game21.status"),
    style = require("compat.game21.style"),
    player = require("compat.game21.player"),
    player_now_ready_to_swap = false,
    event_timeline = Timeline:new(),
    message_timeline = Timeline:new(),
    main_timeline = Timeline:new(),
    custom_timelines = require("compat.game21.custom_timelines"),
    first_play = true,
    walls = require("compat.game21.walls"),
    custom_walls = require("compat.game21.custom_walls"),
    flash_color = { 0, 0, 0, 0 },
    wall_quads = Quads:new(),
    pivot_quads = Quads:new(),
    player_tris = Tris:new(),
    cap_tris = Tris:new(),
    layer_offsets = {},
    pivot_layer_colors = {},
    wall_layer_colors = {},
    player_layer_colors = {},
    death_shake_translate = { 0, 0 },
    current_trail_color = { 0, 0, 0, 0 },
    swap_particle_info = { x = 0, y = 0, angle = 0 },
    layer_shader = love.graphics.newShader(
        [[
            attribute vec2 instance_position;
            attribute vec4 instance_color;
            varying vec4 instance_color_out;

            vec4 position(mat4 transform_projection, vec4 vertex_position)
            {
                instance_color_out = instance_color / 255.0;
                vertex_position.xy += instance_position;
                return transform_projection * vertex_position;
            }
        ]],
        [[
            varying vec4 instance_color_out;

            vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
            {
                return instance_color_out;
            }
        ]]
    ),
    width = love.graphics.getWidth(),
    height = love.graphics.getHeight(),
}

game.message_font = game.assets.get_font("OpenSquare-Regular.ttf", 32 * game.config.get("text_scale"))
game.go_sound = game.assets.get_sound("go.ogg")
game.swap_blip_sound = game.assets.get_sound("swap_blip.ogg")
game.level_up_sound = game.assets.get_sound("level_up.ogg")
game.restart_sound = game.assets.get_sound("restart.ogg")
game.select_sound = game.assets.get_sound("select.ogg")
game.small_circle = game.assets.get_image("smallCircle.png")
game.trail_particles = Particles:new(game.small_circle, function(p, frametime)
    p.color[4] = p.color[4] - game.trail_particles.alpha_decay / 255 * frametime
    p.scale = p.scale * 0.98
    local distance = game.status.radius + 2.4
    p.x, p.y = math.cos(p.angle) * distance, math.sin(p.angle) * distance
    return p.color[4] <= 3 / 255
end, game.config.get("player_trail_alpha"), game.config.get("player_trail_decay"))
game.swap_particles = Particles:new(game.small_circle, function(p, frametime)
    p.color[4] = p.color[4] - 3.5 / 255 * frametime
    p.scale = p.scale * 0.98
    p.x = p.x + math.cos(p.angle) * p.speed_mult * frametime
    p.y = p.y + math.sin(p.angle) * p.speed_mult * frametime
    return p.color[4] <= 3 / 255
end)
game.spawn_swap_particles_ready = false
game.must_spawn_swap_particles = false

function game:start(pack_folder, level_id, difficulty_mult)
    self.pack_data = self.assets.get_pack(pack_folder)
    self.level_data = self.pack_data.levels[level_id]
    self.level_status.reset(self.config.get("sync_music_to_dm"), self.assets)
    self.style.select(self.pack_data.styles[self.level_data.styleId])
    self.style.compute_colors()
    self.difficulty_mult = difficulty_mult
    self.status.reset_all_data()
    self.music = self.pack_data.music[self.level_data.musicId]
    if self.music == nil then
        error("Music with id '" .. self.level_data.musicId .. "' doesn't exist!")
    end
    self:refresh_music_pitch()
    local segment
    if self.first_play then
        segment = self.music.segments[1]
    else
        segment = self.music.segments[math.random(1, #self.music.segments)]
    end
    self.status.beat_pulse_delay = self.status.beat_pulse_delay + (segment.beat_pulse_delay_offset or 0)
    if self.music.source ~= nil then
        self.music.source:seek(segment.time)
        love.audio.play(self.music.source)
    end

    -- initialize random seed
    -- TODO: replays (need to read random seed from file)
    self.seed = math.floor(love.timer.getTime() * 1000)
    math.randomseed(self.seed)
    math.random()

    self.event_timeline:clear()
    self.message_timeline:clear()
    self.custom_timelines:reset()
    self.walls.reset(self.level_status)
    self.custom_walls.cw_clear()

    self.player.reset(
        self:get_swap_cooldown(),
        self.config.get("player_size"),
        self.config.get("player_speed"),
        self.config.get("player_focus_speed")
    )

    self.flash_color = { 255, 255, 255, 0 }

    self.current_rotation = 0
    self.must_change_sides = false
    if not self.first_play then
        self.lua_runtime.run_fn_if_exists("onPreUnload")
    end
    self.lua_runtime.init_env(self)
    self.lua_runtime.run_lua_file(self.pack_data.path .. "/" .. self.level_data.luaFile)
    self.running = true
    if self.first_play then
        love.audio.play(self.select_sound)
    else
        self.lua_runtime.run_fn_if_exists("onUnload")
        love.audio.play(self.restart_sound)
    end
    self.lua_runtime.run_fn_if_exists("onInit")
    self:set_sides(self.level_status.sides)
    self.status.pulse_delay = self.status.pulse_delay + self.level_status.pulse_initial_delay
    self.status.beat_pulse_delay = self.status.beat_pulse_delay + self.level_status.beat_pulse_initial_delay
    self.status.start()
    self.message_text = ""
    love.audio.play(self.go_sound)
    self.lua_runtime.run_fn_if_exists("onLoad")

    self.trail_particles:reset()
    self.swap_particles:reset(30)
end

function game:get_speed_mult_dm()
    local result = self.level_status.speed_mult * math.pow(self.difficulty_mult, 0.65)
    if not self.level_status.has_speed_max_limit() then
        return result
    end
    return result < self.level_status.speed_max and result or self.level_status.speed_max
end

function game:perform_player_kill()
    local fatal = not self.config.get("invincible") and not self.level_status.tutorial_mode
    self.player.kill(fatal)
    self:death()
end

function game:death(force)
    if not self.status.has_died then
        self.lua_runtime.run_fn_if_exists("onPreDeath")
        if force or not (self.level_status.tutorial_mode or self.config.get("invincible")) then
            self.lua_runtime.run_fn_if_exists("onDeath")
            self.status.camera_shake = 45 * self.config.get("camera_shake_mult")
            love.audio.stop()
            self.flash_color[1] = 255
            self.flash_color[2] = 255
            self.flash_color[3] = 255
            self.status.flash_effect = 255
            self.status.has_died = true
        end
        love.audio.play(self.level_status.death_sound)
    end
end

function game:perform_player_swap(play_sound)
    self.player.player_swap()
    self.lua_runtime.run_fn_if_exists("onCursorSwap")
    if play_sound then
        love.audio.play(self.level_status.swap_sound)
    end
end

function game:get_music_dm_sync_factor()
    return math.pow(self.difficulty_mult, 0.12)
end

function game:refresh_music_pitch()
    if self.music.source ~= nil then
        local pitch = self.level_status.music_pitch
            * self.config.get("music_speed_mult")
            * (self.level_status.sync_music_to_dm and self:get_music_dm_sync_factor() or 1)
        if pitch ~= pitch then
            -- pitch is NaN, happens with negative difficulty mults
            pitch = 1
        end
        if pitch < 0 then
            -- pitch can't be 0, setting it to almost 0, not sure if this could cause issues
            pitch = 0.001
        end
        self.music.source:setPitch(pitch)
    end
end

function game:get_swap_cooldown()
    return math.max(36 * self.level_status.swap_cooldown_mult, 8)
end

function game:set_sides(sides)
    love.audio.play(self.level_status.beep_sound)
    if sides < 3 then
        sides = 3
    end
    self.level_status.sides = sides
end

function game:increment_difficulty()
    love.audio.play(self.level_up_sound)
    local sign_mult = self.level_status.rotation_speed > 0 and 1 or -1
    self.level_status.rotation_speed = self.level_status.rotation_speed
        + self.level_status.rotation_speed_inc * sign_mult
    if math.abs(self.level_status.rotation_speed) > self.level_status.rotation_speed_max then
        self.level_status.rotation_speed = self.level_status.rotation_speed_max * sign_mult
    end
    self.level_status.rotation_speed = -self.level_status.rotation_speed
    self.status.fast_spin = self.level_status.fast_spin
end

function game:update(frametime)
    frametime = frametime * 60
    -- TODO: don't update if debug pause

    -- update flash
    if self.status.flash_effect > 0 then
        self.status.flash_effect = self.status.flash_effect - 3 * frametime
    end
    if self.status.flash_effect < 0 then
        self.status.flash_effect = 0
    elseif self.status.flash_effect > 255 then
        self.status.flash_effect = 255
    end
    self.flash_color[4] = self.status.flash_effect

    -- update input
    local focus = love.keyboard.isDown(self.config.get("key_focus"))
    local swap = love.keyboard.isDown(self.config.get("key_swap"))
    local cw = love.keyboard.isDown(self.config.get("key_right"))
    local ccw = love.keyboard.isDown(self.config.get("key_left"))
    local move
    if cw and not ccw then
        move = 1
        self.last_move = 1
    elseif not cw and ccw then
        move = -1
        self.last_move = -1
    elseif cw and ccw then
        move = -self.last_move
    else
        move = 0
    end
    -- TODO: update key icons and level info, or in ui code?
    if self.running then
        self.style.compute_colors()
        self.player.update(focus, self.level_status.swap_enabled, frametime)
        if not self.status.has_died then
            local prevent_player_input = self.lua_runtime.run_fn_if_exists("onInput", frametime, move, focus, swap)
            if not prevent_player_input then
                self.player.update_input_movement(move, self.level_status.player_speed_mult, focus, frametime)
                if not self.player_now_ready_to_swap and self.player.is_ready_to_swap() then
                    self.must_spawn_swap_particles = true
                    self.spawn_swap_particles_ready = true
                    self.swap_particle_info.x, self.swap_particle_info.y = self.player.get_position()
                    self.swap_particle_info.angle = self.player.get_player_angle()
                    self.player_now_ready_to_swap = true
                    if self.config.get("play_swap_sound") then
                        love.audio.play(self.swap_blip_sound)
                    end
                end
                if self.level_status.swap_enabled and swap and self.player.is_ready_to_swap() then
                    self.must_spawn_swap_particles = true
                    self.spawn_swap_particles_ready = false
                    self.swap_particle_info.x, self.swap_particle_info.y = self.player.get_position()
                    self.swap_particle_info.angle = self.player.get_player_angle()
                    self:perform_player_swap(true)
                    self.player.reset_swap(self:get_swap_cooldown())
                    self.player.set_just_swapped(true)
                    self.player_now_ready_to_swap = false
                else
                    self.player.set_just_swapped(false)
                end
            end
            self.status.accumulate_frametime(frametime)
            if self.level_status.score_overwritten then
                self.status.update_custom_score(self.lua_runtime.env[self.level_status.score_overwrite])
            end

            -- events
            if self.event_timeline:update(self.status.get_time_tp()) then
                self.event_timeline:clear()
            end
            if self.message_timeline:update(self.status.get_current_tp()) then
                self.message_timeline:clear()
            end

            -- increment
            if
                self.level_status.inc_enabled
                and self.status.get_increment_time_seconds() >= self.level_status.inc_time
            then
                self.level_status.current_increments = self.level_status.current_increments + 1
                self:increment_difficulty()
                self.status.reset_increment_time()
                self.must_change_sides = true
            end

            if self.must_change_sides and self.walls.empty() then
                local side_number = math.random(self.level_status.sides_min, self.level_status.sides_max)
                self.level_status.speed_mult = self.level_status.speed_mult + self.level_status.speed_inc
                self.level_status.delay_mult = self.level_status.delay_mult + self.level_status.delay_inc
                if self.level_status.rnd_side_changes_enabled then
                    self:set_sides(side_number)
                end
                self.must_change_sides = false
                love.audio.play(self.level_status.level_up_sound)
                self.lua_runtime.run_fn_if_exists("onIncrement")
            end

            if not self.status.is_time_paused() then
                self.lua_runtime.run_fn_if_exists("onUpdate", frametime)
                if self.main_timeline:update(self.status.get_time_tp()) and not self.must_change_sides then
                    self.main_timeline:clear()
                    self.lua_runtime.run_fn_if_exists("onStep")
                end
            end
            self.custom_timelines.update(self.status.get_current_tp())

            if self.config.get("beatpulse") then
                if not self.level_status.manual_beat_pulse_control then
                    if self.status.beat_pulse_delay <= 0 then
                        self.status.beat_pulse = self.level_status.beat_pulse_max
                        self.status.beat_pulse_delay = self.level_status.beat_pulse_delay_max
                    else
                        self.status.beat_pulse_delay = self.status.beat_pulse_delay
                            - frametime * self:get_music_dm_sync_factor()
                    end
                    if self.status.beat_pulse > 0 then
                        self.status.beat_pulse = self.status.beat_pulse
                            - 2
                                * frametime
                                * self:get_music_dm_sync_factor()
                                * self.level_status.beat_pulse_speed_mult
                    end
                end
            end
            local radius_min = self.config.get("beatpulse") and self.level_status.radius_min or 75
            self.status.radius = radius_min * (self.status.pulse / self.level_status.pulse_min) + self.status.beat_pulse

            if not self.level_status.manual_pulse_control then
                if self.status.pulse_delay <= 0 then
                    local pulse_add = self.status.pulse_direction > 0 and self.level_status.pulse_speed
                        or -self.level_status.pulse_speed_r
                    local pulse_limit = self.status.pulse_direction > 0 and self.level_status.pulse_max
                        or self.level_status.pulse_min
                    self.status.pulse = self.status.pulse + pulse_add * frametime * self:get_music_dm_sync_factor()
                    if
                        (self.status.pulse_direction > 0 and self.status.pulse >= pulse_limit)
                        or (self.status.pulse_direction < 0 and self.status.pulse <= pulse_limit)
                    then
                        self.status.pulse = pulse_limit
                        self.status.pulse_direction = -self.status.pulse_direction
                        if self.status.pulse_direction < 0 then
                            self.status.pulse_delay = self.level_status.pulse_delay_max
                        end
                    end
                end
                self.status.pulse_delay = self.status.pulse_delay - frametime * self:get_music_dm_sync_factor()
            end

            if not self.config.get("black_and_white") then
                self.style.update(frametime, math.pow(self.difficulty_mult, 0.8))
            end

            self.player.update_position(self.status.radius)
            self.walls.update(frametime, self.status.radius)
            if
                self.walls.handle_collision(move, frametime, self.player, self.status.radius)
                or self.custom_walls.handle_collision(move, self.status.radius, self.player, frametime)
            then
                self:perform_player_kill()
            end
        else
            self.level_status.rotation_speed = self.level_status.rotation_speed * 0.99
        end

        self.status.pulse3D = self.status.pulse3D
            + self.style.pseudo_3D_pulse_speed * self.status.pulse3D_direction * frametime
        if self.status.pulse3D > self.style.pseudo_3D_pulse_max then
            self.status.pulse3D_direction = -1
        elseif self.status.pulse3D < self.style.pseudo_3D_pulse_min then
            self.status.pulse3D_direction = 1
        end
        -- update rotation
        local next_rotation = self.level_status.rotation_speed * 10
        if self.status.fast_spin > 0 then
            local function get_sign(num)
                return (num > 0 and 1 or (num == 0 and 0 or -1))
            end
            local function get_smoother_step(edge0, edge1, x)
                x = math.max(0, math.min(1, (x - edge0) / (edge1 - edge0)))
                return x * x * x * (x * (x * 6 - 15) + 10)
            end
            next_rotation = next_rotation
                + math.abs((get_smoother_step(0, self.level_status.fast_spin, self.status.fast_spin) / 3.5) * 17)
                    * get_sign(next_rotation)
            self.status.fast_spin = self.status.fast_spin - frametime
        end
        self.current_rotation = self.current_rotation + next_rotation * frametime

        if self.status.camera_shake <= 0 then
            self.death_shake_translate[1] = 0
            self.death_shake_translate[2] = 0
        else
            self.status.camera_shake = self.status.camera_shake - frametime
            self.death_shake_translate[1] = (1 - math.random() * 2) * self.status.camera_shake
            self.death_shake_translate[2] = (1 - math.random() * 2) * self.status.camera_shake
        end

        if not self.status.has_died then
            math.random(math.abs(self.status.pulse * 1000))
            math.random(math.abs(self.status.pulse3D * 1000))
            math.random(math.abs(self.status.fast_spin * 1000))
            math.random(math.abs(self.status.flash_effect * 1000))
            math.random(math.abs(self.level_status.rotation_speed * 1000))
        end

        -- update trail color (also used for swap particles)
        self.current_trail_color[1], self.current_trail_color[2], self.current_trail_color[3] =
            self.style.get_player_color()
        if self.config.get("black_and_white") then
            self.current_trail_color[1], self.current_trail_color[2], self.current_trail_color[3] = 255, 255, 255
        else
            if self.config.get("player_trail_has_swap_color") then
                self.player.get_color_adjusted_for_swap(self.current_trail_color)
            else
                self.player.get_color(self.current_trail_color)
            end
        end
        self.current_trail_color[4] = self.config.get("player_trail_alpha")

        if self.config.get("show_player_trail") and self.status.show_player_trail then
            self.trail_particles:update(frametime)
            if self.player.has_changed_angle() then
                local x, y = self.player.get_position()
                self.trail_particles:emit(
                    x,
                    y,
                    self.config.get("player_trail_scale"),
                    self.player.get_player_angle(),
                    unpack(self.current_trail_color)
                )
            end
        end

        if self.config.get("show_swap_particles") then
            self.swap_particles:update(frametime)
            if self.must_spawn_swap_particles then
                self.must_spawn_swap_particles = false
                local function spawn_particle(expand, speed_mult, scale_mult, alpha)
                    self.swap_particles.spawn_alpha = alpha
                    self.swap_particles:emit(
                        self.swap_particle_info.x,
                        self.swap_particle_info.y,
                        (love.math.random() * 0.7 + 0.65) * scale_mult,
                        self.swap_particle_info.angle + (love.math.random() * 2 - 1) * expand,
                        self.current_trail_color[1],
                        self.current_trail_color[2],
                        self.current_trail_color[3],
                        (love.math.random() * 9.9 + 0.1) * speed_mult
                    )
                end
                if self.spawn_swap_particles_ready then
                    for _ = 1, 14 do
                        spawn_particle(3.14, 1.3, 0.4, 140)
                    end
                else
                    for _ = 1, 20 do
                        spawn_particle(0.45, 1, 1, 45)
                    end
                    for _ = 1, 10 do
                        spawn_particle(3.14, 0.45, 0.75, 35)
                    end
                end
            end
        end

        if self.status.must_state_change ~= "none" then
            -- other values are "mustRestart" or "mustReplay"
            -- so currently the only possebility is "mustRestart"
            self:start(self.pack_data.path, self.level_data.id, self.difficulty_mult)
        end
        -- supress empty block warning for now
        --- @diagnostic disable
        if self.level_status.pseudo_3D_required and not self.config.get("3D_enabled") then
            -- TODO: invalidate score
        end
        if self.level_status.shaders_required and not self.config.get("shaders") then
            -- TODO: invalidate score
        end
        --- @diagnostic enable
    end
end

function game:draw(screen)
    -- for lua access
    self.width, self.height = screen:getDimensions()

    -- do the resize adjustment the old game did after already enforcing our aspect ratio
    local zoom_factor = 1 / math.max(1024 / self.width, 768 / self.height)
    -- apply pulse as well
    local p = self.config.get("pulse") and self.status.pulse / self.level_status.pulse_min or 1
    love.graphics.scale(zoom_factor / p, zoom_factor / p)
    love.graphics.translate(unpack(self.death_shake_translate))

    if not self.status.has_died then
        if self.level_status.camera_shake > 0 then
            love.graphics.translate(
                -- use love.math.random instead of math.random to not break replay rng
                (love.math.random() * 2 - 1) * self.level_status.camera_shake,
                (love.math.random() * 2 - 1) * self.level_status.camera_shake
            )
        end
    end
    local depth, pulse_3d, effect, rad_rot, sin_rot, cos_rot
    if self.config.get("3D_enabled") then
        depth = self.style.pseudo_3D_depth
        pulse_3d = self.config.get("pulse") and self.status.pulse3D or 1
        effect = self.style.pseudo_3D_skew * pulse_3d * self.config.get("3D_multiplier")
        rad_rot = math.rad(self.current_rotation + 90)
        sin_rot = math.sin(rad_rot)
        cos_rot = math.cos(rad_rot)
        love.graphics.scale(1, 1 / (1 + effect))
    end

    -- apply rotation
    love.graphics.rotate(-math.rad(self.current_rotation))

    local function set_render_stage(render_stage, no_shader, instanced)
        if self.config.get("shaders") then
            local shader = self.status.fragment_shaders[render_stage]
            if shader ~= nil then
                self.lua_runtime.run_fn_if_exists("onRenderStage", render_stage, love.timer.getDelta() * 60)
                if instanced then
                    love.graphics.setShader(shader.instance_shader)
                else
                    if render_stage ~= 8 then
                        love.graphics.setShader(shader.shader)
                    else
                        love.graphics.setShader(shader.text_shader)
                    end
                end
            else
                love.graphics.setShader(no_shader)
            end
        end
    end

    local black_and_white = self.config.get("black_and_white")
    if self.config.get("background") then
        set_render_stage(0)
        self.style.draw_background(
            self.level_status.sides,
            self.level_status.darken_uneven_background_chunk,
            black_and_white
        )
    end

    self.wall_quads:clear()
    self.walls.draw(self.style, self.wall_quads, black_and_white)
    self.custom_walls.draw(self.wall_quads)

    self.player_tris:clear()
    self.pivot_quads:clear()
    self.cap_tris:clear()
    if self.status.started then
        self.player.draw(
            self.level_status.sides,
            self.style,
            self.pivot_quads,
            self.player_tris,
            self.cap_tris,
            self.config.get("player_tilt_intensity"),
            self.config.get("swap_blinking_effect"),
            black_and_white
        )
    end
    love.graphics.setColor(1, 1, 1, 1)

    if self.config.get("3D_enabled") then
        local function adjust_alpha(a, i)
            if self.style.pseudo_3D_alpha_mult == 0 then
                return a
            end
            local new_alpha = (a / self.style.pseudo_3D_alpha_mult) - i * self.style.pseudo_3D_alpha_falloff
            if new_alpha > 255 then
                return 255
            elseif new_alpha < 0 then
                return 0
            end
            return new_alpha
        end
        for j = 1, depth do
            local i = depth - j
            local offset = self.style.pseudo_3D_spacing
                * (i + 1)
                * self.style.pseudo_3D_perspective_mult
                * effect
                * 3.6
                * 1.4
            self.layer_offsets[j] = self.layer_offsets[j] or {}
            self.layer_offsets[j][1] = offset * cos_rot
            self.layer_offsets[j][2] = offset * sin_rot
            local r, g, b, a = self.style.get_3D_override_color()
            if black_and_white then
                r, g, b = 255, 255, 255
                self.style.pseudo_3D_override_is_main = false
            end
            r = r / self.style.pseudo_3D_darken_mult
            g = g / self.style.pseudo_3D_darken_mult
            b = b / self.style.pseudo_3D_darken_mult
            a = adjust_alpha(a, i)
            self.pivot_layer_colors[j] = self.pivot_layer_colors[j] or {}
            self.pivot_layer_colors[j][1] = r
            self.pivot_layer_colors[j][2] = g
            self.pivot_layer_colors[j][3] = b
            self.pivot_layer_colors[j][4] = a
            if self.style.pseudo_3D_override_is_main then
                r, g, b, a = self.style.get_wall_color()
                r = r / self.style.pseudo_3D_darken_mult
                g = g / self.style.pseudo_3D_darken_mult
                b = b / self.style.pseudo_3D_darken_mult
                a = adjust_alpha(a, i)
            end
            self.wall_layer_colors[j] = self.wall_layer_colors[j] or {}
            self.wall_layer_colors[j][1] = r
            self.wall_layer_colors[j][2] = g
            self.wall_layer_colors[j][3] = b
            self.wall_layer_colors[j][4] = a
            if self.style.pseudo_3D_override_is_main then
                r, g, b, a = self.style.get_player_color()
                r = r / self.style.pseudo_3D_darken_mult
                g = g / self.style.pseudo_3D_darken_mult
                b = b / self.style.pseudo_3D_darken_mult
                a = adjust_alpha(a, i)
            end
            self.player_layer_colors[j] = self.player_layer_colors[j] or {}
            self.player_layer_colors[j][1] = r
            self.player_layer_colors[j][2] = g
            self.player_layer_colors[j][3] = b
            self.player_layer_colors[j][4] = a
        end
        if depth > 0 then
            self.wall_quads:set_instance_attribute_array("instance_position", "float", 2, self.layer_offsets)
            self.wall_quads:set_instance_attribute_array("instance_color", "float", 4, self.wall_layer_colors)
            self.pivot_quads:set_instance_attribute_array("instance_position", "float", 2, self.layer_offsets)
            self.pivot_quads:set_instance_attribute_array("instance_color", "float", 4, self.pivot_layer_colors)
            self.player_tris:set_instance_attribute_array("instance_position", "float", 2, self.layer_offsets)
            self.player_tris:set_instance_attribute_array("instance_color", "float", 4, self.player_layer_colors)

            set_render_stage(1, self.layer_shader, true)
            self.wall_quads:draw_instanced(depth)
            set_render_stage(2, self.layer_shader, true)
            self.pivot_quads:draw_instanced(depth)
            set_render_stage(3, self.layer_shader, true)
            self.player_tris:draw_instanced(depth)
        end
    end

    if self.config.get("show_player_trail") and self.status.show_player_trail then
        love.graphics.setShader()
        love.graphics.draw(self.trail_particles.batch)
    end

    if self.config.get("show_swap_particles") then
        love.graphics.setShader()
        love.graphics.draw(self.swap_particles.batch)
    end

    set_render_stage(4)
    self.wall_quads:draw()
    set_render_stage(5)
    self.cap_tris:draw()
    set_render_stage(6)
    self.pivot_quads:draw()
    set_render_stage(7)
    self.player_tris:draw()

    -- text shouldn't be affected by rotation/pulse
    love.graphics.origin()
    love.graphics.scale(zoom_factor, zoom_factor)
    love.graphics.translate(unpack(self.death_shake_translate))
    set_render_stage(8)
    if self.message_text ~= "" then
        -- text
        -- TODO: offset_color = self.style.get_color(0)  -- black in bw mode
        -- TODO: draw outlines (if not disabled in config)
        local r, g, b, a = self.style.get_text_color()
        if black_and_white then
            r, g, b = 255, 255, 255
        end
        set_color(r, g, b, a)
        love.graphics.print(
            self.message_text,
            game.message_font,
            self.width / zoom_factor / 2 - game.message_font:getWidth(self.message_text) / 2,
            self.height / zoom_factor / 5.5
        )
    end

    -- reset render stage shaders
    love.graphics.setShader()

    -- flash shouldnt be affected by rotation/pulse/camera_shake
    love.graphics.origin()
    love.graphics.scale(zoom_factor, zoom_factor)
    if self.flash_color[4] ~= 0 and self.config.get("flash") then
        set_color(unpack(self.flash_color))
        love.graphics.rectangle("fill", 0, 0, self.width / zoom_factor, self.height / zoom_factor)
    end
end

return game
