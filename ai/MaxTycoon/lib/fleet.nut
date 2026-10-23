/*
 * Fleet: buys, sizes, renews, culls and withdraws vehicles.
 *
 * Orders: passengers never wait for a full load (they would age in the vehicle and the others would wait
 * longer); freight waits for a full load at the source (a vehicle always loading keeps the station rating near
 * its maximum, so the industry sends almost everything to us) and unloads without loading at the sink.
 * Sizing: a line gets a vehicle when the planned or produced flow reaches 90% of its monthly capacity, or
 * cargo piles up, or the headway is longer than the target while the extra vehicle still runs reasonably full;
 * it loses one when the flow stays low for two months.
 * Culling (the score): a vehicle over two years old must earn 10,000 a year or it drags the "minimum profit"
 * component to zero; such vehicles are sold, or replaced by a new one (which has no age) when the line needs
 * the capacity.
 */

class Fleet {
	to_sell = null;      // vehicle -> reason
	sell_since = null;   // vehicle -> date it was first sent to a depot to be sold
	loads = null;        // vehicle -> last cargo load seen (delivery counting)

	constructor() {
		this.to_sell = {};
		this.sell_since = {};
		this.loads = {};
	}

	/* ---------------- building ---------------- */

	function BuildBasic(depot, engine, cargo) {
		local v;
		if (AIEngine.GetCargoType(engine) != cargo && AIEngine.CanRefitCargo(engine, cargo)) {
			v = AIVehicle.BuildVehicleWithRefit(depot, engine, cargo);
		} else {
			v = AIVehicle.BuildVehicle(depot, engine);
		}
		if (!AIVehicle.IsValidVehicle(v)) return -1;
		::TY.engines.cap_cache[engine + ":" + cargo] <- AIVehicle.GetCapacity(v, cargo);
		return v;
	}

	function BuildTrain(line, depot) {
		local loco = this.BuildBasic(depot, line.engine, line.cargo);
		if (loco < 0) return -1;
		local max_len = line.sites[0].L * 16;
		local base_len = AIVehicle.GetLength(loco);
		::TY.engines.length_cache[line.engine] <- base_len;
		if (base_len > max_len) {
			Log.Warn("FLEET", AIEngine.GetName(line.engine) + " is " + base_len + "/16 tiles, platforms take " + max_len);
			AIVehicle.SellVehicle(loco);
			return -1;
		}
		for (local i = 0; i < line.wagons && line.wagon >= 0; i++) {
			local w = this.BuildBasic(depot, line.wagon, line.cargo);
			if (w < 0) break;
			local before = AIVehicle.GetLength(loco);
			if (!AIVehicle.MoveWagon(w, 0, loco, 0)) {
				Log.Warn("FLEET", AIEngine.GetName(line.wagon) + " cannot be coupled to " + AIEngine.GetName(line.engine) + ": " + AIError.GetLastErrorString());
				::TY.engines.bad_pairs[line.engine + ":" + line.wagon] <- true;
				AIVehicle.SellVehicle(w);
				break;
			}
			local after = AIVehicle.GetLength(loco);
			::TY.engines.length_cache[line.wagon] <- after - before;
			::TY.engines.probed[::TY.engines.PairKey(line.engine, line.wagon)] <- true;
			if (after > max_len) {
				AIVehicle.SellWagon(loco, AIVehicle.GetNumWagons(loco) - 1);
				break;
			}
		}
		if (AIVehicle.GetCapacity(loco, line.cargo) <= 0) {
			AIVehicle.SellVehicle(loco);
			return -1;
		}
		return loco;
	}

	/*
	 * Orders. Aircraft: A, B. Ships: no non-stop flags (the game refuses them), depots as "service if needed".
	 * Road and rail: non-stop, with "service if needed" depot orders in front of each station. Freight: full
	 * load at A, unload and leave empty at B. Loops: every stop in turn, then the depot.
	 */
	function SetOrders(line, v) {
		local ns = line.mode == MODE_ROAD || line.mode == MODE_RAIL ? AIOrder.OF_NON_STOP_INTERMEDIATE : AIOrder.OF_NONE;
		local svc = AIOrder.OF_SERVICE_IF_NEEDED | ns;
		if (line.loop) {
			local ok = true;
			foreach (t in line.stops) ok = ok && AIOrder.AppendOrder(v, t, ns);
			if (ok && line.depots[0] >= 0) ok = AIOrder.AppendOrder(v, line.depots[0], svc);
			return ok;
		}
		if (line.mode == MODE_AIR) {
			return AIOrder.AppendOrder(v, line.tiles[0], AIOrder.OF_NONE) && AIOrder.AppendOrder(v, line.tiles[1], AIOrder.OF_NONE);
		}
		local load_a = ns, load_b = ns;
		if (line.IsFreight()) {
			load_a = ns | AIOrder.OF_FULL_LOAD_ANY;
			load_b = ns | AIOrder.OF_UNLOAD | AIOrder.OF_NO_LOAD;
		}
		local ok = AIOrder.AppendOrder(v, line.tiles[0], load_a);
		/* ships steer by the route's buoys, one leg at a time */
		if (line.mode == MODE_WATER) foreach (b in line.buoys) ok = ok && AIOrder.AppendOrder(v, b, AIOrder.OF_NONE);
		if (ok && line.depots[1] >= 0) ok = AIOrder.AppendOrder(v, line.depots[1], svc);
		ok = ok && AIOrder.AppendOrder(v, line.tiles[1], load_b);
		if (line.mode == MODE_WATER) for (local i = line.buoys.len() - 1; i >= 0; i--) ok = ok && AIOrder.AppendOrder(v, line.buoys[i], AIOrder.OF_NONE);
		if (ok && line.depots[0] >= 0) ok = AIOrder.AppendOrder(v, line.depots[0], svc);
		return ok;
	}

	/* Index of the order for station B. */
	function OrderB(v) {
		for (local i = 1; i < AIOrder.GetOrderCount(v); i++) if (AIOrder.IsGotoStationOrder(v, i)) return i;
		return 1;
	}

	/* Build one vehicle at end 0 or 1 of a line and send it into service. Returns the vehicle or -1. */
	function BuildFor(line, end) {
		if (line.mode == MODE_RAIL && line.VehicleCount() >= ::TY.safety.MaxTrains(line)) {
			::TY.safety.Veto("train beyond the limit of the signalling", "" + line.id);
			return -1;
		}
		if (this.TotalVehicles() >= ::TY.levels.vehicle_cap) return -1;
		local depot = line.depots[end];
		if (depot < 0) { end = 1 - end; depot = line.depots[end]; }
		if (depot < 0) return -1;
		local price = AIEngine.GetPrice(line.engine) + (line.wagon >= 0 ? line.wagons * AIEngine.GetPrice(line.wagon) : 0);
		if (!::TY.finance.Ensure(price)) return -1;
		if (!AIEngine.IsBuildable(line.engine)) this.Repick(line);
		local v = line.mode == MODE_RAIL ? this.BuildTrain(line, depot) : this.BuildBasic(depot, line.engine, line.cargo);
		if (v < 0) {
			Log.Warn("FLEET", "could not build a vehicle for " + line.Name() + ": " + AIError.GetLastErrorString());
			return -1;
		}
		local existing = -1;
		foreach (o, _ in line.Vehicles()) { if (o != v && !(o in this.to_sell)) { existing = o; break; } }
		local ok = existing >= 0 ? AIOrder.ShareOrders(v, existing) : this.SetOrders(line, v);
		if (!ok) {
			Log.Warn("FLEET", "orders for " + line.Name() + " failed: " + AIError.GetLastErrorString());
			AIVehicle.SellVehicle(v);
			return -1;
		}
		if (end == 1 && !line.loop) AIOrder.SkipToOrder(v, this.OrderB(v));
		if (line.loop && existing >= 0) AIOrder.SkipToOrder(v, Util.Rand(max(1, line.stops.len())));
		AIGroup.MoveVehicle(line.group, v);
		if (line.capacity <= 0) line.capacity = AIVehicle.GetCapacity(v, line.cargo);
		AIVehicle.StartStopVehicle(v);
		line.last_change = Util.Today();
		return v;
	}

	function TotalVehicles() { return AIVehicleList().Count(); }

	/* Best current model of the line's class (its engine is no longer sold, or a yearly review). */
	function BestFor(line) {
		local demand = line.IsFreight() ? 150 : 100;
		if (line.mode == MODE_ROAD) return ::TY.engines.BestRoadVehicle(line.cargo, line.roadtype >= 0 ? line.roadtype : AIRoad.ROADTYPE_ROAD, line.path_len, line.dist, demand);
		if (line.mode == MODE_AIR) {
			return ::TY.engines.BestAircraft(line.cargo, line.tiles[0], line.tiles[1], AIAirport.GetAirportType(line.tiles[0]),
				AIAirport.GetAirportType(line.tiles[1]), 150);
		}
		if (line.mode == MODE_WATER) return ::TY.engines.BestShip(line.cargo, line.path_len, line.dist, demand);
		return ::TY.engines.BestTrain(line.cargo, line.sites[0].L, line.path_len, line.dist, 150, line.railtype, line.depots[0], line.double_track ? 0 : 1);
	}

	function Repick(line) {
		local best = this.BestFor(line);
		if (best != null) {
			if (line.mode == MODE_RAIL) { line.wagon = best.plan.wagon == null ? -1 : best.plan.wagon; line.wagons = best.plan.wagons; }
			Log.Info("FLEET", line.Name() + ": engine now " + AIEngine.GetName(best.engine));
			line.engine = best.engine;
			line.capacity = best.capacity;
		}
	}

	/* ---------------- withdrawing ---------------- */

	function Withdraw(v, reason) {
		if (!AIVehicle.IsValidVehicle(v) || (v in this.to_sell)) return;
		this.to_sell[v] <- reason;
		if (!AIVehicle.IsStoppedInDepot(v) && !AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);
		Log.Info("FLEET", "withdrawing " + AIVehicle.GetName(v) + ": " + reason);
	}

	function TrimTo(line, n, reason) {
		local keep = 0;
		foreach (v, _ in line.Vehicles()) {
			if (v in this.to_sell) continue;
			if (keep < n) { keep++; continue; }
			this.Withdraw(v, reason);
		}
	}

	function ActiveCount(line) {
		local n = 0;
		foreach (v, _ in line.Vehicles()) if (!(v in this.to_sell)) n++;
		return n;
	}

	function SellParked() {
		local keys = [];
		foreach (v, _ in this.to_sell) keys.append(v);
		foreach (v in keys) {
			if (!AIVehicle.IsValidVehicle(v)) { delete this.to_sell[v]; if (v in this.sell_since) delete this.sell_since[v]; continue; }
			if (AIVehicle.IsStoppedInDepot(v)) {
				AIVehicle.SellVehicle(v);
				if (!AIVehicle.IsValidVehicle(v)) { delete this.to_sell[v]; if (v in this.sell_since) delete this.sell_since[v]; }
				continue;
			}
			if (!(v in this.sell_since)) this.sell_since[v] <- Util.Today();
			/* a road vehicle that cannot reach any depot gets one next to it: a vehicle that cannot be sold would
			 * drag the minimum-profit component to zero for as long as it lives */
			if (Util.Today() - this.sell_since[v] > 90 && AIVehicle.GetVehicleType(v) == AIVehicle.VT_ROAD) {
				::TY.road.Use(AIRoad.ROADTYPE_ROAD);
				local loc = AIVehicle.GetLocation(v);
				local d = ::TY.road.BuildDepotNear(loc, 5);
				if (d >= 0) Log.Info("FLEET", "depot at " + Util.TileStr(d) + " for stranded " + AIVehicle.GetName(v));
				else if (::TY.road.ConnectToDepot(loc)) Log.Info("FLEET", "road mended to a depot for stranded " + AIVehicle.GetName(v));
				else Log.Warn("FLEET", AIVehicle.GetName(v) + " stranded at " + Util.TileStr(loc) + " (road " + AIRoad.IsRoadTile(loc) + ", stop " +
					AIRoad.IsRoadStationTile(loc) + ", depot " + AIRoad.IsRoadDepotTile(loc) + ", in depot " + AIVehicle.IsInDepot(v) + ", state " +
					AIVehicle.GetState(v) + "): no depot site and no road to one");
				if (AIController.GetSetting("debug") == 1) Util.DumpRoad(loc, 6);
				this.sell_since[v] <- Util.Today();
			}
			if (!AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);
		}
	}

	/* A vehicle that cannot find its way: road vehicles and ships are withdrawn, railways re-checked. */
	lost_count = null;   // line id -> lost events

	function OnLost(line, v) {
		if (line.state != LINE_ACTIVE) return;
		if (this.lost_count == null) this.lost_count = {};
		this.lost_count[line.id] <- ((line.id in this.lost_count) ? this.lost_count[line.id] : 0) + 1;
		if (AIController.GetSetting("debug") == 1) {
			if (line.mode == MODE_WATER) Util.DumpWater(AIVehicle.GetLocation(v), 7);
			if (line.mode == MODE_ROAD) {
				local dest = AIOrder.GetOrderDestination(v, AIOrder.ResolveOrderPosition(v, AIOrder.ORDER_CURRENT));
				Util.DumpRoad(AIMap.IsValidTile(dest) ? dest : AIVehicle.GetLocation(v), 6);
			}
		}
		if (line.mode == MODE_ROAD || line.mode == MODE_WATER) this.Withdraw(v, "lost");
		/* a road may have been flooded or cut: mend it (the fleet manager replaces the withdrawn vehicle) */
		if (line.mode == MODE_ROAD && this.Reconnect(line) == 1) { this.lost_count[line.id] = 0; return; }
		/* a route whose vehicles keep getting lost is wrong somewhere: close it rather than feed it vehicles */
		if (this.lost_count[line.id] >= 3 && line.mode != MODE_RAIL) {
			Log.Warn("FLEET", line.Name() + ": vehicles lost three times; line closed");
			this.Close(line, "vehicles lost");
		}
		if (line.mode == MODE_RAIL) ::TY.planner.CheckTracks(line);
	}

	/* Rebuild the missing pieces of a road line's route: 1 rebuilt, 0 the road was whole, -1 no route or build failed. */
	function Reconnect(line) {
		if (line.mode != MODE_ROAD || line.loop) return 0;
		local conn = ::TY.road.Connect(line.tiles[0], line.tiles[1]);
		if (conn == null) return -1;
		local pieces = ::TY.road.NewPieces(conn.path);
		if (pieces == 0) return 0;
		Log.Info("FLEET", line.Name() + ": road broken, rebuilding " + pieces + " pieces");
		return ::TY.road.BuildPath(conn.path) ? 1 : -1;
	}

	/* ---------------- sizing ---------------- */

	function MaxVehicles(line) {
		local rtt = fmax(4.0, line.Rtt());
		if (line.mode == MODE_RAIL) {
			if (!line.double_track) return 1;
			local by_platform = (rtt / 4.0).tointeger();
			return Util.Clamp(min(line.signal_blocks + 2, by_platform), 2, 30);
		}
		if (line.mode == MODE_AIR) {
			local t = min(::TY.air.Terminals(AIAirport.GetAirportType(line.tiles[0])), ::TY.air.Terminals(AIAirport.GetAirportType(line.tiles[1])));
			return Util.Clamp((t * rtt / 15).tointeger(), 2, 40);
		}
		if (line.mode == MODE_WATER) return Util.Clamp((rtt / 6).tointeger(), 2, 20);
		if (line.loop) return Util.Clamp((rtt / 4).tointeger(), 2, 4);
		/* road: what the flow fills to 60%, plus one */
		local s = ::TY.cdist.LineStats(line);
		local flow = max(s.plan_ab, s.plan_ba);
		local by_flow = line.capacity > 0 ? (flow * rtt / (30.0 * line.capacity * 0.6)).tointeger() + 1 : 2;
		return Util.Clamp(min((rtt / 3).tointeger(), by_flow), 2, line.IsFreight() ? 24 : 12);
	}

	/* Landings per month at an airport over all our air lines (runway and terminal load). */
	function AirportLoad(sid) {
		local load = 0.0;
		foreach (l in ::TY.network.LinesAt(sid)) {
			if (l.mode != MODE_AIR) continue;
			load += this.ActiveCount(l) * 30.0 / fmax(4.0, l.Rtt());
		}
		return load;
	}

	/* Share of the two platforms of a rail station that our trains occupy (dwell / round trip, all lines). */
	function RailStationLoad(sid) {
		local load = 0.0;
		foreach (l in ::TY.network.LinesAt(sid)) {
			if (l.mode != MODE_RAIL) continue;
			load += this.ActiveCount(l) * ::TY.time.StopDays(MODE_RAIL, l.capacity) / fmax(4.0, l.Rtt());
		}
		return load;
	}

	function CanAdd(line) {
		if (this.ActiveCount(line) >= this.MaxVehicles(line)) return false;
		if (line.mode == MODE_RAIL && line.VehicleCount() >= ::TY.safety.MaxTrains(line)) return false;
		if (line.mode == MODE_RAIL) {
			local extra = ::TY.time.StopDays(MODE_RAIL, line.capacity) / fmax(4.0, line.Rtt());
			foreach (sid in line.sids) if (this.RailStationLoad(sid) + extra > 1.3) return false;
		}
		if (line.mode == MODE_AIR) {
			foreach (i, sid in line.sids) {
				local t = ::TY.air.Terminals(AIAirport.GetAirportType(line.tiles[i]));
				if (this.AirportLoad(sid) + 30.0 / fmax(4.0, line.Rtt()) > t * 4.0) return false;
			}
		}
		local count = AIVehicleList();
		count.Valuate(AIVehicle.GetVehicleType);
		count.KeepValue(line.VehicleType());
		if (count.Count() >= ::TY.game.max_vehicles[line.mode]) return false;
		if (this.TotalVehicles() >= ::TY.levels.vehicle_cap) return false;
		return true;
	}

	function Update() {
		local hmax = ::TY.time.headway_max;
		local rich = ::TY.finance.Cash() - ::TY.finance.Reserve() > 1000000;
		local min_load = rich ? 0.25 : 0.4;
		local phase = ::TY.score.phase;
		foreach (line in ::TY.network.Active()) {
			local n = this.ActiveCount(line);
			if (n == 0) {
				this.BuildFor(line, 0);
				continue;
			}
			local s = ::TY.cdist.LineStats(line);
			local age = Util.Today() - line.created;
			local next_util = s.cap_month > 0 ? s.util * n / (n + 1.0) : 0.0;
			/* money per vehicle: a line whose vehicles earn little gets no more of them on account of waiting cargo */
			local per_vehicle = this.ProfitPerVehicle(line);
			local earning = age < 400 || per_vehicle > 4000;
			local more = s.util > 0.9 || (s.wait_ratio > 1.5 && earning) ||
				(s.headway > hmax[line.mode] && (s.util > 0.55 || s.wait_ratio > 0.8 || rich) && next_util > min_load && earning);
			/* with millions idle every vehicle that will pay is a point: fill lines to 50% */
			if (::TY.finance.Cash() > 2000000 && per_vehicle > 10000 && s.util > 0.5 && next_util > 0.35 && ::TY.score.phase != PHASE_HARVEST) more = true;
			/* the year before the ranking: every vehicle that earns anything in it is a point, up to 120 */
			if (phase == PHASE_PREPARE && AIDate.GetMonth(Util.Today()) <= 7 && this.TotalVehicles() < 128 &&
					per_vehicle > 2 * AIEngine.GetRunningCost(line.engine) && s.util > 0.45 && ::TY.finance.Cash() > 300000) more = true;
			if (!::TY.game.CargoDistOn(line.cargo) && !line.IsFreight() && s.rating_a >= 0 && s.rating_a < 45 && s.wait_ratio > 0.5 && earning) more = true;
			local less = n > 1 && age > 120 && ((s.util < 0.35 && s.wait_ratio < 0.3) || (age > 400 && per_vehicle < 2000 && s.util < 0.6));
			/* in the ending year a new vehicle earns no vehicle points: only clear shortfalls get one */
			if (phase == PHASE_HARVEST && !(s.util > 1.2 || s.wait_ratio > 3.0)) more = false;
			if (more) { line.hi++; line.lo = 0; }
			else if (less) { line.lo++; line.hi = 0; }
			else { line.hi = max(0, line.hi - 1); line.lo = max(0, line.lo - 1); }

			if (line.hi >= 2 && Util.Today() - line.last_change >= 20) {
				if (this.CanAdd(line)) {
					local need = 1;
					if (s.util > 1.2) need = max(need, (n * (s.util - 0.9)).tointeger());
					if (s.wait_ratio > 3.0) need = max(need, (s.wait_ratio / 3.0).tointeger());
					need = Util.Clamp(need, 1, 3);
					local added = 0;
					for (local k = 0; k < need && this.CanAdd(line); k++) {
						if (this.BuildFor(line, (n + k) % 2) < 0) break;
						added++;
					}
					if (added > 0) {
						Log.Info("FLEET", line.Name() + ": +" + added + " (" + (n + added) + " vehicles), util " + (s.util * 100).tointeger() +
							"%, waiting " + s.wait_ab + "/" + s.wait_ba + ", headway " + s.headway.tointeger() + " d");
					}
					line.hi = 0;
				} else if (line.mode == MODE_RAIL && !line.double_track &&
						(line.upgrade_failed == 0 || Util.Today() - line.upgrade_failed > 730)) {
					line.note = "upgrade";
				}
			}
			if (line.mode == MODE_RAIL && !line.double_track && line.note == "" && age > (rich ? 120 : 180) &&
					s.headway > (rich ? 1 : 2) * hmax[MODE_RAIL] && s.util > (rich ? 0.3 : 0.45) &&
					(line.upgrade_failed == 0 || Util.Today() - line.upgrade_failed > 730)) {
				line.note = "upgrade";
				Log.Info("FLEET", line.Name() + ": headway " + s.headway.tointeger() + " d with " + (s.util * 100).tointeger() +
					"% of the capacity planned; asking for a second track");
			}
			if (line.lo >= 4 && Util.Today() - line.last_change >= 60) {
				local worst = this.WorstVehicle(line);
				if (worst >= 0) {
					this.Withdraw(worst, line.Name() + " over capacity (util " + (s.util * 100).tointeger() + "%)");
					line.last_change = Util.Today();
				}
				line.lo = 0;
			}
		}
	}

	/* Profit per vehicle over the last twelve months (this year's so far plus the rest of last year). */
	function ProfitPerVehicle(line) {
		local n = 0, total = 0;
		local frac = (AIDate.GetMonth(Util.Today()) - 1) / 12.0;
		foreach (v, _ in line.Vehicles()) {
			if (v in this.to_sell) continue;
			n++;
			total += AIVehicle.GetProfitThisYear(v) + (AIVehicle.GetProfitLastYear(v) * (1.0 - frac)).tointeger();
		}
		return n == 0 ? 0 : total / n;
	}

	/* Oldest, least reliable vehicle of a line. */
	function WorstVehicle(line) {
		local worst = -1, worst_score = -1;
		foreach (v, _ in line.Vehicles()) {
			if (v in this.to_sell) continue;
			local score = AIVehicle.GetAge(v) - AIVehicle.GetReliability(v) * 10;
			if (score > worst_score) { worst_score = score; worst = v; }
		}
		return worst;
	}

	/* ---------------- the score: weak old vehicles ---------------- */

	/*
	 * Every quarter: a vehicle that is (or will soon be) over two years old and earned less than 10,000 last
	 * year pulls the "minimum profit" component to zero. If its line is otherwise worth running, it is replaced
	 * by a new vehicle (no age for two years); if the line has spare capacity it is simply sold; a line whose
	 * every vehicle loses money is closed. Only the score-aware levels do this.
	 */
	function Cull() {
		if (!::TY.levels.score_aware) return;
		local floor = ::TY.score.needed[SCORE_MIN_PROFIT];
		/* the ranking sees the profits of year Y-1 made by vehicles that are over two years old on 1 October Y:
		 * weak old vehicles matter from the last quarter of Y-2 on; before that only hopeless lines are closed */
		local left = ::TY.game.ending_year > 0 ? ::TY.game.YearsLeft() : 99;
		local decisive = left <= 1 || (left == 2 && AIDate.GetMonth(Util.Today()) >= 10);
		local horizon = decisive ? 540 : 100000;
		local sold = 0, replaced = 0, closed = 0;
		foreach (line in ::TY.network.Active()) {
			local total = 0, n = 0, weak = [];
			foreach (v, _ in line.Vehicles()) {
				if (v in this.to_sell) continue;
				n++;
				local p = AIVehicle.GetProfitLastYear(v);
				total += p;
				/* this year's profit so far, projected to the whole year; in the ending year only last year counts */
				local month = AIDate.GetMonth(Util.Today());
				local projected = month >= 4 ? AIVehicle.GetProfitThisYear(v) * 12 / month : max(p, AIVehicle.GetProfitThisYear(v) * 12 / month);
				local harvest = ::TY.score.phase == PHASE_HARVEST;
				/* after June of the ending year a swap would leave the line's stations unserved and its cargo
				 * undelivered in the quarter the ranking looks at */
				if (harvest && month >= 7) continue;
				/* in the ending year only vehicles over two years old on 1 October can hurt */
				local age_oct = AIVehicle.GetAge(v) + (harvest ? AIDate.GetDate(Util.Year(), 10, 1) - Util.Today() : 0);
				if (harvest && age_oct <= 730) continue;
				if (AIVehicle.GetAge(v) >= horizon && (p < floor || (!harvest && projected < floor * 11 / 10))) weak.append(v);
			}
			if (n > 0 && total < 0 && Util.Today() - line.created > 730 && !line.loop) {
				Log.Info("SCORE", line.Name() + ": every vehicle loses money; line closed");
				this.Close(line, "unprofitable");
				closed++;
				continue;
			}
			/* dead weight at any time: an old vehicle that earns nothing on a line with others */
			if (n > 1) {
				foreach (v, _ in line.Vehicles()) {
					if ((v in this.to_sell) || n <= 1) continue;
					if (AIVehicle.GetAge(v) > 730 && AIVehicle.GetProfitLastYear(v) < 1000 && AIVehicle.GetProfitThisYear(v) < 1000) {
						this.Withdraw(v, "earns nothing (" + Util.Money(AIVehicle.GetProfitLastYear(v)) + " last year)");
						n--;
						sold++;
					}
				}
			}
			foreach (v in weak) {
				local s = ::TY.cdist.LineStats(line);
				local price = AIEngine.GetPrice(line.engine) + (line.wagon >= 0 ? line.wagons * AIEngine.GetPrice(line.wagon) : 0);
				/* a new vehicle counts as profitable from its first month and is not checked for the floor until
				 * it is two years old: replace unless the line is over capacity or the vehicle loses money */
				local losing = AIVehicle.GetProfitLastYear(v) < 0 && AIVehicle.GetProfitThisYear(v) < 0;
				if ((n > 1 && s.util < 0.4) || losing || price > 80000) {
					this.Withdraw(v, "profit " + Util.Money(AIVehicle.GetProfitLastYear(v)) + " last year at age " + AIVehicle.GetAge(v) + " days");
					n--;
					sold++;
				} else {
					local nv = this.BuildFor(line, AIVehicle.GetLocation(v) == line.depots[1] ? 1 : 0);
					if (nv >= 0 || (line.mode == MODE_RAIL && line.VehicleCount() >= ::TY.safety.MaxTrains(line))) {
						/* a single-track line gets its new train once the old one is sold (Update builds for an empty line) */
						this.Withdraw(v, "replaced before its second birthday (profit " + Util.Money(AIVehicle.GetProfitLastYear(v)) + ")");
						replaced++;
					}
				}
			}
		}
		if (sold + replaced + closed > 0) Log.Info("SCORE", "culling: " + sold + " sold, " + replaced + " replaced, " + closed + " lines closed");
	}

	/* ---------------- measurement ---------------- */

	function SampleTime(line) {
		if (line.time_audit == null) line.time_audit = [0, 0, 0, 0, 0, 0, 0];
		local ta = line.time_audit;
		foreach (v, _ in line.Vehicles()) {
			if (v in this.to_sell) continue;
			local st = AIVehicle.GetState(v);
			if (st == AIVehicle.VS_AT_STATION) ta[1]++;
			else if (st == AIVehicle.VS_BROKEN) ta[3]++;
			else if (st == AIVehicle.VS_IN_DEPOT || AIVehicle.IsInDepot(v)) ta[4]++;
			else if (st == AIVehicle.VS_RUNNING) {
				local spd = AIVehicle.GetCurrentSpeed(v);
				if (spd <= 2) ta[2]++;
				else { ta[0]++; ta[5] += spd; ta[6] += AIEngine.GetMaxSpeed(AIVehicle.GetEngineType(v)); }
			}
			/* a drop of the load means a delivery (the score counts cargo types delivered per quarter) */
			local load = AIVehicle.GetCargoLoad(v, line.cargo);
			if ((v in this.loads) && load < this.loads[v]) ::TY.score.NoteDelivery(line.cargo, this.loads[v] - load);
			this.loads[v] <- load;
		}
	}

	function TimeAuditText(line) {
		local ta = line.time_audit;
		if (ta == null) return "";
		local total = ta[0] + ta[1] + ta[2] + ta[3] + ta[4];
		if (total == 0) return "";
		local s = "time: moving " + Util.Percent(ta[0], total) + "%, at stations " + Util.Percent(ta[1], total) + "%, waiting " +
			Util.Percent(ta[2], total) + "%, broken down " + Util.Percent(ta[3], total) + "%, depot " + Util.Percent(ta[4], total) + "%";
		if (ta[0] > 0) s += "; average running speed " + (ta[5] / ta[0]) + " km/h (" + Util.Percent(ta[5], ta[6]) + "% of top speed)";
		return s;
	}

	/* Round trip measurement on one probe vehicle per line (feeds the time model). */
	function MeasureTrips() {
		foreach (line in ::TY.network.Active()) {
			this.SampleTime(line);
			if (!AIVehicle.IsValidVehicle(line.probe) || ::TY.network.LineOfVehicle(line.probe) != line || (line.probe in this.to_sell)) {
				line.probe = -1;
				foreach (v, _ in line.Vehicles()) { if (!(v in this.to_sell)) { line.probe = v; break; } }
				line.probe_order = -1;
				line.probe_date = 0;
				if (line.probe < 0) continue;
			}
			local today0 = Util.Today();
			if (line.probe_seen > 0 && today0 - line.probe_seen > 7) line.probe_date = 0;
			line.probe_seen = today0;
			if (!AIOrder.IsCurrentOrderPartOfOrderList(line.probe)) continue;
			local cur = AIOrder.ResolveOrderPosition(line.probe, AIOrder.ORDER_CURRENT);
			if (cur == line.probe_order) continue;
			if (line.probe_order == 0 && cur != 0) {
				local today = Util.Today();
				if (line.probe_date > 0) {
					local rtt = today - line.probe_date;
					if (rtt > 3 && rtt < 1500 && rtt > line.est_rtt * 0.5) {
						line.meas_rtt = line.meas_rtt > 0 ? 0.7 * line.meas_rtt + 0.3 * rtt : rtt.tofloat();
						::TY.time.Calibrate(line.mode, line.est_rtt, rtt.tofloat(), line.capacity);
					}
				}
				line.probe_date = today;
			}
			line.probe_order = cur;
		}
	}

	/* ---------------- renewal and modernisation ---------------- */

	function Renew() {
		/* in the ending year a new vehicle has no profit last year: the old one keeps counting until the ranking */
		if (::TY.score.phase == PHASE_HARVEST) return;
		foreach (line in ::TY.network.Active()) {
			foreach (v, _ in line.Vehicles()) {
				if (v in this.to_sell) continue;
				if (AIVehicle.GetAgeLeft(v) > 180 && AIVehicle.GetEngineType(v) == line.engine) continue;
				if (!::TY.finance.CanAfford(AIEngine.GetPrice(line.engine) * 2)) return;
				local why = AIVehicle.GetAgeLeft(v) <= 180 ? "end of service life" : "replaced by " + AIEngine.GetName(line.engine);
				if (line.mode == MODE_RAIL && line.VehicleCount() >= ::TY.safety.MaxTrains(line)) {
					this.Withdraw(v, why);
					break;
				}
				local nv = this.BuildFor(line, AIVehicle.GetLocation(v) == line.depots[1] ? 1 : 0);
				if (nv >= 0) this.Withdraw(v, why);
				break;
			}
		}
	}

	/* Once a year: switch lines to a clearly better model (not in the last two years: ages and profits restart). */
	function Modernise() {
		if (::TY.score.phase >= PHASE_PREPARE) return;
		foreach (line in ::TY.network.Active()) {
			local best = this.BestFor(line);
			if (best == null || best.engine == line.engine) continue;
			if (AIEngine.GetMaxSpeed(best.engine) < AIEngine.GetMaxSpeed(line.engine) * 105 / 100 &&
					best.capacity < line.capacity * 115 / 100) continue;
			Log.Info("FLEET", line.Name() + ": modernising " + AIEngine.GetName(line.engine) + " -> " + AIEngine.GetName(best.engine));
			line.engine = best.engine;
			line.capacity = best.capacity;
			if (line.mode == MODE_RAIL) { line.wagon = best.plan.wagon == null ? -1 : best.plan.wagon; line.wagons = best.plan.wagons; }
		}
	}

	function HandleSafetyFlags() {
		local flags = ::TY.safety.flagged_lines;
		local ids = [];
		foreach (id, _ in flags) ids.append(id);
		foreach (id in ids) {
			local reason = flags[id];
			delete flags[id];
			local line = ::TY.network.LineById(id);
			if (line == null || line.state != LINE_ACTIVE) continue;
			if (reason == "level crossing on route" || reason == "flooded") {
				Log.Warn("SAFETY", line.Name() + ": " + reason + ", line closed");
				this.Close(line, reason);
			} else if (reason == "level crossing on track") {
				::TY.planner.FixCrossings(line);
			} else if (reason == "train collision") {
				this.TrimTo(line, 1, "collision review");
				line.double_track = false;
				Log.Warn("SAFETY", line.Name() + ": runs a single train until the signalling is reviewed");
			}
		}
	}

	function Close(line, reason) {
		foreach (v, _ in line.Vehicles()) this.Withdraw(v, reason);
		line.state = LINE_CLOSING;
		line.note = reason;
	}

	function FinishClosures() {
		foreach (line in ::TY.network.lines) {
			if (line.state == LINE_CLOSING && line.VehicleCount() == 0) {
				line.state = LINE_CLOSED;
				if (line.mode == MODE_WATER) ::TY.marine.RemoveBuoys(line.buoys);
				Log.Info("FLEET", line.Name() + " closed (" + line.note + ")");
			}
		}
	}
}
