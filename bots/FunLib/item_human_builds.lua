-- Item builds taken from strong human games: they win over the Stratz meta
-- build (FunLib/item_meta_data.lua, generated - don't edit that one by
-- hand). [hero][pos] = buy list in order.
return {
	-- OpenDota 9098399818: Terrorblade pos 1, 761 GPM, 13.4 last hits/min,
	-- hard lane. Farm items first (Falcon 4:22, Treads 8:28, Yasha 14:08,
	-- Shard 15:11, Maelstrom 19:44, Mjollnir 22:32, Manta 25:26, Skadi 29:50),
	-- BKB only at 34:50, Satanic 38:47.
	npc_dota_hero_terrorblade = {
		[1] = { 'item_quelling_blade', 'item_tango', 'item_branches', 'item_magic_wand', 'item_falcon_blade',
			'item_power_treads', 'item_yasha', 'item_aghanims_shard', 'item_maelstrom', 'item_mjollnir',
			'item_manta', 'item_skadi', 'item_black_king_bar', 'item_satanic', 'item_butterfly' },
		-- OpenDota 9098557365: Terrorblade offlane, 641 last hits, 200 neutrals,
		-- 13k tower damage. Treads 7:34, Shard 15:00, Dragon Lance 21:28, S&Y
		-- 24:38, Hurricane Pike 28:13, MKB 36:02, BKB 40:13, Satanic 46:51.
		[3] = { 'item_tango', 'item_branches', 'item_bracer', 'item_magic_wand', 'item_power_treads',
			'item_aghanims_shard', 'item_dragon_lance', 'item_sange_and_yasha', 'item_hurricane_pike',
			'item_monkey_king_bar', 'item_black_king_bar', 'item_satanic', 'item_ultimate_scepter_2' },
	},
	-- OpenDota 9098557365: Spectre pos 1, 602 GPM, 282 neutrals (38 ancients),
	-- 19-4. Battle Fury, not Radiance: Treads 6:45, BFury 17:02, Manta 25:31,
	-- Skadi 36:23, Abyssal 46:09, Shard 47:13, Aghanim 57:28.
	npc_dota_hero_spectre = {
		[1] = { 'item_quelling_blade', 'item_tango', 'item_branches', 'item_wraith_band', 'item_power_treads',
			'item_magic_wand', 'item_bfury', 'item_manta', 'item_skadi', 'item_abyssal_blade',
			'item_aghanims_shard', 'item_ultimate_scepter_2' },
	},
}
