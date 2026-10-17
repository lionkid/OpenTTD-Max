/*
 * A* pathfinders for new railway, road and shipping lanes.
 *
 * Rules that are part of the search, not a later check:
 *   - no level crossings: road tiles block rail (bridge or tunnel instead) and rail tiles block road;
 *   - no coast or sea-level tiles (flood risk) and no tiles where one of our vehicles crashed;
 *   - courtesy: never inside the buffer around another company's stations, never right next to their rails;
 *   - rail: no 90 degree turns, no diagonal pieces or foundations on slopes.
 * Rail costs are travel time plus looks: a straight tile 30, a diagonal piece 20 (2/3 of the time), +55 per
 * 45 degree turn and +110 more when two turns follow each other (a wiggle is slow, OpenTTD limits a train to
 * 88 km/h when its direction changes twice within one wagon length, and it looks unplanned), +20 per incline,
 * +8 per house next to the track (lines run past towns, not through their back gardens), bridges and tunnels
 * at tile cost plus a construction penalty. The result is long straights joined by single clean curves.
 */

const PF_STRAIGHT = 30;
const PF_DIAG = 20;
const PF_TURN = 55;
const PF_TURN2 = 110;
const PF_SLOPE = 20;
const PF_BRIDGE = 120;
const PF_TUNNEL = 150;
const PF_HOUSE = 8;
const PF_KIND_NORMAL = 0;
const PF_KIND_BRIDGE = 1;
const PF_KIND_TUNNEL = 2;

/*
 * Bridge types: the cheapest type that is fast enough for the line, so a line's bridges share one style and
 * no fast line gets a wooden trestle.
 */
class BridgeCache {
	cache = null;   // "len:speed" -> bridge type or -1
	constructor() { this.cache = {}; }

	function For(len, speed) {
		local key = len + ":" + speed;
		if (key in this.cache) return this.cache[key];
		local best = -1, best_price = -1, fastest = -1, fastest_speed = -1;
		foreach (b, _ in AIBridgeList_Length(len)) {
			local s = AIBridge.GetMaxSpeed(b), p = AIBridge.GetPrice(b, len);
			if (s > fastest_speed) { fastest_speed = s; fastest = b; }
			if (s >= speed && (best < 0 || p < best_price)) { best = b; best_price = p; }
		}
		if (best < 0) best = fastest;
		this.cache[key] <- best;
		return best;
	}

}

class RailPathFinder {
	forbidden = null;      // tile -> true
	allowed = null;        // tile -> true: the corridor the search must stay in (null: anywhere)
	own_free = null;       // tile -> track: our placeholder pieces, free for the new track
	potential = null;      // tile -> cost to go along the coarse route (guides the search around detours)
	prefer = null;         // tile -> true (next to the first track of a double line)
	share = null;          // tile -> the only piece allowed there: the free half of a diagonal tile of the first track
	speed = 160;           // line speed, for the bridge type
	max_nodes = 80000;
	max_bridge = 20;
	max_tunnel = 20;
	weight = 1.3;          // heuristic weight (slightly greedy, much faster)
	expanded = 0;
	closest = -1;          // tile nearest to the goal that the last search reached (diagnostics)
	stuck = -1;            // tile furthest along the coarse route that the last guided search reached
	pass_cache = null;
	terrain_cache = null;
	bridges = null;
	g = null;
	par = null;
	kind = null;
	open = null;

	constructor(bridge_cache) {
		this.forbidden = {};
		this.pass_cache = {};
		this.bridges = bridge_cache;
		this.max_bridge = min(20, ::MT.game.max_bridge_length);
		this.max_tunnel = min(20, ::MT.game.max_tunnel_length);
	}

	function Key(tile, din, dprev, turned = 0) { return (tile << 5) | (turned << 4) | (din << 2) | dprev; }

	function Heuristic(tile, goal) {
		local dx = abs(AIMap.GetTileX(tile) - AIMap.GetTileX(goal)), dy = abs(AIMap.GetTileY(tile) - AIMap.GetTileY(goal));
		local lo = min(dx, dy), hi = max(dx, dy);
		return PF_STRAIGHT * (hi - lo) + 2 * PF_DIAG * lo;
	}

	/* Can a new rail piece go on this tile at all? (cached per search) */
	function Passable(t) {
		if (t in this.pass_cache) return this.pass_cache[t];
		local ok = this._Passable(t);
		this.pass_cache[t] <- ok;
		return ok;
	}

	function _Passable(t) {
		if (this.share != null && (t in this.share) && (this.allowed == null || (t in this.allowed))) return true;
		if (t in this.forbidden) return false;
		if (this.allowed != null && !(t in this.allowed)) return false;
		/* our placeholder piece (flat and safe when it was laid) */
		if (this.own_free != null && (t in this.own_free) && ::MT.rail.IsPlaceholder(t, this.own_free[t])) return true;
		if (!Geo.InMap(t, 2)) return false;
		if (!AITile.IsBuildable(t)) return false;
		if (AIRoad.IsRoadTile(t)) return false;           // never a level crossing
		if (!::MT.safety.TileOk(t)) return false;         // flood risk, crash sites
		local s = AITile.GetSlope(t);
		if (AITile.IsSteepSlope(s) || AITile.IsHalftileSlope(s)) return false;
		if (!::MT.nb.TileFree(t) || ::MT.nb.NextToTheirRail(t)) return false;
		return true;
	}

	/* Incline that a straight piece along axis `d` can climb without a foundation. */
	function InclineAlong(slope, d) {
		if (d == DIR_PX || d == DIR_NX) return slope == AITile.SLOPE_NE || slope == AITile.SLOPE_SW;
		return slope == AITile.SLOPE_NW || slope == AITile.SLOPE_SE;
	}

	function PieceOk(t, din, dout) {
		local s = AITile.GetSlope(t);
		if (s == AITile.SLOPE_FLAT) return true;
		if (din != dout) return false;
		return this.InclineAlong(s, din);
	}

	/* Removing a tree inside a town's local authority zone costs 35 rating points with that town. */
	function TreeCost(t) {
		if (!AITile.HasTreeOnTile(t)) return 0;
		local town = AITile.GetClosestTown(t);
		if (AITown.IsValidTown(town) && AITown.GetDistanceManhattanToTile(town, t) <= 20) return 25;
		return 3;
	}

	function _TerrainCost(t) {
		local c = this.TreeCost(t);
		if (AITile.IsFarmTile(t)) c += 4;
		if (AITile.IsRoughTile(t) || AITile.IsRockTile(t)) c += 3;
		if (AITile.GetSlope(t) != AITile.SLOPE_FLAT) c += PF_SLOPE;
		for (local d = 0; d < 4; d++) if (AITile.IsHouseTile(t + Geo.Offset(d))) c += PF_HOUSE;
		/* the second track of a line hugs the first one */
		if (this.prefer != null) c += (t in this.prefer) ? -6 : 45;
		return c;
	}

	/*
	 * Bridge heads may stand on slopes (rivers and coasts are rarely flat): the ramp or a foundation takes the
	 * slope, and the test build decides. Only the far head has to be a tile the line could use anyway.
	 */
	function TryBridge(key, tile, d, goal) {
		if (!this.HeadSlopeOk(tile)) return;
		local off = Geo.Offset(d);
		for (local len = 2; len <= this.max_bridge; len++) {
			local e = tile + len * off;
			if (!Geo.InMap(e, 2)) return;
			if (!RailPathFinder.Below(e - off)) return;   // the span would demolish a house or a station
			if (e != goal && !this.Passable(e)) continue;
			if (!this.HeadSlopeOk(e)) continue;
			local b = this.bridges.For(len + 1, this.speed);
			if (b < 0) return;
			local ok;
			{
				local tm = AITestMode();
				ok = AIBridge.BuildBridge(AIVehicle.VT_RAIL, b, tile, e);
			}
			if (!ok) continue;
			local ng = this.g[key] + (len + 1) * (PF_STRAIGHT + 6) + PF_BRIDGE;
			this.Relax(this.Key(e, d, d), ng, key, PF_KIND_BRIDGE, goal);
			return;
		}
	}

	/* Can a bridge span tile t without clearing it? (OpenTTD demolishes houses under a new bridge) */
	function Below(t) {
		if (!Geo.InMap(t, 1)) return false;
		if (AITile.IsBuildable(t) || AITile.IsWaterTile(t) || AITile.IsCoastTile(t)) return true;
		if (AIRoad.IsRoadTile(t)) return !AIRoad.IsRoadStationTile(t) && !AIRoad.IsDriveThroughRoadStationTile(t);
		if (AIRail.IsRailTile(t)) return !AIRail.IsRailStationTile(t) && !AIRail.IsRailWaypointTile(t);
		return false;
	}

	function HeadSlopeOk(t) {
		local s = AITile.GetSlope(t);
		return !AITile.IsSteepSlope(s) && !AITile.IsHalftileSlope(s);
	}

	function TryTunnel(key, tile, d, goal) {
		local s = AITile.GetSlope(tile);
		if (!this.InclineAlong(s, d)) return;
		local other = AITunnel.GetOtherTunnelEnd(tile);
		if (!AIMap.IsValidTile(other) || other == tile) return;
		if (Geo.LineDir(tile, other) != d) return;
		local len = AIMap.DistanceManhattan(tile, other);
		if (len > this.max_tunnel || len < 2) return;
		if (other in this.forbidden || !::MT.safety.TileOk(other) || !::MT.nb.TileFree(other)) return;
		local ok;
		{
			local tm = AITestMode();
			ok = AITunnel.BuildTunnel(AIVehicle.VT_RAIL, tile);
		}
		if (!ok) return;
		local ng = this.g[key] + (len + 1) * (PF_STRAIGHT + 6) + PF_TUNNEL;
		this.Relax(this.Key(other, d, d), ng, key, PF_KIND_TUNNEL, goal);
	}

	function Relax(nkey, ng, pkey, k, goal) {
		if (nkey in this.g && this.g[nkey] <= ng) return;
		this.g[nkey] <- ng;
		this.par[nkey] <- pkey;
		this.kind[nkey] <- k;
		local t = nkey >> 5;
		local h = (this.potential != null && (t in this.potential)) ? this.potential[t] : this.Heuristic(t, goal);
		this.open.Insert(nkey, ng + (this.weight * h).tointeger());
	}

	/*
	 * Path from start_tile to goal_tile (already built, must be entered with step goal_dir). Returns
	 * [{tile, kind}] from start to goal, or null.
	 * By default start_tile is already built and left straight in start_dir. With opts.free the start tile is
	 * still empty (a branch: it is entered with step start_dir after a piece in direction opts.prev).
	 * opts.goal_next is the step that leaves the goal tile (a merge), so the last turn can be checked.
	 * With opts.escape the search succeeds as soon as it is that many tiles away from the start (goal_tile
	 * only guides it): a test whether a station throat opens into land a railway can use.
	 */
	function FindPath(start_tile, start_dir, goal_tile, goal_dir, opts = null) {
		local escape = (opts != null && ("escape" in opts)) ? opts.escape : 0;
		local start_free = opts != null && ("free" in opts) && opts.free;
		local start_prev = (opts != null && ("prev" in opts)) ? opts.prev : start_dir;
		local goal_next = (opts != null && ("goal_next" in opts)) ? opts.goal_next : -1;
		this.pass_cache = {};
		this.terrain_cache = {};
		this.g = {};
		this.par = {};
		this.kind = {};
		this.open = AIPriorityQueue();
		this.expanded = 0;
		/* The loop below runs tens of thousands of times inside the opcode budget: locals and lookup tables
		 * instead of helper calls (same rules as Geo.Left/Right/Opp/Offset/Dir8/Turn8, PieceOk, Relax). */
		local closed = {}, g = this.g, par = this.par, kind = this.kind, open = this.open;
		local pass = this.pass_cache, terr = this.terrain_cache, slope = {};
		local mx = AIMap.GetMapSizeX();
		local off = [1, mx, -1, -mx], left = [3, 0, 1, 2], right = [1, 2, 3, 0], opp = [2, 3, 0, 1];
		local dir8 = array(16, -1), turn8 = array(64, 0);
		for (local a = 0; a < 4; a++) for (local b = 0; b < 4; b++) dir8[a * 4 + b] = Geo.Dir8(a, b);
		for (local a = 0; a < 8; a++) for (local b = 0; b < 8; b++) turn8[a * 8 + b] = Geo.Turn8(a, b);
		local FLAT = AITile.SLOPE_FLAT, w = this.weight, pot = this.potential, share = this.share;
		local piece = array(16, -1);
		if (share != null) for (local a = 0; a < 4; a++) for (local b = 0; b < 4; b++) piece[a * 4 + b] = ::MT.rail.Piece(a, b);
		local gx = goal_tile % mx, gy = goal_tile / mx, sx = start_tile % mx, sy = start_tile / mx;
		local skey = this.Key(start_tile, start_dir, start_prev, start_free ? 1 : 0);
		g[skey] <- 0;
		par[skey] <- -1;
		kind[skey] <- PF_KIND_NORMAL;
		open.Insert(skey, this.Heuristic(start_tile, goal_tile));
		this.closest = start_tile;
		local closest_d = AIMap.DistanceManhattan(start_tile, goal_tile);
		this.stuck = -1;
		local best_pot = 1 << 30;

		while (!open.IsEmpty()) {
			local key = open.Pop();
			if (key in closed) continue;
			closed[key] <- true;
			if (++this.expanded > this.max_nodes) break;
			if (this.expanded % 2000 == 0) MT_Housekeeping();

			local tile = key >> 5, turned = (key >> 4) & 1, din = (key >> 2) & 3, dprev = key & 3;
			local tx = tile % mx, ty = tile / mx;
			local dg = abs(tx - gx) + abs(ty - gy);
			if (dg < closest_d) { closest_d = dg; this.closest = tile; }
			if (pot != null && (tile in pot) && pot[tile] < best_pot) { best_pot = pot[tile]; this.stuck = tile; }
			if (escape > 0 && abs(tx - sx) + abs(ty - sy) >= escape) return this.Build(key);
			local fixed = kind[key] != PF_KIND_NORMAL || (key == skey && !start_free);
			local s;
			if (tile in slope) s = slope[tile];
			else { s = AITile.GetSlope(tile); slope[tile] <- s; }
			local gk = g[key];
			local d8 = dir8[dprev * 4 + din];
			if (d8 < 0) d8 = dir8[din * 5];
			local nout = fixed ? 1 : 3;
			local need = (share != null && (tile in share)) ? share[tile] : -1;
			for (local k = 0; k < nout; k++) {
				local dout = k == 0 ? din : (k == 1 ? left[din] : right[din]);
				if (din != dprev && dout == opp[dprev]) continue;                    // 90 degree turn
				if (need >= 0 && piece[din * 4 + dout] != need) continue;           // only the free half of a shared tile
				if (!fixed && s != FLAT && (din != dout || !this.InclineAlong(s, din))) continue;
				local n = tile + off[dout];
				local turn = turn8[d8 * 8 + dir8[din * 4 + dout]];
				local cost = (din == dout ? PF_STRAIGHT : PF_DIAG) + PF_TURN * turn + (turn > 0 && turned ? PF_TURN2 : 0);
				local nkey = (n << 5) | ((turn > 0 ? 1 : 0) << 4) | (dout << 2) | din;
				if (n == goal_tile) {
					if (dout != goal_dir) continue;
					if (goal_next >= 0 && dout != din && goal_next == opp[din]) continue;   // 90 degree turn into a merge
					g[nkey] <- gk + cost;
					par[nkey] <- key;
					kind[nkey] <- PF_KIND_NORMAL;
					return this.Build(nkey);
				}
				local ok;
				if (n in pass) ok = pass[n];
				else { ok = this._Passable(n); pass[n] <- ok; }
				if (!ok || (nkey in closed)) continue;
				local tc;
				if (n in terr) tc = terr[n];
				else { tc = this._TerrainCost(n); terr[n] <- tc; }
				local ng = gk + cost + tc;
				if ((nkey in g) && g[nkey] <= ng) continue;
				g[nkey] <- ng;
				par[nkey] <- key;
				kind[nkey] <- PF_KIND_NORMAL;
				local h;
				if (pot != null && (n in pot)) h = pot[n];
				else {
					local dx = abs(n % mx - gx), dy = abs(n / mx - gy);
					h = dx > dy ? PF_STRAIGHT * (dx - dy) + 2 * PF_DIAG * dy : PF_STRAIGHT * (dy - dx) + 2 * PF_DIAG * dx;
				}
				open.Insert(nkey, ng + (w * h).tointeger());
			}
			if (!fixed) {
				local ahead = tile + off[din];
				if (ahead != goal_tile && (!this.Passable(ahead) || !this.PieceOk(ahead, din, din))) this.TryBridge(key, tile, din, goal_tile);
				if (s != FLAT && this.InclineAlong(s, din)) this.TryTunnel(key, tile, din, goal_tile);
			}
		}
		return null;
	}

	function Build(gkey) {
		local out = [];
		local k = gkey;
		while (k != -1) {
			out.append({tile = k >> 5, kind = this.kind[k]});
			k = this.par[k];
		}
		out.reverse();
		this.g = null;
		this.par = null;
		this.kind = null;
		this.open = null;
		this.pass_cache = null;
		this.terrain_cache = null;
		return out;
	}
}

/*
 * Coarse route for a new railway: one state per tile, straight jumps where a bridge could span, a small cost
 * for squeezing past obstacles. Slopes follow the rail rule: a sloped tile is crossed straight along its
 * incline or not at all. It answers within days whether a railway can exist at all (the full search would
 * spend months finding out), and the full search then stays in a corridor around it.
 */
class CorridorFinder {
	max_nodes = 30000;
	expanded = 0;
	rail = null;           // RailPathFinder whose Passable rules apply
	tight = null;          // tile -> cost of the obstacles next to it
	avoid = null;          // tile -> true: where an earlier full search got stuck
	slopes = null;
	bridge_ok = null;      // "from:to" -> result of the test build

	constructor(rail_pf) {
		this.rail = rail_pf;
		this.tight = {};
		this.avoid = {};
	}

	function Free(t) { return !(t in this.avoid) && this.rail.Passable(t); }

	function Tight(t) {
		if (t in this.tight) return this.tight[t];
		local c = 0;
		for (local d = 0; d < 4; d++) if (!this.rail.Passable(t + Geo.Offset(d))) c += 3;
		this.tight[t] <- c;
		return c;
	}

	/* The heads must suit the slopes (ERR_LAND_SLOPED_WRONG is common on river banks): ask the game. */
	function BridgeStands(a, b, len) {
		if (this.bridge_ok == null) this.bridge_ok = {};
		local key = a + ":" + b;
		if (key in this.bridge_ok) return this.bridge_ok[key];
		local br = this.rail.bridges.For(len + 1, this.rail.speed), ok = false;
		if (br >= 0) {
			local tm = AITestMode();
			ok = AIBridge.BuildBridge(AIVehicle.VT_RAIL, br, a, b);
		}
		this.bridge_ok[key] <- ok;
		return ok;
	}

	function SlopeOf(t) {
		if (t in this.slopes) return this.slopes[t];
		local s = AITile.GetSlope(t);
		this.slopes[t] <- s;
		return s;
	}

	/* Tiles from `start` to `goal`, or null. With escape > 0 it succeeds once it is that far from the start. */
	function Find(start, goal, escape = 0) {
		local g = {}, par = {}, closed = {};
		local landed = {};     // tile -> direction of the bridge that ends there (leave it straight, no second bridge)
		local open = AIPriorityQueue();
		local offs = [1, Geo.MX, -1, -Geo.MX];
		local maxj = this.rail.max_bridge;
		local FLAT = AITile.SLOPE_FLAT;
		if (this.slopes == null) this.slopes = {};
		g[start] <- 0;
		par[start] <- -1;
		open.Insert(start, AIMap.DistanceManhattan(start, goal) * 15);
		this.expanded = 0;
		while (!open.IsEmpty()) {
			local t = open.Pop();
			if (t in closed) continue;
			closed[t] <- true;
			if (t == goal || (escape > 0 && AIMap.DistanceManhattan(t, start) >= escape)) return this.Build(par, t);
			if (++this.expanded > this.max_nodes) return null;
			if (this.expanded % 3000 == 0) MT_Housekeeping();
			local gt = g[t];
			local st = this.SlopeOf(t);
			local ld = (t in landed) ? landed[t] : -1;
			for (local d = 0; d < 4; d++) {
				local off = offs[d];
				/* a sloped tile is left the way it was entered: straight along its incline */
				if (st != FLAT && !this.rail.InclineAlong(st, d)) continue;
				if (ld >= 0 && d != ld) continue;
				local n = t + off, cost = 10, jump = false;
				if (n != goal && !this.Free(n)) {
					if (ld >= 0 || (n in this.avoid) || !RailPathFinder.Below(n)) continue;
					local j = 2;
					n += off;
					while (j <= maxj && n != goal && !this.Free(n) && !(n in this.avoid) && RailPathFinder.Below(n)) { j++; n += off; }
					if (j > maxj || !(n == goal || this.Free(n))) continue;
					if (!this.BridgeStands(t, n, j)) continue;
					cost = 10 * j + 40;
					jump = true;
				} else if (n != goal) {
					local sn = this.SlopeOf(n);
					if (sn != FLAT) {
						if (!this.rail.InclineAlong(sn, d)) continue;
						cost += 7;
					}
					cost += this.Tight(n);
				}
				if (n in closed) continue;
				local ng = gt + cost;
				if ((n in g) && g[n] <= ng) continue;
				g[n] <- ng;
				par[n] <- t;
				if (jump) landed[n] <- d;
				else if (n in landed) delete landed[n];
				open.Insert(n, ng + AIMap.DistanceManhattan(n, goal) * 15);
			}
		}
		return null;
	}

	function Build(par, t) {
		local out = [];
		while (t != -1) { out.append(t); t = par[t]; }
		out.reverse();
		return out;
	}

	/*
	 * Every tile within r of the route (bridge jumps filled in), with its cost to go: the rest of the route
	 * from the nearest route tile plus the way to it. Used as the full search's heuristic, it leads the search
	 * around a lake instead of into the bay that points at the goal.
	 */
	function Corridor(route, r) {
		local tiles = [], prev = -1;
		foreach (t in route) {
			if (prev >= 0 && AIMap.DistanceManhattan(prev, t) > 1) {
				local d = Geo.LineDir(prev, t);
				if (d >= 0) for (local x = prev + Geo.Offset(d); x != t; x += Geo.Offset(d)) tiles.append(x);
			}
			tiles.append(t);
			prev = t;
		}
		local pot = {};
		local mx = AIMap.GetMapSizeX(), my = AIMap.GetMapSizeY();
		for (local i = tiles.len() - 1; i >= 0; i--) {
			local rest = (tiles.len() - 1 - i) * PF_STRAIGHT;
			local x0 = AIMap.GetTileX(tiles[i]), y0 = AIMap.GetTileY(tiles[i]);
			for (local y = max(1, y0 - r); y <= min(my - 2, y0 + r); y++) {
				for (local x = max(1, x0 - r); x <= min(mx - 2, x0 + r); x++) {
					local t = AIMap.GetTileIndex(x, y);
					local h = rest + PF_STRAIGHT * max(abs(x - x0), abs(y - y0));
					if (!(t in pot) || pot[t] > h) pot[t] <- h;
				}
			}
		}
		return pot;
	}
}

/*
 * Road pathfinder over existing and new road. Existing level crossings are impassable, rail tiles are only
 * bridged. Existing road is much cheaper than new road, and a turn on new road costs extra, so new roads
 * run straight and join the town streets instead of laying a parallel road next to them.
 * With allow_crossings = true it answers "would a lorry prefer a level crossing here?".
 */
class RoadPathFinder {
	max_nodes = 40000;
	max_bridge = 15;
	allow_crossings = false;
	speed = 80;           // fastest vehicle on the route, for the bridge type
	bridges = null;
	expanded = 0;
	pass_cache = null;
	used_crossing = false;
	forbidden = null;

	constructor(bridge_cache) {
		this.bridges = bridge_cache;
		this.max_bridge = min(15, ::MT.game.max_bridge_length);
		this.forbidden = {};
	}

	function Key(tile, d) { return (tile << 2) | d; }

	/* 0 = blocked, 1 = existing road, 2 = buildable for new road, 3 = level crossing (only if allowed), 4 = road bridge/tunnel */
	function Class(t) {
		if (t in this.pass_cache) return this.pass_cache[t];
		local c = this._Class(t);
		this.pass_cache[t] <- c;
		return c;
	}

	function _Class(t) {
		if (t in this.forbidden) return 0;
		if (!Geo.InMap(t, 1)) return 0;
		if (AIRail.IsLevelCrossingTile(t)) return this.allow_crossings ? 3 : 0;
		if (::MT.safety.IsDangerTile(t)) return 0;
		if (AIRoad.IsRoadTile(t)) {
			if (AIRoad.IsRoadStationTile(t) && !AIRoad.IsDriveThroughRoadStationTile(t)) return 0;
			if (AIRoad.IsRoadDepotTile(t)) return 0;
			if (AITile.HasTransportType(t, AITile.TRANSPORT_RAIL)) return this.allow_crossings ? 3 : 0;
			return 1;
		}
		if (AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) return AITile.HasTransportType(t, AITile.TRANSPORT_ROAD) ? 4 : 0;
		if (!AITile.IsBuildable(t)) return 0;
		if (::MT.safety.IsFloodRisk(t)) return 0;
		local s = AITile.GetSlope(t);
		if (AITile.IsSteepSlope(s) || AITile.IsHalftileSlope(s)) return 0;
		if (!::MT.nb.TileFree(t) || ::MT.nb.NextToTheirRail(t)) return 0;
		return 2;
	}

	function InclineAlong(slope, d) {
		if (d == DIR_PX || d == DIR_NX) return slope == AITile.SLOPE_NE || slope == AITile.SLOPE_SW;
		return slope == AITile.SLOPE_NW || slope == AITile.SLOPE_SE;
	}

	function Heuristic(t, goals_center) { return 10 * AIMap.DistanceManhattan(t, goals_center); }

	/*
	 * Path from any of `sources` to any of `goals` (arrays of tiles). Returns an array of tiles or null.
	 * New road may be laid; bridges cross rail, water and roads.
	 */
	function FindPath(sources, goals) {
		this.pass_cache = {};
		this.expanded = 0;
		local goal_set = {};
		foreach (t in goals) goal_set[t] <- true;
		local gc = goals[0];
		local open = AIPriorityQueue();
		local g = {}, par = {}, closed = {};
		foreach (s in sources) {
			for (local d = 0; d < 4; d++) {
				local k = this.Key(s, d);
				g[k] <- 0;
				par[k] <- -1;
				open.Insert(k, this.Heuristic(s, gc));
			}
		}
		while (!open.IsEmpty()) {
			local key = open.Pop();
			if (key in closed) continue;
			closed[key] <- true;
			if (++this.expanded > this.max_nodes) break;
			if (this.expanded % 2000 == 0) MT_Housekeeping();
			local tile = key >> 2, din = key & 3;
			if (tile in goal_set) return this.Trace(key, par);
			local cls = this.Class(tile);
			for (local dout = 0; dout < 4; dout++) {
				if (dout == Geo.Opp(din) && par[key] != -1) continue;
				local n = tile + Geo.Offset(dout);
				local nc = this.Class(n);
				local cost = 0;
				if (nc == 4) {
					/* existing road bridge or tunnel: jump to the other end if it points our way */
					local other = AIBridge.IsBridgeTile(n) ? AIBridge.GetOtherBridgeEnd(n) : AITunnel.GetOtherTunnelEnd(n);
					if (Geo.LineDir(n, other) != dout) continue;
					local nk = this.Key(other, dout);
					if (nk in closed) continue;
					local ng = g[key] + 10 * (AIMap.DistanceManhattan(n, other) + 2);
					if (!(nk in g) || ng < g[nk]) { g[nk] <- ng; par[nk] <- key; open.Insert(nk, ng + this.Heuristic(other, gc)); }
					continue;
				}
				if (nc == 0) {
					if (dout == din) this.TryBridge(key, tile, dout, g, par, open, closed, gc);
					continue;
				}
				if (nc == 1 || nc == 3) {
					local connected = AIRoad.AreRoadTilesConnected(tile, n);
					/* stations only along their axis: no new road bits into or out of a stop */
					if (!connected && (AIRoad.IsRoadStationTile(n) || AIRoad.IsRoadStationTile(tile))) continue;
					cost = connected ? 10 : 22;
					if (nc == 3) cost += 30;
				} else {
					if (AIRoad.IsRoadStationTile(tile)) continue;
					local s = AITile.GetSlope(n);
					if (s != AITile.SLOPE_FLAT && !this.InclineAlong(s, dout)) continue;
					cost = 30 + (s == AITile.SLOPE_FLAT ? 0 : 15) + (AITile.HasTreeOnTile(n) ? 2 : 0) + (AITile.IsFarmTile(n) ? 2 : 0);
				}
				if (cls == 2 || nc == 2) {
					/* a new piece on a slope must run along the incline */
					local s0 = AITile.GetSlope(tile);
					if (cls == 2 && s0 != AITile.SLOPE_FLAT && !this.InclineAlong(s0, dout)) continue;
				}
				if (dout != din && par[key] != -1) cost += (nc == 2 || cls == 2) ? 14 : 4;
				local nk = this.Key(n, dout);
				if (nk in closed) continue;
				local ng = g[key] + cost;
				if (!(nk in g) || ng < g[nk]) { g[nk] <- ng; par[nk] <- key; open.Insert(nk, ng + this.Heuristic(n, gc)); }
			}
		}
		return null;
	}

	function TryBridge(key, tile, d, g, par, open, closed, gc) {
		if (AITile.GetSlope(tile) != AITile.SLOPE_FLAT || this.Class(tile) != 2 && this.Class(tile) != 1) return;
		if (AIRoad.IsRoadStationTile(tile) || AIRoad.IsRoadDepotTile(tile)) return;
		local off = Geo.Offset(d);
		for (local len = 2; len <= this.max_bridge; len++) {
			local e = tile + len * off;
			if (!Geo.InMap(e, 1)) return;
			if (!RailPathFinder.Below(e - off)) return;
			local ec = this.Class(e);
			if (ec != 2 || AITile.GetSlope(e) != AITile.SLOPE_FLAT) continue;
			local b = this.bridges.For(len + 1, this.speed);
			if (b < 0) return;
			local ok;
			{
				local tm = AITestMode();
				ok = AIBridge.BuildBridge(AIVehicle.VT_ROAD, b, tile, e);
			}
			if (!ok) continue;
			local nk = this.Key(e, d);
			if (nk in closed) return;
			local ng = g[key] + (len + 1) * 12 + 80;
			if (!(nk in g) || ng < g[nk]) { g[nk] <- ng; par[nk] <- key; open.Insert(nk, ng + this.Heuristic(e, gc)); }
			return;
		}
	}

	function Trace(key, par) {
		local out = [];
		local k = key;
		local last = -1;
		while (k != -1) {
			local t = k >> 2;
			if (t != last) out.append(t);
			last = t;
			k = par[k];
		}
		out.reverse();
		this.used_crossing = false;
		foreach (t in out) if (AIRail.IsLevelCrossingTile(t)) this.used_crossing = true;
		this.pass_cache = null;
		return out;
	}
}

/*
 * Shipping lane check: is there water all the way between two docks, and how long is the way? Ships find
 * their own way (YAPF over water regions), so this only answers the question and measures the distance.
 * Water tiles, buoys and the water part of docks are passable; ship depots and land are not.
 */
class WaterPathFinder {
	max_nodes = 40000;
	expanded = 0;
	weight = 2;
	closest = -1;   // smallest distance to the goals the last search reached (diagnostics)

	function Water(t) {
		if (!AIMap.IsValidTile(t)) return false;
		if (AITile.IsWaterTile(t)) return !AIMarine.IsWaterDepotTile(t);
		return AIMarine.IsBuoyTile(t);
	}

	exhausted = null;   // after a search that ran out of water: every tile it reached (one closed body of water)

	/* Length in tiles of a water path between the two tile sets, or -1. */
	function Distance(sources, goals) {
		local goal_set = {};
		foreach (t in goals) goal_set[t] <- true;
		local gx = 0, gy = 0;
		foreach (t in goals) { gx += AIMap.GetTileX(t); gy += AIMap.GetTileY(t); }
		gx /= goals.len();
		gy /= goals.len();
		local g = {}, closed = {};
		local open = AIPriorityQueue();
		local mx = AIMap.GetMapSizeX();
		local off = [1, mx, -1, -mx];
		foreach (s in sources) {
			g[s] <- 0;
			open.Insert(s, 0);
		}
		this.expanded = 0;
		this.closest = 1 << 30;
		while (!open.IsEmpty()) {
			local t = open.Pop();
			if (t in closed) continue;
			closed[t] <- true;
			if (t in goal_set) return g[t];
			local hd = abs(t % mx - gx) + abs(t / mx - gy);
			if (hd < this.closest) this.closest = hd;
			if (++this.expanded > this.max_nodes) return -1;
			if (this.expanded % 3000 == 0) MT_Housekeeping();
			local gt = g[t] + 1;
			for (local d = 0; d < 4; d++) {
				local n = t + off[d];
				if (n in closed) continue;
				if (!(n in goal_set) && !this.Water(n)) continue;
				if ((n in g) && g[n] <= gt) continue;
				g[n] <- gt;
				local h = abs(n % mx - gx) + abs(n / mx - gy);
				open.Insert(n, gt + this.weight * h);
			}
		}
		this.exhausted = closed;
		return -1;
	}
}
