if love.system.getOS() == "Android" then
    -- require can't find it on android
    package.preload.luv = package.loadlib("libluv.so", "luaopen_luv")
end
local log = require("log")("ui.overlay.packs.download_thread")
local json = require("extlibs.json.json")
local http = require("socket.http")
local url = require("socket.url")
local zip = require("extlibs.zip")
local https = require("https")
local threadify = require("threadify")
local assets = threadify.require("game_handler.assets")
local uv = require("luv")

local server_api_url = ""

local pack_data_list
local pack_sizes = {}
local download = {}

local function api(suffix)
    local code, json_data = https.request(server_api_url .. suffix)
    if code ~= 200 then
        log("'" .. suffix .. "' api request failed")
        return {}
    end
    if not json_data or (json_data:sub(1, 1) ~= "{" and json_data:sub(1, 1) ~= "[") then
        -- something went wrong
        return {}
    end
    return json.decode(json_data)
end

function download.set_server_url(serv_api_url)
    server_api_url = serv_api_url
end

---gets a list of pack names for the specified game version
---@param version number
---@return table
function download.get_pack_list(version)
    local code, html = https.request("https://openhexagon.fun/packs" .. tostring(version) .. "/")
    if code ~= 200 then
        log("get pack list request failed")
        return {}
    end
    local packs = {}
    for pack in html:gmatch('\n<a href="(.-).zip"') do
        packs[#packs + 1] = url.unescape(pack)
    end
    local index = 1
    pack_sizes[version] = pack_sizes[version] or {}
    for size in html:gmatch('<a href=".-.zip".-..\\-...\\-.... ..:.. (.-)\n') do
        pack_sizes[version][packs[index]] = tonumber(size)
        index = index + 1
    end
    if not pack_data_list then
        pack_data_list = api("get_packs")
        -- remove packs the player already has
        local promise = assets.init({}, true)
        local result
        promise:done(function(res)
            result = res
        end)
        while not promise.executed do
            threadify.update()
            uv.sleep(10)
        end
        if not result then
            error("could not get current pack list")
        end
        local map = {}
        for i = 1, #result do
            local pack = result[i]
            map[pack.game_version] = map[pack.game_version] or {}
            map[pack.game_version][pack.id] = true
        end
        for i = #pack_data_list, 1, -1 do
            local pack = pack_data_list[i]
            if map[pack.game_version] and map[pack.game_version][pack.id] then
                table.remove(pack_data_list, i)
            end
        end
    end
    local list = {}
    for i = 1, #pack_data_list do
        local pack = pack_data_list[i]
        if pack.game_version == version then
            list[#list + 1] = pack
        end
    end
    return list
end

---downloads and extracts a pack in the right location
---@param version number
---@param pack_name string
---@return string?
function download.get(version, pack_name)
    if pack_sizes[version][pack_name] == nil then
        return "Pack has not been compressed on server yet."
    end
    local file = love.filesystem.openFile("tmp.zip", "w")
    local download_size, last_progress = 0, nil
    log("Downloading", pack_name)
    http.request({
        url = "http://openhexagon.fun/packs" .. version .. "/" .. url.escape(pack_name) .. ".zip",
        sink = function(chunk, err)
            if err then
                log(err)
            elseif chunk then
                file:write(chunk)
                download_size = download_size + #chunk
                local progress = math.floor(download_size / pack_sizes[version][pack_name] * 100)
                if progress ~= last_progress then
                    love.thread.getChannel("pack_download_progress"):push(progress)
                    last_progress = progress
                end
                return 1
            end
        end,
    })
    file:close()
    log("Extracting", "tmp.zip")
    local zip_file = zip:new("tmp.zip")
    zip_file:unzip("packs" .. version)
    zip_file:close()
    love.filesystem.remove("tmp.zip")
    for i = #pack_data_list, 1, -1 do
        local pack = pack_data_list[i]
        if pack.game_version == version and pack.folder_name == pack_name then
            table.remove(pack_data_list, i)
            break
        end
    end
    log("Done")
end

return download
