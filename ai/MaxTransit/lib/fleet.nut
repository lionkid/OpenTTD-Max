/*
 * Fleet: buys, sizes, renews and withdraws vehicles.
 *
 * Sizing follows CargoDist: a line gets a vehicle when the planned flow on one of its links reaches 90% of
 * its monthly capacity, or passengers for that next hop pile up, or the headway is longer than the target
 * while the extra vehicle would still run reasonably full. It loses one when both directions stay under
 * 35% for two months. Orders never use "full load" (passengers would age in a waiting vehicle and the
 * others would wait longer) and are non-stop so trains and buses do not stop at stations they pass.
 */

class Fleet {
	to_sell = null;      // vehicle -> reason

	constructor() { this.to_sell = {}; }

	/* ---------------- building ---------------- */

	function BuildBasic(depot, engine) {
		local v;
		if (AIEngine.GetCargoType(engine) != Util.pax && AIEngine.CanRefitCargo(engine, Util.pax)) {
			v = AIVehicle.BuildVehicleWithRefit(depot, engine, Util.pax);
		} else {
			v = AIVehicle.BuildVehicle(depot, engine);
		}
		return AIVehicle.IsValidVehicle(v) ? v : -1;
	}

	function BuildTrain(line, depot) {
		local loco = this.BuildBasic(depot, line.engine);
		if (loco < 0) return -1;
		local max_len = line.sites[0].L * 16;
		local base_len = AIVehicle.GetLength(loco);
		::MT.engines.length_cache[line.engine] <- base_len;
		if (base_len > max_len) {
			Log.Warn("FLEET", AIEngine.GetName(line.engine) + " is " + base_len + "/16 tiles, platforms take " + max_len);
			AIVehicle.SellVehicle(loco);
			return -1;
		}
		for (local i = 0; i < line.wagons && line.wagon >= 0; i++) {
			local w = this.BuildBasic(depot, line.wagon);
			if (w < 0) break;
			local before = AIVehicle.GetLength(loco);
			if (!AIVehicle.MoveWagon(w, 0, loco, 0)) {
				Log.Warn("FLEET", AIEngine.GetName(line.wagon) + " cannot be coupled to " + AIEngine.GetName(line.engine) + ": " + AIError.GetLastErrorString());
				::MT.engines.bad_pairs[line.engine + ":" + line.wagon] <- true;
				AIVehicle.SellVehicle(w);
				break;
			}
			local after = AIVehicle.GetLength(loco);
			::MT.engines.length_cache[line.wagon] <- after - before;
			if (after > max_len) {
				AIVehicle.SellWagon(loco, AIVehicle.GetNumWagons(loco) - 1);
				break;
			}
		}
		if (AIVehicle.GetCapacity(loco, Util.pax) <= 0) {
			AIVehicle.SellVehicle(loco);
			return -1;
		}
		return loco;
	}

	/*
	 * Orders: A, B for aircraft (they service in the hangar of the airport they visit). Buses and trains get
	 * "service if needed" depot orders in front of each station: [A, depot B, B, depot A], so servicing happens
	 * at the depot next to the platform they are about to use, and only when breakdowns are on and it is due.
	 */
	function SetOrders(line, v) {
		if (line.mode == MODE_AIR) {
			return AIOrder.AppendOrder(v, line.tiles[0], AIOrder.OF_NONE) && AIOrder.AppendOrder(v, line.tiles[1], AIOrder.OF_NONE);
		}
		local ns = AIOrder.OF_NON_STOP_INTERMEDIATE;
		local svc = AIOrder.OF_SERVICE_IF_NEEDED | ns;
		local ok = AIOrder.AppendOrder(v, line.tiles[0], ns);
		if (ok && line.depots[1] >= 0) ok = AIOrder.AppendOrder(v, line.depots[1], svc);
		ok = ok && AIOrder.AppendOrder(v, line.tiles[1], ns);
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
		/* Safety gate: count every train of the line, including those still driving to a depot to be sold. */
		if (line.mode == MODE_RAIL && line.VehicleCount() >= ::MT.safety.MaxTrains(line)) {
			::MT.safety.Veto("train beyond the limit of the signalling", "" + line.id);
			return -1;
		}
		local depot = line.depots[end];
		if (depot < 0) { end = 1 - end; depot = line.depots[end]; }
		if (depot < 0) return -1;
		local price = AIEngine.GetPrice(line.engine) + (line.wagon >= 0 ? line.wagons * AIEngine.GetPrice(line.wagon) : 0);
		if (!::MT.finance.Ensure(price)) return -1;
		if (!AIEngine.IsBuildable(line.engine)) this.Repick(line);
		local v = line.mode == MODE_RAIL ? this.BuildTrain(line, depot) : this.BuildBasic(depot, line.engine);
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
		if (end == 1) AIOrder.SkipToOrder(v, this.OrderB(v));
		AIGroup.MoveVehicle(line.group, v);
		if (line.capacity <= 0) line.capacity = AIVehicle.GetCapacity(v, Util.pax);
		AIVehicle.StartStopVehicle(v);
		line.last_change = Util.Today();
		return v;
	}

	/* The line's engine is no longer sold: choose the best current model of the same class. */
	function Repick(line) {
		local best = null;
		if (line.mode == MODE_ROAD) best = ::MT.engines.BestBus(line.path_len, line.dist, 100);
		else if (line.mode == MODE_AIR) {
			best = ::MT.engines.BestAircraft(line.tiles[0], line.tiles[1], AIAirport.GetAirportType(line.tiles[0]),
				AIAirport.GetAirportType(line.tiles[1]), 150);
		} else {
			best = ::MT.engines.BestTrain(line.sites[0].L, line.path_len, line.dist, 150, line.railtype);
			if (best != null) { line.wagon = best.plan.wagon == null ? -1 : best.plan.wagon; line.wagons = best.plan.wagons; }
		}
		if (best != null) {
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
		local list = line.Vehicles();
		local keep = 0;
		foreach (v, _ in list) {
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

	function MaxVehicles(line) {
		local rtt = fmax(4.0, line.Rtt());
		if (line.mode == MODE_RAIL) {
			if (!line.double_track) return 1;
			local by_platform = (rtt / 4.0).tointeger();
			return Util.Clamp(min(line.signal_blocks + 2, by_platform), 2, 30);
		}
		if (line.mode == MODE_AIR) {
			local t = min(::MT.air.Terminals(AIAirport.GetAirportType(line.tiles[0])), ::MT.air.Terminals(AIAirport.GetAirportType(line.tiles[1])));
			return Util.Clamp((t * rtt / 15).tointeger(), 2, 40);
		}
		return Util.Clamp((rtt / 3).tointeger(), 2, 15);
	}

	/* Landings per month at an airport over all our air lines (runway and terminal load). */
	function AirportLoad(sid) {
		local load = 0.0;
		foreach (l in ::MT.network.LinesAt(sid)) {
			if (l.mode != MODE_AIR) continue;
			load += this.ActiveCount(l) * 30.0 / fmax(4.0, l.Rtt());
		}
		return load;
	}

	/* Share of the two platforms of a rail station that our trains occupy (dwell / round trip, all lines). */
	function RailStationLoad(sid) {
		local load = 0.0;
		foreach (l in ::MT.network.LinesAt(sid)) {
			if (l.mode != MODE_RAIL) continue;
			load += this.ActiveCount(l) * ::MT.time.StopDays(MODE_RAIL, l.capacity) / fmax(4.0, l.Rtt());
		}
		return load;
	}

	function CanAdd(line) {
		if (this.ActiveCount(line) >= this.MaxVehicles(line)) return false;
		if (line.mode == MODE_RAIL && line.VehicleCount() >= ::MT.safety.MaxTrains(line)) return false;
		if (line.mode == MODE_RAIL) {
			local extra = ::MT.time.StopDays(MODE_RAIL, line.capacity) / fmax(4.0, line.Rtt());
			foreach (sid in line.sids) if (this.RailStationLoad(sid) + extra > 1.3) return false;   // 2 platforms, 65% busy
		}
		if (line.mode == MODE_AIR) {
			foreach (i, sid in line.sids) {
				local t = ::MT.air.Terminals(AIAirport.GetAirportType(line.tiles[i]));
				if (this.AirportLoad(sid) + 30.0 / fmax(4.0, line.Rtt()) > t * 4.0) return false;
			}
		}
		local count = AIVehicleList();
		count.Valuate(AIVehicle.GetVehicleType);
		count.KeepValue(line.VehicleType());
		if (count.Count() >= ::MT.game.max_vehicles[line.mode]) return false;
		return true;
	}

	function Update() {
		local hmax = ::MT.time.headway_max;
		foreach (line in ::MT.network.Active()) {
			local n = this.ActiveCount(line);
			if (n == 0) {
				this.BuildFor(line, 0);
				continue;
			}
			local s = ::MT.cdist.LineStats(line);
			local age = Util.Today() - line.created;
			local next_util = s.cap_month > 0 ? s.util * n / (n + 1.0) : 0.0;
			local more = s.util > 0.9 || s.wait_ratio > 1.5 ||
				(s.headway > hmax[line.mode] && (s.util > 0.55 || s.wait_ratio > 0.8) && next_util > 0.4);
			/* With CargoDist off there is no plan, so ratings below 50% (rare pickups) also ask for service. */
			if (!::MT.game.CargoDistOn() && s.rating_a >= 0 && s.rating_a < 45 && s.wait_ratio > 0.5) more = true;
			local less = n > 1 && age > 120 && s.util < 0.35 && s.wait_ratio < 0.3 &&
				(::MT.game.CargoDistOn() ? true : s.wait_ratio < 0.1);
			if (more) { line.hi++; line.lo = 0; }
			else if (less) { line.lo++; line.hi = 0; }
			else { line.hi = max(0, line.hi - 1); line.lo = max(0, line.lo - 1); }

			if (line.hi >= 2 && Util.Today() - line.last_change >= 20) {
				if (this.CanAdd(line)) {
					/* A big shortfall gets up to three vehicles at once instead of one a month. */
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
			/* Frequency: one train every two or three months makes passengers wait (and the rating drop). With
			 * enough demand for a second train, double the line even before the first train is full. */
			if (line.mode == MODE_RAIL && !line.double_track && line.note == "" && age > 180 &&
					s.headway > 2 * hmax[MODE_RAIL] && s.util > 0.45 &&
					(line.upgrade_failed == 0 || Util.Today() - line.upgrade_failed > 730)) {
				line.note = "upgrade";
				Log.Info("FLEET", line.Name() + ": headway " + s.headway.tointeger() + " d with " + (s.util * 100).tointeger() +
					"% of the seats planned; asking for a second track");
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

	/*
	 * Time audit: where do the vehicles of a line spend their time? Sampled every few days:
	 * moving, dwelling at a station, waiting (stopped on the line: signals or queues), broken down, in a depot.
	 */
	function SampleTime(line) {
		if (line.time_audit == null) line.time_audit = [0, 0, 0, 0, 0, 0, 0];   // moving, dwell, wait, broken, depot, speed sum, max speed sum
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
		foreach (line in ::MT.network.Active()) {
			this.SampleTime(line);
			if (!AIVehicle.IsValidVehicle(line.probe) || ::MT.network.LineOfVehicle(line.probe) != line || (line.probe in this.to_sell)) {
				line.probe = -1;
				foreach (v, _ in line.Vehicles()) { if (!(v in this.to_sell)) { line.probe = v; break; } }
				line.probe_order = -1;
				line.probe_date = 0;
				if (line.probe < 0) continue;
			}
			if (AIController.GetSetting("debug") == 1) {
				local v = line.probe;
				Log.Info("TRACE", line.Name() + " v" + v + " " + Util.DateStr(Util.Today()) + " state " + AIVehicle.GetState(v) +
					" speed " + AIVehicle.GetCurrentSpeed(v) + " at " + Util.TileStr(AIVehicle.GetLocation(v)) + " order " +
					AIOrder.ResolveOrderPosition(v, AIOrder.ORDER_CURRENT) + (AIOrder.IsCurrentOrderPartOfOrderList(v) ? "" : " (off list)") +
					" load " + AIVehicle.GetCargoLoad(v, Util.pax) + " rel " + AIVehicle.GetReliability(v));
			}
			local today0 = Util.Today();
			if (line.probe_seen > 0 && today0 - line.probe_seen > 7) line.probe_date = 0;   // missed samples: discard this trip
			line.probe_seen = today0;
			if (!AIOrder.IsCurrentOrderPartOfOrderList(line.probe)) continue;
			local cur = AIOrder.ResolveOrderPosition(line.probe, AIOrder.ORDER_CURRENT);
			if (cur == line.probe_order) continue;
			if (line.probe_order == 0 && cur != 0) {   // just left station A
				local today = Util.Today();
				if (line.probe_date > 0) {
					local rtt = today - line.probe_date;
					if (rtt > 3 && rtt < 1500) {
						line.meas_rtt = line.meas_rtt > 0 ? 0.7 * line.meas_rtt + 0.3 * rtt : rtt.tofloat();
						::MT.time.Calibrate(line.mode, line.est_rtt, rtt.tofloat(), line.capacity);
					}
				}
				line.probe_date = today;
			}
			line.probe_order = cur;
		}
	}

	/* ---------------- renewal and modernisation ---------------- */

	/* Replace one vehicle per line per call that is near the end of its life (reliability, rating). */
	function Renew() {
		foreach (line in ::MT.network.Active()) {
			foreach (v, _ in line.Vehicles()) {
				if (v in this.to_sell) continue;
				if (AIVehicle.GetAgeLeft(v) > 180 && AIVehicle.GetEngineType(v) == line.engine) continue;
				if (!::MT.finance.CanAfford(AIEngine.GetPrice(line.engine) * 2)) return;
				local why = AIVehicle.GetAgeLeft(v) <= 180 ? "end of service life" : "replaced by " + AIEngine.GetName(line.engine);
				if (line.mode == MODE_RAIL && line.VehicleCount() >= ::MT.safety.MaxTrains(line)) {
					/* No spare block for a second train: the old one leaves first, the new one follows when it is sold. */
					this.Withdraw(v, why);
					break;
				}
				local nv = this.BuildFor(line, AIVehicle.GetLocation(v) == line.depots[1] ? 1 : 0);
				if (nv >= 0) this.Withdraw(v, why);
				break;
			}
		}
	}

	/* Once a year: switch lines to a clearly better model (safety filters are part of the choice). */
	function Modernise() {
		foreach (line in ::MT.network.Active()) {
			local best = null;
			if (line.mode == MODE_ROAD) best = ::MT.engines.BestBus(line.path_len, line.dist, 100);
			else if (line.mode == MODE_AIR) {
				best = ::MT.engines.BestAircraft(line.tiles[0], line.tiles[1], AIAirport.GetAirportType(line.tiles[0]),
					AIAirport.GetAirportType(line.tiles[1]), 150);
			} else {
				best = ::MT.engines.BestTrain(line.sites[0].L, line.path_len, line.dist, 150, line.railtype);
			}
			if (best == null || best.engine == line.engine) continue;
			if (AIEngine.GetMaxSpeed(best.engine) < AIEngine.GetMaxSpeed(line.engine) * 105 / 100 &&
					best.capacity < line.capacity * 115 / 100) continue;
			Log.Info("FLEET", line.Name() + ": modernising " + AIEngine.GetName(line.engine) + " -> " + AIEngine.GetName(best.engine));
			line.engine = best.engine;
			line.capacity = best.capacity;
			if (line.mode == MODE_RAIL) { line.wagon = best.plan.wagon == null ? -1 : best.plan.wagon; line.wagons = best.plan.wagons; }
		}
	}

	/* Lines flagged by the SafetyOfficer. */
	function HandleSafetyFlags() {
		local flags = ::MT.safety.flagged_lines;
		local ids = [];
		foreach (id, _ in flags) ids.append(id);
		foreach (id in ids) {
			local reason = flags[id];
			delete flags[id];
			local line = ::MT.network.LineById(id);
			if (line == null || line.state != LINE_ACTIVE) continue;
			if (reason == "level crossing on route" || reason == "level crossing on road" || reason == "flooded") {
				Log.Warn("SAFETY", line.Name() + ": " + reason + ", line closed");
				this.Close(line, reason);
			} else if (reason == "level crossing on track") {
				::MT.planner.FixCrossings(line);
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
		foreach (line in ::MT.network.lines) {
			if (line.state == LINE_CLOSING && line.VehicleCount() == 0) {
				line.state = LINE_CLOSED;
				Log.Info("FLEET", line.Name() + " closed (" + line.note + ")");
			}
		}
	}
}
