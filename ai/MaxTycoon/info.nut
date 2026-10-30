/*
 * MaxTycoon: an OpenTTD AI that plays for the highest company performance rating at the ending year.
 * Part of OpenTTD-Max. Licence: GPL-2.0 (see license.txt).
 *
 * It runs every vehicle type the game offers (buses, trucks, trams, trains, aircraft, ships), serves whole
 * industry chains, grows the towns it serves and keeps their road grids tidy. Two settings scale it: how
 * clever it plays and how fast it develops.
 */
class MaxTycoon extends AIInfo {
	function GetAuthor()        { return "OpenTTD-Max"; }
	function GetName()          { return "MaxTycoon"; }
	function GetShortName()     { return "MXTY"; }
	function GetDescription()   {
		return "Plays for the highest performance rating at the ending year: every vehicle type (road, tram, " +
			"rail, air, water), whole industry chains, fast-growing towns with tidy road grids, and the nine " +
			"components of the company score watched every quarter. Set how clever it plays (Intelligence) " +
			"and how fast it expands (Development).";
	}
	function GetVersion()       { return 1; }
	function MinVersionToLoad() { return 1; }
	function GetDate()          { return "2026-10-23"; }
	function CreateInstance()   { return "MaxTycoon"; }
	function GetAPIVersion()    { return "15"; }
	function UseAsRandomAI()    { return true; }
	function GetURL()           { return "https://github.com/lionkid/openttd-max"; }

	function GetSettings() {
		AddSetting({name = "intelligence", description = "Intelligence: how well it plans (search effort, score awareness, mistakes)",
			min_value = 0, max_value = 3, default_value = 3, flags = CONFIG_INGAME});
		AddLabels("intelligence", {
			_0 = "Simple (greedy, short-sighted, makes mistakes)",
			_1 = "Average (profit first, basic fleet care)",
			_2 = "Clever (score-aware planning, culling, end-game plan)",
			_3 = "Brilliant (deep searches, every score lever, town and industry funding)"});
		AddSetting({name = "development", description = "Development: how fast and how far it expands",
			min_value = 0, max_value = 3, default_value = 3, flags = CONFIG_INGAME});
		AddLabels("development", {
			_0 = "Modest (a few lines, slow growth)",
			_1 = "Steady",
			_2 = "Ambitious",
			_3 = "Relentless (spends every pound and every day)"});
		AddSetting({name = "use_road", description = "Buses, trucks and trams",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "use_rail", description = "Railways (passengers and freight)",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "use_air", description = "Airports and aircraft",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "use_water", description = "Docks and ships",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "grow_towns", description = "Grow the towns it serves (fund buildings, statues, road grids)",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "fund_industries", description = "Fund new industries to complete a cargo chain",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "debug", description = "Verbose diagnostics in the AI log",
			min_value = 0, max_value = 1, default_value = 0, flags = CONFIG_BOOLEAN | CONFIG_INGAME | CONFIG_DEVELOPER});
		AddSetting({name = "debug_signs", description = "Mark construction decisions with signs",
			min_value = 0, max_value = 1, default_value = 0, flags = CONFIG_BOOLEAN | CONFIG_INGAME | CONFIG_DEVELOPER});
	}
}

RegisterAI(MaxTycoon());
