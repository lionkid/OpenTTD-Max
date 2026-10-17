/*
 * Load monitor: how full a route's vehicles would be and how much cargo waits for them.
 *
 * Passenger routes with CargoDist read the link graph results: GetCargoPlannedVia(A, B) is the monthly flow
 * the solver routes from A with B as next hop, GetCargoWaitingVia(A, B) the passengers on the platform for
 * that hop. With CargoDist off, the waiting passengers of a stop are shared by the routes that call there.
 * Freight routes look at the cargo waiting at the source and the station rating there: a rating that sinks
 * means the vehicles do not come often enough, a pile of cargo means they are too few or too small.
 */

class LoadMonitor {
	function Rating(sid, cargo) {
		if (!AIStation.IsValidStation(sid) || !AIStation.HasCargoRating(sid, cargo)) return -1;
		return AIStation.GetCargoRating(sid, cargo);
	}

	function Waiting(sid, cargo) {
		if (!AIStation.IsValidStation(sid)) return 0;
		return AIStation.GetCargoWaiting(sid, cargo);
	}

	/*
	 * {n, rtt, cap_month, util, wait_a, wait_b, wait_ratio, headway, rating_a}: util is the planned flow (CargoDist)
	 * or the cargo produced for us (freight) against the monthly capacity of the vehicles.
	 */
	function Stats(route) {
		local a = route.sids[0], b = route.sids[1];
		local s = {n = route.VehicleCount(), rtt = route.Rtt(), cap_month = 0.0, util = 0.0, wait_a = 0, wait_b = 0,
			wait_ratio = 0.0, headway = 0.0, rating_a = this.Rating(a, route.cargo), plan = 0};
		if (s.n > 0 && s.rtt > 0) {
			s.cap_month = s.n * route.capacity * 30.0 / s.rtt;
			s.headway = s.rtt / s.n;
		}
		if (route.two_way) {
			if (::MT.game.CargoDistOn() && AIStation.IsValidStation(a) && AIStation.IsValidStation(b)) {
				s.plan = max(AIStation.GetCargoPlannedVia(a, b, route.cargo), AIStation.GetCargoPlannedVia(b, a, route.cargo));
				s.wait_a = AIStation.GetCargoWaitingVia(a, b, route.cargo);
				s.wait_b = AIStation.GetCargoWaitingVia(b, a, route.cargo);
			} else {
				local na = max(1, ::MT.routes.RoutesAt(a).len()), nb = max(1, ::MT.routes.RoutesAt(b).len());
				s.wait_a = this.Waiting(a, route.cargo) / na;
				s.wait_b = this.Waiting(b, route.cargo) / nb;
			}
		} else {
			s.wait_a = route.sids[0] >= 0 ? this.Waiting(a, route.cargo) : 0;
			local ind = route.Industry(0);
			if (ind >= 0 && AIIndustry.IsValidIndustry(ind)) {
				local prod = max(0, AIIndustry.GetLastMonthProduction(ind, route.cargo));
				local pct = route.sids[0] >= 0 ? (s.rating_a >= 0 ? s.rating_a : 70) : max(1, AIIndustry.GetLastMonthTransportedPercentage(ind, route.cargo));
				s.plan = prod * pct / 100;
				/* an oil rig's own dock: what the industry keeps back is what waits there */
				if (route.sids[0] < 0) s.wait_a = prod * (100 - pct) / 100;
			}
		}
		if (s.cap_month > 0) s.util = s.plan / s.cap_month;
		if (route.capacity > 0) s.wait_ratio = max(s.wait_a, s.wait_b).tofloat() / route.capacity;
		return s;
	}
}
