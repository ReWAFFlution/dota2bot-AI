"""Generate bots/FunLib/item_meta_data.lua (meta item builds) from scraped Stratz data.

Input lines (scripts/data/stratz_items_*.txt), one per hero/position:
  heroId:pos|start items|boots:rate,...|early item:rate,...|mid ...|late ...
Rates are Stratz purchase rates (% of games) for that hero at that position,
per game phase (0-15, 15-35, 35+ min).

Usage (from the repo root):
  python3 -I scripts/gen_item_lua.py bots/FunLib/item_meta_data.lua scripts/data/stratz_items_*.txt
"""
import re
import sys

out, *sources = sys.argv[1:]

src = open("scripts/gen_meta_lua.py").read()
ns = {}
exec(src[src.index("ID2NPC = {"):src.index("known = set(")], ns)
ID2NPC = ns["ID2NPC"]

# Not bought from the shop / bought by dedicated logic elsewhere.
SKIP = {"great_famango", "greater_famango", "famango", "ward_observer", "ward_sentry",
        "smoke_of_deceit", "dust", "tpscroll", "gem"}
BOOTS = ["phase_boots", "power_treads", "arcane_boots", "tranquil_boots", "travel_boots"]
BOOT_UPGRADES = {"guardian_greaves", "boots_of_bearing", "travel_boots_2"}
# How many items of each phase make the core build, and the minimum purchase rate.
EARLY_MIN, EARLY_MAX = 25, 3
MID_MIN, MID_MAX = 20, 4
LATE_MIN, LATE_MAX = 14, 3
FARM_ITEMS = {"maelstrom", "radiance", "bfury", "hand_of_midas"}
# Lane stat items bought right after the boots.
LANE_ITEMS = {"falcon_blade", "mask_of_madness", "orb_of_corrosion"}
# Cheap lane items that may come before the boots; everything else comes after.
CHEAP_EARLY = {"magic_wand", "bracer", "wraith_band", "null_talisman", "soul_ring", "ring_of_basilius",
               "urn_of_shadows", "infused_raindrop", "orb_of_corrosion", "blight_stone", "wind_lace",
               "magic_stick", "headdress"}

# Melee heroes: "ranged = 0" in bots/FunLib/aba_hero_roles_map.lua.
_hero_const = dict(re.findall(r'HeroName\.(\w+) = "npc_dota_hero_(\w+)"', open("bots/ts_libs/dota/heroes.lua").read()))
MELEE = {_hero_const[c] for c, r in re.findall(r'\[HeroName\.(\w+)\] = \{[^}]*?ranged = (\d)',
                                                open("bots/FunLib/aba_hero_roles_map.lua").read())
         if r == "0" and c in _hero_const}
FARM_MIN, FARM_MAX = 30, 2


def pairs(s):
    res = []
    for p in filter(None, s.split(",")):
        name, rate = p.rsplit(":", 1)
        res.append((name, int(rate)))
    return res


builds = {}
for path in sources:
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        key, start, boots, early, mid, late = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
        hid, pos = (int(x) for x in key.split(":"))
        boots, early, mid, late = pairs(boots), pairs(early), pairs(mid), pairs(late)
        if not mid and not late:
            continue  # too few games for a build

        buy, seen = [], set()

        def add(name):
            if name in SKIP or name in seen:
                return
            seen.add(name)
            buy.append("item_" + name)

        start_items = [n for n in start.split(",") if n]
        # Melee cores lane with Quelling Blade, not Faerie Fire.
        if pos <= 3 and ID2NPC[hid] in MELEE:
            start_items = [n for n in start_items if n != "faerie_fire"]
            if "quelling_blade" not in start_items:
                start_items.insert(0, "quelling_blade")
        for name in start_items:
            # Starting items may repeat (2x branches). Wards/smoke have their own
            # purchase logic; a magic wand isn't affordable at the start.
            if name not in SKIP and name != "magic_wand":
                buy.append("item_" + name)
        boot_choice = max((b for b in boots if b[0] in BOOTS), key=lambda b: b[1], default=None)
        # Farm items the hero really goes for (Stratz purchase rate >= FARM_MIN in
        # the early or mid game) come right after the boots, before fight items.
        # Heroes that farm without them (PL with illusions, Naga) get none.
        farm_rate = {}
        for n, r in early + mid:
            if n in FARM_ITEMS:
                farm_rate[n] = max(farm_rate.get(n, 0), r)
        farm = [n for n, r in sorted(farm_rate.items(), key=lambda x: -x[1]) if r >= FARM_MIN][:FARM_MAX]
        early_core = [n for n, r in early if r >= EARLY_MIN and n not in BOOTS and n not in farm][:EARLY_MAX]
        # Cheap lane items (wand, bracer, wraith band...) before the boots, then the
        # boots, then the farm item(s), then the other early items (Yasha...).
        for n in early_core:
            if n in CHEAP_EARLY:
                add(n)
        if boot_choice and boot_choice[1] >= 25:
            add(boot_choice[0])
        # Lane stat items (Falcon Blade: HP, damage, mana regen) right after the
        # boots, before farm items and Yasha-type items.
        for n in early_core:
            if n in LANE_ITEMS:
                add(n)
        for n in farm:
            add(n)
        for n in early_core:
            add(n)
        mid_added = 0
        for n, r in sorted(mid, key=lambda x: -x[1]):
            if r >= MID_MIN and mid_added < MID_MAX and n not in seen and n not in SKIP:
                add(n)
                mid_added += 1
        for b, r in boots:
            if b in BOOT_UPGRADES and b != "travel_boots_2" and r >= 25:
                add(b)
        late_added = 0
        for n, r in sorted(late, key=lambda x: -x[1]):
            if r >= LATE_MIN and late_added < LATE_MAX and n not in seen:
                add(n)
                late_added += 1

        known = {}
        for n, r in boots + early + mid + late:
            if n not in SKIP:
                known[n] = max(known.get(n, 0), r)
        builds.setdefault(ID2NPC[hid], {})[pos] = (buy, known)

L = []
w = L.append
w("-----")
w("-- Meta item builds. Generated by scripts/gen_item_lua.py; do not edit by hand.")
w("-- Source: Stratz hero item stats per position (purchase rate per game phase),")
w("-- collected 2026-11-18 for patch 7.41f.")
w("--   buy   = purchase order: Stratz starting items, the early core item(s),")
w("--           boots, the most bought mid-game items, then late-game items.")
w("--   known = every item bought in >= 5% of games, with its highest purchase")
w("--           rate (%); situational items prefer items from this list.")
w("-----")
w("local X = {}")
w("X.Builds = {")
for hero in sorted(builds):
    w(f"\t['npc_dota_hero_{hero}'] = {{")
    for pos in sorted(builds[hero]):
        buy, known = builds[hero][pos]
        w(f"\t\t[{pos}] = {{")
        w("\t\t\tbuy = { " + ", ".join(f"'{b}'" for b in buy) + " },")
        w("\t\t\tknown = { " + ", ".join(f"{k} = {v}" for k, v in sorted(known.items())) + " },")
        w("\t\t},")
    w("\t},")
w("}")
w("return X")
w("")
open(out, "w").write("\n".join(L))
print("ok", len(builds), "heroes,", sum(len(v) for v in builds.values()), "hero/position builds")
