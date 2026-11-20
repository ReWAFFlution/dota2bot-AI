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
	},
}
