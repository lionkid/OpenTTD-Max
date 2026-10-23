/*
 * CargoDistMonitor: the link graph results OpenTTD exposes to scripts, for any cargo whose distribution is
 * not manual (passengers by default; freight only when the player turned it on):
 *   planned(A -> B) = AIStation.GetCargoPlannedVia(A, B, cargo): units per month routed from A via B;
 *   waiting(A -> B) = AIStation.GetCargoWaitingVia(A, B, cargo).
 * A line's monthly capacity per direction is vehicles x capacity x 30 / round trip days. With manual
 * distribution (every freight cargo by default), the monitor falls back to the cargo waiting at the source and
 * the source's monthly production that our station attracts.
 */

class CargoDistMonitor {
	function Planned(from, via, cargo) {
		if (!AIStation.IsValidStation(from) || !AIStation.IsValidStation(via)) return 0;
		return AIStation.GetCargoPlannedVia(from, via, cargo);
	}

	function Waiting(from, via, cargo) {
		if (!AIStation.IsValidStation(from) || !AIStation.IsValidStation(via)) return 0;
		return AIStation.GetCargoWaitingVia(from, via, cargo);
	}

	function Rating(sid, cargo) {
		if (!AIStation.IsValidStation(sid) || !AIStation.HasCargoRating(sid, cargo)) return -1;
		return AIStation.GetCargoRating(sid, cargo);
	}

	/* Monthly units an industry sends to our station (last month's transported share, or the rating share). */
	function SourceFlow(line) {
		local e = line.ends[0];
		if (e[0] != END_INDUSTRY || !AIIndustry.IsValidIndustry(e[1])) return 0;
		local prod = AIIndustry.GetLastMonthProduction(e[1], line.cargo);
		local moved = AIIndustry.GetLastMonthTransported(e[1], line.cargo);
		local n = max(1, ::TY.network.LinesFrom(e[1], line.cargo).len());
		if (moved > 0) return moved / n;
		local r = this.Rating(line.sids[0], line.cargo);
		return prod * (r < 0 ? 50 : r) / 100 / n;
	}

	function LineStats(line) {
		local a = line.sids[0], b = line.sids[1];
		local cargo = line.cargo;
		local s = {plan_ab = 0, plan_ba = 0, wait_ab = 0, wait_ba = 0, n = line.VehicleCount(), rtt = line.Rtt(),
			cap_month = 0.0, util = 0.0, wait_ratio = 0.0, headway = 0.0, rating_a = this.Rating(a, cargo), rating_b = this.Rating(b, cargo)};
		if (::TY.game.CargoDistOn(cargo)) {
			s.plan_ab = this.Planned(a, b, cargo);
			s.plan_ba = this.Planned(b, a, cargo);
			s.wait_ab = this.Waiting(a, b, cargo);
			s.wait_ba = this.Waiting(b, a, cargo);
		} else if (line.IsFreight()) {
			s.plan_ab = this.SourceFlow(line);
			s.wait_ab = AIStation.IsValidStation(a) ? AIStation.GetCargoWaiting(a, cargo) : 0;
		} else {
			local na = max(1, ::TY.network.LinesAt(a).len()), nb = max(1, ::TY.network.LinesAt(b).len());
			s.wait_ab = AIStation.IsValidStation(a) ? AIStation.GetCargoWaiting(a, cargo) / na : 0;
			s.wait_ba = AIStation.IsValidStation(b) ? AIStation.GetCargoWaiting(b, cargo) / nb : 0;
		}
		if (s.n > 0 && s.rtt > 0) {
			s.cap_month = s.n * line.capacity * 30.0 / s.rtt;
			s.headway = s.rtt / s.n;
		}
		if (s.cap_month > 0) s.util = max(s.plan_ab, s.plan_ba) / s.cap_month;
		if (line.capacity > 0) s.wait_ratio = max(s.wait_ab, s.wait_ba).tofloat() / line.capacity;
		return s;
	}

	/* Interchange report for a station (passengers). */
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
}
