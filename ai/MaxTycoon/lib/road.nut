/*
 * RoadBuilder: drive-through stops, depots and road connections for buses, trucks and trams.
 *
 * Town stops are drive-through stops on straight town roads (buses keep moving, the stop stays free for the
 * next one). Industry stops are drive-through stops on a short road of our own inside the industry's catchment
 * (radius 3 for a road stop), so trucks load at the mine and unload at the mill without entering a town.
 * A stop pair is checked for level-crossing risk: the shortest road through a crossing is only accepted when
 * no other road exists (a train hitting a truck loses both).
 */

class RoadBuilder {
	bridges = null;
	roadtype = -1;        // current road type (plain road or a tram type)

	constructor(bridge_cache) {
		this.bridges = bridge_cache;
		this.roadtype = AIRoad.ROADTYPE_ROAD;
	}

	function Use(rt) {
		this.roadtype = rt;
		AIRoad.SetCurrentRoadType(rt);
	}

	function StopType(cargo) { return AIRoad.GetRoadVehicleTypeForCargo(cargo); }

	/* Axis (DIR_PX / DIR_PY) of a straight, flat road tile that can take a drive-through stop, or -1. */
	function StopAxis(t) {
		if (!Geo.InMap(t, 2)) return -1;
		if (!AIRoad.IsRoadTile(t) || AIRoad.IsRoadStationTile(t) || AIRoad.IsRoadDepotTile(t)) return -1;
		if (AIRail.IsLevelCrossingTile(t) || AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) return -1;
		if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::TY.safety.IsFloodRisk(t)) return -1;
		local x1 = AIRoad.AreRoadTilesConnected(t, t + 1), x2 = AIRoad.AreRoadTilesConnected(t, t - 1);
		local y1 = AIRoad.AreRoadTilesConnected(t, t + Geo.MX), y2 = AIRoad.AreRoadTilesConnected(t, t - Geo.MX);
		if (x1 && x2 && !y1 && !y2) return DIR_PX;
		if (y1 && y2 && !x1 && !x2) return DIR_PY;
		return -1;
	}

	/*
	 * Best stop tile within `radius` of `center` on an existing road for `cargo`, joined to station_id (or a
	 * new station). Passengers need a catchment of houses; a town cargo (goods, food, water) needs acceptance 8.
	 * `avoid` is a table of tiles not to use; far_from/min_dist keeps the stop away from a tile; `town` limits
	 * the stop to that town's influence zone (the zone its growth counts stations in). Returns {tile, axis}.
	 */
	function FindStop(center, radius, station_id, cargo = -1, avoid = null, far_from = -1, min_dist = 0, town = -1) {
		if (cargo < 0) cargo = Util.pax;
		AIRoad.SetCurrentRoadType(this.roadtype);
		local list = AITileList();
		local cx = Geo.X(center), cy = Geo.Y(center);
		list.AddRectangle(AIMap.GetTileIndex(max(1, cx - radius), max(1, cy - radius)),
			AIMap.GetTileIndex(min(AIMap.GetMapSizeX() - 2, cx + radius), min(AIMap.GetMapSizeY() - 2, cy + radius)));
		list.Valuate(AIRoad.IsRoadTile);
		list.KeepValue(1);
		list.Valuate(AITile.GetCargoAcceptance, cargo, 1, 1, 3);
		list.KeepAboveValue(cargo == Util.pax ? 15 : 7);
		local scored = AIList();
		foreach (t, acc in list) {
			if (avoid != null && (t in avoid)) continue;
			if (far_from >= 0 && AIMap.DistanceManhattan(t, far_from) < min_dist) continue;
			if (town >= 0 && !AITown.IsWithinTownInfluence(town, t)) continue;
			if (this.StopAxis(t) < 0) continue;
			scored.AddItem(t, acc * 4 - AIMap.DistanceManhattan(t, center) * 3);
		}
		local type = this.StopType(cargo);
		foreach (t in Util.TopN(scored, 12)) {
			local axis = this.StopAxis(t);
			local ok;
			{
				local tm = AITestMode();
				ok = AIRoad.BuildDriveThroughRoadStation(t, t + Geo.Offset(axis), type, station_id);
			}
			if (ok) return {tile = t, axis = axis, cargo = cargo, own_road = false};
		}
		return null;
	}

	/*
	 * Stop site inside an industry's catchment: a flat free tile with a flat free neighbour on each side along
	 * one axis (the drive-through stop and its two road tiles). `producing` selects the production or the
	 * acceptance catchment; an accepting site must reach acceptance 8 for the cargo.
	 */
	function FindIndustryStop(ind, cargo, producing, station_id, avoid = null) {
		AIRoad.SetCurrentRoadType(this.roadtype);
		local list = producing ? AITileList_IndustryProducing(ind, 3) : AITileList_IndustryAccepting(ind, 3);
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		local loc = AIIndustry.GetLocation(ind);
		local scored = AIList();
		foreach (t, _ in list) {
			if (avoid != null && (t in avoid)) continue;
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || !::TY.safety.TileOk(t)) continue;
			if (!producing && AITile.GetCargoAcceptance(t, cargo, 1, 1, 3) < 8) continue;
			scored.AddItem(t, -AIMap.DistanceManhattan(t, loc));
		}
		local type = this.StopType(cargo);
		foreach (t in Util.TopN(scored, 40)) {
			foreach (axis in [DIR_PX, DIR_PY]) {
				local a = t - Geo.Offset(axis), b = t + Geo.Offset(axis);
				if (!this.RoadSiteOk(a) || !this.RoadSiteOk(b)) continue;
				if (avoid != null && ((a in avoid) || (b in avoid))) continue;
				local ok;
				{
					local tm = AITestMode();
					ok = AIRoad.BuildRoad(a, b) && AIRoad.BuildDriveThroughRoadStation(t, b, type, station_id);
				}
				if (ok) return {tile = t, axis = axis, cargo = cargo, own_road = true};
			}
		}
		return null;
	}

	/* A tile a new road piece of ours may use (flat, free, not at flood risk; or already a plain road). */
	function RoadSiteOk(t) {
		if (!Geo.InMap(t, 2) || !::TY.safety.TileOk(t)) return false;
		if (AIRoad.IsRoadTile(t)) return !AIRoad.IsRoadStationTile(t) && !AIRoad.IsRoadDepotTile(t) && AITile.GetSlope(t) == AITile.SLOPE_FLAT;
		return AITile.IsBuildable(t) && AITile.GetSlope(t) == AITile.SLOPE_FLAT;
	}

	function BuildStop(spot, station_id) {
		AIRoad.SetCurrentRoadType(this.roadtype);
		local type = this.StopType(spot.cargo);
		local a = spot.tile - Geo.Offset(spot.axis), b = spot.tile + Geo.Offset(spot.axis);
		if (spot.own_road && !AIRoad.BuildRoad(a, b)) {
			if (AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) {
				Log.Warn("BUILD", "stop road at " + Util.TileStr(spot.tile) + " failed: " + AIError.GetLastErrorString());
				return -1;
			}
		}
		if (!AIRoad.BuildDriveThroughRoadStation(spot.tile, b, type, station_id)) {
			Log.Warn("BUILD", (type == AIRoad.ROADVEHTYPE_BUS ? "bus" : "truck") + " stop at " + Util.TileStr(spot.tile) + " failed: " + AIError.GetLastErrorString());
			if (AIError.GetLastError() == AIError.ERR_LOCAL_AUTHORITY_REFUSES) ::TY.planner.OnRefused(AITile.GetClosestTown(spot.tile));
			return -1;
		}
		return AIStation.GetStationID(spot.tile);
	}

	/* Road depot next to the road network close to `near`. Returns the depot tile or -1. */
	/* Road tiles a vehicle on `start` can drive to, up to `limit` tiles. */
	function Reach(start, limit = 120) {
		local seen = {}, queue = [start], i = 0;
		seen[start] <- true;
		while (i < queue.len() && queue.len() < limit) {
			local t = queue[i++];
			for (local d = 0; d < 4; d++) {
				local n = t + Geo.Offset(d);
				if ((n in seen) || !AIRoad.AreRoadTilesConnected(t, n)) continue;
				seen[n] <- true;
				queue.append(n);
			}
			local o = -1;
			if (AIBridge.IsBridgeTile(t)) o = AIBridge.GetOtherBridgeEnd(t);
			else if (AITunnel.IsTunnelTile(t)) o = AITunnel.GetOtherTunnelEnd(t);
			if (o >= 0 && AIMap.IsValidTile(o) && !(o in seen)) { seen[o] <- true; queue.append(o); }
		}
		return seen;
	}

	/* Depot next to a road tile that vehicles at `near` (a stop or a vehicle's tile) can drive to. */
	function BuildDepotNear(near, radius = 6) {
		AIRoad.SetCurrentRoadType(this.roadtype);
		local reach = this.Reach(near);
		local list = AITileList();
		local cx = Geo.X(near), cy = Geo.Y(near);
		list.AddRectangle(AIMap.GetTileIndex(max(1, cx - radius), max(1, cy - radius)),
			AIMap.GetTileIndex(min(AIMap.GetMapSizeX() - 2, cx + radius), min(AIMap.GetMapSizeY() - 2, cy + radius)));
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		list.Valuate(AIMap.DistanceManhattan, near);
		list.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
		foreach (t, _ in list) {
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::TY.safety.IsFloodRisk(t) || AIRoad.IsRoadTile(t)) continue;
			for (local d = 0; d < 4; d++) {
				local r = t + Geo.Offset(d);
				if (!AIRoad.IsRoadTile(r) || AIRoad.IsRoadStationTile(r) || AIRoad.IsRoadDepotTile(r)) continue;
				if (reach.len() > 1 && !(r in reach)) continue;   // not a stray piece of road the vehicles cannot get to
				if (AIRail.IsLevelCrossingTile(r) || AIBridge.IsBridgeTile(r) || AITunnel.IsTunnelTile(r)) continue;
				if (AITile.GetSlope(r) != AITile.SLOPE_FLAT) continue;
				if (!AIRoad.HasRoadType(r, this.roadtype)) continue;
				local ok;
				{
					local tm = AITestMode();
					ok = AIRoad.BuildRoadDepot(t, r) && AIRoad.BuildRoad(t, r);
				}
				if (!ok) continue;
				if (AIRoad.BuildRoadDepot(t, r) && AIRoad.BuildRoad(t, r)) return t;
				AITile.DemolishTile(t);
			}
		}
		return -1;
	}

	/* Build road from a tile (a stranded vehicle's) to the nearest of our depots. */
	function ConnectToDepot(tile) {
		local depots = AIDepotList(AITile.TRANSPORT_ROAD);
		depots.Valuate(AIMap.DistanceManhattan, tile);
		depots.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
		local tried = 0;
		foreach (d, dist in depots) {
			if (++tried > 3 || dist > 40) break;
			local front = AIRoad.GetRoadDepotFrontTile(d);
			local conn = this.Connect(tile, front);
			if (conn == null) continue;
			if (this.NewPieces(conn.path) == 0) continue;   // connected already: the vehicle is stuck for another reason
			if (this.BuildPath(conn.path)) return true;
		}
		return false;
	}

	/* Road tiles touching a stop (both ends of a drive-through stop). */
	function StopEnds(stop_tile) {
		local out = [];
		for (local d = 0; d < 4; d++) {
			local n = stop_tile + Geo.Offset(d);
			if (AIRoad.AreRoadTilesConnected(stop_tile, n)) out.append(n);
		}
		return out;
	}

	/*
	 * Find (and build when needed) a road route between two stops. Returns {path, crossing_risk} or null.
	 * crossing_risk is true when the route found needs a level crossing (no other road exists) or a route
	 * through one would be clearly shorter, so the vehicles' own pathfinder might take it.
	 */
	function Connect(stop_a, stop_b) {
		local pf = RoadPathFinder(this.bridges);
		local path = pf.FindPath([stop_a], [stop_b]);
		local pf2 = RoadPathFinder(this.bridges);
		pf2.allow_crossings = true;
		local fast = pf2.FindPath([stop_a], [stop_b]);
		if (path == null && fast == null) return null;
		if (path == null) return {path = fast, crossing_risk = true};
		local risk = fast != null && pf2.used_crossing && fast.len() + 3 < path.len();
		return {path = path, crossing_risk = risk};
	}

	/* New road needed by a path (tiles not yet connected), for cost estimates. */
	function NewPieces(path) {
		local n = 0;
		for (local i = 0; i + 1 < path.len(); i++) {
			if (AIMap.DistanceManhattan(path[i], path[i + 1]) != 1) { n += 4; continue; }
			if (!AIRoad.AreRoadTilesConnected(path[i], path[i + 1])) n++;
		}
		return n;
	}

	function BuildPath(path) {
		AIRoad.SetCurrentRoadType(this.roadtype);
		for (local i = 0; i + 1 < path.len(); i++) {
			if (i % 30 == 0) TY_Housekeeping();
			local a = path[i], b = path[i + 1];
			local dist = AIMap.DistanceManhattan(a, b);
			if (dist == 1) {
				if (AIRoad.AreRoadTilesConnected(a, b)) continue;
				if (!this.Retry(function() : (a, b) { return AIRoad.BuildRoad(a, b); })) {
					if (AIError.GetLastError() == AIError.ERR_ALREADY_BUILT) continue;
					Log.Warn("BUILD", "road " + Util.TileStr(a) + "-" + Util.TileStr(b) + " failed: " + AIError.GetLastErrorString());
					return false;
				}
				continue;
			}
			/* a jump: existing bridge/tunnel (ours or not) or a new bridge from a to b */
			if ((AIBridge.IsBridgeTile(a) && AIBridge.GetOtherBridgeEnd(a) == b) ||
					(AITunnel.IsTunnelTile(a) && AITunnel.GetOtherTunnelEnd(a) == b)) continue;
			local d = Geo.LineDir(a, b);
			local near = a + Geo.Offset(d);
			if ((AIBridge.IsBridgeTile(near) && AIBridge.GetOtherBridgeEnd(near) == b) ||
					(AITunnel.IsTunnelTile(near) && AITunnel.GetOtherTunnelEnd(near) == b)) {
				if (!AIRoad.AreRoadTilesConnected(a, near)) AIRoad.BuildRoad(a, near);
				continue;
			}
			local bt = this.bridges.Fastest(dist + 1);
			if (bt < 0 || !AIBridge.BuildBridge(AIVehicle.VT_ROAD, bt, a, b)) {
				Log.Warn("BUILD", "road bridge " + Util.TileStr(a) + "-" + Util.TileStr(b) + " failed: " + AIError.GetLastErrorString());
				return false;
			}
		}
		return true;
	}

	/* Retry a build a few times when a vehicle is in the way. */
	function Retry(fn) {
		for (local i = 0; i < 20; i++) {
			if (fn()) return true;
			local err = AIError.GetLastError();
			if (err == AIError.ERR_NOT_ENOUGH_CASH) {
				if (!::TY.finance.Ensure(20000)) return false;
				continue;
			}
			if (err != AIError.ERR_VEHICLE_IN_THE_WAY) return false;
			AIController.Sleep(10);
		}
		return false;
	}

	/*
	 * Straight road from a to b (same row or column), skipping what exists; used for the town road grids.
	 * Returns the number of new pieces, or -1 when a piece could not be built.
	 */
	function BuildStraight(a, b) {
		AIRoad.SetCurrentRoadType(this.roadtype);
		local d = Geo.LineDir(a, b);
		if (d < 0) return -1;
		local n = 0;
		for (local t = a; t != b; t += Geo.Offset(d)) {
			local nx = t + Geo.Offset(d);
			if (AIRoad.AreRoadTilesConnected(t, nx)) continue;
			if (!AIRoad.BuildRoad(t, nx)) {
				if (AIError.GetLastError() == AIError.ERR_ALREADY_BUILT) continue;
				return -1;
			}
			n++;
		}
		return n;
	}
}
