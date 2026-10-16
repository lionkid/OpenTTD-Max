/*
 * MaxTransit: a passenger transit AI for OpenTTD built around CargoDist.
 * Part of OpenTTD-Max. Licence: GPL-2.0 (see license.txt).
 *
 * Priorities, in order: passenger safety, door-to-door travel time, value of every vehicle.
 */
class MaxTransit extends AIInfo {
	function GetAuthor()        { return "OpenTTD-Max"; }
	function GetName()          { return "MaxTransit"; }
	function GetShortName()     { return "MXTR"; }
	function GetDescription()   {
		return "Passenger network AI built for CargoDist: buses feed joined interchange stations, " +
			"double-track signalled railways and safe airport/aircraft pairs carry the trunk flows, and every line " +
			"is sized from the planned link flows. Safety first (no level crossings, no large aircraft at small " +
			"airports, path signals only), then travel time, then value.";
	}
	function GetVersion()       { return 1; }
	function MinVersionToLoad() { return 1; }
	function GetDate()          { return "2026-10-16"; }
	function CreateInstance()   { return "MaxTransit"; }
	function GetAPIVersion()    { return "15"; }
	function UseAsRandomAI()    { return true; }
	function GetURL()           { return "https://github.com/lionkid/openttd-max"; }

	function GetSettings() {
		AddSetting({name = "use_road", description = "Build bus lines (feeders and short links)",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "use_rail", description = "Build railways (intercity trunk lines)",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "use_air", description = "Build airports and fly passengers",
			min_value = 0, max_value = 1, default_value = 1, flags = CONFIG_BOOLEAN | CONFIG_INGAME});
		AddSetting({name = "air_policy", description = "Aircraft while random plane crashes are enabled",
			min_value = 0, max_value = 2, default_value = 1, flags = CONFIG_INGAME});
		AddLabels("air_policy", {
			_0 = "Fly where it is the best option",
			_1 = "Fly only where it saves at least 40% of the travel time",
			_2 = "Do not fly passengers"});
		AddSetting({name = "frequency", description = "Service frequency target",
			min_value = 0, max_value = 2, default_value = 1, flags = CONFIG_INGAME});
		AddLabels("frequency", {_0 = "Economical", _1 = "Balanced", _2 = "Frequent"});
		AddSetting({name = "expansion", description = "Network expansion speed",
			min_value = 0, max_value = 2, default_value = 1, flags = CONFIG_INGAME});
		AddLabels("expansion", {_0 = "Slow", _1 = "Normal", _2 = "Fast"});
		AddSetting({name = "debug", description = "Verbose diagnostics in the AI log (vehicle traces)",
			min_value = 0, max_value = 1, default_value = 0, flags = CONFIG_BOOLEAN | CONFIG_INGAME | CONFIG_DEVELOPER});
		AddSetting({name = "debug_signs", description = "Mark construction decisions with signs",
			min_value = 0, max_value = 1, default_value = 0, flags = CONFIG_BOOLEAN | CONFIG_INGAME | CONFIG_DEVELOPER});
	}
}

RegisterAI(MaxTransit());
