/*
 * Snapshot of the game settings that change what is safe, fast or profitable. Refreshed every month
 * because most of them can be changed during a game.
 */

class GameSnapshot {
	dist_pax = 0;            // AICargo.DT_MANUAL / DT_ASYMMETRIC / DT_SYMMETRIC
	dist_mail = 0;
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
	town_crossings = true;   // towns may build level crossings over our track
	noise = false;
	gradual_loading = true;
	allow = null;            // [road, rail, air] allowed by the game and by our settings
	max_vehicles = null;     // [road, rail, air]
	recalc_interval = 8;
	recalc_time = 32;
	realistic_accel = true;

	constructor() {
		this.allow = [true, true, true];
		this.max_vehicles = [500, 500, 200];
	}

	function Get(name, fallback) {
		if (!AIGameSettings.IsValid(name)) return fallback;
		return AIGameSettings.GetValue(name);
	}

	function Refresh() {
		this.dist_pax = AICargo.GetDistributionType(Util.pax);
		this.dist_mail = Util.mail >= 0 ? AICargo.GetDistributionType(Util.mail) : 0;
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
		this.town_crossings = this.Get("economy.allow_town_level_crossings", 1) != 0;
		this.noise = this.Get("economy.station_noise_level", 0) != 0;
		this.gradual_loading = this.Get("order.gradual_loading", 1) != 0;
		this.recalc_interval = this.Get("linkgraph.recalc_interval", 8);
		this.recalc_time = this.Get("linkgraph.recalc_time", 32);
		this.realistic_accel = this.Get("vehicle.train_acceleration_model", 1) == 1;
		this.max_vehicles = [this.Get("vehicle.max_roadveh", 500), this.Get("vehicle.max_trains", 500),
			this.Get("vehicle.max_aircraft", 200)];
		this.allow = [
			this.Get("ai.ai_disable_veh_roadveh", 0) == 0 && AIController.GetSetting("use_road") == 1 && this.max_vehicles[0] > 0,
			this.Get("ai.ai_disable_veh_train", 0) == 0 && AIController.GetSetting("use_rail") == 1 && this.max_vehicles[1] > 0,
			this.Get("ai.ai_disable_veh_aircraft", 0) == 0 && AIController.GetSetting("use_air") == 1 && this.max_vehicles[2] > 0];
	}

	function CargoDistOn() { return this.dist_pax != AICargo.DT_MANUAL; }

	function DistName(d) {
		if (d == AICargo.DT_SYMMETRIC) return "symmetric";
		if (d == AICargo.DT_ASYMMETRIC) return "asymmetric";
		return "manual (CargoDist off)";
	}

	function Describe() {
		return "CargoDist passengers " + this.DistName(this.dist_pax) + ", mail " + this.DistName(this.dist_mail) +
			"; plane crashes " + ["none", "reduced", "normal"][Util.Clamp(this.plane_crashes, 0, 2)] +
			", plane speed 1/" + this.plane_speed + ", breakdowns " + ["none", "reduced", "normal"][Util.Clamp(this.breakdowns, 0, 2)] +
			", disasters " + (this.disasters ? "on" : "off") + ", station spread " + this.station_spread +
			", max train length " + this.max_train_length + " tiles, town level crossings " + (this.town_crossings ? "allowed" : "forbidden");
	}
}
