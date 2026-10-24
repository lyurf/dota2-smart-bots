local Customize = nil
function LoadCustomize()
	if Customize then return Customize end
	local sDir, tSet = "game/Customize/general", nil
	-- Smart Bots: pcall instead of xpcall (avoids "error in error handling" when the file is missing)
	local status, res = pcall(require, sDir)
	if status then tSet = res end
	if status and tSet then
		Customize = tSet
	else
		if GetScriptDirectory() == 'bots' then Customize = require('bots.Customize.general')
		else Customize = require( GetScriptDirectory()..'/Customize/general' ) end
	end
	return Customize
end
return LoadCustomize()
