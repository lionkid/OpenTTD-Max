/*
 * EngineAdvisor: picks the vehicle model for a route of any mode and cargo.
 *
 * Each candidate model is scored with TimeModel.Evaluate (payment, running cost, depreciation, and for
 * passengers the value of their time). Aircraft are first filtered by airport class (a large aircraft on a
 * short strip crashes on about one landing in five) and range. Trains are planned as a locomotive with the
 * best wagon for the cargo, or as a multiple unit with the cars of its own series; the plan is test-built in
 * a depot before it is chosen (lengths and NewGRF coupling rules are only known from a real vehicle).
 */

class EngineAdvisor {
	length_cache = null;   // engine -> length in 1/16 tile, learned when a vehicle is built
	bad_pairs = null;      // "loco:wagon" -> true when the wagon cannot be attached (NewGRF attach callback)
	probed = null;         // "loco:wagon" -> true once built together (wagon -1: the locomotive alone)
	series_cache = null;   // wagon -> true when it is a car of a multiple-unit series
	series_date = 0;
	cap_cache = null;      // "engine:cargo" -> capacity after refit (learned when a vehicle is built)
	plan_cache = null;     // "loco:L:cargo:rt" -> train plan (or false), valid for a while
	plan_date = -10000;
	quick = false;         // candidate generation: only the shortlisted engines of each class are evaluated
	short_cache = null;    // "mode:cargo:rt" -> [engine] shortlist
	short_date = -10000;

	constructor() {
		this.length_cache = {};
		this.bad_pairs = {};
		this.probed = {};
		this.series_cache = {};
		this.cap_cache = {};
		this.plan_cache = {};
		this.short_cache = {};
	}

	/*
	 * Shortlist of a vehicle class for a cargo: the best engines at a short, a medium and a long distance
	 * (two each), evaluated once a month. Candidate generation looks at hundreds of pairs, and evaluating every
	 * engine for each of them took longer than a month of script time; the shortlist costs a few hundred
	 * evaluations a month instead.
	 */
	function Shortlist(mode, cargo, rt) {
		if (Util.Today() - this.short_date > 30) { this.short_cache = {}; this.short_date = Util.Today(); }
		local key = mode + ":" + cargo + ":" + rt;
		if (key in this.short_cache) return this.short_cache[key];
		local was = this.quick;
		this.quick = false;
		local bands = {};
		foreach (d in [30, 90, 200]) {
			local tiles = d * 1.25;
			local picks = [];
			for (local k = 0; k < 2; k++) {
				local best = null;
				if (mode == MODE_ROAD) best = this.BestRoadVehicle(cargo, rt, tiles, d, 80, picks);
				else if (mode == MODE_WATER) best = this.BestShip(cargo, tiles, d, 80, picks);
				else if (mode == MODE_RAIL) best = this._BestTrain(cargo, ::TY.planner.PlatformLength(), tiles, d, 120, rt, -1, 1, picks);
				else best = this.BestAircraftAt(cargo, d, 80, picks);
				if (best == null) break;
				picks.append(best.engine);
			}
			bands[d] <- picks;
		}
		this.quick = was;
		this.short_cache[key] <- bands;
		return bands;
	}

	/* Engines to consider: in quick mode the shortlist of the distance band, otherwise every engine of the type. */
	function Pool(mode, cargo, rt, vt, dist = 90) {
		if (this.quick) {
			local bands = this.Shortlist(mode, cargo, rt);
			return bands[dist < 60 ? 30 : (dist < 150 ? 90 : 200)];
		}
		local out = [];
		foreach (e, _ in AIEngineList(vt)) out.append(e);
		return out;
	}

	/* Plans depend on the engines on sale and on what was measured: cleared every 60 days and after a probe. */
	function ForgetPlans() { this.plan_cache = {}; this.plan_date = Util.Today(); }

	function Carries(e, cargo) {
		return AIEngine.GetCargoType(e) == cargo || AIEngine.CanRefitCargo(e, cargo);
	}

	function Usable(e, cargo) {
		return AIEngine.IsValidEngine(e) && AIEngine.IsBuildable(e) && this.Carries(e, cargo);
	}

	/* Capacity for a cargo: the engine's own when it is its cargo, else what a refit gave last time (or the same). */
	function Capacity(e, cargo) {
		if (AIEngine.GetCargoType(e) == cargo) return AIEngine.GetCapacity(e);
		local k = e + ":" + cargo;
		if (k in this.cap_cache) return this.cap_cache[k];
		return AIEngine.GetCapacity(e);
	}

	function Opts(e, cargo, speed, capacity, price, running, tiles, dist, demand) {
		return {cargo = cargo, speed = speed, capacity = capacity, price = price, running = running, life_days = AIEngine.GetMaxAge(e),
			reliability = AIEngine.GetReliability(e), tiles = tiles, dist = dist, demand = demand};
	}

	/* Best of a list of [engine, evaluation] by value; ties within 5% go to the faster vehicle. */
	function Pick(cands) {
		local best = null;
		foreach (c in cands) {
			if (best == null) { best = c; continue; }
			local bv = best.eval.value, cv = c.eval.value;
			local margin = abs(bv) * 0.05;
			if (cv > bv + margin || (cv >= bv - margin && c.eval.one_way < best.eval.one_way)) best = c;
		}
		return best;
	}

	/* ---------------- road ---------------- */

	function RoadTypes() {
		local out = [];
		foreach (rt, _ in AIRoadTypeList(AIRoad.ROADTRAMTYPES_ROAD)) if (AIRoad.IsRoadTypeAvailable(rt)) out.append(rt);
		return out;
	}

	function TramTypes() {
		local out = [];
		foreach (rt, _ in AIRoadTypeList(AIRoad.ROADTRAMTYPES_TRAM)) if (AIRoad.IsRoadTypeAvailable(rt)) out.append(rt);
		return out;
	}

	/* Best road vehicle for a cargo on road type rt (a plain road or a tram type). */
	function BestRoadVehicle(cargo, rt, tiles, dist, demand, skip = null) {
		local cands = [];
		foreach (e in this.Pool(MODE_ROAD, cargo, rt, AIVehicle.VT_ROAD, dist)) {
			if (skip != null && Util.Contains(skip, e)) continue;
			if (!this.Usable(e, cargo)) continue;
			if (!AIEngine.CanRunOnRoad(e, rt) || !AIEngine.HasPowerOnRoad(e, rt)) continue;
			if (AIRoad.GetRoadTramType(AIEngine.GetRoadType(e)) != AIRoad.GetRoadTramType(rt)) continue;
			local cap = this.Capacity(e, cargo);
			if (cap <= 0) continue;
			local spd = AIEngine.GetMaxSpeed(e);
			local rs = AIRoad.GetMaxSpeed(rt);
			if (rs > 0) spd = min(spd, rs / 2);
			local ev = ::TY.time.Evaluate(MODE_ROAD, this.Opts(e, cargo, spd, cap, AIEngine.GetPrice(e),
				AIEngine.GetRunningCost(e), tiles, dist, demand));
			cands.append({engine = e, eval = ev, capacity = cap, speed = spd});
		}
		return this.Pick(cands);
	}

	function BestBus(tiles, dist, demand) { return this.BestRoadVehicle(Util.pax, AIRoad.ROADTYPE_ROAD, tiles, dist, demand); }

	/* Is there any road vehicle at all for this cargo on plain roads? */
	function AnyTruck(cargo) {
		foreach (e, _ in AIEngineList(AIVehicle.VT_ROAD)) {
			if (!this.Usable(e, cargo)) continue;
			if (AIRoad.GetRoadTramType(AIEngine.GetRoadType(e)) != AIRoad.ROADTRAMTYPES_ROAD) continue;
			if (this.Capacity(e, cargo) > 0) return true;
		}
		return false;
	}

	/* ---------------- air ---------------- */

	function BestAircraft(cargo, tile_a, tile_b, type_a, type_b, demand) {
		local cands = [];
		local tiles = ::TY.time.AirTiles(tile_a, tile_b);
		local dist = AIMap.DistanceManhattan(tile_a, tile_b);
		foreach (e in this.Pool(MODE_AIR, cargo, 0, AIVehicle.VT_AIR, dist)) {
			if (!this.Usable(e, cargo)) continue;
			if (AIEngine.GetPlaneType(e) == AIAirport.PT_HELICOPTER) continue;
			if (!::TY.safety.CanUseAirports(e, type_a, type_b)) continue;
			if (!::TY.safety.InRange(e, tile_a, tile_b)) continue;
			local cap = this.Capacity(e, cargo);
			if (cap <= 0) continue;
			local ev = ::TY.time.Evaluate(MODE_AIR, this.Opts(e, cargo, AIEngine.GetMaxSpeed(e), cap, AIEngine.GetPrice(e),
				AIEngine.GetRunningCost(e), tiles, dist, demand));
			cands.append({engine = e, eval = ev, capacity = cap, speed = AIEngine.GetMaxSpeed(e)});
		}
		return this.Pick(cands);
	}

	/* Best aircraft for a distance regardless of airports (the shortlist). */
	function BestAircraftAt(cargo, dist, demand, skip = null) {
		local cands = [];
		foreach (e, _ in AIEngineList(AIVehicle.VT_AIR)) {
			if (skip != null && Util.Contains(skip, e)) continue;
			if (!this.Usable(e, cargo) || AIEngine.GetPlaneType(e) == AIAirport.PT_HELICOPTER) continue;
			local cap = this.Capacity(e, cargo);
			if (cap <= 0) continue;
			local ev = ::TY.time.Evaluate(MODE_AIR, this.Opts(e, cargo, AIEngine.GetMaxSpeed(e), cap, AIEngine.GetPrice(e),
				AIEngine.GetRunningCost(e), dist * 1.1, dist, demand));
			cands.append({engine = e, eval = ev, capacity = cap, speed = AIEngine.GetMaxSpeed(e)});
		}
		return this.Pick(cands);
	}

	/* Could any buildable aircraft fly between airports of these types? (for airport type choice) */
	function AnyAircraftFor(type) {
		foreach (e, _ in AIEngineList(AIVehicle.VT_AIR)) {
			if (!this.Usable(e, Util.pax) || AIEngine.GetPlaneType(e) == AIAirport.PT_HELICOPTER) continue;
			if (::TY.safety.LandingRisk(e, type) >= 0) return true;
		}
		return false;
	}

	/* ---------------- water ---------------- */

	function BestShip(cargo, tiles, dist, demand, skip = null) {
		local cands = [];
		foreach (e in this.Pool(MODE_WATER, cargo, 0, AIVehicle.VT_WATER, dist)) {
			if (skip != null && Util.Contains(skip, e)) continue;
			if (!this.Usable(e, cargo)) continue;
			local cap = this.Capacity(e, cargo);
			if (cap <= 0) continue;
			local ev = ::TY.time.Evaluate(MODE_WATER, this.Opts(e, cargo, AIEngine.GetMaxSpeed(e), cap, AIEngine.GetPrice(e),
				AIEngine.GetRunningCost(e), tiles, dist, demand));
			cands.append({engine = e, eval = ev, capacity = cap, speed = AIEngine.GetMaxSpeed(e)});
		}
		return this.Pick(cands);
	}

	function AnyShip(cargo) {
		foreach (e, _ in AIEngineList(AIVehicle.VT_WATER)) if (this.Usable(e, cargo) && this.Capacity(e, cargo) > 0) return true;
		return false;
	}

	/* ---------------- rail ---------------- */

	function CommonPrefix(a, b) {
		local n = min(a.len(), b.len()), i = 0;
		while (i < n && a[i] == b[i]) i++;
		return i;
	}

	/*
	 * Two names belong to one series when they share at least six characters up to a word boundary, as the
	 * cars of a multiple unit are usually named ("N700 Series Shinkansen head cars" / "... intermediate car").
	 * Names without spaces (Chinese, Japanese) end the shared part at any non-ASCII character.
	 */
	function SameSeries(a, b) {
		if (a == null || b == null) return false;
		local p = this.CommonPrefix(a, b);
		if (p < 6) return false;
		if (p == a.len() || p == b.len()) return true;
		local c = a[p - 1] & 0xFF;
		return c == ' ' || c == '(' || c == '-' || c >= 0x80;
	}

	/* A wagon that carries the name of a locomotive series is a car of that multiple unit (cached for a year). */
	function SeriesCar(w) {
		if (Util.Today() - this.series_date > 365) { this.series_cache = {}; this.series_date = Util.Today(); }
		if (w in this.series_cache) return this.series_cache[w];
		local name = AIEngine.GetName(w), r = false;
		foreach (e, _ in AIEngineList(AIVehicle.VT_RAIL)) {
			if (!AIEngine.IsWagon(e) && this.SameSeries(name, AIEngine.GetName(e))) { r = true; break; }
		}
		this.series_cache[w] <- r;
		return r;
	}

	/*
	 * Best wagon for a cargo behind a locomotive on rail type rt. A multiple unit takes the cars of its own
	 * series; the cars of another series stay with their own head cars.
	 */
	function BestWagon(loco, rt, cargo) {
		local best = null, best_score = -1;
		local lname = AIEngine.GetName(loco);
		foreach (w, _ in AIEngineList(AIVehicle.VT_RAIL)) {
			if (!AIEngine.IsWagon(w) || !this.Usable(w, cargo)) continue;
			if (!AIEngine.CanRunOnRail(w, rt)) continue;
			if ((loco + ":" + w) in this.bad_pairs) continue;
			local cap = this.Capacity(w, cargo);
			if (cap <= 0) continue;
			local own = this.SameSeries(lname, AIEngine.GetName(w));
			if (!own && this.SeriesCar(w)) continue;
			local spd = AIEngine.GetMaxSpeed(w);
			local score = cap * 10 + (spd <= 0 ? 600 : min(spd, 600)) + (own ? 100000 : 0);
			if (score > best_score) { best_score = score; best = w; }
		}
		return best;
	}

	/*
	 * Length in 1/16 tile. Lengths are measured when a vehicle is built; until then an articulated multiple
	 * unit is taken as one 8/8 car per 84 units of capacity and anything else as one car.
	 */
	function LengthOf(e) {
		if (e in this.length_cache) return this.length_cache[e];
		if (AIEngine.IsArticulated(e) && AIEngine.GetCapacity(e) > 0) return max(8, (AIEngine.GetCapacity(e) + 83) / 84 * 8);
		return 8;
	}

	function PairKey(loco, wagon) { return loco + ":" + (wagon == null ? -1 : wagon); }

	function Measured(plan) {
		return (plan.loco in this.length_cache) && (plan.wagon == null || (this.PairKey(plan.loco, plan.wagon) in this.probed));
	}

	/*
	 * Build the locomotive and one wagon in `depot` to measure their lengths and to learn whether the wagon can
	 * be coupled and what it holds after a refit, then sell both again on the spot.
	 */
	function Probe(loco, wagon, depot, cargo) {
		local key = this.PairKey(loco, wagon);
		if (key in this.probed) return;
		this.probed[key] <- true;
		if (!AIRail.IsRailDepotTile(depot) || AITile.GetOwner(depot) != AICompany.ResolveCompanyID(AICompany.COMPANY_SELF)) return;
		local price = AIEngine.GetPrice(loco) + (wagon != null ? AIEngine.GetPrice(wagon) : 0);
		if (!::TY.finance.Ensure(price)) return;
		local v = AIVehicle.BuildVehicle(depot, loco);
		if (!AIVehicle.IsValidVehicle(v)) return;
		this.length_cache[loco] <- AIVehicle.GetLength(v);
		this.ForgetPlans();
		if (wagon != null) {
			local w = AIEngine.GetCargoType(wagon) != cargo && AIEngine.CanRefitCargo(wagon, cargo) ?
				AIVehicle.BuildVehicleWithRefit(depot, wagon, cargo) : AIVehicle.BuildVehicle(depot, wagon);
			if (AIVehicle.IsValidVehicle(w)) {
				this.cap_cache[wagon + ":" + cargo] <- AIVehicle.GetCapacity(w, cargo);
				local before = AIVehicle.GetLength(v);
				if (AIVehicle.MoveWagon(w, 0, v, 0)) {
					this.length_cache[wagon] <- AIVehicle.GetLength(v) - before;
				} else {
					Log.Info("TRAIN", AIEngine.GetName(wagon) + " cannot be coupled to " + AIEngine.GetName(loco) + ": " + AIError.GetLastErrorString());
					this.bad_pairs[loco + ":" + wagon] <- true;
					AIVehicle.SellVehicle(w);
				}
			}
		}
		AIVehicle.SellVehicle(v);
	}

	/*
	 * Train plan for a cargo on platforms of `plat_len` tiles on rail type `rt` (-1: the locomotive's own):
	 * {loco, wagon, wagons, railtype, speed, capacity, price, running}.
	 */
	function PlanTrain(loco, plat_len, cargo, rt = -1) {
		if (rt < 0) rt = AIEngine.GetRailType(loco);
		if (Util.Today() - this.plan_date > 60) this.ForgetPlans();
		local key = loco + ":" + plat_len + ":" + cargo + ":" + rt;
		if (key in this.plan_cache) { local c = this.plan_cache[key]; return c == false ? null : c; }
		local plan = this._PlanTrain(loco, plat_len, cargo, rt);
		this.plan_cache[key] <- plan == null ? false : plan;
		return plan;
	}

	function _PlanTrain(loco, plat_len, cargo, rt) {
		if (!AIRail.IsRailTypeAvailable(rt)) return null;
		local self_cap = this.Carries(loco, cargo) ? max(0, this.Capacity(loco, cargo)) : 0;
		local can_pull = AIEngine.CanPullCargo(loco, cargo);
		if (self_cap <= 0 && !can_pull) return null;
		local units = plat_len * 16;
		local llen = this.LengthOf(loco);
		if (llen > units) return null;
		local fixed = self_cap > 0 && AIEngine.IsArticulated(loco);
		local wagon = can_pull && !fixed ? this.BestWagon(loco, AIEngine.GetRailType(loco), cargo) : null;
		local n = 0;
		if (wagon != null) {
			n = (units - llen) / this.LengthOf(wagon);
			if (!this.SameSeries(AIEngine.GetName(loco), AIEngine.GetName(wagon))) {
				/* Keep at least about 4 hp per tonne so the train still reaches its speed on the slopes. */
				local power = max(1, AIEngine.GetPower(loco));
				local wl = AIEngine.GetWeight(loco);
				local ww = max(1, AIEngine.GetWeight(wagon) + AICargo.GetWeight(cargo, this.Capacity(wagon, cargo)));
				while (n > 0 && power < (wl + n * ww) * 4) n--;
			}
		}
		local speed = AIEngine.GetMaxSpeed(loco);
		if (n > 0) {
			local ws = AIEngine.GetMaxSpeed(wagon);
			if (ws > 0) speed = min(speed, ws);
		}
		local rs = AIRail.GetMaxSpeed(rt);
		if (rs > 0) speed = min(speed, rs);
		local cap = self_cap + (n > 0 ? n * this.Capacity(wagon, cargo) : 0);
		if (cap <= 0 || speed <= 0) return null;
		return {loco = loco, wagon = n > 0 ? wagon : null, wagons = n, railtype = rt, speed = speed, capacity = cap,
			price = AIEngine.GetPrice(loco) + (n > 0 ? n * AIEngine.GetPrice(wagon) : 0),
			running = AIEngine.GetRunningCost(loco) + (n > 0 ? n * AIEngine.GetRunningCost(wagon) : 0)};
	}

	function TrainCand(e, cargo, plat_len, tiles, dist, demand, railtype, max_n) {
		if (AIEngine.IsWagon(e) || !AIEngine.IsBuildable(e)) return null;
		if (railtype >= 0 && !(AIEngine.CanRunOnRail(e, railtype) && AIEngine.HasPowerOnRail(e, railtype))) return null;
		local p = this.PlanTrain(e, plat_len, cargo, railtype);
		if (p == null) return null;
		local o = {cargo = cargo, speed = p.speed, capacity = p.capacity, price = p.price, running = p.running,
			life_days = AIEngine.GetMaxAge(e), reliability = AIEngine.GetReliability(e), tiles = tiles, dist = dist, demand = demand,
			max_n = max_n};
		local ev = ::TY.time.Evaluate(MODE_RAIL, o);
		/* Infrastructure for faster rail types costs more per tile; charge the extra track over 15 years. */
		local track = AIRail.GetBuildCost(p.railtype, AIRail.BT_TRACK) * tiles * 2;
		ev.value -= track / 15;
		return {engine = e, eval = ev, plan = p, capacity = p.capacity, speed = p.speed};
	}

	/*
	 * Best train for a cargo on platforms of plat_len tiles. With a depot of ours, the leading plan is built
	 * there once before it is chosen (Probe). max_n limits the trains the line can run (1 on single track).
	 * A single-track line cannot add trains, so its train is chosen for 60% more than today's demand.
	 */
	function BestTrain(cargo, plat_len, tiles, dist, demand, railtype = -1, depot = -1, max_n = 0) {
		local best = this._BestTrain(cargo, plat_len, tiles, dist, max_n == 1 ? demand * 1.6 : demand, railtype, depot, max_n);
		if (best != null && max_n == 1) {
			local again = this.TrainCand(best.engine, cargo, plat_len, tiles, dist, demand, railtype, max_n);
			if (again != null) best = again;
		}
		return best;
	}

	function _BestTrain(cargo, plat_len, tiles, dist, demand, railtype, depot, max_n, skip = null) {
		local cands = [];
		foreach (e in this.Pool(MODE_RAIL, cargo, railtype, AIVehicle.VT_RAIL, dist)) {
			if (skip != null && Util.Contains(skip, e)) continue;
			local c = this.TrainCand(e, cargo, plat_len, tiles, dist, demand, railtype, max_n);
			if (c != null) cands.append(c);
		}
		if (depot < 0 || !::TY.levels.probe_engines) return this.Pick(cands);
		for (local tries = 0; tries < 16; tries++) {
			local best = this.Pick(cands);
			if (best == null || this.Measured(best.plan)) return best;
			this.Probe(best.engine, best.plan.wagon, depot, cargo);
			local rest = [];
			foreach (c in cands) if (c.engine != best.engine) rest.append(c);
			local again = this.TrainCand(best.engine, cargo, plat_len, tiles, dist, demand, railtype, max_n);
			if (again != null) rest.append(again);
			cands = rest;
		}
		return this.Pick(cands);
	}

	/* Any train plan at all for this cargo (for the candidate filters)? */
	function AnyTrain(cargo, plat_len) {
		foreach (e, _ in AIEngineList(AIVehicle.VT_RAIL)) {
			if (AIEngine.IsWagon(e) || !AIEngine.IsBuildable(e)) continue;
			if (this.PlanTrain(e, plat_len, cargo) != null) return true;
		}
		return false;
	}

	function DebugDump() {
		foreach (c in Util.cargos) {
			local road = this.AnyTruck(c), ship = this.AnyShip(c), train = this.AnyTrain(c, 5);
			Log.Info("DEBUG", "cargo " + Util.CargoName(c) + ": road " + road + ", rail " + train + ", ship " + ship +
				", freight " + AICargo.IsFreight(c) + ", town effect " + AICargo.GetTownEffect(c));
		}
		foreach (e, _ in AIEngineList(AIVehicle.VT_WATER)) {
			Log.Info("DEBUG", "ship " + AIEngine.GetName(e) + " cargo " + Util.CargoName(AIEngine.GetCargoType(e)) + " cap " + AIEngine.GetCapacity(e) +
				" speed " + AIEngine.GetMaxSpeed(e) + " price " + AIEngine.GetPrice(e) + " buildable " + AIEngine.IsBuildable(e));
		}
		foreach (rt in this.TramTypes()) Log.Info("DEBUG", "tram road type " + rt + " " + AIRoad.GetName(rt));
	}
}
