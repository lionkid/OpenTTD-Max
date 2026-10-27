/*
 * EngineAdvisor: picks the vehicle model (and for trains the wagons and their number) for a route.
 *
 * Every buildable model that can carry the cargo is scored with Economy.Evaluate; the score is the yearly
 * profit minus 30% of the money the vehicles tie up (a pound spent on a vehicle could have opened another
 * route). Safety filters come first: aircraft class against both airports, aircraft range.
 */

const CAPITAL_RATE = 0.3;

class EngineAdvisor {
	length_cache = null;   // engine -> length in 1/16 tile, learned when a vehicle is built
	refit_cap = null;      // "engine:cargo" -> capacity after refit, learned when a vehicle is built
	bad_pairs = null;      // "loco:wagon" -> true when the wagon cannot be attached (NewGRF attach callback)
	probed = null;         // "loco:wagon" -> true once built together (wagon -1: the locomotive alone)
	series_cache = null;   // wagon -> true when it is a car of a multiple-unit series
	series_date = 0;

	list_cache = null;     // vehicle type -> buildable engines (refreshed monthly)
	plan_cache = null;     // "loco:len:cargo:railtype" -> train plan (same refresh)
	cache_date = -1000;

	constructor() {
		this.length_cache = {};
		this.refit_cap = {};
		this.bad_pairs = {};
		this.probed = {};
		this.series_cache = {};
		this.list_cache = {};
		this.plan_cache = {};
	}

	/*
	 * Buildable engines of a vehicle type. Planning evaluates hundreds of routes in one go; walking the full
	 * engine list (wagons included) for each of them cost most of the planner's time on big maps.
	 */
	function Engines(vt) {
		if (Util.Today() - this.cache_date > 30) {
			this.list_cache = {};
			this.plan_cache = {};
			this.cache_date = Util.Today();
		}
		if (vt in this.list_cache) return this.list_cache[vt];
		local out = [];
		foreach (e, _ in AIEngineList(vt)) if (AIEngine.IsBuildable(e)) out.append(e);
		this.list_cache[vt] <- out;
		return out;
	}

	function Carries(e, cargo) {
		return AIEngine.GetCargoType(e) == cargo || AIEngine.CanRefitCargo(e, cargo);
	}

	function Usable(e, cargo) {
		return AIEngine.IsValidEngine(e) && AIEngine.IsBuildable(e) && this.Carries(e, cargo);
	}

	/* Capacity for `cargo`: the model's own figure, or what a refitted vehicle of it held when we built one. */
	function Capacity(e, cargo) {
		local key = e + ":" + cargo;
		if (key in this.refit_cap) return this.refit_cap[key];
		return AIEngine.GetCapacity(e);
	}

	function LearnCapacity(v, cargo) {
		local e = AIVehicle.GetEngineType(v);
		local cap = AIVehicle.GetCapacity(v, cargo);
		if (cap > 0 && AIEngine.GetCargoType(e) != cargo) this.refit_cap[e + ":" + cargo] <- cap;
	}

	function Opts(e, cargo, speed, capacity, price, running, tiles, dist, supply, two_way, max_n = 0) {
		return {cargo = cargo, speed = speed, capacity = capacity, price = price, running = running, life_days = AIEngine.GetMaxAge(e),
			reliability = AIEngine.GetReliability(e), tiles = tiles, dist = dist, supply = supply, two_way = two_way, max_n = max_n};
	}

	capital_rate = CAPITAL_RATE;   // lower once money is plentiful (set monthly)

	function Score(ev) { return ev.profit - ev.capex * this.capital_rate; }

	/* Best of a list of {engine, eval} by score; ties within 5% go to the faster vehicle. */
	function Pick(cands) {
		local best = null;
		foreach (c in cands) {
			if (best == null) { best = c; continue; }
			local bv = this.Score(best.eval), cv = this.Score(c.eval);
			local margin = abs(bv) * 0.05;
			if (cv > bv + margin || (cv >= bv - margin && c.eval.one_way < best.eval.one_way)) best = c;
		}
		return best;
	}

	/* ---------------- road ---------------- */

	function BestRoad(cargo, tiles, dist, supply, two_way) {
		local cands = [];
		foreach (e in this.Engines(AIVehicle.VT_ROAD)) {
			if (!this.Usable(e, cargo)) continue;
			local rt = AIEngine.GetRoadType(e);
			if (rt != AIRoad.ROADTYPE_ROAD || AIRoad.GetRoadTramType(rt) != AIRoad.ROADTRAMTYPES_ROAD) continue;
			local cap = this.Capacity(e, cargo);
			if (cap <= 0) continue;
			local spd = AIEngine.GetMaxSpeed(e);
			local ev = ::MT.economy.Evaluate(MODE_ROAD, this.Opts(e, cargo, spd, cap, AIEngine.GetPrice(e),
				AIEngine.GetRunningCost(e), tiles, dist, supply, two_way, 15));
			cands.append({engine = e, eval = ev, capacity = cap, speed = spd});
		}
		return this.Pick(cands);
	}

	/* ---------------- water ---------------- */

	function BestShip(cargo, tiles, dist, supply, two_way) {
		local cands = [];
		foreach (e in this.Engines(AIVehicle.VT_WATER)) {
			if (!this.Usable(e, cargo)) continue;
			local cap = this.Capacity(e, cargo);
			if (cap <= 0) continue;
			local spd = AIEngine.GetMaxSpeed(e);
			local ev = ::MT.economy.Evaluate(MODE_WATER, this.Opts(e, cargo, spd, cap, AIEngine.GetPrice(e),
				AIEngine.GetRunningCost(e), tiles, dist, supply, two_way, 12));
			cands.append({engine = e, eval = ev, capacity = cap, speed = spd});
		}
		return this.Pick(cands);
	}

	/* ---------------- air ---------------- */

	/*
	 * Passenger aircraft on sale, best first by seats x speed per pound (monthly cache), with the figures the
	 * evaluation needs. Only the leading few that may use both airports and reach far enough are evaluated.
	 */
	function Planes() {
		this.Engines(AIVehicle.VT_AIR);
		if ("planes" in this.plan_cache) return this.plan_cache.planes;
		local out = [];
		foreach (e in this.Engines(AIVehicle.VT_AIR)) {
			if (!this.Usable(e, Util.pax) || AIEngine.GetPlaneType(e) == AIAirport.PT_HELICOPTER) continue;
			local cap = AIEngine.GetCapacity(e);
			if (cap <= 0) continue;
			out.append({e = e, pt = AIEngine.GetPlaneType(e), cap = cap, speed = AIEngine.GetMaxSpeed(e), price = AIEngine.GetPrice(e), running = AIEngine.GetRunningCost(e),
				range = AIEngine.GetMaximumOrderDistance(e), rank = cap * AIEngine.GetMaxSpeed(e) * 100 / max(1, AIEngine.GetPrice(e) / 100)});
		}
		out.sort(function(a, b) { return b.rank - a.rank; });
		this.plan_cache.planes <- out;
		return out;
	}

	function BestAircraft(tile_a, tile_b, type_a, type_b, supply) {
		local cands = [];
		local tiles = ::MT.economy.AirTiles(tile_a, tile_b);
		local dist = AIMap.DistanceManhattan(tile_a, tile_b);
		local order_dist = AIOrder.GetOrderDistance(AIVehicle.VT_AIR, tile_a, tile_b);
		local terminals = min(::MT.air.Terminals(type_a), ::MT.air.Terminals(type_b));
		local short_strip = ::MT.safety.IsShortStrip(type_a) || ::MT.safety.IsShortStrip(type_b);
		foreach (pl in this.Planes()) {
			if (cands.len() >= 5) break;
			if (short_strip && pl.pt == AIAirport.PT_BIG_PLANE) continue;   // never a large aircraft on a short strip
			if (pl.range > 0 && order_dist * 10 > pl.range * 9) continue;   // beyond its range (10% margin)
			local ev = ::MT.economy.Evaluate(MODE_AIR, this.Opts(pl.e, Util.pax, pl.speed, pl.cap, pl.price, pl.running, tiles, dist,
				supply, true, max(2, terminals * 2)));
			cands.append({engine = pl.e, eval = ev, capacity = pl.cap, speed = pl.speed});
		}
		return this.Pick(cands);
	}

	/* Could any buildable aircraft land at an airport of this type? */
	function AnyAircraftFor(type) {
		foreach (e in this.Engines(AIVehicle.VT_AIR)) {
			if (!this.Usable(e, Util.pax) || AIEngine.GetPlaneType(e) == AIAirport.PT_HELICOPTER) continue;
			if (::MT.safety.AirportOk(e, type)) return true;
		}
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
		foreach (e in this.Engines(AIVehicle.VT_RAIL)) {
			if (!AIEngine.IsWagon(e) && this.SameSeries(name, AIEngine.GetName(e))) { r = true; break; }
		}
		this.series_cache[w] <- r;
		return r;
	}

	/*
	 * Best wagon for `cargo` behind a locomotive on rail type rt. A multiple unit takes the cars of its own
	 * series; the cars of another series stay with their own head cars.
	 */
	function BestWagon(loco, rt, cargo) {
		local best = null, best_score = -1;
		local lname = AIEngine.GetName(loco);
		foreach (w in this.Engines(AIVehicle.VT_RAIL)) {
			if (!AIEngine.IsWagon(w) || !this.Usable(w, cargo)) continue;
			if (!AIEngine.CanRunOnRail(w, rt)) continue;
			if ((loco + ":" + w) in this.bad_pairs) continue;
			local cap = this.Capacity(w, cargo);
			if (cap <= 0) continue;
			local own = this.SameSeries(lname, AIEngine.GetName(w));
			if (!own && this.SeriesCar(w)) continue;
			local spd = AIEngine.GetMaxSpeed(w);
			local score = cap * 10 + (spd <= 0 ? 600 : min(spd, 600)) + (own ? 100000 : 0) + (AIEngine.GetCargoType(w) == cargo ? 50 : 0);
			if (score > best_score) { best_score = score; best = w; }
		}
		return best;
	}

	/* Length in 1/16 tile; an articulated multiple unit is taken as one 8/8 car per 84 seats until measured. */
	function LengthOf(e) {
		if (e in this.length_cache) return this.length_cache[e];
		if (AIEngine.IsArticulated(e) && this.Carries(e, Util.pax)) return max(8, (AIEngine.GetCapacity(e) + 83) / 84 * 8);
		return 8;
	}

	function PairKey(loco, wagon) { return loco + ":" + (wagon == null ? -1 : wagon); }

	function Measured(plan) {
		return (plan.loco in this.length_cache) && (plan.wagon == null || (this.PairKey(plan.loco, plan.wagon) in this.probed));
	}

	/*
	 * Build the locomotive and one wagon in `depot` to measure their lengths and to learn whether the wagon can
	 * be coupled, then sell both again on the spot (a vehicle sold the moment it is built returns its price).
	 */
	function Probe(loco, wagon, depot, cargo) {
		local key = this.PairKey(loco, wagon);
		if (key in this.probed) return;
		this.probed[key] <- true;
		if (!AIRail.IsRailDepotTile(depot) || !Util.IsMine(depot)) return;
		local price = AIEngine.GetPrice(loco) + (wagon != null ? AIEngine.GetPrice(wagon) : 0);
		if (!::MT.finance.Ensure(price)) return;
		local v = AIVehicle.BuildVehicle(depot, loco);
		if (!AIVehicle.IsValidVehicle(v)) return;
		this.length_cache[loco] <- AIVehicle.GetLength(v);
		if (wagon != null) {
			local w = AIEngine.GetCargoType(wagon) != cargo ? AIVehicle.BuildVehicleWithRefit(depot, wagon, cargo) : AIVehicle.BuildVehicle(depot, wagon);
			if (AIVehicle.IsValidVehicle(w)) {
				local before = AIVehicle.GetLength(v);
				this.LearnCapacity(w, cargo);
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
	 * Train plan for platforms of `plat_len` tiles on rail type rt (-1: the locomotive's own), carrying `cargo`:
	 * {loco, wagon, wagons, railtype, speed, capacity, price, running}. An articulated multiple unit is a complete
	 * formation; cars of the locomotive's own series are powered. Otherwise the train keeps about 3 hp per tonne
	 * loaded (4 for passengers) so it still reaches its speed on the slopes.
	 */
	function PlanTrain(loco, plat_len, cargo, rt = -1) {
		local key = loco + ":" + plat_len + ":" + cargo + ":" + rt + ":" + (loco in this.length_cache ? this.length_cache[loco] : 0);
		this.Engines(AIVehicle.VT_RAIL);   // refreshes the caches once a month
		local p;
		if (key in this.plan_cache) p = this.plan_cache[key];
		else {
			/* computed first: the monthly refresh inside may replace the cache table */
			p = this._PlanTrain(loco, plat_len, cargo, rt);
			this.plan_cache[key] <- p;
		}
		if (p == null) return null;
		local copy = {};
		foreach (k, v in p) copy[k] <- v;
		return copy;
	}

	function _PlanTrain(loco, plat_len, cargo, rt) {
		/* a multiple unit (an engine with seats of its own) is a passenger train: it does not haul coal or wood */
		if (cargo != Util.pax && AIEngine.GetCapacity(loco) > 0 && this.Carries(loco, Util.pax)) return null;
		if (rt < 0) rt = AIEngine.GetRailType(loco);
		if (!AIRail.IsRailTypeAvailable(rt)) return null;
		local self_cap = AIEngine.GetCargoType(loco) == cargo || AIEngine.CanRefitCargo(loco, cargo) ? max(0, this.Capacity(loco, cargo)) : 0;
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
				local hp_t = cargo == Util.pax ? 4 : 3;
				local power = max(1, AIEngine.GetPower(loco));
				local wl = AIEngine.GetWeight(loco);
				local ww = max(1, AIEngine.GetWeight(wagon) + AICargo.GetWeight(cargo, this.Capacity(wagon, cargo)));
				while (n > 0 && power < (wl + n * ww) * hp_t) n--;
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
			wagon_cap = n > 0 ? this.Capacity(wagon, cargo) : 0,
			price = AIEngine.GetPrice(loco) + (n > 0 ? n * AIEngine.GetPrice(wagon) : 0),
			running = AIEngine.GetRunningCost(loco) + (n > 0 ? n * AIEngine.GetRunningCost(wagon) : 0)};
	}

	/* Fewer wagons when the supply would never fill the full train within a round trip (freight on one track). */
	function TrimPlan(plan, cargo, supply, tiles) {
		if (plan.wagons <= 2 || plan.wagon_cap <= 0) return plan;
		local rtt = ::MT.economy.RoundTrip(MODE_RAIL, plan.speed, tiles, plan.capacity);
		local per_trip = supply * 1.3 * rtt / 30.0;
		local need = max(2, (per_trip / plan.wagon_cap + 0.999).tointeger());
		if (need >= plan.wagons) return plan;
		local cut = plan.wagons - need;
		plan.wagons = need;
		plan.capacity -= cut * plan.wagon_cap;
		plan.price -= cut * AIEngine.GetPrice(plan.wagon);
		plan.running -= cut * AIEngine.GetRunningCost(plan.wagon);
		return plan;
	}

	function TrainCand(e, plat_len, cargo, tiles, dist, supply, railtype, max_n, two_way) {
		if (AIEngine.IsWagon(e) || !AIEngine.IsBuildable(e)) return null;
		if (railtype >= 0 && !(AIEngine.CanRunOnRail(e, railtype) && AIEngine.HasPowerOnRail(e, railtype))) return null;
		local p = this.PlanTrain(e, plat_len, cargo, railtype);
		if (p == null) return null;
		if (!two_way && max_n == 1) p = this.TrimPlan(p, cargo, supply, tiles);
		local o = {cargo = cargo, speed = p.speed, capacity = p.capacity, price = p.price, running = p.running,
			life_days = AIEngine.GetMaxAge(e), reliability = AIEngine.GetReliability(e), tiles = tiles, dist = dist, supply = supply,
			two_way = two_way, max_n = max_n};
		local ev = ::MT.economy.Evaluate(MODE_RAIL, o);
		/* Faster rail types cost more per tile; charge the extra track over 15 years. */
		local track = AIRail.GetBuildCost(p.railtype, AIRail.BT_TRACK) * tiles * 2;
		ev.profit -= track / 15;
		return {engine = e, eval = ev, plan = p, capacity = p.capacity, speed = p.speed};
	}

	/*
	 * Best train for platforms of plat_len tiles. With a depot of ours, the leading plan is built there once
	 * before it is chosen (Probe), and the next one is tried when it turns out longer than the platforms or its
	 * wagon cannot be coupled, so the plan that is returned can really be built.
	 */
	/*
	 * Locomotives worth evaluating for a cargo: the eight with the most capacity x speed per pound of train
	 * (a monthly cache; the planner asks for hundreds of routes at a time).
	 */
	function Locos(plat_len, cargo, railtype) {
		this.Engines(AIVehicle.VT_RAIL);
		local key = "L:" + plat_len + ":" + cargo + ":" + railtype;
		if (key in this.plan_cache) return this.plan_cache[key];
		local ranked = [];
		foreach (e in this.Engines(AIVehicle.VT_RAIL)) {
			if (AIEngine.IsWagon(e)) continue;
			if (railtype >= 0 && !(AIEngine.CanRunOnRail(e, railtype) && AIEngine.HasPowerOnRail(e, railtype))) continue;
			local p = this.PlanTrain(e, plat_len, cargo, railtype);
			if (p == null) continue;
			ranked.append([p.capacity * p.speed * 1000 / max(1, p.price + p.running * 5), e]);
		}
		ranked.sort(function(a, b) { return b[0] - a[0]; });
		local out = [];
		foreach (r in ranked) { if (out.len() >= 8) break; out.append(r[1]); }
		this.plan_cache[key] <- out;
		return out;
	}

	function BestTrain(plat_len, cargo, tiles, dist, supply, two_way, railtype = -1, depot = -1, max_n = 0) {
		local cands = [];
		foreach (e in this.Locos(plat_len, cargo, railtype)) {
			local c = this.TrainCand(e, plat_len, cargo, tiles, dist, supply, railtype, max_n, two_way);
			if (c != null) cands.append(c);
		}
		if (depot < 0) return this.Pick(cands);
		for (local tries = 0; tries < 16; tries++) {
			local best = this.Pick(cands);
			if (best == null || this.Measured(best.plan)) return best;
			this.Probe(best.engine, best.plan.wagon, depot, cargo);
			local rest = [];
			foreach (c in cands) if (c.engine != best.engine) rest.append(c);
			local again = this.TrainCand(best.engine, plat_len, cargo, tiles, dist, supply, railtype, max_n, two_way);
			if (again != null) rest.append(again);
			cands = rest;
		}
		return this.Pick(cands);
	}
}
