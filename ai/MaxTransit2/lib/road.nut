/*
 * RoadBuilder: drive-through stops in towns, loading bays at industries, depots and road connections.
 *
 * In a town, buses (and lorries delivering goods) use drive-through stops on straight streets: the stop looks
 * like part of the street and keeps the vehicles moving. At an industry, lorries load in a bay stop at the end
 * of a short access road that leaves straight towards the destination. A road route is refused when the
 * vehicles' own pathfinder would likely take a level crossing (the shortest road with crossings is clearly
 * shorter than the one without).
 */

class RoadBuilder {
	bridges = null;
	built = null;      // tiles where the last BuildPath laid new road

	constructor(bridge_cache) {
		this.bridges = bridge_cache;
		this.built = [];
	}

	/* Axis (DIR_PX / DIR_PY) of a straight, flat road tile that can take a drive-through stop, or -1. */
	function StopAxis(t) {
		if (!Geo.InMap(t, 2)) return -1;
		if (!AIRoad.IsRoadTile(t) || AIRoad.IsRoadStationTile(t) || AIRoad.IsRoadDepotTile(t)) return -1;
		if (AIRail.IsLevelCrossingTile(t) || AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) return -1;
		if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::MT.safety.IsFloodRisk(t)) return -1;
		local owner = AITile.GetOwner(t);
		if (owner != AICompany.COMPANY_INVALID && owner != Util.me) return -1;   // never on another company's road
		local x1 = AIRoad.AreRoadTilesConnected(t, t + 1), x2 = AIRoad.AreRoadTilesConnected(t, t - 1);
		local y1 = AIRoad.AreRoadTilesConnected(t, t + Geo.MX), y2 = AIRoad.AreRoadTilesConnected(t, t - Geo.MX);
		if (x1 && x2 && !y1 && !y2) return DIR_PX;
		if (y1 && y2 && !x1 && !x2) return DIR_PY;
		return -1;
	}

	/*
	 * Best drive-through stop tile within `radius` of `center` for `cargo`, joined to station_id (or a new
	 * station). `avoid` is a table of tiles not to use; min_dist keeps the stop away from far_from.
	 * Returns {tile, axis} or null.
	 */
	function FindStop(center, radius, station_id, cargo, vtype, avoid = null, far_from = -1, min_dist = 0, min_acc = 15) {
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		local catchment = ::MT.game.Catchment(MODE_ROAD);
		local list = Geo.Square(center, radius);
		list.Valuate(AIRoad.IsRoadTile);
		list.KeepValue(1);
		list.Valuate(AITile.GetCargoAcceptance, cargo, 1, 1, catchment);
		list.KeepAboveValue(min_acc - 1);
		local scored = AIList();
		foreach (t, acc in list) {
			if (avoid != null && (t in avoid)) continue;
			if (far_from >= 0 && AIMap.DistanceManhattan(t, far_from) < min_dist) continue;
			if (this.StopAxis(t) < 0) continue;
			scored.AddItem(t, acc * 4 - AIMap.DistanceManhattan(t, center) * 3);
		}
		foreach (t in Util.TopN(scored, 12)) {
			if (!::MT.nb.StationOk(t, 1, 1, catchment)) continue;
			local axis = this.StopAxis(t);
			local ok;
			{
				local tm = AITestMode();
				ok = AIRoad.BuildDriveThroughRoadStation(t, t + Geo.Offset(axis), vtype, station_id);
			}
			if (ok) return {tile = t, axis = axis, bay = false};
		}
		return null;
	}

	function BuildStop(spot, station_id, vtype) {
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		/* a drive-through stop goes on a street that may have traffic on it: retry while a vehicle is in the way */
		local ok = Util.Retry(function() : (spot, vtype, station_id) {
			if (spot.bay) return AIRoad.BuildRoadStation(spot.tile, spot.front, vtype, station_id);
			return AIRoad.BuildDriveThroughRoadStation(spot.tile, spot.tile + Geo.Offset(spot.axis), vtype, station_id);
		});
		if (!ok) {
			Log.Warn("BUILD", "road stop at " + Util.TileStr(spot.tile) + " failed: " + AIError.GetLastErrorString());
			if (AIError.GetLastError() == AIError.ERR_LOCAL_AUTHORITY_REFUSES) ::MT.planner.OnRefused(AITile.GetClosestTown(spot.tile));
			return -1;
		}
		if (spot.bay && !AIRoad.AreRoadTilesConnected(spot.front, spot.tile)) {
			if (!Util.Retry(function() : (spot) { return AIRoad.BuildRoad(spot.front, spot.tile); })) {
				AIRoad.RemoveRoadStation(spot.tile);
				return -1;
			}
		}
		return AIStation.GetStationID(spot.tile);
	}

	/* Can new road (or the existing road) be used on tile t for an access road? */
	function RoadOk(t) {
		if (!Geo.InMap(t, 2)) return false;
		if (AIRoad.IsRoadTile(t)) return !AIRoad.IsRoadStationTile(t) && !AIRoad.IsRoadDepotTile(t) && !AIRail.IsLevelCrossingTile(t);
		if (!AITile.IsBuildable(t) || ::MT.safety.IsFloodRisk(t)) return false;
		local s = AITile.GetSlope(t);
		if (AITile.IsSteepSlope(s) || AITile.IsHalftileSlope(s)) return false;
		return ::MT.nb.TileFree(t) && !::MT.nb.NextToTheirRail(t);
	}

	/*
	 * Loading bay for lorries at industry `ind`: a flat tile in the catchment (production for a pickup,
	 * acceptance of `cargo` for a drop) whose entrance faces the destination. Returns {tile, front, bay} or null.
	 */
	function FindBay(ind, cargo, pickup, toward) {
		local radius = ::MT.game.Catchment(MODE_ROAD);
		local list = pickup ? AITileList_IndustryProducing(ind, radius) : AITileList_IndustryAccepting(ind, radius);
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		if (!pickup) {
			list.Valuate(AITile.GetCargoAcceptance, cargo, 1, 1, radius);
			list.KeepAboveValue(7);
		}
		local scored = [];
		foreach (t, _ in list) {
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::MT.safety.IsFloodRisk(t) || AIRoad.IsRoadTile(t)) continue;
			if (!::MT.nb.TileFree(t)) continue;
			for (local d = 0; d < 4; d++) {
				local f = t + Geo.Offset(d);
				if (!this.RoadOk(f) || AITile.GetSlope(f) != AITile.SLOPE_FLAT) continue;
				local score = -AIMap.DistanceManhattan(f, toward) * 2 + AIMap.DistanceManhattan(t, toward) * 2 -
					(AITile.HasTreeOnTile(t) ? 3 : 0) + (AIRoad.IsRoadTile(f) ? 4 : 0);
				scored.append([score, t, f]);
			}
		}
		scored.sort(function(a, b) { return b[0] - a[0]; });
		local tries = 0;
		foreach (s in scored) {
			if (++tries > 20) break;
			if (!::MT.nb.StationOk(s[1], 1, 1, radius)) continue;
			if (pickup && !::MT.nb.PickupOk(s[1], 1, 1, radius, cargo, ind)) continue;
			local ok;
			{
				local tm = AITestMode();
				ok = AIRoad.BuildRoadStation(s[1], s[2], AIRoad.ROADVEHTYPE_TRUCK, AIStation.STATION_NEW);
			}
			if (ok) return {tile = s[1], front = s[2], bay = true};
		}
		return null;
	}

	/* Road depot next to the road network close to `near`. Returns the depot tile or -1. */
	function BuildDepotNear(near, radius = 6) {
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		local list = Geo.Square(near, radius);
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		list.Valuate(AIMap.DistanceManhattan, near);
		list.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
		foreach (t, _ in list) {
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::MT.safety.IsFloodRisk(t) || AIRoad.IsRoadTile(t)) continue;
			if (!::MT.nb.TileFree(t)) continue;
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

	/*
	 * Find (and build when needed) a road route between two road tiles. Returns {path, crossing_risk} or null.
	 * crossing_risk is true when a route through a level crossing would be clearly shorter, so the vehicles'
	 * pathfinder might take it: the caller rejects such a pair.
	 */
	function Connect(a, b, speed) {
		local pf = RoadPathFinder(this.bridges);
		pf.speed = speed;
		pf.max_nodes = min(80000, max(20000, 600 * AIMap.DistanceManhattan(a, b)));
		local path = pf.FindPath([a], [b]);
		if (path == null) return null;
		local pf2 = RoadPathFinder(this.bridges);
		pf2.allow_crossings = true;
		pf2.max_nodes = pf.max_nodes;
		local fast = pf2.FindPath([a], [b]);
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

	/* Build a path; the tiles that get new road are listed in this.built. */
	function BuildPath(path, speed) {
		AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
		this.built = [];
		for (local i = 0; i + 1 < path.len(); i++) {
			if (i % 40 == 0) MT_Housekeeping();
			local a = path[i], b = path[i + 1];
			local dist = AIMap.DistanceManhattan(a, b);
			if (dist == 1) {
				if (AIRoad.AreRoadTilesConnected(a, b)) continue;
				local fresh_a = !AIRoad.IsRoadTile(a), fresh_b = !AIRoad.IsRoadTile(b);
				if (!Util.Retry(function() : (a, b) { return AIRoad.BuildRoad(a, b); })) {
					if (AIError.GetLastError() == AIError.ERR_ALREADY_BUILT) continue;
					Log.Warn("BUILD", "road " + Util.TileStr(a) + "-" + Util.TileStr(b) + " failed: " + AIError.GetLastErrorString());
					return false;
				}
				if (fresh_a) this.built.append(a);
				if (fresh_b) this.built.append(b);
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
			local bt = this.bridges.For(dist + 1, speed);
			if (bt < 0 || !Util.Retry(function() : (bt, a, b) { return AIBridge.BuildBridge(AIVehicle.VT_ROAD, bt, a, b); })) {
				Log.Warn("BUILD", "road bridge " + Util.TileStr(a) + "-" + Util.TileStr(b) + " failed: " + AIError.GetLastErrorString());
				return false;
			}
			this.built.append(a);
			this.built.append(b);
		}
		return true;
	}

	/*
	 * Take away road we laid that nothing else uses any more: our own pieces that became dead ends (a town or
	 * another company may have joined their streets to it, then it stays).
	 */
	function RemoveUnused(tiles) {
		local pending = [];
		foreach (t in tiles) pending.append(t);
		local progress = true;
		while (progress) {
			progress = false;
			local keep = [];
			foreach (t in pending) {
				if (!AIRoad.IsRoadTile(t) || !Util.IsMine(t) || AIRoad.IsRoadStationTile(t) || AIRoad.IsRoadDepotTile(t)) continue;
				if (AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) continue;
				local links = 0;
				for (local d = 0; d < 4; d++) if (AIRoad.AreRoadTilesConnected(t, t + Geo.Offset(d))) links++;
				if (links <= 1 && AITile.DemolishTile(t)) { progress = true; continue; }
				keep.append(t);
			}
			pending = keep;
		}
	}
}
