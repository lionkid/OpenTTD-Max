/*
 * Economy: travel time and income model shared by every mode and cargo.
 *
 * Every vehicle type moves one tile in 2048 / speed ticks, with speed as AIEngine.GetMaxSpeed reports it
 * (aircraft already divided by the plane speed setting): trains and aircraft run their movement twice per
 * tick at speed, road vehicles and ships once per tick at twice the displayed speed, and a 16-step tile needs
 * 16 * 192 progress at speed * 3/4 per call (vehicle_base.h GetAdvanceSpeed / GetAdvanceDistance).
 * Income is AICargo.GetCargoIncome(cargo, Manhattan distance between the stations, days in transit), the
 * same function the game pays deliveries with.
 *
 * Freight is loaded with "full load", so a vehicle carries what the industry hands to the station (its
 * production times the station rating, about 70% with steady pickups) and returns empty; passengers travel
 * both ways. The value of a plan is the yearly profit after running costs and depreciation; the planner
 * divides it by the money the plan needs.
 */

const RATING_SHARE = 0.7;          // share of an industry's production a well served station receives

class Economy {
	stop_days = null;    // per mode: braking, dwell and acceleration for one stop
	load_days = null;    // per mode: extra dwell per unit of capacity (gradual loading)
	calib = null;        // per mode: measured / estimated running time (moving average)

	constructor() {
		this.stop_days = [2.0, 3.0, 5.0, 4.0];
		this.load_days = [0.02, 0.006, 0.006, 0.004];
		this.calib = [1.3, 1.15, 1.15, 1.25];
	}

	function DaysPerTile(speed) { return 2048.0 / (DAY_TICKS * max(1, speed)); }

	/* Aircraft fly diagonally: (dx, dy) takes max + min / 3 tile times. */
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

	function Income(cargo, dist, days) { return AICargo.GetCargoIncome(cargo, dist, max(0, days.tointeger())); }

	/* Learn from a measured round trip: only the running part (without stops) is rescaled. */
	function Calibrate(mode, estimated_rtt, measured_rtt, capacity = 0) {
		local stops = 2.0 * this.StopDays(mode, capacity);
		if (estimated_rtt <= stops + 1 || measured_rtt <= stops + 1) return;
		local ratio = this.calib[mode] * (measured_rtt - stops) / (estimated_rtt - stops);
		ratio = Util.Clamp(ratio, 0.8, 2.5);
		this.calib[mode] = 0.85 * this.calib[mode] + 0.15 * ratio;
	}

	/* Share of the time a vehicle is not broken down. */
	function Availability(reliability) {
		local bd = ::MT.game.breakdowns;
		if (bd <= 0) return 1.0;
		return (bd == 1 ? 0.88 : 0.76) + (bd == 1 ? 0.12 : 0.24) * reliability / 100.0;
	}

	/*
	 * Yearly result of a plan. o: {cargo, supply (units per month and direction), dist, tiles, speed, capacity,
	 * price, running, life_days, reliability, max_n (0: any), two_way}. Returns {n, carried, income, cost,
	 * profit, one_way, rtt, capex, fare, load}.
	 */
	function Evaluate(mode, o) {
		local one_way = this.OneWay(mode, o.speed, o.tiles, o.capacity);
		local rtt = 2.0 * one_way;
		local cap_month = o.capacity * 30.0 / rtt;               // units per month per direction per vehicle
		local n = max(1, (o.supply / (cap_month * 0.9) + 0.999).tointeger());
		if (o.max_n > 0) n = min(n, o.max_n);
		local carried = fmin(o.supply, n * cap_month);
		/* full load: the first unit waits while the vehicle fills; on average half the filling time */
		local fill = o.two_way ? 0.0 : fmin(rtt / n, 30.0 * o.capacity / fmax(1.0, o.supply)) / 2.0;
		local fare = this.Income(o.cargo, o.dist, one_way + fill);
		local income = 12.0 * carried * fare * this.Availability(o.reliability) * (o.two_way ? 2.0 : 1.0);
		local cost = n * (o.running + o.price * 365.0 / max(365, o.life_days));
		return {n = n, carried = carried, income = income, cost = cost, profit = income - cost, one_way = one_way, rtt = rtt,
			capex = n * o.price, fare = fare, load = carried / (n * cap_month)};
	}
}
