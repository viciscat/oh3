local args = require("args")
local music = {}
local audio

function music.init(audio_module)
    audio = audio_module
end

function music.play(music_data, random_segment, time, pitch)
    if not music_data or args.headless then
        return
    end
    if not music_data.source then
        music_data.source = audio.new_stream(music_data.file_path)
    end
    if music_data.source then
        if time then
            music_data.source:seek(time)
        else
            local segment
            if type(random_segment) == "number" then
                segment = random_segment
            else
                segment = random_segment and math.random(1, #music_data.segments) or 1
            end
            music.segment = music_data.segments[segment]
            music_data.source:seek(music.segment.time or 0)
        end
        music_data.source:set_pitch(pitch or 1)
        music_data.source:play()
    end
    music.playing = music_data
end

function music.set_pitch(pitch)
    if music.playing then
        music.playing.source:set_pitch(pitch)
    end
end

function music.stop()
    if music.playing then
        music.playing.source:stop()
        music.playing.source:release()
        music.playing.source = nil
        music.playing = nil
        music.segment = nil
    end
end

return music