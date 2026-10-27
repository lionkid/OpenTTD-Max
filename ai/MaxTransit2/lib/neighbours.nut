/*
 * Neighbours: what other companies serve, so that we never take it from them.
 *
 * The script API cannot tell a human company from another AI (ScriptCompany has no such query and the
 * client list is GameScript only), so every other company is treated as a player whose towns, industries
 * and routes are theirs:
 *   - a town is theirs when they have a station in or around it, their headquarters stand there, or they
 *     hold its exclusive transport rights. Building a station makes the station's closest town record a
 *     rating for the company (station_cmd.cpp), so towns without a rating for anyone else are skipped
 *     without scanning the map;
 *   - an industry is theirs when they have a station in its catchment or cargo leaves it without us;
 *   - their stations and headquarters get a buffer we do not build in, our stations may not reach into the
 *     catchment of their towns, and our track and roads never run right next to their rails (that would
 *     block a second track or a siding they might want).
 * Claims are rechecked every few months and right before we build; if someone moves into one of our towns
 * later, we stop expanding there and leave the existing service as it is.
 */

const NB_CELL = 16;

class Neighbours {
	others = null;      // other valid companies
	hq = null;          // company -> HQ tile
	town_claim = null;  // town -> {by, since, why}
	ind_claim = null;   // industry -> {by, since, why}
	checked = null;     // "t<town>" / "i<industry>" -> date of the last check
	cells = null;       // cell key -> [tiles of their stations and HQs]
	their = null;       // tile -> company (their station tiles we know of)
	contested = null;   // town or "i<industry>" -> date we noticed a company arrive where we already were
	skipped = null;     // reason -> {key -> true}: what we left alone, for the report
	rail_cache = null;  // tile -> true if one of its neighbours is another company's rail (cleared monthly)

	constructor() {
		this.others = [];
		this.hq = {};
		this.town_claim = {};
		this.ind_claim = {};
		this.checked = {};
		this.cells = {};
		this.their = {};
		this.contested = {};
		this.skipped = {};
		this.rail_cache = {};
	}

	function Level() { return Util.Clamp(AIController.GetSetting("courtesy"), 0, 2); }

	/* Tiles kept free around their stations and headquarters. */
	function Buffer() { return [0, 5, 10][this.Level()]; }

	/* Radius of a town for claims: houses spread with the population. */
	function TownRadius(town) {
		local pop = max(0, AITown.GetPopulation(town));
		return 6 + min(16, (sqrt(pop.tofloat()) / 3).tointeger());
	}

	/* ---------------- companies ---------------- */

	function Refresh() {
		this.others = [];
		this.hq = {};
		for (local c = AICompany.COMPANY_FIRST; c < AICompany.COMPANY_LAST; c++) {
			if (AICompany.ResolveCompanyID(c) == AICompany.COMPANY_INVALID || AICompany.IsMine(c)) continue;
			this.others.append(c);
			local h = AICompany.GetCompanyHQ(c);
			if (AIMap.IsValidTile(h)) {
				this.hq[c] <- h;
				this.Mark(h, c);
			}
		}
		this.rail_cache = {};
	}

	function CompanyName(c) {
		local n = AICompany.ResolveCompanyID(c) != AICompany.COMPANY_INVALID ? AICompany.GetName(c) : null;
		return n == null ? ("company " + c) : n;
	}

	function Mark(tile, c) {
		if (tile in this.their) return;
		this.their[tile] <- c;
		local key = (Geo.X(tile) / NB_CELL) * 4096 + Geo.Y(tile) / NB_CELL;
		if (!(key in this.cells)) this.cells[key] <- [];
		this.cells[key].append(tile);
	}

	function Skip(reason, key) {
		if (!(reason in this.skipped)) this.skipped[reason] <- {};
		this.skipped[reason][key] <- true;
	}

	/* Their station tiles in a rectangle around tile c (radius r), recorded and counted per company. */
	function ScanStations(c, r) {
		local list = Geo.Square(c, r);
		list.Valuate(AITile.IsStationTile);
		list.KeepValue(1);
		return this.KeepTheirs(list);
	}

	/* From a list of station tiles, the companies other than us that own them ({company -> tiles}). */
	function KeepTheirs(list) {
		local found = {};
		if (list.Count() == 0) return found;
		list.Valuate(AITile.GetOwner);
		foreach (t, owner in list) {
			if (owner == AICompany.COMPANY_INVALID || owner == Util.me) continue;   // neutral (oil rig, buoy) or ours
			if (!(owner in found)) found[owner] <- 0;
			found[owner]++;
			this.Mark(t, owner);
		}
		return found;
	}

	/* ---------------- towns ---------------- */

	function Stale(key, days) { return !(key in this.checked) || Util.Today() - this.checked[key] > days; }

	/* Is `town` someone else's? Cached for 90 days unless `fresh`. */
	function TownTaken(town, fresh = false) {
		if (this.Level() == 0) return false;
		if (fresh || this.Stale("t" + town, 90)) this.CheckTown(town);
		return town in this.town_claim;
	}

	function CheckTown(town) {
		this.checked["t" + town] <- Util.Today();
		local was = town in this.town_claim;
		local claim = this.TownClaim(town);
		if (claim == null) {
			if (was) delete this.town_claim[town];
			return false;
		}
		if (!was) {
			claim.since <- Util.Today();
			this.town_claim[town] <- claim;
			if (::MT.routes.ServesTown(town) && !(town in this.contested)) {
				this.contested[town] <- Util.Today();
				Log.Info("COURTESY", this.CompanyName(claim.by) + " now also serves " + Util.TownName(town) +
					" (" + claim.why + "); we keep our existing service there but will not expand in this town");
			}
		}
		return true;
	}

	/* {by, why} when another company has a claim on the town, else null. */
	function TownClaim(town) {
		if (!AITown.IsValidTown(town)) return null;
		local ex = AITown.GetExclusiveRightsCompany(town);
		if (ex != AICompany.COMPANY_INVALID && ex != Util.me) return {by = ex, why = "exclusive transport rights"};
		local r = this.TownRadius(town);
		foreach (c, h in this.hq) {
			if (AITown.GetDistanceManhattanToTile(town, h) <= r + 4) return {by = c, why = "headquarters"};
		}
		local active = false;
		foreach (c in this.others) {
			if (AITown.GetRating(town, c) != AITown.TOWN_RATING_NONE) { active = true; break; }
		}
		/* A station between two towns rates with the closer one only; passengers carried from a town where we
		 * have nothing also give it away. */
		if (!active && Util.pax >= 0 && AITown.GetLastMonthSupplied(town, Util.pax) > 0 && !::MT.routes.ServesTown(town)) active = true;
		if (!active) return null;
		local found = this.ScanStations(AITown.GetLocation(town), r);
		local best = -1, n = 0;
		foreach (c, k in found) if (k > n) { n = k; best = c; }
		if (best >= 0) return {by = best, why = n + " station tile(s)"};
		/* Level 2: any activity (roads, removed trees, a station further out) is enough. */
		if (this.Level() >= 2) {
			foreach (c in this.others) {
				if (AITown.GetRating(town, c) != AITown.TOWN_RATING_NONE) return {by = c, why = "active in the town"};
			}
		}
		return null;
	}

	/* ---------------- industries ---------------- */

	function IndustryTaken(ind, fresh = false) {
		if (this.Level() == 0) return false;
		if (fresh || this.Stale("i" + ind, 90)) this.CheckIndustry(ind);
		return ind in this.ind_claim;
	}

	function CheckIndustry(ind) {
		this.checked["i" + ind] <- Util.Today();
		local was = ind in this.ind_claim;
		local claim = this.IndustryClaim(ind);
		if (claim == null) {
			if (was) delete this.ind_claim[ind];
			return false;
		}
		if (!was) {
			claim.since <- Util.Today();
			this.ind_claim[ind] <- claim;
			if (::MT.routes.ServesIndustry(ind) && !(("i" + ind) in this.contested)) {
				this.contested["i" + ind] <- Util.Today();
				Log.Info("COURTESY", this.CompanyName(claim.by) + " now also serves " + Util.IndustryName(ind) +
					" (" + claim.why + "); we keep our route but will not add another one there");
			}
		}
		return true;
	}

	function IndustryClaim(ind) {
		if (!AIIndustry.IsValidIndustry(ind)) return null;
		local serves = ::MT.routes.ServesIndustry(ind);
		local list = AITileList_IndustryProducing(ind, 5);
		if (list.Count() == 0) list = AITileList_IndustryAccepting(ind, 5);
		list.Valuate(AITile.IsStationTile);
		list.KeepValue(1);
		local found = this.KeepTheirs(list);
		foreach (c, k in found) return {by = c, why = k + " station tile(s) at the industry"};
		/* the industry may close while the scan above runs: the cargo list is then null */
		local produced = AIIndustry.IsValidIndustry(ind) ? AIIndustryType.GetProducedCargo(AIIndustry.GetIndustryType(ind)) : null;
		if (!serves && produced != null) {
			foreach (c, _ in produced) {
				if (AIIndustry.GetLastMonthTransported(ind, c) > 0 && !this.OurPickup(ind, c)) {
					return {by = this.others.len() > 0 ? this.others[0] : AICompany.COMPANY_INVALID, why = "its " + Util.CargoName(c) + " is already carried"};
				}
			}
		}
		return null;
	}

	/* One of our stations next to the industry (built for a neighbour) has a rating for the cargo: it picks it up. */
	function OurPickup(ind, cargo) {
		local list = AITileList_IndustryProducing(ind, 5);
		list.Valuate(AITile.IsStationTile);
		list.KeepValue(1);
		list.Valuate(AITile.GetOwner);
		list.KeepValue(Util.me);
		foreach (t, _ in list) if (AIStation.HasCargoRating(AIStation.GetStationID(t), cargo)) return true;
		return false;
	}

	/* ---------------- tiles ---------------- */

	/* Distance (Chebyshev) from tile t to the nearest of their stations/HQs we know, capped at `cap`. */
	function Distance(t, cap) { return this.RectDistance(Geo.X(t), Geo.Y(t), 1, 1, cap); }

	/* Distance from the w x h rectangle at (x0, y0) to the nearest of their stations/HQs, capped at `cap`. */
	function RectDistance(x0, y0, w, h, cap) {
		local x1 = x0 + w - 1, y1 = y0 + h - 1;
		local best = cap;
		for (local cx = max(0, x0 - cap) / NB_CELL; cx <= (x1 + cap) / NB_CELL; cx++) {
			for (local cy = max(0, y0 - cap) / NB_CELL; cy <= (y1 + cap) / NB_CELL; cy++) {
				local key = cx * 4096 + cy;
				if (!(key in this.cells)) continue;
				foreach (s in this.cells[key]) {
					local sx = Geo.X(s), sy = Geo.Y(s);
					local ddx = sx < x0 ? x0 - sx : (sx > x1 ? sx - x1 : 0);
					local ddy = sy < y0 ? y0 - sy : (sy > y1 ? sy - y1 : 0);
					local d = max(ddx, ddy);
					if (d < best) best = d;
				}
			}
		}
		return best;
	}

	/* May we build on tile t? (outside the buffer around their stations and headquarters) */
	function TileFree(t) {
		local b = this.Buffer();
		if (b <= 0) return true;
		return this.Distance(t, b + 1) > b;
	}

	/* Is one of t's neighbours another company's rail? (we never lay a line right along theirs) */
	function NextToTheirRail(t) {
		if (this.Level() == 0) return false;
		if (t in this.rail_cache) return this.rail_cache[t];
		local r = false;
		for (local d = 0; d < 4 && !r; d++) {
			local n = t + Geo.Offset(d);
			if ((AIRail.IsRailTile(n) || AIBridge.IsBridgeTile(n) || AITunnel.IsTunnelTile(n) || AIRail.IsRailStationTile(n) || AIRail.IsRailDepotTile(n)) &&
					AITile.GetOwner(n) != Util.me && AITile.GetOwner(n) != AICompany.COMPANY_INVALID && AITile.HasTransportType(n, AITile.TRANSPORT_RAIL)) r = true;
		}
		this.rail_cache[t] <- r;
		return r;
	}

	/*
	 * May a station of ours stand on the w x h rectangle at `tile` with catchment `radius`? Its catchment must not
	 * reach a station of theirs (plus the buffer) or the houses of a town that is theirs.
	 */
	function StationOk(tile, w, h, radius) {
		if (this.Level() == 0) return true;
		local x0 = Geo.X(tile), y0 = Geo.Y(tile);
		local reach = radius + this.Buffer();
		if (this.RectDistance(x0, y0, w, h, reach + 1) <= reach) return false;
		foreach (town, claim in this.town_claim) {
			local c = AITown.GetLocation(town);
			local r = this.TownRadius(town) + radius;
			local cx = Geo.X(c), cy = Geo.Y(c);
			local ddx = cx < x0 ? x0 - cx : (cx >= x0 + w ? cx - (x0 + w - 1) : 0);
			local ddy = cy < y0 ? y0 - cy : (cy >= y0 + h ? cy - (y0 + h - 1) : 0);
			if (max(ddx, ddy) <= r) return false;
		}
		return true;
	}

	/*
	 * A pickup station for `cargo` must not also cover an industry of theirs that produces it (cargo is split
	 * between the stations by rating, so we would take part of their load).
	 */
	function PickupOk(tile, w, h, radius, cargo, own_ind) {
		if (this.Level() == 0) return true;
		foreach (ind, claim in this.ind_claim) {
			if (ind == own_ind || !AIIndustry.IsValidIndustry(ind)) continue;
			if (AIIndustry.GetDistanceManhattanToTile(ind, tile) > radius + w + h + 8) continue;
			if (AIIndustry.GetLastMonthProduction(ind, cargo) <= 0) continue;
			local list = AITileList_IndustryProducing(ind, radius);
			local x0 = Geo.X(tile), y0 = Geo.Y(tile);
			for (local dx = 0; dx < w; dx++) for (local dy = 0; dy < h; dy++) {
				if (list.HasItem(AIMap.GetTileIndex(x0 + dx, y0 + dy))) return false;
			}
		}
		return true;
	}

	/* Forget the scan results so they are rebuilt from fresh checks (their stations come and go). */
	function Monthly() {
		this.Refresh();
		local today = Util.Today();
		if (AIDate.GetMonth(today) % 3 == 0) {
			this.cells = {};
			this.their = {};
			foreach (c, h in this.hq) this.Mark(h, c);
			/* re-scan the claims we know, so their stations are back in the buffer table */
			local towns = [];
			foreach (town, _ in this.town_claim) towns.append(town);
			foreach (town in towns) this.CheckTown(town);
			local inds = [];
			foreach (ind, _ in this.ind_claim) inds.append(ind);
			foreach (ind in inds) this.CheckIndustry(ind);
		}
	}

	/* Startup: look at every town once (cheap where nobody else has a rating). */
	function Survey() {
		if (this.Level() == 0) return;
		local n = 0;
		foreach (town, _ in AITownList()) {
			if (this.CheckTown(town)) n++;
		}
		if (n > 0 || this.others.len() > 0) {
			Log.Info("COURTESY", this.others.len() + " other compan" + (this.others.len() == 1 ? "y" : "ies") + "; " + n +
				" town(s) already served by them are off limits" + (this.Buffer() > 0 ? ", with " + this.Buffer() + " tiles kept free around their stations" : ""));
		}
	}

	function Report() {
		local towns = 0, inds = 0;
		foreach (t, _ in this.town_claim) towns++;
		foreach (i, _ in this.ind_claim) inds++;
		local s = "level " + this.Level() + ", " + this.others.len() + " other companies; their towns " + towns + ", their industries " + inds;
		local c = 0;
		foreach (k, _ in this.contested) c++;
		if (c > 0) s += "; places they joined after us " + c;
		local v = "";
		foreach (reason, keys in this.skipped) {
			local k = 0;
			foreach (_, __ in keys) k++;
			v += (v == "" ? "" : ", ") + reason + " x" + k;
		}
		if (v != "") s += "; left alone: " + v;
		return s;
	}
}
