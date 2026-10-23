/*
 * MarineBuilder: docks, ship depots and water routes.
 *
 * OpenTTD 15.3 (station_cmd.cpp CmdBuildDock, water_cmd.cpp): a dock stands on a land tile whose slope is
 * inclined (two adjacent corners raised) with flat water in front of it and one more flat water tile beyond;
 * ships stop on the water tiles next to the dock, so the dock tile itself is the order destination. A ship
 * depot takes two flat water tiles. Ships find their way across the map on their own (region pathfinder),
 * so a route only needs the two docks connected by water; a ship that is lost raises an event.
 * Oil rigs own a station (dock and heliport) that any company's ship may load at.
 */

const WATER_BODY_LIMIT = 300;   // a body of water explored this far counts as open water
const WATER_BODY_MIN = 40;      // smaller bodies take no dock

class MarineBuilder {
	bridges = null;
	bodies = null;   // sailable tile -> {tiles, complete, date}: the body of water it lies in

	constructor() { this.bridges = null; this.bodies = {}; }

	/* The body of water a sailable tile lies in (cached for a year; complete bodies are known tile by tile). */
	function Body(t) {
		if ((t in this.bodies) && Util.Today() - this.bodies[t].date < 365) return this.bodies[t];
		local pf = WaterPathFinder();
		local body = pf.Flood(t, WATER_BODY_LIMIT);
		body.date <- Util.Today();
		if (body.complete) { foreach (x, _ in body.tiles) this.bodies[x] <- body; }
		else this.bodies[t] <- body;
		return body;
	}

	/* Can a ship get from a to b? Certain for small bodies; open water is left to the path search. */
	function Reachable(a, b) {
		local A = this.Body(a);
		if (A.complete) return (b in A.tiles);
		local B = this.Body(b);
		if (B.complete) return (a in B.tiles);
		return true;
	}

	function Inclined(s) {
		return s == AITile.SLOPE_NE || s == AITile.SLOPE_SE || s == AITile.SLOPE_SW || s == AITile.SLOPE_NW;
	}

	/* Water tile in front of a dock on an inclined land tile (the slope falls toward the water). */
	function Front(t) {
		local s = AITile.GetSlope(t);
		if (s == AITile.SLOPE_NE) return t + Geo.Offset(DIR_PX);
		if (s == AITile.SLOPE_SW) return t + Geo.Offset(DIR_NX);
		if (s == AITile.SLOPE_SE) return t + Geo.Offset(DIR_NY);
		if (s == AITile.SLOPE_NW) return t + Geo.Offset(DIR_PY);
		return -1;
	}

	/* Does this land tile take a dock whose water tile joins open water (not a one-tile pond)? */
	function DockSiteOk(t, station_id) {
		if (!Geo.InMap(t, 3) || !this.Inclined(AITile.GetSlope(t))) return false;
		if (AITile.IsWaterTile(t) || !(AITile.IsBuildable(t) || AITile.IsCoastTile(t))) return false;
		if (t in ::TY.safety.danger_tiles) return false;
		local w = this.Front(t);
		if (w < 0 || !AITile.IsWaterTile(w) || AITile.IsCoastTile(w) || AITile.GetSlope(w) != AITile.SLOPE_FLAT) return false;
		local w2 = w + (w - t);
		if (!AITile.IsWaterTile(w2) || AITile.GetSlope(w2) != AITile.SLOPE_FLAT) return false;
		local ok;
		{
			local tm = AITestMode();
			ok = AIMarine.BuildDock(t, station_id);
		}
		return ok;
	}

	/*
	 * Dock site within the catchment (radius 5) of an industry (producing or accepting cargo) or around a town
	 * centre for passengers / town cargo. Returns {tile, water} or null.
	 */
	function FindDock(target_tiles, cargo, accepting, station_id) {
		local scored = AIList();
		local inclined = 0, water_ok = 0;
		foreach (t, _ in target_tiles) {
			if (!this.Inclined(AITile.GetSlope(t))) continue;
			/* a land tile (a sloped coast tile counts); a river slope is water and takes no dock */
			if (AITile.IsWaterTile(t) || !(AITile.IsBuildable(t) || AITile.IsCoastTile(t))) continue;
			inclined++;
			local w = this.Front(t);
			if (w < 0 || !AITile.IsWaterTile(w) || AITile.IsCoastTile(w)) continue;
			water_ok++;
			if (accepting && AITile.GetCargoAcceptance(t, cargo, 1, 1, 5) < 8) continue;
			if (!accepting && cargo != Util.pax && AITile.GetCargoProduction(t, cargo, 1, 1, 5) <= 0) continue;
			scored.AddItem(t, accepting ? AITile.GetCargoAcceptance(t, cargo, 1, 1, 5) : AITile.GetCargoProduction(t, cargo, 1, 1, 5));
		}
		local why = "";
		foreach (t in Util.TopN(scored, 30)) {
			if (this.DockSiteOk(t, station_id)) return {tile = t, water = this.Front(t)};
			if (why.len() < 300) {
				local w = this.Front(t), w2 = w + (w - t);
				local ok;
				{
					local tm = AITestMode();
					ok = AIMarine.BuildDock(t, station_id);
				}
				why += " " + Util.TileStr(t) + ":" + (AITile.GetSlope(w) != AITile.SLOPE_FLAT ? "front sloped" : (!AITile.IsWaterTile(w2) ? "no 2nd water" :
					(AITile.GetSlope(w2) != AITile.SLOPE_FLAT ? "2nd sloped" : (ok ? "ok?" : AIError.GetLastErrorString())))) +
					"[t slope " + AITile.GetSlope(t) + " buildable " + AITile.IsBuildable(t) + " coast " + AITile.IsCoastTile(t) + " water " + AITile.IsWaterTile(t) +
					" h " + AITile.GetMinHeight(t) + "-" + AITile.GetMaxHeight(t) + "; w " + Util.TileStr(w) + " coast " + AITile.IsCoastTile(w) + " sea " + AITile.IsSeaTile(w) +
					" river " + AITile.IsRiverTile(w) + " h " + AITile.GetMaxHeight(w) + "; w2 sea " + AITile.IsSeaTile(w2) + " coast " + AITile.IsCoastTile(w2) + "]";
			}
		}
		if (AIController.GetSetting("debug") == 1) Log.Info("DEBUG", "dock search: " + target_tiles.Count() + " tiles, " + inclined + " inclined, " +
			water_ok + " with water in front, " + scored.Count() + " in reach of the cargo, none buildable:" + why);
		return null;
	}

	function IndustryTiles(ind, producing) {
		local list = producing ? AITileList_IndustryProducing(ind, 5) : AITileList_IndustryAccepting(ind, 5);
		return list;
	}

	function TownTiles(town, radius) {
		local c = AITown.GetLocation(town);
		local list = AITileList();
		local cx = Geo.X(c), cy = Geo.Y(c);
		list.AddRectangle(AIMap.GetTileIndex(max(2, cx - radius), max(2, cy - radius)),
			AIMap.GetTileIndex(min(AIMap.GetMapSizeX() - 3, cx + radius), min(AIMap.GetMapSizeY() - 3, cy + radius)));
		return list;
	}

	function BuildDock(site, station_id) {
		if (!AIMarine.BuildDock(site.tile, station_id)) {
			if (station_id == AIStation.STATION_NEW || !AIMarine.BuildDock(site.tile, AIStation.STATION_NEW)) {
				Log.Warn("BUILD", "dock at " + Util.TileStr(site.tile) + " failed: " + AIError.GetLastErrorString());
				if (AIError.GetLastError() == AIError.ERR_LOCAL_AUTHORITY_REFUSES) ::TY.planner.OnRefused(AITile.GetClosestTown(site.tile));
				return -1;
			}
		}
		return AIStation.GetStationID(site.tile);
	}

	/*
	 * Ship depot on two flat water tiles reachable from `water`, within a few tiles, and at least three tiles
	 * from the tiles ships dock on (`keep_clear`): a ship that leaves its depot straight onto a docking tile
	 * loads there at once and then asks the game's pathfinder for a route from inside the depot, which it
	 * answers with "lost". Returns the depot tile or -1.
	 */
	function BuildDepotNear(water, keep_clear = null) {
		local pf = WaterPathFinder();
		water = this.Berth(water);
		if (water < 0) return -1;
		local seen = {}, queue = [water], i = 0;
		seen[water] <- true;
		while (i < queue.len() && i < 400) {
			local t = queue[i++];
			if (AIMap.DistanceManhattan(t, water) >= 2) {
				foreach (axis in [DIR_PX, DIR_PY]) {
					local t2 = t + Geo.Offset(axis);
					if (!pf.Sailable(t2) || AIMarine.IsBuoyTile(t2) || AIMarine.IsLockTile(t2)) continue;
					if (AIMarine.IsBuoyTile(t) || AIMarine.IsLockTile(t)) continue;
					if (keep_clear != null && (this.NearAny(t, keep_clear, 3) || this.NearAny(t2, keep_clear, 3))) continue;
					local front = t - Geo.Offset(axis);
					if (!pf.Sailable(front)) front = t2 + Geo.Offset(axis);
					if (!pf.Sailable(front)) continue;
					local ok;
					{
						local tm = AITestMode();
						ok = AIMarine.BuildWaterDepot(t, front);
					}
					if (!ok) continue;
					if (AIMarine.BuildWaterDepot(t, front)) return t;
				}
			}
			for (local d = 0; d < 4; d++) {
				local n = t + Geo.Offset(d);
				if ((n in seen) || !pf.Sailable(n)) continue;
				seen[n] <- true;
				queue.append(n);
			}
		}
		return -1;
	}

	function NearAny(t, tiles, r) {
		foreach (x in tiles) if (AIMap.DistanceManhattan(t, x) < r) return true;
		return false;
	}

	/* A sailable tile next to a dock's water part (that part is a station tile ships stop beside, not on). */
	function Berth(water) {
		local pf = WaterPathFinder();
		if (pf.Sailable(water)) return water;
		for (local d = 0; d < 4; d++) {
			local n = water + Geo.Offset(d);
			if (pf.Sailable(n)) return n;
		}
		return -1;
	}

	/* Water path between the berths of two docks (or a dock and an oil rig's water). */
	function Connect(water_a, water_b) {
		local a = this.Berth(water_a), b = this.Berth(water_b);
		if (a < 0 || b < 0) return null;
		if (!this.Reachable(a, b)) {
			if (AIController.GetSetting("debug") == 1) Log.Info("DEBUG", "water search " + Util.TileStr(a) + " - " + Util.TileStr(b) + ": different bodies of water");
			return null;
		}
		local pf = WaterPathFinder();
		local path = pf.FindPath(a, b);
		if (path == null && AIController.GetSetting("debug") == 1) Log.Info("DEBUG", "water search " + Util.TileStr(a) + " - " + Util.TileStr(b) + ": " + pf.expanded + " nodes, no path");
		/* a search that ran dry has seen the whole body of water around a: remember it for later pairs */
		if (path == null && !pf.capped && pf.last_tiles != null) {
			local body = {tiles = pf.last_tiles, complete = true, date = Util.Today()};
			foreach (x, _ in body.tiles) this.bodies[x] <- body;
		}
		return path;
	}

	/*
	 * Buoys along a route, every BUOY_SPACING tiles. Ships get one leg at a time as their destination: the
	 * game's ship pathfinder searches a few regions ahead only and reports ships lost on long, winding coasts.
	 */
	function PlaceBuoys(path) {
		local pf = WaterPathFinder();
		local out = [];
		for (local i = BUOY_SPACING; i < path.len() - BUOY_SPACING / 2; i += BUOY_SPACING) {
			local placed = -1;
			foreach (k in [0, 1, -1, 2, -2, 3, -3]) {
				local j = i + k;
				if (j < 1 || j >= path.len() - 1) continue;
				local t = path[j];
				if (AIMarine.IsBuoyTile(t)) { placed = t; break; }
				if (!Geo.InMap(t, 3)) continue;   // the game's pathfinder is unhappy next to the map edge
				if (pf.Kind(t) != 1 || AITile.IsStationTile(t) || AIMarine.IsWaterDepotTile(t) || AIMarine.IsLockTile(t)) continue;
				if (AIMarine.BuildBuoy(t)) { placed = t; break; }
			}
			if (placed >= 0) out.append(placed);
		}
		return out;
	}

	/* Remove the buoys of a closed line (a buoy other ships still steer by stays). */
	function RemoveBuoys(buoys) {
		foreach (t in buoys) if (AIMarine.IsBuoyTile(t)) AIMarine.RemoveBuoy(t);
	}

	/* A water tile next to an oil rig (or any industry station on water) a ship can sail from. */
	function RigWater(ind) {
		local t = AIIndustry.GetDockLocation(ind);
		if (!AIMap.IsValidTile(t)) return -1;
		local pf = WaterPathFinder();
		for (local r = 1; r <= 3; r++) {
			for (local dx = -r; dx <= r; dx++) {
				for (local dy = -r; dy <= r; dy++) {
					local w = t + dx + dy * Geo.MX;
					if (pf.Sailable(w)) return w;
				}
			}
		}
		return -1;
	}

	/* Is there open water (a body of at least WATER_BODY_MIN tiles) within `r` tiles of a tile? A quick filter before any dock search. */
	function NearWater(tile, r) {
		local pf = WaterPathFinder();
		local x = Geo.X(tile), y = Geo.Y(tile);
		for (local dx = -r; dx <= r; dx += 2) {
			for (local dy = -r; dy <= r; dy += 2) {
				local t = AIMap.GetTileIndex(Util.Clamp(x + dx, 1, AIMap.GetMapSizeX() - 2), Util.Clamp(y + dy, 1, AIMap.GetMapSizeY() - 2));
				if (!pf.Sailable(t)) continue;
				local body = this.Body(t);
				if (!body.complete || body.tiles.len() >= WATER_BODY_MIN) return true;
			}
		}
		return false;
	}
}
