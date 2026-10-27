/*
 * Routes: one vehicle group each, two ends (a town or an industry), and what was built for them.
 *
 * Passenger routes are two-way and their stations in a town are joined into one hub station when the
 * station spread allows it (CargoDist then routes transfers inside it). Freight routes run one way: the
 * vehicles fill up at the source and come back empty.
 */

const ROUTE_ACTIVE = 1;
const ROUTE_CLOSING = 2;
const ROUTE_CLOSED = 3;

class Route {
	id = 0;
	mode = 0;
	state = ROUTE_ACTIVE;
	cargo = -1;
	two_way = false;       // passengers both ways; freight is loaded at end 0 only
	ends = null;           // [{type = END_TOWN / END_INDUSTRY, id}, ...]
	sids = null;           // [station a, station b] (-1 for an oil rig's own dock)
	tiles = null;          // order destination tiles [a, b]
	depots = null;         // depot or hangar tiles [a, b] (-1 where there is none)
	group = -1;
	engine = -1;
	wagon = -1;
	wagons = 0;
	railtype = -1;
	double_track = false;
	branch = false;        // rail: shares a station with another route through junctions
	signal_blocks = 0;
	track_tiles = null;    // rail: every track tile; road: the road path (for audits and cleanup)
	new_road = null;       // road: tiles where we laid new road (removed again when the route closes)
	sites = null;          // rail: station frames [a, b]
	p1 = null;             // rail: first track as tile * 4 + kind
	p2 = null;             // rail: second track (empty until the line is doubled)
	twin = null;           // rail: tiles kept free for the second track while the line is single
	dist = 0;              // Manhattan distance between the stations (cargo is paid on it)
	path_len = 0;          // straight-tile equivalents along the route
	capacity = 0;          // units per vehicle
	speed = 0;
	est_rtt = 0.0;         // estimated round trip days
	meas_rtt = 0.0;        // measured round trip days (0 until measured)
	cost = 0;              // money spent on infrastructure
	created = 0;
	last_change = 0;
	hi = 0;                // consecutive checks asking for more capacity
	lo = 0;                // consecutive checks asking for less
	probe = -1;            // vehicle used to measure round trips
	probe_order = -1;
	probe_date = 0;
	probe_seen = 0;
	feeder = false;        // bus shuttle inside one town
	note = "";
	upgrade_failed = 0;    // date of the last failed second-track attempt
	last_check = 0;        // date of the last track verification
	trees_cut = 0;         // trees removed by the construction (replanted nearby)
	turns = 0;             // 45 degree direction changes along the first track (looks report)
	losses = 0;            // consecutive yearly reviews with a loss
	est_profit = -1;       // yearly profit the plan expected, before learning (until compared with a real year)

	constructor() {
		this.ends = [{type = END_TOWN, id = -1}, {type = END_TOWN, id = -1}];
		this.sids = [-1, -1];
		this.tiles = [-1, -1];
		this.depots = [-1, -1];
		this.track_tiles = [];
		this.new_road = [];
		this.sites = [null, null];
		this.p1 = [];
		this.p2 = [];
		this.twin = [];
	}

	function ModeName() { return ["ROAD", "RAIL", "AIR", "SHIP"][this.mode]; }

	function EndName(i) {
		local e = this.ends[i];
		if (e.type == END_TOWN) return Util.TownName(e.id);
		return Util.IndustryName(e.id);
	}

	function Town(i) { return this.ends[i].type == END_TOWN ? this.ends[i].id : -1; }
	function Industry(i) { return this.ends[i].type == END_INDUSTRY ? this.ends[i].id : -1; }

	function Name() {
		local what = this.two_way ? (this.mode == MODE_ROAD ? "BUS" : this.ModeName()) : this.ModeName() + " " + Util.CargoName(this.cargo);
		return "R" + this.id + " " + what + " " + this.EndName(0) + (this.two_way ? " - " : " > ") + this.EndName(1);
	}

	function GroupName() {
		local s = "R" + this.id + " " + this.EndName(0) + (this.two_way ? "-" : ">") + this.EndName(1);
		return s.len() > 30 ? s.slice(0, 30) : s;
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
	/*
	 * Round trip without waiting, for the capacity of stations and airports: a measured trip that grew because
	 * the vehicles queue there would make the stop look less busy and let even more vehicles in.
	 */
	function FreeRtt() { return this.est_rtt > 0 ? this.est_rtt : this.Rtt(); }

	function VehicleType() {
		return [AIVehicle.VT_ROAD, AIVehicle.VT_RAIL, AIVehicle.VT_AIR, AIVehicle.VT_WATER][this.mode];
	}

	function Save() {
		return {
			id = this.id, mode = this.mode, state = this.state, cargo = this.cargo, two_way = this.two_way, ends = this.ends,
			sids = this.sids, tiles = this.tiles, depots = this.depots, group = this.group, engine = this.engine,
			wagon = this.wagon, wagons = this.wagons, railtype = this.railtype, double_track = this.double_track,
			signal_blocks = this.signal_blocks, branch = this.branch, track_tiles = this.track_tiles, new_road = this.new_road,
			sites = this.sites, p1 = this.p1, p2 = this.p2, twin = this.twin, dist = this.dist, path_len100 = (this.path_len * 100).tointeger(),
			capacity = this.capacity, speed = this.speed, est_rtt100 = (this.est_rtt * 100).tointeger(),
			meas_rtt100 = (this.meas_rtt * 100).tointeger(), cost = this.cost, created = this.created,
			last_change = this.last_change, feeder = this.feeder, note = this.note, upgrade_failed = this.upgrade_failed,
			trees_cut = this.trees_cut, turns = this.turns, losses = this.losses, est_profit = this.est_profit
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

class Routes {
	routes = null;
	hubs = null;           // town -> {sid, air_sid, air_tile, rail, dock_sid, shuttle}
	group_route = null;    // group -> route
	next_id = 1;

	constructor() {
		this.routes = [];
		this.hubs = {};
		this.group_route = {};
	}

	function Add(route) {
		route.id = this.next_id++;
		route.created = Util.Today();
		route.last_change = Util.Today();
		if (!AIGroup.IsValidGroup(route.group)) route.group = AIGroup.CreateGroup(route.VehicleType(), AIGroup.GROUP_INVALID);
		if (AIGroup.IsValidGroup(route.group)) {
			AIGroup.SetName(route.group, route.GroupName());
			this.group_route[route.group] <- route;
		}
		this.routes.append(route);
		return route;
	}

	function RouteOfVehicle(v) {
		if (!AIVehicle.IsValidVehicle(v)) return null;
		local g = AIVehicle.GetGroupID(v);
		return (g in this.group_route) ? this.group_route[g] : null;
	}

	function RouteById(id) {
		foreach (r in this.routes) if (r.id == id) return r;
		return null;
	}

	function Active() {
		local out = [];
		foreach (r in this.routes) if (r.state == ROUTE_ACTIVE) out.append(r);
		return out;
	}

	function Open() {
		local out = [];
		foreach (r in this.routes) if (r.state != ROUTE_CLOSED) out.append(r);
		return out;
	}

	function RoutesAt(sid) {
		local out = [];
		if (sid < 0) return out;
		foreach (r in this.routes) {
			if (r.state != ROUTE_CLOSED && (r.sids[0] == sid || r.sids[1] == sid)) out.append(r);
		}
		return out;
	}

	/* Direct passenger route between two towns in a mode (either direction). */
	function HasLink(a, b, mode) {
		foreach (r in this.routes) {
			if (r.state == ROUTE_CLOSED || r.mode != mode || !r.two_way) continue;
			if ((r.Town(0) == a && r.Town(1) == b) || (r.Town(0) == b && r.Town(1) == a)) return true;
		}
		return false;
	}

	function ServesTown(town) {
		foreach (r in this.routes) {
			if (r.state == ROUTE_CLOSED) continue;
			if (r.Town(0) == town || r.Town(1) == town) return true;
		}
		return false;
	}

	function ServesIndustry(ind) {
		foreach (r in this.routes) {
			if (r.state == ROUTE_CLOSED) continue;
			if (r.Industry(0) == ind || r.Industry(1) == ind) return true;
		}
		return false;
	}

	/* Our route that already takes `cargo` away from industry `ind`, or null. */
	function Carrying(ind, cargo) {
		foreach (r in this.routes) {
			if (r.state != ROUTE_CLOSED && r.Industry(0) == ind && r.cargo == cargo) return r;
		}
		return null;
	}

	function Hub(town) {
		if (!(town in this.hubs)) this.hubs[town] <- {sid = -1, air_sid = -1, air_tile = -1, rail = 0, shuttle = false};
		return this.hubs[town];
	}

	function HubStation(town) {
		if (!(town in this.hubs)) return -1;
		local sid = this.hubs[town].sid;
		return AIStation.IsValidStation(sid) ? sid : -1;
	}

	/*
	 * Tiles no new track may use: every rail terminus with its throat and the two corridor tiles in front of
	 * both rows. A single-track line's unbuilt arrival corridor ends in a throat piece pointing at it, so
	 * another line laid there would join the two networks.
	 */
	function ReservedRail() {
		local out = {};
		foreach (r in this.routes) {
			if (r.mode != MODE_RAIL || r.state == ROUTE_CLOSED) continue;
			foreach (site in r.sites) {
				if (site == null) continue;
				foreach (t in ::MT.rail.Footprint(site)) out[t] <- true;
				foreach (row in [0, 1]) out[::MT.rail.T(site, row, -5)] <- true;
			}
			foreach (t in r.twin) out[t] <- true;   // where the line's second track will go
		}
		return out;
	}

	/* Towns reachable from `town` through our passenger routes (the CargoDist component). */
	function InNetwork() {
		local out = {};
		foreach (r in this.routes) {
			if (r.state == ROUTE_CLOSED || !r.two_way) continue;
			out[r.Town(0)] <- true;
			out[r.Town(1)] <- true;
		}
		return out;
	}

	function Save() {
		local rs = [];
		foreach (r in this.routes) if (r.state != ROUTE_CLOSED) rs.append(r.Save());
		return {routes = rs, hubs = this.hubs, next_id = this.next_id};
	}

	function Load(t) {
		this.next_id = t.next_id;
		this.hubs = t.hubs;
		foreach (rt in t.routes) {
			local r = Route();
			r.Load(rt);
			this.routes.append(r);
			if (AIGroup.IsValidGroup(r.group)) this.group_route[r.group] <- r;
		}
	}
}
