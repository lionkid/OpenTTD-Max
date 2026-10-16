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
	prefer = null;         // tile -> true (next to the first track of a double line)
	max_nodes = 80000;
	max_bridge = 20;
	max_tunnel = 20;
	weight = 1.3;          // heuristic weight (slightly greedy, much faster)
	expanded = 0;
	pass_cache = null;
	bridges = null;
	g = null;
	par = null;
	kind = null;

	constructor(bridge_cache) {
		this.forbidden = {};
		this.prefer = {};
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
		if (t in this.forbidden) return false;
		if (!Geo.InMap(t, 2)) return false;
		if (!AITile.IsBuildable(t)) return false;
		if (AIRoad.IsRoadTile(t)) return false;           // never a level crossing
		if (!::MT.safety.TileOk(t)) return false;         // flood risk, crash sites
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

	function TerrainCost(t) {
		local c = 0;
		if (AITile.HasTreeOnTile(t)) c += 3;
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
		this.open.Insert(nkey, ng + (this.weight * this.Heuristic(nkey >> 5, goal)).tointeger());
	}

	open = null;

	function TryBridge(key, tile, d, goal) {
		if (AITile.GetSlope(tile) != AITile.SLOPE_FLAT) return;
		local off = Geo.Offset(d);
		for (local len = 2; len <= this.max_bridge; len++) {
			local e = tile + len * off;
			if (!Geo.InMap(e, 2)) return;
			if (e != goal && !this.Passable(e)) continue;
			if (AITile.GetSlope(e) != AITile.SLOPE_FLAT) continue;
			local b = this.bridges.Fastest(len + 1);
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

	function TryTunnel(key, tile, d, goal) {
		local s = AITile.GetSlope(tile);
		if (!this.InclineAlong(s, d)) return;
		local other = AITunnel.GetOtherTunnelEnd(tile);
		if (!AIMap.IsValidTile(other) || other == tile) return;
		if (Geo.LineDir(tile, other) != d) return;
		local len = AIMap.DistanceManhattan(tile, other);
		if (len > this.max_tunnel || len < 2) return;
		if (other in this.forbidden || !::MT.safety.TileOk(other)) return;
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
	 * Path from start_tile (already built, left straight in start_dir) to goal_tile (already built, must be
	 * entered with step goal_dir). Returns [{tile, kind}] from start to goal, or null.
	 */
	function FindPath(start_tile, start_dir, goal_tile, goal_dir) {
		this.pass_cache = {};
		this.g = {};
		this.par = {};
		this.kind = {};
		this.open = AIPriorityQueue();
		this.expanded = 0;
		local closed = {};
		local skey = this.Key(start_tile, start_dir, start_dir);
		this.g[skey] <- 0;
		this.par[skey] <- -1;
		this.kind[skey] <- PF_KIND_NORMAL;
		this.open.Insert(skey, this.Heuristic(start_tile, goal_tile));

		while (!this.open.IsEmpty()) {
			local key = this.open.Pop();
			if (key in closed) continue;
			closed[key] <- true;
			if (++this.expanded > this.max_nodes) break;
			if (this.expanded % 2000 == 0) MT_Housekeeping();

			local tile = key >> 5, turned = (key >> 4) & 1, din = (key >> 2) & 3, dprev = key & 3;
			local kd = this.kind[key];
			local fixed = kd != PF_KIND_NORMAL || key == skey;
			local outs = fixed ? [din] : [din, Geo.Left(din), Geo.Right(din)];
			foreach (dout in outs) {
				if (din != dprev && dout == Geo.Opp(dprev)) continue;        // 90 degree turn
				if (kd == PF_KIND_NORMAL && key != skey && !this.PieceOk(tile, din, dout)) continue;
				local n = tile + Geo.Offset(dout);
				local turn = Geo.Turn8(Geo.Dir8(dprev, din), Geo.Dir8(din, dout));
				local cost = (din == dout ? PF_STRAIGHT : PF_DIAG) + PF_TURN * turn + (turn > 0 && turned ? PF_TURN2 : 0);
				if (n == goal_tile) {
					if (dout != goal_dir) continue;
					local gkey = this.Key(n, dout, din, turn > 0 ? 1 : 0);
					this.g[gkey] <- this.g[key] + cost;
					this.par[gkey] <- key;
					this.kind[gkey] <- PF_KIND_NORMAL;
					return this.Build(gkey);
				}
				if (!this.Passable(n)) continue;
				local nkey = this.Key(n, dout, din, turn > 0 ? 1 : 0);
				if (nkey in closed) continue;
				this.Relax(nkey, this.g[key] + cost + this.TerrainCost(n), key, PF_KIND_NORMAL, goal_tile);
			}
			if (!fixed) {
				local ahead = tile + Geo.Offset(din);
				if (ahead != goal_tile && (!this.Passable(ahead) || !this.PieceOk(ahead, din, din))) this.TryBridge(key, tile, din, goal_tile);
				this.TryTunnel(key, tile, din, goal_tile);
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
		return out;
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
		this.max_bridge = min(15, ::MT.game.max_bridge_length);
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
