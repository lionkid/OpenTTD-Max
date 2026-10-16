/*
 * SafetyOfficer: passenger safety comes first.
 *
 * Every risk the game lets a company prevent is a hard veto here:
 *   - large aircraft never get orders for small or commuter airports (3276 / 2^22 crash chance per landing in
 *     aircraft_cmd.cpp MaybeCrashAirplane, which applies even when "plane crashes" is set to none);
 *   - no level crossings: our railways bridge or tunnel under roads, our roads bridge over railways;
 *   - trains only share track that is protected by one-way path signals; an unsignalled line runs one train;
 *   - nothing is built on coast or sea-level tiles that the sea can flood;
 *   - an airport keeps its hangar and is never removed while aircraft fly to it (CRASH_AIRCRAFT_NO_AIRPORT);
 *   - aircraft orders stay inside the aircraft's range.
 * The only risk left is the random landing crash of a correctly matched aircraft when the game setting is not
 * "none" (43 / 2^22 per landing on "normal"); the air policy setting decides how much travel time it must save.
 */

const CRASH_DENOM = 4194304;       // 2^22, GB(Random(), 0, 22) in MaybeCrashAirplane
const CRASH_SHORT_STRIP = 3276;    // large aircraft landing on a short strip

class SafetyOfficer {
	incidents = null;      // [{date, reason, victims, tile, vehicle, line}]
	victims = 0;
	vetoes = null;         // reason -> count
	danger_tiles = null;   // tile -> reason; never build through these again
	flagged_lines = null;  // line id -> reason, handled by the fleet manager
	audits = 0;
	last_issues = 0;
	fixed_issues = 0;
	landings_exposed = 0;  // estimated landings with a non-zero random crash chance
	delivered = 0;         // cargo units delivered (all our cargo is passengers and mail)
	last_quarter = -1;

	constructor() {
		this.incidents = [];
		this.vetoes = {};
		this.danger_tiles = {};
		this.flagged_lines = {};
	}

	/* Record a refused plan; `key` identifies what was refused so repeated evaluations count once. */
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

	/*
	 * Crash chance numerator (out of 2^22) for one landing of `engine` at an airport of `type`, or -1 when the
	 * combination is forbidden (unsafe or impossible).
	 */
	function LandingRisk(engine, type) {
		local pt = AIEngine.GetPlaneType(engine);
		if (this.IsHeliport(type) && pt != AIAirport.PT_HELICOPTER) return -1;
		if (pt == AIAirport.PT_BIG_PLANE && this.IsShortStrip(type)) return -1;
		local pc = ::MT.game.plane_crashes;
		if (pc <= 0) return 0;
		return (0x4000 << pc) / 1500;
	}

	function CanUseAirports(engine, type_a, type_b) {
		if (this.LandingRisk(engine, type_a) < 0 || this.LandingRisk(engine, type_b) < 0) {
			return this.Veto("aircraft class not allowed at the airport", engine + "@" + min(type_a, type_b) + "/" + max(type_a, type_b));
		}
		return true;
	}

	/* Range check with a 10% margin; 0 means unlimited range. */
	function InRange(engine, tile_a, tile_b) {
		local range = AIEngine.GetMaximumOrderDistance(engine);
		if (range <= 0) return true;
		local dist = AIOrder.GetOrderDistance(AIVehicle.VT_AIR, tile_a, tile_b);
		if (dist * 10 > range * 9) return this.Veto("out of range", engine + "@" + tile_a + "/" + tile_b);
		return true;
	}

	/* Expected passenger victims per year for a planned air line: landings x chance x people on board. */
	function AirRiskPerYear(engine, type_a, type_b, landings_per_year, pax_per_flight) {
		local ra = this.LandingRisk(engine, type_a), rb = this.LandingRisk(engine, type_b);
		if (ra < 0 || rb < 0) return -1.0;
		return landings_per_year / 2.0 * (ra + rb).tofloat() / CRASH_DENOM * (pax_per_flight + 2);
	}

	/*
	 * Air policy: may passengers fly instead of taking a surface route of `alt_days`?
	 * With random crashes off, a matched aircraft is as safe as a train and only time and value decide.
	 */
	function AirAllowed(air_days, alt_days, key = "") {
		if (::MT.game.plane_crashes <= 0) return true;
		local policy = AIController.GetSetting("air_policy");
		if (policy == 2) return this.Veto("air link (policy: no flying with random crashes)", key);
		if (policy == 1 && alt_days > 0 && air_days * 10 > alt_days * 6) return this.Veto("air link (policy: saves < 40% time over rail)", key);
		return true;
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
	function MaxTrains(line) {
		if (!line.double_track) return 1;
		return max(1, line.signal_blocks);
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
		local line = ::MT.network.LineOfVehicle(v);
		this.victims += n;
		this.incidents.append({date = Util.Today(), reason = reason, victims = n, tile = tile, vehicle = v,
			line = line == null ? -1 : line.id});
		Log.Error("SAFETY", "INCIDENT: " + this.ReasonName(reason) + " at " + Util.TileStr(tile) + ", " + n +
			" victims, vehicle " + v + (line == null ? "" : ", line " + line.Name()));

		switch (reason) {
			case AIEventVehicleCrashed.CRASH_RV_LEVEL_CROSSING:
				/* A crossing we did not build (a town or a competitor). Never route through it again and move the
				 * line off this road if the fleet manager can. */
				this.danger_tiles[tile] <- "level crossing crash";
				if (line != null) this.flagged_lines[line.id] <- "level crossing on route";
				break;
			case AIEventVehicleCrashed.CRASH_TRAIN:
				if (line != null) this.flagged_lines[line.id] <- "train collision";
				break;
			case AIEventVehicleCrashed.CRASH_PLANE_LANDING:
				if (line != null) this.flagged_lines[line.id] <- "landing crash";
				break;
			case AIEventVehicleCrashed.CRASH_AIRCRAFT_NO_AIRPORT:
				this.Audit();
				break;
			case AIEventVehicleCrashed.CRASH_FLOODED:
				this.danger_tiles[tile] <- "flooded";
				if (line != null) this.flagged_lines[line.id] <- "flooded";
				break;
		}
	}

	/* ---------------- periodic duties ---------------- */

	/* Keep aged or unreliable vehicles out of service until they are serviced. */
	function ServiceRound() {
		if (::MT.game.breakdowns <= 0) return;
		local list = AIVehicleList();
		foreach (v, _ in list) {
			if (!AIVehicle.IsPrimaryVehicle(v)) continue;
			local state = AIVehicle.GetState(v);
			if (state != AIVehicle.VS_RUNNING && state != AIVehicle.VS_AT_STATION) continue;
			if (AIVehicle.GetReliability(v) >= 45) continue;
			if (AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) continue;
			if (AIVehicle.SendVehicleToDepotForServicing(v)) {
				Log.Info("SAFETY", "vehicle " + AIVehicle.GetName(v) + " reliability " + AIVehicle.GetReliability(v) + "%: sent for service");
			}
		}
	}

	/*
	 * Network audit: re-checks every rule on what is built and running. Towns may add level crossings later
	 * (economy.allow_town_level_crossings), a vehicle may have been replaced by a model of another class, etc.
	 */
	function Audit() {
		this.audits++;
		local issues = 0;
		foreach (line in ::MT.network.lines) {
			if (line.state == LINE_CLOSED) continue;
			if (line.mode == MODE_AIR) {
				local ta = AIAirport.GetAirportType(line.tiles[0]), tb = AIAirport.GetAirportType(line.tiles[1]);
				foreach (v, _ in line.Vehicles()) {
					local e = AIVehicle.GetEngineType(v);
					if (this.LandingRisk(e, ta) < 0 || this.LandingRisk(e, tb) < 0) {
						issues++;
						Log.Error("SAFETY", "audit: " + AIEngine.GetName(e) + " on " + line.Name() + " may not use these airports; withdrawn");
						::MT.fleet.Withdraw(v, "unsafe airport for aircraft class");
					}
				}
				if (AIAirport.GetNumHangars(line.tiles[0]) == 0 || AIAirport.GetNumHangars(line.tiles[1]) == 0) {
					issues++;
					Log.Warn("SAFETY", "audit: airport without hangar on " + line.Name());
				}
			} else if (line.mode == MODE_RAIL) {
				local crossings = 0;
				foreach (t in line.track_tiles) if (AIRail.IsLevelCrossingTile(t)) crossings++;
				if (crossings > 0) {
					issues++;
					this.flagged_lines[line.id] <- "level crossing on track";
					Log.Error("SAFETY", "audit: " + crossings + " level crossing(s) appeared on " + line.Name());
				}
				local trains = line.VehicleCount();
				if (trains > this.MaxTrains(line)) {
					issues++;
					Log.Error("SAFETY", "audit: " + trains + " trains on " + line.Name() + " (limit " + this.MaxTrains(line) + ")");
					::MT.fleet.TrimTo(line, this.MaxTrains(line), "too many trains for the signalling");
				}
			} else if (line.mode == MODE_ROAD) {
				local crossings = 0;
				foreach (t in line.track_tiles) if (AIRail.IsLevelCrossingTile(t)) crossings++;
				if (crossings > 0) {
					issues++;
					this.flagged_lines[line.id] <- "level crossing on road";
					Log.Warn("SAFETY", "audit: " + crossings + " level crossing(s) on the road of " + line.Name());
				}
			}
		}
		this.last_issues = issues;
		return issues;
	}

	/* Called every month: adds each finished economy quarter to the running total. */
	function CountDelivered() {
		local cur = (AIDate.GetMonth(Util.Today()) - 1) / 3;
		if (this.last_quarter == -1) { this.last_quarter = cur; return; }
		if (cur != this.last_quarter) {
			this.delivered += AICompany.GetQuarterlyCargoDelivered(AICompany.COMPANY_SELF, AICompany.CURRENT_QUARTER + 1);
			this.last_quarter = cur;
		}
	}

	function Delivered() {
		return this.delivered + AICompany.GetQuarterlyCargoDelivered(AICompany.COMPANY_SELF, AICompany.CURRENT_QUARTER);
	}

	function Report() {
		local s = "incidents " + this.incidents.len() + ", victims " + this.victims + ", passengers and mail delivered " +
			this.Delivered() + ", audits " + this.audits + " (open issues " + this.last_issues + ")";
		local v = "";
		foreach (reason, keys in this.vetoes) {
			local n = 0;
			foreach (k, _ in keys) n++;
			v += (v == "" ? "" : ", ") + reason + " x" + n;
		}
		if (v != "") s += "; vetoed plans: " + v;
		return s;
	}
}
