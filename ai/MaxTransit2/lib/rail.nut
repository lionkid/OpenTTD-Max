/*
 * RailBuilder: terminus stations with a two-crossover throat, lines of two one-way tracks protected by
 * one-way path signals, and a depot behind the platforms. The same terminus serves a town (passengers),
 * a mine or farm (freight pickup) and a power station or factory (drop-off).
 *
 * Station frame: o = outward (towards the line), din = inward, lat = Right(o).
 * Row 0 carries departures, row 1 (offset lat) arrivals. Platforms are O + k * din, k = 0 .. L-1.
 * Throat tiles outside the platforms: T1 = O - din, T2 = O - 2 din, T3 = O - 3 din in both rows.
 *   crossover on T1: arrivals (row 1) into platform row 0;
 *   crossover on T2: platform row 1 out to the departure track (row 0).
 * Every station uses the same handedness, so the departure track of one end meets the arrival track of the
 * other end without the two tracks ever crossing, and the second track always lies on the same side of the
 * first: the pair runs as one parallel double line.
 *
 * A new line starts with one track and one train (no signals: a single train cannot collide). When the
 * traffic needs more trains the second track is laid alongside and both tracks get one-way PBS signals at
 * the same spacing, placed side by side where the tracks run in parallel.
 */

const SIGNAL_SPACING = 6;

class RailBuilder {
	bridges = null;
	bad_sites = null;   // station origin tile -> date: the line could not leave this site
	line_speed = 160;   // speed of the line being built (bridge type)
	guide = null;       // tiles of the first track while the second one is searched (start to goal order)
	twin_shift = 0;     // offset of the future second track from the one being planned (0: no double line in view)
	guide_share = null; // first track's diagonal tiles -> the free half the second track may take there
	last_trees = 0;     // trees on the tiles of the last path that was built

	constructor(bridge_cache) {
		this.bridges = bridge_cache;
		this.bad_sites = {};
	}

	/* The tiles just outside a terminus that the other track of the line needs (kept free for it). */
	function OtherCorridor(site, row) { return [this.T(site, row, -4), this.T(site, row, -5)]; }

	/*
	 * From the moment a terminus is built until its tracks are laid, the two tiles where each track leaves or
	 * enters the station hold loose rail pieces across the line (connected to nothing): a town does not build
	 * houses on rail, so a search that takes weeks still finds its way out. The searches treat these tiles as
	 * free (own_free) and BuildPath lifts each piece just before it lays the track there.
	 */
	own_free = null;   // tile -> placeholder track, for the next searches and BuildPath

	function CrossTrack(site) {
		return (site.din == DIR_PX || site.din == DIR_NX) ? AIRail.RAILTRACK_NW_SE : AIRail.RAILTRACK_NE_SW;
	}

	function IsPlaceholder(t, track) {
		return AIRail.IsRailTile(t) && !AIRail.IsRailStationTile(t) && !AIRail.IsRailDepotTile(t) &&
			Util.IsMine(t) && AIRail.GetRailTracks(t) == track;
	}

	function UsePlaceholders(sites) {
		this.own_free = {};
		foreach (site in sites) {
			if (site == null) continue;
			local track = this.CrossTrack(site);
			foreach (row in [0, 1]) foreach (t in this.OtherCorridor(site, row)) if (this.IsPlaceholder(t, track)) this.own_free[t] <- track;
		}
	}

	function ClearPlaceholder(t) {
		if (this.own_free == null || !(t in this.own_free)) return;
		if (this.IsPlaceholder(t, this.own_free[t])) AIRail.RemoveRailTrack(t, this.own_free[t]);
		delete this.own_free[t];
	}

	function ReserveCorridor(site, row) {
		AIRail.SetCurrentRailType(site.railtype);
		local track = this.CrossTrack(site), out = (row == 1 ? 1 : -1) * Geo.Offset(site.lat);
		foreach (t in this.OtherCorridor(site, row)) {
			if (!AITile.IsBuildable(t) || AITile.GetSlope(t) != AITile.SLOPE_FLAT) continue;
			if (AIRail.IsRailTile(t + out)) continue;
			AIRail.BuildRailTrack(t, track);
		}
	}

	function FreeCorridor(site, row) {
		local track = this.CrossTrack(site);
		foreach (t in this.OtherCorridor(site, row)) if (this.IsPlaceholder(t, track)) AIRail.RemoveRailTrack(t, track);
	}

	function T(site, row, k) { return site.O + k * Geo.Offset(site.din) + row * Geo.Offset(site.lat); }

	function MakeSite(O, o, L, railtype) {
		return {O = O, o = o, din = Geo.Opp(o), lat = Geo.Right(o), L = L, railtype = railtype, sid = -1, depot = -1};
	}

	/* All tiles a station reserves: throat, line start tiles, platforms and the depot end (a full rectangle). */
	function Footprint(site) {
		local out = [];
		for (local row = 0; row < 2; row++) {
			for (local k = -4; k <= site.L; k++) out.append(this.T(site, row, k));
		}
		return out;
	}

	function Platforms(site) {
		local out = [];
		for (local row = 0; row < 2; row++) for (local k = 0; k < site.L; k++) out.append(this.T(site, row, k));
		return out;
	}

	/*
	 * Is there open land beyond tile t? Depth-first over tiles a track could use, away from `blocked`; `need`
	 * tiles reached are enough. A throat that opens into a pocket between houses and roads fails this.
	 */
	function OpenAround(t, blocked, need) {
		if (!this.Open(t)) return false;
		local seen = {}, stack = [t], n = 0;
		seen[t] <- true;
		while (stack.len() > 0 && n < need) {
			local c = stack.pop();
			n++;
			for (local d = 0; d < 4; d++) {
				local x = c + Geo.Offset(d);
				if (x in seen) continue;
				seen[x] <- true;
				if (!(x in blocked) && this.Open(x)) stack.append(x);
			}
		}
		return n >= need;
	}

	/* Can a railway leave both rows of the throat? A short real search from each throat end must get 10 tiles away. */
	function CanLeave(site, blocked) {
		foreach (row in [0, 1]) {
			local other = this.T(site, 1 - row, -5), own = this.T(site, row, -4);
			local was_other = other in blocked, was_own = own in blocked;
			blocked[other] <- true;
			if (was_own) delete blocked[own];
			local guide = this.T(site, row, -16);
			if (!AIMap.IsValidTile(guide)) guide = own;
			local pf = RailPathFinder(this.bridges);
			pf.max_nodes = 1500;
			pf.forbidden = blocked;
			local path = pf.FindPath(this.T(site, row, -3), site.o, guide, site.o, {escape = 10});
			if (!was_other) delete blocked[other];
			if (was_own) blocked[own] <- true;
			if (path == null) return false;
		}
		return true;
	}

	function Open(t) {
		if (!Geo.InMap(t, 2) || !AITile.IsBuildable(t) || AIRoad.IsRoadTile(t) || !::MT.safety.TileOk(t)) return false;
		if (!::MT.nb.TileFree(t)) return false;
		local sl = AITile.GetSlope(t);
		return !AITile.IsSteepSlope(sl) && !AITile.IsHalftileSlope(sl);
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

	/* Heightmap rectangle to level a footprint (CMD_LEVEL_LAND moves the north corner of every tile). */
	function Rect(site) {
		local x0 = 1 << 30, y0 = 1 << 30, x1 = -1, y1 = -1;
		foreach (t in this.Footprint(site)) {
			x0 = min(x0, Geo.X(t)); y0 = min(y0, Geo.Y(t)); x1 = max(x1, Geo.X(t)); y1 = max(y1, Geo.Y(t));
		}
		return [AIMap.GetTileIndex(x0, y0), AIMap.GetTileIndex(x1 + 1, y1 + 1)];
	}

	/*
	 * Station site for `target`, whose throat faces `toward` (or a perpendicular direction if needed):
	 *   {kind = "town", town}: passengers; catchment at least 30% of a station in the town centre;
	 *   {kind = "pickup", ind, cargo}: a platform within the catchment of the industry's production;
	 *   {kind = "drop", ind, cargo}: a platform where the industry accepts the cargo.
	 * Footprint tiles must be buildable, outside flood risk and outside other companies' buffer. Flat sites at
	 * one height are preferred; a site whose heights differ by one level is levelled before building.
	 */
	function FindSite(target, toward, L, railtype, join_sid, reserved) {
		local site = null;
		if (target.kind == "town") {
			local town = target.town;
			local r = 10 + min(12, (AITown.GetPopulation(town) / 400).tointeger());
			site = this.FindSiteR(target, toward, L, railtype, join_sid, reserved, r, 30);
			if (site == null) site = this.FindSiteR(target, toward, L, railtype, join_sid, reserved, r + 8, 15);
		} else {
			site = this.FindSiteR(target, toward, L, railtype, join_sid, reserved, L + 7, 0);
		}
		if (site == null) Log.Info("PLAN", "no rail station site at " + (target.kind == "town" ? Util.TownName(target.town) : Util.IndustryName(target.ind)));
		return site;
	}

	function Center(target) {
		return target.kind == "town" ? AITown.GetLocation(target.town) : AIIndustry.GetLocation(target.ind);
	}

	function FindSiteR(target, toward, L, railtype, join_sid, reserved, r, acc_pct) {
		local center = this.Center(target);
		local cx = Geo.X(center), cy = Geo.Y(center);
		local x0 = max(3, cx - r - L), y0 = max(3, cy - r - L);
		local x1 = min(AIMap.GetMapSizeX() - 4, cx + r + L), y1 = min(AIMap.GetMapSizeY() - 4, cy + r + L);
		local radius = ::MT.game.Catchment(MODE_RAIL);
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
		local cover = null;
		if (target.kind == "pickup" || target.kind == "drop") {
			cover = {};
			local cl = target.kind == "pickup" ? AITileList_IndustryProducing(target.ind, radius) : AITileList_IndustryAccepting(target.ind, radius);
			foreach (t, _ in cl) cover[t] <- true;
		}
		local town = target.kind == "town" ? target.town : AITile.GetClosestTown(center);
		local o_pref = Geo.Towards(center, toward);
		local trees_ok = Util.TreeAllowance(town);
		local cargo = target.kind == "town" ? Util.pax : target.cargo;
		local ref = target.kind == "town" ? AITile.GetCargoAcceptance(center, Util.pax, 2, L, radius) : 8;
		local min_acc = target.kind == "town" ? max(8, ref * acc_pct / 100) : 8;
		local walk = max(3, ::MT.game.station_spread - 2);
		local scored = [];
		foreach (o in [o_pref, Geo.Left(o_pref), Geo.Right(o_pref)]) {
			foreach (t, hh in info) {
				local dc = AIMap.DistanceManhattan(t, center);
				if (dc > r || (t in this.bad_sites)) continue;
				local site = this.MakeSite(t, o, L, railtype);
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
				if (cover != null) {
					local covered = false;
					foreach (pt in this.Platforms(site)) if (pt in cover) { covered = true; break; }
					if (!covered) continue;
				}
				local flat = hi == lo;
				local trees = 0;
				if (!flat) {
					/* levelling clears the ring as well: its trees count against the town rating too */
					foreach (rt in this.Ring(site)) {
						if (!AITile.IsBuildable(rt) || AIRoad.IsRoadTile(rt) || ::MT.safety.IsFloodRisk(rt)) { good = false; break; }
						if (AITile.HasTreeOnTile(rt)) trees++;
					}
					if (!good) continue;
				}
				foreach (ft in this.Footprint(site)) if (AITile.HasTreeOnTile(ft)) trees++;
				if (trees > trees_ok) continue;
				local wh = this.StationWH(site);
				local acc = AITile.GetCargoAcceptance(this.TopLeft(site), cargo, wh[0], wh[1], radius);
				local score;
				if (target.kind == "town") {
					if (acc < min_acc && dc > walk) continue;
					score = acc * 3 - dc * 4;
				} else {
					if (target.kind == "drop" && acc < 8) continue;
					score = 300 - dc * 6;
				}
				score -= (o == o_pref ? 0 : 40) + (flat ? 0 : 60) + trees * 8;
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
			local wh = this.StationWH(site);
			if (!::MT.nb.StationOk(this.TopLeft(site), wh[0], wh[1], radius)) continue;
			if (target.kind == "pickup" && !::MT.nb.PickupOk(this.TopLeft(site), wh[0], wh[1], radius, target.cargo, target.ind)) continue;
			local blocked = {};
			foreach (ft in this.Footprint(site)) blocked[ft] <- true;
			if (reserved != null) foreach (ft, _ in reserved) blocked[ft] <- true;
			local open = true;
			foreach (row in [0, 1]) {
				local other = this.T(site, 1 - row, -5);
				blocked[other] <- true;
				if (!this.OpenAround(this.T(site, row, -5), blocked, 80)) open = false;
				delete blocked[other];
			}
			if (!open || !this.CanLeave(site, blocked)) continue;
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

	/* Level a site that is not flat; the reference height is tried from both ends of the rectangle. */
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
	function BuildStation(site, join_sid, town) {
		AIRail.SetCurrentRailType(site.railtype);
		if (!this.Level(site)) return this.Fail("site levelling");
		local tl = this.TopLeft(site);
		if (!AIRail.BuildRailStation(tl, this.Axis(site), 2, site.L, join_sid)) {
			if (join_sid == AIStation.STATION_NEW || !AIRail.BuildRailStation(tl, this.Axis(site), 2, site.L, AIStation.STATION_NEW)) {
				return this.Fail("rail station at " + Util.TileStr(tl), town);
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

	/* Find and build one track between two termini. Returns the path ([{tile, kind}]) or null. */
	function BuildTrack(from_site, to_site, forbidden, prefer, railtype) {
		local ends = this.Ends(from_site, to_site);
		return this.BuildTrackSpec({tile = ends.start, dir = ends.start_dir, opts = null, sw = null},
			{tile = ends.goal, dir = ends.goal_dir, next = -1, merge = null}, forbidden, prefer, railtype);
	}

	/* ---------------- junctions on existing double track ---------------- */

	/* Departure and arrival track of one end of a doubled line (decoded paths). */
	function StationPaths(route, end) {
		local p1 = this.Decode(route.p1), p2 = this.Decode(route.p2);
		return end == 0 ? {dep = p1, arr = p2} : {dep = p2, arr = p1};
	}

	function FreeForTrack(t, forbidden) {
		if (forbidden != null && (t in forbidden)) return false;
		if (!Geo.InMap(t, 2) || !AITile.IsBuildable(t) || AIRoad.IsRoadTile(t) || !::MT.safety.TileOk(t)) return false;
		if (!::MT.nb.TileFree(t)) return false;
		return AITile.GetSlope(t) == AITile.SLOPE_FLAT;
	}

	/*
	 * A plain straight tile of a path without signals, with straight track on both neighbours as well: a switch
	 * there diverges by 45 degrees. Next to a curve it could make a 90 degree turn, which trains may not take.
	 */
	function PlainStraight(path, i) {
		if (i < 2 || i + 2 >= path.len()) return -1;
		for (local k = i - 2; k <= i + 2; k++) if (path[k].kind != PF_KIND_NORMAL) return -1;
		local a = path[i - 1].tile, b = path[i].tile, c = path[i + 1].tile;
		local u = Geo.DirOf(a, b);
		if (u < 0 || u != Geo.DirOf(b, c)) return -1;
		if (Geo.DirOf(path[i - 2].tile, a) != u || Geo.DirOf(c, path[i + 2].tile) != u) return -1;
		if (AIRail.GetSignalType(b, a) != AIRail.SIGNALTYPE_NONE || AIRail.GetSignalType(b, c) != AIRail.SIGNALTYPE_NONE) return -1;
		local tracks = AIRail.GetRailTracks(b);
		if (tracks != AIRail.RAILTRACK_NE_SW && tracks != AIRail.RAILTRACK_NW_SE) return -1;
		return u;
	}

	/* Switch on a departure track: the new line leaves tile path[i] sideways into an empty tile q. */
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

	/* Merge into an arrival track: the new line joins tile path[j] from the side. */
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

	function TerminusStart(site) { return {tile = this.T(site, 0, -3), dir = site.o, opts = null, sw = null}; }
	function TerminusGoal(site) { return {tile = this.T(site, 1, -3), dir = site.din, next = -1, merge = null}; }

	trapped = false;        // the last search found no way out at its start
	trapped_goal = false;   // ... or no way in at its goal
	corridor_note = "";

	/*
	 * The full search runs inside a corridor 3 tiles to each side of a coarse route (CorridorFinder) and is
	 * led along it. Without a coarse route there is no railway, which is known within days instead of
	 * months; both ends are tested first. When the full search gets stuck, the next coarse route keeps two
	 * tiles away from that place: two rounds at most (a failing search is the costliest thing the AI does).
	 */
	function SearchInCorridor(pf, start, start_dir, goal, goal_dir, opts) {
		local from = (opts != null && ("free" in opts) && opts.free) ? start : start + Geo.Offset(start_dir);
		local to = goal - Geo.Offset(goal_dir);
		local cf = CorridorFinder(pf);
		cf.max_nodes = 1500;
		if (cf.Find(from, to, 16) == null) { this.trapped = true; this.corridor_note = "no way out at the start"; return null; }
		if (cf.Find(to, from, 16) == null) { this.trapped_goal = true; this.corridor_note = "no way in at the goal"; return null; }
		local cap = pf.max_nodes, route = null;
		/* Planned alignment between two termini: laid out directly, searched only around obstacles. */
		if (pf.prefer == null && opts != null && !("free" in opts) && !("goal_next" in opts)) {
			local d0 = Util.Today();
			local tp = this.TemplatePath(pf, start, start_dir, goal, goal_dir);
			Log.Debug("DEBUG", "template alignment: " + (tp == null ? "no" : "yes") + ", " + (Util.Today() - d0) + " days");
			if (tp != null) { this.corridor_note = "planned alignment"; return tp; }
		}
		local debug = AIController.GetSetting("debug") == 1;
		/*
		 * The second track of a line is searched along the first one: first within one tile of it, where it may
		 * also take the free half of the first track's diagonal tiles (the two then run as one compact double
		 * line), then in corridors two and four tiles wide.
		 */
		if (this.guide != null) {
			foreach (r in [1, 2, 4]) {
				pf.allowed = cf.Corridor(this.guide, r);
				pf.potential = pf.allowed;
				pf.share = r == 1 ? this.guide_share : null;
				pf.pass_cache = {};
				pf.max_nodes = min(cap, max(6000, 8 * pf.allowed.len()));
				local d0 = Util.Today();
				local path = pf.FindPath(start, start_dir, goal, goal_dir, opts);
				pf.share = null;
				Log.Debug("DEBUG", "search along the first track (" + r + "): " + (path == null ? "none" : "ok") + " in " + pf.expanded + " nodes, " + (Util.Today() - d0) + " days");
				if (path == null && r == 1 && AIController.GetSetting("debug") == 1) {
					local mark = {};
					foreach (t, _ in pf.allowed) if (!(t in this.guide_share)) mark[t] <- ",";
					foreach (t, _ in this.guide_share) mark[t] <- "s";
					mark[start] <- "A";
					mark[goal] <- "B";
					Log.Info("DEBUG", "stuck near " + Util.TileStr(pf.closest) + " (',' corridor, 's' shareable half)");
					Util.DumpRail(pf.closest, 9, pf.forbidden, mark);
				}
				if (path != null) { this.corridor_note = "along the first track"; return path; }
			}
			/* a second track that cannot follow the first one would only add a long search and a stray line */
			this.corridor_note = "no way along the first track";
			pf.allowed = null;
			pf.potential = null;
			return null;
		}
		for (local round = 0; round < 2; round++) {
			pf.allowed = null;
			pf.potential = null;
			pf.pass_cache = {};
			cf.tight = {};
			cf.max_nodes = min(60000, max(15000, 250 * AIMap.DistanceManhattan(from, to)));
			local ops = Util.OpsMark(), d0 = Util.Today();
			route = cf.Find(from, to);
			if (debug) Log.Info("DEBUG", "coarse round " + round + ": " + (route == null ? "none" : route.len() + " tiles") + " in " + cf.expanded +
				" nodes, " + Util.OpsSince(ops) / max(1, cf.expanded) + " ops per node, " + (Util.Today() - d0) + " days");
			if (route == null) {
				this.corridor_note = round == 0 ? "no coarse route (" + cf.expanded + " nodes)" : "no other coarse route after " + round + " tries";
				break;
			}
			/* fares are paid on the straight distance: a line that has to go a long way round neither pays nor looks planned */
			local direct = AIMap.DistanceManhattan(from, to);
			if (route.len() > direct * 8 / 5 + 20) {
				this.corridor_note = "only a detour of " + route.len() + " tiles for " + direct + " tiles of distance";
				break;
			}
			pf.allowed = cf.Corridor(route, 3);
			pf.potential = pf.allowed;
			pf.max_nodes = min(cap, max(6000, (round == 0 ? 8 : 4) * pf.allowed.len()));
			ops = Util.OpsMark();
			local path = pf.FindPath(start, start_dir, goal, goal_dir, opts);
			if (debug) Log.Info("DEBUG", "corridor round " + round + ": " + (path == null ? "none" : "ok") + " in " + pf.expanded + " nodes, " +
				Util.OpsSince(ops) / max(1, pf.expanded) + " ops per node, " + (Util.Today() - d0) + " days");
			if (path != null) return path;
			if (pf.stuck < 0) break;
			local sx = AIMap.GetTileX(pf.stuck), sy = AIMap.GetTileY(pf.stuck);
			for (local y = sy - 2; y <= sy + 2; y++) {
				for (local x = sx - 2; x <= sx + 2; x++) {
					local t = AIMap.GetTileIndex(x, y);
					if (AIMap.DistanceManhattan(t, from) > 3 && AIMap.DistanceManhattan(t, to) > 3) cf.avoid[t] <- true;
				}
			}
			this.corridor_note = "none in " + (round + 1) + " corridors around coarse routes of " + route.len() + " tiles";
		}
		pf.allowed = null;
		pf.potential = null;
		return null;
	}

	/* ---------------- planned alignments ---------------- */

	/* Track piece on a tile entered with step din and left with step dout (-1 for a reversal). */
	function Piece(din, dout) {
		local ein = [0, 3, 2, 1][din];    // edge crossed when entering: NE 0, SE 1, SW 2, NW 3
		local eout = [2, 1, 0, 3][dout];  // edge crossed when leaving
		local a = min(ein, eout), b = max(ein, eout);
		if (a == 0 && b == 2) return AIRail.RAILTRACK_NE_SW;
		if (a == 1 && b == 3) return AIRail.RAILTRACK_NW_SE;
		if (a == 0 && b == 3) return AIRail.RAILTRACK_NW_NE;
		if (a == 1 && b == 2) return AIRail.RAILTRACK_SW_SE;
		if (a == 2 && b == 3) return AIRail.RAILTRACK_NW_SW;
		if (a == 0 && b == 1) return AIRail.RAILTRACK_NE_SE;
		return -1;
	}

	/* The half-tile piece that runs parallel to a corner piece on the same tile (two diagonal tracks side by side). */
	function Complement(track) {
		if (track == AIRail.RAILTRACK_NW_NE) return AIRail.RAILTRACK_SW_SE;
		if (track == AIRail.RAILTRACK_SW_SE) return AIRail.RAILTRACK_NW_NE;
		if (track == AIRail.RAILTRACK_NW_SW) return AIRail.RAILTRACK_NE_SE;
		if (track == AIRail.RAILTRACK_NE_SE) return AIRail.RAILTRACK_NW_SW;
		return -1;
	}

	/*
	 * Steps of the ideal alignment from tile `from` (left with start_dir) to `to` (entered with goal_dir): a
	 * straight run, one 45 degree diagonal (alternating steps), a straight run. When both ends face the same
	 * way, `frac` places the diagonal (0: right after the start, 1: just before the goal); when they are at a
	 * right angle, it sets the share of the diagonal. null when the ends cannot be joined that way.
	 */
	function TemplateMoves(from, start_dir, to, goal_dir, frac) {
		local dx = Geo.X(to) - Geo.X(from), dy = Geo.Y(to) - Geo.Y(from);
		local need = [max(0, dx), max(0, dy), max(0, -dx), max(0, -dy)];   // steps in DIR_PX, DIR_PY, DIR_NX, DIR_NY
		local moves = [];
		if (start_dir == goal_dir) {
			local u = start_dir, v = (u == DIR_PX || u == DIR_NX) ? (dy >= 0 ? DIR_PY : DIR_NY) : (dx >= 0 ? DIR_PX : DIR_NX);
			if (need[Geo.Opp(u)] > 0) return null;
			local major = need[u], minor = need[v];
			local straight = major - minor;
			if (straight < 2) return null;
			local a = Util.Clamp((straight * frac + 0.5).tointeger(), 1, straight - 1);
			for (local i = 0; i < a; i++) moves.append(u);
			for (local i = 0; i < minor; i++) { moves.append(v); moves.append(u); }
			for (local i = a; i < straight; i++) moves.append(u);
			return moves;
		}
		if (goal_dir == Geo.Opp(start_dir)) return null;
		/* at a right angle: a run out of the first station, the diagonal, a run into the second */
		if (need[Geo.Opp(start_dir)] > 0 || need[Geo.Opp(goal_dir)] > 0) return null;
		local ds = need[start_dir], dg = need[goal_dir];
		local most = min(ds, dg) - 1;
		if (most < 1) return null;
		local b = Util.Clamp((most * (0.4 + 0.6 * frac) + 0.5).tointeger(), 1, most);
		for (local i = 0; i < ds - b; i++) moves.append(start_dir);
		for (local i = 0; i < b; i++) { moves.append(goal_dir); moves.append(start_dir); }
		for (local i = 0; i < dg - b; i++) moves.append(goal_dir);
		return moves;
	}

	/*
	 * Does piece (din, dout) fit on tile t for the search `pf`? With `share`, a tile of ours that holds exactly the
	 * parallel half-tile piece (the first track of a double line on a diagonal) fits as well.
	 */
	function Fits(pf, t, din, dout, share) {
		local s = AITile.GetSlope(t);
		if (s != AITile.SLOPE_FLAT && (din != dout || !pf.InclineAlong(s, din))) return false;
		if (pf.Passable(t)) return true;
		if (!share || s != AITile.SLOPE_FLAT || !AIRail.IsRailTile(t) || !Util.IsMine(t)) return false;
		if (AIRail.IsRailStationTile(t) || AIRail.IsRailDepotTile(t) || AIRail.IsLevelCrossingTile(t)) return false;
		local need = this.Piece(din, dout);
		if (need < 0 || AIRail.GetRailTracks(t) != this.Complement(need)) return false;
		for (local d = 0; d < 4; d++) if (AIRail.GetSignalType(t, t + Geo.Offset(d)) != AIRail.SIGNALTYPE_NONE) return false;
		return true;
	}

	/*
	 * Indices of the template tiles that cannot take their piece, grouped into spans (with a margin of three
	 * tiles) that a local search has to route around. [[p, q], ...] with 1 <= p < q <= last index.
	 */
	function Spans(bad, last) {
		local spans = [];
		foreach (k in bad) {
			local p = max(1, k - 3), q = min(last, k + 3);
			if (spans.len() > 0 && p <= spans.top()[1] + 2) spans.top()[1] = max(spans.top()[1], q);
			else spans.append([p, q]);
		}
		return spans;
	}

	/*
	 * Path along the ideal alignment between two termini. Most of the line is laid out directly; where a road,
	 * a river or a hill is in the way, a small search between the template tiles before and after it finds a
	 * bridge, a tunnel or a short detour. Returns [{tile, kind}] or null (then the full searches take over).
	 */
	function TemplatePath(pf, start, start_dir, goal, goal_dir) {
		local tries = [];
		foreach (frac in [0.5, 0.3, 0.7, 0.0, 1.0]) {
			local moves = this.TemplateMoves(start, start_dir, goal, goal_dir, frac);
			if (moves == null) return null;
			local tiles = [start], t = start;
			foreach (m in moves) { t += Geo.Offset(m); tiles.append(t); }
			if (t != goal) return null;
			local bad = [];
			for (local k = 1; k < tiles.len() - 1; k++) if (!this.Fits(pf, tiles[k], moves[k - 1], moves[k], false)) bad.append(k);
			local spans = this.Spans(bad, tiles.len() - 1);
			local cost = 0;
			foreach (s in spans) cost += s[1] - s[0] + 8;
			/*
			 * The second track will be this one moved a tile sideways: an alignment where that twin fits as
			 * well gives a double line that runs side by side all the way. (On a diagonal the twin shares the
			 * template's tiles, each holding one half.)
			 */
			local twin_bad = 0;
			if (this.twin_shift != 0) {
				local on = {};
				foreach (t in tiles) on[t] <- true;
				for (local k = 1; k < tiles.len() - 1; k++) {
					local tt = tiles[k] + this.twin_shift;
					if (!(tt in on) && !this.Fits(pf, tt, moves[k - 1], moves[k], false)) twin_bad++;
				}
			}
			tries.append({tiles = tiles, moves = moves, spans = spans, cost = cost, rank = cost + twin_bad * 2});
			if (bad.len() == 0 && twin_bad <= 4) break;
		}
		tries.sort(function(a, b) { return a.rank - b.rank; });
		foreach (n, tr in tries) {
			if (n >= 3 || tr.cost > tr.tiles.len()) break;   // mostly detours: the full search does better
			local path = this.Repair(pf, tr.tiles, tr.moves, tr.spans, start_dir, null);
			if (path != null) return path;
		}
		return null;
	}

	/*
	 * Lay `tiles` (entered with `moves`) out as a path, replacing each span with the result of a local search.
	 * `kinds` gives bridge and tunnel ends of the template (null: all plain track).
	 */
	function Repair(pf, tiles, moves, spans, start_dir, kinds) {
		local last = tiles.len() - 1;
		local saved_allowed = pf.allowed, saved_pot = pf.potential, saved_nodes = pf.max_nodes;
		local out = [], next = 0, used = {};
		foreach (k, t in tiles) used[t] <- k;
		local ok = true;
		foreach (span in spans) {
			local p = span[0], q = span[1];
			/* a search starts and ends on plain track, never on the far head of a bridge or tunnel */
			if (kinds != null) {
				while (p > 1 && kinds[p] != PF_KIND_NORMAL) p--;
				while (q < last && kinds[q] != PF_KIND_NORMAL) q++;
			}
			if (p < next) { ok = false; break; }
			for (local k = next; k < p; k++) out.append({tile = tiles[k], kind = kinds == null ? PF_KIND_NORMAL : kinds[k]});
			/* the rest of the template, and what earlier repairs laid, is off limits to this search */
			local added = [];
			foreach (t, k in used) {
				if (k >= p && k <= q) continue;
				if (!(t in pf.forbidden)) { pf.forbidden[t] <- true; added.append(t); }
			}
			local pts = [];
			for (local k = p; k <= q; k++) pts.append([Geo.X(tiles[k]), Geo.Y(tiles[k])]);
			local prev = p >= 2 ? moves[p - 2] : start_dir;
			local sub = null;
			/* a narrow search first; a wider and longer one if the obstacle is bigger than it looked */
			foreach (wide in [[5, 5000], [9, 14000]]) {
				pf.allowed = this.Band(pts, wide[0]);
				pf.potential = null;
				pf.max_nodes = wide[1];
				sub = pf.FindPath(tiles[p], moves[p - 1], tiles[q], moves[q - 1],
					{free = true, prev = prev, goal_next = q < last ? moves[q] : -1});
				if (sub != null) break;
			}
			foreach (t in added) delete pf.forbidden[t];
			if (sub == null) { ok = false; break; }
			foreach (e in sub) { out.append(e); used[e.tile] <- -1; }
			next = q + 1;
		}
		pf.allowed = saved_allowed;
		pf.potential = saved_pot;
		pf.max_nodes = saved_nodes;
		pf.pass_cache = {};
		if (!ok) return null;
		for (local k = next; k <= last; k++) out.append({tile = tiles[k], kind = kinds == null ? PF_KIND_NORMAL : kinds[k]});
		/* a repair must not touch the template elsewhere (it would join the track to itself) */
		local seen = {};
		foreach (e in out) {
			if (e.tile in seen) return null;
			seen[e.tile] <- true;
		}
		return out;
	}

	/*
	 * Second track of a double line: the first track moved one tile sideways (the arrival row of each station
	 * is the departure row moved by `shift`) and run the other way. On straight runs the two lie side by side;
	 * on diagonals they share tiles, each holding one half (the compact double diagonal). Bridges and tunnels
	 * get a twin next to them. Where the shifted track does not fit, a local search goes around.
	 */
	function ParallelPath(pf, p1, shift, start, goal) {
		local n = p1.len() - 1;
		local tiles = [], kinds = [];
		for (local j = 0; j <= n; j++) {
			tiles.append(p1[n - j].tile + shift);
			kinds.append(j > 0 ? p1[n - j + 1].kind : PF_KIND_NORMAL);
		}
		if (tiles[0] != start || tiles[n] != goal) return null;
		local moves = [];
		for (local j = 1; j <= n; j++) {
			local d = AIMap.DistanceManhattan(tiles[j - 1], tiles[j]) == 1 ? Geo.DirOf(tiles[j - 1], tiles[j]) : Geo.LineDir(tiles[j - 1], tiles[j]);
			if (d < 0) return null;
			moves.append(d);
		}
		local bad = [];
		for (local k = 1; k < n; k++) {
			local fits;
			if (kinds[k + 1] != PF_KIND_NORMAL) fits = this.TwinJumpFits(pf, tiles[k], tiles[k + 1], kinds[k + 1]);
			else if (kinds[k] != PF_KIND_NORMAL) fits = true;   // far head of a jump, checked with it
			else fits = this.Fits(pf, tiles[k], moves[k - 1], moves[k], true);
			if (!fits) bad.append(k);
		}
		Log.Debug("DEBUG", "parallel track: " + bad.len() + " of " + n + " tiles do not fit" + (bad.len() > 0 ? ", first at " + Util.TileStr(tiles[bad[0]]) : ""));
		if (bad.len() > 0 && AIController.GetSetting("debug") == 1) {
			local mark = {};
			foreach (t in tiles) mark[t] <- "o";
			foreach (k in bad) mark[tiles[k]] <- "X";
			Util.DumpRail(tiles[bad[0]], 9, null, mark);
			local k = bad[0];
			Log.Info("DEBUG", "first bad tile " + Util.TileStr(tiles[k]) + " moves " + moves[k - 1] + "->" + moves[k] + " piece " + this.Piece(moves[k - 1], moves[k]) +
				" tracks there " + AIRail.GetRailTracks(tiles[k]) + " buildable " + AITile.IsBuildable(tiles[k]) + " slope " + AITile.GetSlope(tiles[k]) +
				" forbidden " + (tiles[k] in pf.forbidden) + " kind " + kinds[k]);
		}
		local spans = this.Spans(bad, n);
		if (bad.len() * 5 > n * 2 || spans.len() > max(8, n / 8)) return null;
		return this.Repair(pf, tiles, moves, spans, moves[0], kinds);
	}

	/* Can the twin of a bridge or tunnel go from a to b? */
	function TwinJumpFits(pf, a, b, kind) {
		if ((a in pf.forbidden) || (b in pf.forbidden) || !::MT.nb.TileFree(a) || !::MT.nb.TileFree(b)) return false;
		local tm = AITestMode();
		if (kind == PF_KIND_TUNNEL) return AITunnel.GetOtherTunnelEnd(a) == b && AITunnel.BuildTunnel(AIVehicle.VT_RAIL, a);
		local d = Geo.LineDir(a, b);
		if (d < 0) return false;
		for (local t = a + Geo.Offset(d); t != b; t += Geo.Offset(d)) if (!RailPathFinder.Below(t)) return false;
		local len = AIMap.DistanceManhattan(a, b) + 1;
		local br = this.bridges.For(len, this.line_speed);
		return br >= 0 && AIBridge.BuildBridge(AIVehicle.VT_RAIL, br, a, b);
	}

	/* Tiles within r (Chebyshev) of a polyline. */
	function Band(pts, r) {
		local band = {};
		local mx = AIMap.GetMapSizeX() - 2, my = AIMap.GetMapSizeY() - 2;
		for (local i = 1; i < pts.len(); i++) {
			local p = pts[i - 1], q = pts[i];
			local n = max(1, max(abs(q[0] - p[0]), abs(q[1] - p[1])));
			for (local k = 0; k <= n; k++) {
				local x = p[0] + (q[0] - p[0]) * k / n, y = p[1] + (q[1] - p[1]) * k / n;
				for (local oy = -r; oy <= r; oy++) {
					local yy = y + oy;
					if (yy < 1 || yy > my) continue;
					for (local ox = -r; ox <= r; ox++) {
						local xx = x + ox;
						if (xx >= 1 && xx <= mx) band[AIMap.GetTileIndex(xx, yy)] <- true;
					}
				}
			}
		}
		return band;
	}

	/* Find and build one track between two specs (terminus or junction). Returns the path or null. */
	function BuildTrackSpec(start, goal, forbidden, prefer, railtype) {
		this.trapped = false;
		this.trapped_goal = false;
		local blocked = {};
		foreach (t, v in forbidden) blocked[t] <- v;
		for (local attempt = 0; attempt < 3; attempt++) {
			local pf = RailPathFinder(this.bridges);
			pf.speed = this.line_speed;
			pf.max_nodes = min(120000, max(40000, 320 * AIMap.DistanceManhattan(start.tile, goal.tile)));
			if (prefer != null) { pf.prefer = prefer; pf.weight = 1.5; }
			pf.forbidden = blocked;
			if (this.own_free != null) pf.own_free = this.own_free;
			local opts = start.opts == null ? {} : start.opts;
			if (goal.next >= 0) opts.goal_next <- goal.next;
			local t0 = Util.Today();
			local path = this.SearchInCorridor(pf, start.tile, start.dir, goal.tile, goal.dir, opts);
			Log.Info("BUILD", "rail path " + Util.TileStr(start.tile) + " -> " + Util.TileStr(goal.tile) + ": " +
				(path == null ? "none, " + this.corridor_note : path.len() + " tiles, " + this.Turns(path) + " turns") + " (" + pf.expanded + " nodes, " +
				(Util.Today() - t0) + " days)" +
				(start.sw != null ? ", branching off at " + Util.TileStr(start.sw[1]) : "") +
				(goal.merge != null ? ", merging at " + Util.TileStr(goal.merge[1]) : ""));
			if (path == null) return null;
			if (start.sw != null) path.insert(0, {tile = start.sw[1], kind = PF_KIND_NORMAL});
			this.last_trees = 0;
			foreach (p in path) if (AITile.HasTreeOnTile(p.tile)) this.last_trees++;
			AIRail.SetCurrentRailType(railtype);
			local fail = this.BuildPath(path, railtype);
			if (fail < 0) {
				local ok = true;
				if (start.sw != null) {
					local sw = start.sw;
					ok = Util.Retry(function() : (sw) { return AIRail.BuildRail(sw[0], sw[1], sw[2]); });
				}
				if (ok && goal.merge != null) {
					local mg = goal.merge;
					ok = Util.Retry(function() : (mg) { return AIRail.BuildRail(mg[0], mg[1], mg[2]); });
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
			this.ClearPlaceholder(cur);
			if (nk == PF_KIND_BRIDGE || nk == PF_KIND_TUNNEL) this.ClearPlaceholder(next);
			if (nk == PF_KIND_BRIDGE) {
				local len = AIMap.DistanceManhattan(cur, next) + 1;
				local b = this.bridges.For(len, this.line_speed);
				if (b < 0 || !Util.Retry(function() : (b, cur, next) { return AIBridge.BuildBridge(AIVehicle.VT_RAIL, b, cur, next); })) return i;
				continue;
			}
			if (nk == PF_KIND_TUNNEL) {
				if (!Util.Retry(function() : (cur) { return AITunnel.BuildTunnel(AIVehicle.VT_RAIL, cur); })) return i;
				continue;
			}
			if (ck == PF_KIND_BRIDGE || ck == PF_KIND_TUNNEL) continue;
			if (!Util.Retry(function() : (prev, cur, next) { return AIRail.BuildRail(prev, cur, next); })) {
				if (AIError.GetLastError() == AIError.ERR_ALREADY_BUILT && AIRail.AreTilesConnected(prev, cur, next)) continue;
				return i;
			}
		}
		return -1;
	}

	/*
	 * Remove the part of a path that was built before index `upto` (exclusive), keeping the end tiles. A tile
	 * that also carries the other track of the line (a shared diagonal) only loses this path's piece.
	 */
	function RemovePath(path, upto) {
		for (local i = 1; i < upto && i < path.len() - 1; i++) {
			local t = path[i].tile;
			if (AIRail.IsRailStationTile(t) || AIRail.IsRailDepotTile(t) || !Util.IsMine(t)) continue;
			if (path[i].kind == PF_KIND_NORMAL && path[i + 1].kind == PF_KIND_NORMAL && AIRail.IsRailTile(t) &&
					AIMap.DistanceManhattan(path[i - 1].tile, t) == 1 && AIMap.DistanceManhattan(t, path[i + 1].tile) == 1) {
				local piece = this.Piece(Geo.DirOf(path[i - 1].tile, t), Geo.DirOf(t, path[i + 1].tile));
				if (piece >= 0 && AIRail.GetRailTracks(t) != piece && (AIRail.GetRailTracks(t) & piece) != 0) {
					AIRail.RemoveRailTrack(t, piece);
					continue;
				}
			}
			if (AIRail.IsRailTile(t) || AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) AITile.DemolishTile(t);
		}
	}

	/* Build a path that is already planned (the second track); on failure it is removed again. */
	function BuildGivenPath(path, railtype) {
		this.last_trees = 0;
		foreach (p in path) if (AITile.HasTreeOnTile(p.tile)) this.last_trees++;
		local fail = this.BuildPath(path, railtype);
		if (fail < 0 && this.Verify(path) < 0) return path;
		Log.Warn("BUILD", "planned track failed at " + (fail >= 0 ? Util.TileStr(path[fail].tile) + ": " + AIError.GetLastErrorString() : "verification"));
		this.RemovePath(path, fail >= 0 ? fail : path.len() - 1);
		return null;
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

	/* The free half of every diagonal tile of a built track (flat, one corner piece, no signal). */
	function ShareTable(path) {
		local out = {};
		for (local i = 1; i + 1 < path.len(); i++) {
			local t = path[i].tile;
			if (path[i].kind != PF_KIND_NORMAL || path[i + 1].kind != PF_KIND_NORMAL) continue;
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || !AIRail.IsRailTile(t)) continue;
			local c = this.Complement(AIRail.GetRailTracks(t));
			if (c < 0) continue;
			local signal = false;
			for (local d = 0; d < 4; d++) if (AIRail.GetSignalType(t, t + Geo.Offset(d)) != AIRail.SIGNALTYPE_NONE) signal = true;
			if (!signal) out[t] <- c;
		}
		return out;
	}

	/* Tiles the second track of a line will need: the first track moved sideways, less what they share. */
	function TwinTiles(p1, shift) {
		local on = {}, out = [];
		foreach (p in p1) on[p.tile] <- true;
		foreach (t in this.PathTiles(p1)) if (!((t + shift) in on)) out.append(t + shift);
		return out;
	}

	/* 45 degree direction changes along a path (the looks report: fewer is calmer). */
	function Turns(path) {
		local n = 0, prev8 = -1;
		for (local i = 1; i + 1 < path.len(); i++) {
			local a = path[i - 1].tile, b = path[i].tile, c = path[i + 1].tile;
			local din = Geo.DirOf(a, b), dout = Geo.DirOf(b, c);
			if (din < 0) din = Geo.LineDir(a, b);
			if (dout < 0) dout = Geo.LineDir(b, c);
			if (din < 0 || dout < 0) continue;
			local d8 = Geo.Dir8(din, dout);
			if (d8 < 0) continue;
			if (prev8 >= 0) n += Geo.Turn8(prev8, d8);
			prev8 = d8;
		}
		return n;
	}

	/* Straight-tile equivalents along a path (diagonal pieces count 2/3). */
	function PathLength(path) {
		local len = 0.0;
		for (local i = 1; i < path.len(); i++) {
			local a = path[i - 1].tile, b = path[i].tile;
			local dist = AIMap.DistanceManhattan(a, b);
			if (dist > 1) { len += dist; continue; }
			if (i + 1 < path.len() && Geo.DirOf(a, b) != Geo.DirOf(b, path[i + 1].tile) && path[i + 1].kind == PF_KIND_NORMAL) len += 2.0 / 3.0;
			else len += 1.0;
		}
		return len;
	}

	/* Can a one-way signal go on path[i], facing the way the path runs? */
	function SignalSpot(path, i) {
		if (i < 2 || i >= path.len() - 2) return false;
		if (path[i].kind != PF_KIND_NORMAL || path[i + 1].kind != PF_KIND_NORMAL) return false;
		if (AIMap.DistanceManhattan(path[i - 1].tile, path[i].tile) != 1) return false;
		if (path[i - 1].kind != PF_KIND_NORMAL) return false;   // right behind a bridge or tunnel
		return Geo.DirOf(path[i - 1].tile, path[i].tile) == Geo.DirOf(path[i].tile, path[i + 1].tile);
	}

	/* One-way PBS signals every SIGNAL_SPACING tiles on straight pieces. Returns the signal count. */
	function SignalPath(path, railtype) {
		AIRail.SetCurrentRailType(railtype);
		local count = 0, since = 0;
		for (local i = 2; i < path.len() - 2; i++) {
			since++;
			if (since < SIGNAL_SPACING || !this.SignalSpot(path, i)) continue;
			if (AIRail.BuildSignal(path[i].tile, path[i - 1].tile, AIRail.SIGNALTYPE_PBS_ONEWAY)) {
				count++;
				since = 0;
			}
		}
		return count;
	}

	/*
	 * Signals for both tracks of a double line, side by side: every signal on the first track gets a partner on
	 * the second track where it runs alongside (the neighbouring tile of the parallel track), and the rest of
	 * the second track is signalled at the usual spacing. Returns [signals on p1, signals on p2].
	 */
	function SignalPair(p1, p2, railtype) {
		AIRail.SetCurrentRailType(railtype);
		local n1 = this.SignalPath(p1, railtype);
		local index2 = {};
		for (local i = 0; i < p2.len(); i++) index2[p2[i].tile] <- i;
		local placed = {};
		for (local i = 2; i < p1.len() - 2; i++) {
			local t = p1[i].tile;
			if (AIRail.GetSignalType(t, p1[i - 1].tile) == AIRail.SIGNALTYPE_NONE) continue;
			for (local d = 0; d < 4; d++) {
				local q = t + Geo.Offset(d);
				if (!(q in index2)) continue;
				local j = index2[q];
				if (!this.SignalSpot(p2, j)) continue;
				if (AIRail.BuildSignal(q, p2[j - 1].tile, AIRail.SIGNALTYPE_PBS_ONEWAY)) placed[j] <- true;
				break;
			}
		}
		local count = 0, since = 0;
		for (local i = 2; i < p2.len() - 2; i++) {
			since++;
			if (i in placed) { count++; since = 0; continue; }
			if (since < SIGNAL_SPACING + 2 || !this.SignalSpot(p2, i)) continue;
			if (AIRail.BuildSignal(p2[i].tile, p2[i - 1].tile, AIRail.SIGNALTYPE_PBS_ONEWAY)) { count++; since = 0; }
		}
		return [n1, count];
	}

	/*
	 * Share of the second track's tiles that lie right next to the first track or share a tile with it (a
	 * diagonal pair), for the looks report.
	 */
	function ParallelShare(p1, p2) {
		local t1 = {};
		foreach (p in p1) t1[p.tile] <- true;
		local near = 0;
		foreach (p in p2) {
			if (p.tile in t1) { near++; continue; }
			for (local d = 0; d < 4; d++) if ((p.tile + Geo.Offset(d)) in t1) { near++; break; }
		}
		return p2.len() == 0 ? 0 : 100 * near / p2.len();
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

	function Encode(path) {
		local out = [];
		foreach (p in path) out.append(p.tile * 4 + p.kind);
		return out;
	}

	function Decode(enc) {
		local out = [];
		foreach (e in enc) out.append({tile = e / 4, kind = e % 4});
		return out;
	}

	/*
	 * Remove what we built on these tiles. Rail station tiles are removed one by one: demolishing a single
	 * platform tile removes every platform of that station, and a terminal may be joined to a hub station that
	 * holds the platforms of other routes.
	 */
	function Demolish(tiles) {
		foreach (t in tiles) {
			if (!Util.IsMine(t)) continue;
			if (AIRail.IsRailStationTile(t)) AIRail.RemoveRailStationTileRectangle(t, t, false);
			else if (AIRail.IsRailTile(t) || AIRail.IsRailDepotTile(t) || AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) AITile.DemolishTile(t);
		}
	}
}
