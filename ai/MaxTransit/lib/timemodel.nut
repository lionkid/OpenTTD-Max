/*
 * Travel time model.
 *
 * Every vehicle type moves one tile in 2048 / speed ticks, with speed as returned by AIEngine.GetMaxSpeed
 * (km-ish/h, aircraft already divided by the plane speed setting):
 *   - trains run their movement handler twice per tick at speed (train_cmd.cpp Train::Tick),
 *   - road vehicles once per tick at twice the displayed speed (internal unit 0.5 km-ish/h),
 *   - aircraft twice per tick at speed / plane_speed (aircraft_cmd.cpp UpdateAircraftSpeed),
 *   and a 16-step tile needs 16 * 192 progress at speed * 3/4 per call (vehicle_base.h).
 * Aircraft fly diagonally, so (dx, dy) takes max + min / 3 tile times; a diagonal track piece takes 2/3 of a
 * straight one. Passenger fares lose 1/255 for every 2.5 days in a vehicle (economy.cpp), so time is money
 * twice over: the fare drops and the station rating drops when pickups are rare.
 */

class TimeModel {
	stop_days = null;    // per mode: braking, dwell and acceleration for one stop
	load_days = null;    // per mode: extra dwell per seat (gradual loading)
	calib = null;        // per mode: measured / estimated running time (moving average)
	vot_pct = 0.5;       // extra value of one passenger-day, in % of the fare ("frequency" setting)
	headway_max = null;  // per mode: target maximum days between departures

	constructor() {
		this.stop_days = [2.0, 3.0, 5.0];
		this.load_days = [0.02, 0.006, 0.006];
		this.calib = [1.3, 1.1, 1.15];
		this.headway_max = [6, 12, 15];
	}

	function Refresh() {
		local f = Util.Clamp(AIController.GetSetting("frequency"), 0, 2);
		this.vot_pct = [0.25, 0.5, 1.0][f];
		this.headway_max = [[10, 20, 25], [6, 12, 15], [4, 8, 10]][f];
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

	function Fare(dist, days) { return AICargo.GetCargoIncome(Util.pax, dist, max(0, days.tointeger())); }

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
	 * Annual value of serving `demand` passengers per month and direction with an engine:
	 * fares minus running cost and depreciation, minus the value of passenger time (waiting + riding).
	 */
	function Evaluate(mode, o) {
		local one_way = this.OneWay(mode, o.speed, o.tiles, o.capacity);
		local rtt = 2.0 * one_way;
		local cap_month = o.capacity * 30.0 / rtt;               // seats per month per direction per vehicle
		local n = max(1, (o.demand / (cap_month * 0.8) + 0.999).tointeger());
		/* Frequency: add vehicles until the headway target is met while the load stays above 40%. */
		local hmax = this.headway_max[mode];
		while (rtt / n > hmax && o.demand / ((n + 1) * cap_month) >= 0.4) n++;
		/* a single-track railway runs one train: demand beyond its seats is not carried */
		if (("max_n" in o) && o.max_n > 0) n = min(n, o.max_n);
		local load = fmin(1.0, o.demand / (n * cap_month));
		local fare = this.Fare(o.dist, one_way);
		local pax_year = 24.0 * n * cap_month * load;
		local avail = 1.0;
		local bd = ::MT.game.breakdowns;
		if (bd > 0) avail = (bd == 1 ? 0.88 : 0.76) + (bd == 1 ? 0.12 : 0.24) * o.reliability / 100.0;
		local income = pax_year * fare * avail;
		local cost = n * (o.running + o.price * 365.0 / max(365, o.life_days));
		local headway = rtt / n;
		local time_cost = pax_year * this.DoorToDoor(one_way, headway) * fare * this.vot_pct / 100.0;
		return {
			n = n, profit = income - cost, value = income - cost - time_cost, one_way = one_way, rtt = rtt,
			headway = headway, load = load, capex = n * o.price, fare = fare, pax_year = pax_year
		};
	}
}
