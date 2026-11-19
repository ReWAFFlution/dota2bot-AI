if GetScriptDirectory == nil then GetScriptDirectory = function () return "bots" end end
local Utils = require( GetScriptDirectory()..'/FunLib/utils' )

local Dota2Teams = { }

Dota2Teams.defaultPostfix = '丰'
Dota2Teams.maxTeamSize = 12 -- e.g. for 12 v 12

local defaultTeams = {
    {name = "ZXC", players = {
        "Агуша", "Дед Инсайд 2009", "ZXCУрса", "Дед Внутри", "Мать Мертвы"
    }},
    {name = "LWFB", players = {
        "Бен ЛаТен", "Баран Обама", "Мистер Поппер", "Старый Педофил", "Отчим в Деле"
    }},
    {name = "LOL", players = {
        "Шрек Суальный", "Головач Лена", "Секс Инструктор", "Пожилой Пажилой", "Мамкин Сынок"
    }},
    {name = "BEER", players = {
        "Папа потеет", "Пол Кружки Пива", "Пивной Барон", "Скуф на Выезде", "Джонни Дodепп"
    }},
    {name = "XYU", players = {
        "Стив Бловджобс", "Егор Вкредит", "Дмитрий Накиев", "Тарас Вульva", "Кринж Лорд"
    }},
    {name = "SEX", players = {
        "Стив Бловджобс", "Король Минета", "Мамут Рахал", "ЧпokиНатор", "Джек Подрочитель"
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
