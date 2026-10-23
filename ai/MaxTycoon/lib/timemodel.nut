/*
 * Travel time and value model for every mode and cargo.
 *
 * Every vehicle type moves one tile in about 2048 / speed ticks, with speed as returned by AIEngine.GetMaxSpeed
 * (km-ish/h, aircraft already divided by the plane speed setting); a calibration factor per mode is learned
 * from measured round trips. Aircraft fly diagonally, so (dx, dy) takes max + min / 3 tile times; a diagonal
 * track piece takes 2/3 of a straight one; ships are measured like trains.
 *
 * Payment: AICargo.GetCargoIncome(cargo, distance, days) is the game's own formula (economy.cpp
 * GetTransportedGoodsIncome): it pays per unit and Manhattan distance between the stations, and drops with the
 * days in transit beyond the cargo's two thresholds, so fast vehicles earn more per unit.
 * Passengers travel both ways; freight goes one way and the vehicle returns empty.
 */

class TimeModel {
	stop_days = null;    // per mode: braking, dwell and acceleration for one stop
	load_days = null;    // per mode: extra dwell per unit of capacity (gradual loading)
	calib = null;        // per mode: measured / estimated running time (moving average)
	vot_pct = 0.25;      // value of one passenger-day in % of the fare (passengers prefer frequent service)
	headway_max = null;  // per mode: target maximum days between departures

	constructor() {
		this.stop_days = [2.0, 3.0, 5.0, 4.0];
		this.load_days = [0.02, 0.006, 0.006, 0.01];
		this.calib = [1.3, 1.1, 1.15, 1.3];
		this.headway_max = [8, 15, 15, 30];
	}

	function Refresh() {
		local dev = ::TY.levels.dev;
		this.headway_max = [[12, 25, 25, 45], [8, 15, 15, 30], [6, 12, 12, 25], [5, 10, 10, 20]][dev];
	}

	function DaysPerTile(speed) { return 2048.0 / (DAY_TICKS * max(1, speed)); }

	function AirTiles(a, b) {
		local dx = abs(AIMap.GetTileX(a) - AIMap.GetTileX(b)), dy = abs(AIMap.GetTileY(a) - AIMap.GetTileY(b));
		return max(dx, dy) + min(dx, dy) / 3.0;
	}

	function StopDays(mode, capacity) { return this.stop_days[mode] + capacity * this.load_days[mode]; }

	/* One-way days in the vehicle including one stop; `tiles` in straight-tile equivalents. */
	function OneWay(mode, speed, tiles, capacity = 0) {
		return tiles * this.DaysPerTile(speed) * this.calib[mode] + this.StopDays(mode, capacity);
	}

	function RoundTrip(mode, speed, tiles, capacity = 0) { return 2.0 * this.OneWay(mode, speed, tiles, capacity); }

	function Fare(cargo, dist, days) { return AICargo.GetCargoIncome(cargo, dist, max(0, days.tointeger())); }

	/* Door-to-door days: on average half a headway of waiting, then the ride. */
	function DoorToDoor(one_way, headway) { return one_way + headway / 2.0; }

	/* Learn from a measured round trip: only the running part (without stops) is rescaled. */
	function Calibrate(mode, estimated_rtt, measured_rtt, capacity = 0) {
		local stops = 2.0 * this.StopDays(mode, capacity);
		if (estimated_rtt <= stops + 1 || measured_rtt <= stops + 1) return;
		local ratio = this.calib[mode] * (measured_rtt - stops) / (estimated_rtt - stops);
		ratio = Util.Clamp(ratio, 0.8, 2.5);
		this.calib[mode] = 0.85 * this.calib[mode] + 0.15 * ratio;
	}

	/*
	 * Annual value of carrying `demand` units per month (per direction for passengers, from the source for
	 * freight) with an engine: payment minus running cost and depreciation, minus (passengers only) the value of
	 * their time waiting and riding. Options: speed, capacity, price, running, life_days, reliability, tiles,
	 * dist, demand, cargo, [max_n], [both_ways].
	 */
	function Evaluate(mode, o) {
		local both = ("both_ways" in o) ? o.both_ways : (o.cargo == Util.pax);
		local one_way = this.OneWay(mode, o.speed, o.tiles, o.capacity);
		local rtt = 2.0 * one_way;
		local cap_month = o.capacity * 30.0 / rtt;               // units per month per direction per vehicle
		local n = max(1, (o.demand / (cap_month * 0.8) + 0.999).tointeger());
		/* Frequency: add vehicles until the headway target is met while the load stays reasonable. */
		local hmax = this.headway_max[mode];
		while (rtt / n > hmax && o.demand / ((n + 1) * cap_month) >= 0.4) n++;
		if (("max_n" in o) && o.max_n > 0) n = min(n, o.max_n);
		local load = fmin(1.0, o.demand / (n * cap_month));
		local fare = this.Fare(o.cargo, o.dist, one_way);
		local units_year = (both ? 24.0 : 12.0) * n * cap_month * load;
		local avail = 1.0;
		local bd = ::TY.game.breakdowns;
		if (bd > 0) avail = (bd == 1 ? 0.88 : 0.76) + (bd == 1 ? 0.12 : 0.24) * o.reliability / 100.0;
		local income = units_year * fare * avail;
		local cost = n * (o.running + o.price * 365.0 / max(365, o.life_days));
		local headway = rtt / n;
		local time_cost = 0.0;
		if (o.cargo == Util.pax) time_cost = units_year * this.DoorToDoor(one_way, headway) * fare * this.vot_pct / 100.0;
		return {
			n = n, profit = income - cost, value = income - cost - time_cost, one_way = one_way, rtt = rtt,
			headway = headway, load = load, capex = n * o.price, fare = fare, units_year = units_year, income = income
		};
	}
}
