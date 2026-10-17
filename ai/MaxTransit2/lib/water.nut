/*
 * WaterBuilder: docks, ship depots and shipping lanes.
 *
 * A dock stands on an inclined coast tile; its water part covers the flat water tile below the slope and
 * ships approach from the water tile beyond (station_cmd.cpp CmdBuildDock). An oil rig has its own neutral
 * dock, so a route from a rig needs a dock only at the refinery. Ships find their own way over water
 * (YAPF with water regions), so a lane only has to exist: WaterPathFinder checks that and measures it.
 */

class WaterBuilder {
	/* Corners on the edge a tile shares with its neighbour in direction d, and the two corners away from it. */
	EDGE = null;
	FAR = null;

	constructor() {
		this.EDGE = [[AITile.CORNER_W, AITile.CORNER_S], [AITile.CORNER_E, AITile.CORNER_S],
			[AITile.CORNER_N, AITile.CORNER_E], [AITile.CORNER_N, AITile.CORNER_W]];
		this.FAR = [[AITile.CORNER_N, AITile.CORNER_E], [AITile.CORNER_N, AITile.CORNER_W],
			[AITile.CORNER_W, AITile.CORNER_S], [AITile.CORNER_E, AITile.CORNER_S]];
	}

	function CornerBit(c) {
		if (c == AITile.CORNER_W) return AITile.SLOPE_W;
		if (c == AITile.CORNER_S) return AITile.SLOPE_S;
		if (c == AITile.CORNER_E) return AITile.SLOPE_E;
		return AITile.SLOPE_N;
	}

	/*
	 * Most shore tiles are not the clean incline a dock needs (one corner up, or flat at sea level). Raising the
	 * one or two corners away from the water by a level makes it one; returns those corners as slope bits, or 0
	 * when that would not do (the corners facing the water must be at water level, the far ones at most one up).
	 */
	function RaiseFor(t, d, water_h) {
		if (AITile.GetCornerHeight(t, this.EDGE[d][0]) != water_h || AITile.GetCornerHeight(t, this.EDGE[d][1]) != water_h) return 0;
		local bits = 0;
		foreach (c in this.FAR[d]) {
			local h = AITile.GetCornerHeight(t, c);
			if (h == water_h) bits = bits | this.CornerBit(c);
			else if (h != water_h + 1) return 0;
		}
		if (bits == 0) return 0;
		local tm = AITestMode();
		return AITile.RaiseTile(t, bits) ? bits : 0;
	}

	/* Direction of the low edge of an inclined slope (where a dock's water part goes), or -1. */
	function Downhill(t) {
		local s = AITile.GetSlope(t);
		if (s != AITile.SLOPE_NE && s != AITile.SLOPE_SE && s != AITile.SLOPE_SW && s != AITile.SLOPE_NW) return -1;
		local lo = AITile.GetMinHeight(t);
		for (local d = 0; d < 4; d++) {
			if (AITile.GetCornerHeight(t, this.EDGE[d][0]) == lo && AITile.GetCornerHeight(t, this.EDGE[d][1]) == lo) return d;
		}
		return -1;
	}

	function OpenWater(t) { return AIMap.IsValidTile(t) && AITile.IsWaterTile(t) && AITile.GetSlope(t) == AITile.SLOPE_FLAT && !AIMarine.IsWaterDepotTile(t); }

	/*
	 * Dock sites for `target` ({kind = "town", town} / {kind = "pickup" | "drop", ind, cargo}), best first.
	 * Each is {tile, dir, front, approach}. The water in front must be open for at least a few tiles.
	 */
	function DockSites(target, max_n) {
		local radius = ::MT.game.Catchment(MODE_WATER);
		local list;
		local cargo = target.kind == "town" ? Util.pax : target.cargo;
		local center;
		if (target.kind == "town") {
			center = AITown.GetLocation(target.town);
			list = Geo.Square(center, ::MT.nb.TownRadius(target.town) + 2);
		} else {
			center = AIIndustry.GetLocation(target.ind);
			list = target.kind == "pickup" ? AITileList_IndustryProducing(target.ind, radius) : AITileList_IndustryAccepting(target.ind, radius);
		}
		/* the land part is an inclined tile at the water's edge (usually a shore tile) */
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		local out = [];
		local why = [0, 0, 0, 0, 0];   // diagnostics: not inclined, no open water, acceptance, courtesy, game refuses
		local raised = [];
		foreach (t, _ in list) {
			local d = this.Downhill(t), raise = 0;
			if (d < 0) {
				/* a shore tile that a small earthwork turns into a dock site */
				for (local k = 0; k < 4 && d < 0; k++) {
					local f = t + Geo.Offset(k);
					if (!this.OpenWater(f) || !this.OpenWater(f + Geo.Offset(k))) continue;
					raise = this.RaiseFor(t, k, AITile.GetMinHeight(f));
					if (raise != 0) d = k;
				}
				if (d < 0) { why[0]++; continue; }
			}
			local front = t + Geo.Offset(d), approach = front + Geo.Offset(d);
			if (!this.OpenWater(front) || !this.OpenWater(approach)) { why[1]++; continue; }
			local acc = AITile.GetCargoAcceptance(t, cargo, 1, 1, radius);
			if (target.kind != "pickup" && acc < (target.kind == "town" ? 20 : 8)) { why[2]++; continue; }
			if (!::MT.nb.TileFree(t) || !::MT.nb.StationOk(t, 1, 1, radius) ||
					(target.kind == "pickup" && !::MT.nb.PickupOk(t, 1, 1, radius, cargo, target.ind))) { why[3]++; continue; }
			if (raise == 0) {
				local ok;
				{
					local tm = AITestMode();
					ok = AIMarine.BuildDock(t, AIStation.STATION_NEW);
				}
				if (!ok) { why[4]++; Log.Debug("DEBUG", "dock at " + Util.TileStr(t) + ": " + AIError.GetLastErrorString()); continue; }
			}
			local site = {score = acc * 2 - AIMap.DistanceManhattan(t, center) * 3 - (raise != 0 ? 40 : 0), tile = t, dir = d,
				front = front, approach = approach, raise = raise};
			if (raise == 0) out.append(site);
			else raised.append(site);
		}
		/* natural sites first; the earthwork only where the coast offers none */
		if (out.len() == 0) out = raised;
		out.sort(function(a, b) { return b.score - a.score; });
		if (out.len() > max_n) out.resize(max_n);
		if (out.len() == 0) Log.Debug("DEBUG", "dock sites: " + list.Count() + " tiles; not inclined " + why[0] + ", no open water " + why[1] +
			", acceptance " + why[2] + ", other companies " + why[3] + ", refused " + why[4]);
		return out;
	}

	function BuildDock(site, join) {
		if (site.raise != 0 && !AITile.RaiseTile(site.tile, site.raise)) {
			Log.Warn("BUILD", "earthwork for a dock at " + Util.TileStr(site.tile) + " failed: " + AIError.GetLastErrorString());
			return -1;
		}
		if (!AIMarine.BuildDock(site.tile, join)) {
			if (join == AIStation.STATION_NEW || !AIMarine.BuildDock(site.tile, AIStation.STATION_NEW)) {
				Log.Warn("BUILD", "dock at " + Util.TileStr(site.tile) + " failed: " + AIError.GetLastErrorString());
				if (AIError.GetLastError() == AIError.ERR_LOCAL_AUTHORITY_REFUSES) ::MT.planner.OnRefused(AITile.GetClosestTown(site.tile));
				if (site.raise != 0) AITile.LowerTile(site.tile, site.raise);   // no earthwork left behind
				return -1;
			}
		}
		return AIStation.GetStationID(site.tile);
	}

	/* Water tiles next to an oil rig's own dock, where ships wait to load. */
	function RigApproach(ind) {
		local out = [];
		local dock = AIIndustry.GetDockLocation(ind);
		if (!AIMap.IsValidTile(dock)) return out;
		foreach (t, _ in Geo.Square(dock, 2)) if (this.OpenWater(t)) out.append(t);
		return out;
	}

	/* Approach tiles of a dock site (the open water beyond its water part, and around it). */
	function Approach(site) {
		local out = [site.approach];
		foreach (side in [Geo.Left(site.dir), Geo.Right(site.dir)]) {
			local t = site.approach + Geo.Offset(side);
			if (this.OpenWater(t)) out.append(t);
		}
		return out;
	}

	/* Length of the water way between two sets of approach tiles, or -1 (no lane within the search budget). */
	bodies = null;   // closed bodies of water found by searches that ran dry: [{tile -> true}, ...]

	/* Is a tile set known to lie in a closed body of water that does not reach the other set? */
	function Apart(from, to) {
		if (this.bodies == null) return false;
		foreach (body in this.bodies) {
			local in_from = false, in_to = false;
			foreach (t in from) if (t in body) { in_from = true; break; }
			foreach (t in to) if (t in body) { in_to = true; break; }
			if (in_from != in_to) return true;
		}
		return false;
	}

	function Lane(from, to, budget = 40000) {
		if (this.Apart(from, to)) return -1;
		local pf = WaterPathFinder();
		pf.max_nodes = budget;
		local d = pf.Distance(from, to);
		if (d < 0 && pf.exhausted != null) {
			if (this.bodies == null) this.bodies = [];
			if (this.bodies.len() < 12) this.bodies.append(pf.exhausted);
		}
		Log.Debug("DEBUG", "water lane " + Util.TileStr(from[0]) + " -> " + Util.TileStr(to[0]) + ": " + (d < 0 ? "none" : d + " tiles") +
			" after " + pf.expanded + " nodes" + (d < 0 ? ", got within " + pf.closest + " tiles" : ""));
		return d;
	}

	/*
	 * Ship depot near a dock: two tiles of open water along one axis, a few tiles away so it does not stand in
	 * front of the dock, with water around it so ships can turn in. Returns the depot tile or -1.
	 */
	function BuildDepotNear(site) {
		local cands = AIList();
		foreach (t, _ in Geo.Square(site.approach, 6)) {
			if (!this.OpenWater(t)) continue;
			local dd = AIMap.DistanceManhattan(t, site.approach);
			if (dd < 2) continue;
			cands.AddItem(t, 100 - dd);
		}
		foreach (t in Util.TopN(cands, 30)) {
			foreach (d in [DIR_PX, DIR_PY]) {
				local f = t + Geo.Offset(d);
				if (!this.OpenWater(f) || !this.OpenWater(t - Geo.Offset(d)) || !this.OpenWater(f + Geo.Offset(d))) continue;
				local ok;
				{
					local tm = AITestMode();
					ok = AIMarine.BuildWaterDepot(t, f);
				}
				if (!ok) continue;
				if (AIMarine.BuildWaterDepot(t, f)) {
					/* the depot tile is the one with the entrance; either half answers IsWaterDepotTile */
					return AIMarine.IsWaterDepotTile(t) ? t : f;
				}
			}
		}
		return -1;
	}
}
