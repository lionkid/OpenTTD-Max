/*
 * MaxTransit2: a profit-first, good-looking and courteous transport AI for OpenTTD.
 * Part of OpenTTD-Max. Licence: GPL-2.0 (see license.txt).
 *
 * Goals, in order: never take a town, an industry or a route another company already serves; earn money
 * fast with freight and passengers by rail, road, air and water; build every line so that it looks planned
 * (long straights, parallel double track, even signals, tunnels and bridges, replanted trees, no leftovers).
 */
class MaxTransit2 extends AIInfo {
	function GetAuthor()        { return "OpenTTD-Max"; }
	function GetName()          { return "MaxTransit2"; }
	function GetShortName()     { return "MXT2"; }
	function GetDescription()   {
		return "Second-generation MaxTransit: picks the fastest-paying freight and passenger routes for trains, " +
			"road vehicles, aircraft and ships, builds them tidily (straight alignments, parallel double track, " +
			"evenly spaced signals, tunnels and bridges, trees replanted, no level crossings, no leftovers) and " +
			"keeps away from every town, industry and route another company already serves.";
	}
	function GetVersion()       { return 1; }
	function MinVersionToLoad() { return 1; }
	function GetDate()          { return "2026-10-17"; }
	function CreateInstance()   { return "MaxTransit2"; }
	function GetAPIVersion()    { return "15"; }
	function UseAsRandomAI()    { return true; }
	function GetURL()           { return "https://github.com/lionkid/openttd-max"; }

	function GetSettings() {
		AddSetting({name = "use_rail", description = "Build railways",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "use_road", description = "Build road vehicle routes (buses and lorries)",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "use_air", description = "Build airports and fly passengers and mail",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "use_water", description = "Build docks and run ships (oil rigs, coastal freight, ferries)",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "passengers", description = "Carry passengers and mail between towns",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "freight", description = "Carry freight from industries",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "courtesy", description = "Courtesy towards other companies (the game does not tell scripts which companies are human)",
			min_value = 0, max_value = 2, default_value = 1, flags = CONFIG_INGAME});
		AddLabels("courtesy", {
			_0 = "Compete normally",
			_1 = "Stay out of their towns, industries and routes",
			_2 = "Stay out and keep a wide berth around their network"});
		AddSetting({name = "air_crashes", description = "Passenger flights while the game's random plane crashes are enabled",
			min_value = 0, max_value = 1, default_value = 0, flags = CONFIG_INGAME});
		AddLabels("air_crashes", {_0 = "Fly anyway (large aircraft still never use small airports)", _1 = "Only fly when plane crashes are off"});
		AddSetting({name = "scenery", description = "Landscaping",
			min_value = 0, max_value = 2, default_value = 1, flags = CONFIG_INGAME});
		AddLabels("scenery", {_0 = "None", _1 = "Replant the trees our lines cut", _2 = "Replant and add green belts around stations"});
		AddSetting({name = "expansion", description = "Expansion speed",
			min_value = 0, max_value = 2, default_value = 2, flags = CONFIG_INGAME});
		AddLabels("expansion", {_0 = "Slow", _1 = "Normal", _2 = "Fast"});
		AddSetting({name = "debug", description = "Verbose diagnostics in the AI log",
			min_value = 0, max_value = 1, default_value = 0, flags = CONFIG_BOOLEAN | CONFIG_INGAME | CONFIG_DEVELOPER});
		AddSetting({name = "debug_signs", description = "Mark construction decisions with signs",
			min_value = 0, max_value = 1, default_value = 0, flags = CONFIG_BOOLEAN | CONFIG_INGAME | CONFIG_DEVELOPER});
		AddSetting({name = "dump_map", description = "Write a map of the network to the AI log every year (tools/ai/render_map.py)",
			min_value = 0, max_value = 1, default_value = 0, flags = CONFIG_BOOLEAN | CONFIG_INGAME | CONFIG_DEVELOPER});
	}
}

RegisterAI(MaxTransit2());
