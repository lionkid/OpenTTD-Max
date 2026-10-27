/*
 * Planner: decides what to build next, and closes what does not pay.
 *
 * Candidates are freight routes (an industry's cargo to an industry or town that accepts it) and passenger
 * routes (two towns), each evaluated for every mode in the distance band where that mode can pay:
 *   road 12-70 tiles, rail 30-220, air from 80 (passengers), water wherever both ends reach the same water.
 * Each candidate gets the yearly profit of its full fleet (Economy.Evaluate through the EngineAdvisor) and
 * the money it needs; the score is the return on that money, so cheap, quick routes come first while money is
 * short. Once there is more money than the projects can use, building time is what is scarce and each
 * project counts as costing at least a sixth of the money available, which ranks by absolute profit instead.
 * Towns and industries another company serves are never candidates (Neighbours); before a project starts,
 * both ends are checked again.
 */

class Planner {
	last_build = -10000;
	failures = null;      // candidate key -> date of the last failure
	refused = null;       // town -> date its local authority last refused us
	cands = null;
	cands_date = -10000;

	constructor() {
		this.failures = {};
		this.refused = {};
		this.cands = [];
	}

	/* Called after ERR_LOCAL_AUTHORITY_REFUSES: plant trees to win the town back, wait before retrying. */
	function OnRefused(town) {
		if (!AITown.IsValidTown(town)) return;
		this.refused[town] <- Util.Today();
		local planted = 0;
		local list = Geo.Square(AITown.GetLocation(town), 12);
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		foreach (t, _ in list) {
			if (planted >= 30) break;
			if (AITile.HasTreeOnTile(t) || AIRoad.IsRoadTile(t) || AITile.IsFarmTile(t) || !::MT.nb.TileFree(t)) continue;
			if (AITile.PlantTree(t)) planted++;
		}
		::MT.landscape.planted += planted;
		Log.Info("PLAN", Util.TownName(town) + " refused construction; planted " + planted + " trees to repair relations");
	}

	function Refused(town) { return (town in this.refused) && Util.Today() - this.refused[town] < 240; }

	function Cooldown() {
		local base = [45, 15, 4][Util.Clamp(AIController.GetSetting("expansion"), 0, 2)];
		if (::MT.finance.Available() > 2000000) return base / 3;
		if (::MT.finance.Available() > 600000) return base / 2;
		return base;
	}

	function PlatformLength() { return Util.Clamp(::MT.game.max_train_length, 3, 6); }

	function Failed(key) { return (key in this.failures) && Util.Today() - this.failures[key] < 730; }

	/*
	 * Ends where a mode found no site (no room for a station, an airport or a dock): every pair with that end
	 * is skipped for a year instead of being tried one by one.
	 */
	nosite = null;
	function SiteKey(mode, e) { return mode + ":" + e.type + ":" + e.id; }
	function MarkNoSite(mode, e) {
		if (this.nosite == null) this.nosite = {};
		this.nosite[this.SiteKey(mode, e)] <- Util.Today();
	}
	function NoSite(mode, e) {
		if (this.nosite == null) return false;
		local k = this.SiteKey(mode, e);
		return (k in this.nosite) && Util.Today() - this.nosite[k] < 365;
	}
	function Blocked(mode, a, b) { return this.NoSite(mode, a) || this.NoSite(mode, b); }
	/* an airport type that found no room in a town: the next plans for that town take the next smaller type */
	function MarkNoAirport(town, type) {
		if (this.nosite == null) this.nosite = {};
		this.nosite["airport:" + type + ":" + town] <- Util.Today();
	}
	function NoAirport(town, type) {
		if (this.nosite == null) return false;
		local k = "airport:" + type + ":" + town;
		return (k in this.nosite) && Util.Today() - this.nosite[k] < 365;
	}

	scale = 0;   // vehicle profit of the last year: a route must be worth a little of it
	plan_days = 0;   // game days the last candidate evaluation took (big maps: plan less often)

	function Step() {
		local today = Util.Today();
		if (today - this.last_build < this.Cooldown() || ::MT.finance.trouble) return;
		foreach (route in ::MT.routes.Active()) {
			if (route.mode != MODE_RAIL || route.double_track) continue;
			if (route.note == "signals") {
				this.last_build = today;
				::MT.projects.InstallSignals(route, ::MT.rail.Decode(route.p2));
				return;
			}
			if (route.note == "upgrade" && ::MT.finance.CanAfford(::MT.projects.UpgradeCost(route))) {
				this.last_build = today;
				::MT.projects.UpgradeRail(route);
				return;
			}
		}
		if (::MT.projects.Interchanges()) { this.last_build = today; return; }
		if (this.cands.len() == 0 || today - this.cands_date > max(30, 3 * this.plan_days)) {
			this.cands = this.Candidates();
			this.plan_days = Util.Today() - today;
			this.cands_date = Util.Today();
			if (AIController.GetSetting("debug") == 1) {
				local shown = {};
				foreach (i, c in this.cands) {
					local k = c.mode + (c.two_way ? "p" : "f");
					if (!(k in shown)) shown[k] <- 0;
					if (i >= 10 && shown[k] >= 3) continue;
					shown[k]++;
					Log.Info("DEBUG", "candidate " + (i + 1) + ": " + this.Describe(c) + " score " + (c.score * 100).tointeger() + "%");
				}
			}
		}
		local tried = 0, started = Util.Today();
		::MT.finance.idle = true;
		::MT.finance.next_need = 0;
		foreach (c in this.cands) {
			if (c.done || this.Failed(c.key)) continue;
			::MT.finance.idle = false;
			if (!::MT.finance.CanAfford(c.first_cost)) {
				if (::MT.finance.next_need == 0) ::MT.finance.next_need = c.first_cost.tointeger();
				continue;
			}
			if (!this.StillFree(c)) { c.done = true; continue; }
			if (++tried > 3 || Util.Today() - started > 45) break;
			Log.Info("PLAN", "building " + this.Describe(c));
			local ok = false, began = Util.Today();
			try {
				ok = ::MT.projects.Build(c);
			} catch (e) {
				Log.Error("PLAN", "construction error: " + e);
				ok = false;
			}
			this.LearnDays(c.mode, c.dist, Util.Today() - began);
			c.done = true;
			this.last_build = Util.Today();
			if (ok) {
				this.cands_date = min(this.cands_date, Util.Today() - 25);   // re-plan soon: the network changed
				return;
			}
			this.failures[c.key] <- Util.Today();
		}
		this.last_build = Util.Today();
	}

	/* Both ends still free of other companies (checked again right before building). */
	function StillFree(c) {
		foreach (e in [c.a, c.b]) {
			if (e.type == END_TOWN) {
				if (::MT.nb.TownTaken(e.id, true)) {
					::MT.nb.Skip("towns served by others", e.id);
					Log.Info("COURTESY", "skipping " + this.Describe(c) + ": " + Util.TownName(e.id) + " is served by " +
						::MT.nb.CompanyName(::MT.nb.town_claim[e.id].by));
					return false;
				}
			} else {
				if (!AIIndustry.IsValidIndustry(e.id)) return false;
				if (::MT.nb.IndustryTaken(e.id, true)) {
					::MT.nb.Skip("industries served by others", e.id);
					Log.Info("COURTESY", "skipping " + this.Describe(c) + ": " + Util.IndustryName(e.id) + " is served by " +
						::MT.nb.CompanyName(::MT.nb.ind_claim[e.id].by));
					return false;
				}
			}
		}
		return true;
	}

	function EndName(e) { return e.type == END_TOWN ? Util.TownName(e.id) : Util.IndustryName(e.id); }

	function Describe(c) {
		local what = c.two_way ? (["bus", "rail", "air", "ferry"][c.mode] + " passengers") :
			(["road", "rail", "air", "ship"][c.mode] + " " + Util.CargoName(c.cargo));
		return what + " " + this.EndName(c.a) + (c.two_way ? " - " : " > ") + this.EndName(c.b) + " (" + c.dist + " tiles, " +
			c.supply.tointeger() + "/month, " + AIEngine.GetName(c.engine) + ", profit " + Util.Money(c.profit.tointeger()) +
			"/year on " + Util.Money(c.full_cost.tointeger()) + ", first outlay " + Util.Money(c.first_cost.tointeger()) +
			(("days" in c) ? ", about " + c.days.tointeger() + " days to build" : "") + ")";
	}

	/* ---------------- candidates ---------------- */

	function Candidates() {
		local out = [];
		local ops = Util.OpsMark();
		if (::MT.game.pax_on) this.PaxCandidates(out);
		local pax_ops = Util.OpsSince(ops), pax_n = out.len();
		if (::MT.game.freight_on) this.FreightCandidates(out);
		Log.Debug("PLAN", "passenger candidates " + pax_n + " (" + pax_ops / 1000 + "k operations), freight " + (out.len() - pax_n) +
			" (" + (Util.OpsSince(ops) - pax_ops) / 1000 + "k)");
		/*
		 * Two things are scarce: money, and construction time (a railway's path search takes weeks of the AI's
		 * share of the game). A project's score is its yearly profit per unit of both: its cost as a share of
		 * the money available plus its building time as a share of half a year. While money is short, cheap
		 * projects win; once it is not, quick ones do.
		 */
		local money = fmax(50000.0, ::MT.finance.Available().tofloat());
		local min_profit = max(10000, this.scale / 60);
		/* every mode the game allows gets its first routes: a mode with fewer than two scores half as much again */
		local per_mode = [0, 0, 0, 0];
		foreach (r in ::MT.routes.Active()) per_mode[r.mode]++;
		local keep = [];
		foreach (c in out) {
			c.raw_profit <- c.profit;
			c.profit *= this.Factor(c.two_way, c.mode);
			if (c.profit < min_profit || this.Blocked(c.mode, c.a, c.b)) continue;
			c.days <- this.BuildDays(c.mode, c.dist);
			/* every project also takes planning, a first fleet and its management: ten days at least */
			c.score <- c.profit / (c.full_cost / money + (c.days + 10) / 180.0) * (per_mode[c.mode] < 2 ? 1.5 : 1.0);
			keep.append(c);
		}
		out = keep;
		out.sort(function(x, y) { return y.score > x.score ? 1 : (y.score < x.score ? -1 : 0); });
		Log.Debug("PLAN", out.len() + " candidates (" + Util.OpsSince(ops) / 1000 + "k operations)");
		return out;
	}

	function Key(mode, a, b, cargo) {
		local ka = a.type + "." + a.id, kb = b.type + "." + b.id;
		if (cargo == Util.pax && ka > kb) { local t = ka; ka = kb; kb = t; }
		return mode + ":" + cargo + ":" + ka + ":" + kb;
	}

	function Cand(mode, cargo, a, b, d, supply, best, infra, two_way) {
		local n = best.eval.n;
		local price = best.eval.capex / max(1, n);
		return {mode = mode, cargo = cargo, a = a, b = b, dist = d, supply = supply, engine = best.engine, best = best,
			two_way = two_way, profit = best.eval.profit.tofloat(), full_cost = (infra + best.eval.capex).tofloat(),
			first_cost = (infra + min(n, 2) * price).tofloat(), infra = infra, key = this.Key(mode, a, b, cargo), done = false};
	}

	function TownEnd(t) { return {type = END_TOWN, id = t}; }
	function IndEnd(i) { return {type = END_INDUSTRY, id = i}; }

	/* ---------------- passengers ---------------- */

	function Towns() {
		local list = AITownList();
		list.Valuate(AITown.GetPopulation);
		list.KeepAboveValue(250);
		local out = [];
		foreach (t in Util.TopN(list, 40)) {
			if (this.Refused(t)) continue;
			if (::MT.nb.TownTaken(t)) { ::MT.nb.Skip("towns served by others", t); continue; }
			out.append(t);
		}
		return out;
	}

	/* Monthly passengers our station in a town collects: a fraction of the town's production (catchment x rating). */
	function TownCap(town, mode) {
		local capture = [0.20, 0.16, 0.16, 0.12][mode];
		return AITown.GetLastMonthProduction(town, Util.pax) * capture;
	}

	/*
	 * Passengers per month and direction that a new link between towns a and b adds. With CargoDist a town's
	 * passengers are shared out over every destination of the network, so a link only adds the passengers of
	 * a town the network does not reach yet; between two towns already in the network it mostly reroutes
	 * people who travel anyway (a fifth is counted for the shorter trips and spare capacity).
	 */
	function PaxFlow(a, b, mode, in_net) {
		local ca = this.TownCap(a, mode), cb = this.TownCap(b, mode);
		local na = a in in_net, nb = b in in_net;
		if (!na && !nb) return fmin(ca, cb);
		if (na && !nb) return cb;
		if (!na && nb) return ca;
		return 0.2 * fmin(ca, cb);
	}

	/* ---------------- learning from built routes ---------------- */

	/* Construction days per mode: a fixed part and a part per tile of distance (learned from every project). */
	day_base = [3.0, 10.0, 2.0, 6.0];
	day_tile = null;

	function BuildDays(mode, dist) {
		if (this.day_tile == null) this.day_tile = [0.05, 0.25, 0.0, 0.05];
		return this.day_base[mode] + this.day_tile[mode] * dist;
	}

	/* Savegames hold no floats: hundredths of a day per tile. */
	function DayTileSave() {
		this.BuildDays(0, 0);
		local out = [];
		foreach (f in this.day_tile) out.append((f * 100).tointeger());
		return out;
	}

	function DayTileLoad(a) {
		this.BuildDays(0, 0);
		foreach (i, v in a) if (i < 4) this.day_tile[i] = v / 100.0;
	}

	function LearnDays(mode, dist, days) {
		this.BuildDays(mode, dist);
		local per_tile = fmax(0.0, (days - this.day_base[mode]) / fmax(10.0, dist.tofloat()));
		this.day_tile[mode] = 0.7 * this.day_tile[mode] + 0.3 * per_tile;
	}

	/*
	 * The estimates are only as good as the model behind them: congestion at airports, breakdowns, slopes and
	 * growing industries are not in it. So every route, after its first full calendar year, compares its real
	 * profit with the estimate it was built on, and the ratio (a moving average per mode, for passengers and
	 * freight apart) scales all later estimates of that kind.
	 */
	learn = null;   // "p<mode>" / "f<mode>" -> real profit / estimated profit (moving average)

	function Factor(two_way, mode) {
		if (this.learn == null) this.learn = {};
		local k = (two_way ? "p" : "f") + mode;
		return (k in this.learn) ? this.learn[k] : 1.0;
	}

	function Learn(route, actual) {
		if (route.est_profit <= 0) return;
		local year = AIDate.GetYear(Util.Today());
		if (route.created >= AIDate.GetDate(year - 1, 1, 1)) return;   // not yet a whole year in service
		local sample = Util.Clamp(1000 * actual / route.est_profit, 200, 3000) / 1000.0;
		local k = (route.two_way ? "p" : "f") + route.mode;
		local old = this.Factor(route.two_way, route.mode);
		this.learn[k] <- 0.7 * old + 0.3 * sample;
		Log.Info("PLAN", route.Name() + " made " + Util.Money(actual) + " last year against an estimate of " + Util.Money(route.est_profit) +
			"; " + (route.two_way ? "passenger" : "freight") + " " + ["road", "rail", "air", "water"][route.mode] + " estimates now x" +
			(this.learn[k] * 100).tointeger() + "%");
		route.est_profit = -1;   // learn once per route
	}

	function PaxCandidates(out) {
		local towns = this.Towns();
		local game = ::MT.game;
		local in_net = ::MT.routes.InNetwork();
		local fly = game.allow[MODE_AIR] && ::MT.safety.FlyingAllowed();
		/* airport types per town, once per round (the 20 biggest towns are the ones worth an airport) */
		this.air_type = {};
		if (fly) {
			local budget = ::MT.finance.Available();
			for (local i = 0; i < min(20, towns.len()); i++) this.air_type[towns[i]] <- this.AirportTypeFor(towns[i], budget);
		}
		for (local i = 0; i < towns.len(); i++) {
			for (local j = i + 1; j < towns.len(); j++) {
				local a = towns[i], b = towns[j];
				local d = AIMap.DistanceManhattan(AITown.GetLocation(a), AITown.GetLocation(b));
				if (d < 15) continue;
				local found = [];
				if (game.allow[MODE_ROAD] && d <= 55 && !::MT.routes.HasLink(a, b, MODE_ROAD)) found.append(this.EvalPaxRoad(a, b, d, this.PaxFlow(a, b, MODE_ROAD, in_net)));
				if (game.allow[MODE_RAIL] && d >= 35 && d <= 220 && !::MT.routes.HasLink(a, b, MODE_RAIL)) found.append(this.EvalPaxRail(a, b, d, this.PaxFlow(a, b, MODE_RAIL, in_net)));
				if (fly && d >= 80 && (a in this.air_type) && (b in this.air_type) && !::MT.routes.HasLink(a, b, MODE_AIR)) {
					found.append(this.EvalPaxAir(a, b, d, this.PaxFlow(a, b, MODE_AIR, in_net)));
				}
				if (game.allow[MODE_WATER] && d >= 20 && d <= 200 && !::MT.routes.HasLink(a, b, MODE_WATER) && this.Coastal(a) && this.Coastal(b)) {
					found.append(this.EvalPaxWater(a, b, d, this.PaxFlow(a, b, MODE_WATER, in_net)));
				}
				local best = null;
				foreach (c in found) {
					if (c == null || c.profit <= 0 || this.Failed(c.key)) continue;
					if (best == null || c.profit / c.full_cost > best.profit / best.full_cost) best = c;
				}
				if (best != null) out.append(best);
			}
		}
	}

	function EvalPaxRoad(a, b, d, supply) {
		if (supply < 8) return null;
		local best = ::MT.engines.BestRoad(Util.pax, d * 1.25, d, supply, true);
		if (best == null) return null;
		local rt = AIRoad.ROADTYPE_ROAD;
		local infra = AIRoad.GetBuildCost(rt, AIRoad.BT_ROAD) * d * 0.5 + 2 * AIRoad.GetBuildCost(rt, AIRoad.BT_BUS_STOP) +
			AIRoad.GetBuildCost(rt, AIRoad.BT_DEPOT) * 2;
		return this.Cand(MODE_ROAD, Util.pax, this.TownEnd(a), this.TownEnd(b), d, supply, best, infra, true);
	}

	function RailInfra(rt, tiles, L) {
		local track = AIRail.GetBuildCost(rt, AIRail.BT_TRACK) * tiles * 1.3;
		local stations = 2 * (2 * L * AIRail.GetBuildCost(rt, AIRail.BT_STATION) + 10 * AIRail.GetBuildCost(rt, AIRail.BT_TRACK) +
			AIRail.GetBuildCost(rt, AIRail.BT_DEPOT));
		local clear = AITile.GetBuildCost(AITile.BT_CLEAR_GRASS) * tiles * 2;
		return track + stations + clear;
	}

	function EvalPaxRail(a, b, d, supply) {
		if (supply < 8) return null;
		local L = this.PlatformLength();
		local best = ::MT.engines.BestTrain(L, Util.pax, d * 1.2, d, supply * 1.4, true, -1, -1, 1);
		if (best == null) return null;
		return this.Cand(MODE_RAIL, Util.pax, this.TownEnd(a), this.TownEnd(b), d, supply, best, this.RailInfra(best.plan.railtype, d * 1.2, L), true);
	}

	/* A town with open water at its edge (a ferry could call), cached for a year. */
	function Coastal(town) {
		if (this.near_water == null) this.near_water = {};
		local key = "t" + town;
		if ((key in this.near_water) && Util.Today() - this.near_water[key][1] < 365) return this.near_water[key][0];
		/* sea or lake, not a river: river towns rarely share a navigable water body */
		local list = Geo.Square(AITown.GetLocation(town), ::MT.nb.TownRadius(town) + 2);
		list.Valuate(AITile.IsSeaTile);
		list.KeepValue(1);
		local r = list.Count() >= 15;
		this.near_water[key] <- [r, Util.Today()];
		return r;
	}

	function EvalPaxWater(a, b, d, supply) {
		if (supply < 8) return null;
		local best = ::MT.engines.BestShip(Util.pax, d * 1.3, d, supply, true);
		if (best == null) return null;
		local infra = 2 * AIMarine.GetBuildCost(AIMarine.BT_DOCK) + AIMarine.GetBuildCost(AIMarine.BT_DEPOT);
		return this.Cand(MODE_WATER, Util.pax, this.TownEnd(a), this.TownEnd(b), d, supply, best, infra, true);
	}

	function HasAirport(town) {
		local hub = ::MT.routes.Hub(town);
		return AIStation.IsValidStation(hub.air_sid) && AIAirport.IsAirportTile(hub.air_tile);
	}

	function AirportTypeFor(town, budget) {
		if (this.HasAirport(town)) return AIAirport.GetAirportType(::MT.routes.Hub(town).air_tile);
		foreach (t in ::MT.air.ChooseTypes(AITown.GetPopulation(town), budget / 3)) if (!this.NoAirport(town, t)) return t;
		return -1;
	}

	air_type = null;   // town -> airport type it has or would get (this planning round)

	function EvalPaxAir(a, b, d, supply) {
		if (supply < 8) return null;
		local ta = this.air_type[a], tb = this.air_type[b];
		if (ta < 0 || tb < 0) return null;
		local best = ::MT.engines.BestAircraft(AITown.GetLocation(a), AITown.GetLocation(b), ta, tb, supply);
		if (best == null) return null;
		local infra = (this.HasAirport(a) ? 0 : AIAirport.GetPrice(ta)) + (this.HasAirport(b) ? 0 : AIAirport.GetPrice(tb));
		/* random landing crashes (when the game has them on): the aircraft lost on average each year */
		local p = ::MT.safety.LandingProbability(best.engine);
		if (p > 0) best.eval.profit -= best.eval.n * 2.0 * 365.0 / fmax(1.0, best.eval.rtt) * p * AIEngine.GetPrice(best.engine);
		local c = this.Cand(MODE_AIR, Util.pax, this.TownEnd(a), this.TownEnd(b), d, supply, best, infra, true);
		c.type_a <- ta;
		c.type_b <- tb;
		/* a pair that failed for want of room for these airports may still fit smaller ones */
		c.key += ":" + ta + "-" + tb;
		return c;
	}

	/* ---------------- freight ---------------- */

	/* Industries producing freight we could take: not ours yet, not someone else's, ranked by monthly value. */
	function Producers() {
		local scored = [];
		foreach (c, _ in AICargoList()) {
			if (c == Util.pax || c == Util.mail || !AICargo.IsFreight(c)) continue;
			local unit = AICargo.GetCargoIncome(c, 60, 20);
			foreach (ind, _ in AIIndustryList_CargoProducing(c)) {
				local prod = AIIndustry.GetLastMonthProduction(ind, c);
				if (prod < 15) continue;
				if (::MT.routes.Carrying(ind, c) != null) continue;
				scored.append([prod * unit, ind, c]);
			}
		}
		scored.sort(function(a, b) { return b[0] > a[0] ? 1 : (b[0] < a[0] ? -1 : 0); });
		local out = [];
		foreach (s in scored) {
			if (out.len() >= 45) break;
			if (::MT.nb.IndustryTaken(s[1])) { ::MT.nb.Skip("industries served by others", s[1]); continue; }
			/* already picked up by one of our stations built for a neighbour */
			if (AIIndustry.GetLastMonthTransported(s[1], s[2]) > 0 && ::MT.nb.OurPickup(s[1], s[2])) continue;
			out.append(s);
		}
		return out;
	}

	/* Industry near water (a dock could serve it), cached for a year. */
	near_water = null;
	function NearWater(ind, pickup) {
		if (this.near_water == null) this.near_water = {};
		local key = ind + (pickup ? "p" : "a");
		if ((key in this.near_water) && Util.Today() - this.near_water[key][1] < 365) return this.near_water[key][0];
		local r = false;
		if (AIIndustry.HasDock(ind)) r = true;
		else {
			local list = pickup ? AITileList_IndustryProducing(ind, ::MT.game.Catchment(MODE_WATER)) : AITileList_IndustryAccepting(ind, ::MT.game.Catchment(MODE_WATER));
			list.Valuate(AITile.IsSeaTile);
			list.KeepValue(1);
			r = list.Count() >= 2;   // a dock needs two tiles of water in front of it; DockSites and the lane check decide
		}
		this.near_water[key] <- [r, Util.Today()];
		return r;
	}

	function FreightCandidates(out) {
		local game = ::MT.game;
		foreach (p in this.Producers()) {
			local ind = p[1], cargo = p[2];
			local prod = AIIndustry.GetLastMonthProduction(ind, cargo);
			local supply = prod * RATING_SHARE;
			local loc = AIIndustry.GetLocation(ind);
			local rig = AIIndustry.HasDock(ind) && AIIndustry.IsBuiltOnWater(ind);
			local dests = [];
			local acc = AIIndustryList_CargoAccepting(cargo);
			acc.Valuate(AIIndustry.GetDistanceManhattanToTile, loc);
			acc.KeepBetweenValue(11, 251);
			acc.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
			foreach (a, dist in acc) {
				if (dests.len() >= 6) break;
				if (a == ind || AIIndustry.IsCargoAccepted(a, cargo) != AIIndustry.CAS_ACCEPTED) continue;
				if (::MT.nb.IndustryTaken(a)) { ::MT.nb.Skip("industries served by others", a); continue; }
				dests.append([this.IndEnd(a), dist]);
			}
			local te = AICargo.GetTownEffect(cargo);
			if (te == AICargo.TE_GOODS || te == AICargo.TE_FOOD || te == AICargo.TE_WATER) {
				local towns = AITownList();
				towns.Valuate(AITown.GetPopulation);
				towns.KeepAboveValue(900);
				foreach (t, _ in towns) {
					local dist = AITown.GetDistanceManhattanToTile(t, loc);
					if (dist < 11 || dist > 70 || ::MT.nb.TownTaken(t)) continue;
					dests.append([this.TownEnd(t), dist]);
				}
			}
			if (rig) Log.Debug("DEBUG", "oil rig " + Util.IndustryName(ind) + ": " + prod + "/month, " + dests.len() + " refineries in range" +
				(dests.len() > 0 ? ", nearest by water: " + this.NearWater(dests[0][0].id, false) : ""));
			local best = {};   // mode -> best candidate: a fallback when the best mode cannot be built
			foreach (dd in dests) {
				local dest = dd[0], d = dd[1];
				local found = [];
				if (rig) {
					if (game.allow[MODE_WATER] && dest.type == END_INDUSTRY && this.NearWater(dest.id, false)) found.append(this.EvalFreight(MODE_WATER, ind, cargo, dest, d, supply));
				} else {
					if (game.allow[MODE_ROAD] && d <= 70) found.append(this.EvalFreight(MODE_ROAD, ind, cargo, dest, d, supply));
					if (game.allow[MODE_RAIL] && d >= 30 && d <= 220 && dest.type == END_INDUSTRY) found.append(this.EvalFreight(MODE_RAIL, ind, cargo, dest, d, supply));
					if (game.allow[MODE_WATER] && d >= 20 && dest.type == END_INDUSTRY && this.NearWater(ind, true) && this.NearWater(dest.id, false)) {
						found.append(this.EvalFreight(MODE_WATER, ind, cargo, dest, d, supply));
					}
				}
				foreach (c in found) {
					if (c == null || c.profit <= 0 || this.Failed(c.key)) continue;
					if (!(c.mode in best) || c.profit / c.full_cost > best[c.mode].profit / best[c.mode].full_cost) best[c.mode] <- c;
				}
			}
			foreach (m, c in best) out.append(c);
		}
	}

	function EvalFreight(mode, ind, cargo, dest, d, supply) {
		local a = this.IndEnd(ind);
		local best = null, infra = 0;
		if (mode == MODE_ROAD) {
			best = ::MT.engines.BestRoad(cargo, d * 1.3, d, supply, false);
			local rt = AIRoad.ROADTYPE_ROAD;
			infra = AIRoad.GetBuildCost(rt, AIRoad.BT_ROAD) * d * 0.9 + 2 * AIRoad.GetBuildCost(rt, AIRoad.BT_TRUCK_STOP) +
				AIRoad.GetBuildCost(rt, AIRoad.BT_DEPOT) + AITile.GetBuildCost(AITile.BT_CLEAR_GRASS) * d;
		} else if (mode == MODE_RAIL) {
			local L = this.PlatformLength();
			best = ::MT.engines.BestTrain(L, cargo, d * 1.2, d, supply, false, -1, -1, 1);
			if (best != null) infra = this.RailInfra(best.plan.railtype, d * 1.2, L);
		} else if (mode == MODE_WATER) {
			best = ::MT.engines.BestShip(cargo, d * 1.3, d, supply, false);
			local docks = AIIndustry.HasDock(ind) ? 1 : 2;
			infra = docks * AIMarine.GetBuildCost(AIMarine.BT_DOCK) + AIMarine.GetBuildCost(AIMarine.BT_DEPOT);
		}
		if (best == null) return null;
		return this.Cand(mode, cargo, a, dest, d, supply, best, infra, false);
	}

	/* ---------------- money that construction cannot use ---------------- */

	/*
	 * Building is limited by the AI's share of the game (path searches take weeks), so money piles up in the
	 * later years. Part of it buys income without construction: a statue in each town where our stations stand
	 * adds 26 to every station rating there (station_cmd.cpp UpdateStationRating), so more of the cargo and
	 * passengers reach our vehicles. One statue a month, only with a large surplus, never in a town another
	 * company serves; never bribes or exclusive rights. (Funding new buildings was tried and dropped: at about
	 * a statue's price every three months it cost far more than the extra passengers brought in.)
	 */
	function SpendIdle() {
		local spare = ::MT.finance.Cash() - ::MT.finance.Reserve() * 4 - max(::MT.finance.next_need, 400000);
		if (spare < 1000000 || ::MT.finance.trouble) return;
		local towns = {};
		foreach (route in ::MT.routes.Active()) {
			foreach (sid in route.sids) if (sid >= 0 && AIStation.IsValidStation(sid)) towns[AIStation.GetNearestTown(sid)] <- true;
		}
		foreach (town, _ in towns) {
			if (!AITown.IsValidTown(town) || AITown.HasStatue(town) || ::MT.nb.TownTaken(town)) continue;
			if (!AITown.IsActionAvailable(town, AITown.TOWN_ACTION_BUILD_STATUE)) continue;
			if (AITown.PerformTownAction(town, AITown.TOWN_ACTION_BUILD_STATUE)) {
				Log.Info("PLAN", "statue in " + Util.TownName(town) + " (better ratings at our stations there)");
				return;
			}
		}
	}

	/* ---------------- closing routes ---------------- */

	function CloseRoute(route, reason) {
		if (route.state != ROUTE_ACTIVE) return;
		Log.Warn("PLAN", route.Name() + ": closing (" + reason + ")");
		::MT.fleet.Close(route, reason);
	}

	/* Once its vehicles are sold, a closed route's stations, depots, track and new roads are removed. */
	function FinishClosures() {
		foreach (route in ::MT.routes.routes) {
			if (route.state != ROUTE_CLOSING || route.VehicleCount() > 0) continue;
			route.state = ROUTE_CLOSED;
			::MT.projects.Cleanup(route);
			Log.Info("PLAN", route.Name() + " closed and removed (" + route.note + ")");
		}
	}

	/* An industry closed: its routes go too. */
	function OnIndustryClosed(ind) {
		foreach (route in ::MT.routes.Active()) {
			if (route.Industry(0) == ind || route.Industry(1) == ind) this.CloseRoute(route, Util.IndustryName(ind) + " closes");
		}
		this.cands_date = -10000;
	}

	crossings_seen = null;   // crossings we could not remove (reported once)

	/* A town built a road across our track: take the crossing out again and give the road a bridge. */
	function FixCrossings(route) {
		foreach (t in route.track_tiles) {
			if (!AIRail.IsLevelCrossingTile(t)) continue;
			local done = false, axis = -1;
			foreach (d in [DIR_PX, DIR_PY]) {
				local a = t - Geo.Offset(d), b = t + Geo.Offset(d);
				if (AIRoad.AreRoadTilesConnected(t, a) || AIRoad.AreRoadTilesConnected(t, b)) {
					done = AIRoad.RemoveRoad(a, b);
					axis = d;
					break;
				}
			}
			if (!done && AIError.GetLastError() == AIError.ERR_LOCAL_AUTHORITY_REFUSES) this.OnRefused(AITile.GetClosestTown(t));
			local bridged = done && this.BridgeTownRoad(t, axis);
			/* another company's road across our track cannot be taken away: say so once */
			if (!done && this.crossings_seen != null && (t in this.crossings_seen)) continue;
			if (!done) { if (this.crossings_seen == null) this.crossings_seen = {}; this.crossings_seen[t] <- true; }
			Log.Warn("SAFETY", route.Name() + ": level crossing at " + Util.TileStr(t) + (done ? " removed" +
				(bridged ? "; the road now crosses on a bridge" : "") : " could not be removed (" + AIError.GetLastErrorString() + ")"));
		}
	}

	/* After a town-built crossing is removed, a road bridge over the railway (towns extend dead ends). */
	function BridgeTownRoad(t, d) {
		local off = Geo.Offset(d);
		local a = t - off, b = t + off;
		while (AIRail.IsRailTile(a) && AIMap.DistanceManhattan(a, t) < 6) a -= off;
		while (AIRail.IsRailTile(b) && AIMap.DistanceManhattan(b, t) < 6) b += off;
		foreach (h in [a, b]) {
			local road = AIRoad.IsRoadTile(h) && !AIRoad.IsRoadStationTile(h) && !AIRoad.IsDriveThroughRoadStationTile(h) && !AIRoad.IsRoadDepotTile(h);
			if (AIRail.IsRailTile(h) || AIBridge.IsBridgeTile(h) || AITunnel.IsTunnelTile(h) || (!AITile.IsBuildable(h) && !road)) return false;
		}
		local br = ::MT.bridges.For(AIMap.DistanceManhattan(a, b) + 1, 80);
		if (br < 0) return false;
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		local ok;
		{
			local tm = AITestMode();
			ok = AIBridge.BuildBridge(AIVehicle.VT_ROAD, br, a, b);
		}
		if (ok && ::MT.finance.Ensure(AIBridge.GetPrice(br, AIMap.DistanceManhattan(a, b) + 1) + 20000) &&
				AIBridge.BuildBridge(AIVehicle.VT_ROAD, br, a, b)) {
			foreach (pair in [[a, a - off], [b, b + off]]) {
				if (AIRoad.IsRoadTile(pair[1]) && !AIRoad.AreRoadTilesConnected(pair[0], pair[1])) AIRoad.BuildRoad(pair[0], pair[1]);
			}
			return true;
		}
		return false;
	}
}
