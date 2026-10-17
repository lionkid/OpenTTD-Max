/*
 * AirBuilder: airport type and site choice.
 *
 * Airports without a short strip (city, metropolitan, international, intercontinental) are preferred so that
 * large aircraft can use them. A small or commuter airport is only built when no larger type is available or
 * affordable, and then only small aircraft fly there. The site is the best passenger catchment on open land
 * near the town (never on houses), outside other companies' towns and buffers.
 */

class AirBuilder {
	types = null;        // airport types usable this month (Candidates)
	types_date = -1000;

	/* Types in order of preference that are available now and have a hangar (cached for a month). */
	function Candidates() {
		if (this.types != null && Util.Today() - this.types_date < 30) return this.types;
		local out = [];
		foreach (t in [AIAirport.AT_INTERCON, AIAirport.AT_INTERNATIONAL, AIAirport.AT_METROPOLITAN,
				AIAirport.AT_LARGE, AIAirport.AT_COMMUTER, AIAirport.AT_SMALL]) {
			if (!AIAirport.IsValidAirportType(t) || !AIAirport.IsAirportInformationAvailable(t)) continue;
			if (!::MT.engines.AnyAircraftFor(t)) continue;
			out.append(t);
		}
		this.types = out;
		this.types_date = Util.Today();
		return out;
	}

	/* Airport types for a town of `population`, largest first, that fit the budget. */
	function ChooseTypes(population, budget) {
		local out = [];
		foreach (t in this.Candidates()) {
			if (AIAirport.GetPrice(t) > budget) continue;
			if (population < 2500 && (t == AIAirport.AT_INTERCON || t == AIAirport.AT_INTERNATIONAL)) continue;
			if (population < 1200 && t == AIAirport.AT_METROPOLITAN) continue;
			out.append(t);
		}
		return out;
	}

	/* Top-left tile for an airport of `type` near `town`, or -1. */
	function FindSite(town, type, join_sid) {
		local w = AIAirport.GetAirportWidth(type), h = AIAirport.GetAirportHeight(type);
		local radius = AIAirport.GetAirportCoverageRadius(type);
		local center = AITown.GetLocation(town);
		local r = min(22, 8 + (AITown.GetPopulation(town) / 400).tointeger());
		local cx = Geo.X(center), cy = Geo.Y(center);
		local list = AITileList();
		list.AddRectangle(AIMap.GetTileIndex(max(2, cx - r - w), max(2, cy - r - h)),
			AIMap.GetTileIndex(min(AIMap.GetMapSizeX() - w - 2, cx + r), min(AIMap.GetMapSizeY() - h - 2, cy + r)));
		list.Valuate(AITile.IsBuildableRectangle, w, h);
		list.KeepValue(1);
		list.Valuate(AITile.GetCargoAcceptance, Util.pax, w, h, radius);
		list.KeepAboveValue(20);
		local tries = 0;
		foreach (t in Util.TopN(list, 60)) {
			if (++tries > 40) break;
			if (!this.SiteSafe(t, w, h)) continue;
			if (!::MT.nb.StationOk(t, w, h, radius)) continue;
			if (::MT.game.noise) {
				local nt = AIAirport.GetNearestTown(t, type);
				if (AIAirport.GetNoiseLevelIncrease(t, type) > AITown.GetAllowedNoise(nt)) continue;
			}
			local ok;
			{
				local tm = AITestMode();
				ok = AIAirport.BuildAirport(t, type, join_sid);
			}
			if (ok) return t;
		}
		return -1;
	}

	/* No flood risk anywhere under the airport or in a ring of one tile around it. */
	function SiteSafe(t, w, h) {
		for (local x = -1; x <= w; x++) {
			for (local y = -1; y <= h; y++) {
				local tile = t + x + y * Geo.MX;
				if (::MT.safety.IsFloodRisk(tile) || ::MT.safety.IsDangerTile(tile)) return false;
				if (x >= 0 && x < w && y >= 0 && y < h && !::MT.nb.TileFree(tile)) return false;
			}
		}
		return true;
	}

	function Build(tile, type, join_sid) {
		if (!AIAirport.BuildAirport(tile, type, join_sid)) {
			Log.Warn("BUILD", "airport at " + Util.TileStr(tile) + " failed: " + AIError.GetLastErrorString());
			if (AIError.GetLastError() == AIError.ERR_LOCAL_AUTHORITY_REFUSES) ::MT.planner.OnRefused(AIAirport.GetNearestTown(tile, type));
			return -1;
		}
		return AIStation.GetStationID(tile);
	}

	/* Terminals limit how many aircraft one airport serves without holding patterns. */
	function Terminals(type) {
		switch (type) {
			case AIAirport.AT_SMALL: return 2;
			case AIAirport.AT_COMMUTER: return 3;
			case AIAirport.AT_LARGE: return 3;
			case AIAirport.AT_METROPOLITAN: return 3;
			case AIAirport.AT_INTERNATIONAL: return 6;
			case AIAirport.AT_INTERCON: return 8;
		}
		return 2;
	}

	function TypeName(type) {
		switch (type) {
			case AIAirport.AT_SMALL: return "small";
			case AIAirport.AT_COMMUTER: return "commuter";
			case AIAirport.AT_LARGE: return "city";
			case AIAirport.AT_METROPOLITAN: return "metropolitan";
			case AIAirport.AT_INTERNATIONAL: return "international";
			case AIAirport.AT_INTERCON: return "intercontinental";
		}
		return "airport";
	}
}
