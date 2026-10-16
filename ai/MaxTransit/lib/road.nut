/*
 * RoadBuilder: drive-through bus stops, depots and road connections.
 *
 * Drive-through stops on straight town roads keep buses moving (no turning inside the stop, which also keeps
 * the stop free for the next bus). A stop pair is refused when the buses' own pathfinder would likely use a
 * level crossing: we compare the best road path with and without crossings.
 */

class RoadBuilder {
	bridges = null;

	constructor(bridge_cache) { this.bridges = bridge_cache; }

	/* Axis (DIR_PX / DIR_PY) of a straight, flat road tile that can take a drive-through stop, or -1. */
	function StopAxis(t) {
		if (!Geo.InMap(t, 2)) return -1;
		if (!AIRoad.IsRoadTile(t) || AIRoad.IsRoadStationTile(t) || AIRoad.IsRoadDepotTile(t)) return -1;
		if (AIRail.IsLevelCrossingTile(t) || AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) return -1;
		if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::MT.safety.IsFloodRisk(t)) return -1;
		local x1 = AIRoad.AreRoadTilesConnected(t, t + 1), x2 = AIRoad.AreRoadTilesConnected(t, t - 1);
		local y1 = AIRoad.AreRoadTilesConnected(t, t + Geo.MX), y2 = AIRoad.AreRoadTilesConnected(t, t - Geo.MX);
		if (x1 && x2 && !y1 && !y2) return DIR_PX;
		if (y1 && y2 && !x1 && !x2) return DIR_PY;
		return -1;
	}

	/*
	 * Best stop tile within `radius` of `center` for passengers, joined to station_id (or a new station).
	 * `avoid` is a table of tiles not to use; min_dist keeps the stop away from a given tile.
	 * Returns {tile, axis} or null.
	 */
	function FindStop(center, radius, station_id, avoid = null, far_from = -1, min_dist = 0) {
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		local list = AITileList();
		local cx = Geo.X(center), cy = Geo.Y(center);
		list.AddRectangle(AIMap.GetTileIndex(max(1, cx - radius), max(1, cy - radius)),
			AIMap.GetTileIndex(min(AIMap.GetMapSizeX() - 2, cx + radius), min(AIMap.GetMapSizeY() - 2, cy + radius)));
		list.Valuate(AIRoad.IsRoadTile);
		list.KeepValue(1);
		list.Valuate(AITile.GetCargoAcceptance, Util.pax, 1, 1, 3);
		list.KeepAboveValue(15);
		local scored = AIList();
		foreach (t, acc in list) {
			if (avoid != null && (t in avoid)) continue;
			if (far_from >= 0 && AIMap.DistanceManhattan(t, far_from) < min_dist) continue;
			if (this.StopAxis(t) < 0) continue;
			scored.AddItem(t, acc * 4 - AIMap.DistanceManhattan(t, center) * 3);
		}
		foreach (t in Util.TopN(scored, 12)) {
			local axis = this.StopAxis(t);
			local ok;
			{
				local tm = AITestMode();
				ok = AIRoad.BuildDriveThroughRoadStation(t, t + Geo.Offset(axis), AIRoad.ROADVEHTYPE_BUS, station_id);
			}
			if (ok) return {tile = t, axis = axis};
		}
		return null;
	}

	function BuildStop(spot, station_id) {
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		if (!AIRoad.BuildDriveThroughRoadStation(spot.tile, spot.tile + Geo.Offset(spot.axis), AIRoad.ROADVEHTYPE_BUS, station_id)) {
			Log.Warn("BUILD", "bus stop at " + Util.TileStr(spot.tile) + " failed: " + AIError.GetLastErrorString());
			if (AIError.GetLastError() == AIError.ERR_LOCAL_AUTHORITY_REFUSES) ::MT.planner.OnRefused(AITile.GetClosestTown(spot.tile));
			return -1;
		}
		return AIStation.GetStationID(spot.tile);
	}

	/* Road depot next to the road network close to `near`. Returns the depot tile or -1. */
	function BuildDepotNear(near, radius = 6) {
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		local list = AITileList();
		local cx = Geo.X(near), cy = Geo.Y(near);
		list.AddRectangle(AIMap.GetTileIndex(max(1, cx - radius), max(1, cy - radius)),
			AIMap.GetTileIndex(min(AIMap.GetMapSizeX() - 2, cx + radius), min(AIMap.GetMapSizeY() - 2, cy + radius)));
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		list.Valuate(AIMap.DistanceManhattan, near);
		list.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
		foreach (t, _ in list) {
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::MT.safety.IsFloodRisk(t) || AIRoad.IsRoadTile(t)) continue;
			for (local d = 0; d < 4; d++) {
				local r = t + Geo.Offset(d);
				if (!AIRoad.IsRoadTile(r) || AIRoad.IsRoadStationTile(r) || AIRoad.IsRoadDepotTile(r)) continue;
				if (AIRail.IsLevelCrossingTile(r) || AIBridge.IsBridgeTile(r) || AITunnel.IsTunnelTile(r)) continue;
				if (AITile.GetSlope(r) != AITile.SLOPE_FLAT) continue;
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
	 * crossing_risk is true when a route through a level crossing would be clearly shorter, so the buses'
	 * pathfinder might take it: the caller rejects such a pair.
	 */
	function Connect(stop_a, stop_b) {
		local pf = RoadPathFinder(this.bridges);
		local path = pf.FindPath([stop_a], [stop_b]);
		if (path == null) return null;
		local pf2 = RoadPathFinder(this.bridges);
		pf2.allow_crossings = true;
		local fast = pf2.FindPath([stop_a], [stop_b]);
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
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		for (local i = 0; i + 1 < path.len(); i++) {
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
			if (err != AIError.ERR_VEHICLE_IN_THE_WAY) return false;
			AIController.Sleep(10);
		}
		return false;
	}
}
