/*
 * CargoDistMonitor: reads the link graph results that OpenTTD exposes to scripts.
 *
 *   planned(A -> B) = AIStation.GetCargoPlannedVia(A, B): passengers per month the MCF solver routes from A
 *                     with B as next hop (passengers starting at A plus those transferring at A);
 *   waiting(A -> B) = AIStation.GetCargoWaitingVia(A, B): passengers on the platform for that next hop.
 *
 * A line's monthly capacity per direction is vehicles x seats x 30 / round trip days. Planned flow above the
 * capacity means the solver had to overload the link (it plans up to the demand), so the line needs vehicles;
 * passengers piling up for one next hop confirm it. With CargoDist off (manual distribution) every waiting
 * passenger is "via any station" and the monitor falls back to waiting cargo shared by the lines of a stop.
 */

class CargoDistMonitor {
	function Planned(from, via) {
		if (!AIStation.IsValidStation(from) || !AIStation.IsValidStation(via)) return 0;
		return AIStation.GetCargoPlannedVia(from, via, Util.pax);
	}

	function Waiting(from, via) {
		if (!AIStation.IsValidStation(from) || !AIStation.IsValidStation(via)) return 0;
		return AIStation.GetCargoWaitingVia(from, via, Util.pax);
	}

	function Rating(sid) {
		if (!AIStation.IsValidStation(sid) || !AIStation.HasCargoRating(sid, Util.pax)) return -1;
		return AIStation.GetCargoRating(sid, Util.pax);
	}

	function LineStats(line) {
		local a = line.sids[0], b = line.sids[1];
		local s = {plan_ab = 0, plan_ba = 0, wait_ab = 0, wait_ba = 0, n = line.VehicleCount(), rtt = line.Rtt(),
			cap_month = 0.0, util = 0.0, wait_ratio = 0.0, headway = 0.0, rating_a = this.Rating(a), rating_b = this.Rating(b)};
		if (::MT.game.CargoDistOn()) {
			s.plan_ab = this.Planned(a, b);
			s.plan_ba = this.Planned(b, a);
			s.wait_ab = this.Waiting(a, b);
			s.wait_ba = this.Waiting(b, a);
		} else {
			local na = max(1, ::MT.network.LinesAt(a).len()), nb = max(1, ::MT.network.LinesAt(b).len());
			s.wait_ab = AIStation.IsValidStation(a) ? AIStation.GetCargoWaiting(a, Util.pax) / na : 0;
			s.wait_ba = AIStation.IsValidStation(b) ? AIStation.GetCargoWaiting(b, Util.pax) / nb : 0;
		}
		if (s.n > 0 && s.rtt > 0) {
			s.cap_month = s.n * line.capacity * 30.0 / s.rtt;
			s.headway = s.rtt / s.n;
		}
		if (s.cap_month > 0) s.util = max(s.plan_ab, s.plan_ba) / s.cap_month;
		if (line.capacity > 0) s.wait_ratio = max(s.wait_ab, s.wait_ba).tofloat() / line.capacity;
		return s;
	}

	/*
	 * Interchange report for a station: passengers per month starting here, ending here and changing
	 * vehicles here (the value CargoDist adds by combining lines), plus the busiest next hops.
	 */
	function HubReport(sid) {
		if (!AIStation.IsValidStation(sid)) return null;
		local total = AIStation.GetCargoPlanned(sid, Util.pax);
		local start = AIStation.GetCargoPlannedFrom(sid, sid, Util.pax);
		local end = AIStation.GetCargoPlannedVia(sid, sid, Util.pax);
		local transfer = max(0, total - start - end);
		local vias = AIStationList_CargoPlannedByVia(sid, Util.pax);
		local top = "";
		foreach (v in Util.TopN(vias, 3)) {
			if (v == sid || !AIStation.IsValidStation(v)) continue;
			top += (top == "" ? "" : ", ") + AIStation.GetName(v) + " " + vias.GetValue(v);
		}
		return {total = total, start = start, end = end, transfer = transfer, top = top};
	}

	/*
	 * Transfer pairs worth a direct link: at hub `sid`, planned flow from origin X continuing to next hop Y,
	 * both other stations. A direct X-Y service saves the transfer wait and usually distance.
	 * Returns [[from_sid, via_sid, monthly], ...] sorted by volume.
	 */
	function TransferPairs(sid, min_monthly) {
		local out = [];
		if (!AIStation.IsValidStation(sid)) return out;
		local origins = AIStationList_CargoPlannedByFrom(sid, Util.pax);
		foreach (from, amount in origins) {
			if (from == sid || amount < min_monthly || !AIStation.IsValidStation(from)) continue;
			local vias = AIStationList_CargoPlannedFromByVia(sid, Util.pax, from);
			foreach (via, flow in vias) {
				if (via == sid || via == from || flow < min_monthly || !AIStation.IsValidStation(via)) continue;
				out.append([from, via, flow]);
			}
		}
		out.sort(function(a, b) { return b[2] - a[2]; });
		return out;
	}
}
