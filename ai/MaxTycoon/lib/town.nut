/*
 * TownCare: makes the towns we serve grow fast and keeps them tidy.
 *
 * OpenTTD 15.3 town_cmd.cpp:
 *   - growth rate: a town builds a house (or a road piece) every (m + 1) * 70 ticks, where m comes from the
 *     number of stations within its zone that loaded or unloaded in the last 50 days: 420 with one station,
 *     300 / 220 / 160 with two to four and 100 with five or more (halved per town growth speed step, halved
 *     again for cities, divided by houses/50 + 1). Funding new buildings (3 months) uses 120 / 100 / 80 / 60,
 *     and lets an arctic or desert town grow without its food and water;
 *   - the stations may belong to anyone; what counts is the station sign tile inside the town zone
 *     (AITown.IsWithinTownInfluence) and a vehicle that loaded or unloaded there;
 *   - above the snow line a town over 90 people needs food every month to grow, a desert town over 60 needs
 *     food and water (delivered to any station whose nearest town it is);
 *   - houses are built next to roads of any owner and the town extends roads of any owner, so a road grid
 *     laid out in advance (on the town's own grid lines: x and y congruent to the centre modulo 3 for the
 *     2x2 layout and modulo 4 for the 3x3 layout) is filled with houses in straight blocks;
 *   - a statue adds 26 to the rating of every station of ours in the town for good; advertising adds 64,
 *     112 or 160 once to the stations within 10, 15 or 20 tiles and the rating drifts back by 2 per 2.5 days.
 * Five served stations are reached with a circle line: separate bus stops around the centre, served by a
 * couple of buses in a loop, each stop its own station.
 */

class TownCare {
	towns = null;        // town -> {loop, loop_try, grid_ring, grid_try, statue, funded, fund_try, ads}
	last_project = -10000;

	constructor() { this.towns = {}; }

	function Rec(town) {
		if (!(town in this.towns)) this.towns[town] <- {loop = -1, loop_try = -10000, grid_ring = 0, grid_try = -10000, funded = 0, ads = 0, grid_tiles = 0};
		return this.towns[town];
	}

	/* Towns we serve with a station: our hubs plus the nearest towns of freight stations. */
	function Served() {
		local out = {};
		foreach (town, hub in ::TY.network.hubs) if (AIStation.IsValidStation(hub.sid)) out[town] <- true;
		return out;
	}

	/* Last year's vehicle profit: town spending follows what the network earns, not what the bank lends. */
	function YearProfit() {
		local total = 0;
		foreach (v, _ in AIVehicleList()) total += AIVehicle.GetProfitLastYear(v);
		return total;
	}

	/* Money the town budget may spend this month: a share of last year's profit, and only cash in hand. */
	function Budget() {
		local cash = ::TY.finance.Cash() - ::TY.finance.Reserve() * 2;
		if (::TY.finance.harvest) cash = min(cash, ::TY.score.SpendingRoom());
		local share = this.YearProfit() * ::TY.levels.town_budget / 2.0;
		/* idle millions do nothing for the score: a fifth of what lies above a million is the towns' too */
		share = fmax(share, (cash - 1000000) * 0.2);
		return fmax(0.0, fmin(cash, share));
	}

	/* ---------------- monthly actions ---------------- */

	function Monthly() {
		if (!::TY.levels.town_care || ::TY.score.phase >= PHASE_HARVEST) return;
		local budget = this.Budget();
		if (::TY.score.phase == PHASE_PREPARE) budget = budget / 4;
		local served = this.Served();
		local spent = 0;
		/* statues first: a permanent rating bonus on every station of the town */
		foreach (town, _ in served) {
			if (!AITown.IsValidTown(town) || AITown.HasStatue(town)) continue;
			if (::TY.levels.iq < 2 || ::TY.network.LinkCount(town) < 2) continue;
			if (!AITown.IsActionAvailable(town, AITown.TOWN_ACTION_BUILD_STATUE)) continue;
			local cost = this.ActionCost(town, AITown.TOWN_ACTION_BUILD_STATUE);
			if (cost < 0 || spent + cost > budget) continue;
			if (AITown.PerformTownAction(town, AITown.TOWN_ACTION_BUILD_STATUE)) {
				spent += cost;
				Log.Info("TOWN", "statue in " + Util.TownName(town) + " (" + Util.Money(cost) + "): +26 rating on every station there");
			}
		}
		/* fund buildings: the towns whose growth brings the most to our stations */
		local cands = AIList();
		foreach (town, _ in served) {
			if (!AITown.IsValidTown(town) || AITown.GetFundBuildingsDuration(town) > 0) continue;
			if (!AITown.IsActionAvailable(town, AITown.TOWN_ACTION_FUND_BUILDINGS)) continue;
			local links = ::TY.network.LinkCount(town);
			if (links == 0) continue;
			cands.AddItem(town, links * 1000 + AITown.GetPopulation(town) / 10);
		}
		local funds = 0;
		foreach (town in Util.TopN(cands, 6)) {
			if (funds >= 2 || ::TY.finance.Cash() < 500000 || AITown.GetPopulation(town) > 5000) break;
			local cost = this.ActionCost(town, AITown.TOWN_ACTION_FUND_BUILDINGS);
			if (cost < 0 || spent + cost > budget) break;
			funds++;
			if (AITown.PerformTownAction(town, AITown.TOWN_ACTION_FUND_BUILDINGS)) {
				spent += cost;
				this.Rec(town).funded++;
				Log.Info("TOWN", "funding new buildings in " + Util.TownName(town) + " (pop " + AITown.GetPopulation(town) + ", " +
					::TY.network.ServedStationsOfTown(town) + " served stations, " + Util.Money(cost) + ")");
			}
		}
		/* advertising where our stations' ratings are low (cheap, one-off bump) */
		if (::TY.levels.iq >= 2) {
			foreach (town, hub in ::TY.network.hubs) {
				if (!AIStation.IsValidStation(hub.sid)) continue;
				local r = ::TY.cdist.Rating(hub.sid, Util.pax);
				if (r < 0 || r >= 60) continue;
				if (!AITown.IsActionAvailable(town, AITown.TOWN_ACTION_ADVERTISE_MEDIUM)) continue;
				local cost = this.ActionCost(town, AITown.TOWN_ACTION_ADVERTISE_MEDIUM);
				if (cost < 0 || spent + cost > budget) continue;
				if (AITown.PerformTownAction(town, AITown.TOWN_ACTION_ADVERTISE_MEDIUM)) {
					spent += cost;
					this.Rec(town).ads++;
				}
			}
		}
	}

	/* Cost of a town action (the game's test mode). */
	function ActionCost(town, action) {
		local cost = -1;
		{
			local tm = AITestMode();
			local acc = AIAccounting();
			if (AITown.PerformTownAction(town, action)) cost = acc.GetCosts();
		}
		return cost;
	}

	/* ---------------- construction projects ---------------- */

	/* One town project per planner step: a circle line to reach five served stations, or a ring of grid roads. */
	function Project() {
		if (!::TY.levels.town_care || !::TY.game.allow[MODE_ROAD] || ::TY.score.phase >= PHASE_HARVEST) return false;
		/* lines first: town projects come one at a time, between line projects, once the network earns */
		if (Util.Today() - this.last_project < 45 || ::TY.network.ActiveCount() < 4) return false;
		if (::TY.network.ActiveCount() >= ::TY.levels.line_cap) return false;
		local worth = this.Budget();
		if (worth < 20000) return false;
		local served = this.Served();
		foreach (town, _ in served) {
			if (!AITown.IsValidTown(town) || ::TY.planner.Refused(town)) continue;
			local rec = this.Rec(town);
			local pop = AITown.GetPopulation(town);
			if (rec.loop < 0 && pop >= 900 && Util.Today() - rec.loop_try > 400 && ::TY.network.ServedStationsOfTown(town) < 5) {
				rec.loop_try = Util.Today();
				this.last_project = Util.Today();
				if (this.BuildLoop(town, rec)) return true;
			}
			if (::TY.levels.grid_roads && pop >= 600 && Util.Today() - rec.grid_try > 365 && worth > 40000) {
				rec.grid_try = Util.Today();
				this.last_project = Util.Today();
				if (this.BuildGrid(town, rec)) return true;
			}
		}
		return false;
	}

	/*
	 * Circle line: up to five separate bus stops around the centre, inside the town zone, at least four tiles
	 * apart, visited in a loop by two buses. Every stop is its own station, so every one of them counts for
	 * the growth rate once a bus has called there.
	 */
	function BuildLoop(town, rec) {
		::TY.road.Use(AIRoad.ROADTYPE_ROAD);
		local center = AITown.GetLocation(town);
		local r = 5 + min(8, AITown.GetPopulation(town) / 500);
		local need = 5 - ::TY.network.ServedStationsOfTown(town);
		local spots = [], avoid = {};
		/* keep away from our existing stations in the town (they count already) */
		foreach (sid, _ in AIStationList(AIStation.STATION_ANY)) {
			local loc = AIStation.GetLocation(sid);
			if (AIStation.GetNearestTown(sid) != town) continue;
			local x = Geo.X(loc), y = Geo.Y(loc);
			for (local dy = -3; dy <= 3; dy++) for (local dx = -3; dx <= 3; dx++) avoid[AIMap.GetTileIndex(x + dx, y + dy)] <- true;
		}
		for (local k = 0; k < need + 1 && spots.len() < need; k++) {
			local spot = ::TY.road.FindStop(center, r, AIStation.STATION_NEW, Util.pax, avoid, -1, 0, town);
			if (spot == null) break;
			spots.append(spot);
			local x = Geo.X(spot.tile), y = Geo.Y(spot.tile);
			for (local dy = -3; dy <= 3; dy++) for (local dx = -3; dx <= 3; dx++) avoid[AIMap.GetTileIndex(x + dx, y + dy)] <- true;
		}
		if (spots.len() < 2) return false;
		/* visiting order: nearest neighbour tour from the first stop */
		local order = [spots[0]], rest = spots.slice(1);
		while (rest.len() > 0) {
			local last = order[order.len() - 1], bi = 0, bd = 1 << 30;
			foreach (i, s in rest) { local d = AIMap.DistanceManhattan(last.tile, s.tile); if (d < bd) { bd = d; bi = i; } }
			order.append(rest[bi]);
			rest.remove(bi);
		}
		local best = ::TY.engines.BestBus(order.len() * 6, 6, 60);
		if (best == null) return false;
		if (!::TY.finance.Ensure(order.len() * AIRoad.GetBuildCost(AIRoad.ROADTYPE_ROAD, AIRoad.BT_BUS_STOP) + 30000)) return false;
		local sids = [], tiles = [];
		foreach (s in order) {
			local sid = ::TY.road.BuildStop(s, AIStation.STATION_NEW);
			if (sid < 0) continue;
			sids.append(sid);
			tiles.append(s.tile);
		}
		if (tiles.len() < 2) { foreach (t in tiles) AIRoad.RemoveRoadStation(t); return false; }
		/* connect consecutive stops (town roads mostly exist already) */
		local path_len = 0;
		for (local i = 0; i < tiles.len(); i++) {
			local a = tiles[i], b = tiles[(i + 1) % tiles.len()];
			local conn = ::TY.road.Connect(a, b);
			if (conn == null || !::TY.road.BuildPath(conn.path)) {
				Log.Info("TOWN", "circle line in " + Util.TownName(town) + ": no road between two stops");
				foreach (t in tiles) AIRoad.RemoveRoadStation(t);
				return false;
			}
			path_len += conn.path.len();
		}
		local depot = ::TY.road.BuildDepotNear(tiles[0]);
		if (depot < 0) { foreach (t in tiles) AIRoad.RemoveRoadStation(t); return false; }
		local line = Line();
		line.mode = MODE_ROAD;
		line.cargo = Util.pax;
		line.roadtype = AIRoad.ROADTYPE_ROAD;
		line.loop = true;
		line.ends = [[END_TOWN, town], [END_TOWN, town]];
		line.towns = [town, town];
		line.sids = [sids[0], sids[sids.len() - 1]];
		line.tiles = [tiles[0], tiles[tiles.len() - 1]];
		line.stops = tiles;
		line.stops_sids = sids;
		line.depots = [depot, -1];
		line.engine = best.engine;
		line.capacity = ::TY.engines.Capacity(best.engine, Util.pax);
		line.speed = AIEngine.GetMaxSpeed(best.engine);
		line.dist = 6;
		line.path_len = path_len;
		line.est_rtt = ::TY.time.OneWay(MODE_ROAD, line.speed, path_len, line.capacity) + (tiles.len() - 1) * ::TY.time.StopDays(MODE_ROAD, line.capacity);
		line.track_tiles = [];
		::TY.network.Add(line);
		rec.loop = line.id;
		local hub = ::TY.network.Hub(town);
		foreach (sid in sids) if (!Util.Contains(hub.stations, sid)) hub.stations.append(sid);
		::TY.fleet.BuildFor(line, 0);
		if (tiles.len() >= 4) ::TY.fleet.BuildFor(line, 1);
		Log.Info("TOWN", line.Name() + " opened: circle line with " + tiles.len() + " stops (" + ::TY.network.ServedStationsOfTown(town) +
			" served stations in " + Util.TownName(town) + " once the buses call), " + AIEngine.GetName(best.engine));
		return true;
	}

	/*
	 * Road grid: the next ring of grid lines around the built-up area, on the town's own grid (spacing 3 for
	 * the 2x2 layout, 4 otherwise), so that growth fills straight blocks. Lines are built as straight pieces
	 * between crossings where the land is free; water, stations and our tracks are skipped.
	 */
	function BuildGrid(town, rec) {
		::TY.road.Use(AIRoad.ROADTYPE_ROAD);
		local center = AITown.GetLocation(town);
		local layout = AITown.GetRoadLayout(town);
		local s = layout == AITown.ROAD_LAYOUT_2x2 ? 3 : 4;
		local houses = AITown.GetHouseCount(town);
		local built_r = (sqrt(houses.tofloat()) * 1.3).tointeger() + 2;
		local ring = max(rec.grid_ring, built_r / s);
		if (ring > 8) return false;
		local cx = Geo.X(center), cy = Geo.Y(center);
		local x0 = cx - (ring + 1) * s, x1 = cx + (ring + 1) * s, y0 = cy - (ring + 1) * s, y1 = cy + (ring + 1) * s;
		if (x0 < 2 || y0 < 2 || x1 >= AIMap.GetMapSizeX() - 2 || y1 >= AIMap.GetMapSizeY() - 2) return false;
		local pieces = 0, segments = 0;
		local budget = min(60000, (this.Budget() / 2).tointeger());
		if (budget < 5000) return false;
		local cost_tile = AIRoad.GetBuildCost(AIRoad.ROADTYPE_ROAD, AIRoad.BT_ROAD);
		/* grid lines parallel to the y axis (constant x) and to the x axis (constant y), the outer ring only */
		for (local gx = x0; gx <= x1; gx += s) {
			for (local gy = y0; gy < y1; gy += s) {
				if (!(gx == x0 || gx == x1 || gy == y0 || gy + s == y1 || gy == y1)) continue;
				if (pieces * cost_tile > budget) break;
				local n = this.GridSegment(AIMap.GetTileIndex(gx, gy), AIMap.GetTileIndex(gx, gy + s), town);
				if (n > 0) { pieces += n; segments++; }
			}
		}
		for (local gy = y0; gy <= y1; gy += s) {
			for (local gx = x0; gx < x1; gx += s) {
				if (!(gy == y0 || gy == y1 || gx == x0 || gx + s == x1 || gx == x1)) continue;
				if (pieces * cost_tile > budget) break;
				local n = this.GridSegment(AIMap.GetTileIndex(gx, gy), AIMap.GetTileIndex(gx + s, gy), town);
				if (n > 0) { pieces += n; segments++; }
			}
		}
		rec.grid_ring = ring + 1;
		rec.grid_tiles += pieces;
		if (pieces > 0) Log.Info("TOWN", "road grid for " + Util.TownName(town) + " (" + ["original", "better roads", "2x2", "3x3"][Util.Clamp(layout, 0, 3)] +
			" layout, spacing " + s + "): ring " + ring + ", " + segments + " segments, " + pieces + " new road pieces");
		return pieces > 0;
	}

	/* One straight grid segment if every tile of it is open land or road; returns new pieces or 0. */
	function GridSegment(a, b, town) {
		local d = Geo.LineDir(a, b);
		if (d < 0) return 0;
		for (local t = a; ; t += Geo.Offset(d)) {
			if (!Geo.InMap(t, 2)) return 0;
			if (AIRoad.IsRoadTile(t)) { if (t == b) break; continue; }
			if (!AITile.IsBuildable(t) || AITile.IsWaterTile(t) || AITile.IsCoastTile(t)) return 0;
			if (AITile.GetSlope(t) != AITile.SLOPE_FLAT && !this.RoadSlopeOk(AITile.GetSlope(t), d)) return 0;
			if (AITile.HasTreeOnTile(t) && Util.TreeAllowance(town) < 3) return 0;
			if (t == b) break;
		}
		local ok;
		{
			local tm = AITestMode();
			ok = AIRoad.BuildRoad(a, b);
		}
		if (!ok && AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) return 0;
		local n = ::TY.road.BuildStraight(a, b);
		return n < 0 ? 0 : n;
	}

	function RoadSlopeOk(slope, d) {
		if (d == DIR_PX || d == DIR_NX) return slope == AITile.SLOPE_NE || slope == AITile.SLOPE_SW;
		return slope == AITile.SLOPE_NW || slope == AITile.SLOPE_SE;
	}

	function Report() {
		local n = 0, five = 0, funded = 0, statues = 0, grids = 0, loops = 0;
		foreach (town, _ in this.Served()) {
			if (!AITown.IsValidTown(town)) continue;
			n++;
			if (::TY.network.ServedStationsOfTown(town) >= 5) five++;
			if (AITown.HasStatue(town)) statues++;
			local rec = this.Rec(town);
			funded += rec.funded;
			grids += rec.grid_tiles;
			if (rec.loop >= 0) loops++;
		}
		return n + " towns served, " + five + " with five or more served stations, " + loops + " circle lines, " + statues + " statues, " +
			funded + " building funds, " + grids + " grid road pieces";
	}

	function Save() { return this.towns; }
	function Load(t) { this.towns = t; }
}
