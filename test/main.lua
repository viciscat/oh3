local search_names = {
    "liblove.so",
    "liblove.dll",
}
for i = 1, #search_names do
    package.preload.love = package.loadlib(search_names[i], "luaopen_love")
    if package.preload.love ~= nil then
        break
    end
end
require("love")
require("love.filesystem")
love.filesystem.init("ohtest")
love.filesystem.setIdentity("ohtest")
require("love.arg")
require("love.timer")
require("love.keyboard")
local newarg = { "test", "--pattern", "lua", "--exclude-pattern", "main.lua" }
for i = 1, #arg do
    newarg[#newarg + 1] = arg[i]
end
arg = newarg
require("busted.runner")({ standalone = false })
