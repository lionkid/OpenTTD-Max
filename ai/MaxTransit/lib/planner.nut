/*
 * Planner: decides what to build next.
 *
 * Candidates are town pairs scored per mode. Each mode is only considered in the distance band where it can
 * be worth its cost, and the comparison between modes follows the AI's priorities:
 *   1. safety: unsafe plans are never generated (SafetyOfficer filters engines, airports, tiles and paths);
 *      while random plane crashes are enabled, the air policy may forbid an air link unless it saves enough
 *      door-to-door time over rail;
 *   2. time: TimeModel.Evaluate charges every passenger-day (riding and waiting) on top of the fare loss;
 *   3. value: return on the money spent, with a bonus for joining the existing network (CargoDist gives a
 *      new link the demand of every station it connects to) and for transfer flows a direct link would serve.
 * Before new links, the planner finishes what makes existing ones better: second tracks where one train is
 * not enough, bus shuttles between an airport and the town's hub station, and walk-in stops that extend a
 * hub's catchment.
 */

class Planner {
	last_build = -10000;
	failures = null;      // candidate key -> date of the last failure
	transfer_bonus = null; // "townA:townB" -> monthly passengers changing at a hub between them
	policy_logged = null;  // air links refused by the air policy (logged once)
	refused = null;        // town -> date its local authority last refused us

	constructor() {
		this.failures = {};
		this.transfer_bonus = {};
		this.policy_logged = {};
		this.refused = {};
	}

	/* Called after ERR_LOCAL_AUTHORITY_REFUSES: plant trees to win the town back, wait before retrying. */
	function OnRefused(town) {
		if (!AITown.IsValidTown(town)) return;
		this.refused[town] <- Util.Today();
		local n = Util.PlantTrees(town, 30);
		Log.Info("PLAN", Util.TownName(town) + " refused construction (rating " + Util.RatingEstimate(town) +
			"); planted " + n + " trees to repair relations");
	}

	function Refused(town) { return (town in this.refused) && Util.Today() - this.refused[town] < 240; }

	function Cooldown() {
		local base = [120, 40, 12][Util.Clamp(AIController.GetSetting("expansion"), 0, 2)];
		/* money in the bank does nothing for the passengers: build sooner when the reserve is large */
		if (::MT.finance.Available() > 2000000) return base / 4;
		if (::MT.finance.Available() > 600000) return base / 2;
		return base;
	}

	function PlatformLength() { return Util.Clamp(::MT.game.max_train_length, 3, 6); }

	function Step() {
		if (Util.Today() - this.last_build < this.Cooldown()) return;
		if (::MT.finance.trouble) return;
		foreach (line in ::MT.network.Active()) {
			if (line.mode != MODE_RAIL || line.double_track) continue;
			if (line.note == "signals") {
				this.last_build = Util.Today();
				this.InstallSignals(line, this.Decode(line.p2));
				return;
			}
			if (line.note == "upgrade" && ::MT.finance.CanAfford(this.UpgradeCost(line))) {
				this.last_build = Util.Today();
				this.UpgradeRail(line);
				return;
			}
		}
		if (this.Interchanges()) { this.last_build = Util.Today(); return; }
		local cands = this.Candidates();
		local tried = 0;
		local started = Util.Today();
		foreach (c in cands) {
			if (!::MT.finance.CanAfford(c.cost)) continue;
			if (++tried > 3 || Util.Today() - started > 45) break;   // failed searches cost game time; let the fleet catch up
			Log.Info("PLAN", "building " + this.Describe(c));
			local ok = false;
			try {
				if (c.mode == MODE_AIR) ok = this.BuildAir(c);
				else if (c.mode == MODE_RAIL) ok = this.BuildRail(c);
				else ok = this.BuildRoad(c);
			} catch (e) {
				Log.Error("PLAN", "construction error: " + e);
				ok = false;
			}
			this.last_build = Util.Today();
			if (ok) return;
			this.failures[c.key] <- Util.Today();
		}
	}

	function Describe(c) {
		return ["bus", "rail", "air"][c.mode] + " " + Util.TownName(c.a) + " - " + Util.TownName(c.b) + " (" + c.dist +
			" tiles, est. demand " + c.demand.tointeger() + "/month, one way " + c.one_way.tointeger() + " d, cost " +
			Util.Money(c.cost.tointeger()) + ", value " + Util.Money(c.value.tointeger()) + "/year)";
	}

	/* ---------------- candidates ---------------- */

	function Towns() {
		local list = AITownList();
		list.Valuate(AITown.GetPopulation);
		list.KeepAboveValue(220);
		return Util.TopN(list, 32);
	}

	/* Monthly passengers our stations would collect in a town (houses produce them every month). */
	function Supply(town, mode) {
		local prod = AITown.GetLastMonthProduction(town, Util.pax);
		local capture = [0.30, 0.40, 0.35][mode];
		local hub = ::MT.network.HubStation(town);
		if (hub >= 0) capture += 0.1;
		return prod * capture;
	}

	function Candidates() {
		local towns = this.Towns();
		local out = [];
		local game = ::MT.game;
		local in_net = {};
		foreach (l in ::MT.network.lines) {
			if (l.state == LINE_CLOSED) continue;
			in_net[l.towns[0]] <- true;
			in_net[l.towns[1]] <- true;
		}
		for (local i = 0; i < towns.len(); i++) {
			for (local j = i + 1; j < towns.len(); j++) {
				local a = towns[i], b = towns[j];
				if (this.Refused(a) || this.Refused(b)) continue;
				local la = AITown.GetLocation(a), lb = AITown.GetLocation(b);
				local d = AIMap.DistanceManhattan(la, lb);
				if (d < 10) continue;
				local found = [];
				if (game.allow[MODE_ROAD] && d <= 45 && !::MT.network.HasLink(a, b, MODE_ROAD)) {
					local c = this.EvalRoad(a, b, d);
					if (c != null) found.append(c);
				}
				local rail = null;
				if (game.allow[MODE_RAIL] && d >= 28 && d <= 260 && !::MT.network.HasLink(a, b, MODE_RAIL)) {
					rail = this.EvalRail(a, b, d);
					if (rail != null) found.append(rail);
				}
				if (game.allow[MODE_AIR] && d >= 60 && !::MT.network.HasLink(a, b, MODE_AIR)) {
					local c = this.EvalAir(a, b, d);
					if (c != null) {
						/* Safety first: compare with the surface alternative the AI could build instead. */
						local alt = rail != null ? rail.door : (game.allow[MODE_RAIL] && d <= 260 ? this.SurfaceDays(d) : -1);
						if (::MT.safety.AirAllowed(c.door, alt, c.key)) found.append(c);
						else if (!(c.key in this.policy_logged)) {
							this.policy_logged[c.key] <- true;
							Log.Info("SAFETY", "air link " + Util.TownName(a) + " - " + Util.TownName(b) + " not planned: " +
								"door-to-door " + c.door.tointeger() + " d by air vs " + alt.tointeger() + " d by rail (air policy)");
						}
					}
				}
				foreach (c in found) {
					if ((c.key in this.failures) && Util.Today() - this.failures[c.key] < 730) continue;
					/* CargoDist network effect: a link that joins our network serves all its destinations. */
					local na = (a in in_net), nb = (b in in_net);
					if (na != nb) c.value *= 1.35;
					else if (!na && !nb && ::MT.network.lines.len() > 0) c.value *= 0.9;
					local tb = this.TransferBonus(a, b);
					if (tb > 0) c.value += tb * 12 * c.fare * 0.5;
					c.score <- c.value / fmax(1.0, c.cost);
					if (c.value > 0) out.append(c);
				}
			}
		}
		out.sort(function(x, y) { return y.score > x.score ? 1 : (y.score < x.score ? -1 : 0); });
		return out;
	}

	/* Rough door-to-door days by the best train available, for the air policy when no rail plan exists. */
	function SurfaceDays(d) {
		local best = ::MT.engines.BestTrain(this.PlatformLength(), d * 1.2, d, 200);
		if (best == null) return -1;
		return ::MT.time.DoorToDoor(best.eval.one_way, best.eval.headway);
	}

	function Demand(a, b, mode) {
		local d = fmin(this.Supply(a, mode), this.Supply(b, mode));
		return fmax(20.0, d);
	}

	function Key(a, b, mode) { return min(a, b) + ":" + max(a, b) + ":" + mode; }

	function Cand(mode, a, b, d, demand, best, cost) {
		return {mode = mode, a = a, b = b, dist = d, demand = demand, engine = best.engine, best = best, cost = cost.tofloat(),
			value = best.eval.value.tofloat(), one_way = best.eval.one_way, fare = best.eval.fare,
			door = ::MT.time.DoorToDoor(best.eval.one_way, best.eval.headway), key = this.Key(a, b, mode)};
	}

	function EvalRoad(a, b, d) {
		local demand = this.Demand(a, b, MODE_ROAD);
		local best = ::MT.engines.BestBus(d * 1.25, d, demand);
		if (best == null) return null;
		local rt = AIRoad.ROADTYPE_ROAD;
		local cost = AIRoad.GetBuildCost(rt, AIRoad.BT_ROAD) * d * 0.7 + 2 * AIRoad.GetBuildCost(rt, AIRoad.BT_BUS_STOP) +
			2 * AIRoad.GetBuildCost(rt, AIRoad.BT_DEPOT) + min(best.eval.n, 2) * AIEngine.GetPrice(best.engine);
		return this.Cand(MODE_ROAD, a, b, d, demand, best, cost);
	}

	function EvalRail(a, b, d) {
		local demand = this.Demand(a, b, MODE_RAIL);
		local L = this.PlatformLength();
		local tiles = d * 1.2;
		local best = ::MT.engines.BestTrain(L, tiles, d, demand);
		if (best == null) return null;
		local rt = best.plan.railtype;
		local track = AIRail.GetBuildCost(rt, AIRail.BT_TRACK) * tiles * 1.2;
		local stations = 2 * (2 * L * AIRail.GetBuildCost(rt, AIRail.BT_STATION) + 10 * AIRail.GetBuildCost(rt, AIRail.BT_TRACK) +
			AIRail.GetBuildCost(rt, AIRail.BT_DEPOT));
		local clear = AITile.GetBuildCost(AITile.BT_CLEAR_GRASS) * tiles * 2;
		local first = track + stations + clear + best.plan.price;
		/* the full value needs the second track and more trains */
		local full = first + track + AIRail.GetBuildCost(rt, AIRail.BT_SIGNAL) * tiles / 3 + (best.eval.n - 1) * best.plan.price;
		local c = this.Cand(MODE_RAIL, a, b, d, demand, best, full);
		c.first_cost <- first;
		c.cost = first;
		c.value = c.value * first / full;
		return c;
	}

	function EvalAir(a, b, d) {
		local demand = this.Demand(a, b, MODE_AIR);
		local budget = ::MT.finance.Available();
		local ta = this.AirportTypeFor(a, budget), tb = this.AirportTypeFor(b, budget);
		if (ta < 0 || tb < 0) return null;
		local la = AITown.GetLocation(a), lb = AITown.GetLocation(b);
		local best = ::MT.engines.BestAircraft(la, lb, ta, tb, demand);
		if (best == null) return null;
		local cost = (this.HasAirport(a) ? 0 : AIAirport.GetPrice(ta)) + (this.HasAirport(b) ? 0 : AIAirport.GetPrice(tb)) +
			2 * AIEngine.GetPrice(best.engine);
		local c = this.Cand(MODE_AIR, a, b, d, demand, best, cost);
		c.type_a <- ta;
		c.type_b <- tb;
		/* Residual random landing risk is a cost too (only non-zero when the game setting allows crashes). */
		local risk = ::MT.safety.AirRiskPerYear(best.engine, ta, tb, 24.0 * best.eval.n * 30.0 / best.eval.rtt, best.capacity);
		if (risk > 0) c.value -= risk * 2000000;
		return c;
	}

	function HasAirport(town) {
		local hub = ::MT.network.Hub(town);
		return AIStation.IsValidStation(hub.air_sid) && AIAirport.IsAirportTile(hub.air_tile);
	}

	function AirportTypeFor(town, budget) {
		if (this.HasAirport(town)) return AIAirport.GetAirportType(::MT.network.Hub(town).air_tile);
		local types = ::MT.air.ChooseTypes(AITown.GetPopulation(town), budget / 3);
		return types.len() > 0 ? types[0] : -1;
	}

	function TransferBonus(a, b) {
		local k = min(a, b) + ":" + max(a, b);
		return (k in this.transfer_bonus) ? this.transfer_bonus[k] : 0;
	}

	/* Transfer flows at our hubs (CargoDist): candidates for direct links that save the change. */
	function ScanTransfers() {
		this.transfer_bonus = {};
		foreach (town, hub in ::MT.network.hubs) {
			if (!AIStation.IsValidStation(hub.sid)) continue;
			foreach (p in ::MT.cdist.TransferPairs(hub.sid, 60)) {
				local ta = AIStation.GetNearestTown(p[0]), tb = AIStation.GetNearestTown(p[1]);
				if (ta == tb) continue;
				local k = min(ta, tb) + ":" + max(ta, tb);
				if (!(k in this.transfer_bonus)) this.transfer_bonus[k] <- 0;
				this.transfer_bonus[k] += p[2];
			}
		}
	}

	/* ---------------- construction: road ---------------- */

	function StopFor(town, join) {
		local center = AITown.GetLocation(town);
		local r = 4 + min(6, AITown.GetPopulation(town) / 800);
		local spot = ::MT.road.FindStop(center, r, join);
		if (spot == null && join != AIStation.STATION_NEW) spot = ::MT.road.FindStop(center, r, AIStation.STATION_NEW);
		return spot;
	}

	function JoinId(town) {
		local sid = ::MT.network.HubStation(town);
		return sid >= 0 ? sid : AIStation.STATION_NEW;
	}

	function BuildRoad(c) {
		local spot_a = this.StopFor(c.a, this.JoinId(c.a));
		local spot_b = this.StopFor(c.b, this.JoinId(c.b));
		if (spot_a == null || spot_b == null) { Log.Warn("PLAN", "no stop site"); return false; }
		return this.BuildBusLine(c.a, c.b, spot_a, spot_b, this.JoinId(c.a), this.JoinId(c.b), c.engine, false);
	}

	function BuildBusLine(ta, tb, spot_a, spot_b, join_a, join_b, engine, feeder) {
		if (!::MT.finance.Ensure(4 * AIRoad.GetBuildCost(AIRoad.ROADTYPE_ROAD, AIRoad.BT_BUS_STOP))) return false;
		local sa = ::MT.road.BuildStop(spot_a, join_a);
		if (sa < 0 && join_a != AIStation.STATION_NEW) sa = ::MT.road.BuildStop(spot_a, AIStation.STATION_NEW);
		if (sa < 0) return false;
		local sb = ::MT.road.BuildStop(spot_b, join_b);
		if (sb < 0 && join_b != AIStation.STATION_NEW) sb = ::MT.road.BuildStop(spot_b, AIStation.STATION_NEW);
		if (sb < 0) { AIRoad.RemoveRoadStation(spot_a.tile); return false; }
		local conn = ::MT.road.Connect(spot_a.tile, spot_b.tile);
		if (conn == null || conn.crossing_risk) {
			if (conn != null) {
				::MT.safety.Veto("bus route through a level crossing", ta + ":" + tb);
				Log.Warn("SAFETY", "bus line " + Util.TownName(ta) + " - " + Util.TownName(tb) + " refused: the shortest road uses a level crossing");
			} else Log.Warn("PLAN", "no road route " + Util.TileStr(spot_a.tile) + " - " + Util.TileStr(spot_b.tile));
			AIRoad.RemoveRoadStation(spot_a.tile);
			AIRoad.RemoveRoadStation(spot_b.tile);
			return false;
		}
		local pieces = ::MT.road.NewPieces(conn.path);
		::MT.finance.Ensure(pieces * AIRoad.GetBuildCost(AIRoad.ROADTYPE_ROAD, AIRoad.BT_ROAD) * 2 + 20000);
		if (!::MT.road.BuildPath(conn.path)) {
			AIRoad.RemoveRoadStation(spot_a.tile);
			AIRoad.RemoveRoadStation(spot_b.tile);
			return false;
		}
		local da = ::MT.road.BuildDepotNear(spot_a.tile);
		local db = ::MT.road.BuildDepotNear(spot_b.tile);
		if (da < 0 && db < 0) {
			Log.Warn("PLAN", "no depot site for the bus line");
			AIRoad.RemoveRoadStation(spot_a.tile);
			AIRoad.RemoveRoadStation(spot_b.tile);
			return false;
		}
		local line = Line();
		line.mode = MODE_ROAD;
		line.towns = [ta, tb];
		line.sids = [sa, sb];
		line.tiles = [spot_a.tile, spot_b.tile];
		line.depots = [da, db];
		line.engine = engine;
		line.capacity = AIEngine.GetCapacity(engine);
		line.speed = AIEngine.GetMaxSpeed(engine);
		line.dist = AIMap.DistanceManhattan(spot_a.tile, spot_b.tile);
		line.path_len = conn.path.len();
		line.est_rtt = ::MT.time.RoundTrip(MODE_ROAD, line.speed, line.path_len, line.capacity);
		line.track_tiles = conn.path;
		line.feeder = feeder;
		::MT.network.Add(line);
		this.RegisterStation(ta, sa, MODE_ROAD);
		this.RegisterStation(tb, sb, MODE_ROAD);
		::MT.fleet.BuildFor(line, 0);
		if (!feeder || line.est_rtt > 12) ::MT.fleet.BuildFor(line, 1);
		Log.Info("BUILD", line.Name() + " opened: " + line.path_len + " road tiles (" + ::MT.road.NewPieces(conn.path) + " new), " +
			AIEngine.GetName(engine) + ", round trip about " + line.est_rtt.tointeger() + " days");
		Util.SignAt(spot_a.tile, "MT " + line.Name());
		return true;
	}

	function RegisterStation(town, sid, mode) {
		local hub = ::MT.network.Hub(town);
		if (!AIStation.IsValidStation(hub.sid)) hub.sid = sid;
		if (mode == MODE_RAIL) hub.rail++;
		if (mode == MODE_ROAD && hub.sid == sid) hub.road_stops.append(sid);
	}

	/* ---------------- construction: air ---------------- */

	function EnsureAirport(town, want_type) {
		local hub = ::MT.network.Hub(town);
		if (AIStation.IsValidStation(hub.air_sid) && AIAirport.IsAirportTile(hub.air_tile)) return [hub.air_tile, false];
		local types = [want_type];
		foreach (t in ::MT.air.ChooseTypes(AITown.GetPopulation(town), ::MT.finance.Available())) if (t != want_type) types.append(t);
		foreach (t in types) {
			local join = this.JoinId(town);
			local tile = ::MT.air.FindSite(town, t, join);
			if (tile < 0 && join != AIStation.STATION_NEW) { join = AIStation.STATION_NEW; tile = ::MT.air.FindSite(town, t, join); }
			if (tile < 0) continue;
			if (!::MT.finance.Ensure(AIAirport.GetPrice(t) + 5000)) return null;
			local sid = ::MT.air.Build(tile, t, join);
			if (sid < 0 && join != AIStation.STATION_NEW) sid = ::MT.air.Build(tile, t, AIStation.STATION_NEW);
			if (sid < 0) continue;
			hub.air_sid = sid;
			hub.air_tile = tile;
			hub.air_type = t;
			if (!AIStation.IsValidStation(hub.sid)) hub.sid = sid;
			Log.Info("BUILD", ::MT.air.TypeName(t) + " airport for " + Util.TownName(town) + " at " + Util.TileStr(tile) +
				(sid == hub.sid ? " (hub station)" : ""));
			return [tile, true];
		}
		return null;
	}

	function BuildAir(c) {
		local ea = this.EnsureAirport(c.a, c.type_a);
		if (ea == null) return false;
		local eb = this.EnsureAirport(c.b, c.type_b);
		if (eb == null) { this.DropAirport(c.a, ea); return false; }
		local ta = AIAirport.GetAirportType(ea[0]), tb = AIAirport.GetAirportType(eb[0]);
		local best = ::MT.engines.BestAircraft(ea[0], eb[0], ta, tb, c.demand);
		if (best == null) {
			Log.Warn("PLAN", "no safe aircraft for " + ::MT.air.TypeName(ta) + " / " + ::MT.air.TypeName(tb) + " airports");
			this.DropAirport(c.a, ea);
			this.DropAirport(c.b, eb);
			return false;
		}
		local line = Line();
		line.mode = MODE_AIR;
		line.towns = [c.a, c.b];
		line.sids = [AIStation.GetStationID(ea[0]), AIStation.GetStationID(eb[0])];
		line.tiles = [ea[0], eb[0]];
		line.depots = [AIAirport.GetHangarOfAirport(ea[0]), AIAirport.GetHangarOfAirport(eb[0])];
		line.engine = best.engine;
		line.capacity = best.capacity;
		line.speed = AIEngine.GetMaxSpeed(best.engine);
		line.dist = AIMap.DistanceManhattan(ea[0], eb[0]);
		line.path_len = ::MT.time.AirTiles(ea[0], eb[0]);
		line.est_rtt = ::MT.time.RoundTrip(MODE_AIR, line.speed, line.path_len, line.capacity);
		::MT.network.Add(line);
		::MT.fleet.BuildFor(line, 0);
		::MT.fleet.BuildFor(line, 1);
		local pt = AIEngine.GetPlaneType(best.engine);
		Log.Info("BUILD", line.Name() + " opened: " + AIEngine.GetName(best.engine) + " (" +
			(pt == AIAirport.PT_BIG_PLANE ? "large" : "small") + " aircraft, " + ::MT.air.TypeName(ta) + " / " + ::MT.air.TypeName(tb) +
			" airports: landing risk " + ::MT.safety.LandingRisk(best.engine, ta) + "/2^22), " + line.dist + " tiles, round trip about " +
			line.est_rtt.tointeger() + " days");
		return true;
	}

	/* Remove an airport we just built for a plan that failed (no aircraft can be heading there yet). */
	function DropAirport(town, ea) {
		if (ea == null || !ea[1]) return;
		if (AIVehicleList_Station(AIStation.GetStationID(ea[0])).Count() > 0) return;
		local hub = ::MT.network.Hub(town);
		if (hub.sid == hub.air_sid) hub.sid = -1;
		hub.air_sid = -1;
		hub.air_tile = -1;
		AIAirport.RemoveAirport(ea[0]);
	}

	/* ---------------- construction: rail ---------------- */

	/*
	 * A doubled, signalled line ending in `town` whose station a new line can share (via a junction on its
	 * tracks). Sharing puts both lines into one station, so CargoDist can route transfers through it.
	 */
	function SharedRailEnd(town) {
		foreach (line in ::MT.network.Active()) {
			if (line.mode != MODE_RAIL || !line.double_track || line.branch) continue;
			for (local end = 0; end < 2; end++) {
				if (line.towns[end] != town) continue;
				if (::MT.network.LinesAt(line.sids[end]).len() >= 3) continue;
				return {line = line, end = end, site = line.sites[end]};
			}
		}
		return null;
	}

	/*
	 * No room for a new terminal in `town`: if one of our single-track lines ends there, double it so that the
	 * next line can share its station (and its own passengers get more trains).
	 */
	function UnlockSharing(town) {
		foreach (line in ::MT.network.Active()) {
			if (line.mode != MODE_RAIL || line.double_track || line.branch || line.note != "") continue;
			if (line.towns[0] != town && line.towns[1] != town) continue;
			if (line.upgrade_failed != 0 && Util.Today() - line.upgrade_failed < 730) continue;
			line.note = "upgrade";
			Log.Info("PLAN", "no room for another terminal in " + Util.TownName(town) + ": doubling " + line.Name() + " so new lines can share its station");
			return true;
		}
		return false;
	}

	function BuildRail(c) {
		local sa = this.SharedRailEnd(c.a), sb = this.SharedRailEnd(c.b);
		if (sa != null || sb != null) {
			if (this.BuildRailShared(c, sa, sb)) return true;
			Log.Info("PLAN", "sharing an existing station did not work out; trying separate terminals");
		}
		local plan = c.best.plan;
		local L = this.PlatformLength();
		local rt = plan.railtype;
		AIRail.SetCurrentRailType(rt);
		local la = AITown.GetLocation(c.a), lb = AITown.GetLocation(c.b);
		local site_a = ::MT.rail.FindSite(c.a, lb, L, rt, this.JoinId(c.a), null);
		if (site_a == null) {
			Log.Warn("PLAN", "no rail station site in " + Util.TownName(c.a));
			this.UnlockSharing(c.a);
			return false;
		}
		local reserved = {};
		foreach (t in ::MT.rail.Footprint(site_a)) reserved[t] <- true;
		local site_b = ::MT.rail.FindSite(c.b, site_a.O, L, rt, this.JoinId(c.b), reserved);
		if (site_b == null) {
			Log.Warn("PLAN", "no rail station site in " + Util.TownName(c.b));
			this.UnlockSharing(c.b);
			return false;
		}
		if (!::MT.finance.Ensure(c.first_cost.tointeger())) return false;
		if (!::MT.rail.BuildStation(site_a, this.JoinId(c.a))) { this.Demolish(::MT.rail.Footprint(site_a)); return false; }
		if (!::MT.rail.BuildStation(site_b, this.JoinId(c.b))) {
			this.Demolish(::MT.rail.Footprint(site_a));
			this.Demolish(::MT.rail.Footprint(site_b));
			return false;
		}
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::MT.network.ReservedRail()) forbidden[t] <- true;
		delete forbidden[::MT.rail.T(site_a, 0, -4)];
		delete forbidden[::MT.rail.T(site_b, 1, -4)];
		if (::MT.rail.T(site_a, 0, -5) in forbidden) delete forbidden[::MT.rail.T(site_a, 0, -5)];
		if (::MT.rail.T(site_b, 1, -5) in forbidden) delete forbidden[::MT.rail.T(site_b, 1, -5)];
		/* keep the way out of B and into A free for the second track */
		foreach (t in ::MT.rail.OtherCorridor(site_a, 1)) forbidden[t] <- true;
		foreach (t in ::MT.rail.OtherCorridor(site_b, 0)) forbidden[t] <- true;
		local p1 = ::MT.rail.BuildTrack(site_a, site_b, forbidden, null, rt);
		if (p1 == null || ::MT.rail.Verify(p1) >= 0) {
			Log.Warn("PLAN", "no railway " + Util.TownName(c.a) + " - " + Util.TownName(c.b));
			if (::MT.rail.trapped) ::MT.rail.bad_sites[site_a.O] <- Util.Today();
			if (p1 != null) ::MT.rail.RemovePath(p1, p1.len() - 1);
			this.Demolish(::MT.rail.Footprint(site_a));
			this.Demolish(::MT.rail.Footprint(site_b));
			return false;
		}
		local line = Line();
		line.mode = MODE_RAIL;
		line.towns = [c.a, c.b];
		line.sids = [site_a.sid, site_b.sid];
		line.tiles = [::MT.rail.T(site_a, 0, 0), ::MT.rail.T(site_b, 0, 0)];
		line.depots = [site_a.depot, site_b.depot];
		line.engine = plan.loco;
		line.wagon = plan.wagon == null ? -1 : plan.wagon;
		line.wagons = plan.wagons;
		line.railtype = rt;
		line.sites = [site_a, site_b];
		line.p1 = this.Encode(p1);
		line.track_tiles = ::MT.rail.PathTiles(p1);
		line.capacity = plan.capacity;
		line.speed = plan.speed;
		line.dist = AIMap.DistanceManhattan(line.tiles[0], line.tiles[1]);
		line.path_len = this.PathLength(p1) + 2 * L;
		line.est_rtt = ::MT.time.RoundTrip(MODE_RAIL, line.speed, line.path_len, line.capacity);
		::MT.network.Add(line);
		this.RegisterStation(c.a, site_a.sid, MODE_RAIL);
		this.RegisterStation(c.b, site_b.sid, MODE_RAIL);
		local v = ::MT.fleet.BuildFor(line, 0);
		Log.Info("BUILD", line.Name() + " opened: " + p1.len() + " track tiles, " + AIRail.GetName(rt) + ", " +
			AIEngine.GetName(plan.loco) + (plan.wagons > 0 ? " + " + plan.wagons + " x " + AIEngine.GetName(plan.wagon) : "") +
			", " + plan.capacity + " seats, " + plan.speed + " km/h, one train (single track, no signals needed)" +
			(v < 0 ? " - first train failed" : ""));
		if (v < 0) ::MT.fleet.Repick(line);
		return true;
	}

	/*
	 * Rail line that shares the station of an existing doubled line at one or both ends. The new line is
	 * doubled and signalled before its first train runs, because the shared tracks are one-way.
	 */
	function BuildRailShared(c, sa, sb) {
		local base = sa != null ? sa.line : sb.line;
		local rt = base.railtype;
		if (sa != null && sb != null && sa.line.railtype != sb.line.railtype) return false;
		local L = sa != null ? sa.site.L : sb.site.L;
		if (sa != null && sb != null) L = min(sa.site.L, sb.site.L);
		local tiles = c.dist * 1.2;
		local best = ::MT.engines.BestTrain(L, tiles, c.dist, c.demand, rt);
		if (best == null) return false;
		local la = AITown.GetLocation(c.a), lb = AITown.GetLocation(c.b);
		local site_a = sa != null ? sa.site : null, site_b = sb != null ? sb.site : null;
		local reserved = {};
		if (site_a == null) {
			site_a = ::MT.rail.FindSite(c.a, site_b != null ? site_b.O : lb, L, rt, this.JoinId(c.a), null);
			if (site_a == null) return false;
		}
		foreach (t in ::MT.rail.Footprint(site_a)) reserved[t] <- true;
		if (site_b == null) {
			site_b = ::MT.rail.FindSite(c.b, site_a.O, L, rt, this.JoinId(c.b), reserved);
			if (site_b == null) return false;
		}
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::MT.network.ReservedRail()) forbidden[t] <- true;
		/* junction specs first: they must exist before anything is built */
		local start1 = null, goal1 = null, start2 = null, goal2 = null;
		if (sa != null) {
			local pa = ::MT.rail.StationPaths(sa.line, sa.end);
			start1 = ::MT.rail.BranchPoint(pa.dep, forbidden);
			goal2 = ::MT.rail.MergePoint(pa.arr, forbidden);
			if (start1 == null || goal2 == null) { Log.Info("PLAN", "no junction site on " + sa.line.Name()); return false; }
		}
		if (sb != null) {
			local pb = ::MT.rail.StationPaths(sb.line, sb.end);
			start2 = ::MT.rail.BranchPoint(pb.dep, forbidden);
			goal1 = ::MT.rail.MergePoint(pb.arr, forbidden);
			if (start2 == null || goal1 == null) { Log.Info("PLAN", "no junction site on " + sb.line.Name()); return false; }
		}
		local cost = AIRail.GetBuildCost(rt, AIRail.BT_TRACK) * tiles * 2.6 + best.plan.price * 2 + 30000;
		if (!::MT.finance.Ensure(cost.tointeger())) return false;
		local new_a = sa == null, new_b = sb == null;
		if (new_a && !::MT.rail.BuildStation(site_a, this.JoinId(c.a))) { this.Demolish(::MT.rail.Footprint(site_a)); return false; }
		if (new_b && !::MT.rail.BuildStation(site_b, this.JoinId(c.b))) {
			if (new_a) this.Demolish(::MT.rail.Footprint(site_a));
			this.Demolish(::MT.rail.Footprint(site_b));
			return false;
		}
		if (start1 == null) start1 = ::MT.rail.TerminusStart(site_a);
		if (goal1 == null) goal1 = ::MT.rail.TerminusGoal(site_b);
		if (start2 == null) start2 = ::MT.rail.TerminusStart(site_b);
		if (goal2 == null) goal2 = ::MT.rail.TerminusGoal(site_a);
		/* the throat tiles next to a terminus stay free for the line's own tracks */
		foreach (t in [start1.tile, goal1.tile, start2.tile, goal2.tile]) if (t in forbidden) delete forbidden[t];
		foreach (pair in [[new_a, site_a], [new_b, site_b]]) {
			if (!pair[0]) continue;
			foreach (row in [0, 1]) foreach (k in [-4, -5]) {
				local t = ::MT.rail.T(pair[1], row, k);
				if (t in forbidden) delete forbidden[t];
			}
		}
		local f1 = {};
		foreach (t, v in forbidden) f1[t] <- v;
		if (new_a) foreach (t in ::MT.rail.OtherCorridor(site_a, 1)) f1[t] <- true;
		if (new_b) foreach (t in ::MT.rail.OtherCorridor(site_b, 0)) f1[t] <- true;
		if (start2.sw != null) f1[start2.tile] <- true;
		if (goal2.merge != null) f1[goal2.merge[0]] <- true;
		local p1 = ::MT.rail.BuildTrackSpec(start1, goal1, f1, null, rt);
		local fail = p1 == null || ::MT.rail.Verify(p1) >= 0;
		local p2 = null;
		if (!fail) {
			local f2 = {};
			foreach (t, v in forbidden) f2[t] <- v;
			local prefer = {};
			foreach (t in ::MT.rail.PathTiles(p1)) {
				f2[t] <- true;
				for (local d = 0; d < 4; d++) prefer[t + Geo.Offset(d)] <- true;
			}
			p2 = ::MT.rail.BuildTrackSpec(start2, goal2, f2, prefer, rt);
			fail = p2 == null || ::MT.rail.Verify(p2) >= 0;
		}
		if (fail) {
			Log.Warn("PLAN", "no railway " + Util.TownName(c.a) + " - " + Util.TownName(c.b) + " through the shared station");
			if (::MT.rail.trapped) {
				if (new_a) ::MT.rail.bad_sites[site_a.O] <- Util.Today();
				if (new_b) ::MT.rail.bad_sites[site_b.O] <- Util.Today();
			}
			foreach (p in [p1, p2]) {
				if (p == null) continue;
				::MT.rail.RemovePath(p, p.len() - 1);
				/* take the junction pieces off the existing tracks again */
				if (p.len() > 1 && p[0].tile != start1.tile && p[0].tile != start2.tile) AIRail.RemoveRail(p[0].tile, p[0].tile, p[1].tile);
			}
			if (start1.sw != null) AIRail.RemoveRail(start1.sw[0], start1.sw[1], start1.sw[2]);
			if (start2.sw != null) AIRail.RemoveRail(start2.sw[0], start2.sw[1], start2.sw[2]);
			if (goal1.merge != null) AIRail.RemoveRail(goal1.merge[0], goal1.merge[1], goal1.merge[2]);
			if (goal2.merge != null) AIRail.RemoveRail(goal2.merge[0], goal2.merge[1], goal2.merge[2]);
			if (new_a) this.Demolish(::MT.rail.Footprint(site_a));
			if (new_b) this.Demolish(::MT.rail.Footprint(site_b));
			return false;
		}
		/* signals before any train: the new tracks are one-way like the shared ones */
		local n1 = ::MT.rail.SignalPath(p1, rt), n2 = ::MT.rail.SignalPath(p2, rt);
		if (new_a) ::MT.rail.BuildThroatSignals(site_a);
		if (new_b) ::MT.rail.BuildThroatSignals(site_b);
		local line = Line();
		line.mode = MODE_RAIL;
		line.branch = true;
		line.towns = [c.a, c.b];
		line.sids = [site_a.sid, site_b.sid];
		line.tiles = [::MT.rail.T(site_a, 0, 0), ::MT.rail.T(site_b, 0, 0)];
		line.depots = [site_a.depot, site_b.depot];
		line.engine = best.plan.loco;
		line.wagon = best.plan.wagon == null ? -1 : best.plan.wagon;
		line.wagons = best.plan.wagons;
		line.railtype = rt;
		line.sites = [site_a, site_b];
		line.p1 = this.Encode(p1);
		line.p2 = this.Encode(p2);
		line.double_track = true;
		line.signal_blocks = min(n1, n2);
		line.track_tiles = ::MT.rail.PathTiles(p1);
		line.track_tiles.extend(::MT.rail.PathTiles(p2));
		line.capacity = best.plan.capacity;
		line.speed = best.plan.speed;
		line.dist = AIMap.DistanceManhattan(line.tiles[0], line.tiles[1]);
		line.path_len = this.PathLength(p1) + 2 * L;
		line.est_rtt = ::MT.time.RoundTrip(MODE_RAIL, line.speed, line.path_len, line.capacity);
		::MT.network.Add(line);
		if (new_a) this.RegisterStation(c.a, site_a.sid, MODE_RAIL);
		if (new_b) this.RegisterStation(c.b, site_b.sid, MODE_RAIL);
		::MT.fleet.BuildFor(line, 0);
		::MT.fleet.BuildFor(line, 1);
		Log.Info("BUILD", line.Name() + " opened sharing " + (sa != null ? AIStation.GetName(site_a.sid) : "") +
			(sa != null && sb != null ? " and " : "") + (sb != null ? AIStation.GetName(site_b.sid) : "") + ": " + p1.len() + " + " + p2.len() +
			" track tiles with " + n1 + " + " + n2 + " one-way path signals, " + AIEngine.GetName(best.plan.loco) + ", " +
			best.plan.capacity + " seats; passengers can change trains there");
		return true;
	}

	function Footprints(site_a, site_b) {
		local t = {};
		foreach (x in ::MT.rail.Footprint(site_a)) t[x] <- true;
		foreach (x in ::MT.rail.Footprint(site_b)) t[x] <- true;
		return t;
	}

	/*
	 * Remove what we built on these tiles. Rail station tiles are removed one by one: demolishing a single
	 * platform tile removes every platform of that station (station_cmd.cpp RemoveRailStation), and a new
	 * terminal is usually joined to the town's hub station, which holds the platforms of other lines.
	 */
	function Demolish(tiles) {
		local me = AICompany.ResolveCompanyID(AICompany.COMPANY_SELF);
		foreach (t in tiles) {
			if (AITile.GetOwner(t) != me) continue;
			if (AIRail.IsRailStationTile(t)) AIRail.RemoveRailStationTileRectangle(t, t, false);
			else AITile.DemolishTile(t);
		}
	}

	function Encode(path) {
		local out = [];
		foreach (p in path) out.append(p.tile * 4 + p.kind);
		return out;
	}

	function Decode(enc) {
		local out = [];
		foreach (e in enc) out.append({tile = e / 4, kind = e % 4});
		return out;
	}

	/* Straight-tile equivalents along a path (diagonal pieces count 2/3). */
	function PathLength(path) {
		local len = 0.0;
		for (local i = 1; i < path.len(); i++) {
			local a = path[i - 1].tile, b = path[i].tile;
			local dist = AIMap.DistanceManhattan(a, b);
			if (dist > 1) { len += dist; continue; }
			if (i + 1 < path.len() && Geo.DirOf(a, b) != Geo.DirOf(b, path[i + 1].tile) && path[i + 1].kind == PF_KIND_NORMAL) len += 2.0 / 3.0;
			else len += 1.0;
		}
		return len;
	}

	function UpgradeCost(line) {
		local rt = line.railtype;
		return AIRail.GetBuildCost(rt, AIRail.BT_TRACK) * line.p1.len() * 1.3 + AIRail.GetBuildCost(rt, AIRail.BT_SIGNAL) * line.p1.len() / 3 +
			AIEngine.GetPrice(line.engine);
	}

	/*
	 * Second track and one-way path signals. Trains are parked in their depots while the signals go up, so no
	 * train is ever on a track whose signalling changes under it.
	 */
	function UpgradeRail(line) {
		local site_a = line.sites[0], site_b = line.sites[1];
		local rt = line.railtype;
		local p1 = this.Decode(line.p1);
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::MT.network.ReservedRail()) forbidden[t] <- true;
		foreach (t in [::MT.rail.T(site_b, 0, -4), ::MT.rail.T(site_a, 1, -4), ::MT.rail.T(site_b, 0, -5), ::MT.rail.T(site_a, 1, -5)]) {
			if (t in forbidden) delete forbidden[t];
		}
		local prefer = {};
		foreach (t in ::MT.rail.PathTiles(p1)) {
			forbidden[t] <- true;
			for (local d = 0; d < 4; d++) prefer[t + Geo.Offset(d)] <- true;
		}
		if (!::MT.finance.Ensure(this.UpgradeCost(line).tointeger())) return false;
		Log.Info("PLAN", line.Name() + ": laying the second track");
		local p2 = ::MT.rail.BuildTrack(site_b, site_a, forbidden, prefer, rt);
		if (p2 == null || ::MT.rail.Verify(p2) >= 0) {
			Log.Warn("PLAN", line.Name() + ": no route for a second track; stays a single-train line for now");
			if (p2 != null) ::MT.rail.RemovePath(p2, p2.len() - 1);
			line.note = "";
			line.upgrade_failed = Util.Today();
			return false;
		}
		line.track_tiles.extend(::MT.rail.PathTiles(p2));
		line.p2 = this.Encode(p2);
		return this.InstallSignals(line, p2);
	}

	/* Phase two of a doubling: park the trains, signal both tracks, restart. */
	function InstallSignals(line, p2) {
		local site_a = line.sites[0], site_b = line.sites[1];
		local rt = line.railtype;
		local p1 = this.Decode(line.p1);
		if (!this.ParkTrains(line)) {
			/* The second track is laid but unsignalled: the line keeps one train until the next try. */
			Log.Warn("SAFETY", line.Name() + ": trains did not reach the depot; signals postponed");
			this.RestartTrains(line);
			line.note = "signals";
			return false;
		}
		local n1 = ::MT.rail.SignalPath(p1, rt), n2 = ::MT.rail.SignalPath(p2, rt);
		::MT.rail.BuildThroatSignals(site_a);
		::MT.rail.BuildThroatSignals(site_b);
		line.double_track = true;
		line.signal_blocks = min(n1, n2);
		line.note = "";
		this.RestartTrains(line);
		Log.Info("BUILD", line.Name() + ": double track with " + n1 + " + " + n2 + " one-way path signals; up to " +
			::MT.fleet.MaxVehicles(line) + " trains");
		::MT.fleet.BuildFor(line, 1);
		return true;
	}

	function ParkTrains(line) {
		foreach (v, _ in line.Vehicles()) {
			if (!AIVehicle.IsStoppedInDepot(v) && !AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);
		}
		for (local i = 0; i < 90; i++) {
			local all = true;
			foreach (v, _ in line.Vehicles()) if (!AIVehicle.IsStoppedInDepot(v)) { all = false; break; }
			if (all) return true;
			AIController.Sleep(DAY_TICKS);
		}
		return false;
	}

	function RestartTrains(line) {
		foreach (v, _ in line.Vehicles()) {
			if (v in ::MT.fleet.to_sell) continue;
			if (AIVehicle.IsStoppedInDepot(v)) AIVehicle.StartStopVehicle(v);
			else if (AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);   // cancels the depot order
		}
	}

	/* Re-verify both tracks of a line piece by piece (after a lost train) and report breaks. */
	function CheckTracks(line) {
		if (line.last_check > 0 && Util.Today() - line.last_check < 30) return;
		line.last_check = Util.Today();
		foreach (name, enc in {p1 = line.p1, p2 = line.p2}) {
			if (enc.len() == 0) continue;
			local p = this.Decode(enc);
			local bad = ::MT.rail.Verify(p);
			if (bad >= 0) {
				Log.Error("FLEET", line.Name() + ": track " + name + " broken at " + Util.TileStr(p[bad].tile) + " (index " + bad + " of " + p.len() +
					", tracks " + AIRail.GetRailTracks(p[bad].tile) + ", rail " + AIRail.IsRailTile(p[bad].tile) + ", owner " + AITile.GetOwner(p[bad].tile) + ")");
			}
		}
		foreach (i, site in line.sites) {
			if (site == null) continue;
			if (!AIRail.IsRailDepotTile(site.depot)) Log.Error("FLEET", line.Name() + ": depot " + Util.TileStr(site.depot) + " is gone");
		}
	}

	/* A town built a road across our track. Remove the road piece on the crossing if the town allows it. */
	function FixCrossings(line) {
		foreach (t in line.track_tiles) {
			if (!AIRail.IsLevelCrossingTile(t)) continue;
			local done = false;
			foreach (d in [DIR_PX, DIR_PY]) {
				local a = t - Geo.Offset(d), b = t + Geo.Offset(d);
				if (AIRoad.AreRoadTilesConnected(t, a) || AIRoad.AreRoadTilesConnected(t, b)) {
					done = AIRoad.RemoveRoad(a, b);
					break;
				}
			}
			Log.Warn("SAFETY", line.Name() + ": level crossing at " + Util.TileStr(t) + (done ? " removed" :
				" could not be removed (" + AIError.GetLastErrorString() + "); consider disallowing town level crossings"));
		}
	}

	/* ---------------- interchanges ---------------- */

	function Interchanges() {
		if (!::MT.game.allow[MODE_ROAD]) return false;
		foreach (town, hub in ::MT.network.hubs) {
			if (AIStation.IsValidStation(hub.air_sid) && AIStation.IsValidStation(hub.sid) && hub.air_sid != hub.sid && !hub.shuttle) {
				hub.shuttle = true;
				if (this.BuildShuttle(town, hub.sid, hub.air_sid)) return true;
			}
			if (AIStation.IsValidStation(hub.sid) && hub.catchment < 2 && AITown.GetPopulation(town) > 700 &&
					(hub.rail > 0 || hub.sid == hub.air_sid)) {
				local loc = AIStation.GetLocation(hub.sid);
				local spot = ::MT.road.FindStop(AITown.GetLocation(town), 6, hub.sid, null, loc, 5);
				if (spot != null && ::MT.road.BuildStop(spot, hub.sid) >= 0) {
					hub.catchment++;
					Log.Info("BUILD", "walk-in stop for " + AIStation.GetName(hub.sid) + " at " + Util.TileStr(spot.tile) +
						" (extends the hub's catchment, no buses needed)");
					return true;
				}
				hub.catchment = 99;
			}
		}
		return false;
	}

	/* Bus shuttle between two stations of one town so CargoDist can route through both. */
	function BuildShuttle(town, sid1, sid2) {
		local s1 = ::MT.road.FindStop(AIStation.GetLocation(sid1), 6, sid1);
		local s2 = ::MT.road.FindStop(AIStation.GetLocation(sid2), 7, sid2);
		if (s1 == null || s2 == null) {
			Log.Info("PLAN", "no road stops to link " + AIStation.GetName(sid1) + " and " + AIStation.GetName(sid2));
			return false;
		}
		local best = ::MT.engines.BestBus(AIMap.DistanceManhattan(s1.tile, s2.tile) + 2, AIMap.DistanceManhattan(s1.tile, s2.tile), 100);
		if (best == null) return false;
		Log.Info("PLAN", "interchange shuttle " + AIStation.GetName(sid1) + " <-> " + AIStation.GetName(sid2));
		return this.BuildBusLine(town, town, s1, s2, sid1, sid2, best.engine, true);
	}
}
