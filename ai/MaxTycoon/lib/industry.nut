/*
 * IndustryMap: the cargo chains of this game and where their links are on the map.
 *
 * OpenTTD 15.3 (industry_cmd.cpp, economy.cpp):
 *   - a primary industry produces its rate every 256 ticks; with the smooth economy its rate grows two times
 *     out of three in a month when more than 60% of last month's production was transported (five times out
 *     of six above 80%), and shrinks otherwise: a well served mine grows, a badly served one dies;
 *   - a processing industry turns every delivered unit into one unit of its product (all vanilla multipliers
 *     are 256/256) and closes after five years without production, so feeding it is what keeps it;
 *   - the share a station gets is about (rating + 1) / 256 of the production, split among the stations in
 *     the catchment by rating; a vehicle always loading there keeps the rating near its maximum;
 *   - delivered cargo goes to the nearest accepting industry in the station's catchment, or to houses when
 *     the station's acceptance for a town cargo (goods, food, water) reaches 8;
 *   - a company may fund processing industries anywhere (cost about 0.75 million at default prices) and raw
 *     ones only when construction.raw_industry_construction allows; the site must be flat and at least 15
 *     tiles from a conflicting type (a sawmill from a forest, a steel mill from an iron ore mine).
 */

class IndustryMap {
	types = null;        // type -> {name, raw, proc, produces, accepts, water, dock, buildable, prospect}
	producers = null;    // cargo -> [type]
	consumers = null;    // cargo -> [type]
	town_cargo = null;   // cargo -> true when houses accept it (goods, food, water, sweets, fizzy drinks)
	dirty = true;
	refreshed = -1000;
	prod_list = null;    // cargo -> [{ind, prod, moved, stations}] sorted by production
	acc_list = null;     // cargo -> [ind]
	closed = null;       // industry -> true (closed while we served it)

	constructor() {
		this.types = {};
		this.producers = {};
		this.consumers = {};
		this.town_cargo = {};
		this.prod_list = {};
		this.acc_list = {};
		this.closed = {};
		foreach (c in Util.cargos) {
			local te = AICargo.GetTownEffect(c);
			if (te == AICargo.TE_GOODS || te == AICargo.TE_FOOD || te == AICargo.TE_WATER) this.town_cargo[c] <- true;
		}
		foreach (t, _ in AIIndustryTypeList()) {
			if (!AIIndustryType.IsValidIndustryType(t)) continue;
			local prod = [], acc = [];
			foreach (c, _ in AIIndustryType.GetProducedCargo(t)) prod.append(c);
			foreach (c, _ in AIIndustryType.GetAcceptedCargo(t)) acc.append(c);
			this.types[t] <- {name = AIIndustryType.GetName(t), raw = AIIndustryType.IsRawIndustry(t), proc = AIIndustryType.IsProcessingIndustry(t),
				produces = prod, accepts = acc, water = AIIndustryType.IsBuiltOnWater(t), dock = AIIndustryType.HasDock(t),
				buildable = AIIndustryType.CanBuildIndustry(t), prospect = AIIndustryType.CanProspectIndustry(t),
				cost = AIIndustryType.GetConstructionCost(t)};
			foreach (c in prod) { if (!(c in this.producers)) this.producers[c] <- []; this.producers[c].append(t); }
			foreach (c in acc) { if (!(c in this.consumers)) this.consumers[c] <- []; this.consumers[c].append(t); }
		}
	}

	/* Cargo that houses accept (delivered to a town, not to an industry). */
	function IsTownCargo(c) { return c in this.town_cargo; }

	/* Is there anything on the map (or in the rules) that takes this cargo? */
	function HasConsumer(c) { return this.IsTownCargo(c) || (c in this.consumers); }

	/* Re-read the industries every other month (production figures change, industries open and close). */
	function Refresh() {
		this.prod_list = {};
		this.acc_list = {};
		foreach (c in Util.cargos) {
			if (c == Util.pax || c == Util.mail) continue;
			local out = [];
			foreach (ind, _ in AIIndustryList_CargoProducing(c)) {
				if (!AIIndustry.IsValidIndustry(ind)) continue;
				local p = AIIndustry.GetLastMonthProduction(ind, c);
				if (p < 0) continue;
				out.append({ind = ind, prod = p, moved = AIIndustry.GetLastMonthTransported(ind, c), stations = AIIndustry.GetAmountOfStationsAround(ind)});
			}
			out.sort(function(a, b) { return b.prod - a.prod; });
			this.prod_list[c] <- out;
			local acc = [];
			foreach (ind, _ in AIIndustryList_CargoAccepting(c)) if (AIIndustry.IsValidIndustry(ind)) acc.append(ind);
			this.acc_list[c] <- acc;
		}
		this.dirty = false;
		this.refreshed = Util.Today();
	}

	function Producers(c) { return (c in this.prod_list) ? this.prod_list[c] : []; }
	function Acceptors(c) { return (c in this.acc_list) ? this.acc_list[c] : []; }

	/* Nearest industry accepting cargo c to a tile (and its distance), or null. */
	function NearestAcceptor(c, tile, exclude = -1) {
		local best = null, bd = 1 << 30;
		foreach (ind in this.Acceptors(c)) {
			if (ind == exclude) continue;
			local d = AIIndustry.GetDistanceManhattanToTile(ind, tile);
			if (d < bd) { bd = d; best = ind; }
		}
		return best == null ? null : {ind = best, dist = bd};
	}

	/* Towns whose centre accepts cargo c (acceptance of a 3x3 at the centre with radius 3 reaches 8). */
	function TownsAccepting(c, limit = 12) {
		local list = AITownList();
		list.Valuate(AITown.GetPopulation);
		list.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);
		local out = [];
		foreach (town, pop in list) {
			if (out.len() >= limit) break;
			local t = AITown.GetLocation(town);
			if (AITile.GetCargoAcceptance(t, c, 1, 1, 3) >= 8) out.append(town);
		}
		return out;
	}

	/* Cargo of the whole chain behind a processing type: what it needs. */
	function Inputs(type) { return (type in this.types) ? this.types[type].accepts : []; }
	function Outputs(type) { return (type in this.types) ? this.types[type].produces : []; }

	/*
	 * A processing type for cargo c that could be funded near `tile` (the producer): the first flat site the
	 * game accepts in a ring 16-30 tiles away (industries conflict with their suppliers within 14 tiles).
	 * Returns {type, tile, cost} or null. Test mode only; the planner pays.
	 */
	function FundingSite(c, near) {
		if (!(c in this.consumers)) return null;
		local best = null;
		foreach (type in this.consumers[c]) {
			local info = this.types[type];
			if (!info.buildable || info.water || info.cost <= 0) continue;
			/* in town only: banks, water towers, toy shops cannot be placed by us in the open */
			local cx = Geo.X(near), cy = Geo.Y(near);
			local tries = 0;
			for (local r = 16; r <= 30 && tries < 400; r += 2) {
				for (local k = 0; k < 16 && tries < 400; k++) {
					local ang = k * 3.14159 * 2 / 16;
					local x = cx + (r * cos(ang)).tointeger(), y = cy + (r * sin(ang)).tointeger();
					if (x < 4 || y < 4 || x >= AIMap.GetMapSizeX() - 8 || y >= AIMap.GetMapSizeY() - 8) continue;
					local t = AIMap.GetTileIndex(x, y);
					if (!AITile.IsBuildable(t) || AITile.GetSlope(t) != AITile.SLOPE_FLAT) continue;
					tries++;
					local ok;
					{
						local tm = AITestMode();
						ok = AIIndustryType.BuildIndustry(type, t);
					}
					if (ok) return {type = type, tile = t, cost = info.cost};
				}
			}
		}
		return best;
	}

	function Describe() {
		local chains = "", n = 0;
		foreach (c in Util.cargos) {
			if (c == Util.pax || c == Util.mail) continue;
			local np = this.Producers(c).len(), na = this.Acceptors(c).len();
			local to = this.IsTownCargo(c) ? "towns" : (na + " industries");
			chains += (chains == "" ? "" : "; ") + Util.CargoName(c) + ": " + np + " producers -> " + to;
			n++;
		}
		return n + " cargo chains: " + chains;
	}
}
