/*
 * Network model: lines (one vehicle group each, two stations) and hubs (one interchange station per town).
 *
 * CargoDist routes passengers over the link graph by station, so every mode we run in a town is joined into
 * the same station whenever the station spread allows it: a transfer between bus, train and aircraft then
 * happens inside one station. Where an airport is too far to join, a short bus shuttle links the two stations.
 */

const LINE_ACTIVE = 1;
const LINE_CLOSING = 2;
const LINE_CLOSED = 3;

class Line {
	id = 0;
	mode = 0;
	state = LINE_ACTIVE;
	towns = null;          // [town a, town b]
	sids = null;           // [station a, station b]
	tiles = null;          // order destination tiles [a, b]
	depots = null;         // depot or hangar tiles [a, b]
	group = -1;
	engine = -1;
	wagon = -1;
	wagons = 0;
	railtype = -1;
	double_track = false;
	signal_blocks = 0;
	track_tiles = null;    // rail: every track tile; road: the planned road path (both for safety audits)
	sites = null;          // rail: station frames [a, b]
	p1 = null;             // rail: first track as tile * 4 + kind
	p2 = null;             // rail: second track (empty until the line is doubled)
	dist = 0;              // Manhattan distance between the stations (fares are paid on it)
	path_len = 0;          // straight-tile equivalents along the route
	capacity = 0;          // seats per vehicle
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
	probe_seen = 0;        // date of the last sample; a gap invalidates the trip being measured
	feeder = false;        // bus shuttle that only links two stations of one town
	time_audit = null;     // samples: [moving, dwell, waiting, broken, depot, speed sum, top speed sum]
	note = "";
	upgrade_failed = 0;    // date of the last failed second-track attempt

	constructor() {
		this.towns = [-1, -1];
		this.sids = [-1, -1];
		this.tiles = [-1, -1];
		this.depots = [-1, -1];
		this.track_tiles = [];
		this.sites = [null, null];
		this.p1 = [];
		this.p2 = [];
	}

	function ModeName() { return ["BUS", "RAIL", "AIR"][this.mode]; }

	function Name() {
		local a = this.towns[0] >= 0 ? Util.TownName(this.towns[0]) : "?";
		local b = this.towns[1] >= 0 ? Util.TownName(this.towns[1]) : "?";
		return "L" + this.id + " " + this.ModeName() + " " + a + "-" + b;
	}

	function Vehicles() {
		if (!AIGroup.IsValidGroup(this.group)) return AIList();
		return AIVehicleList_Group(this.group);
	}

	function VehicleCount() {
		if (!AIGroup.IsValidGroup(this.group)) return 0;
		return AIGroup.GetNumVehicles(this.group, this.VehicleType());
	}

	function Rtt() { return this.meas_rtt > 0 ? this.meas_rtt : this.est_rtt; }

	function VehicleType() {
		return [AIVehicle.VT_ROAD, AIVehicle.VT_RAIL, AIVehicle.VT_AIR][this.mode];
	}

	function Save() {
		return {
			id = this.id, mode = this.mode, state = this.state, towns = this.towns, sids = this.sids, tiles = this.tiles,
			depots = this.depots, group = this.group, engine = this.engine, wagon = this.wagon, wagons = this.wagons,
			railtype = this.railtype, double_track = this.double_track, signal_blocks = this.signal_blocks,
			track_tiles = this.track_tiles, sites = this.sites, p1 = this.p1, p2 = this.p2, dist = this.dist,
			path_len100 = (this.path_len * 100).tointeger(), capacity = this.capacity, speed = this.speed,
			est_rtt100 = (this.est_rtt * 100).tointeger(), meas_rtt100 = (this.meas_rtt * 100).tointeger(),
			created = this.created, last_change = this.last_change, feeder = this.feeder, note = this.note,
			upgrade_failed = this.upgrade_failed
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
	hubs = null;           // town -> {sid, air_sid, air_tile, air_type, rail, road_stops, catchment}
	group_line = null;     // group -> line
	next_id = 1;

	constructor() {
		this.lines = [];
		this.hubs = {};
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

	function LinesAt(sid) {
		local out = [];
		foreach (l in this.lines) {
			if (l.state != LINE_CLOSED && (l.sids[0] == sid || l.sids[1] == sid)) out.append(l);
		}
		return out;
	}

	/* Direct line between two towns in a mode (either direction). */
	function HasLink(a, b, mode) {
		foreach (l in this.lines) {
			if (l.state == LINE_CLOSED || l.mode != mode) continue;
			if ((l.towns[0] == a && l.towns[1] == b) || (l.towns[0] == b && l.towns[1] == a)) return true;
		}
		return false;
	}

	function LinkCount(town) {
		local n = 0;
		foreach (l in this.lines) if (l.state != LINE_CLOSED && (l.towns[0] == town || l.towns[1] == town)) n++;
		return n;
	}

	function Hub(town) {
		if (!(town in this.hubs)) {
			this.hubs[town] <- {sid = -1, air_sid = -1, air_tile = -1, air_type = -1, rail = 0, road_stops = [], catchment = 0, shuttle = false};
		}
		return this.hubs[town];
	}

	function HubStation(town) {
		if (!(town in this.hubs)) return -1;
		local sid = this.hubs[town].sid;
		return AIStation.IsValidStation(sid) ? sid : -1;
	}

	/* Towns reachable from `town` through our lines (the CargoDist component). */
	function Component(town) {
		local seen = {};
		seen[town] <- true;
		local queue = [town];
		while (queue.len() > 0) {
			local t = queue.pop();
			foreach (l in this.lines) {
				if (l.state == LINE_CLOSED) continue;
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
		return {lines = ls, hubs = this.hubs, next_id = this.next_id};
	}

	function Load(t) {
		this.next_id = t.next_id;
		this.hubs = t.hubs;
		foreach (lt in t.lines) {
			local l = Line();
			l.Load(lt);
			this.lines.append(l);
			if (AIGroup.IsValidGroup(l.group)) this.group_line[l.group] <- l;
		}
	}
}
