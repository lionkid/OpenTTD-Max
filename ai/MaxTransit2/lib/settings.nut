/*
 * Snapshot of the game settings that change what is possible, safe or profitable. Refreshed every month
 * because most of them can be changed during a game.
 */

class GameSnapshot {
	dist_pax = 0;            // AICargo.DT_MANUAL / DT_ASYMMETRIC / DT_SYMMETRIC
	plane_crashes = 2;       // 0 none, 1 reduced, 2 normal
	plane_speed = 4;         // aircraft speed divisor (4 = 1/4)
	breakdowns = 1;          // 0 none, 1 reduced, 2 normal
	station_spread = 12;
	max_train_length = 7;    // tiles
	max_bridge_length = 64;
	max_tunnel_length = 64;
	town_crossings = true;   // towns may build level crossings over our track
	noise = false;
	maintenance = false;     // infrastructure maintenance costs
	modified_catchment = true;
	allow = null;            // [road, rail, air, water] allowed by the game and by our settings
	max_vehicles = null;     // [road, rail, air, water]
	opcodes = 10000;         // script operations per tick before the AI is suspended
	pax_on = true;
	freight_on = true;

	constructor() {
		this.allow = [true, true, true, true];
		this.max_vehicles = [500, 500, 200, 300];
	}

	function Get(name, fallback) {
		if (!AIGameSettings.IsValid(name)) return fallback;
		return AIGameSettings.GetValue(name);
	}

	function Refresh() {
		this.dist_pax = Util.pax >= 0 ? AICargo.GetDistributionType(Util.pax) : AICargo.DT_MANUAL;
		this.plane_crashes = this.Get("vehicle.plane_crashes", 2);
		this.plane_speed = max(1, this.Get("vehicle.plane_speed", 4));
		this.breakdowns = this.Get("difficulty.vehicle_breakdowns", 1);
		this.station_spread = this.Get("station.station_spread", 12);
		this.max_train_length = this.Get("vehicle.max_train_length", 7);
		this.max_bridge_length = this.Get("construction.max_bridge_length", 64);
		this.max_tunnel_length = this.Get("construction.max_tunnel_length", 64);
		this.town_crossings = this.Get("economy.allow_town_level_crossings", 1) != 0;
		this.noise = this.Get("economy.station_noise_level", 0) != 0;
		this.maintenance = this.Get("economy.infrastructure_maintenance", 0) != 0;
		this.modified_catchment = this.Get("station.modified_catchment", 1) != 0;
		this.opcodes = max(1, this.Get("script.script_max_opcode_till_suspend", 10000));
		this.max_vehicles = [this.Get("vehicle.max_roadveh", 500), this.Get("vehicle.max_trains", 500),
			this.Get("vehicle.max_aircraft", 200), this.Get("vehicle.max_ships", 300)];
		this.allow = [
			this.Get("ai.ai_disable_veh_roadveh", 0) == 0 && AIController.GetSetting("use_road") == 1 && this.max_vehicles[0] > 0,
			this.Get("ai.ai_disable_veh_train", 0) == 0 && AIController.GetSetting("use_rail") == 1 && this.max_vehicles[1] > 0,
			this.Get("ai.ai_disable_veh_aircraft", 0) == 0 && AIController.GetSetting("use_air") == 1 && this.max_vehicles[2] > 0,
			this.Get("ai.ai_disable_veh_ship", 0) == 0 && AIController.GetSetting("use_water") == 1 && this.max_vehicles[3] > 0];
		this.pax_on = AIController.GetSetting("passengers") == 1 && Util.pax >= 0;
		this.freight_on = AIController.GetSetting("freight") == 1;
	}

	function CargoDistOn() { return this.dist_pax != AICargo.DT_MANUAL; }

	/* Catchment radius of a station type (the "modified catchment" setting shrinks bus, lorry and rail stops). */
	function Catchment(mode) {
		if (!this.modified_catchment) return 4;
		return [3, 4, 4, 5][mode];
	}

	/* Vehicles of a type we may still buy (game limit). */
	function VehicleRoom(mode) {
		local list = AIVehicleList();
		list.Valuate(AIVehicle.GetVehicleType);
		list.KeepValue([AIVehicle.VT_ROAD, AIVehicle.VT_RAIL, AIVehicle.VT_AIR, AIVehicle.VT_WATER][mode]);
		return this.max_vehicles[mode] - list.Count();
	}

	function Describe() {
		local modes = "";
		foreach (i, name in ["road", "rail", "air", "water"]) if (this.allow[i]) modes += (modes == "" ? "" : "/") + name;
		return "modes " + (modes == "" ? "none" : modes) + "; passengers " + (this.pax_on ? "on" : "off") + ", freight " +
			(this.freight_on ? "on" : "off") + "; CargoDist passengers " + (this.CargoDistOn() ? "on" : "off") +
			"; plane crashes " + ["none", "reduced", "normal"][Util.Clamp(this.plane_crashes, 0, 2)] +
			", plane speed 1/" + this.plane_speed + ", breakdowns " + ["none", "reduced", "normal"][Util.Clamp(this.breakdowns, 0, 2)] +
			", max train length " + this.max_train_length + " tiles, infrastructure maintenance " + (this.maintenance ? "on" : "off");
	}
}
