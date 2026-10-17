/*
 * Landscape: what makes the network look planned rather than dropped on the map.
 *   - every tree a line cuts is replanted nearby (scenery >= 1), a few tiles away from the track so a
 *     second track or a siding never has to cut it again;
 *   - with scenery 2, stations in towns get a small green belt (which the town council likes as well);
 *   - the company has one livery and a headquarters in its first town;
 *   - the yearly report measures the looks: curves per 100 tiles of track, share of the second track that
 *     runs right next to the first, level crossings (always 0), trees replanted.
 */

class Landscape {
	planted = 0;        // trees planted in total
	owed = 0;           // trees cut and not yet replanted

	function Level() { return Util.Clamp(AIController.GetSetting("scenery"), 0, 2); }

	/* A tile a tree may go on: open, flat-ish land, not farmland, not right next to rails, roads or stations. */
	function TreeSpot(t, keep_clear) {
		if (!Geo.InMap(t, 2) || (t in keep_clear)) return false;
		if (!AITile.IsBuildable(t) || AITile.HasTreeOnTile(t) || AITile.IsFarmTile(t) || AIRoad.IsRoadTile(t)) return false;
		if (AITile.IsCoastTile(t) || AITile.IsSteepSlope(AITile.GetSlope(t))) return false;
		return true;
	}

	/*
	 * Replant `count` trees within 3-6 tiles of `tiles` (a path or a station). Tiles closer than 3 stay clear for
	 * a second track and sidings. Returns the number planted.
	 */
	function Replant(tiles, count) {
		if (this.Level() < 1 || count <= 0 || tiles.len() == 0) return 0;
		local near = {};
		foreach (t in tiles) {
			for (local dx = -2; dx <= 2; dx++) for (local dy = -2; dy <= 2; dy++) near[t + dx + dy * Geo.MX] <- true;
		}
		local n = 0, step = max(1, tiles.len() / max(1, count));
		for (local i = 0; i < tiles.len() && n < count; i += step) {
			local t = tiles[i];
			foreach (r in [3, 4, 5, 6]) {
				local placed = false;
				foreach (d in [[r, 0], [-r, 0], [0, r], [0, -r], [r, r], [-r, -r], [r, -r], [-r, r]]) {
					local c = t + d[0] + d[1] * Geo.MX;
					if (!this.TreeSpot(c, near)) continue;
					if (AITile.PlantTree(c)) { n++; placed = true; break; }
				}
				if (placed) break;
			}
		}
		this.planted += n;
		return n;
	}

	/* A ring of trees around a town station (scenery 2), on open land 2-3 tiles out. */
	function GreenBelt(station_tiles, max_trees) {
		if (this.Level() < 2 || station_tiles.len() == 0) return 0;
		local keep = {};
		foreach (t in station_tiles) {
			for (local dx = -1; dx <= 1; dx++) for (local dy = -1; dy <= 1; dy++) keep[t + dx + dy * Geo.MX] <- true;
		}
		local n = 0;
		foreach (t in station_tiles) {
			if (n >= max_trees) break;
			foreach (d in [[2, 0], [-2, 0], [0, 2], [0, -2], [3, 1], [-3, -1], [1, -3], [-1, 3]]) {
				local c = t + d[0] + d[1] * Geo.MX;
				if (n >= max_trees) break;
				if (this.TreeSpot(c, keep) && AITile.PlantTree(c)) n++;
			}
		}
		this.planted += n;
		return n;
	}

	/* Trees on a list of tiles (counted before construction, so the same number can be replanted). */
	function CountTrees(tiles) {
		local n = 0;
		foreach (t in tiles) if (AITile.HasTreeOnTile(t)) n++;
		return n;
	}

	/* One livery for everything: dark blue with a white stripe (the next free pair if another company has it). */
	function Livery() {
		local pairs = [[AICompany.COLOUR_DARK_BLUE, AICompany.COLOUR_WHITE], [AICompany.COLOUR_DARK_GREEN, AICompany.COLOUR_CREAM],
			[AICompany.COLOUR_MAUVE, AICompany.COLOUR_WHITE], [AICompany.COLOUR_GREY, AICompany.COLOUR_BLUE]];
		foreach (p in pairs) {
			if (AICompany.SetPrimaryLiveryColour(AICompany.LS_DEFAULT, p[0])) {
				AICompany.SetSecondaryLiveryColour(AICompany.LS_DEFAULT, p[1]);
				return;
			}
		}
	}

	/* Headquarters on open land at the edge of our first town (never on houses), once. */
	function BuildHQ(town) {
		if (AIMap.IsValidTile(AICompany.GetCompanyHQ(AICompany.COMPANY_SELF)) || !AITown.IsValidTown(town)) return;
		local center = AITown.GetLocation(town);
		local list = Geo.Square(center, 12);
		list.Valuate(AITile.IsBuildableRectangle, 2, 2);
		list.KeepValue(1);
		list.Valuate(AIMap.DistanceManhattan, center);
		list.KeepAboveValue(4);
		list.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
		local tries = 0;
		foreach (t, _ in list) {
			if (++tries > 30) break;
			if (!::MT.nb.TileFree(t) || ::MT.safety.IsFloodRisk(t)) continue;
			if (AICompany.BuildCompanyHQ(t)) {
				Log.Info("BUILD", "headquarters in " + Util.TownName(town) + " at " + Util.TileStr(t));
				return;
			}
		}
	}
}
