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

-- Version in chat and console, so everyone can see which Smart Bots version the host runs.
if package ~= nil and package.loaded ~= nil then package.loaded['bots.FuncLib.systems.version'] = nil end
local okV, Version = pcall(require, 'bots.FuncLib.systems.version')
local sVersion = (okV and type(Version) == 'table' and Version.number) or '?'
if GameRules ~= nil and GameRules.SendCustomMessage ~= nil then
	GameRules:SendCustomMessage('Smart Bots '..sVersion..': server scripts started.', 0, 0)
end
print('[SmartBots] Version '..sVersion..'. Server scripts started.')
