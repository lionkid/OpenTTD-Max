/*
 * Network model: lines (one vehicle group each, two stations, one cargo) and hubs (the stations of a town or
 * an industry).
 *
 * A line's ends are towns (passengers, mail, goods, food and water delivered to a town) or industries
 * (freight); `ends` holds [kind, id] for each with kind END_TOWN or END_INDUSTRY. Stations of one town are
 * joined where the station spread allows it (transfers inside one station); every served station of a town
 * also counts for its growth, so a town that is to grow gets several separate ones (see TownCare).
 */

const LINE_ACTIVE = 1;
const LINE_CLOSING = 2;
const LINE_CLOSED = 3;

const END_TOWN = 0;
const END_INDUSTRY = 1;

class Line {
	id = 0;
	mode = 0;
	cargo = -1;
	state = LINE_ACTIVE;
	ends = null;           // [[kind, id], [kind, id]]
	towns = null;          // [town a, town b] (the nearest town of an industry end)
	sids = null;           // [station a, station b]
	tiles = null;          // order destination tiles [a, b]
	depots = null;         // depot, hangar or ship depot tiles [a, b]
	group = -1;
	engine = -1;
	wagon = -1;
	wagons = 0;
	railtype = -1;
	roadtype = -1;         // road vehicles: the road type (plain road or a tram type)
	double_track = false;
	branch = false;        // rail: shares a station with another line through junctions
	signal_blocks = 0;
	track_tiles = null;    // rail: every track tile; road: the planned road path; water: the sailed path
	buoys = null;          // water: buoy tiles along the route, in sailing order from end 0
	sites = null;          // rail: station frames [a, b]
	p1 = null;             // rail: first track as tile * 4 + kind
	p2 = null;             // rail: second track (empty until the line is doubled)
	dist = 0;              // Manhattan distance between the stations (payment is made on it)
	path_len = 0;          // straight-tile equivalents along the route
	capacity = 0;          // units per vehicle
	speed = 0;
	est_rtt = 0.0;         // estimated round trip days
	meas_rtt = 0.0;        // measured round trip days (0 until measured)
	created = 0;
	last_change = 0;
	hi = 0;                // consecutive checks asking for more capacity
	lo = 0;                // consecutive checks asking for less
	probe = -1;            // vehicle used to measure round trips
	probe_order = -1;
	probe_date = 0;
	probe_seen = 0;
	feeder = false;        // bus shuttle that only links two stations of one town
	loop = false;          // town circle line: one vehicle group visiting several stops of one town
	stops = null;          // loop: every stop tile in order
	stops_sids = null;     // loop: the station of every stop
	time_audit = null;
	note = "";
	upgrade_failed = 0;
	last_check = 0;
	last_load = null;      // [cargo units seen on the probe vehicle, date] for delivery counting

	constructor() {
		this.ends = [[END_TOWN, -1], [END_TOWN, -1]];
		this.towns = [-1, -1];
		this.sids = [-1, -1];
		this.tiles = [-1, -1];
		this.depots = [-1, -1];
		this.track_tiles = [];
		this.buoys = [];
		this.sites = [null, null];
		this.p1 = [];
		this.p2 = [];
		this.stops = [];
		this.stops_sids = [];
	}

	function ModeName() {
		if (this.mode == MODE_ROAD) return this.roadtype >= 0 && AIRoad.GetRoadTramType(this.roadtype) == AIRoad.ROADTRAMTYPES_TRAM ? "TRAM" :
			(this.cargo == Util.pax ? "BUS" : "TRUCK");
		return ["ROAD", "RAIL", "AIR", "SHIP"][this.mode];
	}

	function EndName(i) {
		local e = this.ends[i];
		if (e[0] == END_INDUSTRY) {
			local n = AIIndustry.IsValidIndustry(e[1]) ? AIIndustry.GetName(e[1]) : null;
			return n == null ? ("industry " + e[1]) : n;
		}
		return e[1] >= 0 ? Util.TownName(e[1]) : "?";
	}

	function Name() {
		return "L" + this.id + " " + this.ModeName() + " " + Util.CargoName(this.cargo) + " " + this.EndName(0) + "-" + this.EndName(1);
	}

	function IsFreight() { return this.cargo != Util.pax; }

	function Vehicles() {
		if (!AIGroup.IsValidGroup(this.group)) return AIList();
		return AIVehicleList_Group(this.group);
	}

	function VehicleCount() {
		if (!AIGroup.IsValidGroup(this.group)) return 0;
		return AIGroup.GetNumVehicles(this.group, this.VehicleType());
	}

	function Rtt() { return this.meas_rtt > 0 ? this.meas_rtt : this.est_rtt; }

	function VehicleType() { return Util.VehicleType(this.mode); }

	function Save() {
		return {
			id = this.id, mode = this.mode, cargo = this.cargo, state = this.state, ends = this.ends, towns = this.towns, sids = this.sids,
			tiles = this.tiles, depots = this.depots, group = this.group, engine = this.engine, wagon = this.wagon, wagons = this.wagons,
			railtype = this.railtype, roadtype = this.roadtype, double_track = this.double_track, signal_blocks = this.signal_blocks,
			branch = this.branch, track_tiles = this.track_tiles, buoys = this.buoys, sites = this.sites, p1 = this.p1, p2 = this.p2, dist = this.dist,
			path_len100 = (this.path_len * 100).tointeger(), capacity = this.capacity, speed = this.speed,
			est_rtt100 = (this.est_rtt * 100).tointeger(), meas_rtt100 = (this.meas_rtt * 100).tointeger(),
			created = this.created, last_change = this.last_change, feeder = this.feeder, loop = this.loop, stops = this.stops, stops_sids = this.stops_sids,
			note = this.note, upgrade_failed = this.upgrade_failed
		};
	}

	/* Savegames cannot hold floats: those fields are stored as hundredths. */
	function Load(t) {
		foreach (k, v in t) {
			if (k == "path_len100") this.path_len = v / 100.0;
			else if (k == "est_rtt100") this.est_rtt = v / 100.0;
			else if (k == "meas_rtt100") this.meas_rtt = v / 100.0;
			else if (k in this) this[k] = v;
		}
	}
}

class Network {
	lines = null;
	hubs = null;           // town -> {sid, air_sid, air_tile, air_type, rail, road_stops, catchment, shuttle, stations}
	ind_hubs = null;       // industry -> {sid, dock_sid, tiles}
	group_line = null;     // group -> line
	next_id = 1;

	constructor() {
		this.lines = [];
		this.hubs = {};
		this.ind_hubs = {};
		this.group_line = {};
	}

	function Add(line) {
		line.id = this.next_id++;
		line.created = Util.Today();
		line.last_change = Util.Today();
		if (!AIGroup.IsValidGroup(line.group)) {
			line.group = AIGroup.CreateGroup(line.VehicleType(), AIGroup.GROUP_INVALID);
		}
		if (AIGroup.IsValidGroup(line.group)) {
			local name = line.Name();
			if (name.len() > 30) name = name.slice(0, 30);
			AIGroup.SetName(line.group, name);
			this.group_line[line.group] <- line;
		}
		this.lines.append(line);
		return line;
	}

	function LineOfVehicle(v) {
		if (!AIVehicle.IsValidVehicle(v)) return null;
		local g = AIVehicle.GetGroupID(v);
		return (g in this.group_line) ? this.group_line[g] : null;
	}

	function LineById(id) {
		foreach (l in this.lines) if (l.id == id) return l;
		return null;
	}

	function Active() {
		local out = [];
		foreach (l in this.lines) if (l.state == LINE_ACTIVE) out.append(l);
		return out;
	}

	function ActiveCount() {
		local n = 0;
		foreach (l in this.lines) if (l.state == LINE_ACTIVE) n++;
		return n;
	}

	function LinesAt(sid) {
		local out = [];
		foreach (l in this.lines) {
			if (l.state != LINE_CLOSED && (l.sids[0] == sid || l.sids[1] == sid)) out.append(l);
		}
		return out;
	}

	/* A station is "served" for the score when a vehicle of an active line calls there. */
	function IsServed(sid) {
		foreach (l in this.lines) {
			if (l.state != LINE_ACTIVE) continue;
			if (l.sids[0] == sid || l.sids[1] == sid || (l.loop && Util.Contains(l.stops_sids, sid))) {
				if (l.VehicleCount() > 0) return true;
			}
		}
		return false;
	}

	function EndKey(kind, id) { return (kind == END_TOWN ? "t" : "i") + id; }

	/* Direct line between two ends carrying a cargo in a mode (either direction). */
	function HasLink(ka, ia, kb, ib, cargo, mode = -1) {
		foreach (l in this.lines) {
			if (l.state == LINE_CLOSED || l.cargo != cargo) continue;
			if (mode >= 0 && l.mode != mode) continue;
			local a = l.ends[0], b = l.ends[1];
			if ((a[0] == ka && a[1] == ia && b[0] == kb && b[1] == ib) || (a[0] == kb && a[1] == ib && b[0] == ka && b[1] == ia)) return true;
		}
		return false;
	}

	function HasTownLink(a, b, mode) { return this.HasLink(END_TOWN, a, END_TOWN, b, Util.pax, mode); }

	/* Is there a ship line between these two stations already (whatever ends it was planned for)? */
	function HasWaterLink(sa, sb) {
		foreach (l in this.lines) {
			if (l.state == LINE_CLOSED || l.mode != MODE_WATER) continue;
			if (Util.Contains(l.sids, sa) && Util.Contains(l.sids, sb)) return true;
		}
		return false;
	}

	/* Lines that take cargo from an industry (any mode). */
	function LinesFrom(ind, cargo) {
		local out = [];
		foreach (l in this.lines) {
			if (l.state == LINE_CLOSED || l.cargo != cargo) continue;
			if (l.ends[0][0] == END_INDUSTRY && l.ends[0][1] == ind) out.append(l);
		}
		return out;
	}

	function LinkCount(town) {
		local n = 0;
		foreach (l in this.lines) if (l.state != LINE_CLOSED && (l.towns[0] == town || l.towns[1] == town)) n++;
		return n;
	}

	function Hub(town) {
		if (!(town in this.hubs)) {
			this.hubs[town] <- {sid = -1, air_sid = -1, air_tile = -1, air_type = -1, rail = 0, road_stops = [], catchment = 0, shuttle = false,
				stations = [], dock_sid = -1};
		}
		return this.hubs[town];
	}

	function HubStation(town) {
		if (!(town in this.hubs)) return -1;
		local sid = this.hubs[town].sid;
		return AIStation.IsValidStation(sid) ? sid : -1;
	}

	function IndHub(ind) {
		if (!(ind in this.ind_hubs)) this.ind_hubs[ind] <- {sid = -1, dock_sid = -1, rail = 0, truck = 0};
		return this.ind_hubs[ind];
	}

	/* Our station at an industry (joined station for trucks and trains), or -1. */
	function IndStation(ind) {
		if (!(ind in this.ind_hubs)) return -1;
		local sid = this.ind_hubs[ind].sid;
		return AIStation.IsValidStation(sid) ? sid : -1;
	}

	/* Distinct served stations of a town (for its growth: five stations give the fastest growth). */
	function ServedStationsOfTown(town) {
		local seen = {}, n = 0;
		foreach (l in this.lines) {
			if (l.state != LINE_ACTIVE || l.VehicleCount() == 0) continue;
			local sids = l.loop ? l.stops_sids : l.sids;
			foreach (sid in sids) {
				if (!AIStation.IsValidStation(sid) || (sid in seen)) continue;
				if (AIStation.GetNearestTown(sid) != town) continue;
				seen[sid] <- true;
				n++;
			}
		}
		return n;
	}

	/*
	 * Tiles no new track may use: every rail terminus with its throat and the two corridor tiles in front of
	 * both rows.
	 */
	function ReservedRail() {
		local out = {};
		foreach (l in this.lines) {
			if (l.mode != MODE_RAIL || l.state == LINE_CLOSED) continue;
			foreach (site in l.sites) {
				if (site == null) continue;
				foreach (t in ::TY.rail.Footprint(site)) out[t] <- true;
				foreach (row in [0, 1]) out[::TY.rail.T(site, row, -5)] <- true;
			}
		}
		return out;
	}

	/* Towns reachable from `town` through our passenger lines (the CargoDist component). */
	function Component(town) {
		local seen = {};
		seen[town] <- true;
		local queue = [town];
		while (queue.len() > 0) {
			local t = queue.pop();
			foreach (l in this.lines) {
				if (l.state == LINE_CLOSED || l.cargo != Util.pax) continue;
				local other = -1;
				if (l.towns[0] == t) other = l.towns[1];
				else if (l.towns[1] == t) other = l.towns[0];
				if (other >= 0 && !(other in seen)) { seen[other] <- true; queue.append(other); }
			}
		}
		return seen;
	}

	function Save() {
		local ls = [];
		foreach (l in this.lines) ls.append(l.Save());
		return {lines = ls, hubs = this.hubs, ind_hubs = this.ind_hubs, next_id = this.next_id};
	}

	function Load(t) {
		this.next_id = t.next_id;
		this.hubs = t.hubs;
		if ("ind_hubs" in t) this.ind_hubs = t.ind_hubs;
		foreach (lt in t.lines) {
			local l = Line();
			l.Load(lt);
			this.lines.append(l);
			if (AIGroup.IsValidGroup(l.group)) this.group_line[l.group] <- l;
		}
	}
}
