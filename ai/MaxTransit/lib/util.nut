/*
 * Shared helpers: logging, tile geometry, dates and small list utilities.
 */

const MODE_ROAD = 0;
const MODE_RAIL = 1;
const MODE_AIR  = 2;

const DAY_TICKS = 74;

/* Direction codes used by the pathfinders and builders: 0 = +x (SW), 1 = +y (SE), 2 = -x (NE), 3 = -y (NW). */
const DIR_PX = 0;
const DIR_PY = 1;
const DIR_NX = 2;
const DIR_NY = 3;

/* OpenTTD's min() and max() take integers only; these also take floats. */
function fmin(a, b) { return a < b ? a : b; }
function fmax(a, b) { return a > b ? a : b; }

Log <- {
	function Info(tag, msg)  { AILog.Info("[" + tag + "] " + msg); }
	function Warn(tag, msg)  { AILog.Warning("[" + tag + "] " + msg); }
	function Error(tag, msg) { AILog.Error("[" + tag + "] " + msg); }
};

Geo <- {
	MX = 0,  // map size x, set by Init()

	function Init() { Geo.MX = AIMap.GetMapSizeX(); }

	function Offset(d) {
		switch (d) {
			case DIR_PX: return 1;
			case DIR_PY: return Geo.MX;
			case DIR_NX: return -1;
			case DIR_NY: return -Geo.MX;
		}
		return 0;
	}
	function Opp(d)   { return (d + 2) % 4; }
	function Right(d) { return (d + 1) % 4; }
	function Left(d)  { return (d + 3) % 4; }
	function Step(t, d, n = 1) { return t + n * Geo.Offset(d); }
	function X(t) { return AIMap.GetTileX(t); }
	function Y(t) { return AIMap.GetTileY(t); }

	/* Direction of the step from tile a to the adjacent tile b, or -1. */
	function DirOf(a, b) {
		local diff = b - a;
		if (diff == 1) return DIR_PX;
		if (diff == -1) return DIR_NX;
		if (diff == Geo.MX) return DIR_PY;
		if (diff == -Geo.MX) return DIR_NY;
		return -1;
	}

	/* Axis direction of the straight line from a to b (same row or column), or -1. */
	function LineDir(a, b) {
		local dx = Geo.X(b) - Geo.X(a), dy = Geo.Y(b) - Geo.Y(a);
		if (dy == 0 && dx > 0) return DIR_PX;
		if (dy == 0 && dx < 0) return DIR_NX;
		if (dx == 0 && dy > 0) return DIR_PY;
		if (dx == 0 && dy < 0) return DIR_NY;
		return -1;
	}

	/* Axis direction that points most closely from tile a towards tile b. */
	function Towards(a, b) {
		local dx = Geo.X(b) - Geo.X(a), dy = Geo.Y(b) - Geo.Y(a);
		if (abs(dx) >= abs(dy)) return dx >= 0 ? DIR_PX : DIR_NX;
		return dy >= 0 ? DIR_PY : DIR_NY;
	}

	/*
	 * OpenTTD 8-way direction of a train on the track piece that is entered with step din and left with step
	 * dout (N = 0, NE = 1, E = 2, SE = 3, S = 4, SW = 5, W = 6, NW = 7).
	 */
	function Dir8(din, dout) {
		if (din == dout) return [5, 3, 1, 7][din];
		local a = min(din, dout), b = max(din, dout);
		if (a == DIR_PX && b == DIR_PY) return 4;   // S
		if (a == DIR_PX && b == DIR_NY) return 6;   // W
		if (a == DIR_PY && b == DIR_NX) return 2;   // E
		if (a == DIR_NX && b == DIR_NY) return 0;   // N
		return -1;                                  // reversal, never a valid piece
	}

	/* Angle in 45 degree steps (0, 1 or 2) between two 8-way directions. */
	function Turn8(a, b) {
		local d = abs(a - b) % 8;
		return d > 4 ? 8 - d : d;
	}

	function InMap(t, margin = 1) {
		if (!AIMap.IsValidTile(t)) return false;
		local x = Geo.X(t), y = Geo.Y(t);
		return x >= margin && y >= margin && x < AIMap.GetMapSizeX() - margin && y < AIMap.GetMapSizeY() - margin;
	}
};

Util <- {
	pax = -1,   // passenger cargo id
	mail = -1,  // mail cargo id (may stay -1)

	function Init() {
		foreach (c, _ in AICargoList()) {
			if (AICargo.GetTownEffect(c) == AICargo.TE_PASSENGERS && Util.pax == -1) Util.pax = c;
			if (AICargo.GetTownEffect(c) == AICargo.TE_MAIL && Util.mail == -1) Util.mail = c;
		}
		if (Util.pax == -1) {
			foreach (c, _ in AICargoList()) {
				if (AICargo.HasCargoClass(c, AICargo.CC_PASSENGERS)) { Util.pax = c; break; }
			}
		}
	}

	function Today() { return AIDate.GetCurrentDate(); }
	function Year()  { return AIDate.GetYear(AIDate.GetCurrentDate()); }

	function DateStr(d) {
		local m = AIDate.GetMonth(d), day = AIDate.GetDayOfMonth(d);
		return AIDate.GetYear(d) + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day;
	}

	function TileStr(t) {
		if (t == null || !AIMap.IsValidTile(t)) return "(invalid)";
		return "(" + AIMap.GetTileX(t) + "," + AIMap.GetTileY(t) + ")";
	}

	function TownName(town) {
		local n = AITown.GetName(town);
		return n == null ? ("town " + town) : n;
	}

	function Money(m) {
		local neg = m < 0;
		if (neg) m = -m;
		local s;
		if (m >= 10000000) s = (m / 1000000) + "M";
		else if (m >= 1000000) s = (m / 1000000) + "." + ((m / 100000) % 10) + "M";
		else if (m >= 10000) s = (m / 1000) + "k";
		else s = "" + m;
		return (neg ? "-" : "") + "GBP " + s;
	}

	function Clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

	function Contains(arr, v) {
		foreach (x in arr) if (x == v) return true;
		return false;
	}

	/* Items of an AIList sorted by value, highest first, at most n of them. */
	function TopN(list, n) {
		list.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);
		local out = [];
		foreach (item, _ in list) {
			if (out.len() >= n) break;
			out.append(item);
		}
		return out;
	}

	function Percent(a, b) { return b <= 0 ? 0 : (100 * a / b); }

	/* Run fn (a closure without arguments) in test mode and return its result. */
	function Test(fn) {
		local tm = AITestMode();
		return fn();
	}

	/* Cost estimate of fn in test mode (AIAccounting), or -1 if it would fail. */
	function Cost(fn) {
		local tm = AITestMode();
		local acc = AIAccounting();
		if (!fn()) return -1;
		return acc.GetCosts();
	}

	/* Rough rating value for the category the API reports (accurate values are GameScript only). */
	function RatingEstimate(town) {
		local r = AITown.GetRating(town, AICompany.COMPANY_SELF);
		switch (r) {
			case AITown.TOWN_RATING_NONE: return 500;
			case AITown.TOWN_RATING_APPALLING: return -600;
			case AITown.TOWN_RATING_VERY_POOR: return -300;
			case AITown.TOWN_RATING_POOR: return -100;
			case AITown.TOWN_RATING_MEDIOCRE: return 100;
			case AITown.TOWN_RATING_GOOD: return 300;
			case AITown.TOWN_RATING_VERY_GOOD: return 500;
			case AITown.TOWN_RATING_EXCELLENT: return 700;
		}
		return 900;
	}

	/* Trees we may still cut in a town before it refuses new stations (rating must stay above -200). */
	function TreeAllowance(town) { return max(0, (Util.RatingEstimate(town) + 150) / 35); }

	/*
	 * Plant trees on free land around a town to repair our rating (+7 per tree, up to the cap of 220 that
	 * tree planting can reach). Returns the number of trees planted.
	 */
	function PlantTrees(town, count) {
		local c = AITown.GetLocation(town);
		local list = AITileList();
		local x = AIMap.GetTileX(c), y = AIMap.GetTileY(c);
		list.AddRectangle(AIMap.GetTileIndex(max(1, x - 12), max(1, y - 12)),
			AIMap.GetTileIndex(min(AIMap.GetMapSizeX() - 2, x + 12), min(AIMap.GetMapSizeY() - 2, y + 12)));
		list.Valuate(AITile.IsBuildable);
		list.KeepValue(1);
		list.Valuate(AITile.HasTreeOnTile);
		list.KeepValue(0);
		list.Valuate(AIRoad.IsRoadTile);
		list.KeepValue(0);
		local planted = 0;
		foreach (t, _ in list) {
			if (planted >= count) break;
			if (AITile.PlantTree(t)) planted++;
		}
		return planted;
	}

	/*
	 * Debug map of the rail around a tile, one row per y: '-' x-axis track, '|' y-axis track, '/' '\\' 'n' 'u'
	 * corner pieces, '+' several pieces, 'S' station, 'D' depot, '=' bridge head, 'T' tunnel portal,
	 * 'r' road, '#' level crossing, '~' water. A '!' after a tile marks a signal on it. With `blocked`, other
	 * tiles show 'x' when forbidden to the path search, 'h' when not buildable and 's' when sloped.
	 */
	/* Opcode accounting for profiling: a mark, then the operations used since (ticks times the budget). */
	function OpsMark() { return [AIController.GetTick(), AIController.GetOpsTillSuspend()]; }
	function OpsSince(m) { return (AIController.GetTick() - m[0]) * ::MT.game.opcodes + m[1] - AIController.GetOpsTillSuspend(); }

	function DumpRail(center, r, blocked = null, mark = null) {
		local cx = AIMap.GetTileX(center), cy = AIMap.GetTileY(center);
		AILog.Info("RAILMAP around " + Util.TileStr(center) + " x " + (cx - r) + ".." + (cx + r));
		for (local y = cy - r; y <= cy + r; y++) {
			local row = "";
			for (local x = cx - r; x <= cx + r; x++) {
				local t = AIMap.GetTileIndex(x, y);
				local c = ".";
				if (!AIMap.IsValidTile(t)) c = " ";
				else if (mark != null && (t in mark)) c = mark[t];
				else if (AIRail.IsLevelCrossingTile(t)) c = "#";
				else if (AIRail.IsRailStationTile(t)) c = "S";
				else if (AIRail.IsRailDepotTile(t)) c = "D";
				else if (AIBridge.IsBridgeTile(t)) c = "=";
				else if (AITunnel.IsTunnelTile(t)) c = "T";
				else if (AIRail.IsRailTile(t)) {
					local tr = AIRail.GetRailTracks(t);
					if (tr == AIRail.RAILTRACK_NE_SW) c = "-";
					else if (tr == AIRail.RAILTRACK_NW_SE) c = "|";
					else if (tr == AIRail.RAILTRACK_NW_NE) c = "n";
					else if (tr == AIRail.RAILTRACK_SW_SE) c = "u";
					else if (tr == AIRail.RAILTRACK_NW_SW) c = "/";
					else if (tr == AIRail.RAILTRACK_NE_SE) c = "\\";
					else c = "+";
				} else if (AIRoad.IsRoadTile(t)) c = "r";
				else if (AITile.IsWaterTile(t)) c = "~";
				else if (blocked != null) {
					if (t in blocked) c = "x";
					else if (!AITile.IsBuildable(t)) c = "h";
					else if (AITile.GetSlope(t) != AITile.SLOPE_FLAT) c = "s";
				}
				local sig = false;
				if (AIRail.IsRailTile(t) && !AIRail.IsRailStationTile(t) && !AIRail.IsRailDepotTile(t)) {
					for (local d = 0; d < 4; d++) {
						if (AIRail.GetSignalType(t, t + Geo.Offset(d)) != AIRail.SIGNALTYPE_NONE) sig = true;
					}
				}
				row += c + (sig ? "!" : " ");
			}
			AILog.Info("RAILMAP " + (y < 100 ? (y < 10 ? "  " : " ") : "") + y + " " + row);
		}
	}

	function SignAt(tile, text) {
		if (AIController.GetSetting("debug_signs") == 1) AISign.BuildSign(tile, text);
	}
};
