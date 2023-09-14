local threadify = require("threadify")
local threaded_assets = threadify.require("game_handler.assets")
local async = require("async")
local assets = {}
local audio_module, sound_volume
local sound_path = "assets/audio/"
local cached_sounds = {}
local cached_packs = {}
local packs = {}

function assets.init(audio, config)
    sound_volume = config.get("sound_volume")
    audio_module = audio
end

assets.get_pack = async(function(folder)
    if not cached_packs[folder] then
        cached_packs[folder] = async.await(threaded_assets.get_pack(20, folder))
    end
    return cached_packs[folder]
end)

function assets.get_sound(filename)
    if not cached_sounds[filename] then
        if love.filesystem.getInfo(sound_path .. filename) then
            cached_sounds[filename] = audio_module.new_static(sound_path .. filename)
            cached_sounds[filename].volume = sound_volume
        else
            if filename:match("_") then
                -- possibly a pack sound
                local location = filename:find("_")
                local pack = filename:sub(1, location - 1)
                if packs[pack] then
                    local name = filename:sub(location + 1)
                    local path = packs[pack].path .. "Sounds/" .. name
                    if not love.filesystem.getInfo(path) then
                        return
                    end
                    cached_sounds[filename] = audio_module.new_static(path)
                    cached_sounds[filename].volume = sound_volume
                end
            end
            return
        end
    end
    return cached_sounds[filename]
end

return assets
