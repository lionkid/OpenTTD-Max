/*
 * Planner: decides what to build next.
 *
 * Candidates are passenger links between towns and freight links from a producing industry to an accepting
 * industry or town, each evaluated for every mode that fits its distance (road, rail, air, water). Their
 * value is the yearly operating result of the vehicles they need plus what they add to the score:
 * delivered cargo (400 of the 1000 points: one point per 100 units a year), profitable vehicles, served
 * station parts, a cargo type not delivered yet, and a mode not used yet. Points are converted to money
 * at ScoreKeeper.PoundsPerPoint() so that profit (which buys the next lines) and score are compared on one
 * scale. While money is short the candidates are ranked by value per pound of the first outlay; with money
 * to spare, construction time is what is scarce and they are ranked by value.
 *
 * Construction flows: road lines (stops in towns or in industry catchments, roads built where needed),
 * railways (two-platform termini or shared stations, single track first, doubled with path signals), air
 * lines (airports joined to the town's hub), ship lines (docks, a depot in the water), and the town circle
 * lines and road grids of TownCare.
 */

class Planner {
	last_build = -10000;
	failures = null;       // candidate key -> date of the last failure
	refused = null;        // town -> date its local authority last refused us
	built_modes = null;    // mode -> lines built (variety)
	cands_cache = null;    // the last candidate list (evaluating every pair costs weeks of script time)
	cands_date = -10000;
	no_site = null;        // end key -> date no rail station site was found there
	no_air = null;         // town -> date no airport site was found there

	constructor() {
		this.failures = {};
		this.refused = {};
		this.built_modes = array(MODE_COUNT, 0);
		this.no_site = {};
		this.no_air = {};
	}

	function NoAir(town) { return (town in this.no_air) && Util.Today() - this.no_air[town] < 365; }

	function NoSite(end) {
		local k = ::TY.network.EndKey(end[0], end[1]);
		return (k in this.no_site) && Util.Today() - this.no_site[k] < 730;
	}

	function OnRefused(town) {
		if (!AITown.IsValidTown(town)) return;
		this.refused[town] <- Util.Today();
		local n = Util.PlantTrees(town, 30);
		Log.Info("PLAN", Util.TownName(town) + " refused construction (rating " + Util.RatingEstimate(town) +
			"); planted " + n + " trees to repair relations");
	}

	function Refused(town) { return (town in this.refused) && Util.Today() - this.refused[town] < 240; }

	function Cooldown() {
		local base = ::TY.levels.cooldown;
		if (::TY.finance.Available() > 2000000) return base / 4;
		if (::TY.finance.Available() > 600000) return base / 2;
		return base;
	}

	function PlatformLength() { return Util.Clamp(::TY.game.max_train_length, 3, 6); }

	function Step() {
		if (Util.Today() - this.last_build < this.Cooldown()) return;
		if (::TY.finance.trouble) return;
		foreach (line in ::TY.network.Active()) {
			if (line.mode != MODE_RAIL || line.double_track) continue;
			if (line.note == "signals") {
				this.last_build = Util.Today();
				this.InstallSignals(line, this.Decode(line.p2));
				return;
			}
			if (line.note == "upgrade" && ::TY.finance.CanAfford(this.UpgradeCost(line))) {
				this.last_build = Util.Today();
				this.UpgradeRail(line);
				return;
			}
		}
		if (::TY.towns.Project()) { this.last_build = Util.Today(); return; }
		if (this.Interchanges()) { this.last_build = Util.Today(); return; }
		if (this.AddFacilities()) { this.last_build = Util.Today(); return; }
		if (::TY.network.ActiveCount() >= ::TY.levels.line_cap) return;
		local cands = this.CachedCandidates();
		/* road lines are built in a day or two and every vehicle is a point: the good ones go first, without using up the step */
		if (this.QuickRoads(cands) > 0) {
			local rest = [];
			foreach (c in cands) if (!(c.key in this.failures) && !::TY.network.HasLink(c.ends[0][0], c.ends[0][1], c.ends[1][0], c.ends[1][1], c.cargo, c.mode)) rest.append(c);
			cands = rest;
			this.last_build = Util.Today();
		}
		if (AIController.GetSetting("debug") == 1) {
			for (local i = 0; i < min(8, cands.len()); i++) {
				Log.Info("DEBUG", "candidate " + (i + 1) + ": " + this.Describe(cands[i]) + " score " + (cands[i].score * 100).tointeger() + "%");
			}
		}
		/*
		 * End game: a railway or a ship line takes weeks to build and its vehicles only count once they have a
		 * full calendar year of profit, so from July of the year before the ranking only road and air lines are
		 * opened, and in the ending year only a cheap road line that adds a missing cargo type (counted in
		 * July-September), and before July. A month lost in a long site search is a month of fleet management lost.
		 */
		local phase = ::TY.score.phase, month = AIDate.GetMonth(Util.Today());
		if (phase == PHASE_HARVEST && (month >= 7 || ::TY.score.Deficit(SCORE_CARGO) <= 0)) return;
		local slow_ok = phase == PHASE_GROW || phase == PHASE_OVER || (phase == PHASE_PREPARE && month <= 6);
		local tried = 0;
		local started = Util.Today();
		foreach (c in cands) {
			if (!::TY.finance.CanAfford(c.cost)) continue;
			if (!slow_ok && (c.mode == MODE_RAIL || c.mode == MODE_WATER)) continue;
			if (c.mode == MODE_RAIL && (this.NoSite(c.ends[0]) || this.NoSite(c.ends[1]))) continue;   // a cached candidate may predate the finding
			if (phase == PHASE_HARVEST && (c.mode != MODE_ROAD || ::TY.score.CargoDelivered(c.cargo))) continue;
			if (++tried > ::TY.levels.patience || Util.Today() - started > 45) break;
			Log.Info("PLAN", "building " + this.Describe(c));
			local t_start = Util.Today();
			local ok = false;
			try {
				if (c.mode == MODE_AIR) ok = this.BuildAir(c);
				else if (c.mode == MODE_RAIL) ok = this.BuildRail(c);
				else if (c.mode == MODE_WATER) ok = this.BuildWater(c);
				else ok = this.BuildRoad(c);
			} catch (e) {
				Log.Error("PLAN", "construction error: " + e);
				ok = false;
			}
			this.last_build = Util.Today();
			if (AIController.GetSetting("debug") == 1) Log.Info("DEBUG", "attempt took " + (Util.Today() - t_start) + " days: " + (ok ? "built" : "failed"));
			if (ok) {
				this.built_modes[c.mode]++;
				this.cands_date = -10000;   // the network changed: re-evaluate next time
				if (c.mode != MODE_ROAD) this.SideProject(cands);
				return;
			}
			this.failures[c.key] <- Util.Today();
		}
	}

	/* Candidates are re-evaluated every 40 days or after a build; a failed one is dropped from the cached list. */
	function CachedCandidates() {
		if (this.cands_cache == null || Util.Today() - this.cands_date > 40) {
			local ops = Util.OpsMark();
			local t0 = Util.Today();
			::TY.engines.quick = true;
			try { this.cands_cache = this.Candidates(); } catch (e) { ::TY.engines.quick = false; throw e; }
			::TY.engines.quick = false;
			this.cands_date = Util.Today();
			if (AIController.GetSetting("debug") == 1) Log.Info("DEBUG", "candidates: " + this.cands_cache.len() + " in " + (Util.Today() - t0) + " days");
		}
		local out = [];
		foreach (c in this.cands_cache) {
			if ((c.key in this.failures) && Util.Today() - this.failures[c.key] < 730) continue;
			if (::TY.network.HasLink(c.ends[0][0], c.ends[0][1], c.ends[1][0], c.ends[1][1], c.cargo, c.mode)) continue;
			out.append(c);
		}
		return out;
	}

	/* With money to spare, a road line is built next to each big project: it takes days, not months. */
	function SideProject(cands) {
		if (::TY.finance.Cash() - ::TY.finance.Reserve() < 300000 || ::TY.network.ActiveCount() >= ::TY.levels.line_cap) return;
		foreach (c in cands) {
			if (c.mode != MODE_ROAD || !::TY.finance.CanAfford(c.cost)) continue;
			if ((c.key in this.failures) && Util.Today() - this.failures[c.key] < 730) continue;
			if (::TY.network.HasLink(c.ends[0][0], c.ends[0][1], c.ends[1][0], c.ends[1][1], c.cargo, MODE_ROAD)) continue;
			Log.Info("PLAN", "side project: " + this.Describe(c));
			local ok = false;
			try { ok = this.BuildRoad(c); } catch (e) { Log.Error("PLAN", "construction error: " + e); }
			if (ok) this.built_modes[MODE_ROAD]++;
			else this.failures[c.key] <- Util.Today();
			return;
		}
	}

	/*
	 * Up to two road lines whose vehicles each earn a few thousand a year, built before the main candidate loop:
	 * a railway attempt can take the planner two months and a bus line two days, so cheap vehicle points must
	 * not wait behind it. Nothing in the ending year (its vehicles would not count) and nothing when money is short.
	 */
	function QuickRoads(cands) {
		if (::TY.score.phase == PHASE_HARVEST || ::TY.finance.Cash() - ::TY.finance.Reserve() < 150000) return 0;
		if (::TY.network.ActiveCount() >= ::TY.levels.line_cap) return 0;
		local built = 0;
		foreach (c in cands) {
			if (c.mode != MODE_ROAD || !::TY.finance.CanAfford(c.cost)) continue;
			local n = ("n" in c.best.eval) ? c.best.eval.n : 1;
			if (c.profit / fmax(1.0, n) < 3500 || c.value < 1.5 * c.cost) continue;
			if ((c.key in this.failures) && Util.Today() - this.failures[c.key] < 730) continue;
			if (::TY.network.HasLink(c.ends[0][0], c.ends[0][1], c.ends[1][0], c.ends[1][1], c.cargo, MODE_ROAD)) continue;
			Log.Info("PLAN", "quick road line: " + this.Describe(c));
			local ok = false;
			try { ok = this.BuildRoad(c); } catch (e) { Log.Error("PLAN", "construction error: " + e); }
			if (ok) { built++; this.built_modes[MODE_ROAD]++; this.cands_date = -10000; }
			else this.failures[c.key] <- Util.Today();
			if (built >= 2) break;
		}
		return built;
	}

	function EndName(e) {
		if (e[0] == END_INDUSTRY) { local n = AIIndustry.GetName(e[1]); return n == null ? "industry " + e[1] : n; }
		return Util.TownName(e[1]);
	}

	function Describe(c) {
		return Util.ModeName(c.mode).tolower() + " " + Util.CargoName(c.cargo) + " " + this.EndName(c.ends[0]) + " - " + this.EndName(c.ends[1]) +
			" (" + c.dist + " tiles, " + c.demand.tointeger() + "/month, one way " + c.one_way.tointeger() + " d, cost " +
			Util.Money(c.cost.tointeger()) + ", profit " + Util.Money(c.profit.tointeger()) + "/year, value " + Util.Money(c.value.tointeger()) + ")";
	}

	/* ---------------- candidates ---------------- */

	function Towns() {
		local list = AITownList();
		list.Valuate(AITown.GetPopulation);
		list.KeepAboveValue(200);
		return Util.TopN(list, [16, 20, 28, 34][::TY.levels.iq]);
	}

	/* Monthly passengers (or mail) our stations would collect in a town. */
	function Supply(town, cargo, mode) {
		local prod = AITown.GetLastMonthProduction(town, cargo);
		local capture = [0.30, 0.40, 0.35, 0.30][mode];
		if (::TY.network.HubStation(town) >= 0) capture += 0.1;
		return prod * capture;
	}

	function Demand(a, b, cargo, mode) {
		return fmax(cargo == Util.pax ? 20.0 : 10.0, fmin(this.Supply(a, cargo, mode), this.Supply(b, cargo, mode)));
	}

	function Key(c) {
		local a = ::TY.network.EndKey(c.ends[0][0], c.ends[0][1]), b = ::TY.network.EndKey(c.ends[1][0], c.ends[1][1]);
		return a + ":" + b + ":" + c.cargo + ":" + c.mode;
	}

	function EndCenter(e) { return e[0] == END_TOWN ? AITown.GetLocation(e[1]) : AIIndustry.GetLocation(e[1]); }
	function EndTown(e) { return e[0] == END_TOWN ? e[1] : AITile.GetClosestTown(AIIndustry.GetLocation(e[1])); }

	function Cand(mode, cargo, ea, eb, d, demand, best, cost) {
		local c = {mode = mode, cargo = cargo, ends = [ea, eb], towns = [this.EndTown(ea), this.EndTown(eb)], dist = d, demand = demand,
			engine = best.engine, best = best, cost = cost.tofloat(), profit = best.eval.profit.tofloat(), value = best.eval.value.tofloat(),
			one_way = best.eval.one_way, fare = best.eval.fare, units = best.eval.units_year,
			door = ::TY.time.DoorToDoor(best.eval.one_way, best.eval.headway), key = ""};
		c.key = this.Key(c);
		return c;
	}

	/* The value of a candidate counts the whole fleet it needs; the first purchase is smaller: scale to it. */
	function ScaleToFull(c, full) {
		local f = c.cost / fmax(1.0, full.tofloat());
		c.value *= f;
		c.profit *= f;
		c.units *= f;
		return c;
	}

	links = null;          // "a:b:cargo:mode" and "a:b:cargo" -> true for every open line (one candidate round)
	from_ind = null;       // "ind:cargo" -> lines from that industry
	town_acc = null;       // cargo -> towns accepting it

	function LinkKey(ea, eb, cargo, mode) {
		local a = ::TY.network.EndKey(ea[0], ea[1]), b = ::TY.network.EndKey(eb[0], eb[1]);
		if (a > b) { local t = a; a = b; b = t; }
		return a + ":" + b + ":" + cargo + (mode >= 0 ? ":" + mode : "");
	}

	function Linked(ea, eb, cargo, mode = -1) { return this.LinkKey(ea, eb, cargo, mode) in this.links; }

	function IndexLinks() {
		this.links = {};
		this.from_ind = {};
		this.town_acc = {};
		foreach (l in ::TY.network.lines) {
			if (l.state == LINE_CLOSED) continue;
			this.links[this.LinkKey(l.ends[0], l.ends[1], l.cargo, l.mode)] <- true;
			this.links[this.LinkKey(l.ends[0], l.ends[1], l.cargo, -1)] <- true;
			if (l.ends[0][0] == END_INDUSTRY) {
				local k = l.ends[0][1] + ":" + l.cargo;
				this.from_ind[k] <- (k in this.from_ind) ? this.from_ind[k] + 1 : 1;
			}
		}
	}

	function Candidates() {
		local out = [];
		/* value per pound of a typical project: cheap lines are not preferred just because the purse is empty */
		local budget_share = fmax(60000.0, ::TY.finance.Available().tofloat() / 6.0);
		local game = ::TY.game;
		this.IndexLinks();
		local in_net = {};
		foreach (l in ::TY.network.lines) {
			if (l.state == LINE_CLOSED || l.cargo != Util.pax) continue;
			in_net[l.towns[0]] <- true;
			in_net[l.towns[1]] <- true;
		}
		/* passengers (and mail by road) between towns */
		local towns = this.Towns();
		for (local i = 0; i < towns.len(); i++) {
			for (local j = i + 1; j < towns.len(); j++) {
				local a = towns[i], b = towns[j];
				if (this.Refused(a) || this.Refused(b)) continue;
				local la = AITown.GetLocation(a), lb = AITown.GetLocation(b);
				local d = AIMap.DistanceManhattan(la, lb);
				if (d < 10) continue;
				local ea = [END_TOWN, a], eb = [END_TOWN, b];
				local found = [];
				if (game.allow[MODE_ROAD] && d <= 45 && !this.Linked(ea, eb, Util.pax, MODE_ROAD)) {
					local c = this.EvalRoad(Util.pax, ea, eb, d, this.Demand(a, b, Util.pax, MODE_ROAD));
					if (c != null) found.append(c);
					if (Util.mail >= 0 && d >= 15 && !this.Linked(ea, eb, Util.mail) && ::TY.engines.AnyTruck(Util.mail)) {
						local m = this.EvalRoad(Util.mail, ea, eb, d, this.Demand(a, b, Util.mail, MODE_ROAD));
						if (m != null) found.append(m);
					}
				}
				local rail = null;
				if (game.allow[MODE_RAIL] && d >= 28 && d <= 260 && !this.Linked(ea, eb, Util.pax, MODE_RAIL) && !this.NoSite(ea) && !this.NoSite(eb)) {
					rail = this.EvalRail(Util.pax, ea, eb, d, this.Demand(a, b, Util.pax, MODE_RAIL));
					if (rail != null) found.append(rail);
				}
				if (game.allow[MODE_AIR] && d >= 60 && !this.Linked(ea, eb, Util.pax, MODE_AIR) && !this.NoAir(a) && !this.NoAir(b)) {
					local c = this.EvalAir(ea, eb, d, this.Demand(a, b, Util.pax, MODE_AIR));
					if (c != null) found.append(c);
				}
				if (game.allow[MODE_WATER] && d >= 20 && d <= 200 && !this.Linked(ea, eb, Util.pax, MODE_WATER) &&
						::TY.marine.NearWater(la, 8) && ::TY.marine.NearWater(lb, 8)) {
					local c = this.EvalWater(Util.pax, ea, eb, d, this.Demand(a, b, Util.pax, MODE_WATER));
					if (c != null) found.append(c);
					if (AIController.GetSetting("debug") == 1) Log.Info("DEBUG", "water pair " + Util.TownName(a) + " - " + Util.TownName(b) + " (" + d + " tiles): " +
						(c == null ? "no ship plan" : "profit " + Util.Money(c.profit.tointeger()) + ", value " + Util.Money(c.value.tointeger())));
				}
				foreach (c in found) {
					if ((c.key in this.failures) && Util.Today() - this.failures[c.key] < 730) continue;
					/* CargoDist network effect: a link that joins our network serves all its destinations. */
					if (c.cargo == Util.pax) {
						local na = (a in in_net), nb = (b in in_net);
						if (na != nb) c.value *= 1.35;
						else if (!na && !nb && ::TY.network.lines.len() > 0) c.value *= 0.9;
					}
					out.append(c);
				}
			}
		}
		/* freight from industries */
		foreach (c in this.FreightCandidates()) out.append(c);
		/* score bonuses, mistakes, ranking */
		local ppp = this.PoundsPerPoint();
		foreach (c in out) {
			c.value += this.ScoreBonus(c) * ppp;
			if (::TY.levels.noise > 0) c.value *= 1.0 + ::TY.levels.noise * (Util.Rand(1000) - 500) / 500.0;
			c.score <- c.value / fmax(fmax(1.0, c.cost), budget_share);
		}
		local kept = [];
		foreach (c in out) if (c.value > 0) kept.append(c);
		kept.sort(function(x, y) { return y.score > x.score ? 1 : (y.score < x.score ? -1 : 0); });
		if (kept.len() > ::TY.levels.cand_limit) {
			/* a rich company's budget share makes every cheap road line score low: keep the best few anyway (QuickRoads) */
			local quota = max(6, ::TY.levels.cand_limit / 5), roads = [];
			for (local i = ::TY.levels.cand_limit; i < kept.len() && roads.len() < quota; i++) if (kept[i].mode == MODE_ROAD) roads.append(kept[i]);
			kept.resize(::TY.levels.cand_limit);
			kept.extend(roads);
		}
		return kept;
	}

	/*
	 * Money a point of the score is worth to the planner. Early profit compounds into more lines later while
	 * points do not, so a point is cheap while the ending year is far away and dear in the last years; once
	 * every component a line can raise is at its target, only money itself is left to earn.
	 */
	function PoundsPerPoint() {
		local sc = ::TY.score;
		local open = sc.Deficit(SCORE_DELIVERED) + sc.Deficit(SCORE_VEHICLES) + sc.Deficit(SCORE_STATIONS) + sc.Deficit(SCORE_CARGO);
		if (open <= 0) return 200000.0;
		local left = ::TY.game.ending_year > 0 ? max(1, ::TY.game.YearsLeft()) : 30;
		return Util.Clamp((15000.0 * 8 / left).tointeger(), 3000, 40000).tofloat();
	}

	/*
	 * Points a candidate would add in a year, against the current deficits. Only vehicles that clear the
	 * 10,000 "minimum profit" floor with a margin count: a line of marginal vehicles is a liability that has
	 * to be replaced or sold two years later.
	 */
	function ScoreBonus(c) {
		local n = max(1, c.best.eval.n);
		local per_vehicle = c.best.eval.profit / n;
		local sound = per_vehicle >= 3000;
		local pts = 0.0;
		if (!sound) pts -= 3.0;
		/* variety: the first line of a mode (every vehicle type should appear) */
		if (::TY.levels.iq >= 1 && sound && this.built_modes[c.mode] == 0 && ::TY.network.lines.len() >= 2) pts += 8.0;
		if (!::TY.levels.score_aware) return pts;
		local sc = ::TY.score;
		pts += fmin(sc.Deficit(SCORE_DELIVERED), c.units / 100.0);
		if (sound) pts += fmin(sc.Deficit(SCORE_VEHICLES), n * 100.0 / 120.0);
		pts += fmin(sc.Deficit(SCORE_STATIONS), 2 * 100.0 / 80.0);
		if (sc.Deficit(SCORE_CARGO) > 0 && !sc.CargoDelivered(c.cargo)) {
			local already = false;
			foreach (l in ::TY.network.Active()) if (l.cargo == c.cargo) { already = true; break; }
			if (!already) pts += 12.0;   // more than its 6.25 points: a new cargo also opens the next link of its chain
		}
		return pts;
	}

	/* ---------------- freight candidates ---------------- */

	function FreightCandidates() {
		local out = [];
		local game = ::TY.game;
		local limit = max(4, ::TY.levels.cand_limit / 4);
		foreach (cargo in Util.cargos) {
			if (cargo == Util.pax || cargo == Util.mail) continue;
			if (!::TY.industry.HasConsumer(cargo)) continue;
			local n = 0;
			foreach (src in ::TY.industry.Producers(cargo)) {
				if (n >= limit) break;
				if (src.prod < 24) continue;
				if (src.ind in ::TY.industry.closed) continue;
				local fk = src.ind + ":" + cargo;
				local ours = (fk in this.from_ind) ? this.from_ind[fk] : 0;
				if (ours >= 2) continue;
				local share = (src.stations > ours ? 0.45 : 0.75) / (ours + 1);
				local demand = src.prod * share;
				if (demand < 15) continue;
				n++;
				local ea = [END_INDUSTRY, src.ind];
				local la = AIIndustry.GetLocation(src.ind);
				local sinks = this.Sinks(cargo, src.ind, la);
				foreach (sk in sinks) {
					local eb = sk.end;
					local d = AIMap.DistanceManhattan(la, this.EndCenter(eb));
					if (d < 8) continue;
					if (this.Linked(ea, eb, cargo)) continue;
					local found = [];
					if (game.allow[MODE_ROAD] && d <= 70 && ::TY.engines.AnyTruck(cargo)) {
						local c = this.EvalRoad(cargo, ea, eb, d, demand);
						if (c != null) found.append(c);
					}
					if (game.allow[MODE_RAIL] && d >= 25 && d <= 250 && demand >= 40 && !this.NoSite(ea) && !this.NoSite(eb)) {
						local c = this.EvalRail(cargo, ea, eb, d, demand);
						if (c != null) found.append(c);
					}
					if (game.allow[MODE_WATER] && d >= 12 && d <= 300 && ::TY.engines.AnyShip(cargo) &&
							(AIIndustry.IsBuiltOnWater(src.ind) || ::TY.marine.NearWater(la, 7)) && ::TY.marine.NearWater(this.EndCenter(eb), 7)) {
						local c = this.EvalWater(cargo, ea, eb, d, demand);
						if (c != null) found.append(c);
					}
					foreach (c in found) {
						if ((c.key in this.failures) && Util.Today() - this.failures[c.key] < 730) continue;
						/* feeding a processing industry starts the next link of the chain: its output can be carried on */
						if (eb[0] == END_INDUSTRY && ::TY.industry.Outputs(AIIndustry.GetIndustryType(eb[1])).len() > 0) c.value *= 1.15;
						out.append(c);
					}
				}
			}
		}
		return out;
	}

	/* Nearest accepting industries (three) or towns (two) for a cargo from a producer. */
	function Sinks(cargo, src, la) {
		local out = [];
		if (::TY.industry.IsTownCargo(cargo)) {
			if (!(cargo in this.town_acc)) this.town_acc[cargo] <- ::TY.industry.TownsAccepting(cargo, 20);
			local towns = AIList();
			foreach (town in this.town_acc[cargo]) towns.AddItem(town, -AIMap.DistanceManhattan(la, AITown.GetLocation(town)));
			foreach (town in Util.TopN(towns, 2)) if (!this.Refused(town)) out.append({end = [END_TOWN, town]});
			return out;
		}
		local inds = AIList();
		foreach (ind in ::TY.industry.Acceptors(cargo)) {
			if (ind == src) continue;
			inds.AddItem(ind, -AIIndustry.GetDistanceManhattanToTile(ind, la));
		}
		foreach (ind in Util.TopN(inds, 3)) out.append({end = [END_INDUSTRY, ind]});
		return out;
	}

	/* ---------------- evaluation per mode ---------------- */

	function EvalRoad(cargo, ea, eb, d, demand) {
		local best = ::TY.engines.BestRoadVehicle(cargo, AIRoad.ROADTYPE_ROAD, d * 1.25, d, demand);
		if (best == null) return null;
		local rt = AIRoad.ROADTYPE_ROAD;
		local stop = cargo == Util.pax ? AIRoad.BT_BUS_STOP : AIRoad.BT_TRUCK_STOP;
		local infra = AIRoad.GetBuildCost(rt, AIRoad.BT_ROAD) * d * 0.7 + 2 * AIRoad.GetBuildCost(rt, stop) + 2 * AIRoad.GetBuildCost(rt, AIRoad.BT_DEPOT);
		return this.ScaleToFull(this.Cand(MODE_ROAD, cargo, ea, eb, d, demand, best, infra + AIEngine.GetPrice(best.engine)), infra + best.eval.capex);
	}

	function EvalRail(cargo, ea, eb, d, demand) {
		local L = this.PlatformLength();
		local tiles = d * 1.2;
		local best = ::TY.engines.BestTrain(cargo, L, tiles, d, demand, -1, -1, 1);
		if (best == null) return null;
		local rt = best.plan.railtype;
		local track = AIRail.GetBuildCost(rt, AIRail.BT_TRACK) * tiles * 1.2;
		local stations = 2 * (2 * L * AIRail.GetBuildCost(rt, AIRail.BT_STATION) + 10 * AIRail.GetBuildCost(rt, AIRail.BT_TRACK) +
			AIRail.GetBuildCost(rt, AIRail.BT_DEPOT));
		local clear = AITile.GetBuildCost(AITile.BT_CLEAR_GRASS) * tiles * 2;
		local first = track + stations + clear + best.plan.price;
		local c = this.Cand(MODE_RAIL, cargo, ea, eb, d, demand, best, first);
		c.first_cost <- first;
		return c;
	}

	function EvalAir(ea, eb, d, demand) {
		local a = ea[1], b = eb[1];
		local budget = ::TY.finance.Available();
		local ta = this.AirportTypeFor(a, budget), tb = this.AirportTypeFor(b, budget);
		if (ta < 0 || tb < 0) return null;
		local la = AITown.GetLocation(a), lb = AITown.GetLocation(b);
		local best = ::TY.engines.BestAircraft(Util.pax, la, lb, ta, tb, demand);
		if (best == null) return null;
		local airports = (this.HasAirport(a) ? 0 : AIAirport.GetPrice(ta)) + (this.HasAirport(b) ? 0 : AIAirport.GetPrice(tb));
		local c = this.ScaleToFull(this.Cand(MODE_AIR, Util.pax, ea, eb, d, demand, best, airports + min(best.eval.n, 2) * AIEngine.GetPrice(best.engine)),
			airports + best.eval.capex);
		c.type_a <- ta;
		c.type_b <- tb;
		/* random landing crashes cost the aircraft, its passengers' fares and a profitable vehicle */
		local crashes = ::TY.safety.AirCrashesPerYear(best.engine, ta, tb, 24.0 * best.eval.n * 30.0 / best.eval.rtt);
		if (crashes > 0) c.value -= crashes * (AIEngine.GetPrice(best.engine) + 150000);
		return c;
	}

	function EvalWater(cargo, ea, eb, d, demand) {
		local best = ::TY.engines.BestShip(cargo, d * 1.3, d, demand);
		if (best == null) return null;
		/* slow ships on long routes: the cargo ages away and the ships hardly pay */
		if (best.eval.one_way > 120 || best.eval.profit / max(1, best.eval.n) < 4000) return null;
		local infra = 2 * AIMarine.GetBuildCost(AIMarine.BT_DOCK) + AIMarine.GetBuildCost(AIMarine.BT_DEPOT) + 20000;
		local c = this.ScaleToFull(this.Cand(MODE_WATER, cargo, ea, eb, d, demand, best, infra + AIEngine.GetPrice(best.engine)), infra + best.eval.capex);
		return c;
	}

	function HasAirport(town) {
		local hub = ::TY.network.Hub(town);
		return AIStation.IsValidStation(hub.air_sid) && AIAirport.IsAirportTile(hub.air_tile);
	}

	function AirportTypeFor(town, budget) {
		if (this.HasAirport(town)) return AIAirport.GetAirportType(::TY.network.Hub(town).air_tile);
		local types = ::TY.air.ChooseTypes(AITown.GetPopulation(town), budget / 3);
		return types.len() > 0 ? types[0] : -1;
	}

	/* ---------------- stations at the ends ---------------- */

	function JoinId(end) {
		local sid = end[0] == END_TOWN ? ::TY.network.HubStation(end[1]) : ::TY.network.IndStation(end[1]);
		return sid >= 0 ? sid : AIStation.STATION_NEW;
	}

	/* Register a built station with the hub of its end. */
	function RegisterStation(end, sid, mode) {
		if (end[0] == END_TOWN) {
			local hub = ::TY.network.Hub(end[1]);
			if (!AIStation.IsValidStation(hub.sid)) hub.sid = sid;
			if (mode == MODE_RAIL) hub.rail++;
			if (mode == MODE_ROAD && hub.sid == sid) hub.road_stops.append(sid);
			if (!Util.Contains(hub.stations, sid)) hub.stations.append(sid);
		} else {
			local hub = ::TY.network.IndHub(end[1]);
			if (!AIStation.IsValidStation(hub.sid)) hub.sid = sid;
			if (mode == MODE_RAIL) hub.rail++;
			if (mode == MODE_ROAD) hub.truck++;
			if (mode == MODE_WATER) hub.dock_sid = sid;
		}
	}

	/* A road stop for an end: in a town (passengers / town cargo) or in an industry's catchment. */
	function StopFor(end, cargo, producing, join) {
		if (end[0] == END_TOWN) {
			local center = AITown.GetLocation(end[1]);
			local r = 4 + min(6, AITown.GetPopulation(end[1]) / 800);
			local spot = ::TY.road.FindStop(center, r, join, cargo);
			if (spot == null && join != AIStation.STATION_NEW) spot = ::TY.road.FindStop(center, r, AIStation.STATION_NEW, cargo);
			if (spot == null && cargo != Util.pax) spot = ::TY.road.FindStop(center, r + 4, AIStation.STATION_NEW, cargo);
			return spot;
		}
		local spot = ::TY.road.FindIndustryStop(end[1], cargo, producing, join);
		if (spot == null && join != AIStation.STATION_NEW) spot = ::TY.road.FindIndustryStop(end[1], cargo, producing, AIStation.STATION_NEW);
		return spot;
	}

	/* ---------------- construction: road ---------------- */

	function BuildRoad(c) {
		::TY.road.Use(AIRoad.ROADTYPE_ROAD);
		local freight = c.cargo != Util.pax && c.cargo != Util.mail;
		local join_a = this.JoinId(c.ends[0]), join_b = this.JoinId(c.ends[1]);
		local spot_a = this.StopFor(c.ends[0], c.cargo, true, join_a);
		local spot_b = this.StopFor(c.ends[1], c.cargo, false, join_b);
		if (spot_a == null || spot_b == null) { Log.Warn("PLAN", "no stop site for " + this.Describe(c)); return false; }
		return this.BuildRoadLine(c, spot_a, spot_b, join_a, join_b, c.engine, false);
	}

	function BuildRoadLine(c, spot_a, spot_b, join_a, join_b, engine, feeder) {
		local rt = AIRoad.ROADTYPE_ROAD;
		local stop_bt = c.cargo == Util.pax ? AIRoad.BT_BUS_STOP : AIRoad.BT_TRUCK_STOP;
		if (!::TY.finance.Ensure(4 * AIRoad.GetBuildCost(rt, stop_bt) + 10000)) return false;
		local sa = ::TY.road.BuildStop(spot_a, join_a);
		if (sa < 0 && join_a != AIStation.STATION_NEW) sa = ::TY.road.BuildStop(spot_a, AIStation.STATION_NEW);
		if (sa < 0) return false;
		local sb = ::TY.road.BuildStop(spot_b, join_b);
		if (sb < 0 && join_b != AIStation.STATION_NEW) sb = ::TY.road.BuildStop(spot_b, AIStation.STATION_NEW);
		if (sb < 0) { AIRoad.RemoveRoadStation(spot_a.tile); return false; }
		local conn = ::TY.road.Connect(spot_a.tile, spot_b.tile);
		if (conn == null) {
			Log.Warn("PLAN", "no road route " + Util.TileStr(spot_a.tile) + " - " + Util.TileStr(spot_b.tile));
			AIRoad.RemoveRoadStation(spot_a.tile);
			AIRoad.RemoveRoadStation(spot_b.tile);
			return false;
		}
		if (conn.crossing_risk) ::TY.safety.Veto("road route past a level crossing (accepted)", c.key);
		local pieces = ::TY.road.NewPieces(conn.path);
		::TY.finance.Ensure(pieces * AIRoad.GetBuildCost(rt, AIRoad.BT_ROAD) * 2 + 20000);
		if (!::TY.road.BuildPath(conn.path)) {
			AIRoad.RemoveRoadStation(spot_a.tile);
			AIRoad.RemoveRoadStation(spot_b.tile);
			return false;
		}
		local da = ::TY.road.BuildDepotNear(spot_a.tile);
		local db = ::TY.road.BuildDepotNear(spot_b.tile);
		if (da < 0 && db < 0) {
			Log.Warn("PLAN", "no depot site for the road line");
			AIRoad.RemoveRoadStation(spot_a.tile);
			AIRoad.RemoveRoadStation(spot_b.tile);
			return false;
		}
		local line = Line();
		line.mode = MODE_ROAD;
		line.cargo = c.cargo;
		line.roadtype = rt;
		line.ends = c.ends;
		line.towns = c.towns;
		line.sids = [sa, sb];
		line.tiles = [spot_a.tile, spot_b.tile];
		line.depots = [da, db];
		line.engine = engine;
		line.capacity = ::TY.engines.Capacity(engine, c.cargo);
		line.speed = AIEngine.GetMaxSpeed(engine);
		line.dist = AIMap.DistanceManhattan(spot_a.tile, spot_b.tile);
		line.path_len = conn.path.len();
		line.est_rtt = ::TY.time.RoundTrip(MODE_ROAD, line.speed, line.path_len, line.capacity);
		line.track_tiles = conn.path;
		line.feeder = feeder;
		::TY.network.Add(line);
		this.RegisterStation(c.ends[0], sa, MODE_ROAD);
		this.RegisterStation(c.ends[1], sb, MODE_ROAD);
		local n0 = ::TY.fleet.BuildFor(line, 0);
		if (!feeder || line.est_rtt > 12) ::TY.fleet.BuildFor(line, line.IsFreight() ? 0 : 1);
		Log.Info("BUILD", line.Name() + " opened: " + line.path_len + " road tiles (" + pieces + " new), " +
			AIEngine.GetName(engine) + " (" + line.capacity + " units), round trip about " + line.est_rtt.tointeger() + " days" +
			(n0 < 0 ? " - first vehicle failed" : ""));
		Util.SignAt(spot_a.tile, "TY " + line.Name());
		return true;
	}

	/* ---------------- construction: air ---------------- */

	function EnsureAirport(town, want_type) {
		local hub = ::TY.network.Hub(town);
		if (AIStation.IsValidStation(hub.air_sid) && AIAirport.IsAirportTile(hub.air_tile)) return [hub.air_tile, false];
		local types = [want_type];
		foreach (t in ::TY.air.ChooseTypes(AITown.GetPopulation(town), ::TY.finance.Available())) if (t != want_type) types.append(t);
		foreach (t in types) {
			local join = this.JoinId([END_TOWN, town]);
			local tile = ::TY.air.FindSite(town, t, join);
			if (tile < 0 && join != AIStation.STATION_NEW) { join = AIStation.STATION_NEW; tile = ::TY.air.FindSite(town, t, join); }
			if (tile < 0) continue;
			if (!::TY.finance.Ensure(AIAirport.GetPrice(t) + 5000)) return null;
			local sid = ::TY.air.Build(tile, t, join);
			if (sid < 0 && join != AIStation.STATION_NEW) sid = ::TY.air.Build(tile, t, AIStation.STATION_NEW);
			if (sid < 0) continue;
			hub.air_sid = sid;
			hub.air_tile = tile;
			hub.air_type = t;
			if (!AIStation.IsValidStation(hub.sid)) hub.sid = sid;
			if (!Util.Contains(hub.stations, sid)) hub.stations.append(sid);
			Log.Info("BUILD", ::TY.air.TypeName(t) + " airport for " + Util.TownName(town) + " at " + Util.TileStr(tile) +
				(sid == hub.sid ? " (hub station)" : ""));
			return [tile, true];
		}
		Log.Info("PLAN", "no airport site in " + Util.TownName(town) + " (" + types.len() + " types tried)");
		this.no_air[town] <- Util.Today();
		return null;
	}

	function BuildAir(c) {
		local a = c.ends[0][1], b = c.ends[1][1];
		local ea = this.EnsureAirport(a, c.type_a);
		if (ea == null) return false;
		local eb = this.EnsureAirport(b, c.type_b);
		if (eb == null) { this.DropAirport(a, ea); return false; }
		local ta = AIAirport.GetAirportType(ea[0]), tb = AIAirport.GetAirportType(eb[0]);
		local best = ::TY.engines.BestAircraft(Util.pax, ea[0], eb[0], ta, tb, c.demand);
		if (best == null) {
			Log.Warn("PLAN", "no aircraft for " + ::TY.air.TypeName(ta) + " / " + ::TY.air.TypeName(tb) + " airports");
			this.DropAirport(a, ea);
			this.DropAirport(b, eb);
			return false;
		}
		local line = Line();
		line.mode = MODE_AIR;
		line.cargo = Util.pax;
		line.ends = c.ends;
		line.towns = [a, b];
		line.sids = [AIStation.GetStationID(ea[0]), AIStation.GetStationID(eb[0])];
		line.tiles = [ea[0], eb[0]];
		line.depots = [AIAirport.GetHangarOfAirport(ea[0]), AIAirport.GetHangarOfAirport(eb[0])];
		line.engine = best.engine;
		line.capacity = best.capacity;
		line.speed = AIEngine.GetMaxSpeed(best.engine);
		line.dist = AIMap.DistanceManhattan(ea[0], eb[0]);
		line.path_len = ::TY.time.AirTiles(ea[0], eb[0]);
		line.est_rtt = ::TY.time.RoundTrip(MODE_AIR, line.speed, line.path_len, line.capacity);
		::TY.network.Add(line);
		::TY.fleet.BuildFor(line, 0);
		::TY.fleet.BuildFor(line, 1);
		local pt = AIEngine.GetPlaneType(best.engine);
		Log.Info("BUILD", line.Name() + " opened: " + AIEngine.GetName(best.engine) + " (" + (pt == AIAirport.PT_BIG_PLANE ? "large" : "small") +
			" aircraft, " + ::TY.air.TypeName(ta) + " / " + ::TY.air.TypeName(tb) + " airports), " + line.dist + " tiles, round trip about " +
			line.est_rtt.tointeger() + " days");
		return true;
	}

	function DropAirport(town, ea) {
		if (ea == null || !ea[1]) return;
		if (AIVehicleList_Station(AIStation.GetStationID(ea[0])).Count() > 0) return;
		local hub = ::TY.network.Hub(town);
		if (hub.sid == hub.air_sid) hub.sid = -1;
		hub.air_sid = -1;
		hub.air_tile = -1;
		AIAirport.RemoveAirport(ea[0]);
	}

	/* ---------------- construction: water ---------------- */

	/* Dock (or the oil rig's own station) for an end; returns {tile, water, sid, built} or null. */
	/*
	 * The dock an end would use: an oil rig's own station, our dock there, or a site to build on. Nothing is
	 * built here; CommitDock builds a planned dock once the water route is known.
	 */
	function DockFor(end, cargo, producing) {
		if (end[0] == END_INDUSTRY && AIIndustry.IsBuiltOnWater(end[1]) && AIIndustry.HasDock(end[1])) {
			local t = AIIndustry.GetDockLocation(end[1]);
			local w = ::TY.marine.RigWater(end[1]);
			if (w < 0) return null;
			return {tile = t, water = w, berth = w, sid = AIStation.GetStationID(t), built = false, exists = true, end = end, join = -1, hub = null};
		}
		local hub = end[0] == END_TOWN ? ::TY.network.Hub(end[1]) : ::TY.network.IndHub(end[1]);
		local tiles = end[0] == END_TOWN ? ::TY.marine.TownTiles(end[1], 9 + min(6, AITown.GetPopulation(end[1]) / 600)) :
			::TY.marine.IndustryTiles(end[1], producing);
		if (AIStation.IsValidStation(hub.dock_sid)) {
			foreach (t, _ in AITileList_StationType(hub.dock_sid, AIStation.STATION_DOCK)) {
				/* the game reuses station ids: the dock must really stand at this end */
				if (!AIMarine.IsDockTile(t) || AITile.IsWaterTile(t) || !tiles.HasItem(t)) continue;
				local w = ::TY.marine.Front(t);
				local berth = w >= 0 ? ::TY.marine.Berth(w) : -1;
				if (berth >= 0) return {tile = t, water = w, berth = berth, sid = hub.dock_sid, built = false, exists = true, end = end, join = -1, hub = hub};
			}
			hub.dock_sid = -1;
		}
		local join = this.JoinId(end);
		local site = ::TY.marine.FindDock(tiles, cargo, !producing, join);
		if (site == null && join != AIStation.STATION_NEW) {
			join = AIStation.STATION_NEW;
			site = ::TY.marine.FindDock(tiles, cargo, !producing, join);
		}
		if (site == null) return null;
		/* the berth of a planned dock: the water tile beyond the one the dock takes, sailable before and after building */
		return {tile = site.tile, water = site.water, berth = site.water + (site.water - site.tile), sid = -1, built = false, exists = false,
			end = end, join = join, hub = hub};
	}

	/* Build a planned dock (nothing to do for an existing one). */
	function CommitDock(d) {
		if (d.exists || d.built) return true;
		if (!::TY.finance.Ensure(AIMarine.GetBuildCost(AIMarine.BT_DOCK) + 5000)) return false;
		local sid = ::TY.marine.BuildDock(d, d.join);
		if (sid < 0) return false;
		d.sid = sid;
		d.built = true;
		d.hub.dock_sid = sid;
		if (!AIStation.IsValidStation(d.hub.sid)) d.hub.sid = sid;
		if (d.end[0] == END_TOWN && !Util.Contains(d.hub.stations, sid)) d.hub.stations.append(sid);
		return true;
	}

	/* Remove a dock this attempt built, and forget it. */
	function DropDock(d) {
		if (d == null || !d.built) return;
		if (AIVehicleList_Station(d.sid).Count() > 0) return;
		AIMarine.RemoveDock(d.tile);
		d.built = false;
		if (!AIStation.IsValidStation(d.sid) || !AIStation.HasStationType(d.sid, AIStation.STATION_DOCK)) {
			if (d.hub.dock_sid == d.sid) d.hub.dock_sid = -1;
		}
		if (!AIStation.IsValidStation(d.sid)) {
			if (d.hub.sid == d.sid) d.hub.sid = -1;
			if ("stations" in d.hub) {
				for (local i = 0; i < d.hub.stations.len(); i++) if (d.hub.stations[i] == d.sid) { d.hub.stations.remove(i); break; }
			}
		}
	}

	function BuildWater(c) {
		local da = this.DockFor(c.ends[0], c.cargo, true);
		if (da == null) { Log.Warn("PLAN", "no dock site at " + this.EndName(c.ends[0])); return false; }
		local db = this.DockFor(c.ends[1], c.cargo, false);
		if (db == null) { Log.Warn("PLAN", "no dock site at " + this.EndName(c.ends[1])); return false; }
		if (da.tile == db.tile || AIMap.DistanceManhattan(da.tile, db.tile) < 8 || (da.exists && db.exists && da.sid == db.sid)) {
			Log.Warn("PLAN", "docks at " + Util.TileStr(da.tile) + " and " + Util.TileStr(db.tile) + " are too close for a ship line");
			return false;
		}
		if (da.exists && db.exists && ::TY.network.HasWaterLink(da.sid, db.sid)) {
			Log.Warn("PLAN", "docks at " + Util.TileStr(da.tile) + " and " + Util.TileStr(db.tile) + " already have a ship line");
			return false;
		}
		local path = ::TY.marine.Connect(da.berth, db.berth);
		if (path == null || path.len() < 6) {
			Log.Warn("PLAN", "no water route between the dock sites " + Util.TileStr(da.tile) + " and " + Util.TileStr(db.tile) +
				(path == null ? "" : " (path " + path.len() + " tiles)"));
			return false;
		}
		if (!this.CommitDock(da)) { Log.Warn("PLAN", "dock at " + Util.TileStr(da.tile) + " not built"); return false; }
		if (!this.CommitDock(db)) { Log.Warn("PLAN", "dock at " + Util.TileStr(db.tile) + " not built"); this.DropDock(da); return false; }
		/* the depot off the route, a few tiles from the first dock and clear of both docks' berths */
		local clear = [da.water, db.water];
		local depot = ::TY.marine.BuildDepotNear(path[min(4, path.len() - 1)], clear);
		if (depot < 0) depot = ::TY.marine.BuildDepotNear(path[max(0, path.len() - 5)], clear);
		if (depot < 0) {
			Log.Warn("PLAN", "no ship depot site");
			this.DropDock(da);
			this.DropDock(db);
			return false;
		}
		local best = ::TY.engines.BestShip(c.cargo, path.len(), AIMap.DistanceManhattan(da.tile, db.tile), c.demand);
		if (best == null) { this.DropDock(da); this.DropDock(db); return false; }
		local line = Line();
		line.mode = MODE_WATER;
		line.cargo = c.cargo;
		line.ends = c.ends;
		line.towns = c.towns;
		line.sids = [da.sid, db.sid];
		line.tiles = [da.tile, db.tile];
		line.depots = [depot, -1];
		line.engine = best.engine;
		line.capacity = best.capacity;
		line.speed = AIEngine.GetMaxSpeed(best.engine);
		line.dist = AIMap.DistanceManhattan(da.tile, db.tile);
		line.path_len = path.len();
		line.est_rtt = ::TY.time.RoundTrip(MODE_WATER, line.speed, line.path_len, line.capacity);
		line.track_tiles = path;
		line.buoys = ::TY.marine.PlaceBuoys(path);
		::TY.network.Add(line);
		if (da.built) this.RegisterStation(c.ends[0], da.sid, MODE_WATER);
		if (db.built) this.RegisterStation(c.ends[1], db.sid, MODE_WATER);
		/* one ship first: the fleet manager adds more once it has sailed the route (a bad route costs one ship) */
		local v = ::TY.fleet.BuildFor(line, 0);
		Log.Info("BUILD", line.Name() + " opened: " + path.len() + " water tiles between the docks at " + Util.TileStr(da.tile) + " and " + Util.TileStr(db.tile) +
			", " + line.buoys.len() + " buoys, depot " + Util.TileStr(depot) + ", " + AIEngine.GetName(best.engine) + " (" + line.capacity + " units), round trip about " + line.est_rtt.tointeger() +
			" days" + (v < 0 ? " - first ship failed" : ""));
		return true;
	}

	/* ---------------- construction: rail ---------------- */

	function SameEnd(e, kind, id) { return e[0] == kind && e[1] == id; }

	/* A doubled, signalled line ending at `end` whose station a new line (of the same cargo class) can share. */
	function SharedRailEnd(end, cargo) {
		foreach (line in ::TY.network.Active()) {
			if (line.mode != MODE_RAIL || !line.double_track || line.branch) continue;
			for (local k = 0; k < 2; k++) {
				if (!this.SameEnd(line.ends[k], end[0], end[1])) continue;
				if (::TY.network.LinesAt(line.sids[k]).len() >= 3) continue;
				return {line = line, end = k, site = line.sites[k]};
			}
		}
		return null;
	}

	function UnlockSharing(end) {
		foreach (line in ::TY.network.Active()) {
			if (line.mode != MODE_RAIL || line.double_track || line.branch || line.note != "") continue;
			if (!this.SameEnd(line.ends[0], end[0], end[1]) && !this.SameEnd(line.ends[1], end[0], end[1])) continue;
			if (line.upgrade_failed != 0 && Util.Today() - line.upgrade_failed < 730) continue;
			line.note = "upgrade";
			Log.Info("PLAN", "no room for another terminal at " + this.EndName(end) + ": doubling " + line.Name() + " so new lines can share its station");
			return true;
		}
		return false;
	}

	function SiteFor(end, cargo, producing, toward, L, rt, join, reserved) {
		if (end[0] == END_TOWN) return ::TY.rail.FindSite(end[1], toward, L, rt, join, reserved, cargo);
		return ::TY.rail.FindIndustrySite(end[1], cargo, producing, toward, L, rt, join, reserved);
	}

	function BuildRail(c) {
		local sa = this.SharedRailEnd(c.ends[0], c.cargo), sb = this.SharedRailEnd(c.ends[1], c.cargo);
		if (sa != null || sb != null) {
			if (this.BuildRailShared(c, sa, sb)) return true;
			Log.Info("PLAN", "sharing an existing station did not work out; trying separate terminals");
		}
		local plan = c.best.plan;
		local L = this.PlatformLength();
		local rt = plan.railtype;
		AIRail.SetCurrentRailType(rt);
		local la = this.EndCenter(c.ends[0]), lb = this.EndCenter(c.ends[1]);
		if (this.NoSite(c.ends[0]) || this.NoSite(c.ends[1])) return false;
		local site_a = this.SiteFor(c.ends[0], c.cargo, true, lb, L, rt, this.JoinId(c.ends[0]), null);
		if (site_a == null && L > 3) site_a = this.SiteFor(c.ends[0], c.cargo, true, lb, L - 2 < 3 ? 3 : L - 2, rt, this.JoinId(c.ends[0]), null);
		if (site_a == null) {
			Log.Warn("PLAN", "no rail station site at " + this.EndName(c.ends[0]));
			this.no_site[::TY.network.EndKey(c.ends[0][0], c.ends[0][1])] <- Util.Today();
			this.UnlockSharing(c.ends[0]);
			return false;
		}
		local reserved = {};
		foreach (t in ::TY.rail.Footprint(site_a)) reserved[t] <- true;
		L = site_a.L;
		local site_b = this.SiteFor(c.ends[1], c.cargo, false, site_a.O, L, rt, this.JoinId(c.ends[1]), reserved);
		if (site_b == null && L > 3) site_b = this.SiteFor(c.ends[1], c.cargo, false, site_a.O, L - 2 < 3 ? 3 : L - 2, rt, this.JoinId(c.ends[1]), reserved);
		if (site_b == null) {
			Log.Warn("PLAN", "no rail station site at " + this.EndName(c.ends[1]));
			this.no_site[::TY.network.EndKey(c.ends[1][0], c.ends[1][1])] <- Util.Today();
			this.UnlockSharing(c.ends[1]);
			return false;
		}
		if (!::TY.finance.Ensure(c.first_cost.tointeger())) return false;
		if (!::TY.rail.BuildStation(site_a, this.JoinId(c.ends[0]))) { this.Demolish(::TY.rail.Footprint(site_a)); return false; }
		if (!::TY.rail.BuildStation(site_b, this.JoinId(c.ends[1]))) {
			this.Demolish(::TY.rail.Footprint(site_a));
			this.Demolish(::TY.rail.Footprint(site_b));
			return false;
		}
		foreach (site in [site_a, site_b]) foreach (row in [0, 1]) ::TY.rail.ReserveCorridor(site, row);
		::TY.rail.UsePlaceholders([site_a, site_b]);
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::TY.network.ReservedRail()) forbidden[t] <- true;
		delete forbidden[::TY.rail.T(site_a, 0, -4)];
		delete forbidden[::TY.rail.T(site_b, 1, -4)];
		if (::TY.rail.T(site_a, 0, -5) in forbidden) delete forbidden[::TY.rail.T(site_a, 0, -5)];
		if (::TY.rail.T(site_b, 1, -5) in forbidden) delete forbidden[::TY.rail.T(site_b, 1, -5)];
		foreach (t in ::TY.rail.OtherCorridor(site_a, 1)) forbidden[t] <- true;
		foreach (t in ::TY.rail.OtherCorridor(site_b, 0)) forbidden[t] <- true;
		local p1 = ::TY.rail.BuildTrack(site_a, site_b, forbidden, null, rt);
		if (p1 == null || ::TY.rail.Verify(p1) >= 0) {
			Log.Warn("PLAN", "no railway " + this.EndName(c.ends[0]) + " - " + this.EndName(c.ends[1]));
			if (::TY.rail.trapped) ::TY.rail.bad_sites[site_a.O] <- Util.Today();
			if (::TY.rail.trapped_goal) ::TY.rail.bad_sites[site_b.O] <- Util.Today();
			if (p1 != null) ::TY.rail.RemovePath(p1, p1.len() - 1);
			foreach (site in [site_a, site_b]) foreach (row in [0, 1]) ::TY.rail.FreeCorridor(site, row);
			this.Demolish(::TY.rail.Footprint(site_a));
			this.Demolish(::TY.rail.Footprint(site_b));
			return false;
		}
		/* the platforms may be shorter than planned: the train is chosen for the shorter end */
		L = min(site_a.L, site_b.L);
		local exact = ::TY.engines.BestTrain(c.cargo, L, c.dist * 1.2, c.dist, c.demand, rt, site_a.depot, 1);
		if (exact != null) plan = exact.plan;
		else if (plan.wagons * ::TY.engines.LengthOf(plan.wagon == null ? plan.loco : plan.wagon) + ::TY.engines.LengthOf(plan.loco) > L * 16) {
			local p2 = ::TY.engines.PlanTrain(plan.loco, L, c.cargo, rt);
			if (p2 != null) plan = p2;
		}
		local line = Line();
		line.mode = MODE_RAIL;
		line.cargo = c.cargo;
		line.ends = c.ends;
		line.towns = c.towns;
		line.sids = [site_a.sid, site_b.sid];
		line.tiles = [::TY.rail.T(site_a, 0, 0), ::TY.rail.T(site_b, 0, 0)];
		line.depots = [site_a.depot, site_b.depot];
		line.engine = plan.loco;
		line.wagon = plan.wagon == null ? -1 : plan.wagon;
		line.wagons = plan.wagons;
		line.railtype = rt;
		line.sites = [site_a, site_b];
		line.p1 = this.Encode(p1);
		line.track_tiles = ::TY.rail.PathTiles(p1);
		line.capacity = plan.capacity;
		line.speed = plan.speed;
		line.dist = AIMap.DistanceManhattan(line.tiles[0], line.tiles[1]);
		line.path_len = this.PathLength(p1) + 2 * L;
		line.est_rtt = ::TY.time.RoundTrip(MODE_RAIL, line.speed, line.path_len, line.capacity);
		::TY.network.Add(line);
		this.RegisterStation(c.ends[0], site_a.sid, MODE_RAIL);
		this.RegisterStation(c.ends[1], site_b.sid, MODE_RAIL);
		if (::TY.levels.early_double && ::TY.finance.Cash() - ::TY.finance.Reserve() > 3 * c.first_cost + 500000) this.UpgradeRail(line);
		local v = ::TY.fleet.BuildFor(line, 0);
		Log.Info("BUILD", line.Name() + " opened: " + p1.len() + " track tiles, " + AIRail.GetName(rt) + ", " +
			AIEngine.GetName(plan.loco) + (plan.wagons > 0 ? " + " + plan.wagons + " x " + AIEngine.GetName(plan.wagon) : "") +
			", " + plan.capacity + " units, " + plan.speed + " km/h, " +
			(line.double_track ? "double track with path signals" : "one train (single track, no signals needed)") +
			(v < 0 ? " - first train failed" : ""));
		if (v < 0) ::TY.fleet.Repick(line);
		return true;
	}

	function BuildRailShared(c, sa, sb) {
		local base = sa != null ? sa.line : sb.line;
		local rt = base.railtype;
		if (sa != null && sb != null && sa.line.railtype != sb.line.railtype) return false;
		local L = sa != null ? sa.site.L : sb.site.L;
		if (sa != null && sb != null) L = min(sa.site.L, sb.site.L);
		local tiles = c.dist * 1.2;
		local best = ::TY.engines.BestTrain(c.cargo, L, tiles, c.dist, c.demand, rt, (sa != null ? sa : sb).site.depot);
		if (best == null) return false;
		local la = this.EndCenter(c.ends[0]), lb = this.EndCenter(c.ends[1]);
		local site_a = sa != null ? sa.site : null, site_b = sb != null ? sb.site : null;
		local reserved = {};
		if (site_a == null) {
			site_a = this.SiteFor(c.ends[0], c.cargo, true, site_b != null ? site_b.O : lb, L, rt, this.JoinId(c.ends[0]), null);
			if (site_a == null) return false;
		}
		foreach (t in ::TY.rail.Footprint(site_a)) reserved[t] <- true;
		if (site_b == null) {
			site_b = this.SiteFor(c.ends[1], c.cargo, false, site_a.O, L, rt, this.JoinId(c.ends[1]), reserved);
			if (site_b == null) return false;
		}
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::TY.network.ReservedRail()) forbidden[t] <- true;
		local start1 = null, goal1 = null, start2 = null, goal2 = null;
		if (sa != null) {
			local pa = ::TY.rail.StationPaths(sa.line, sa.end);
			start1 = ::TY.rail.BranchPoint(pa.dep, forbidden);
			goal2 = ::TY.rail.MergePoint(pa.arr, forbidden);
			if (start1 == null || goal2 == null) { Log.Info("PLAN", "no junction site on " + sa.line.Name()); return false; }
		}
		if (sb != null) {
			local pb = ::TY.rail.StationPaths(sb.line, sb.end);
			start2 = ::TY.rail.BranchPoint(pb.dep, forbidden);
			goal1 = ::TY.rail.MergePoint(pb.arr, forbidden);
			if (start2 == null || goal1 == null) { Log.Info("PLAN", "no junction site on " + sb.line.Name()); return false; }
		}
		local cost = AIRail.GetBuildCost(rt, AIRail.BT_TRACK) * tiles * 2.6 + best.plan.price * 2 + 30000;
		if (!::TY.finance.Ensure(cost.tointeger())) return false;
		local new_a = sa == null, new_b = sb == null;
		if (new_a && !::TY.rail.BuildStation(site_a, this.JoinId(c.ends[0]))) { this.Demolish(::TY.rail.Footprint(site_a)); return false; }
		if (new_b && !::TY.rail.BuildStation(site_b, this.JoinId(c.ends[1]))) {
			if (new_a) this.Demolish(::TY.rail.Footprint(site_a));
			this.Demolish(::TY.rail.Footprint(site_b));
			return false;
		}
		local fresh = [];
		if (new_a) fresh.append(site_a);
		if (new_b) fresh.append(site_b);
		foreach (site in fresh) foreach (row in [0, 1]) ::TY.rail.ReserveCorridor(site, row);
		::TY.rail.UsePlaceholders(fresh);
		if (start1 == null) start1 = ::TY.rail.TerminusStart(site_a);
		if (goal1 == null) goal1 = ::TY.rail.TerminusGoal(site_b);
		if (start2 == null) start2 = ::TY.rail.TerminusStart(site_b);
		if (goal2 == null) goal2 = ::TY.rail.TerminusGoal(site_a);
		foreach (t in [start1.tile, goal1.tile, start2.tile, goal2.tile]) if (t in forbidden) delete forbidden[t];
		foreach (pair in [[new_a, site_a], [new_b, site_b]]) {
			if (!pair[0]) continue;
			foreach (row in [0, 1]) foreach (k in [-4, -5]) {
				local t = ::TY.rail.T(pair[1], row, k);
				if (t in forbidden) delete forbidden[t];
			}
		}
		local f1 = {};
		foreach (t, v in forbidden) f1[t] <- v;
		if (new_a) foreach (t in ::TY.rail.OtherCorridor(site_a, 1)) f1[t] <- true;
		if (new_b) foreach (t in ::TY.rail.OtherCorridor(site_b, 0)) f1[t] <- true;
		if (start2.sw != null) f1[start2.tile] <- true;
		if (goal2.merge != null) f1[goal2.merge[0]] <- true;
		local p1 = ::TY.rail.BuildTrackSpec(start1, goal1, f1, null, rt);
		local fail = p1 == null || ::TY.rail.Verify(p1) >= 0;
		local p2 = null;
		if (!fail) {
			local f2 = {};
			foreach (t, v in forbidden) f2[t] <- v;
			local prefer = {};
			foreach (t in ::TY.rail.PathTiles(p1)) {
				f2[t] <- true;
				for (local d = 0; d < 4; d++) prefer[t + Geo.Offset(d)] <- true;
			}
			p2 = ::TY.rail.BuildTrackSpec(start2, goal2, f2, prefer, rt);
			fail = p2 == null || ::TY.rail.Verify(p2) >= 0;
		}
		if (fail) {
			Log.Warn("PLAN", "no railway " + this.EndName(c.ends[0]) + " - " + this.EndName(c.ends[1]) + " through the shared station");
			if (::TY.rail.trapped || ::TY.rail.trapped_goal) {
				if (new_a) ::TY.rail.bad_sites[site_a.O] <- Util.Today();
				if (new_b) ::TY.rail.bad_sites[site_b.O] <- Util.Today();
			}
			foreach (p in [p1, p2]) {
				if (p == null) continue;
				::TY.rail.RemovePath(p, p.len() - 1);
				if (p.len() > 1 && p[0].tile != start1.tile && p[0].tile != start2.tile) AIRail.RemoveRail(p[0].tile, p[0].tile, p[1].tile);
			}
			if (start1.sw != null) AIRail.RemoveRail(start1.sw[0], start1.sw[1], start1.sw[2]);
			if (start2.sw != null) AIRail.RemoveRail(start2.sw[0], start2.sw[1], start2.sw[2]);
			if (goal1.merge != null) AIRail.RemoveRail(goal1.merge[0], goal1.merge[1], goal1.merge[2]);
			if (goal2.merge != null) AIRail.RemoveRail(goal2.merge[0], goal2.merge[1], goal2.merge[2]);
			foreach (site in fresh) foreach (row in [0, 1]) ::TY.rail.FreeCorridor(site, row);
			if (new_a) this.Demolish(::TY.rail.Footprint(site_a));
			if (new_b) this.Demolish(::TY.rail.Footprint(site_b));
			return false;
		}
		local n1 = ::TY.rail.SignalPath(p1, rt), n2 = ::TY.rail.SignalPath(p2, rt);
		if (new_a) ::TY.rail.BuildThroatSignals(site_a);
		if (new_b) ::TY.rail.BuildThroatSignals(site_b);
		local line = Line();
		line.mode = MODE_RAIL;
		line.cargo = c.cargo;
		line.branch = true;
		line.ends = c.ends;
		line.towns = c.towns;
		line.sids = [site_a.sid, site_b.sid];
		line.tiles = [::TY.rail.T(site_a, 0, 0), ::TY.rail.T(site_b, 0, 0)];
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
		line.track_tiles = ::TY.rail.PathTiles(p1);
		line.track_tiles.extend(::TY.rail.PathTiles(p2));
		line.capacity = best.plan.capacity;
		line.speed = best.plan.speed;
		line.dist = AIMap.DistanceManhattan(line.tiles[0], line.tiles[1]);
		line.path_len = this.PathLength(p1) + 2 * L;
		line.est_rtt = ::TY.time.RoundTrip(MODE_RAIL, line.speed, line.path_len, line.capacity);
		::TY.network.Add(line);
		if (new_a) this.RegisterStation(c.ends[0], site_a.sid, MODE_RAIL);
		if (new_b) this.RegisterStation(c.ends[1], site_b.sid, MODE_RAIL);
		::TY.fleet.BuildFor(line, 0);
		if (!line.IsFreight()) ::TY.fleet.BuildFor(line, 1);
		Log.Info("BUILD", line.Name() + " opened sharing " + (sa != null ? AIStation.GetName(site_a.sid) : "") +
			(sa != null && sb != null ? " and " : "") + (sb != null ? AIStation.GetName(site_b.sid) : "") + ": " + p1.len() + " + " + p2.len() +
			" track tiles with " + n1 + " + " + n2 + " one-way path signals, " + AIEngine.GetName(best.plan.loco) + ", " + best.plan.capacity + " units");
		return true;
	}

	function Footprints(site_a, site_b) {
		local t = {};
		foreach (x in ::TY.rail.Footprint(site_a)) t[x] <- true;
		foreach (x in ::TY.rail.Footprint(site_b)) t[x] <- true;
		return t;
	}

	/* Remove what we built on these tiles (rail station tiles one by one: a joined station keeps its other platforms). */
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

	function UpgradeRail(line) {
		local site_a = line.sites[0], site_b = line.sites[1];
		local rt = line.railtype;
		local p1 = this.Decode(line.p1);
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::TY.network.ReservedRail()) forbidden[t] <- true;
		foreach (t in [::TY.rail.T(site_b, 0, -4), ::TY.rail.T(site_a, 1, -4), ::TY.rail.T(site_b, 0, -5), ::TY.rail.T(site_a, 1, -5)]) {
			if (t in forbidden) delete forbidden[t];
		}
		local prefer = {};
		foreach (t in ::TY.rail.PathTiles(p1)) {
			forbidden[t] <- true;
			for (local d = 0; d < 4; d++) prefer[t + Geo.Offset(d)] <- true;
		}
		if (!::TY.finance.Ensure(this.UpgradeCost(line).tointeger())) return false;
		Log.Info("PLAN", line.Name() + ": laying the second track");
		::TY.rail.UsePlaceholders([site_a, site_b]);
		local p2 = ::TY.rail.BuildTrack(site_b, site_a, forbidden, prefer, rt);
		if (p2 == null || ::TY.rail.Verify(p2) >= 0) {
			Log.Warn("PLAN", line.Name() + ": no route for a second track; stays a single-train line for now");
			if (p2 != null) ::TY.rail.RemovePath(p2, p2.len() - 1);
			::TY.rail.ReserveCorridor(site_a, 1);
			::TY.rail.ReserveCorridor(site_b, 0);
			line.note = "";
			line.upgrade_failed = Util.Today();
			return false;
		}
		line.track_tiles.extend(::TY.rail.PathTiles(p2));
		line.p2 = this.Encode(p2);
		return this.InstallSignals(line, p2);
	}

	function InstallSignals(line, p2) {
		local site_a = line.sites[0], site_b = line.sites[1];
		local rt = line.railtype;
		local p1 = this.Decode(line.p1);
		if (!this.ParkTrains(line)) {
			Log.Warn("SAFETY", line.Name() + ": trains did not reach the depot; signals postponed");
			this.RestartTrains(line);
			line.note = "signals";
			return false;
		}
		local n1 = ::TY.rail.SignalPath(p1, rt), n2 = ::TY.rail.SignalPath(p2, rt);
		::TY.rail.BuildThroatSignals(site_a);
		::TY.rail.BuildThroatSignals(site_b);
		line.double_track = true;
		line.signal_blocks = min(n1, n2);
		line.note = "";
		this.RestartTrains(line);
		Log.Info("BUILD", line.Name() + ": double track with " + n1 + " + " + n2 + " one-way path signals; up to " +
			::TY.fleet.MaxVehicles(line) + " trains");
		::TY.fleet.BuildFor(line, line.IsFreight() ? 0 : 1);
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
			if (v in ::TY.fleet.to_sell) continue;
			if (AIVehicle.IsStoppedInDepot(v)) AIVehicle.StartStopVehicle(v);
			else if (AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);
		}
	}

	function CheckTracks(line) {
		if (line.last_check > 0 && Util.Today() - line.last_check < 30) return;
		line.last_check = Util.Today();
		foreach (name, enc in {p1 = line.p1, p2 = line.p2}) {
			if (enc.len() == 0) continue;
			local p = this.Decode(enc);
			local bad = ::TY.rail.Verify(p);
			if (bad >= 0) {
				Log.Error("FLEET", line.Name() + ": track " + name + " broken at " + Util.TileStr(p[bad].tile) + " (index " + bad + " of " + p.len() + ")");
			}
		}
	}

	/* A town built a road across our track. Remove the road piece on the crossing and give the road a bridge. */
	function FixCrossings(line) {
		foreach (t in line.track_tiles) {
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
			Log.Warn("SAFETY", line.Name() + ": level crossing at " + Util.TileStr(t) + (done ? " removed" +
				(bridged ? "; the road now crosses on a bridge" : "") : " could not be removed (" + AIError.GetLastErrorString() + ")"));
		}
	}

	function BridgeTownRoad(t, d) {
		local off = Geo.Offset(d);
		local a = t - off, b = t + off;
		while (AIRail.IsRailTile(a) && AIMap.DistanceManhattan(a, t) < 6) a -= off;
		while (AIRail.IsRailTile(b) && AIMap.DistanceManhattan(b, t) < 6) b += off;
		foreach (h in [a, b]) {
			local road = AIRoad.IsRoadTile(h) && !AIRoad.IsRoadStationTile(h) && !AIRoad.IsDriveThroughRoadStationTile(h) && !AIRoad.IsRoadDepotTile(h);
			if (AIRail.IsRailTile(h) || AIBridge.IsBridgeTile(h) || AITunnel.IsTunnelTile(h) || (!AITile.IsBuildable(h) && !road)) return false;
		}
		local br = ::TY.rail.bridges.Fastest(AIMap.DistanceManhattan(a, b) + 1);
		if (br < 0) return false;
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		local ok;
		{
			local tm = AITestMode();
			ok = AIBridge.BuildBridge(AIVehicle.VT_ROAD, br, a, b);
		}
		if (ok && ::TY.finance.Ensure(AIBridge.GetPrice(br, AIMap.DistanceManhattan(a, b) + 1) + 20000) &&
				AIBridge.BuildBridge(AIVehicle.VT_ROAD, br, a, b)) {
			foreach (pair in [[a, a - off], [b, b + off]]) {
				if (AIRoad.IsRoadTile(pair[1]) && !AIRoad.AreRoadTilesConnected(pair[0], pair[1])) AIRoad.BuildRoad(pair[0], pair[1]);
			}
			return true;
		}
		return false;
	}

	/* ---------------- interchanges ---------------- */

	function Interchanges() {
		if (!::TY.game.allow[MODE_ROAD]) return false;
		foreach (town, hub in ::TY.network.hubs) {
			if (AIStation.IsValidStation(hub.air_sid) && AIStation.IsValidStation(hub.sid) && hub.air_sid != hub.sid && !hub.shuttle) {
				hub.shuttle = true;
				if (this.BuildShuttle(town, hub.sid, hub.air_sid)) return true;
			}
			if (AIStation.IsValidStation(hub.sid) && hub.catchment < 2 && AITown.GetPopulation(town) > 700 &&
					(hub.rail > 0 || hub.sid == hub.air_sid)) {
				local loc = AIStation.GetLocation(hub.sid);
				::TY.road.Use(AIRoad.ROADTYPE_ROAD);
				local spot = ::TY.road.FindStop(AITown.GetLocation(town), 6, hub.sid, Util.pax, null, loc, 5);
				if (spot != null && ::TY.road.BuildStop(spot, hub.sid) >= 0) {
					hub.catchment++;
					Log.Info("BUILD", "walk-in stop for " + AIStation.GetName(hub.sid) + " at " + Util.TileStr(spot.tile) + " (extends the hub's catchment)");
					return true;
				}
				hub.catchment = 99;
			}
		}
		return false;
	}

	/* Bus shuttle between two stations of one town so CargoDist can route through both. */
	function BuildShuttle(town, sid1, sid2) {
		::TY.road.Use(AIRoad.ROADTYPE_ROAD);
		local s1 = ::TY.road.FindStop(AIStation.GetLocation(sid1), 6, sid1, Util.pax);
		local s2 = ::TY.road.FindStop(AIStation.GetLocation(sid2), 7, sid2, Util.pax);
		if (s1 == null || s2 == null) return false;
		local d = AIMap.DistanceManhattan(s1.tile, s2.tile);
		local best = ::TY.engines.BestBus(d + 2, d, 100);
		if (best == null) return false;
		Log.Info("PLAN", "interchange shuttle " + AIStation.GetName(sid1) + " <-> " + AIStation.GetName(sid2));
		local c = {mode = MODE_ROAD, cargo = Util.pax, ends = [[END_TOWN, town], [END_TOWN, town]], towns = [town, town], key = "shuttle" + town};
		return this.BuildRoadLine(c, s1, s2, sid1, sid2, best.engine, true);
	}

	/* ---------------- station parts ---------------- */

	facilities_date = -10000;

	/*
	 * The "stations" component counts the facility parts (rail, bus, truck, airport, dock) of every station
	 * that loaded or unloaded in the last 50 days. A bus stop and a truck stop joined to a rail station or an
	 * airport count as two more parts for a few hundred pounds, without any vehicle calling at them: the
	 * station is served by its trains. Added while the component is short, one station per planner step.
	 */
	function AddFacilities() {
		if (!::TY.levels.score_aware || ::TY.score.Deficit(SCORE_STATIONS) <= 0) return false;
		if (!::TY.game.allow[MODE_ROAD] || Util.Today() - this.facilities_date < 20) return false;
		this.facilities_date = Util.Today();
		::TY.road.Use(AIRoad.ROADTYPE_ROAD);
		foreach (sid, _ in AIStationList(AIStation.STATION_ANY)) {
			if (!::TY.network.IsServed(sid)) continue;
			local want = [];
			if (!AIStation.HasStationType(sid, AIStation.STATION_BUS_STOP)) want.append(Util.pax);
			if (!AIStation.HasStationType(sid, AIStation.STATION_TRUCK_STOP) && Util.mail >= 0) want.append(Util.mail);
			if (want.len() == 0) continue;
			local tiles = AITileList_StationType(sid, AIStation.STATION_ANY);
			local around = AITileList();
			foreach (t, _ in tiles) {
				local x = Geo.X(t), y = Geo.Y(t);
				for (local dy = -2; dy <= 2; dy++) for (local dx = -2; dx <= 2; dx++) {
					local n = AIMap.GetTileIndex(x + dx, y + dy);
					if (Geo.InMap(n, 2) && !tiles.HasItem(n)) around.AddItem(n, 0);
				}
			}
			local built = 0;
			foreach (cargo in want) {
				local spot = null;
				/* a side street off an existing road first (vehicles and depots can reach it); a free stub only when there is none */
				for (local pass = 0; pass < 2 && spot == null; pass++) {
					foreach (t, _ in around) {
						if (!::TY.road.RoadSiteOk(t) || AIRoad.IsRoadTile(t)) continue;
						foreach (axis in [DIR_PX, DIR_PY]) {
							local a = t - Geo.Offset(axis), b = t + Geo.Offset(axis);
							if (!::TY.road.RoadSiteOk(a) || !::TY.road.RoadSiteOk(b)) continue;
							if (pass == 0 && !AIRoad.IsRoadTile(a) && !AIRoad.IsRoadTile(b)) continue;
							local ok;
							{
								local tm = AITestMode();
								ok = AIRoad.BuildRoad(a, b) && AIRoad.BuildDriveThroughRoadStation(t, b, ::TY.road.StopType(cargo), sid);
							}
							if (ok) { spot = {tile = t, axis = axis, cargo = cargo, own_road = true}; break; }
						}
						if (spot != null) break;
					}
				}
				if (spot == null) continue;
				if (!::TY.finance.Ensure(5000)) return built > 0;
				if (::TY.road.BuildStop(spot, sid) >= 0) { built++; around.RemoveItem(spot.tile); }
			}
			if (built > 0) {
				Log.Info("BUILD", built + " extra stop(s) joined to " + AIStation.GetName(sid) + " (station parts for the score)");
				return true;
			}
		}
		return false;
	}

	/* ---------------- events ---------------- */

	function OnIndustryClosed(ind) {
		::TY.industry.closed[ind] <- true;
		::TY.industry.dirty = true;
		foreach (line in ::TY.network.Active()) {
			if (this.SameEnd(line.ends[0], END_INDUSTRY, ind) || this.SameEnd(line.ends[1], END_INDUSTRY, ind)) {
				Log.Warn("PLAN", line.Name() + ": industry closed; line closed");
				::TY.fleet.Close(line, "industry closed");
			}
		}
	}

	function OnSubsidy(id) {
		if (!AISubsidy.IsValidSubsidy(id)) return;
		Log.Info("PLAN", "subsidy offered for " + Util.CargoName(AISubsidy.GetCargoType(id)));
	}
}
