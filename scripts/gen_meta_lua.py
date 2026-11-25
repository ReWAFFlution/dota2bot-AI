"""Generate bots/FunLib/meta_draft_data.lua from scraped Stratz data.

Usage (from the repo root):
  python3 -I scripts/gen_meta_lua.py scripts/data/stratz_matchups.txt \
      scripts/data/stratz_positions.txt typescript/post-process/names.ts \
      bots/ts_libs/dota/heroes.lua bots/FunLib/meta_draft_data.lua
"""
import re
import sys

src, positions_src, names_ts, heroes_lua, out = sys.argv[1:6]

# A hero "plays" a position when at least this share of its games (summed over
# Stratz's per-position pick rates) is at that position.
POSITION_MIN_SHARE = 20

ID2NPC = {
    1: "antimage", 2: "axe", 3: "bane", 4: "bloodseeker", 5: "crystal_maiden",
    6: "drow_ranger", 7: "earthshaker", 8: "juggernaut", 9: "mirana", 10: "morphling",
    11: "nevermore", 12: "phantom_lancer", 13: "puck", 14: "pudge", 15: "razor",
    16: "sand_king", 17: "storm_spirit", 18: "sven", 19: "tiny", 20: "vengefulspirit",
    21: "windrunner", 22: "zuus", 23: "kunkka", 25: "lina", 26: "lion",
    27: "shadow_shaman", 28: "slardar", 29: "tidehunter", 30: "witch_doctor", 31: "lich",
    32: "riki", 33: "enigma", 34: "tinker", 35: "sniper", 36: "necrolyte",
    37: "warlock", 38: "beastmaster", 39: "queenofpain", 40: "venomancer", 41: "faceless_void",
    42: "skeleton_king", 43: "death_prophet", 44: "phantom_assassin", 45: "pugna", 46: "templar_assassin",
    47: "viper", 48: "luna", 49: "dragon_knight", 50: "dazzle", 51: "rattletrap",
    52: "leshrac", 53: "furion", 54: "life_stealer", 55: "dark_seer", 56: "clinkz",
    57: "omniknight", 58: "enchantress", 59: "huskar", 60: "night_stalker", 61: "broodmother",
    62: "bounty_hunter", 63: "weaver", 64: "jakiro", 65: "batrider", 66: "chen",
    67: "spectre", 68: "ancient_apparition", 69: "doom_bringer", 70: "ursa", 71: "spirit_breaker",
    72: "gyrocopter", 73: "alchemist", 74: "invoker", 75: "silencer", 76: "obsidian_destroyer",
    77: "lycan", 78: "brewmaster", 79: "shadow_demon", 80: "lone_druid", 81: "chaos_knight",
    82: "meepo", 83: "treant", 84: "ogre_magi", 85: "undying", 86: "rubick",
    87: "disruptor", 88: "nyx_assassin", 89: "naga_siren", 90: "keeper_of_the_light", 91: "wisp",
    92: "visage", 93: "slark", 94: "medusa", 95: "troll_warlord", 96: "centaur",
    97: "magnataur", 98: "shredder", 99: "bristleback", 100: "tusk", 101: "skywrath_mage",
    102: "abaddon", 103: "elder_titan", 104: "legion_commander", 105: "techies", 106: "ember_spirit",
    107: "earth_spirit", 108: "abyssal_underlord", 109: "terrorblade", 110: "phoenix", 111: "oracle",
    112: "winter_wyvern", 113: "arc_warden", 114: "monkey_king", 119: "dark_willow", 120: "pangolier",
    121: "grimstroke", 123: "hoodwink", 126: "void_spirit", 128: "snapfire", 129: "mars",
    131: "ringmaster", 135: "dawnbreaker", 136: "marci", 137: "primal_beast", 138: "muerta",
    145: "kez", 155: "largo",
}

known = set(re.findall(r'"(npc_dota_hero_[a-z_]+)"', open(heroes_lua).read()))
npc = {i: "npc_dota_hero_" + n for i, n in ID2NPC.items()}
missing = [v for v in npc.values() if v not in known]
if missing:
    sys.exit("unknown hero names: " + ", ".join(missing))


def parse_pairs(s):
    res = []
    for p in filter(None, s.split(",")):
        i, v = p.split(":")
        res.append((int(i), float(v)))
    return res


counters, synergy = {}, {}
for line in open(src):
    line = line.strip()
    if not line:
        continue
    hid, c, s = line.split("|")
    hid = int(hid)
    # Stratz "Counter Rating" from this hero's point of view: negative = the
    # other hero beats it. Keep only real counters (<= -1.0%).
    counters[npc[hid]] = [(npc[i], round(-v, 1)) for i, v in parse_pairs(c) if v <= -1.0]
    # Synergy rating: positive = better win rate together. Keep >= +1.0%.
    synergy[npc[hid]] = [(npc[i], v) for i, v in parse_pairs(s) if v >= 1.0]

if len(counters) != len(ID2NPC):
    sys.exit(f"expected {len(ID2NPC)} heroes, got {len(counters)}")

# Visible name -> internal name, from typescript/post-process/names.ts.
visible = {}
for internal, vis in re.findall(r'(npc_dota_hero_[a-z_]+):\s*\{[^}]*visibleName:\s*"([^"]+)"', open(names_ts).read()):
    visible[vis] = internal
visible.setdefault("Largo", "npc_dota_hero_largo")  # missing from names.ts

by_pos = {}  # pos -> [(hero, pick%)] as listed by Stratz
picks = {}   # hero -> {pos: pick%}
for line in open(positions_src):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    pos, entries = line.split("|", 1)
    for entry in entries.split(";"):
        name, pick, _win = entry.rsplit(":", 2)
        if name not in visible:
            sys.exit("unknown visible hero name: " + name)
        by_pos.setdefault(int(pos), []).append((visible[name], float(pick)))
        picks.setdefault(visible[name], {})[int(pos)] = float(pick)

# positions[hero] = {pos: share%} for positions holding >= POSITION_MIN_SHARE of its games
positions = {}
for hero, per_pos in picks.items():
    total = sum(per_pos.values())
    for pos, pick in per_pos.items():
        share = round(100 * pick / total)
        if share >= POSITION_MIN_SHARE:
            positions.setdefault(hero, {})[pos] = share


def fits(hero, pos):
    return pos in positions.get(hero, {})

# Meta pool (2026-11-25): heroes with pick rate >= 10% and win rate >= 53% in
# at least one rank bracket on Dotabuff (meta page, this month), plus heroes
# with >= 3% of a position's games and >= 53% win rate there on Stratz (meta
# trends, 8 days) - more meta heroes for the draft. Bot-weak heroes (Ancient
# Apparition) left out.
META = {
    1: ["phantom_assassin", "skeleton_king", "spectre", "phantom_lancer", "sven", "troll_warlord", "riki"],
    2: ["obsidian_destroyer", "sniper", "dragon_knight"],
    3: ["skeleton_king", "abaddon", "legion_commander", "omniknight"],
    4: ["nyx_assassin", "bounty_hunter", "shadow_shaman", "grimstroke", "crystal_maiden"],
    5: ["dazzle", "lich", "shadow_shaman", "crystal_maiden", "vengefulspirit", "grimstroke"],
}
for pos, names in META.items():
    for n in names:
        assert "npc_dota_hero_" + n in known, n

# Popular heroes per position: the most picked heroes at that position on
# Stratz that are not already meta there, up to POPULAR_PER_POSITION.
POPULAR_PER_POSITION = 10
popular = {}
for pos in range(1, 6):
    meta_here = {"npc_dota_hero_" + n for n in META[pos]}
    ranked = sorted((e for e in by_pos[pos] if e[0] not in meta_here and fits(e[0], pos)), key=lambda e: -e[1])
    popular[pos] = ranked[:POPULAR_PER_POSITION]

# Position pool: up to POOL_PER_POSITION most picked heroes that play the
# position (meta heroes excluded; the drafter filters further at runtime).
POOL_PER_POSITION = 40
all_meta = {"npc_dota_hero_" + n for names in META.values() for n in names}
pool = {}
for pos in range(1, 6):
    ranked = sorted((e for e in by_pos[pos] if e[0] not in all_meta and fits(e[0], pos)), key=lambda e: -e[1])
    pool[pos] = ranked[:POOL_PER_POSITION]

L = []
w = L.append
w("-----")
w("-- Meta draft data. Generated by scripts/gen_meta_lua.py; do not edit by hand.")
w("-- Source: Stratz (meta trends + per-hero matchups) and Dotabuff (meta page),")
w("-- meta and positions collected 2026-11-25, matchups 2026-11-18.")
w("-----")
w("")
w("local X = {}")
w("")
w("-- Meta heroes per position: pick >= 10% and win >= 53% in a Dotabuff rank")
w("-- bracket, or >= 3% of the position's games and >= 53% win there on Stratz.")
w("-- Comment: Stratz pick% / win% at the position.")
comments = {
    1: "PA 17.3/55.4, WK 3.9/55.1, Spectre 6.1/54.1, PL 12.3/51.3 (Dotabuff 13.7/53.1), Sven 9.8/53.5, Troll 3.0/55.6, Riki 6.4/55.3",
    2: "OD 5.5/48.2 (Dotabuff 13.2/53.5), Sniper 12.1/52.0, DK 2.3/51.6 (Dotabuff top bracket 20.6% picks)",
    3: "WK 7.7/55.9, Abaddon 6.1/55.8, LC 9.5/51.5 (Dotabuff 16.5/53.2), Omniknight 2.0/54.8",
    4: "Nyx 4.7/52.8 (Dotabuff 12.4/53.7), BH 3.3/49.7 (Dotabuff 11.0/54.9), SS 4.1/53.7, Grimstroke 2.8/53.8, CM 4.0/53.5",
    5: "Dazzle 6.4/54.4, Lich 6.0/53.3, SS 8.5/53.2, CM 9.2/52.8, VS 3.0/53.4, Grimstroke 3.6/53.2",
}
w("X.MetaByPosition = {")
for pos in range(1, 6):
    w(f"\t-- pos {pos}: {comments[pos]}")
    w(f"\t[{pos}] = {{")
    for n in META[pos]:
        w(f"\t\t'npc_dota_hero_{n}',")
    w("\t},")
w("}")
w("")
w(f"-- Popular (not meta) heroes per position: the {POPULAR_PER_POSITION} most picked heroes at")
w("-- that position on Stratz, excluding that position's meta heroes. Comment = pick%.")
w("X.PopularByPosition = {")
for pos in range(1, 6):
    w(f"\t[{pos}] = {{")
    for n, pick in popular[pos]:
        w(f"\t\t'{n}', -- {pick}")
    w("\t},")
w("}")
w("")
w(f"-- Pool of up to {POOL_PER_POSITION} heroes per position (most picked there on Stratz,")
w("-- playing that position, meta heroes excluded). Used for slots outside the")
w("-- counter/meta/popular quotas, mainly supports. Comment = pick%.")
w("X.PoolByPosition = {")
for pos in range(1, 6):
    w(f"\t[{pos}] = {{")
    for n, pick in pool[pos]:
        w(f"\t\t'{n}', -- {pick}")
    w("\t},")
w("}")
w("")
w("-- Positions[hero] = { [pos] = share% }: positions holding at least")
w(f"-- {POSITION_MIN_SHARE}% of the hero's games on Stratz. A hero only goes to a position")
w("-- listed here. Heroes missing here have no Stratz data; the drafter falls back")
w("-- to the bot's own role weights for them.")
w("X.Positions = {")
for h in sorted(positions):
    items = ", ".join(f"[{p}] = {v}" for p, v in sorted(positions[h].items()))
    w(f"\t['{h}'] = {{ {items} }},")
w("}")
w("")
w("-- Counters[hero] = heroes that beat `hero`, strongest first, as")
w("-- { name, advantage% }. Stratz matchups, all ranks, >= 1000 games.")
w("X.Counters = {")
for h in sorted(counters):
    items = ", ".join(f"{{'{n}', {v}}}" for n, v in counters[h])
    w(f"\t['{h}'] = {{ {items} }},")
w("}")
w("")
w("-- Synergy[hero] = heroes that win more often on the same team as `hero`,")
w("-- best first, as { name, synergy% }. Stratz, all ranks, >= 1000 games.")
w("X.Synergy = {")
for h in sorted(synergy):
    items = ", ".join(f"{{'{n}', {v}}}" for n, v in synergy[h])
    w(f"\t['{h}'] = {{ {items} }},")
w("}")
w("")
w("return X")
w("")
open(out, "w").write("\n".join(L))
print("ok", len(counters), "heroes,", sum(len(v) for v in counters.values()), "counters,",
      sum(len(v) for v in synergy.values()), "synergies")
