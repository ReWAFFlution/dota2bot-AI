-- Minimal Dota bot API stubs for offline simulations (luajit).
local V = {} V.__index = V
function Vector(x, y, z) return setmetatable({ x = x, y = y, z = z or 0 }, V) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y) end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y) end
V.__mul = function(a, k) return Vector(a.x * k, a.y * k) end
V.__div = function(a, k) return Vector(a.x / k, a.y / k) end
function V:Length2D() return math.sqrt(self.x ^ 2 + self.y ^ 2) end
function V:Normalized() local l = self:Length2D() return Vector(self.x / l, self.y / l) end
function RandomVector() return Vector(0, 0) end
TEAM_RADIANT, TEAM_DIRE = 2, 3
LANE_TOP, LANE_MID, LANE_BOT = 1, 2, 3
TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3, TOWER_MID_1, TOWER_MID_2, TOWER_MID_3, TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3, TOWER_BASE_1, TOWER_BASE_2 = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
UNIT_LIST_ALL, UNIT_LIST_ENEMY_HEROES, UNIT_LIST_ALLIED_HEROES, UNIT_LIST_ALLIED_WARDS = 0, 1, 2, 3
BOT_MODE_NONE, BOT_MODE_LANING, BOT_MODE_ROAM = 0, 1, 9
DAMAGE_TYPE_PHYSICAL, DAMAGE_TYPE_ALL = 1, 7
SIM_T = 0
function DotaTime() return SIM_T end
function GetTeam() return 2 end
function GetOpposingTeam() return 3 end
function GetUnitToUnitDistance(a, b) return (a:GetLocation() - b:GetLocation()):Length2D() end
function GetUnitToLocationDistance(a, l) return (a:GetLocation() - l):Length2D() end
