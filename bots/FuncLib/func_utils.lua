local Fu = {}

-- Cache key registry for numeric cache lookups (avoids string concat)
-- Source: typescript/bots/FuncLib/systems/cache_keys.ts (compiled to Lua via tstl)
Fu.CK = require( GetScriptDirectory()..'/FuncLib/systems/cache_keys' )

-- Data & system modules (accessed as Fu.Site, Fu.Item, etc.)
Fu.Site = require( GetScriptDirectory()..'/FuncLib/data/site' )           -- Neutral camp data, farm timing, lane info
Fu.Item = require( GetScriptDirectory()..'/FuncLib/systems/item' )        -- Item build lists, purchase logic, item utilities
Fu.Buff = require( GetScriptDirectory()..'/FuncLib/data/buff' )           -- Buff/debuff definitions and modifier lookups
Fu.Role = require( GetScriptDirectory()..'/FuncLib/systems/role' )        -- Position/role assignment (pos 1-5), PvN mode checks
Fu.Skill = require( GetScriptDirectory()..'/FuncLib/systems/skill' )      -- Ability build orders, talent trees, skill list helpers
Fu.Chat = require( GetScriptDirectory()..'/FuncLib/systems/chat' )        -- Chat messages and trash talk (local only)
Fu.Utils = require( GetScriptDirectory()..'/FuncLib/systems/utils' )      -- General utilities: distance, caching, TP helpers, game state
Fu.Customize = require(GetScriptDirectory()..'/FuncLib/systems/custom_loader') -- Loads user settings from Customize/general.lua

-- Mixin modules (each injects Fu.* functions directly onto the Fu table)
require( GetScriptDirectory()..'/FuncLib/general_utils/unit_check' )(Fu)      -- IsValid, IsValidHero, IsUnitValid, CanBeAttacked
require( GetScriptDirectory()..'/FuncLib/general_utils/hero_state' )(Fu)      -- GetHP, GetMP, GetModifierTime, HasItem, hero status checks
require( GetScriptDirectory()..'/FuncLib/general_utils/math_helper' )(Fu)     -- GetDistance, IsInRange, VectorTowards, VectorAway, remap helpers
require( GetScriptDirectory()..'/FuncLib/general_utils/combat' )(Fu)          -- WeAreStronger, CanKillTarget, GetEstimatedDamage, fight evaluation
require( GetScriptDirectory()..'/FuncLib/general_utils/targeting' )(Fu)       -- GetProperTarget, GetMostHpUnit, GetWeakestUnit, target selection
require( GetScriptDirectory()..'/FuncLib/general_utils/positioning' )(Fu)     -- IsInAllyArea, IsInEnemyArea, fountain locations, area checks
require( GetScriptDirectory()..'/FuncLib/general_utils/team_info' )(Fu)       -- GetAllyCount, GetEnemyCount, GetAlliesNearLoc, GetEnemiesNearLoc
require( GetScriptDirectory()..'/FuncLib/general_utils/bot_mode' )(Fu)        -- IsRetreating, IsPushing, IsDefending, IsDoingRoshan, IsFarming
require( GetScriptDirectory()..'/FuncLib/general_utils/item_ability' )(Fu)    -- IsItemAvailable, CanCastAbility, IsAllowedToSpam, SetQueuePtToINT
require( GetScriptDirectory()..'/FuncLib/general_utils/map_info' )(Fu)        -- IsInLaningPhase, IsRoshanAlive, GetCurrentRoshanLocation, game phase
require( GetScriptDirectory()..'/FuncLib/general_utils/lane_strategy' )(Fu)   -- GetLanePartner, lane assignment, lane front helpers
require( GetScriptDirectory()..'/FuncLib/general_utils/projectile' )(Fu)      -- Projectile dodge detection, incoming spell tracking
require( GetScriptDirectory()..'/FuncLib/general_utils/hero_info' )(Fu)       -- Hero-specific data: attack ranges, spell lists, hero classifications
require( GetScriptDirectory()..'/FuncLib/general_utils/special_units' )(Fu)   -- Roshan, Tormentor, courier, summon identification
require( GetScriptDirectory()..'/FuncLib/general_utils/init_debug' )(Fu)      -- Debug logging, IsDebug flag, log() function, error tracking

return Fu
