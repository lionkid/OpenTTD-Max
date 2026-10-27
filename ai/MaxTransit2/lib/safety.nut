/*
 * Safety: the rules that keep vehicles (and the money in them) from being destroyed. They are hard rules in
 * construction and vehicle choice, not a trade-off:
 *   - large aircraft never get orders for small or commuter airports (3276 / 2^22 crash chance on every
 *     braking step of the landing in aircraft_cmd.cpp MaybeCrashAirplane, whatever the crash setting);
 *   - no level crossings: our railways bridge or tunnel under roads, our roads bridge over railways;
 *   - trains only share track that is protected by one-way path signals; an unsignalled line runs one train;
 *   - nothing is built on coast or sea-level tiles that the sea can flood (docks excepted, they float);
 *   - an airport keeps its hangar and is never removed while aircraft fly to it;
 *   - aircraft orders stay inside the aircraft's range.
 * The random landing crash of a correctly matched aircraft (about 0.1-0.3% per landing with the game's
 * "plane crashes" setting on) is the only risk left; the air_crashes setting decides whether to accept it.
 */

const CRASH_DENOM = 4194304;       // 2^22, GB(Random(), 0, 22) in MaybeCrashAirplane

class SafetyOfficer {
	incidents = null;      // [{date, reason, victims, tile, vehicle, route}]
	victims = 0;
	vetoes = null;         // reason -> {key -> true}
	danger_tiles = null;   // tile -> reason; never build through these again
	flagged = null;        // route id -> reason, handled by the fleet manager
	serviced = null;       // vehicle -> date it was last sent for service

	constructor() {
		this.incidents = [];
		this.vetoes = {};
		this.danger_tiles = {};
		this.flagged = {};
		this.serviced = {};
	}

	function Veto(reason, key = "") {
		if (!(reason in this.vetoes)) this.vetoes[reason] <- {};
		this.vetoes[reason][key] <- true;
		return false;
	}

	/* ---------------- aircraft and airports ---------------- */

	function IsShortStrip(type) { return type == AIAirport.AT_SMALL || type == AIAirport.AT_COMMUTER; }

	function IsHeliport(type) {
		return type == AIAirport.AT_HELIPORT || type == AIAirport.AT_HELISTATION || type == AIAirport.AT_HELIDEPOT;
	}

	/* May `engine` land at an airport of `type`? */
	function AirportOk(engine, type) {
		local pt = AIEngine.GetPlaneType(engine);
		if (this.IsHeliport(type) && pt != AIAirport.PT_HELICOPTER) return false;
		if (pt == AIAirport.PT_BIG_PLANE && this.IsShortStrip(type)) return false;
		return true;
	}

	/* Movement steps of the landing roll that roll for a crash (aircraft_cmd.cpp UpdateAircraftSpeed braking). */
	function CrashRollsPerLanding(engine) {
		local ps = ::MT.game.plane_speed;
		local v = min(230 * ps, max(1, AIEngine.GetMaxSpeed(engine)) * ps);
		local thr = 50 * ps, n = 0;
		while (v > thr && n < 2000) {
			v -= max(1, (v * v / 16384) / ps);
			n++;
		}
		return max(1, n);
	}

	/* Chance that one landing of a matched aircraft ends in a random crash (0 with the setting "none"). */
	function LandingProbability(engine) {
		local pc = ::MT.game.plane_crashes;
		if (pc <= 0) return 0.0;
		local p = ((0x4000 << pc) / 1500 + 1).tofloat() / CRASH_DENOM;
		return 1.0 - pow(1.0 - p, this.CrashRollsPerLanding(engine));
	}

	function PercentText(p) {
		local x = (p * 10000).tointeger();   // hundredths of a percent
		return (x / 100) + "." + (x % 100 < 10 ? "0" : "") + (x % 100) + "%";
	}

	/* Do we fly passengers at all under the current crash setting? */
	function FlyingAllowed() {
		return ::MT.game.plane_crashes <= 0 || AIController.GetSetting("air_crashes") == 0;
	}

	/* ---------------- land construction ---------------- */

	/* Coast and sea-level tiles can be flooded by the sea; vehicles on them are destroyed (CRASH_FLOODED). */
	function IsFloodRisk(tile) {
		if (AITile.IsCoastTile(tile) || AITile.IsWaterTile(tile)) return true;
		return AITile.GetMinHeight(tile) <= 0;
	}

	function IsDangerTile(tile) { return tile in this.danger_tiles; }

	/* Track or road we may build on: never on a level crossing, a flood risk or a crash site. */
	function TileOk(tile) {
		if (this.IsFloodRisk(tile)) return false;
		if (AIRail.IsLevelCrossingTile(tile)) return false;
		if (tile in this.danger_tiles) return false;
		return true;
	}

	/* Unsignalled track runs a single train; one-way path signalled double track may run many. */
	function MaxTrains(route) {
		if (!route.double_track) return 1;
		return max(1, route.signal_blocks);
	}

	/* ---------------- events ---------------- */

	function ReasonName(r) {
		switch (r) {
			case AIEventVehicleCrashed.CRASH_TRAIN: return "train collision";
			case AIEventVehicleCrashed.CRASH_RV_LEVEL_CROSSING: return "road vehicle hit at level crossing";
			case AIEventVehicleCrashed.CRASH_RV_UFO: return "road vehicle destroyed by UFO";
			case AIEventVehicleCrashed.CRASH_PLANE_LANDING: return "aircraft crashed on landing";
			case AIEventVehicleCrashed.CRASH_AIRCRAFT_NO_AIRPORT: return "aircraft without airport";
			case AIEventVehicleCrashed.CRASH_FLOODED: return "vehicle flooded";
		}
		return "unknown";
	}

	function OnVehicleCrashed(ev) {
		local v = ev.GetVehicleID();
		local reason = ev.GetCrashReason();
		local tile = ev.GetCrashSite();
		local n = ev.GetVictims();
		local route = ::MT.routes.RouteOfVehicle(v);
		this.victims += n;
		this.incidents.append({date = Util.Today(), reason = reason, victims = n, tile = tile, vehicle = v,
			route = route == null ? -1 : route.id});
		Log.Error("SAFETY", "INCIDENT: " + this.ReasonName(reason) + " at " + Util.TileStr(tile) + ", " + n +
			" victims" + (route == null ? "" : ", route " + route.Name()));
		switch (reason) {
			case AIEventVehicleCrashed.CRASH_RV_LEVEL_CROSSING:
				this.danger_tiles[tile] <- "level crossing crash";
				if (route != null) this.flagged[route.id] <- "level crossing on route";
				break;
			case AIEventVehicleCrashed.CRASH_TRAIN:
				if (route != null) this.flagged[route.id] <- "train collision";
				break;
			case AIEventVehicleCrashed.CRASH_FLOODED:
				this.danger_tiles[tile] <- "flooded";
				if (route != null) this.flagged[route.id] <- "flooded";
				break;
		}
	}

	/*
	 * Send unreliable aircraft and ships for service (trains and road vehicles have "service if needed" depot
	 * orders at both ends). Three quarters of what the model reaches when new, at most every 120 days.
	 */
	function ServiceRound() {
		if (::MT.game.breakdowns <= 0) return;
		local today = Util.Today();
		foreach (v, _ in AIVehicleList()) {
			if (!AIVehicle.IsPrimaryVehicle(v)) continue;
			local vt = AIVehicle.GetVehicleType(v);
			if (vt == AIVehicle.VT_RAIL || vt == AIVehicle.VT_ROAD) continue;
			local state = AIVehicle.GetState(v);
			if (state != AIVehicle.VS_RUNNING && state != AIVehicle.VS_AT_STATION) continue;
			local best = AIEngine.GetReliability(AIVehicle.GetEngineType(v));
			if (AIVehicle.GetReliability(v) >= min(45, best * 3 / 4)) continue;
			if ((v in this.serviced) && today - this.serviced[v] < 120) continue;
			if (AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) continue;
			if (AIVehicle.SendVehicleToDepotForServicing(v)) this.serviced[v] <- today;
		}
	}

	/* Re-check what is built: towns may add level crossings over our track, an engine may be renewed wrongly. */
	function Audit() {
		local issues = 0;
		foreach (route in ::MT.routes.Active()) {
			if (route.mode == MODE_AIR) {
				local ta = AIAirport.GetAirportType(route.tiles[0]), tb = AIAirport.GetAirportType(route.tiles[1]);
				foreach (v, _ in route.Vehicles()) {
					local e = AIVehicle.GetEngineType(v);
					if (!this.AirportOk(e, ta) || !this.AirportOk(e, tb)) {
						issues++;
						Log.Error("SAFETY", AIEngine.GetName(e) + " on " + route.Name() + " may not use these airports; withdrawn");
						::MT.fleet.Withdraw(v, "unsafe airport for aircraft class");
					}
				}
			} else if (route.mode == MODE_RAIL) {
				local crossings = 0;
				foreach (t in route.track_tiles) if (AIRail.IsLevelCrossingTile(t)) crossings++;
				if (crossings > 0) {
					issues++;
					this.flagged[route.id] <- "level crossing on track";
				}
				local trains = route.VehicleCount();
				if (trains > this.MaxTrains(route)) {
					issues++;
					::MT.fleet.TrimTo(route, this.MaxTrains(route), "too many trains for the signalling");
				}
			}
		}
		return issues;
	}

	function Report() {
		local s = "incidents " + this.incidents.len() + ", victims " + this.victims;
		local v = "";
		foreach (reason, keys in this.vetoes) {
			local n = 0;
			foreach (k, _ in keys) n++;
			v += (v == "" ? "" : ", ") + reason + " x" + n;
		}
		if (v != "") s += "; vetoed: " + v;
		return s;
	}
}
