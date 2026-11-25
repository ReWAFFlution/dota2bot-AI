-- Dodging skillshots and delayed area spells (FunLib/dodge.lua): this mode
-- wins (0.99) only while an enemy hook/arrow/wave is about to pass through
-- us or we stand in an enemy area spell; otherwise it wants nothing.
local bot = GetBot()
if bot == nil or bot:IsIllusion() then return end

local okD, Dodge = pcall(require, GetScriptDirectory()..'/FunLib/dodge')
if not okD then Dodge = nil end

function GetDesire()
	if not Dodge or not bot:IsAlive() then return BOT_MODE_DESIRE_NONE end
	local ok, d = pcall(Dodge.Desire, bot)
	return ok and d or BOT_MODE_DESIRE_NONE
end

function Think()
	if not Dodge then return end
	pcall(Dodge.Think, bot)
end
