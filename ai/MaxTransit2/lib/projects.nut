/*
 * Projects: building a planned route, mode by mode, and taking it down again.
 *
 * Every project either completes or removes what it built: a failed path search leaves no half-built track,
 * no orphan stop and no stray road behind. Trees cut on the way are counted and replanted next to the line.
 */

class Projects {
	function Build(c) {
		if (c.mode == MODE_ROAD) return c.two_way ? this.BuildBus(c) : this.BuildLorry(c);
		if (c.mode == MODE_RAIL) return this.BuildRail(c);
		if (c.mode == MODE_AIR) return this.BuildAir(c);
		if (c.mode == MODE_WATER) return c.two_way ? this.BuildFerry(c) : this.BuildShip(c);
		return false;
	}

	function JoinId(town) {
		local sid = ::MT.routes.HubStation(town);
		return sid >= 0 ? sid : AIStation.STATION_NEW;
	}

	function RegisterStation(town, sid, mode) {
		local hub = ::MT.routes.Hub(town);
		if (!AIStation.IsValidStation(hub.sid)) hub.sid = sid;
		if (mode == MODE_RAIL) hub.rail++;
	}

	function NewRoute(c) {
		local r = Route();
		r.mode = c.mode;
		r.cargo = c.cargo;
		r.two_way = c.two_way;
		r.ends = [c.a, c.b];
		r.engine = c.engine;
		r.est_profit = ("raw_profit" in c) ? c.raw_profit.tointeger() : -1;
		return r;
	}

	function Opened(route, extra) {
		Log.Info("BUILD", route.Name() + " opened: " + extra);
		Util.SignAt(route.tiles[0], route.GroupName());
		if (route.ends[0].type == END_TOWN) ::MT.landscape.BuildHQ(route.ends[0].id);
		else if (route.ends[1].type == END_TOWN) ::MT.landscape.BuildHQ(route.ends[1].id);
	}

	/* ---------------- road ---------------- */

	function StopFor(town, join, cargo, vtype, min_acc) {
		local center = AITown.GetLocation(town);
		local r = 4 + min(6, AITown.GetPopulation(town) / 800);
		local spot = ::MT.road.FindStop(center, r, join, cargo, vtype, null, -1, 0, min_acc);
		if (spot == null && join != AIStation.STATION_NEW) spot = ::MT.road.FindStop(center, r, AIStation.STATION_NEW, cargo, vtype, null, -1, 0, min_acc);
		return spot;
	}

	function BuildBus(c) {
		local a = c.a.id, b = c.b.id;
		local spot_a = this.StopFor(a, this.JoinId(a), Util.pax, AIRoad.ROADVEHTYPE_BUS, 15);
		local spot_b = this.StopFor(b, this.JoinId(b), Util.pax, AIRoad.ROADVEHTYPE_BUS, 15);
		if (spot_a == null || spot_b == null) {
			Log.Warn("PLAN", "no bus stop site in " + Util.TownName(spot_a == null ? a : b));
			if (spot_a == null) ::MT.planner.MarkNoSite(MODE_ROAD, c.a);
			if (spot_b == null) ::MT.planner.MarkNoSite(MODE_ROAD, c.b);
			return false;
		}
		return this.BuildRoadRoute(c, spot_a, spot_b, this.JoinId(a), this.JoinId(b), AIRoad.ROADVEHTYPE_BUS);
	}

	function BuildLorry(c) {
		local ind = c.a.id;
		local dest_loc = c.b.type == END_TOWN ? AITown.GetLocation(c.b.id) : AIIndustry.GetLocation(c.b.id);
		local spot_a = ::MT.road.FindBay(ind, c.cargo, true, dest_loc);
		if (spot_a == null) { Log.Warn("PLAN", "no lorry bay at " + Util.IndustryName(ind)); ::MT.planner.MarkNoSite(MODE_ROAD, c.a); return false; }
		local spot_b;
		if (c.b.type == END_TOWN) spot_b = this.StopFor(c.b.id, AIStation.STATION_NEW, c.cargo, AIRoad.ROADVEHTYPE_TRUCK, 8);
		else spot_b = ::MT.road.FindBay(c.b.id, c.cargo, false, spot_a.front);
		if (spot_b == null) {
			Log.Warn("PLAN", "no lorry stop at " + (c.b.type == END_TOWN ? Util.TownName(c.b.id) : Util.IndustryName(c.b.id)));
			::MT.planner.MarkNoSite(MODE_ROAD, c.b);
			return false;
		}
		return this.BuildRoadRoute(c, spot_a, spot_b, AIStation.STATION_NEW, AIStation.STATION_NEW, AIRoad.ROADVEHTYPE_TRUCK);
	}

	/* Road end of a stop for the path search: the street a drive-through stop is on, the access tile of a bay. */
	function RoadEnd(spot) { return spot.bay ? spot.front : spot.tile; }

	function BuildRoadRoute(c, spot_a, spot_b, join_a, join_b, vtype) {
		local speed = AIEngine.GetMaxSpeed(c.engine);
		if (!::MT.finance.Ensure(c.first_cost.tointeger())) return false;
		local sa = ::MT.road.BuildStop(spot_a, join_a, vtype);
		if (sa < 0 && join_a != AIStation.STATION_NEW) sa = ::MT.road.BuildStop(spot_a, AIStation.STATION_NEW, vtype);
		if (sa < 0) return false;
		local sb = ::MT.road.BuildStop(spot_b, join_b, vtype);
		if (sb < 0 && join_b != AIStation.STATION_NEW) sb = ::MT.road.BuildStop(spot_b, AIStation.STATION_NEW, vtype);
		local undo = function() : (spot_a, spot_b) {
			AIRoad.RemoveRoadStation(spot_a.tile);
			AIRoad.RemoveRoadStation(spot_b.tile);
			local loose = [];
			foreach (s in [spot_a, spot_b]) if (s.bay) loose.append(s.front);
			::MT.road.RemoveUnused(loose);
		};
		if (sb < 0) { undo(); return false; }
		local conn = ::MT.road.Connect(this.RoadEnd(spot_a), this.RoadEnd(spot_b), speed);
		if (conn == null || conn.crossing_risk) {
			if (conn != null) {
				::MT.safety.Veto("road route through a level crossing", c.key);
				Log.Warn("SAFETY", "road route refused: the vehicles would likely take a level crossing");
			} else Log.Warn("PLAN", "no road route " + Util.TileStr(spot_a.tile) + " - " + Util.TileStr(spot_b.tile));
			undo();
			return false;
		}
		local trees = ::MT.landscape.CountTrees(conn.path);
		::MT.finance.Ensure(::MT.road.NewPieces(conn.path) * AIRoad.GetBuildCost(AIRoad.ROADTYPE_ROAD, AIRoad.BT_ROAD) * 2 + 20000);
		if (!::MT.road.BuildPath(conn.path, speed)) {
			::MT.road.RemoveUnused(::MT.road.built);
			undo();
			return false;
		}
		local new_road = ::MT.road.built;
		local da = ::MT.road.BuildDepotNear(this.RoadEnd(spot_a));
		local db = c.two_way ? ::MT.road.BuildDepotNear(this.RoadEnd(spot_b)) : -1;
		if (da < 0 && db < 0) {
			Log.Warn("PLAN", "no depot site for the road route");
			::MT.road.RemoveUnused(new_road);
			undo();
			return false;
		}
		if (da < 0) { da = db; db = -1; }
		local route = this.NewRoute(c);
		route.sids = [sa, sb];
		route.tiles = [spot_a.tile, spot_b.tile];
		route.depots = [da, db];
		route.capacity = c.best.capacity;
		route.speed = speed;
		route.dist = AIMap.DistanceManhattan(spot_a.tile, spot_b.tile);
		route.path_len = conn.path.len();
		route.est_rtt = ::MT.economy.RoundTrip(MODE_ROAD, route.speed, route.path_len, route.capacity);
		route.track_tiles = conn.path;
		route.new_road = new_road;
		route.trees_cut = trees;
		route.cost = c.infra.tointeger();
		if ("feeder" in c) { route.feeder = true; route.est_profit = -1; }
		::MT.routes.Add(route);
		if (c.two_way) {
			this.RegisterStation(c.a.id, sa, MODE_ROAD);
			this.RegisterStation(c.b.id, sb, MODE_ROAD);
		}
		local first = min(2, max(1, c.best.eval.n));
		for (local i = 0; i < first; i++) ::MT.fleet.BuildFor(route, i % 2);
		::MT.landscape.Replant(conn.path, trees);
		this.Opened(route, conn.path.len() + " road tiles (" + new_road.len() + " new), " + AIEngine.GetName(c.engine) +
			", round trip about " + route.est_rtt.tointeger() + " days");
		return true;
	}

	/* ---------------- air ---------------- */

	/*
	 * The town's airport, or a new one: the type the plan was scored with, else a smaller one the planned
	 * aircraft can still use. A plan for large aircraft never ends at a short strip, where only small aircraft
	 * could fly and the route would earn far less than planned: the plan is dropped instead, and the next
	 * round plans the town with the types that are left.
	 */
	function EnsureAirport(town, want, big) {
		local hub = ::MT.routes.Hub(town);
		if (AIStation.IsValidStation(hub.air_sid) && AIAirport.IsAirportTile(hub.air_tile)) return [hub.air_tile, false];
		local types = [want];
		foreach (t in ::MT.air.ChooseTypes(AITown.GetPopulation(town), ::MT.finance.Available())) {
			if (t != want && !(big && ::MT.safety.IsShortStrip(t))) types.append(t);
		}
		foreach (t in types) {
			local join = this.JoinId(town);
			local tile = ::MT.air.FindSite(town, t, join);
			if (tile < 0 && join != AIStation.STATION_NEW) { join = AIStation.STATION_NEW; tile = ::MT.air.FindSite(town, t, join); }
			if (tile < 0) {
				::MT.planner.MarkNoAirport(town, t);
				continue;
			}
			if (!::MT.finance.Ensure(AIAirport.GetPrice(t) + 5000)) return null;
			local sid = ::MT.air.Build(tile, t, join);
			if (sid < 0 && join != AIStation.STATION_NEW) sid = ::MT.air.Build(tile, t, AIStation.STATION_NEW);
			if (sid < 0) continue;
			hub.air_sid = sid;
			hub.air_tile = tile;
			if (!AIStation.IsValidStation(hub.sid)) hub.sid = sid;
			Log.Info("BUILD", ::MT.air.TypeName(t) + " airport for " + Util.TownName(town) + " at " + Util.TileStr(tile));
			local w = AIAirport.GetAirportWidth(t), h = AIAirport.GetAirportHeight(t);
			::MT.landscape.GreenBelt([tile, tile + (w - 1), tile + (h - 1) * Geo.MX, tile + (w - 1) + (h - 1) * Geo.MX], 12);
			return [tile, true];
		}
		Log.Info("PLAN", "no room for a " + ::MT.air.TypeName(want) + " airport at " + Util.TownName(town) + (big ? " or another one for large aircraft" : ""));
		return null;
	}

	function BuildAir(c) {
		local a = c.a.id, b = c.b.id;
		local big = AIEngine.GetPlaneType(c.engine) == AIAirport.PT_BIG_PLANE;
		local ea = this.EnsureAirport(a, c.type_a, big);
		if (ea == null) return false;
		local eb = this.EnsureAirport(b, c.type_b, big);
		if (eb == null) { this.DropAirport(a, ea); return false; }
		local ta = AIAirport.GetAirportType(ea[0]), tb = AIAirport.GetAirportType(eb[0]);
		local best = ::MT.engines.BestAircraft(ea[0], eb[0], ta, tb, c.supply);
		if (best == null) {
			Log.Warn("PLAN", "no aircraft for " + ::MT.air.TypeName(ta) + " / " + ::MT.air.TypeName(tb) + " airports");
			this.DropAirport(a, ea);
			this.DropAirport(b, eb);
			return false;
		}
		local route = this.NewRoute(c);
		route.engine = best.engine;
		route.sids = [AIStation.GetStationID(ea[0]), AIStation.GetStationID(eb[0])];
		route.tiles = [ea[0], eb[0]];
		route.depots = [AIAirport.GetHangarOfAirport(ea[0]), AIAirport.GetHangarOfAirport(eb[0])];
		route.capacity = best.capacity;
		route.speed = AIEngine.GetMaxSpeed(best.engine);
		route.dist = AIMap.DistanceManhattan(ea[0], eb[0]);
		route.path_len = ::MT.economy.AirTiles(ea[0], eb[0]);
		route.est_rtt = ::MT.economy.RoundTrip(MODE_AIR, route.speed, route.path_len, route.capacity);
		route.cost = c.infra.tointeger();
		::MT.routes.Add(route);
		::MT.fleet.BuildFor(route, 0);
		::MT.fleet.BuildFor(route, 1);
		local risk = ::MT.safety.LandingProbability(best.engine);
		this.Opened(route, AIEngine.GetName(best.engine) + " (" + (AIEngine.GetPlaneType(best.engine) == AIAirport.PT_BIG_PLANE ? "large" : "small") +
			" aircraft, " + ::MT.air.TypeName(ta) + " / " + ::MT.air.TypeName(tb) + " airports" +
			(risk > 0 ? ", random crash risk " + ::MT.safety.PercentText(risk) + " per landing" : "") + "), " + route.dist +
			" tiles, round trip about " + route.est_rtt.tointeger() + " days");
		return true;
	}

	/* Remove an airport we just built for a plan that failed (no aircraft can be heading there yet). */
	function DropAirport(town, ea) {
		if (ea == null || !ea[1]) return;
		if (AIVehicleList_Station(AIStation.GetStationID(ea[0])).Count() > 0) return;
		local hub = ::MT.routes.Hub(town);
		if (hub.sid == hub.air_sid) hub.sid = -1;
		hub.air_sid = -1;
		hub.air_tile = -1;
		AIAirport.RemoveAirport(ea[0]);
	}

	/* ---------------- water ---------------- */

	function BuildShip(c) {
		local src = c.a.id, dst = c.b.id;
		local rig = AIIndustry.HasDock(src) && AIIndustry.IsBuiltOnWater(src);
		local from_sets = [];
		if (rig) {
			local ap = ::MT.water.RigApproach(src);
			if (ap.len() > 0) from_sets.append({site = null, approach = ap, tile = AIIndustry.GetDockLocation(src)});
		} else {
			foreach (s in ::MT.water.DockSites({kind = "pickup", ind = src, cargo = c.cargo}, 4)) from_sets.append({site = s, approach = ::MT.water.Approach(s), tile = s.tile});
		}
		local to_sites = ::MT.water.DockSites({kind = "drop", ind = dst, cargo = c.cargo}, 4);
		Log.Debug("DEBUG", "ship: " + from_sets.len() + " source dock sites, " + to_sites.len() + " destination dock sites");
		if (from_sets.len() == 0 || to_sites.len() == 0) {
			Log.Warn("PLAN", "no dock site at " + (from_sets.len() == 0 ? Util.IndustryName(src) : Util.IndustryName(dst)));
			::MT.planner.MarkNoSite(MODE_WATER, from_sets.len() == 0 ? c.a : c.b);
			return false;
		}
		local pick = null, lane = -1;
		foreach (f in from_sets) {
			foreach (t in to_sites) {
				lane = ::MT.water.Lane(f.approach, ::MT.water.Approach(t), min(60000, 400 * max(20, c.dist)));
				/* cargo is paid on the straight distance: a long way round the coast does not pay */
				if (lane > 0 && lane <= c.dist * 1.8 + 20) { pick = [f, t]; break; }
			}
			if (pick != null || Util.Today() - ::MT.planner.last_build > 60) break;
		}
		if (pick == null) { Log.Warn("PLAN", "no shipping lane " + Util.IndustryName(src) + " - " + Util.IndustryName(dst)); return false; }
		local tiles = lane * 0.85;
		local best = ::MT.engines.BestShip(c.cargo, tiles, c.dist, c.supply, false);
		Log.Debug("DEBUG", "ship: lane of " + lane + " tiles, best " + (best == null ? "none" : AIEngine.GetName(best.engine)));
		if (best == null) return false;
		if (!::MT.finance.Ensure((c.infra + AIEngine.GetPrice(best.engine)).tointeger())) { Log.Warn("PLAN", "not enough money for the ships"); return false; }
		local sa = -1;
		if (pick[0].site != null) {
			sa = ::MT.water.BuildDock(pick[0].site, AIStation.STATION_NEW);
			if (sa < 0) return false;
		}
		local sb = ::MT.water.BuildDock(pick[1], AIStation.STATION_NEW);
		if (sb < 0) {
			if (pick[0].site != null) AIMarine.RemoveDock(pick[0].site.tile);
			return false;
		}
		local depot = pick[0].site != null ? ::MT.water.BuildDepotNear(pick[0].site) : ::MT.water.BuildDepotNear(pick[1]);
		if (depot < 0) {
			Log.Warn("PLAN", "no ship depot site");
			if (pick[0].site != null) AIMarine.RemoveDock(pick[0].site.tile);
			AIMarine.RemoveDock(pick[1].tile);
			return false;
		}
		local route = this.NewRoute(c);
		route.engine = best.engine;
		route.sids = [sa, sb];
		route.tiles = [pick[0].tile, pick[1].tile];
		route.depots = [depot, -1];
		route.capacity = best.capacity;
		route.speed = AIEngine.GetMaxSpeed(best.engine);
		route.dist = AIMap.DistanceManhattan(route.tiles[0], route.tiles[1]);
		route.path_len = tiles;
		route.est_rtt = ::MT.economy.RoundTrip(MODE_WATER, route.speed, tiles, route.capacity);
		route.cost = c.infra.tointeger();
		::MT.routes.Add(route);
		local first = min(2, max(1, best.eval.n));
		for (local i = 0; i < first; i++) ::MT.fleet.BuildFor(route, 0);
		this.Opened(route, (rig ? "from the rig's own dock, " : "") + lane + " tiles of water, " + AIEngine.GetName(best.engine) +
			", round trip about " + route.est_rtt.tointeger() + " days");
		return true;
	}

	/* Passenger ferry between two coastal towns; the docks join the towns' hub stations where they can. */
	function BuildFerry(c) {
		local a = c.a.id, b = c.b.id;
		local sites_a = ::MT.water.DockSites({kind = "town", town = a}, 4);
		local sites_b = ::MT.water.DockSites({kind = "town", town = b}, 4);
		if (sites_a.len() == 0 || sites_b.len() == 0) {
			Log.Warn("PLAN", "no dock site in " + Util.TownName(sites_a.len() == 0 ? a : b));
			::MT.planner.MarkNoSite(MODE_WATER, sites_a.len() == 0 ? c.a : c.b);
			return false;
		}
		local pick = null, lane = -1;
		foreach (sa in sites_a) {
			foreach (sb in sites_b) {
				lane = ::MT.water.Lane(::MT.water.Approach(sa), ::MT.water.Approach(sb), min(60000, 400 * max(20, c.dist)));
				if (lane > 0 && lane <= c.dist * 1.6 + 15) { pick = [sa, sb]; break; }
			}
			if (pick != null) break;
		}
		if (pick == null) { Log.Warn("PLAN", "no ferry lane " + Util.TownName(a) + " - " + Util.TownName(b)); return false; }
		local tiles = lane * 0.85;
		local best = ::MT.engines.BestShip(Util.pax, tiles, c.dist, c.supply, true);
		if (best == null) return false;
		if (!::MT.finance.Ensure((c.infra + 2 * AIEngine.GetPrice(best.engine)).tointeger())) return false;
		local da = ::MT.water.BuildDock(pick[0], this.JoinId(a));
		if (da < 0) return false;
		local db = ::MT.water.BuildDock(pick[1], this.JoinId(b));
		if (db < 0) { AIMarine.RemoveDock(pick[0].tile); return false; }
		local depot = ::MT.water.BuildDepotNear(pick[0]);
		if (depot < 0) depot = ::MT.water.BuildDepotNear(pick[1]);
		if (depot < 0) {
			Log.Warn("PLAN", "no ship depot site");
			AIMarine.RemoveDock(pick[0].tile);
			AIMarine.RemoveDock(pick[1].tile);
			return false;
		}
		local route = this.NewRoute(c);
		route.engine = best.engine;
		route.sids = [da, db];
		route.tiles = [pick[0].tile, pick[1].tile];
		route.depots = [depot, -1];
		route.capacity = best.capacity;
		route.speed = AIEngine.GetMaxSpeed(best.engine);
		route.dist = AIMap.DistanceManhattan(route.tiles[0], route.tiles[1]);
		route.path_len = tiles;
		route.est_rtt = ::MT.economy.RoundTrip(MODE_WATER, route.speed, tiles, route.capacity);
		route.cost = c.infra.tointeger();
		::MT.routes.Add(route);
		this.RegisterStation(a, da, MODE_WATER);
		this.RegisterStation(b, db, MODE_WATER);
		local first = min(2, max(1, best.eval.n));
		for (local i = 0; i < first; i++) ::MT.fleet.BuildFor(route, i % 2);
		this.Opened(route, lane + " tiles of water, " + AIEngine.GetName(best.engine) + ", round trip about " + route.est_rtt.tointeger() + " days");
		return true;
	}

	/* ---------------- rail ---------------- */

	function Target(e, cargo, pickup) {
		if (e.type == END_TOWN) return {kind = "town", town = e.id};
		return {kind = pickup ? "pickup" : "drop", ind = e.id, cargo = cargo};
	}

	function EndLocation(e) { return e.type == END_TOWN ? AITown.GetLocation(e.id) : AIIndustry.GetLocation(e.id); }

	function Footprints(site_a, site_b) {
		local t = {};
		foreach (x in ::MT.rail.Footprint(site_a)) t[x] <- true;
		foreach (x in ::MT.rail.Footprint(site_b)) t[x] <- true;
		return t;
	}

	/*
	 * A doubled, signalled passenger line ending in `town` whose station a new line can share (via a junction
	 * on its tracks): both lines then meet in one station and CargoDist routes transfers through it.
	 */
	function SharedRailEnd(town) {
		foreach (route in ::MT.routes.Active()) {
			if (route.mode != MODE_RAIL || !route.two_way || !route.double_track || route.branch) continue;
			for (local end = 0; end < 2; end++) {
				if (route.Town(end) != town) continue;
				if (::MT.routes.RoutesAt(route.sids[end]).len() >= 3) continue;
				return {route = route, end = end, site = route.sites[end]};
			}
		}
		return null;
	}

	function BuildRail(c) {
		local L = ::MT.planner.PlatformLength();
		local plan = c.best.plan;
		local rt = plan.railtype;
		::MT.rail.line_speed = plan.speed;
		if (c.two_way) {
			local sa = this.SharedRailEnd(c.a.id), sb = this.SharedRailEnd(c.b.id);
			if ((sa != null || sb != null) && this.BuildRailShared(c, sa, sb)) return true;
		}
		AIRail.SetCurrentRailType(rt);
		local join_a = c.two_way ? this.JoinId(c.a.id) : AIStation.STATION_NEW;
		local join_b = c.two_way ? this.JoinId(c.b.id) : AIStation.STATION_NEW;
		local town_a = c.a.type == END_TOWN ? c.a.id : AITile.GetClosestTown(this.EndLocation(c.a));
		local town_b = c.b.type == END_TOWN ? c.b.id : AITile.GetClosestTown(this.EndLocation(c.b));
		local site_a = ::MT.rail.FindSite(this.Target(c.a, c.cargo, true), this.EndLocation(c.b), L, rt, join_a, null);
		if (site_a == null) { ::MT.planner.MarkNoSite(MODE_RAIL, c.a); return false; }
		local reserved = {};
		foreach (t in ::MT.rail.Footprint(site_a)) reserved[t] <- true;
		local site_b = ::MT.rail.FindSite(this.Target(c.b, c.cargo, false), site_a.O, L, rt, join_b, reserved);
		if (site_b == null) { ::MT.planner.MarkNoSite(MODE_RAIL, c.b); return false; }
		local trees = ::MT.landscape.CountTrees(::MT.rail.Footprint(site_a)) + ::MT.landscape.CountTrees(::MT.rail.Footprint(site_b));
		if (!::MT.finance.Ensure(c.first_cost.tointeger())) return false;
		if (!::MT.rail.BuildStation(site_a, join_a, town_a)) { ::MT.rail.Demolish(::MT.rail.Footprint(site_a)); return false; }
		if (!::MT.rail.BuildStation(site_b, join_b, town_b)) {
			::MT.rail.Demolish(::MT.rail.Footprint(site_a));
			::MT.rail.Demolish(::MT.rail.Footprint(site_b));
			return false;
		}
		foreach (site in [site_a, site_b]) foreach (row in [0, 1]) ::MT.rail.ReserveCorridor(site, row);
		::MT.rail.UsePlaceholders([site_a, site_b]);
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::MT.routes.ReservedRail()) forbidden[t] <- true;
		foreach (t in [::MT.rail.T(site_a, 0, -4), ::MT.rail.T(site_b, 1, -4), ::MT.rail.T(site_a, 0, -5), ::MT.rail.T(site_b, 1, -5)]) {
			if (t in forbidden) delete forbidden[t];
		}
		/* keep the way out of B and into A free for the second track */
		foreach (t in ::MT.rail.OtherCorridor(site_a, 1)) forbidden[t] <- true;
		foreach (t in ::MT.rail.OtherCorridor(site_b, 0)) forbidden[t] <- true;
		::MT.rail.twin_shift = site_a.o == Geo.Opp(site_b.o) ? Geo.Offset(site_a.lat) : 0;
		local p1 = ::MT.rail.BuildTrack(site_a, site_b, forbidden, null, rt);
		local twin_shift = ::MT.rail.twin_shift;
		::MT.rail.twin_shift = 0;
		if (p1 == null || ::MT.rail.Verify(p1) >= 0) {
			Log.Warn("PLAN", "no railway " + this.Describe2(c));
			if (::MT.rail.trapped) ::MT.rail.bad_sites[site_a.O] <- Util.Today();
			if (::MT.rail.trapped_goal) ::MT.rail.bad_sites[site_b.O] <- Util.Today();
			if (p1 != null) ::MT.rail.RemovePath(p1, p1.len() - 1);
			foreach (site in [site_a, site_b]) foreach (row in [0, 1]) ::MT.rail.FreeCorridor(site, row);
			::MT.rail.Demolish(::MT.rail.Footprint(site_a));
			::MT.rail.Demolish(::MT.rail.Footprint(site_b));
			return false;
		}
		trees += ::MT.rail.last_trees;
		local path_len = ::MT.rail.PathLength(p1) + 2 * L;
		/* the estimate is checked in the new depot: the train must fit the platforms and couple */
		local exact = ::MT.engines.BestTrain(L, c.cargo, path_len, c.dist, c.supply * (c.two_way ? 1.4 : 1.0), c.two_way, rt, site_a.depot, 1);
		if (exact != null) plan = exact.plan;
		local route = this.NewRoute(c);
		route.engine = plan.loco;
		route.wagon = plan.wagon == null ? -1 : plan.wagon;
		route.wagons = plan.wagons;
		route.railtype = rt;
		route.sites = [site_a, site_b];
		route.sids = [site_a.sid, site_b.sid];
		route.tiles = [::MT.rail.T(site_a, 0, 0), ::MT.rail.T(site_b, 0, 0)];
		route.depots = [site_a.depot, site_b.depot];
		route.p1 = ::MT.rail.Encode(p1);
		route.track_tiles = ::MT.rail.PathTiles(p1);
		if (twin_shift != 0) route.twin = ::MT.rail.TwinTiles(p1, twin_shift);
		route.turns = ::MT.rail.Turns(p1);
		route.capacity = plan.capacity;
		route.speed = plan.speed;
		route.dist = AIMap.DistanceManhattan(route.tiles[0], route.tiles[1]);
		route.path_len = path_len;
		route.est_rtt = ::MT.economy.RoundTrip(MODE_RAIL, route.speed, route.path_len, route.capacity);
		route.trees_cut = trees;
		route.cost = c.infra.tointeger();
		::MT.routes.Add(route);
		if (c.two_way) {
			this.RegisterStation(c.a.id, site_a.sid, MODE_RAIL);
			this.RegisterStation(c.b.id, site_b.sid, MODE_RAIL);
		}
		::MT.landscape.Replant(route.track_tiles, trees);
		foreach (i, site in [site_a, site_b]) if (route.ends[i].type == END_TOWN) ::MT.landscape.GreenBelt(::MT.rail.Platforms(site), 10);
		/* With money to spare the second track goes in at once (the way out of a growing town is still free). */
		if (::MT.finance.Cash() - ::MT.finance.Reserve() > 3 * c.first_cost + 400000) this.UpgradeRail(route);
		local v = ::MT.fleet.BuildFor(route, 0);
		this.Opened(route, p1.len() + " track tiles with " + route.turns + " curve steps, " + AIRail.GetName(rt) + ", " +
			AIEngine.GetName(plan.loco) + (plan.wagons > 0 ? " + " + plan.wagons + " x " + AIEngine.GetName(plan.wagon) : "") +
			", " + plan.capacity + " " + Util.CargoName(c.cargo) + ", " + plan.speed + " km/h, " +
			(route.double_track ? "double track" : "single track, one train") + (v < 0 ? " - first train failed" : ""));
		if (v < 0) ::MT.fleet.Repick(route);
		return true;
	}

	function Describe2(c) { return ::MT.planner.EndName(c.a) + " - " + ::MT.planner.EndName(c.b); }

	/* Passenger line that shares the station of an existing doubled line at one or both ends. */
	function BuildRailShared(c, sa, sb) {
		local base = sa != null ? sa.route : sb.route;
		local rt = base.railtype;
		if (sa != null && sb != null && sa.route.railtype != sb.route.railtype) return false;
		local L = sa != null ? sa.site.L : sb.site.L;
		if (sa != null && sb != null) L = min(sa.site.L, sb.site.L);
		local tiles = c.dist * 1.2;
		local best = ::MT.engines.BestTrain(L, Util.pax, tiles, c.dist, c.supply, true, rt, (sa != null ? sa : sb).site.depot);
		if (best == null) return false;
		::MT.rail.line_speed = best.plan.speed;
		local site_a = sa != null ? sa.site : null, site_b = sb != null ? sb.site : null;
		local reserved = {};
		if (site_a == null) {
			site_a = ::MT.rail.FindSite({kind = "town", town = c.a.id}, site_b != null ? site_b.O : AITown.GetLocation(c.b.id), L, rt, this.JoinId(c.a.id), null);
			if (site_a == null) return false;
		}
		foreach (t in ::MT.rail.Footprint(site_a)) reserved[t] <- true;
		if (site_b == null) {
			site_b = ::MT.rail.FindSite({kind = "town", town = c.b.id}, site_a.O, L, rt, this.JoinId(c.b.id), reserved);
			if (site_b == null) return false;
		}
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::MT.routes.ReservedRail()) forbidden[t] <- true;
		local start1 = null, goal1 = null, start2 = null, goal2 = null;
		if (sa != null) {
			local pa = ::MT.rail.StationPaths(sa.route, sa.end);
			start1 = ::MT.rail.BranchPoint(pa.dep, forbidden);
			goal2 = ::MT.rail.MergePoint(pa.arr, forbidden);
			if (start1 == null || goal2 == null) return false;
		}
		if (sb != null) {
			local pb = ::MT.rail.StationPaths(sb.route, sb.end);
			start2 = ::MT.rail.BranchPoint(pb.dep, forbidden);
			goal1 = ::MT.rail.MergePoint(pb.arr, forbidden);
			if (start2 == null || goal1 == null) return false;
		}
		local cost = AIRail.GetBuildCost(rt, AIRail.BT_TRACK) * tiles * 2.6 + best.plan.price * 2 + 30000;
		if (!::MT.finance.Ensure(cost.tointeger())) return false;
		local new_a = sa == null, new_b = sb == null;
		if (new_a && !::MT.rail.BuildStation(site_a, this.JoinId(c.a.id), c.a.id)) { ::MT.rail.Demolish(::MT.rail.Footprint(site_a)); return false; }
		if (new_b && !::MT.rail.BuildStation(site_b, this.JoinId(c.b.id), c.b.id)) {
			if (new_a) ::MT.rail.Demolish(::MT.rail.Footprint(site_a));
			::MT.rail.Demolish(::MT.rail.Footprint(site_b));
			return false;
		}
		local fresh = [];
		if (new_a) fresh.append(site_a);
		if (new_b) fresh.append(site_b);
		foreach (site in fresh) foreach (row in [0, 1]) ::MT.rail.ReserveCorridor(site, row);
		::MT.rail.UsePlaceholders(fresh);
		if (start1 == null) start1 = ::MT.rail.TerminusStart(site_a);
		if (goal1 == null) goal1 = ::MT.rail.TerminusGoal(site_b);
		if (start2 == null) start2 = ::MT.rail.TerminusStart(site_b);
		if (goal2 == null) goal2 = ::MT.rail.TerminusGoal(site_a);
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
		local p2 = null, trees = fail ? 0 : ::MT.rail.last_trees;
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
			if (!fail) trees += ::MT.rail.last_trees;
		}
		if (fail) {
			Log.Warn("PLAN", "no railway " + this.Describe2(c) + " through the shared station");
			if (::MT.rail.trapped || ::MT.rail.trapped_goal) {
				if (new_a) ::MT.rail.bad_sites[site_a.O] <- Util.Today();
				if (new_b) ::MT.rail.bad_sites[site_b.O] <- Util.Today();
			}
			foreach (p in [p1, p2]) {
				if (p == null) continue;
				::MT.rail.RemovePath(p, p.len() - 1);
				if (p.len() > 1 && p[0].tile != start1.tile && p[0].tile != start2.tile) AIRail.RemoveRail(p[0].tile, p[0].tile, p[1].tile);
			}
			if (start1.sw != null) AIRail.RemoveRail(start1.sw[0], start1.sw[1], start1.sw[2]);
			if (start2.sw != null) AIRail.RemoveRail(start2.sw[0], start2.sw[1], start2.sw[2]);
			if (goal1.merge != null) AIRail.RemoveRail(goal1.merge[0], goal1.merge[1], goal1.merge[2]);
			if (goal2.merge != null) AIRail.RemoveRail(goal2.merge[0], goal2.merge[1], goal2.merge[2]);
			foreach (site in fresh) foreach (row in [0, 1]) ::MT.rail.FreeCorridor(site, row);
			if (new_a) ::MT.rail.Demolish(::MT.rail.Footprint(site_a));
			if (new_b) ::MT.rail.Demolish(::MT.rail.Footprint(site_b));
			return false;
		}
		local sig = ::MT.rail.SignalPair(p1, p2, rt);
		if (new_a) ::MT.rail.BuildThroatSignals(site_a);
		if (new_b) ::MT.rail.BuildThroatSignals(site_b);
		local route = this.NewRoute(c);
		route.branch = true;
		route.engine = best.plan.loco;
		route.wagon = best.plan.wagon == null ? -1 : best.plan.wagon;
		route.wagons = best.plan.wagons;
		route.railtype = rt;
		route.sites = [site_a, site_b];
		route.sids = [site_a.sid, site_b.sid];
		route.tiles = [::MT.rail.T(site_a, 0, 0), ::MT.rail.T(site_b, 0, 0)];
		route.depots = [site_a.depot, site_b.depot];
		route.p1 = ::MT.rail.Encode(p1);
		route.p2 = ::MT.rail.Encode(p2);
		route.double_track = true;
		route.signal_blocks = min(sig[0], sig[1]);
		route.track_tiles = ::MT.rail.PathTiles(p1);
		route.track_tiles.extend(::MT.rail.PathTiles(p2));
		route.turns = ::MT.rail.Turns(p1);
		route.capacity = best.plan.capacity;
		route.speed = best.plan.speed;
		route.dist = AIMap.DistanceManhattan(route.tiles[0], route.tiles[1]);
		route.path_len = ::MT.rail.PathLength(p1) + 2 * L;
		route.est_rtt = ::MT.economy.RoundTrip(MODE_RAIL, route.speed, route.path_len, route.capacity);
		route.trees_cut = trees;
		route.cost = cost.tointeger();
		::MT.routes.Add(route);
		if (new_a) this.RegisterStation(c.a.id, site_a.sid, MODE_RAIL);
		if (new_b) this.RegisterStation(c.b.id, site_b.sid, MODE_RAIL);
		::MT.landscape.Replant(route.track_tiles, trees);
		::MT.fleet.BuildFor(route, 0);
		::MT.fleet.BuildFor(route, 1);
		this.Opened(route, "sharing " + (sa != null ? AIStation.GetName(site_a.sid) : "") + (sa != null && sb != null ? " and " : "") +
			(sb != null ? AIStation.GetName(site_b.sid) : "") + ": " + p1.len() + " + " + p2.len() + " track tiles, signals " + sig[0] + " + " + sig[1] +
			", " + ::MT.rail.ParallelShare(p1, p2) + "% of the second track alongside the first");
		return true;
	}

	function UpgradeCost(route) {
		local rt = route.railtype;
		return AIRail.GetBuildCost(rt, AIRail.BT_TRACK) * route.p1.len() * 1.3 + AIRail.GetBuildCost(rt, AIRail.BT_SIGNAL) * route.p1.len() / 3 +
			AIEngine.GetPrice(route.engine);
	}

	/* Second track alongside the first, then one-way path signals side by side on both. */
	function UpgradeRail(route) {
		local site_a = route.sites[0], site_b = route.sites[1];
		local rt = route.railtype;
		::MT.rail.line_speed = route.speed;
		local p1 = ::MT.rail.Decode(route.p1);
		local forbidden = this.Footprints(site_a, site_b);
		foreach (t, _ in ::MT.routes.ReservedRail()) forbidden[t] <- true;
		foreach (t in [::MT.rail.T(site_b, 0, -4), ::MT.rail.T(site_a, 1, -4), ::MT.rail.T(site_b, 0, -5), ::MT.rail.T(site_a, 1, -5)]) {
			if (t in forbidden) delete forbidden[t];
		}
		foreach (t in route.twin) if (t in forbidden) delete forbidden[t];   // kept free for exactly this track
		local prefer = {};
		foreach (t in ::MT.rail.PathTiles(p1)) {
			forbidden[t] <- true;
			for (local d = 0; d < 4; d++) prefer[t + Geo.Offset(d)] <- true;
		}
		if (!::MT.finance.Ensure(this.UpgradeCost(route).tointeger())) return false;
		Log.Info("PLAN", route.Name() + ": laying the second track");
		::MT.rail.UsePlaceholders([site_a, site_b]);
		local p2 = null;
		/* first the twin of the first track, one tile to the side */
		if (site_a.o == Geo.Opp(site_b.o)) {
			local pf = RailPathFinder(::MT.bridges);
			pf.speed = route.speed;
			pf.forbidden = forbidden;
			if (::MT.rail.own_free != null) pf.own_free = ::MT.rail.own_free;
			local ends = ::MT.rail.Ends(site_b, site_a);
			local plan = ::MT.rail.ParallelPath(pf, p1, Geo.Offset(site_a.lat), ends.start, ends.goal);
			if (plan != null) p2 = ::MT.rail.BuildGivenPath(plan, rt);
			Log.Info("BUILD", route.Name() + ": parallel second track " + (p2 != null ? "laid" : (plan == null ? "does not fit" : "failed")));
		}
		if (p2 == null) {
			local guide = [];
			for (local i = p1.len() - 1; i >= 0; i--) guide.append(p1[i].tile);
			::MT.rail.guide = guide;
			::MT.rail.guide_share = ::MT.rail.ShareTable(p1);
			p2 = ::MT.rail.BuildTrack(site_b, site_a, forbidden, prefer, rt);
			::MT.rail.guide = null;
			::MT.rail.guide_share = null;
		}
		if (p2 != null && route.state != ROUTE_ACTIVE) {
			::MT.rail.RemovePath(p2, p2.len() - 1);   // the route closed while its second track was searched
			return false;
		}
		if (p2 == null || ::MT.rail.Verify(p2) >= 0) {
			Log.Warn("PLAN", route.Name() + ": no route for a second track; stays a single-train line for now");
			if (p2 != null) ::MT.rail.RemovePath(p2, p2.len() - 1);
			::MT.rail.ReserveCorridor(site_a, 1);
			::MT.rail.ReserveCorridor(site_b, 0);
			route.note = "";
			route.upgrade_failed = Util.Today();
			return false;
		}
		::MT.landscape.Replant(::MT.rail.PathTiles(p2), ::MT.rail.last_trees);
		route.trees_cut += ::MT.rail.last_trees;
		route.track_tiles.extend(::MT.rail.PathTiles(p2));
		route.p2 = ::MT.rail.Encode(p2);
		route.twin = [];
		return this.InstallSignals(route, p2);
	}

	/* Phase two of a doubling: park the trains, signal both tracks, restart. */
	function InstallSignals(route, p2) {
		local site_a = route.sites[0], site_b = route.sites[1];
		local p1 = ::MT.rail.Decode(route.p1);
		if (!this.ParkTrains(route)) {
			Log.Warn("SAFETY", route.Name() + ": trains did not reach the depot; signals postponed");
			this.RestartTrains(route);
			route.note = "signals";
			return false;
		}
		/* the yearly review may have closed the route while its trains were parking */
		if (route.state != ROUTE_ACTIVE) return false;
		local sig = ::MT.rail.SignalPair(p1, p2, route.railtype);
		::MT.rail.BuildThroatSignals(site_a);
		::MT.rail.BuildThroatSignals(site_b);
		route.double_track = true;
		route.signal_blocks = min(sig[0], sig[1]);
		route.note = "";
		this.RestartTrains(route);
		Log.Info("BUILD", route.Name() + ": double track, " + ::MT.rail.ParallelShare(p1, p2) + "% of it side by side, signals " +
			sig[0] + " + " + sig[1] + "; up to " + ::MT.fleet.MaxVehicles(route) + " trains");
		::MT.fleet.BuildFor(route, 1);
		return true;
	}

	function ParkTrains(route) {
		foreach (v, _ in route.Vehicles()) {
			if (!AIVehicle.IsStoppedInDepot(v) && !AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);
		}
		for (local i = 0; i < 90; i++) {
			local all = true;
			foreach (v, _ in route.Vehicles()) if (!AIVehicle.IsStoppedInDepot(v)) { all = false; break; }
			if (all) return true;
			AIController.Sleep(DAY_TICKS);
			/* the AI only waits here: the calendar work costs nothing */
			MT_Housekeeping();
			::MT.ai.Periodic(true);
		}
		return false;
	}

	function RestartTrains(route) {
		foreach (v, _ in route.Vehicles()) {
			if (v in ::MT.fleet.to_sell) continue;
			if (AIVehicle.IsStoppedInDepot(v)) AIVehicle.StartStopVehicle(v);
			else if (AIOrder.IsGotoDepotOrder(v, AIOrder.ORDER_CURRENT)) AIVehicle.SendVehicleToDepot(v);
		}
	}

	/* ---------------- interchanges ---------------- */

	/* A town whose airport is not part of its hub station gets a shuttle bus between the two (CargoDist transfers). */
	function Interchanges() {
		if (!::MT.game.allow[MODE_ROAD] || !::MT.game.pax_on) return false;
		foreach (town, hub in ::MT.routes.hubs) {
			if (!AIStation.IsValidStation(hub.air_sid) || !AIStation.IsValidStation(hub.sid) || hub.air_sid == hub.sid || hub.shuttle) continue;
			hub.shuttle = true;
			local s1 = ::MT.road.FindStop(AIStation.GetLocation(hub.sid), 6, hub.sid, Util.pax, AIRoad.ROADVEHTYPE_BUS);
			local s2 = ::MT.road.FindStop(AIStation.GetLocation(hub.air_sid), 7, hub.air_sid, Util.pax, AIRoad.ROADVEHTYPE_BUS);
			if (s1 == null || s2 == null) continue;
			local d = AIMap.DistanceManhattan(s1.tile, s2.tile);
			local best = ::MT.engines.BestRoad(Util.pax, d + 2, d, 60, true);
			if (best == null) continue;
			local c = {mode = MODE_ROAD, cargo = Util.pax, a = {type = END_TOWN, id = town}, b = {type = END_TOWN, id = town}, two_way = true,
				engine = best.engine, best = best, first_cost = 30000.0, infra = 10000, key = "shuttle:" + town, supply = 60};
			Log.Info("PLAN", "interchange shuttle " + AIStation.GetName(hub.sid) + " <-> " + AIStation.GetName(hub.air_sid));
			c.feeder <- true;
			if (this.BuildRoadRoute(c, s1, s2, hub.sid, hub.air_sid, AIRoad.ROADVEHTYPE_BUS)) return true;
		}
		return false;
	}

	/* ---------------- cleanup ---------------- */

	function UsedElsewhere(route, sid) {
		foreach (r in ::MT.routes.Open()) if (r != route && (r.sids[0] == sid || r.sids[1] == sid)) return true;
		return false;
	}

	function DepotUsedElsewhere(route, depot) {
		foreach (r in ::MT.routes.Open()) if (r != route && (r.depots[0] == depot || r.depots[1] == depot)) return true;
		return false;
	}

	/* Remove what a closed route built and no other route uses: stations, depots, track, new roads. */
	function Cleanup(route) {
		if (route.mode == MODE_ROAD) {
			foreach (i, sid in route.sids) {
				if (sid < 0 || this.UsedElsewhere(route, sid) || !AIRoad.IsRoadStationTile(route.tiles[i])) continue;
				AIRoad.RemoveRoadStation(route.tiles[i]);
			}
			foreach (d in route.depots) if (d >= 0 && AIRoad.IsRoadDepotTile(d) && !this.DepotUsedElsewhere(route, d)) AITile.DemolishTile(d);
			::MT.road.RemoveUnused(route.new_road);
		} else if (route.mode == MODE_RAIL) {
			local keep = {};
			foreach (r in ::MT.routes.Open()) {
				if (r == route || r.mode != MODE_RAIL) continue;
				foreach (t in r.track_tiles) keep[t] <- true;
				foreach (s in r.sites) if (s != null) foreach (t in ::MT.rail.Footprint(s)) keep[t] <- true;
			}
			local tiles = [];
			foreach (t in route.track_tiles) if (!(t in keep)) tiles.append(t);
			foreach (i, s in route.sites) {
				if (s == null || this.UsedElsewhere(route, route.sids[i])) continue;
				foreach (t in ::MT.rail.Footprint(s)) if (!(t in keep)) tiles.append(t);
			}
			::MT.rail.Demolish(tiles);
		} else if (route.mode == MODE_AIR) {
			foreach (i, sid in route.sids) {
				if (sid < 0 || this.UsedElsewhere(route, sid) || AIVehicleList_Station(sid).Count() > 0) continue;
				local town = route.Town(i);
				if (town >= 0) {
					local hub = ::MT.routes.Hub(town);
					if (hub.air_sid == sid) { hub.air_sid = -1; hub.air_tile = -1; }
					if (hub.sid == sid) hub.sid = -1;
				}
				AIAirport.RemoveAirport(route.tiles[i]);
			}
		} else if (route.mode == MODE_WATER) {
			foreach (i, sid in route.sids) {
				if (sid < 0 || this.UsedElsewhere(route, sid)) continue;
				if (AIMarine.IsDockTile(route.tiles[i])) AIMarine.RemoveDock(route.tiles[i]);
			}
			foreach (d in route.depots) if (d >= 0 && AIMarine.IsWaterDepotTile(d) && !this.DepotUsedElsewhere(route, d)) AIMarine.RemoveWaterDepot(d);
		}
		foreach (town, hub in ::MT.routes.hubs) if (hub.sid >= 0 && !AIStation.IsValidStation(hub.sid)) hub.sid = -1;
	}
}
