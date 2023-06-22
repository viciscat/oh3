local msgpack = require("extlibs.msgpack.msgpack")
local replay = require("game_handler.replay")
local game_handler = require("game_handler")
local database = require("server.database")
local config = require("config")
local uv = require("luv")

database.set_identity(1)

local replay_path = database.get_replay_path()

game_handler.init(config)
local level_validators = {}
local levels = {}
local packs = game_handler.get_packs()
for j = 1, #packs do
    local pack = packs[j]
    if pack.game_version == 21 then
        for k = 1, pack.level_count do
            local level = pack.levels[k]
            local encoded_opts = msgpack.pack(level.options.difficulty_mult)
            for i = 1, #level.options.difficulty_mult do
                level_validators[#level_validators + 1] = pack.id .. "_" .. level.id .. "_m_" .. level.options.difficulty_mult[i]
                levels[#levels + 1] = pack.id
                levels[#levels + 1] = level.id
                levels[#levels + 1] = encoded_opts
            end
        end
    end
end
love.thread.getChannel("ranked_levels"):push(level_validators)
love.thread.getChannel("ranked_levels"):push(levels)

local time_tolerance = 3
local score_tolerance = 0.2
local max_processing_time = 10

local function save_replay(replay_obj, hash, data)
    local dir = replay_path .. hash:sub(1, 2) .. "/"
    if not love.filesystem.getInfo(dir) then
        love.filesystem.createDirectory(dir)
    end
    local n
    local path = dir .. hash
    -- in case a replay actually has a duplicate hash (which is almost impossible) add some random numbers to it
    if love.filesystem.getInfo(path) then
        path = path .. 0
        n = 0
        while love.filesystem.getInfo(path) do
            n = n + 1
            path = path:sub(1, -2) .. n
        end
        hash = hash .. n
    end
    replay_obj:save(path, data)
end

local function verify_replay(compressed_replay, time, steam_id)
    local start = uv.hrtime()
    local decoded_replay = replay:new_from_data(compressed_replay)
    game_handler.replay_start(decoded_replay)
    game_handler.run_until_death(function()
        if uv.hrtime() - start > max_processing_time * 1000000000 then
            print("exceeded max processing time")
            return true
        end
        return false
    end)
    local score = game_handler.get_score()
    if score + score_tolerance > decoded_replay.score and score - score_tolerance < decoded_replay.score then
        if time + time_tolerance > score and time - time_tolerance < score then
            print("replay verified")
            local hash, data = decoded_replay:get_hash()
            if database.save_score(
                time,
                steam_id,
                decoded_replay.pack_id,
                decoded_replay.level_id,
                msgpack.pack(decoded_replay.data.level_settings),
                score,
                hash
            ) then
                save_replay(decoded_replay, hash, data)
                print("Saved new score")
            end
        else
            print("time between packets of " .. time .. " does not match score of " .. score)
        end
    else
        print("The replay's score of " .. decoded_replay.score .. " does not match the actual score of " .. score)
    end
end

local run = true
while run do
    local cmd = love.thread.getChannel("game_commands"):demand()
    if cmd[1] == "rp" then
        verify_replay(cmd[2], cmd[3], cmd[4])
    elseif cmd[1] == "stop" then
        run = false
    end
end
