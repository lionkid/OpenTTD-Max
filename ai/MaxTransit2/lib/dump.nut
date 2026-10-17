/*
 * Developer tool: a picture of the map in the AI log (setting dump_map). tools/ai/render_map.py turns the
 * last dump of a log into a top-down image: terrain, water, houses, our tracks, roads, stations and signals,
 * and other companies' stations. It exists because the null video driver cannot take screenshots.
 */

MapDump <- {
	function Line(kind, items) {
		local s = "";
		foreach (i, it in items) {
			s += (s == "" ? "" : ";") + it;
			if (s.len() > 900) { AILog.Info("MAPDUMP " + kind + " " + s); s = ""; }
		}
		if (s != "") AILog.Info("MAPDUMP " + kind + " " + s);
	}

	terrain_done = false,

	/*
	 * The network goes into the log every year, the terrain (towns grow) the first time and then every five
	 * years: it costs the AI weeks of its time on a 256 x 256 map.
	 */
	function Run() {
		local mx = AIMap.GetMapSizeX(), my = AIMap.GetMapSizeY();
		if (mx * my > 300000) {
			AILog.Info("MAPDUMP skipped: the map is too large for the dump (valuators over the whole map hit the CPU limit)");
			return;
		}
		AILog.Info("MAPDUMP size " + mx + " " + my + " " + Util.DateStr(Util.Today()));
		if (!MapDump.terrain_done || Util.Year() % 5 == 4) MapDump.Terrain(mx, my);
		MapDump.terrain_done = true;
		MapDump.Network(mx, my);
	}

	function Terrain(mx, my) {
		local digits = "0123456789abcdefghijklmnopqrstuvwxyz";
		for (local y = 0; y < my; y++) {
			local row = "";
			for (local x = 0; x < mx; x++) {
				local t = AIMap.GetTileIndex(x, y);
				if (AITile.IsWaterTile(t)) row += "~";
				else if (AITile.IsHouseTile(t)) row += "h";
				else if (AIIndustry.IsValidIndustry(AIIndustry.GetIndustryID(t))) row += "i";
				else if (AIRoad.IsRoadTile(t) && !Util.IsMine(t)) row += "r";
				else {
					local h = Util.Clamp(AITile.GetMinHeight(t), 0, 35);   // -1 on the void tiles at the map edge
					row += digits.slice(h, h + 1);
				}
			}
			AILog.Info("MAPDUMP row " + y + " " + row);
			if (y % 32 == 0) MT_Housekeeping();
		}
	}

	function Network(mx, my) {
		local all = AITileList();
		all.AddRectangle(AIMap.GetTileIndex(1, 1), AIMap.GetTileIndex(mx - 2, my - 2));
		all.Valuate(AITile.GetOwner);
		local rail = [], road = [], stations = [], signals = [], theirs = [], their_rail = [];
		foreach (t, owner in all) {
			local x = AIMap.GetTileX(t), y = AIMap.GetTileY(t);
			if (owner == Util.me) {
				if (AITile.IsStationTile(t)) stations.append(x + "," + y);
				else if (AIRail.IsRailDepotTile(t) || AIRoad.IsRoadDepotTile(t) || AIMarine.IsWaterDepotTile(t)) stations.append(x + "," + y + ",d");
				else if (AIBridge.IsBridgeTile(t) || AITunnel.IsTunnelTile(t)) rail.append(x + "," + y + "," + (AITile.HasTransportType(t, AITile.TRANSPORT_RAIL) ? "b" : "B"));
				else if (AIRail.IsRailTile(t)) {
					rail.append(x + "," + y + "," + AIRail.GetRailTracks(t));
					for (local d = 0; d < 4; d++) {
						if (AIRail.GetSignalType(t, t + Geo.Offset(d)) != AIRail.SIGNALTYPE_NONE) { signals.append(x + "," + y); break; }
					}
				} else if (AIRoad.IsRoadTile(t)) road.append(x + "," + y);
			} else if (owner != AICompany.COMPANY_INVALID) {
				if (AITile.IsStationTile(t)) theirs.append(x + "," + y);
				else if (AIRail.IsRailTile(t)) their_rail.append(x + "," + y + "," + AIRail.GetRailTracks(t));
			}
		}
		MapDump.Line("rail", rail);
		MapDump.Line("road", road);
		MapDump.Line("station", stations);
		MapDump.Line("signal", signals);
		MapDump.Line("theirs", theirs);
		MapDump.Line("theirrail", their_rail);
		local towns = [];
		foreach (town, _ in AITownList()) {
			local c = AITown.GetLocation(town);
			towns.append(AIMap.GetTileX(c) + "," + AIMap.GetTileY(c) + "," + Util.TownName(town));
		}
		MapDump.Line("town", towns);
	}
};
