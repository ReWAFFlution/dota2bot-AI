if GetScriptDirectory == nil then GetScriptDirectory = function () return "bots" end end
local Utils = require( GetScriptDirectory()..'/FunLib/utils' )

local Dota2Teams = { }

Dota2Teams.defaultPostfix = '丰'
Dota2Teams.maxTeamSize = 12 -- e.g. for 12 v 12

local defaultTeams = {
    {name = "ZXC", players = {
        "Джек Подрочитель", "Усама Бен Лаваш", "Барак Обама Спиздил Раму",
        "Билли Херрингтон", "Мистер Поппер", "Старый Педофил", "Папа в Деле", "Дедушка в Очко",
        "Шрек Суальный", "Головач Лена", "Секс Инструктор", "Пожилой Пажилой",
        "Отчим в Деле", "Дед Инсайд 2009", "Сын Маминой Подруги",
        "Батя в Здании", "Кринж Лорд", "Пивной Барон", "Скуф на Выезде",
        "Мамкин Сынок", "Хлебушек с Маслом", "Джонни Додепп"
    }},
    {name = "XUY", players = {
        "Стив Бловджобс", "Егор Вкредит", "Дмитрий Накиев", "Тарас Вульva",
        "Король Минета", "Мамут Рахал", "ЧпokиНатор", "Пол Кружки Пива",
        "Елисей Поля", "Попаданец в Очко", "Мастер Шифу без Штанов",
        "Капитан Залупа", "Лорд Вагинатор", "Трахтенберг на Пенсии",
        "Супер Сус", "Влад А4 Листа", "Опасный Поцык", "Доктор Дью"
    }}
}

local function generateTeam(overrides)
    local playerList = { }
    local overriddenNames = { }
    local randomNum = 0
    repeat
        randomNum = RandomInt(1, #defaultTeams)
    -- Ensure a team can only pick from the matching team-name pool.
    until randomNum % 2 == GetTeam() - 2

    playerList = Utils.MergeLists(defaultTeams[randomNum].players, {})
    if overrides and #overrides > 0 then
        for i = 1, #overrides do
            if overrides[i] and overrides[i] ~= 'Random' then
                playerList[i] = overrides[i]
                table.insert(overriddenNames, overrides[i])
            end
        end
    end

    local team = { }
    for i = 1, Dota2Teams.maxTeamSize do
        local pName = table.remove(playerList, 1)
        if Utils.HasValue(overriddenNames, pName) then
            table.insert(team, pName)
        else
            table.insert(team, defaultTeams[randomNum].name .. "." .. pName .. '.' .. Dota2Teams.defaultPostfix)
        end
    end
    return team
end

--[[
    Example of overrides arg with specific player names for Radiant:
    local playerNameOverrides = {
        Radiant = {"p1", "p2", "p3", "p4", "p5"}
    }
]]
function Dota2Teams.generateTeams(overrides)
    local radiantOverrides = overrides and overrides.Radiant or {}
    local direOverrides = overrides and overrides.Dire or {}

    local radiantTeam = generateTeam(radiantOverrides)
    local direTeam = generateTeam(direOverrides)

    return {
        Radiant = radiantTeam,
        Dire = direTeam
    }
end

return Dota2Teams
