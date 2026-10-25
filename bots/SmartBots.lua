--[[
Smart Bots (HATS) - server scripts launcher.

Starts all Smart Bots server scripts with one command. Once per game, during hero
selection, in a lobby with "Enable Cheats" checked:
    sv_cheats 1; script_reload_code bots/SmartBots
--]]

local SCRIPTS = { 'bots.FairNeutrals', 'bots.SmartPace' }

for _, name in ipairs(SCRIPTS) do
	-- forget a copy loaded in an earlier game so the script really starts again
	if package ~= nil and package.loaded ~= nil then package.loaded[name] = nil end
	local ok, err = pcall(require, name)
	if not ok then print('[SmartBots] '..name..' failed: '..tostring(err)) end
end

print('[SmartBots] Server scripts started.')
