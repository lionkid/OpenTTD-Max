/*
 * Fleet: buys, sizes, renews and withdraws vehicles.
 *
 * Freight vehicles load "full load any" at the source and unload at the destination, coming back empty; one
 * more vehicle is added while cargo piles up at the source (or the rating there sinks) and the extra vehicle
 * would still fill, one is taken away when vehicles queue at the source for a long time. Passenger routes
 * follow the planned CargoDist flows like MaxTransit 1. A vehicle that loses money for two years in a row is
 * sold; the yearly review closes a route that loses money as a whole.
 */

class Fleet {
	to_sell = null;      // vehicle -> reason

	constructor() { this.to_sell = {}; }

	/* ---------------- building ---------------- */

	function BuildBasic(depot, engine, cargo) {
		local v;
		if (AIEngine.GetCargoType(engine) != cargo && AIEngine.CanRefitCargo(engine, cargo)) {
			v = AIVehicle.BuildVehicleWithRefit(depot, engine, cargo);
		} else {
			v = AIVehicle.BuildVehicle(depot, engine);
		}
		if (!AIVehicle.IsValidVehicle(v)) return -1;
		::MT.engines.LearnCapacity(v, cargo);
		return v;
	}

	function BuildTrain(route, depot) {
		local loco = this.BuildBasic(depot, route.engine, route.cargo);
		if (loco < 0) return -1;
		local max_len = route.sites[0].L * 16;
		local base_len = AIVehicle.GetLength(loco);
		::MT.engines.length_cache[route.engine] <- base_len;
		if (base_len > max_len) {
			Log.Warn("FLEET", AIEngine.GetName(route.engine) + " is " + base_len + "/16 tiles, platforms take " + max_len);
			AIVehicle.SellVehicle(loco);
			return -1;
		}
		for (local i = 0; i < route.wagons && route.wagon >= 0; i++) {
			local w = this.BuildBasic(depot, route.wagon, route.cargo);
			if (w < 0) break;
			local before = AIVehicle.GetLength(loco);
			if (!AIVehicle.MoveWagon(w, 0, loco, 0)) {
				Log.Warn("FLEET", AIEngine.GetName(route.wagon) + " cannot be coupled to " + AIEngine.GetName(route.engine) + ": " + AIError.GetLastErrorString());
				::MT.engines.bad_pairs[route.engine + ":" + route.wagon] <- true;
				AIVehicle.SellVehicle(w);
				break;
			}
			local after = AIVehicle.GetLength(loco);
			::MT.engines.length_cache[route.wagon] <- after - before;
			::MT.engines.probed[::MT.engines.PairKey(route.engine, route.wagon)] <- true;
			if (after > max_len) {
				AIVehicle.SellWagon(loco, AIVehicle.GetNumWagons(loco) - 1);
				break;
			}
		}
		if (AIVehicle.GetCapacity(loco, route.cargo) <= 0) {
			AIVehicle.SellVehicle(loco);
			return -1;
		}
		return loco;
	}

	/*
	 * Orders. Passengers: A, B (aircraft and ships), or A, depot B, B, depot A with "service if needed" (road
	 * and rail: servicing happens at the depot next to the stop they are about to use). Freight: full load at
	 * the source, unload and leave empty at the destination, same depot pattern.
	 */
	function SetOrders(route, v) {
		local ns = (route.mode == MODE_RAIL || route.mode == MODE_ROAD) ? AIOrder.OF_NON_STOP_INTERMEDIATE : AIOrder.OF_NONE;
		local fa = route.two_way ? ns : (ns | AIOrder.OF_FULL_LOAD_ANY);
		local fb = route.two_way ? ns : (ns | AIOrder.OF_UNLOAD | AIOrder.OF_NO_LOAD);
		local svc = AIOrder.OF_SERVICE_IF_NEEDED | ns;
		local depots = route.mode == MODE_RAIL || route.mode == MODE_ROAD;
		local ok = AIOrder.AppendOrder(v, route.tiles[0], fa);
		if (ok && depots && route.depots[1] >= 0) ok = AIOrder.AppendOrder(v, route.depots[1], svc);
		ok = ok && AIOrder.AppendOrder(v, route.tiles[1], fb);
		if (ok && depots && route.depots[0] >= 0) ok = AIOrder.AppendOrder(v, route.depots[0], svc);
		return ok;
	}

	/* Index of the order for end B. */
	function OrderB(v) {
		for (local i = 1; i < AIOrder.GetOrderCount(v); i++) if (AIOrder.IsGotoStationOrder(v, i)) return i;
		return 1;
	}

	/* Build one vehicle at end 0 or 1 of a route and send it into service. Returns the vehicle or -1. */
	function BuildFor(route, end) {
		if (route.mode == MODE_RAIL && route.VehicleCount() >= ::MT.safety.MaxTrains(route)) {
			::MT.safety.Veto("train beyond the limit of the signalling", "" + route.id);
			return -1;
		}
		if (::MT.game.VehicleRoom(route.mode) <= 0) return -1;
		local depot = route.depots[end];
		if (depot < 0) { end = 1 - end; depot = route.depots[end]; }
		if (depot < 0) return -1;
		/* freight starts at the source */
		if (!route.two_way && route.depots[0] >= 0) { end = 0; depot = route.depots[0]; }
		if (!AIEngine.IsBuildable(route.engine)) this.Repick(route);
		local price = AIEngine.GetPrice(route.engine) + (route.wagon >= 0 ? route.wagons * AIEngine.GetPrice(route.wagon) : 0);
		if (!::MT.finance.Ensure(price)) return -1;
		local v = route.mode == MODE_RAIL ? this.BuildTrain(route, depot) : this.BuildBasic(depot, route.engine, route.cargo);
		if (v < 0) {
			Log.Warn("FLEET", "could not build a vehicle for " + route.Name() + ": " + AIError.GetLastErrorString());
			return -1;
		}
		local existing = -1;
		foreach (o, _ in route.Vehicles()) { if (o != v && !(o in this.to_sell)) { existing = o; break; } }
		local ok = existing >= 0 ? AIOrder.ShareOrders(v, existing) : this.SetOrders(route, v);
		if (!ok) {
			Log.Warn("FLEET", "orders for " + route.Name() + " failed: " + AIError.GetLastErrorString());
			AIVehicle.SellVehicle(v);
			return -1;
		}
		if (end == 1) AIOrder.SkipToOrder(v, this.OrderB(v));
		AIGroup.MoveVehicle(route.group, v);
		if (route.capacity <= 0 || route.mode != MODE_RAIL) route.capacity = AIVehicle.GetCapacity(v, route.cargo);
		AIVehicle.StartStopVehicle(v);
		route.last_change = Util.Today();
		return v;
	}

	/* The route's engine is no longer sold: choose the best current model of the same kind. */
	function Repick(route) {
		local best = this.BestFor(route);
		if (best == null) return;
		Log.Info("FLEET", route.Name() + ": engine now " + AIEngine.GetName(best.engine));
		route.engine = best.engine;
		route.capacity = best.capacity;
		if (route.mode == MODE_RAIL) { route.wagon = best.plan.wagon == null ? -1 : best.plan.wagon; route.wagons = best.plan.wagons; }
	}

	function BestFor(route) {
		local supply = max(30, ::MT.monitor.Stats(route).plan);
		if (route.mode == MODE_ROAD) return ::MT.engines.BestRoad(route.cargo, route.path_len, route.dist, supply, route.two_way);
		if (route.mode == MODE_WATER) return ::MT.engines.BestShip(route.cargo, route.path_len, route.dist, supply, route.two_way);
		if (route.mode == MODE_AIR) {
			return ::MT.engines.BestAircraft(route.tiles[0], route.tiles[1], AIAirport.GetAirportType(route.tiles[0]),
				AIAirport.GetAirportType(route.tiles[1]), supply);
		}
		return ::MT.engines.BestTrain(route.sites[0].L, route.cargo, route.path_len, route.dist, supply, route.two_way,
			route.railtype, route.depots[0], route.double_track ? 0 : 1);
	}

	/* ---------------- withdrawing ---------------- */

	function Withdraw(v, reason) {
		if (!AIVehicle.IsValidVehicle(v) || (v in this.to_sell)) return;
		this.to_sell[v] <- reason;
		if (!AIVehicle.IsStoppedInDepot(v) && !AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);
		Log.Info("FLEET", "withdrawing " + AIVehicle.GetName(v) + ": " + reason);
	}

	function TrimTo(route, n, reason) {
		local keep = 0;
		foreach (v, _ in route.Vehicles()) {
			if (v in this.to_sell) continue;
			if (keep < n) { keep++; continue; }
			this.Withdraw(v, reason);
		}
	}

	function ActiveCount(route) {
		local n = 0;
		foreach (v, _ in route.Vehicles()) if (!(v in this.to_sell)) n++;
		return n;
	}

	function SellParked() {
		local keys = [];
		foreach (v, _ in this.to_sell) keys.append(v);
		foreach (v in keys) {
			if (!AIVehicle.IsValidVehicle(v)) { delete this.to_sell[v]; continue; }
			if (AIVehicle.IsStoppedInDepot(v)) {
				AIVehicle.SellVehicle(v);
				if (!AIVehicle.IsValidVehicle(v)) delete this.to_sell[v];
				continue;
			}
			if (!AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);
		}
	}

	/* ---------------- sizing ---------------- */

	function MaxVehicles(route) {
		local rtt = fmax(4.0, route.FreeRtt());
		if (route.mode == MODE_RAIL) {
			if (!route.double_track) return 1;
			return Util.Clamp(min(route.signal_blocks + 2, (rtt / 4.0).tointeger()), 2, 30);
		}
		if (route.mode == MODE_AIR) {
			local t = min(::MT.air.Terminals(AIAirport.GetAirportType(route.tiles[0])), ::MT.air.Terminals(AIAirport.GetAirportType(route.tiles[1])));
			return Util.Clamp((t * rtt / 15).tointeger(), 2, 40);
		}
		if (route.mode == MODE_WATER) return Util.Clamp((rtt / 6).tointeger(), 2, 14);
		/* road: a bay stop takes two lorries at a time, a drive-through stop two buses per direction */
		return Util.Clamp((rtt / (route.two_way ? 3 : 2.5)).tointeger(), 2, 20);
	}

	/* Landings per month at an airport over all our air routes. */
	function AirportLoad(sid) {
		local load = 0.0;
		foreach (r in ::MT.routes.RoutesAt(sid)) {
			if (r.mode != MODE_AIR) continue;
			load += this.ActiveCount(r) * 30.0 / fmax(4.0, r.FreeRtt());
		}
		return load;
	}

	/* Share of the two platforms of a rail station that our trains occupy (dwell / round trip, all routes). */
	function RailStationLoad(sid) {
		local load = 0.0;
		foreach (r in ::MT.routes.RoutesAt(sid)) {
			if (r.mode != MODE_RAIL) continue;
			load += this.ActiveCount(r) * ::MT.economy.StopDays(MODE_RAIL, r.capacity) / fmax(4.0, r.FreeRtt());
		}
		return load;
	}

	function CanAdd(route) {
		if (this.ActiveCount(route) >= this.MaxVehicles(route)) return false;
		if (route.mode == MODE_RAIL && route.VehicleCount() >= ::MT.safety.MaxTrains(route)) return false;
		if (route.mode == MODE_RAIL) {
			local extra = ::MT.economy.StopDays(MODE_RAIL, route.capacity) / fmax(4.0, route.FreeRtt());
			foreach (sid in route.sids) if (sid >= 0 && this.RailStationLoad(sid) + extra > 1.3) return false;
		}
		if (route.mode == MODE_AIR) {
			foreach (i, sid in route.sids) {
				local t = ::MT.air.Terminals(AIAirport.GetAirportType(route.tiles[i]));
				if (this.AirportLoad(sid) + 30.0 / fmax(4.0, route.FreeRtt()) > t * 4.0) return false;
			}
		}
		return ::MT.game.VehicleRoom(route.mode) > 0;
	}

	/* Vehicles of a route waiting at the source to fill up (freight), the sign of too many vehicles. */
	function Queued(route) {
		local n = 0;
		foreach (v, _ in route.Vehicles()) {
			if (v in this.to_sell) continue;
			if (AIVehicle.GetState(v) == AIVehicle.VS_AT_STATION && AIVehicle.GetCurrentSpeed(v) == 0 &&
					AIMap.DistanceManhattan(AIVehicle.GetLocation(v), route.tiles[0]) < 8) n++;
			else if (route.mode == MODE_ROAD && AIVehicle.GetState(v) == AIVehicle.VS_RUNNING && AIVehicle.GetCurrentSpeed(v) == 0 &&
					AIMap.DistanceManhattan(AIVehicle.GetLocation(v), route.tiles[0]) < 4) n++;
		}
		return n;
	}

	function Update() {
		local rich = ::MT.finance.Cash() - ::MT.finance.Reserve() > 500000;
		foreach (route in ::MT.routes.Active()) {
			local n = this.ActiveCount(route);
			if (n == 0) {
				this.BuildFor(route, 0);
				continue;
			}
			local s = ::MT.monitor.Stats(route);
			local age = Util.Today() - route.created;
			local more = false, less = false;
			if (route.two_way) {
				local next_util = s.cap_month > 0 ? s.util * n / (n + 1.0) : 0.0;
				more = s.util > 0.9 || s.wait_ratio > 1.5 || (s.headway > 15 && next_util > 0.5);
				if (!::MT.game.CargoDistOn()) more = s.wait_ratio > 1.2 || (s.rating_a >= 0 && s.rating_a < 45 && s.wait_ratio > 0.5);
				less = n > 1 && age > 120 && s.util < 0.35 && s.wait_ratio < 0.3 && (::MT.game.CargoDistOn() || s.wait_ratio < 0.1);
			} else {
				local queued = this.Queued(route);
				/* cargo piles up (more than a load waiting) or the rating sinks while nobody is loading */
				more = queued == 0 && (s.wait_ratio > 1.2 || (s.rating_a >= 0 && s.rating_a < 55 && s.wait_ratio > 0.4) || s.util > 1.1);
				less = n > 1 && age > 120 && queued >= 2;
			}
			/*
			 * Waiting cargo asks for more vehicles, but when last year's vehicles earned little more of them only
			 * add running costs: the cargo waits because the trips are slow (queues at a busy airport, aircraft
			 * flying slowly from a breakdown until they land), not because there are too few vehicles. A vehicle
			 * must earn the capital rate on its price, as a new route would. Vehicles that lost money go one by one.
			 */
			local ly = this.LastYear(route), why = route.Name() + " has more vehicles than cargo";
			if (ly.n > 0 && (ly.losers * 4 > ly.n || ly.average < AIEngine.GetPrice(route.engine) * ::MT.engines.capital_rate)) {
				more = false;
				if (ly.losers > 0 && n > 2) {
					less = true;
					why = route.Name() + ": " + ly.losers + " of " + ly.n + " vehicles lost money last year";
				}
			}
			if (more) { route.hi++; route.lo = 0; }
			else if (less) { route.lo++; route.hi = 0; }
			else { route.hi = max(0, route.hi - 1); route.lo = max(0, route.lo - 1); }

			if (route.hi >= 2 && Util.Today() - route.last_change >= (route.two_way ? 20 : 12)) {
				if (this.CanAdd(route)) {
					local need = 1;
					if (s.util > 1.3) need = max(need, (n * (s.util - 1.0)).tointeger());
					if (s.wait_ratio > 3.0) need = max(need, (s.wait_ratio / 3.0).tointeger());
					need = Util.Clamp(need, 1, rich ? 4 : 2);
					local added = 0;
					for (local k = 0; k < need && this.CanAdd(route); k++) {
						if (this.BuildFor(route, (n + k) % 2) < 0) break;
						added++;
					}
					if (added > 0) {
						Log.Info("FLEET", route.Name() + ": +" + added + " (" + (n + added) + " vehicles), use " + (s.util * 100).tointeger() +
							"%, waiting " + s.wait_a + (route.two_way ? "/" + s.wait_b : "") + (s.rating_a >= 0 ? ", rating " + s.rating_a + "%" : ""));
					}
					route.hi = 0;
				} else if (route.mode == MODE_RAIL && !route.double_track &&
						(route.upgrade_failed == 0 || Util.Today() - route.upgrade_failed > 2190)) {
					/* a second track that found no way rarely finds one later (2 of about 110 retries after two years): wait six */
					route.note = "upgrade";
				}
			}
			if (route.lo >= 3 && Util.Today() - route.last_change >= 60) {
				local worst = this.WorstVehicle(route);
				if (worst >= 0) {
					this.Withdraw(worst, why);
					route.last_change = Util.Today();
				}
				route.lo = 0;
			}
		}
	}

	/* Last year's profit of the vehicles that were in service all of last year. */
	function LastYear(route) {
		local now = AIDate.GetCurrentDate();
		local full_year = 365 + now - AIDate.GetDate(AIDate.GetYear(now), 1, 1);
		local sum = 0, n = 0, losers = 0;
		foreach (v, _ in route.Vehicles()) {
			if ((v in this.to_sell) || AIVehicle.GetAge(v) < full_year) continue;
			local p = AIVehicle.GetProfitLastYear(v);
			if (p < 0) losers++;
			sum += p;
			n++;
		}
		return {n = n, losers = losers, average = n > 0 ? sum / n : 0};
	}

	/* Oldest, least reliable vehicle of a route. */
	function WorstVehicle(route) {
		local worst = -1, worst_score = -1;
		foreach (v, _ in route.Vehicles()) {
			if (v in this.to_sell) continue;
			local score = AIVehicle.GetAge(v) - AIVehicle.GetReliability(v) * 10;
			if (score > worst_score) { worst_score = score; worst = v; }
		}
		return worst;
	}

	/* Round trip measurement on one probe vehicle per route (feeds the time model). */
	function MeasureTrips() {
		foreach (route in ::MT.routes.Active()) {
			if (!AIVehicle.IsValidVehicle(route.probe) || ::MT.routes.RouteOfVehicle(route.probe) != route || (route.probe in this.to_sell)) {
				route.probe = -1;
				foreach (v, _ in route.Vehicles()) { if (!(v in this.to_sell)) { route.probe = v; break; } }
				route.probe_order = -1;
				route.probe_date = 0;
				if (route.probe < 0) continue;
			}
			local today = Util.Today();
			if (route.probe_seen > 0 && today - route.probe_seen > 7) route.probe_date = 0;
			route.probe_seen = today;
			if (!AIOrder.IsCurrentOrderPartOfOrderList(route.probe)) continue;
			local cur = AIOrder.ResolveOrderPosition(route.probe, AIOrder.ORDER_CURRENT);
			if (cur == route.probe_order) continue;
			if (route.probe_order == 0 && cur != 0) {   // just left end A
				if (route.probe_date > 0) {
					local rtt = today - route.probe_date;
					if (rtt > 3 && rtt < 1500 && rtt > route.est_rtt * 0.5) {
						/* freight waits for a full load: only passenger trips calibrate the running time */
						route.meas_rtt = route.meas_rtt > 0 ? 0.7 * route.meas_rtt + 0.3 * rtt : rtt.tofloat();
						if (route.two_way) ::MT.economy.Calibrate(route.mode, route.est_rtt, rtt.tofloat(), route.capacity);
					}
				}
				route.probe_date = today;
			}
			route.probe_order = cur;
		}
	}

	/* ---------------- renewal, modernisation, money ---------------- */

	/* Replace one vehicle per route per call that is near the end of its life. */
	function Renew() {
		foreach (route in ::MT.routes.Active()) {
			foreach (v, _ in route.Vehicles()) {
				if (v in this.to_sell) continue;
				if (AIVehicle.GetAgeLeft(v) > 180 && AIVehicle.GetEngineType(v) == route.engine) continue;
				if (!::MT.finance.CanAfford(AIEngine.GetPrice(route.engine) * 2)) return;
				local why = AIVehicle.GetAgeLeft(v) <= 180 ? "end of service life" : "replaced by " + AIEngine.GetName(route.engine);
				if (route.mode == MODE_RAIL && route.VehicleCount() >= ::MT.safety.MaxTrains(route)) {
					this.Withdraw(v, why);
					break;
				}
				local nv = this.BuildFor(route, AIVehicle.GetLocation(v) == route.depots[1] ? 1 : 0);
				if (nv >= 0) this.Withdraw(v, why);
				break;
			}
		}
	}

	/* Once a year: switch routes to a clearly better model. */
	function Modernise() {
		foreach (route in ::MT.routes.Active()) {
			local best = this.BestFor(route);
			if (best == null || best.engine == route.engine) continue;
			if (AIEngine.GetMaxSpeed(best.engine) < AIEngine.GetMaxSpeed(route.engine) * 105 / 100 &&
					best.capacity < route.capacity * 115 / 100) continue;
			Log.Info("FLEET", route.Name() + ": modernising " + AIEngine.GetName(route.engine) + " -> " + AIEngine.GetName(best.engine));
			route.engine = best.engine;
			route.capacity = best.capacity;
			if (route.mode == MODE_RAIL) { route.wagon = best.plan.wagon == null ? -1 : best.plan.wagon; route.wagons = best.plan.wagons; }
		}
	}

	/*
	 * Yearly money review. A vehicle older than two years that lost money last year and is losing again this
	 * year is sold (one per route per review). A route that lost money as a whole for two reviews in a row is
	 * closed and its infrastructure removed.
	 */
	function Review() {
		foreach (route in ::MT.routes.Active()) {
			local total = 0, n = 0;
			foreach (v, _ in route.Vehicles()) {
				if (v in this.to_sell) continue;
				n++;
				total += AIVehicle.GetProfitLastYear(v);
			}
			if (n > 0) ::MT.planner.Learn(route, total);
			if (n == 0 || Util.Today() - route.created < 500) continue;
			if (total < 0) route.losses++;
			else route.losses = 0;
			if (route.losses >= 2) {
				::MT.planner.CloseRoute(route, "lost money for two years (" + Util.Money(total) + " last year)");
				continue;
			}
			if (n <= 1) continue;
			foreach (v, _ in route.Vehicles()) {
				if (v in this.to_sell || AIVehicle.GetAge(v) < 730) continue;
				if (AIVehicle.GetProfitLastYear(v) < 0 && AIVehicle.GetProfitThisYear(v) < 0) {
					this.Withdraw(v, "lost " + Util.Money(-AIVehicle.GetProfitLastYear(v)) + " last year");
					break;
				}
			}
		}
	}

	/* Routes flagged by the safety officer. */
	function HandleSafetyFlags() {
		local flags = ::MT.safety.flagged;
		local ids = [];
		foreach (id, _ in flags) ids.append(id);
		foreach (id in ids) {
			local reason = flags[id];
			delete flags[id];
			local route = ::MT.routes.RouteById(id);
			if (route == null || route.state != ROUTE_ACTIVE) continue;
			if (reason == "level crossing on route" || reason == "flooded") {
				::MT.planner.CloseRoute(route, reason);
			} else if (reason == "level crossing on track") {
				::MT.planner.FixCrossings(route);
			} else if (reason == "train collision") {
				this.TrimTo(route, 1, "collision review");
				route.double_track = false;
			}
		}
	}

	function Close(route, reason) {
		foreach (v, _ in route.Vehicles()) this.Withdraw(v, reason);
		route.state = ROUTE_CLOSING;
		route.note = reason;
	}
}
