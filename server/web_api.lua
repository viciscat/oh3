local utils = require("compat.game192.utils")
local database = require("server.database")
local json = require("extlibs.json.json")
local msgpack = require("extlibs.msgpack.msgpack")
local threadify = require("threadify")
local threaded_assets = threadify.require("game_handler.assets")
local http = require("extlibs.http")
local url = require("socket.url")
local log = require("log")("server.web_api")
local uv = require("luv")
local zip = require("extlibs.love-zip")

local zip_path = "zip_cache/"
if not love.filesystem.getInfo(zip_path) then
    love.filesystem.createDirectory(zip_path)
end

local args = {
    block = false,
    allow_cors = true,
    keyfile = os.getenv("TLS_KEY"),
    certfile = os.getenv("TLS_CERT"),
}
if args.keyfile and args.certfile then
    args.sslport = 8001
    -- ideally this wouldn't be a thing, but we'll need http support for downloading in chunks, lua-https can only output strings
    args.port = 8003
else
    log("WARNING: Falling back to http as no certificate or key were specified")
    args.port = 8001
end

local app = http:new(args)

json.encode_inf_as_1e500 = true

local packs
local promise = threaded_assets.init({}, true)
promise:done(function(pack_list)
    packs = pack_list
end)
while not promise.executed do
    threadify.update()
    uv.sleep(10)
end
if not packs then
    error("getting pack list failed")
end

database.set_identity(3)

local replay_path = database.get_replay_path()

local function replay_get_video_path(hash)
    local path = replay_path .. hash:sub(1, 2) .. "/" .. hash .. ".mp4"
    if love.filesystem.getInfo(path) then
        return path
    end
end

local newest_scores = database.get_newest_scores(3 * 10 ^ 6)

app.handlers["/get_newest_scores/..."] = function(captures, headers)
    local seconds = math.min(tonumber(captures[1]) or 0, 3 * 10 ^ 6)
    local channel = love.thread.getChannel("new_scores")
    for _ = 1, channel:getCount() do
        newest_scores[#newest_scores + 1] = channel:pop()
    end
    local scores = {}
    for i = 1, #newest_scores do
        if os.time() - newest_scores[i].timestamp < seconds then
            newest_scores[i].has_video = newest_scores[i].replay_hash
                    and replay_get_video_path(newest_scores[i].replay_hash)
                    and true
                or false
            scores[#scores + 1] = newest_scores[i]
        end
    end
    headers["content-type"] = "application/json"
    return json.encode(scores)
end

app.handlers["/get_leaderboard/.../.../..."] = function(captures, headers)
    local pack, level, level_options = unpack(captures)
    if pack and level and level_options then
        pack = url.unescape(pack)
        level = url.unescape(level)
        level_options = json.decode(url.unescape(level_options))
        -- only difficulty_mult needs this as it's the only legacy option
        level_options.difficulty_mult = utils.float_round(level_options.difficulty_mult)
        local lb = database.get_leaderboard(pack, level, msgpack.pack(level_options))
        for i = 1, #lb do
            local score = lb[i]
            score.has_video = score.replay_hash and replay_get_video_path(score.replay_hash) and true or false
        end
        headers["content-type"] = "application/json"
        return json.encode(lb)
    else
        return "invalid options"
    end
end

app.handlers["/get_video/..."] = function(captures, headers)
    local replay_hash = captures[1]
    local path = replay_get_video_path(replay_hash)
    if path then
        return http.file(path, headers)
    else
        return "no video for this replay"
    end
end

app.handlers["/get_packs"] = function(_, headers)
    headers["content-type"] = "application/json"
    return json.encode(packs)
end

app.handlers["/get_pack/.../..."] = function(captures, headers)
    local version, name = unpack(captures)
    local filename = string.format("%s%s_%s.zip", zip_path, version, name)
    if not love.filesystem.getInfo(filename) then
        local pack_path = string.format("packs%s/%s", version, name)
        if love.filesystem.getInfo(pack_path) then
            if not zip.writeZip(pack_path, filename, true) then
                return "Failed to compress pack"
            end
        else
            return string.format("Could not find pack at '%s'!", pack_path)
        end
    end
    return http.file(filename, headers)
end

log("Compressing all packs")
for i = 1, #packs do
    local pack = packs[i]
    local filename = string.format("%s%s_%s.zip", zip_path, pack.game_version, pack.folder_name)
    local info = love.filesystem.getInfo(filename)
    if not info then
        local pack_path = string.format("packs%s/%s", pack.game_version, pack.folder_name)
        log("Compressing " .. pack_path)
        if not zip.writeZip(pack_path, filename) then
            error("Failed to compress pack")
        end
        info = love.filesystem.getInfo(filename)
    end
    packs[i].file_size = info.size
end
log("Done compressing all packs")

app:run()
