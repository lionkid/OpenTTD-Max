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
			AITile.GetOwner(t) == AICompany.ResolveCompanyID(AICompany.COMPANY_SELF) && AIRail.GetRailTracks(t) == track;
	}

	/* Placeholders at the station ends of these sites, for the searches that follow. */
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
			/* the other row's track never reaches this edge; a track outside might, and would be joined */
			if (AIRail.IsRailTile(t + out)) continue;
			AIRail.BuildRailTrack(t, track);
		}
	}

	function FreeCorridor(site, row) {
		local track = this.CrossTrack(site);
		foreach (t in this.OtherCorridor(site, row)) if (this.IsPlaceholder(t, track)) AIRail.RemoveRailTrack(t, track);
	}

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

	/*
	 * Is there open land beyond tile t? Depth-first over tiles a track could use, away from `blocked`; `need`
	 * tiles reached are enough. A throat that opens into a pocket between houses and roads fails this, and a
	 * path search toward it would only exhaust its node budget.
	 */
	function OpenAround(t, blocked, need, info = null) {
		if (info != null ? !(t in info) : !this.Open(t)) return false;
		local seen = {}, stack = [t], n = 0;
		local offs = [1, Geo.MX, -1, -Geo.MX];
		seen[t] <- true;
		while (stack.len() > 0 && n < need) {
			local c = stack.pop();
			n++;
			for (local d = 0; d < 4; d++) {
				local x = c + offs[d];
				if (x in seen) continue;
				seen[x] <- true;
				if (x in blocked) continue;
				/* the site scan already holds every free, gently sloped tile of the square (no game calls here) */
				if (info != null ? (x in info) : this.Open(x)) stack.append(x);
			}
		}
		return n >= need;
	}

	/*
	 * Can a railway leave both rows of the throat? A short search from each throat end must get ten tiles away,
	 * with the curves and slopes a real track needs (the arrival row is the same test run backwards).
	 */
	function CanLeave(site, blocked) {
		foreach (row in [0, 1]) {
			local other = this.T(site, 1 - row, -5), own = this.T(site, row, -4);
			local was_other = other in blocked, was_own = own in blocked;
			blocked[other] <- true;
			if (was_own) delete blocked[own];
			local guide = this.T(site, row, -16);
			if (!AIMap.IsValidTile(guide)) guide = own;
			local pf = RailPathFinder(this.bridges);
			pf.max_nodes = 150;   // ten tiles out takes a few dozen nodes in open country; a site that needs more is a pocket
			pf.forbidden = blocked;
			local path = pf.FindPath(this.T(site, row, -3), site.o, guide, site.o, {escape = 10});
			if (!was_other) delete blocked[other];
			if (was_own) blocked[own] <- true;
			if (path == null) return false;
		}
		return true;
	}

	function Open(t) {
		if (!Geo.InMap(t, 2) || !AITile.IsBuildable(t) || AIRoad.IsRoadTile(t) || !::TY.safety.TileOk(t)) return false;
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
	 * Station site for a town end: the throat faces `toward` (or a perpendicular direction if needed), the
	 * platforms cover enough of the town's houses (passengers: 30% of what the centre would see; a town cargo:
	 * acceptance 8). A built-up town may have no room near its centre: then the search widens by 8 tiles and
	 * accepts half the catchment.
	 */
	function FindSite(town, toward, L, railtype, join_sid, reserved, cargo = -1) {
		if (cargo < 0) cargo = Util.pax;
		local r = 10 + min(12, (AITown.GetPopulation(town) / 400).tointeger());
		local target = {center = AITown.GetLocation(town), cargo = cargo, kind = cargo == Util.pax ? "pax" : "accept", town = town};
		local site = this.FindSiteR(target, toward, L, railtype, join_sid, reserved, r, 30);
		if (site == null) site = this.FindSiteR(target, toward, L, railtype, join_sid, reserved, r + 8, 15);
		return site;
	}

	/* Station site at an industry: the platforms must lie in the industry's catchment (production or acceptance). */
	function FindIndustrySite(ind, cargo, producing, toward, L, railtype, join_sid, reserved) {
		local target = {center = AIIndustry.GetLocation(ind), cargo = cargo, kind = producing ? "produce" : "accept",
			town = AITile.GetClosestTown(AIIndustry.GetLocation(ind)), ind = ind};
		local site = this.FindSiteR(target, toward, L, railtype, join_sid, reserved, 9, 0);
		if (site == null) site = this.FindSiteR(target, toward, L, railtype, join_sid, reserved, 14, 0);
		return site;
	}

	/* Does a station rectangle at `tl` reach the target (catchment radius 4 for rail)? */
	function Reaches(target, tl, w, h) {
		if (target.kind == "pax") return AITile.GetCargoAcceptance(tl, target.cargo, w, h, 4);
		if (target.kind == "accept") return AITile.GetCargoAcceptance(tl, target.cargo, w, h, 4) >= 8 ? 100 : 0;
		/* producing: the industry must be inside the catchment of the platforms */
		local list = AITileList_IndustryProducing(target.ind, 4);
		local x0 = Geo.X(tl), y0 = Geo.Y(tl);
		for (local x = x0; x < x0 + w; x++) {
			for (local y = y0; y < y0 + h; y++) if (list.HasItem(AIMap.GetTileIndex(x, y))) return 100;
		}
		return 0;
	}

	/*
	 * Free, gently sloped tiles around a centre with their heights, tile -> [min, max]. Scanning a 60x60 square
	 * costs a few game days, and one attempt asks for the same square up to four times (two radii, two platform
	 * lengths), so the scan is kept for a month; tiles reserved by the other terminal are left out on use.
	 */
	site_info = null;

	function SiteInfo(center, reach) {
		local c = this.site_info;
		if (c != null && c.center == center && c.reach >= reach && Util.Today() - c.date < 30) return c.info;
		local cx = Geo.X(center), cy = Geo.Y(center);
		local x0 = max(3, cx - reach), y0 = max(3, cy - reach);
		local x1 = min(AIMap.GetMapSizeX() - 4, cx + reach), y1 = min(AIMap.GetMapSizeY() - 4, cy + reach);
		/* valuators run in the game, one call for the whole square; the script loops only read the values */
		local info = {};
		local list = AITileList();
		list.AddRectangle(AIMap.GetTileIndex(x0, y0), AIMap.GetTileIndex(x1, y1));
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		list.Valuate(AIRoad.IsRoadTile);
		list.KeepValue(0);
		list.Valuate(AIRail.IsLevelCrossingTile);
		list.KeepValue(0);
		list.Valuate(AITile.GetMinHeight);
		list.RemoveValue(0);                      // sea level: flood risk
		local lo = {};
		foreach (t, h in list) lo[t] <- h;
		list.Valuate(AITile.GetSlope);
		local danger = ::TY.safety.danger_tiles;
		foreach (t, sl in list) {
			/* a buildable tile has no half-tile foundation; a steep slope has bit 4 set; a gentle one rises by one level */
			if ((sl & AITile.SLOPE_STEEP) != 0 || (t in danger)) continue;
			local h = lo[t];
			info[t] <- [h, sl == AITile.SLOPE_FLAT ? h : h + 1];
		}
		this.site_info = {center = center, reach = reach, date = Util.Today(), info = info};
		return info;
	}

	function FindSiteR(target, toward, L, railtype, join_sid, reserved, r, acc_pct) {
		local center = target.center;
		local info = this.SiteInfo(center, r + 8 + L);   // the widened search of FindSite reuses the same scan
		if (reserved != null) {
			local trimmed = {};
			foreach (t, h in info) if (!(t in reserved)) trimmed[t] <- h;
			info = trimmed;
		}
		local o_pref = Geo.Towards(center, toward);
		/* trees cost rating only inside a town's local authority zone (economy.dist_local_authority, 20 tiles) */
		local authority = AITile.GetTownAuthority(center);
		local trees_ok = AITown.IsValidTown(authority) ? Util.TreeAllowance(authority) : 99;
		local ref = target.kind == "pax" ? AITile.GetCargoAcceptance(center, target.cargo, 2, L, 4) : 100;
		local min_acc = target.kind == "pax" ? max(8, ref * acc_pct / 100) : 1;
		local walk = max(3, ::TY.game.station_spread - 2);
		local scored = [];
		local why = {footprint = 0, exit = 0, ring = 0, trees = 0, reach = 0, open = 0, leave = 0, build = 0};
		foreach (o in [o_pref, Geo.Left(o_pref), Geo.Right(o_pref), Geo.Opp(o_pref)]) {
			foreach (t, hh in info) {
				local dc = AIMap.DistanceManhattan(t, center);
				if (dc > r + (target.kind == "pax" ? 0 : 4) || (t in this.bad_sites)) continue;
				/* the footprint, tile by tile with an early exit (building the whole list first cost most of the search) */
				local din = Geo.Opp(o), o_in = Geo.Offset(din), o_lat = Geo.Offset(Geo.Right(o));
				local good = true, lo = 1000, hi = -1;
				for (local k = -4; k <= L && good; k++) {
					for (local row = 0; row < 2; row++) {
						local ft = t + k * o_in + row * o_lat;
						if (!(ft in info)) { good = false; break; }
						local h = info[ft];
						if (h[0] < lo) lo = h[0];
						if (h[1] > hi) hi = h[1];
						if (hi - lo > 1) { good = false; break; }
					}
				}
				if (!good) { why.footprint++; continue; }
				local site = this.MakeSite(target.town, t, o, L, railtype);
				/* the line leaves the throat straight: the first tile outside must be free as well */
				foreach (row in [0, 1]) {
					local ex = this.T(site, row, -5);
					if (!AITile.IsBuildable(ex) || AIRoad.IsRoadTile(ex) || !::TY.safety.TileOk(ex) || (reserved != null && (ex in reserved))) good = false;
				}
				if (!good) { why.exit++; continue; }
				local flat = hi == lo;
				if (!flat) {
					foreach (rt in this.Ring(site)) {
						if (!AITile.IsBuildable(rt) || AIRoad.IsRoadTile(rt) || ::TY.safety.IsFloodRisk(rt)) { good = false; break; }
					}
					if (!good) { why.ring++; continue; }
				}
				local trees = 0;
				foreach (ft in this.Footprint(site)) if (AITile.HasTreeOnTile(ft)) trees++;
				if (trees > trees_ok) { why.trees++; continue; }
				local wh = this.StationWH(site);
				local acc = this.Reaches(target, this.TopLeft(site), wh[0], wh[1]);
				if (acc < min_acc && (target.kind != "pax" || dc > walk)) { why.reach++; continue; }
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
			if (++tries > 10) break;
			local site = sc[1];
			local blocked = {};
			foreach (ft in this.Footprint(site)) blocked[ft] <- true;
			if (reserved != null) foreach (ft, _ in reserved) blocked[ft] <- true;
			local open = true;
			foreach (row in [0, 1]) {
				local other = this.T(site, 1 - row, -5);
				blocked[other] <- true;
				if (!this.OpenAround(this.T(site, row, -5), blocked, 80, info)) open = false;
				delete blocked[other];
			}
			if (!open) { why.open++; continue; }
			if (!this.CanLeave(site, blocked)) { why.leave++; continue; }
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
			why.build++;
		}
		local near = 0;
		foreach (t, hh in info) if (AIMap.DistanceManhattan(t, center) <= r) near++;
		Log.Info("PLAN", "rail site search at " + Util.TileStr(center) + " (" + target.kind + " " + Util.CargoName(target.cargo) + ", r " + r + "): " +
			near + " free tiles in range, " + scored.len() + " footprints, none buildable (rejected: footprint " + why.footprint + ", exit " + why.exit +
			", ring " + why.ring + ", trees " + why.trees + ", reach " + why.reach + ", pocket " + why.open + ", no way out " + why.leave + ", build " + why.build + ")");
		return null;
	}

	function IsLevel(site) {
		local h = -1;
		foreach (t in this.Footprint(site)) {
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT || ::TY.safety.IsFloodRisk(t)) return false;
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
		if (err == AIError.ERR_LOCAL_AUTHORITY_REFUSES && town >= 0) ::TY.planner.OnRefused(town);
		return false;
	}

	/* Station, throat (both crossovers) and depot. Sets site.sid and site.depot. Trees cut inside a town's
	 * authority zone cost 35 rating points each; the same number is planted again around the town afterwards. */
	function BuildStation(site, join_sid) {
		AIRail.SetCurrentRailType(site.railtype);
		local trees = 0;
		foreach (ft in this.Footprint(site)) if (AITile.HasTreeOnTile(ft)) trees++;
		local authority = AITile.GetTownAuthority(site.O);
		local ok = this._BuildStation(site, join_sid);
		if (ok && trees > 0 && AITown.IsValidTown(authority)) Util.PlantTrees(authority, trees * 5);
		return ok;
	}

	function _BuildStation(site, join_sid) {
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
		this.trapped_goal = false;
		local ends = this.Ends(from_site, to_site);
		local blocked = {};
		foreach (t, v in forbidden) blocked[t] <- v;
		for (local attempt = 0; attempt < 3; attempt++) {
			local pf = RailPathFinder(this.bridges);
			pf.max_nodes = (min(120000, max(40000, 320 * AIMap.DistanceManhattan(ends.start, ends.goal))) * ::TY.levels.search_scale).tointeger();
			if (prefer != null) pf.weight = 1.5;
			pf.forbidden = blocked;
			if (this.own_free != null) pf.own_free = this.own_free;
			if (prefer != null) pf.prefer = prefer;
			local t0 = Util.Today();
			local path = this.SearchInCorridor(pf, ends.start, ends.start_dir, ends.goal, ends.goal_dir, null);
			Log.Info("BUILD", "rail path " + Util.TileStr(ends.start) + " -> " + Util.TileStr(ends.goal) + ": " +
				(path == null ? "none, " + this.corridor_note : path.len() + " tiles") + " (" + pf.expanded + " nodes, " +
				(Util.Today() - t0) + " days)");
			if (path == null) {
				if (AIController.GetSetting("debug") == 1) Util.DumpRail(ends.goal, 10, blocked);
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
		local p1 = ::TY.planner.Decode(line.p1), p2 = ::TY.planner.Decode(line.p2);
		return end == 0 ? {dep = p1, arr = p2} : {dep = p2, arr = p1};
	}

	function FreeForTrack(t, forbidden) {
		if (forbidden != null && (t in forbidden)) return false;
		if (!Geo.InMap(t, 2) || !AITile.IsBuildable(t) || AIRoad.IsRoadTile(t) || !::TY.safety.TileOk(t)) return false;
		local sl = AITile.GetSlope(t);
		return sl == AITile.SLOPE_FLAT;
	}

	/*
	 * A plain straight tile of a path without signals, with straight track on both neighbours as well: a switch
	 * there diverges by 45 degrees. Next to a curve it could make a 90 degree turn, which trains may not take
	 * (pf.forbid_90_deg), so the new line would be unreachable and its trains lost.
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
	trapped = false;        // the last search found no way out at its start
	trapped_goal = false;   // ... or no way in at its goal
	corridor_note = "";

	/*
	 * The full search runs inside a corridor 3 tiles to each side of a coarse route (CorridorFinder) and is
	 * led along it. Without a coarse route there is no railway, which is known within days instead of
	 * months; both ends are tested first, so a pocket between houses, roads and water fails in a few hundred
	 * nodes. When the full search gets stuck (a turn or a bridge the coarse route could not foresee), the
	 * next coarse route keeps two tiles away from that place: three rounds at most.
	 */
	function SearchInCorridor(pf, start, start_dir, goal, goal_dir, opts) {
		local from = (opts != null && ("free" in opts) && opts.free) ? start : start + Geo.Offset(start_dir);
		local to = goal - Geo.Offset(goal_dir);
		local cf = CorridorFinder(pf);
		cf.max_nodes = 1500;
		if (cf.Find(from, to, 16) == null) { this.trapped = true; this.corridor_note = "no way out at the start"; return null; }
		if (cf.Find(to, from, 16) == null) { this.trapped_goal = true; this.corridor_note = "no way in at the goal"; return null; }
		local debug = AIController.GetSetting("debug") == 1;
		local cap = pf.max_nodes, route = null;
		/*
		 * Budgets: the script expands about a thousand nodes a game day at the default AI speed, and a search that
		 * has not found the goal after a few times the corridor's length is blocked, not slow. A failed long
		 * search once took a year; with these caps the whole thing stays within a few weeks.
		 */
		local started = Util.Today(), days_max = (20 * ::TY.levels.search_scale).tointeger();
		for (local round = 0; round < ::TY.levels.reroute_rounds; round++) {
			if (round > 0 && Util.Today() - started > days_max) { this.corridor_note = "search budget of " + days_max + " days spent"; break; }
			/* the coarse search sees the whole map again (the last full search cached passability in its corridor) */
			pf.allowed = null;
			pf.potential = null;
			pf.pass_cache = {};
			cf.tight = {};
			cf.max_nodes = (min(8000, max(3000, 40 * AIMap.DistanceManhattan(from, to))) * ::TY.levels.search_scale).tointeger();
			local ops = Util.OpsMark();
			route = cf.Find(from, to);
			if (debug) Log.Info("DEBUG", "coarse search: " + cf.expanded + " nodes, " + Util.OpsSince(ops) / max(1, cf.expanded) + " ops per node");
			if (route == null) {
				this.corridor_note = round == 0 ? "no coarse route (" + cf.expanded + " nodes)" : "no other coarse route after " + round + " tries";
				break;
			}
			pf.allowed = cf.Corridor(route, 3);
			pf.potential = pf.allowed;
			pf.max_nodes = min(cap, min(6000, max(2500, (round == 0 ? 3 : 2) * pf.allowed.len())));
			ops = Util.OpsMark();
			local path = pf.FindPath(start, start_dir, goal, goal_dir, opts);
			if (debug) {
				local st = pf.stats;
				Log.Info("DEBUG", "rail search in a corridor of " + pf.allowed.len() + " tiles: " + pf.expanded + " nodes, " +
					Util.OpsSince(ops) / max(1, pf.expanded) + " ops per node" + (path == null ? ", stuck at " + Util.TileStr(pf.stuck) : "") +
					" [passable " + st.passable + ", terrain " + st.terrain + ", bridge calls " + st.bridge_calls + ", bridge steps " + st.bridge_steps +
					", bridge tests " + st.bridge_tests + ", tunnels " + st.tunnel_calls + ", housekeeping " + st.housekeeping + "]");
			}
			if (path != null) return path;
			if (pf.stuck < 0) break;
			if (debug) {
				local mark = {};
				foreach (t in route) mark[t] <- "o";
				mark[pf.stuck] <- "@";
				Util.DumpRail(pf.stuck, 10, pf.forbidden, mark);
			}
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

	function BuildTrackSpec(start, goal, forbidden, prefer, railtype) {
		this.trapped = false;
		this.trapped_goal = false;
		local blocked = {};
		foreach (t, v in forbidden) blocked[t] <- v;
		for (local attempt = 0; attempt < 3; attempt++) {
			local pf = RailPathFinder(this.bridges);
			pf.max_nodes = (min(120000, max(40000, 320 * AIMap.DistanceManhattan(start.tile, goal.tile))) * ::TY.levels.search_scale).tointeger();
			if (prefer != null) { pf.prefer = prefer; pf.weight = 1.5; }
			pf.forbidden = blocked;
			if (this.own_free != null) pf.own_free = this.own_free;
			local opts = start.opts == null ? {} : start.opts;
			if (goal.next >= 0) opts.goal_next <- goal.next;
			local t0 = Util.Today();
			local path = this.SearchInCorridor(pf, start.tile, start.dir, goal.tile, goal.dir, opts);
			Log.Info("BUILD", "rail path " + Util.TileStr(start.tile) + " -> " + Util.TileStr(goal.tile) + ": " +
				(path == null ? "none, " + this.corridor_note : path.len() + " tiles") + " (" + pf.expanded + " nodes, " +
				(Util.Today() - t0) + " days)" +
				(start.sw != null ? ", branching off at " + Util.TileStr(start.sw[1]) : "") +
				(goal.merge != null ? ", merging at " + Util.TileStr(goal.merge[1]) : ""));
			if (path == null) return null;
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
			if (i % 40 == 0) TY_Housekeeping();
			local cur = path[i].tile, prev = path[i - 1].tile, next = path[i + 1].tile;
			local nk = path[i + 1].kind, ck = path[i].kind;
			this.ClearPlaceholder(cur);
			if (nk == PF_KIND_BRIDGE || nk == PF_KIND_TUNNEL) this.ClearPlaceholder(next);
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
				if (!::TY.finance.Ensure(20000)) return false;
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
