/*
 * A* pathfinders for new railway and road. Safety rules are part of the search, not a later check:
 *   - no level crossings: road tiles block rail (bridge or tunnel instead) and rail tiles block road,
 *     existing level crossings are never used;
 *   - no coast or sea-level tiles (flood risk) and no tiles where one of our vehicles crashed;
 *   - rail: no 90 degree turns (also too slow), no diagonal pieces or foundations on slopes so that every
 *     piece joins its neighbours at the same height.
 * Costs are travel time: a straight tile 30, a diagonal piece 20 (2/3 of the time), +45 per 45 degree turn and
 * +90 more when two turns follow each other (OpenTTD limits a train to 88 km/h when its direction changes twice
 * within one wagon length, train_cmd.cpp GetCurveSpeedLimit), +20 per incline, bridges and tunnels at tile cost
 * plus a construction penalty.
 */

const PF_STRAIGHT = 30;
const PF_DIAG = 20;
const PF_TURN = 45;
const PF_TURN2 = 90;
const PF_SLOPE = 20;
const PF_BRIDGE = 120;
const PF_TUNNEL = 150;
const PF_KIND_NORMAL = 0;
const PF_KIND_BRIDGE = 1;
const PF_KIND_TUNNEL = 2;

class BridgeCache {
	fastest = null;   // length -> bridge type or -1
	constructor() { this.fastest = {}; }
	function Fastest(len) {
		if (len in this.fastest) return this.fastest[len];
		local list = AIBridgeList_Length(len);
		local best = -1, best_speed = -1;
		foreach (b, _ in list) {
			local s = AIBridge.GetMaxSpeed(b);
			if (s > best_speed) { best_speed = s; best = b; }
		}
		this.fastest[len] <- best;
		return best;
	}
}

class RailPathFinder {
	forbidden = null;      // tile -> true
	allowed = null;        // tile -> true: the corridor the search must stay in (null: anywhere)
	own_free = null;       // tile -> track: our placeholder pieces, free for the new track
	potential = null;      // tile -> cost to go along the coarse route (guides the search around detours)
	prefer = null;         // tile -> true (next to the first track of a double line)
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

	constructor(bridge_cache) {
		this.forbidden = {};
		this.prefer = {};
		this.pass_cache = {};
		this.bridges = bridge_cache;
		this.max_bridge = min(20, ::TY.game.max_bridge_length);
		this.max_tunnel = min(20, ::TY.game.max_tunnel_length);
		this.max_nodes = (80000 * ::TY.levels.search_scale).tointeger();
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

	stats = null;   // debug counters of the last search

	function _Passable(t) {
		if (this.stats != null) this.stats.passable++;
		if (t in this.forbidden) return false;
		if (this.allowed != null && !(t in this.allowed)) return false;
		/* our placeholder piece (flat and safe when it was laid) */
		if (this.own_free != null && (t in this.own_free) && ::TY.rail.IsPlaceholder(t, this.own_free[t])) return true;
		if (!Geo.InMap(t, 2)) return false;
		if (!AITile.IsBuildable(t)) return false;
		if (AIRoad.IsRoadTile(t)) return false;           // never a level crossing
		if (!::TY.safety.TileOk(t)) return false;         // flood risk, crash sites
		local s = AITile.GetSlope(t);
		if (AITile.IsSteepSlope(s) || AITile.IsHalftileSlope(s)) return false;
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

	/* per tile, cached per search: a tile is reached in several states */
	function TerrainCost(t) {
		if (t in this.terrain_cache) return this.terrain_cache[t];
		local c = this._TerrainCost(t);
		this.terrain_cache[t] <- c;
		return c;
	}

	function _TerrainCost(t) {
		if (this.stats != null) this.stats.terrain++;
		local c = this.TreeCost(t);
		if (AITile.IsFarmTile(t)) c += 4;
		if (AITile.IsRoughTile(t) || AITile.IsRockTile(t)) c += 3;
		if (AITile.GetSlope(t) != AITile.SLOPE_FLAT) c += PF_SLOPE;
		if (t in this.prefer) c -= 6;
		return c;
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

	open = null;

	/*
	 * Bridge heads may stand on slopes (rivers and coasts are rarely flat): the ramp or a foundation takes the
	 * slope, and the test build decides. Only the far head has to be a tile the line could use anyway.
	 */
	below_cache = null;   // tile -> may a bridge span it (per search)
	head_cache = null;    // tile -> may a bridge head stand on it (per search)

	function BelowCached(t) {
		if (this.below_cache == null) this.below_cache = {};
		if (t in this.below_cache) return this.below_cache[t];
		local ok = RailPathFinder.Below(t);
		this.below_cache[t] <- ok;
		return ok;
	}

	function HeadCached(t) {
		if (this.head_cache == null) this.head_cache = {};
		if (t in this.head_cache) return this.head_cache[t];
		local ok = this.HeadSlopeOk(t);
		this.head_cache[t] <- ok;
		return ok;
	}

	function TryBridge(key, tile, d, goal) {
		if (this.stats != null) this.stats.bridge_calls++;
		if (!this.HeadCached(tile)) return;
		local off = Geo.Offset(d);
		for (local len = 2; len <= this.max_bridge; len++) {
			if (this.stats != null) this.stats.bridge_steps++;
			local e = tile + len * off;
			if (!Geo.InMap(e, 2)) return;
			if (!this.BelowCached(e - off)) return;   // the span would demolish a house or a station
			if (e != goal && !this.Passable(e)) continue;
			if (!this.HeadCached(e)) continue;
			local b = this.bridges.Fastest(len + 1);
			if (b < 0) return;
			local ok;
			{
				local tm = AITestMode();
				if (this.stats != null) this.stats.bridge_tests++;
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
		if (this.stats != null) this.stats.tunnel_calls++;
		local s = AITile.GetSlope(tile);
		if (!this.InclineAlong(s, d)) return;
		local other = AITunnel.GetOtherTunnelEnd(tile);
		if (!AIMap.IsValidTile(other) || other == tile) return;
		if (Geo.LineDir(tile, other) != d) return;
		local len = AIMap.DistanceManhattan(tile, other);
		if (len > this.max_tunnel || len < 2) return;
		if (other in this.forbidden || !::TY.safety.TileOk(other)) return;
		local ok;
		{
			local tm = AITestMode();
			ok = AITunnel.BuildTunnel(AIVehicle.VT_RAIL, tile);
		}
		if (!ok) return;
		local ng = this.g[key] + (len + 1) * (PF_STRAIGHT + 6) + PF_TUNNEL;
		this.Relax(this.Key(other, d, d), ng, key, PF_KIND_TUNNEL, goal);
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
		this.below_cache = {};
		this.head_cache = {};
		this.g = {};
		this.par = {};
		this.kind = {};
		this.open = AIPriorityQueue();
		this.expanded = 0;
		this.stats = {passable = 0, terrain = 0, bridge_calls = 0, bridge_steps = 0, bridge_tests = 0, tunnel_calls = 0, housekeeping = 0};
		/* The loop below runs tens of thousands of times inside the opcode budget: locals and lookup tables
		 * instead of helper calls (same rules as Geo.Left/Right/Opp/Offset/Dir8/Turn8, PieceOk, Relax). */
		local closed = {}, g = this.g, par = this.par, kind = this.kind, open = this.open;
		local pass = this.pass_cache, terr = this.terrain_cache, slope = {};
		local mx = AIMap.GetMapSizeX();
		local off = [1, mx, -1, -mx], left = [3, 0, 1, 2], right = [1, 2, 3, 0], opp = [2, 3, 0, 1];
		local dir8 = array(16, -1), turn8 = array(64, 0);
		for (local a = 0; a < 4; a++) for (local b = 0; b < 4; b++) dir8[a * 4 + b] = Geo.Dir8(a, b);
		for (local a = 0; a < 8; a++) for (local b = 0; b < 8; b++) turn8[a * 8 + b] = Geo.Turn8(a, b);
		local FLAT = AITile.SLOPE_FLAT, w = this.weight, pot = this.potential;
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
			if (this.expanded % 2000 == 0) { this.stats.housekeeping++; TY_Housekeeping(); }

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
			for (local k = 0; k < nout; k++) {
				local dout = k == 0 ? din : (k == 1 ? left[din] : right[din]);
				if (din != dprev && dout == opp[dprev]) continue;                    // 90 degree turn
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

	slopes = null;
	bridge_ok = null;      // "from:to" -> result of the test build

	/* The heads must suit the slopes (ERR_LAND_SLOPED_WRONG is common on river banks): ask the game. */
	function BridgeStands(a, b, len) {
		if (this.bridge_ok == null) this.bridge_ok = {};
		local key = a + ":" + b;
		if (key in this.bridge_ok) return this.bridge_ok[key];
		local br = this.rail.bridges.Fastest(len + 1), ok = false;
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
			if (this.expanded % 3000 == 0) TY_Housekeeping();
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
					if (ld >= 0 || (n in this.avoid) || !this.rail.BelowCached(n)) continue;
					local j = 2;
					n += off;
					while (j <= maxj && n != goal && !this.Free(n) && !(n in this.avoid) && this.rail.BelowCached(n)) { j++; n += off; }
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
 * bridged. With allow_crossings = true it answers "would a bus prefer a level crossing here?".
 */
class RoadPathFinder {
	max_nodes = 40000;
	max_bridge = 15;
	allow_crossings = false;
	bridges = null;
	expanded = 0;
	pass_cache = null;
	used_crossing = false;
	forbidden = null;

	constructor(bridge_cache) {
		this.bridges = bridge_cache;
		this.max_bridge = min(15, ::TY.game.max_bridge_length);
		this.forbidden = {};
	}

	function Key(tile, d) { return (tile << 2) | d; }

	/* 0 = blocked, 1 = existing road, 2 = buildable for new road, 3 = level crossing (only if allowed) */
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
		if (::TY.safety.IsDangerTile(t)) return 0;
		if (AIRoad.IsRoadTile(t)) {
			if (AIRoad.IsRoadStationTile(t) && !AIRoad.IsDriveThroughRoadStationTile(t)) return 0;
			if (AIRoad.IsRoadDepotTile(t)) return 0;
			if (AITile.HasTransportType(t, AITile.TRANSPORT_RAIL)) return this.allow_crossings ? 3 : 0;
			return 1;
		}
		if (AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) return AITile.HasTransportType(t, AITile.TRANSPORT_ROAD) ? 4 : 0;
		if (!AITile.IsBuildable(t)) return 0;
		if (::TY.safety.IsFloodRisk(t)) return 0;
		local s = AITile.GetSlope(t);
		if (AITile.IsSteepSlope(s) || AITile.IsHalftileSlope(s)) return 0;
		return 2;
	}

	function InclineAlong(slope, d) {
		if (d == DIR_PX || d == DIR_NX) return slope == AITile.SLOPE_NE || slope == AITile.SLOPE_SW;
		return slope == AITile.SLOPE_NW || slope == AITile.SLOPE_SE;
	}

	function Heuristic(t, goals_center) { return 10 * AIMap.DistanceManhattan(t, goals_center); }

	/*
	 * Path from any of `sources` to any of `goals` (arrays of road tiles). Returns an array of tiles or null.
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
					cost = 30 + (s == AITile.SLOPE_FLAT ? 0 : 15) + (AITile.HasTreeOnTile(n) ? 2 : 0);
				}
				if (cls == 2 || nc == 2) {
					/* a new piece on a slope must run along the incline */
					local s0 = AITile.GetSlope(tile);
					if (cls == 2 && s0 != AITile.SLOPE_FLAT && !this.InclineAlong(s0, dout)) continue;
				}
				if (dout != din && par[key] != -1) cost += 4;
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
			local ec = this.Class(e);
			if (ec != 2 || AITile.GetSlope(e) != AITile.SLOPE_FLAT) continue;
			local b = this.bridges.Fastest(len + 1);
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
 * Water pathfinder: ships sail on flat sea, river and canal tiles, which need no construction, and across
 * shore tiles with a single raised corner (water_cmd.cpp GetTileTrackStatus_Water: such a coast tile holds one
 * diagonal track piece joining its two water-side edges). The search only answers whether two water tiles are
 * connected and how far apart they are by water. Moves go through tile edges, as ships do.
 */
const BUOY_SPACING = 16;

class WaterPathFinder {
	max_nodes = 60000;
	expanded = 0;
	capped = false;      // the last search gave up at max_nodes
	last_tiles = null;   // tiles the last search closed (a failed, uncapped search closed the start's whole body of water)

	constructor() { this.max_nodes = (60000 * ::TY.levels.search_scale).tointeger(); }

	/* 0: not sailable; 1: flat water (any way through); 2..: a corner coast tile (slope value, two edges only). */
	function Kind(t) {
		if (!AIMap.IsValidTile(t)) return 0;
		if (AIMarine.IsBuoyTile(t) || AIMarine.IsLockTile(t)) return 1;
		if (!AITile.IsWaterTile(t)) {
			if (AITile.IsCoastTile(t)) {
				local s = AITile.GetSlope(t);
				if (s == AITile.SLOPE_W || s == AITile.SLOPE_S || s == AITile.SLOPE_E || s == AITile.SLOPE_N) return s;
			}
			return 0;
		}
		if (AITile.IsCoastTile(t)) return 0;
		return AITile.GetSlope(t) == AITile.SLOPE_FLAT ? 1 : 0;
	}

	function Sailable(t) { return this.Kind(t) == 1; }

	/*
	 * Edges of a corner coast tile that carry its track piece, as the step directions that cross them:
	 * entering with step d crosses the edge opposite to d's side, leaving with step d crosses d's side.
	 * Side of a step: +x is the SW edge, -x NE, +y SE, -y NW (OpenTTD's x axis runs NE to SW).
	 */
	function Edges(slope) {
		/* raised W corner: track RIGHT joins the NE and SE edges; S: UPPER joins NE and NW; E: LEFT joins NW and SW; N: LOWER joins SE and SW */
		if (slope == AITile.SLOPE_W) return [DIR_NX, DIR_PY];
		if (slope == AITile.SLOPE_S) return [DIR_NX, DIR_NY];
		if (slope == AITile.SLOPE_E) return [DIR_NY, DIR_PX];
		return [DIR_PY, DIR_PX];
	}

	/* May a ship enter a corner coast tile with step d and leave it with step dout? */
	function CornerOk(slope, din, dout) {
		local e = this.Edges(slope);
		local entry = Geo.Opp(din);   // the edge crossed on entry is on the side the ship comes from
		return (entry == e[0] && dout == e[1]) || (entry == e[1] && dout == e[0]);
	}

	/* Path of water tiles from a to b (both flat water), or null. */
	function FindPath(a, b) {
		if (this.Kind(a) != 1 || this.Kind(b) != 1) return null;
		local g = {}, par = {}, closed = {}, kinds = {};
		local open = AIPriorityQueue();
		local offs = [1, Geo.MX, -1, -Geo.MX];
		local Key = function(t, d) { return (t << 2) | d; };
		for (local d = 0; d < 4; d++) { local k = Key(a, d); g[k] <- 0; par[k] <- -1; open.Insert(k, AIMap.DistanceManhattan(a, b)); }
		this.expanded = 0;
		this.capped = false;
		this.last_tiles = {};
		while (!open.IsEmpty()) {
			local key = open.Pop();
			if (key in closed) continue;
			closed[key] <- true;
			local t = key >> 2, din = key & 3;
			this.last_tiles[t] <- true;
			if (t == b) {
				local out = [], k = key, last = -1;
				while (k != -1) { local x = k >> 2; if (x != last) out.append(x); last = x; k = par[k]; }
				out.reverse();
				return out;
			}
			if (++this.expanded > this.max_nodes) { this.capped = true; return null; }
			if (this.expanded % 4000 == 0) TY_Housekeeping();
			local kt;
			if (t in kinds) kt = kinds[t];
			else { kt = this.Kind(t); kinds[t] <- kt; }
			local gt = g[key];
			for (local dout = 0; dout < 4; dout++) {
				if (par[key] != -1 && dout == Geo.Opp(din)) continue;          // no reversing inside a tile
				if (kt > 1 && !this.CornerOk(kt, din, dout)) continue;          // a corner tile joins two edges only
				local n = t + offs[dout];
				local kn;
				if (n in kinds) kn = kinds[n];
				else { kn = this.Kind(n); kinds[n] <- kn; }
				if (kn == 0) continue;
				/* the game's own answer for the shared edge (tracks on both sides), then the corner tile's two edges */
				if (!AIMarine.AreWaterTilesConnected(t, n)) continue;
				if (kn > 1 && n != b) {
					local e = this.Edges(kn);
					local entry = Geo.Opp(dout);
					if (entry != e[0] && entry != e[1]) continue;
				}
				local nk = Key(n, dout);
				if (nk in closed) continue;
				local ng = gt + (kn > 1 ? 2 : 1);
				if ((nk in g) && g[nk] <= ng) continue;
				g[nk] <- ng;
				par[nk] <- key;
				open.Insert(nk, ng + AIMap.DistanceManhattan(n, b));
			}
		}
		return null;
	}

	/*
	 * Sailable tiles reachable from `start`, up to `limit` tiles: {tiles, complete}. A reachability test before
	 * the A* search: a dock on a pond cannot reach the sea however long the search runs, and a small body of
	 * water is found complete within a few hundred tiles.
	 */
	function Flood(start, limit) {
		local seen = {}, queue = [start], i = 0;
		local offs = [1, Geo.MX, -1, -Geo.MX];
		seen[start] <- true;
		while (i < queue.len()) {
			if (queue.len() > limit) return {tiles = seen, complete = false};
			local t = queue[i++];
			local kt = this.Kind(t);
			for (local d = 0; d < 4; d++) {
				if (kt > 1 && !Util.Contains(this.Edges(kt), d)) continue;   // a corner tile is left through its two edges
				local n = t + offs[d];
				if (n in seen) continue;
				local kn = this.Kind(n);
				if (kn == 0 || !AIMarine.AreWaterTilesConnected(t, n)) continue;
				if (kn > 1 && !Util.Contains(this.Edges(kn), Geo.Opp(d))) continue;
				seen[n] <- true;
				queue.append(n);
			}
			if (i % 400 == 0) TY_Housekeeping();
		}
		return {tiles = seen, complete = true};
	}

	/* Tiles along a water path where buoys help a long voyage (every BUOY_SPACING tiles, away from the ends). */
	function BuoySpots(path) {
		local out = [];
		for (local i = BUOY_SPACING; i < path.len() - BUOY_SPACING / 2; i += BUOY_SPACING) out.append(path[i]);
		return out;
	}
}
