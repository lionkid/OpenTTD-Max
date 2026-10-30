/*
 * Game settings snapshot (refreshed monthly; most can change during a game) and the two AI levels.
 *
 * Levels turn the "intelligence" and "development" settings into the knobs the modules read:
 *   intelligence: how many candidates are evaluated, how hard the pathfinders search, whether the planner
 *                 reads the score components and the end-game calendar, whether weak old vehicles are culled,
 *                 and how much random noise disturbs its ranking (the mistakes of a simpler player);
 *   development:  construction cadence, how far the network may grow, and the share of spare cash that goes
 *                 to towns (fund buildings, statues, advertising, road grids) and to new industries.
 */

class GameSnapshot {
	dist = null;             // cargo -> distribution type
	plane_crashes = 2;       // 0 none, 1 reduced, 2 normal
	plane_speed = 4;         // aircraft speed divisor (4 = 1/4)
	breakdowns = 1;          // 0 none, 1 reduced, 2 normal
	disasters = false;
	station_spread = 12;
	distant_join = true;
	max_train_length = 7;    // tiles
	forbid_90 = true;
	max_bridge_length = 64;
	max_tunnel_length = 64;
	build_on_slopes = true;
	stop_on_town_road = true;
	stop_on_competitor_road = false;
	town_crossings = true;   // towns may build level crossings over our track
	noise = false;
	gradual_loading = true;
	allow = null;            // [road, rail, air, water] allowed by the game and by our settings
	max_vehicles = null;     // [road, rail, air, water]
	recalc_interval = 8;
	recalc_time = 32;
	realistic_accel = true;
	opcodes = 10000;         // script operations per tick before the AI is suspended
	ai_speed = 2;          // difficulty.competitor_speed
	ending_year = 2050;      // the year the game ranks the companies (game_creation.ending_year)
	economy = 1;             // 0 original, 1 smooth, 2 frozen
	raw_industry = 0;        // construction.raw_industry_construction: 0 none, 1 prospecting, 2 as other industries
	town_layout = 0;         // economy.town_layout default for new towns (towns carry their own)
	town_growth_rate = 2;    // economy.town_growth_rate (0 none .. 4 very fast)
	larger_towns = 4;
	landscape = 0;           // 0 temperate, 1 arctic, 2 tropic, 3 toyland
	inflation = false;
	infrastructure = false;  // infrastructure maintenance (costs per tile/station part)
	modified_catchment = true;
	neutral_industries = true;
	town_roads = true;       // towns build roads themselves

	constructor() {
		this.allow = [true, true, true, true];
		this.max_vehicles = [500, 500, 200, 300];
		this.dist = {};
	}

	function Get(name, fallback) {
		if (!AIGameSettings.IsValid(name)) return fallback;
		return AIGameSettings.GetValue(name);
	}

	function Refresh() {
		foreach (c in Util.cargos) this.dist[c] <- AICargo.GetDistributionType(c);
		this.plane_crashes = this.Get("vehicle.plane_crashes", 2);
		this.plane_speed = max(1, this.Get("vehicle.plane_speed", 4));
		this.breakdowns = this.Get("difficulty.vehicle_breakdowns", 1);
		this.disasters = this.Get("difficulty.disasters", 0) != 0;
		this.station_spread = this.Get("station.station_spread", 12);
		this.distant_join = this.Get("station.distant_join_stations", 1) != 0;
		this.max_train_length = this.Get("vehicle.max_train_length", 7);
		this.forbid_90 = this.Get("pf.forbid_90_deg", 1) != 0;
		this.max_bridge_length = this.Get("construction.max_bridge_length", 64);
		this.max_tunnel_length = this.Get("construction.max_tunnel_length", 64);
		this.build_on_slopes = this.Get("construction.build_on_slopes", 1) != 0;
		this.stop_on_town_road = this.Get("construction.road_stop_on_town_road", 1) != 0;
		this.stop_on_competitor_road = this.Get("construction.road_stop_on_competitor_road", 0) != 0;
		this.town_crossings = this.Get("economy.allow_town_level_crossings", 1) != 0;
		this.noise = this.Get("economy.station_noise_level", 0) != 0;
		this.gradual_loading = this.Get("order.gradual_loading", 1) != 0;
		this.recalc_interval = this.Get("linkgraph.recalc_interval", 8);
		this.recalc_time = this.Get("linkgraph.recalc_time", 32);
		this.realistic_accel = this.Get("vehicle.train_acceleration_model", 1) == 1;
		this.opcodes = max(1, this.Get("script.script_max_opcode_till_suspend", 10000));
		this.ai_speed = this.Get("difficulty.competitor_speed", 2);   // the AI runs every 2^(4-n) ticks
		this.ending_year = this.Get("game_creation.ending_year", 2050);
		this.economy = this.Get("economy.type", 1);
		this.raw_industry = this.Get("construction.raw_industry_construction", 0);
		this.town_layout = this.Get("economy.town_layout", 0);
		this.town_growth_rate = this.Get("economy.town_growth_rate", 2);
		this.larger_towns = this.Get("economy.larger_towns", 4);
		this.landscape = this.Get("game_creation.landscape", 0);
		this.inflation = this.Get("economy.inflation", 0) != 0;
		this.infrastructure = this.Get("economy.infrastructure_maintenance", 0) != 0;
		this.modified_catchment = this.Get("station.modified_catchment", 1) != 0;
		this.neutral_industries = this.Get("station.serve_neutral_industries", 1) != 0;
		this.town_roads = this.Get("economy.allow_town_roads", 1) != 0;
		this.max_vehicles = [this.Get("vehicle.max_roadveh", 500), this.Get("vehicle.max_trains", 500),
			this.Get("vehicle.max_aircraft", 200), this.Get("vehicle.max_ships", 300)];
		this.allow = [
			this.Get("ai.ai_disable_veh_roadveh", 0) == 0 && AIController.GetSetting("use_road") == 1 && this.max_vehicles[0] > 0,
			this.Get("ai.ai_disable_veh_train", 0) == 0 && AIController.GetSetting("use_rail") == 1 && this.max_vehicles[1] > 0,
			this.Get("ai.ai_disable_veh_aircraft", 0) == 0 && AIController.GetSetting("use_air") == 1 && this.max_vehicles[2] > 0,
			this.Get("ai.ai_disable_veh_ship", 0) == 0 && AIController.GetSetting("use_water") == 1 && this.max_vehicles[3] > 0];
	}

	function CargoDistOn(cargo) { return (cargo in this.dist) && this.dist[cargo] != AICargo.DT_MANUAL; }

	function DistName(d) {
		if (d == AICargo.DT_SYMMETRIC) return "symmetric";
		if (d == AICargo.DT_ASYMMETRIC) return "asymmetric";
		return "manual";
	}

	/* Years left until the ranking (the rating of the last quarter before the ending year counts). */
	function YearsLeft() { return this.ending_year - Util.Year(); }

	function Describe() {
		local freight = -1;
		foreach (c in Util.cargos) if (c != Util.pax && c != Util.mail) { freight = this.dist[c]; break; }
		return "ending year " + this.ending_year + " (" + this.YearsLeft() + " years left); CargoDist passengers " +
			this.DistName(this.dist[Util.pax]) + (freight >= 0 ? ", freight " + this.DistName(freight) : "") +
			"; economy " + ["original", "smooth", "frozen"][Util.Clamp(this.economy, 0, 2)] +
			", raw industry construction " + ["off", "prospecting", "allowed"][Util.Clamp(this.raw_industry, 0, 2)] +
			", AI speed " + this.ai_speed + ", plane crashes " + ["none", "reduced", "normal"][Util.Clamp(this.plane_crashes, 0, 2)] +
			", breakdowns " + ["none", "reduced", "normal"][Util.Clamp(this.breakdowns, 0, 2)] +
			", inflation " + (this.inflation ? "on" : "off") + ", infrastructure maintenance " + (this.infrastructure ? "on" : "off") +
			", town growth rate " + this.town_growth_rate + ", vehicles allowed road/rail/air/water " +
			(this.allow[0] ? "y" : "n") + (this.allow[1] ? "y" : "n") + (this.allow[2] ? "y" : "n") + (this.allow[3] ? "y" : "n");
	}
}

/* The knobs derived from the two level settings; Refresh() reads the settings (they can change in game). */
class Levels {
	iq = 3;
	dev = 3;

	cand_limit = 80;       // candidates evaluated per planning step
	search_scale = 1.4;    // node budget multiplier of the pathfinders
	reroute_rounds = 4;    // corridor rounds when a rail search gets stuck
	score_aware = true;    // bonuses for score components below target, culling, end-game plan
	town_care = true;      // fund buildings, statues, advertising
	grid_roads = true;     // pre-build tidy road grids for growing towns
	fund_industries = true;
	probe_engines = true;  // test-build trains before choosing them
	noise = 0.0;           // relative random noise on candidate values (mistakes)
	patience = 3;          // failed searches tolerated per planning step
	cooldown = 8;          // base days between construction projects
	town_budget = 0.3;     // share of spare cash a month that town actions may use
	line_cap = 400;        // lines the network may reach
	vehicle_cap = 1000;    // vehicles in total
	early_double = true;   // open railways with double track when money allows
	reserve_months = 2;    // months of running costs kept as reserve

	function Refresh() {
		this.iq = Util.Clamp(AIController.GetSetting("intelligence"), 0, 3);
		this.dev = Util.Clamp(AIController.GetSetting("development"), 0, 3);
		local iq = this.iq, dev = this.dev;
		this.cand_limit = [6, 15, 40, 80][iq];
		this.search_scale = [0.5, 0.8, 1.0, 1.4][iq];
		this.reroute_rounds = [1, 2, 3, 4][iq];
		this.score_aware = iq >= 2;
		this.town_care = iq >= 1 && dev >= 1 && AIController.GetSetting("grow_towns") == 1;
		this.grid_roads = iq >= 2 && dev >= 1 && AIController.GetSetting("grow_towns") == 1;
		this.fund_industries = iq >= 2 && dev >= 2 && AIController.GetSetting("fund_industries") == 1;
		this.probe_engines = iq >= 1;
		this.noise = [0.35, 0.12, 0.0, 0.0][iq];
		this.patience = [1, 2, 3, 4][iq];
		this.cooldown = [90, 40, 18, 8][dev];
		this.town_budget = [0.0, 0.05, 0.15, 0.3][dev];
		this.line_cap = [12, 30, 90, 400][dev];
		this.vehicle_cap = [40, 120, 400, 1000][dev];
		this.early_double = dev >= 2;
		this.reserve_months = [3, 2, 2, 1][dev];
	}

	function Describe() {
		return "intelligence " + ["simple", "average", "clever", "brilliant"][this.iq] + ", development " +
			["modest", "steady", "ambitious", "relentless"][this.dev] + " (candidates " + this.cand_limit + ", cooldown " +
			this.cooldown + " d, line cap " + this.line_cap + ", score-aware " + (this.score_aware ? "yes" : "no") + ")";
	}
}
