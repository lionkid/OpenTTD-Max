/*
 * EngineAdvisor: picks the vehicle model for a route.
 *
 * Order of the checks follows the AI's priorities: first everything unsafe is filtered out (aircraft class
 * against both airports, range), then each remaining model is scored with TimeModel.Evaluate, which counts
 * fares, running cost, depreciation and the value of the passengers' door-to-door time.
 */

class EngineAdvisor {
	length_cache = null;   // engine -> length in 1/16 tile, learned when a vehicle is built
	bad_pairs = null;      // "loco:wagon" -> true when the wagon cannot be attached (NewGRF attach callback)

	constructor() {
		this.length_cache = {};
		this.bad_pairs = {};
	}

	function CarriesPax(e) {
		return AIEngine.GetCargoType(e) == Util.pax || AIEngine.CanRefitCargo(e, Util.pax);
	}

	function Usable(e) {
		return AIEngine.IsValidEngine(e) && AIEngine.IsBuildable(e) && this.CarriesPax(e);
	}

	function Opts(e, speed, capacity, price, running, tiles, dist, demand) {
		return {speed = speed, capacity = capacity, price = price, running = running, life_days = AIEngine.GetMaxAge(e),
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

	function BestBus(tiles, dist, demand) {
		local cands = [];
		foreach (e, _ in AIEngineList(AIVehicle.VT_ROAD)) {
			if (!this.Usable(e)) continue;
			if (AIEngine.GetRoadType(e) != AIRoad.ROADTYPE_ROAD) continue;
			if (AIRoad.GetRoadTramType(AIEngine.GetRoadType(e)) != AIRoad.ROADTRAMTYPES_ROAD) continue;
			local cap = AIEngine.GetCapacity(e);
			if (cap <= 0) continue;
			local ev = ::MT.time.Evaluate(MODE_ROAD, this.Opts(e, AIEngine.GetMaxSpeed(e), cap, AIEngine.GetPrice(e),
				AIEngine.GetRunningCost(e), tiles, dist, demand));
			cands.append({engine = e, eval = ev, capacity = cap, speed = AIEngine.GetMaxSpeed(e)});
		}
		return this.Pick(cands);
	}

	/* ---------------- air ---------------- */

	function BestAircraft(tile_a, tile_b, type_a, type_b, demand) {
		local cands = [];
		local tiles = ::MT.time.AirTiles(tile_a, tile_b);
		local dist = AIMap.DistanceManhattan(tile_a, tile_b);
		foreach (e, _ in AIEngineList(AIVehicle.VT_AIR)) {
			if (!this.Usable(e)) continue;
			if (AIEngine.GetPlaneType(e) == AIAirport.PT_HELICOPTER) continue;
			if (!::MT.safety.CanUseAirports(e, type_a, type_b)) continue;
			if (!::MT.safety.InRange(e, tile_a, tile_b)) continue;
			local cap = AIEngine.GetCapacity(e);
			if (cap <= 0) continue;
			local ev = ::MT.time.Evaluate(MODE_AIR, this.Opts(e, AIEngine.GetMaxSpeed(e), cap, AIEngine.GetPrice(e),
				AIEngine.GetRunningCost(e), tiles, dist, demand));
			cands.append({engine = e, eval = ev, capacity = cap, speed = AIEngine.GetMaxSpeed(e)});
		}
		return this.Pick(cands);
	}

	/* Could any buildable aircraft fly between airports of these types? (for airport type choice) */
	function AnyAircraftFor(type) {
		foreach (e, _ in AIEngineList(AIVehicle.VT_AIR)) {
			if (!this.Usable(e) || AIEngine.GetPlaneType(e) == AIAirport.PT_HELICOPTER) continue;
			if (::MT.safety.LandingRisk(e, type) >= 0) return true;
		}
		return false;
	}

	/* Largest seat count among aircraft that may use an airport type. */
	function BestCapacityFor(type) {
		local best = 0;
		foreach (e, _ in AIEngineList(AIVehicle.VT_AIR)) {
			if (!this.Usable(e) || AIEngine.GetPlaneType(e) == AIAirport.PT_HELICOPTER) continue;
			if (::MT.safety.LandingRisk(e, type) < 0) continue;
			best = max(best, AIEngine.GetCapacity(e));
		}
		return best;
	}

	/* ---------------- rail ---------------- */

	function CommonPrefix(a, b) {
		local n = min(a.len(), b.len()), i = 0;
		while (i < n && a[i] == b[i]) i++;
		return i;
	}

	/* Best passenger wagon for a locomotive on rail type rt (prefers the loco's own series). */
	function BestWagon(loco, rt) {
		local best = null, best_score = -1;
		local lname = AIEngine.GetName(loco);
		foreach (w, _ in AIEngineList(AIVehicle.VT_RAIL)) {
			if (!AIEngine.IsWagon(w) || !this.Usable(w)) continue;
			if (!AIEngine.CanRunOnRail(w, rt)) continue;
			if ((loco + ":" + w) in this.bad_pairs) continue;
			local cap = AIEngine.GetCapacity(w);
			if (cap <= 0) continue;
			local spd = AIEngine.GetMaxSpeed(w);
			local score = cap * 10 + (spd <= 0 ? 600 : min(spd, 600)) + this.CommonPrefix(lname, AIEngine.GetName(w)) * 2000;
			if (score > best_score) { best_score = score; best = w; }
		}
		return best;
	}

	function LengthOf(e) { return (e in this.length_cache) ? this.length_cache[e] : 8; }

	/*
	 * Train plan for platforms of `plat_len` tiles: [loco, wagon, wagons, railtype, speed, capacity, price, running].
	 * Multiple units that carry passengers themselves run without extra wagons unless wagons of their series exist.
	 */
	function PlanTrain(loco, plat_len) {
		local rt = AIEngine.GetRailType(loco);
		if (!AIRail.IsRailTypeAvailable(rt)) return null;
		local self_cap = this.CarriesPax(loco) ? max(0, AIEngine.GetCapacity(loco)) : 0;
		local can_pull = AIEngine.CanPullCargo(loco, Util.pax);
		if (self_cap <= 0 && !can_pull) return null;
		local units = plat_len * 16;
		local llen = this.LengthOf(loco);
		if (llen > units) return null;
		local wagon = can_pull || self_cap > 0 ? this.BestWagon(loco, rt) : null;
		local n = 0;
		if (wagon != null) {
			n = (units - llen) / this.LengthOf(wagon);
			/* Keep at least about 4 hp per tonne so the train still reaches its speed on the slopes. */
			local power = max(1, AIEngine.GetPower(loco));
			local wl = AIEngine.GetWeight(loco), ww = max(1, AIEngine.GetWeight(wagon) + AIEngine.GetCapacity(wagon) / 16);
			while (n > 0 && power < (wl + n * ww) * 4) n--;
		}
		local speed = AIEngine.GetMaxSpeed(loco);
		if (n > 0) {
			local ws = AIEngine.GetMaxSpeed(wagon);
			if (ws > 0) speed = min(speed, ws);
		}
		local rs = AIRail.GetMaxSpeed(rt);
		if (rs > 0) speed = min(speed, rs);
		local cap = self_cap + (n > 0 ? n * AIEngine.GetCapacity(wagon) : 0);
		if (cap <= 0 || speed <= 0) return null;
		return {loco = loco, wagon = n > 0 ? wagon : null, wagons = n, railtype = rt, speed = speed, capacity = cap,
			price = AIEngine.GetPrice(loco) + (n > 0 ? n * AIEngine.GetPrice(wagon) : 0),
			running = AIEngine.GetRunningCost(loco) + (n > 0 ? n * AIEngine.GetRunningCost(wagon) : 0)};
	}

	function BestTrain(plat_len, tiles, dist, demand, railtype = -1) {
		local cands = [];
		foreach (e, _ in AIEngineList(AIVehicle.VT_RAIL)) {
			if (AIEngine.IsWagon(e) || !AIEngine.IsBuildable(e)) continue;
			if (railtype >= 0 && !(AIEngine.CanRunOnRail(e, railtype) && AIEngine.HasPowerOnRail(e, railtype))) continue;
			local p = this.PlanTrain(e, plat_len);
			if (p == null) continue;
			if (railtype >= 0) p.railtype = railtype;
			local o = {speed = p.speed, capacity = p.capacity, price = p.price, running = p.running,
				life_days = AIEngine.GetMaxAge(e), reliability = AIEngine.GetReliability(e), tiles = tiles, dist = dist, demand = demand};
			local ev = ::MT.time.Evaluate(MODE_RAIL, o);
			/* Infrastructure for faster rail types costs more per tile; charge the extra track over 15 years. */
			local track = AIRail.GetBuildCost(p.railtype, AIRail.BT_TRACK) * tiles * 2;
			ev.value -= track / 15;
			cands.append({engine = e, eval = ev, plan = p, capacity = p.capacity, speed = p.speed});
		}
		return this.Pick(cands);
	}
}
