/*
 * RailBuilder: terminus stations with a two-crossover throat, lines of two one-way tracks protected by
 * one-way path signals, and a depot behind the platforms.
 *
 * Station frame: o = outward (towards the line), din = inward, lat = Right(o).
 * Row 0 carries departures, row 1 (offset lat) arrivals. Platforms are O + k * din, k = 0 .. L-1.
 * Throat tiles outside the platforms: T1 = O - din, T2 = O - 2 din, T3 = O - 3 din in both rows.
 *   crossover on T1: arrivals (row 1) into platform row 0;
 *   crossover on T2: platform row 1 out to the departure track (row 0).
 * Both crossovers are S-curves (one 45 degree turn each way), which do not limit speed in OpenTTD.
 * Every station uses the same handedness, so the departure track of one end meets the arrival track of the
 * other end without the two tracks ever crossing.
 *
 * A new line starts with one track and one train (no signals: a single train cannot collide). When demand
 * needs more trains the second track is laid and both tracks get one-way PBS signals; only then does the
 * SafetyOfficer allow more than one train.
 */

const SIGNAL_SPACING = 6;

class RailBuilder {
	bridges = null;
	bad_sites = null;   // station origin tile -> date: the line could not leave this site

	constructor(bridge_cache) {
		this.bridges = bridge_cache;
		this.bad_sites = {};
	}

	/* The tiles just outside a terminus that the other track of the line needs (kept free for it). */
	function OtherCorridor(site, row) { return [this.T(site, row, -4), this.T(site, row, -5)]; }

	function T(site, row, k) { return site.O + k * Geo.Offset(site.din) + row * Geo.Offset(site.lat); }

	function MakeSite(town, O, o, L, railtype) {
		return {town = town, O = O, o = o, din = Geo.Opp(o), lat = Geo.Right(o), L = L, railtype = railtype, sid = -1, depot = -1};
	}

	/* All tiles a station reserves: throat, line start tiles, platforms and the depot end (a full rectangle). */
	function Footprint(site) {
		local out = [];
		for (local row = 0; row < 2; row++) {
			for (local k = -4; k <= site.L; k++) out.append(this.T(site, row, k));
		}
		return out;
	}

	/* Tiles around the footprint; levelling moves their corners too, so they must be free of buildings. */
	function Ring(site) {
		local out = [];
		for (local k = -5; k <= site.L + 1; k++) {
			out.append(this.T(site, -1, k));
			out.append(this.T(site, 2, k));
		}
		out.append(this.T(site, 0, -5)); out.append(this.T(site, 1, -5));
		out.append(this.T(site, 0, site.L + 1)); out.append(this.T(site, 1, site.L + 1));
		return out;
	}

	function TopLeft(site) {
		local a = this.T(site, 0, 0), b = this.T(site, 1, site.L - 1);
		return AIMap.GetTileIndex(min(Geo.X(a), Geo.X(b)), min(Geo.Y(a), Geo.Y(b)));
	}

	function Axis(site) {
		return (site.din == DIR_PX || site.din == DIR_NX) ? AIRail.RAILTRACK_NE_SW : AIRail.RAILTRACK_NW_SE;
	}

	function StationWH(site) {
		return (site.din == DIR_PX || site.din == DIR_NX) ? [site.L, 2] : [2, site.L];
	}

	/*
	 * Heightmap rectangle to level a footprint: CMD_LEVEL_LAND moves the north corner of every tile in the
	 * area, so the far corners of the last row and column need the area to reach one tile further.
	 */
	function Rect(site) {
		local x0 = 1 << 30, y0 = 1 << 30, x1 = -1, y1 = -1;
		foreach (t in this.Footprint(site)) {
			x0 = min(x0, Geo.X(t)); y0 = min(y0, Geo.Y(t)); x1 = max(x1, Geo.X(t)); y1 = max(y1, Geo.Y(t));
		}
		return [AIMap.GetTileIndex(x0, y0), AIMap.GetTileIndex(x1 + 1, y1 + 1)];
	}

	/*
	 * Station site near `town` whose throat faces `toward` (or a perpendicular direction if needed).
	 * Footprint tiles must be buildable and outside flood risk. Flat sites at one height are preferred; a site
	 * whose heights differ by one level is accepted with a penalty and levelled before building.
	 * Catchment: at least 30% of what a station in the town centre would see (CargoDist's symmetric demand is
	 * limited by the weaker end), unless the site is close enough for walk-in stops to bring the centre in.
	 */
	function FindSite(town, toward, L, railtype, join_sid, reserved) {
		local center = AITown.GetLocation(town);
		local r = 10 + min(12, (AITown.GetPopulation(town) / 400).tointeger());
		local cx = Geo.X(center), cy = Geo.Y(center);
		local x0 = max(3, cx - r - L), y0 = max(3, cy - r - L);
		local x1 = min(AIMap.GetMapSizeX() - 4, cx + r + L), y1 = min(AIMap.GetMapSizeY() - 4, cy + r + L);
		local info = {};   // tile -> [min height, max height]
		local list = AITileList();
		list.AddRectangle(AIMap.GetTileIndex(x0, y0), AIMap.GetTileIndex(x1, y1));
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		foreach (t, _ in list) {
			if (reserved != null && (t in reserved)) continue;
			if (AIRoad.IsRoadTile(t) || !::MT.safety.TileOk(t)) continue;
			local sl = AITile.GetSlope(t);
			if (AITile.IsSteepSlope(sl) || AITile.IsHalftileSlope(sl)) continue;
			info[t] <- [AITile.GetMinHeight(t), AITile.GetMaxHeight(t)];
		}
		local o_pref = Geo.Towards(center, toward);
		local trees_ok = Util.TreeAllowance(town);
		local ref = AITile.GetCargoAcceptance(center, Util.pax, 2, L, 4);
		local min_acc = max(8, ref * 30 / 100);
		local walk = max(3, ::MT.game.station_spread - 2);
		local scored = [];
		foreach (o in [o_pref, Geo.Left(o_pref), Geo.Right(o_pref)]) {
			foreach (t, hh in info) {
				local dc = AIMap.DistanceManhattan(t, center);
				if (dc > r || (t in this.bad_sites)) continue;
				local site = this.MakeSite(town, t, o, L, railtype);
				local good = true, lo = 1000, hi = -1;
				foreach (ft in this.Footprint(site)) {
					if (!(ft in info)) { good = false; break; }
					local h = info[ft];
					lo = min(lo, h[0]); hi = max(hi, h[1]);
					if (hi - lo > 1) { good = false; break; }
				}
				if (!good) continue;
				/* the line leaves the throat straight: the first tile outside must be free as well */
				foreach (row in [0, 1]) {
					local ex = this.T(site, row, -5);
					if (!AITile.IsBuildable(ex) || AIRoad.IsRoadTile(ex) || !::MT.safety.TileOk(ex) || (reserved != null && (ex in reserved))) good = false;
				}
				if (!good) continue;
				local flat = hi == lo;
				if (!flat) {
					foreach (rt in this.Ring(site)) {
						if (!AITile.IsBuildable(rt) || AIRoad.IsRoadTile(rt) || ::MT.safety.IsFloodRisk(rt)) { good = false; break; }
					}
					if (!good) continue;
				}
				local trees = 0;
				foreach (ft in this.Footprint(site)) if (AITile.HasTreeOnTile(ft)) trees++;
				if (trees > trees_ok) continue;
				local wh = this.StationWH(site);
				local acc = AITile.GetCargoAcceptance(this.TopLeft(site), Util.pax, wh[0], wh[1], 4);
				if (acc < min_acc && dc > walk) continue;
				local score = acc * 3 - dc * 4 - (o == o_pref ? 0 : 40) - (flat ? 0 : 60) - trees * 8;
				/* prefer sites whose throat is on the side of the destination */
				score -= AIMap.DistanceManhattan(this.T(site, 0, -4), toward) - AIMap.DistanceManhattan(t, toward);
				site.level <- !flat;
				scored.append([score, site]);
			}
			if (scored.len() >= 40) break;
		}
		scored.sort(function(a, b) { return b[0] - a[0]; });
		local tries = 0;
		foreach (sc in scored) {
			if (++tries > 14) break;
			local site = sc[1];
			local good;
			{
				local tm = AITestMode();
				AIRail.SetCurrentRailType(railtype);
				if (site.level) {
					local rc = this.Rect(site);
					good = AITile.LevelTiles(rc[0], rc[1]);
				} else {
					good = AIRail.BuildRailStation(this.TopLeft(site), this.Axis(site), 2, L, join_sid);
					if (!good && join_sid != AIStation.STATION_NEW) good = AIRail.BuildRailStation(this.TopLeft(site), this.Axis(site), 2, L, AIStation.STATION_NEW);
				}
			}
			if (good) return site;
		}
		local near = 0;
		foreach (t, hh in info) if (AIMap.DistanceManhattan(t, center) <= r) near++;
		Log.Info("PLAN", "rail site search in " + Util.TownName(town) + " (pop " + AITown.GetPopulation(town) + ", r " + r + "): " +
			near + " free tiles in range, " + scored.len() + " footprints, none buildable; min acceptance " + min_acc + " (centre " + ref + ")");
		return null;
	}

	function IsLevel(site) {
		local h = -1;
		foreach (t in this.Footprint(site)) {
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::MT.safety.IsFloodRisk(t)) return false;
			if (h < 0) h = AITile.GetMinHeight(t);
			else if (AITile.GetMinHeight(t) != h) return false;
		}
		return true;
	}

	/*
	 * Level a site that is not flat. CMD_LEVEL_LAND reports success when any corner moved, so the result is
	 * checked; the reference height (north corner of the start tile) is tried from both ends of the rectangle.
	 */
	function Level(site) {
		if (!("level" in site) || !site.level) return true;
		local rc = this.Rect(site);
		foreach (pair in [[rc[0], rc[1]], [rc[1], rc[0]]]) {
			AITile.LevelTiles(pair[0], pair[1]);
			if (this.IsLevel(site)) { site.level = false; return true; }
		}
		Log.Warn("BUILD", "levelling " + Util.TileStr(rc[0]) + "-" + Util.TileStr(rc[1]) + " did not give a flat site: " + AIError.GetLastErrorString());
		return false;
	}

	function Fail(what, town = -1) {
		local err = AIError.GetLastError();
		Log.Warn("BUILD", what + " failed: " + AIError.GetLastErrorString());
		if (err == AIError.ERR_LOCAL_AUTHORITY_REFUSES && town >= 0) ::MT.planner.OnRefused(town);
		return false;
	}

	/* Station, throat (both crossovers) and depot. Sets site.sid and site.depot. */
	function BuildStation(site, join_sid) {
		AIRail.SetCurrentRailType(site.railtype);
		if (!this.Level(site)) return this.Fail("site levelling");
		local tl = this.TopLeft(site);
		if (!AIRail.BuildRailStation(tl, this.Axis(site), 2, site.L, join_sid)) {
			if (join_sid == AIStation.STATION_NEW || !AIRail.BuildRailStation(tl, this.Axis(site), 2, site.L, AIStation.STATION_NEW)) {
				return this.Fail("rail station at " + Util.TileStr(tl), site.town);
			}
		}
		site.sid = AIStation.GetStationID(tl);
		local T = this.T.bindenv(this);
		for (local row = 0; row < 2; row++) {
			if (!AIRail.BuildRail(T(site, row, 0), T(site, row, -1), T(site, row, -2))) return this.Fail("throat");
			if (!AIRail.BuildRail(T(site, row, -1), T(site, row, -2), T(site, row, -3))) return this.Fail("throat");
			if (!AIRail.BuildRail(T(site, row, -2), T(site, row, -3), T(site, row, -4))) return this.Fail("throat");
		}
		if (!AIRail.BuildRail(T(site, 1, -2), T(site, 1, -1), T(site, 0, -1))) return this.Fail("crossover 1");
		if (!AIRail.BuildRail(T(site, 1, -1), T(site, 0, -1), T(site, 0, 0))) return this.Fail("crossover 1");
		if (!AIRail.BuildRail(T(site, 1, -1), T(site, 1, -2), T(site, 0, -2))) return this.Fail("crossover 2");
		if (!AIRail.BuildRail(T(site, 1, -2), T(site, 0, -2), T(site, 0, -3))) return this.Fail("crossover 2");
		local depot = T(site, 0, site.L);
		if (!AIRail.BuildRailDepot(depot, T(site, 0, site.L - 1))) return this.Fail("rail depot");
		site.depot = depot;
		return true;
	}

	/* Throat signals: departures leave through row 0, arrivals wait before the throat on row 1. */
	function BuildThroatSignals(site) {
		AIRail.SetCurrentRailType(site.railtype);
		local ok = AIRail.BuildSignal(this.T(site, 0, -3), this.T(site, 0, -2), AIRail.SIGNALTYPE_PBS_ONEWAY);
		ok = AIRail.BuildSignal(this.T(site, 1, -3), this.T(site, 1, -4), AIRail.SIGNALTYPE_PBS_ONEWAY) && ok;
		if (!ok) Log.Warn("BUILD", "throat signal at " + Util.TileStr(this.T(site, 0, -3)) + ": " + AIError.GetLastErrorString());
		return ok;
	}

	/* Path endpoints: P1 from A's departures to B's arrivals, P2 from B's departures to A's arrivals. */
	function Ends(from_site, to_site) {
		return {start = this.T(from_site, 0, -3), start_dir = from_site.o, goal = this.T(to_site, 1, -3), goal_dir = to_site.din};
	}

	/*
	 * Find and build one track. `forbidden` is a table of tiles to avoid (stations, the other track).
	 * Returns the path ([{tile, kind}]) or null.
	 */
	function BuildTrack(from_site, to_site, forbidden, prefer, railtype) {
		this.trapped = false;
		local ends = this.Ends(from_site, to_site);
		local blocked = {};
		foreach (t, v in forbidden) blocked[t] <- v;
		for (local attempt = 0; attempt < 3; attempt++) {
			local pf = RailPathFinder(this.bridges);
			pf.max_nodes = min(120000, max(40000, 320 * AIMap.DistanceManhattan(ends.start, ends.goal)));
			if (prefer != null) pf.weight = 1.5;
			pf.forbidden = blocked;
			if (prefer != null) pf.prefer = prefer;
			local path = pf.FindPath(ends.start, ends.start_dir, ends.goal, ends.goal_dir);
			Log.Info("BUILD", "rail path " + Util.TileStr(ends.start) + " -> " + Util.TileStr(ends.goal) + ": " +
				(path == null ? "none" : path.len() + " tiles") + " (" + pf.expanded + " nodes)");
			if (path == null) {
				if (pf.expanded < 60) this.trapped = true;
				return null;
			}
			local fail = this.BuildPath(path, railtype);
			if (fail < 0) return path;
			Log.Warn("BUILD", "rail build failed at " + Util.TileStr(path[fail].tile) + ": " + AIError.GetLastErrorString() + "; re-planning");
			this.RemovePath(path, fail);
			blocked[path[fail].tile] <- true;
		}
		return null;
	}

	/* ---------------- junctions on existing double track ---------------- */

	/* Departure and arrival track of one end of a doubled line (decoded paths). */
	function StationPaths(line, end) {
		local p1 = ::MT.planner.Decode(line.p1), p2 = ::MT.planner.Decode(line.p2);
		return end == 0 ? {dep = p1, arr = p2} : {dep = p2, arr = p1};
	}

	function FreeForTrack(t, forbidden) {
		if (forbidden != null && (t in forbidden)) return false;
		if (!Geo.InMap(t, 2) || !AITile.IsBuildable(t) || AIRoad.IsRoadTile(t) || !::MT.safety.TileOk(t)) return false;
		local sl = AITile.GetSlope(t);
		return sl == AITile.SLOPE_FLAT;
	}

	/* A plain straight tile of a path without signals, between index lo and hi. */
	function PlainStraight(path, i) {
		if (path[i - 1].kind != PF_KIND_NORMAL || path[i].kind != PF_KIND_NORMAL || path[i + 1].kind != PF_KIND_NORMAL) return -1;
		local a = path[i - 1].tile, b = path[i].tile, c = path[i + 1].tile;
		local u = Geo.DirOf(a, b);
		if (u < 0 || u != Geo.DirOf(b, c)) return -1;
		if (AIRail.GetSignalType(b, a) != AIRail.SIGNALTYPE_NONE || AIRail.GetSignalType(b, c) != AIRail.SIGNALTYPE_NONE) return -1;
		local tracks = AIRail.GetRailTracks(b);
		if (tracks != AIRail.RAILTRACK_NE_SW && tracks != AIRail.RAILTRACK_NW_SE) return -1;
		return u;
	}

	/*
	 * Switch on a departure track: the new line leaves tile path[i] sideways into an empty tile q.
	 * Returns a start spec for BuildTrackSpec, or null.
	 */
	function BranchPoint(dep, forbidden) {
		for (local i = 3; i < dep.len() - 3 && i < 45; i++) {
			local u = this.PlainStraight(dep, i);
			if (u < 0) continue;
			local a = dep[i - 1].tile, b = dep[i].tile;
			foreach (side in [Geo.Left(u), Geo.Right(u)]) {
				local q = b + Geo.Offset(side);
				if (!this.FreeForTrack(q, forbidden) || !this.FreeForTrack(q + Geo.Offset(side), forbidden)) continue;
				local ok;
				{
					local tm = AITestMode();
					ok = AIRail.BuildRail(a, b, q);
				}
				if (ok) return {tile = q, dir = side, opts = {free = true, prev = u}, sw = [a, b, q]};
			}
		}
		return null;
	}

	/* Merge into an arrival track: the new line joins tile path[j] from the side. Returns a goal spec or null. */
	function MergePoint(arr, forbidden) {
		local n = arr.len();
		for (local j = n - 4; j >= 2 && j > n - 45; j--) {
			local w = this.PlainStraight(arr, j);
			if (w < 0) continue;
			local b = arr[j].tile, c = arr[j + 1].tile;
			foreach (side in [Geo.Left(w), Geo.Right(w)]) {
				local q = b + Geo.Offset(side);
				if (!this.FreeForTrack(q, forbidden) || !this.FreeForTrack(q + Geo.Offset(side), forbidden)) continue;
				local ok;
				{
					local tm = AITestMode();
					ok = AIRail.BuildRail(q, b, c);
				}
				if (ok) return {tile = b, dir = Geo.Opp(side), next = w, merge = [q, b, c]};
			}
		}
		return null;
	}

	/* Start and goal specs of a plain terminus end. */
	function TerminusStart(site) { return {tile = this.T(site, 0, -3), dir = site.o, opts = null, sw = null}; }
	function TerminusGoal(site) { return {tile = this.T(site, 1, -3), dir = site.din, next = -1, merge = null}; }

	/*
	 * Find and build one track between two specs (terminus or junction). Junction pieces are added to the
	 * existing track only once the new track is laid. Returns the path or null (everything removed again).
	 */
	trapped = false;   // the last search died next to its start: the site has no way out

	function BuildTrackSpec(start, goal, forbidden, prefer, railtype) {
		this.trapped = false;
		local blocked = {};
		foreach (t, v in forbidden) blocked[t] <- v;
		for (local attempt = 0; attempt < 3; attempt++) {
			local pf = RailPathFinder(this.bridges);
			pf.max_nodes = min(120000, max(40000, 320 * AIMap.DistanceManhattan(start.tile, goal.tile)));
			if (prefer != null) { pf.prefer = prefer; pf.weight = 1.5; }
			pf.forbidden = blocked;
			local opts = start.opts == null ? {} : start.opts;
			if (goal.next >= 0) opts.goal_next <- goal.next;
			local path = pf.FindPath(start.tile, start.dir, goal.tile, goal.dir, opts);
			Log.Info("BUILD", "rail path " + Util.TileStr(start.tile) + " -> " + Util.TileStr(goal.tile) + ": " +
				(path == null ? "none" : path.len() + " tiles") + " (" + pf.expanded + " nodes)" +
				(start.sw != null ? ", branching off at " + Util.TileStr(start.sw[1]) : "") +
				(goal.merge != null ? ", merging at " + Util.TileStr(goal.merge[1]) : ""));
			if (path == null) {
				if (pf.expanded < 60) this.trapped = true;
				return null;
			}
			if (start.sw != null) path.insert(0, {tile = start.sw[1], kind = PF_KIND_NORMAL});
			AIRail.SetCurrentRailType(railtype);
			local fail = this.BuildPath(path, railtype);
			if (fail < 0) {
				local ok = true;
				if (start.sw != null) {
					local sw = start.sw;
					ok = this.Retry(function() : (sw) { return AIRail.BuildRail(sw[0], sw[1], sw[2]); });
				}
				if (ok && goal.merge != null) {
					local mg = goal.merge;
					ok = this.Retry(function() : (mg) { return AIRail.BuildRail(mg[0], mg[1], mg[2]); });
					if (!ok && start.sw != null) AIRail.RemoveRail(start.sw[0], start.sw[1], start.sw[2]);
				}
				if (ok) return path;
				Log.Warn("BUILD", "junction failed: " + AIError.GetLastErrorString());
				this.RemovePath(path, path.len() - 1);
				return null;
			}
			Log.Warn("BUILD", "rail build failed at " + Util.TileStr(path[fail].tile) + ": " + AIError.GetLastErrorString() + "; re-planning");
			this.RemovePath(path, fail);
			blocked[path[fail].tile] <- true;
		}
		return null;
	}

	/* Build a path; returns -1 on success or the index of the tile that failed. */
	function BuildPath(path, railtype) {
		AIRail.SetCurrentRailType(railtype);
		local n = path.len();
		for (local i = 1; i < n - 1; i++) {
			if (i % 40 == 0) MT_Housekeeping();
			local cur = path[i].tile, prev = path[i - 1].tile, next = path[i + 1].tile;
			local nk = path[i + 1].kind, ck = path[i].kind;
			if (nk == PF_KIND_BRIDGE) {
				local len = AIMap.DistanceManhattan(cur, next) + 1;
				local b = this.bridges.Fastest(len);
				if (b < 0 || !this.Retry(function() : (b, cur, next) { return AIBridge.BuildBridge(AIVehicle.VT_RAIL, b, cur, next); })) return i;
				continue;
			}
			if (nk == PF_KIND_TUNNEL) {
				if (!this.Retry(function() : (cur) { return AITunnel.BuildTunnel(AIVehicle.VT_RAIL, cur); })) return i;
				continue;
			}
			if (ck == PF_KIND_BRIDGE || ck == PF_KIND_TUNNEL) continue;
			if (!this.Retry(function() : (prev, cur, next) { return AIRail.BuildRail(prev, cur, next); })) {
				if (AIError.GetLastError() == AIError.ERR_ALREADY_BUILT && AIRail.AreTilesConnected(prev, cur, next)) continue;
				return i;
			}
		}
		return -1;
	}

	function Retry(fn) {
		for (local i = 0; i < 20; i++) {
			if (fn()) return true;
			local err = AIError.GetLastError();
			if (err == AIError.ERR_NOT_ENOUGH_CASH) {
				if (!::MT.finance.Ensure(20000)) return false;
				continue;
			}
			if (err != AIError.ERR_VEHICLE_IN_THE_WAY) return false;
			AIController.Sleep(10);
		}
		return false;
	}

	/* Remove the part of a path that was built before index `upto` (exclusive), keeping the end tiles. */
	function RemovePath(path, upto) {
		for (local i = 1; i < upto && i < path.len() - 1; i++) {
			local t = path[i].tile;
			if (AIRail.IsRailStationTile(t) || AIRail.IsRailDepotTile(t)) continue;   // never part of a path; never demolish
			if (AIRail.IsRailTile(t) || AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) AITile.DemolishTile(t);
		}
	}

	/* Tiles of a path including the tiles under bridges and inside tunnels (for audits). */
	function PathTiles(path) {
		local out = [];
		for (local i = 0; i < path.len(); i++) {
			out.append(path[i].tile);
			if (i > 0 && path[i].kind != PF_KIND_NORMAL) {
				local a = path[i - 1].tile, b = path[i].tile;
				local d = Geo.LineDir(a, b);
				for (local t = a + Geo.Offset(d); t != b; t += Geo.Offset(d)) out.append(t);
			}
		}
		return out;
	}

	/* One-way PBS signals every SIGNAL_SPACING tiles in the direction of travel. Returns the signal count. */
	function SignalPath(path, railtype) {
		AIRail.SetCurrentRailType(railtype);
		local count = 0, since = 0;
		for (local i = 2; i < path.len() - 2; i++) {
			since++;
			if (since < SIGNAL_SPACING) continue;
			if (path[i].kind != PF_KIND_NORMAL || path[i + 1].kind != PF_KIND_NORMAL) continue;
			if (AIMap.DistanceManhattan(path[i - 1].tile, path[i].tile) != 1) continue;
			if (path[i - 1].kind != PF_KIND_NORMAL && AIMap.DistanceManhattan(path[i - 1].tile, path[i].tile) == 1 &&
				i >= 2 && AIMap.DistanceManhattan(path[i - 2].tile, path[i - 1].tile) != 1) continue;   // right behind a bridge
			if (AIRail.BuildSignal(path[i].tile, path[i - 1].tile, AIRail.SIGNALTYPE_PBS_ONEWAY)) {
				count++;
				since = 0;
			}
		}
		return count;
	}

	/* Check that a built path is continuous (every piece connects its neighbours). */
	function Verify(path) {
		for (local i = 1; i < path.len() - 1; i++) {
			local prev = path[i - 1].tile, cur = path[i].tile, next = path[i + 1].tile;
			if (path[i].kind != PF_KIND_NORMAL || path[i + 1].kind != PF_KIND_NORMAL) continue;
			if (AIMap.DistanceManhattan(prev, cur) != 1) continue;
			if (!AIRail.AreTilesConnected(prev, cur, next)) return i;
		}
		return -1;
	}
}
