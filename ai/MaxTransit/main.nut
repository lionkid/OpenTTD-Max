/*
 * MaxTransit main controller: schedules the modules, handles events and saves the network.
 *
 * Loop (every 20 ticks):
 *   events -> safety first (crash response, audits, servicing)
 *   every 3 days: round-trip measurement, selling withdrawn vehicles
 *   every 15 days: CargoDist-driven fleet sizing
 *   every month: settings refresh, safety audit, renewals, transfer scan
 *   when the cooldown allows: one construction project (planner)
 */

require("lib/util.nut");
require("lib/settings.nut");
require("lib/finance.nut");
require("lib/safety.nut");
require("lib/timemodel.nut");
require("lib/engines.nut");
require("lib/pathfinder.nut");
require("lib/road.nut");
require("lib/air.nut");
require("lib/rail.nut");
require("lib/network.nut");
require("lib/cargodist.nut");
require("lib/fleet.nut");
require("lib/planner.nut");

MT <- {};

/* Called from long construction loops so that safety events and sales are not delayed by pathfinding. */
MT_last_housekeeping <- 0;
function MT_Housekeeping() {
	local today = AIDate.GetCurrentDate();
	if (today == ::MT_last_housekeeping || !("ai" in ::MT)) return;
	::MT_last_housekeeping = today;
	::MT.ai.HandleEvents();
	::MT.fleet.SellParked();
	if (today - ::MT.ai.last_3 >= 3) {
		::MT.fleet.MeasureTrips();
		::MT.ai.last_3 = today;
	}
}

class MaxTransit extends AIController {
	loaded = null;
	month_count = 0;
	last_3 = 0;
	dumped = null;

	constructor() {
		this.loaded = null;
		this.dumped = {};
	}
}

function MaxTransit::Init() {
	::MT.ai <- this;
	Geo.Init();
	Util.Init();
	AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
	::MT.game <- GameSnapshot();
	::MT.game.Refresh();
	::MT.finance <- Finance();
	::MT.safety <- SafetyOfficer();
	::MT.time <- TimeModel();
	::MT.time.Refresh();
	::MT.engines <- EngineAdvisor();
	::MT.bridges <- BridgeCache();
	::MT.road <- RoadBuilder(::MT.bridges);
	::MT.air <- AirBuilder();
	::MT.rail <- RailBuilder(::MT.bridges);
	::MT.network <- Network();
	::MT.cdist <- CargoDistMonitor();
	::MT.fleet <- Fleet();
	::MT.planner <- Planner();
}

function MaxTransit::NameCompany() {
	if (!AICompany.SetName("MaxTransit")) {
		for (local i = 2; i < 100; i++) if (AICompany.SetName("MaxTransit #" + i)) break;
	}
	AICompany.SetPresidentName("M. Transit");
}

function MaxTransit::Start() {
	this.Init();
	if (this.loaded != null) {
		this.Restore(this.loaded);
		this.loaded = null;
	} else {
		this.NameCompany();
	}
	/* Old vehicles break down more and lower station ratings: renew six months before the end of life. */
	AICompany.SetAutoRenewStatus(true);
	AICompany.SetAutoRenewMonths(-6);
	AICompany.SetAutoRenewMoney(100000);

	Log.Info("MAIN", "MaxTransit 1 started in " + Util.Year() + ". " + ::MT.game.Describe());
	if (Util.pax < 0) {
		Log.Error("MAIN", "no passenger cargo in this game; nothing to do");
		while (true) this.Sleep(1000);
	}
	if (!::MT.game.CargoDistOn()) {
		Log.Warn("CDIST", "passenger distribution is manual: lines are sized from waiting passengers and ratings. " +
			"Set Cargo distribution > passengers to symmetric to let MaxTransit plan from link flows.");
	}
	if (::MT.game.plane_crashes > 0) {
		Log.Info("SAFETY", "random landing crashes are enabled (" + ::MT.safety.LandingRisk(this.AnyPlane(), AIAirport.AT_LARGE) +
			" in 2^22 per landing); large aircraft at small airports are always refused (3276 in 2^22, any setting)");
	}

	local last_month = -1, last_year = -1, last_15 = 0;
	while (true) {
		this.HandleEvents();
		local today = AIDate.GetCurrentDate();
		local month = AIDate.GetMonth(today), year = AIDate.GetYear(today);
		if (today - this.last_3 >= 3) {
			::MT.fleet.MeasureTrips();
			::MT.fleet.SellParked();
			this.last_3 = today;
		}
		if (month != last_month) {
			this.Monthly();
			last_month = month;
		}
		if (today - last_15 >= 15) {
			::MT.fleet.Update();
			last_15 = today;
		}
		if (year != last_year) {
			if (last_year != -1) this.Yearly();
			last_year = year;
		}
		::MT.planner.Step();
		::MT.finance.Repay();
		this.Sleep(20);
	}
}

function MaxTransit::AnyPlane() {
	foreach (e, _ in AIEngineList(AIVehicle.VT_AIR)) return e;
	return -1;
}

function MaxTransit::Monthly() {
	this.month_count++;
	::MT.game.Refresh();
	::MT.time.Refresh();
	::MT.finance.UpdateReserve();
	if (::MT.finance.trouble && ::MT.finance.Cash() > ::MT.finance.Reserve() * 2) ::MT.finance.trouble = false;
	::MT.safety.CountDelivered();
	::MT.safety.ServiceRound();
	::MT.safety.Audit();
	::MT.fleet.HandleSafetyFlags();
	::MT.fleet.FinishClosures();
	::MT.fleet.Renew();
	if (this.month_count % 2 == 0 && ::MT.game.CargoDistOn()) ::MT.planner.ScanTransfers();
}

function MaxTransit::Yearly() {
	::MT.fleet.Modernise();
	this.Report();
}

function MaxTransit::Report() {
	local counts = [0, 0, 0], vehicles = [0, 0, 0];
	local profit = 0;
	foreach (line in ::MT.network.lines) {
		if (line.state == LINE_CLOSED) continue;
		counts[line.mode]++;
		foreach (v, _ in line.Vehicles()) {
			vehicles[line.mode]++;
			profit += AIVehicle.GetProfitLastYear(v);
		}
	}
	Log.Info("REPORT", "year " + (Util.Year() - 1) + ": lines bus " + counts[0] + " / rail " + counts[1] + " / air " + counts[2] +
		", vehicles " + vehicles[0] + " / " + vehicles[1] + " / " + vehicles[2] + ", vehicle profit " + Util.Money(profit) +
		", " + ::MT.finance.Status());
	Log.Info("REPORT", "safety: " + ::MT.safety.Report());
	Log.Info("REPORT", "time model calibration (measured/estimated): bus " + (::MT.time.calib[0] * 100).tointeger() +
		"%, rail " + (::MT.time.calib[1] * 100).tointeger() + "%, air " + (::MT.time.calib[2] * 100).tointeger() + "%");
	foreach (line in ::MT.network.Active()) {
		local s = ::MT.cdist.LineStats(line);
		local p = 0;
		foreach (v, _ in line.Vehicles()) p += AIVehicle.GetProfitLastYear(v);
		Log.Info("REPORT", line.Name() + ": " + s.n + " vehicles, round trip " + line.Rtt().tointeger() + " d (est " +
			line.est_rtt.tointeger() + "), headway " + s.headway.tointeger() + " d, planned " + s.plan_ab + "/" + s.plan_ba +
			" per month vs capacity " + s.cap_month.tointeger() + ", waiting " + s.wait_ab + "/" + s.wait_ba + ", profit " + Util.Money(p));
		local ta = ::MT.fleet.TimeAuditText(line);
		if (ta != "") Log.Info("REPORT", "  " + ta);
		line.time_audit = null;
	}
	if (::MT.game.CargoDistOn()) {
		foreach (town, hub in ::MT.network.hubs) {
			local r = ::MT.cdist.HubReport(hub.sid);
			if (r == null || r.total <= 0) continue;
			Log.Info("CDIST", AIStation.GetName(hub.sid) + ": " + r.total + " passengers/month planned, " + r.start + " start, " +
				r.end + " end, " + r.transfer + " change here" + (r.top == "" ? "" : "; next hops " + r.top));
		}
	}
}

function MaxTransit::HandleEvents() {
	while (AIEventController.IsEventWaiting()) {
		local e = AIEventController.GetNextEvent();
		switch (e.GetEventType()) {
			case AIEvent.ET_VEHICLE_CRASHED:
				::MT.safety.OnVehicleCrashed(AIEventVehicleCrashed.Convert(e));
				break;
			case AIEvent.ET_VEHICLE_LOST: {
				local v = AIEventVehicleLost.Convert(e).GetVehicleID();
				local line = ::MT.network.LineOfVehicle(v);
				Log.Warn("FLEET", "vehicle " + AIVehicle.GetName(v) + " is lost at " + Util.TileStr(AIVehicle.GetLocation(v)) +
					" heading for " + Util.TileStr(AIOrder.GetOrderDestination(v, AIOrder.ORDER_CURRENT)) + (line == null ? "" : " on " + line.Name()));
				if (line != null && line.mode == MODE_ROAD && line.state == LINE_ACTIVE) ::MT.fleet.Withdraw(v, "lost");
				if (line != null && line.mode == MODE_RAIL) {
					::MT.planner.CheckTracks(line);
					if (!(line.id in ::MT.ai.dumped)) {
						::MT.ai.dumped[line.id] <- true;
						Util.DumpRail(AIVehicle.GetLocation(v), 14);
					}
				}
				break;
			}
			case AIEvent.ET_VEHICLE_WAITING_IN_DEPOT: {
				local v = AIEventVehicleWaitingInDepot.Convert(e).GetVehicleID();
				if (v in ::MT.fleet.to_sell) {
					AIVehicle.SellVehicle(v);
					if (!AIVehicle.IsValidVehicle(v)) delete ::MT.fleet.to_sell[v];
				}
				break;
			}
			case AIEvent.ET_COMPANY_IN_TROUBLE: {
				local c = AIEventCompanyInTrouble.Convert(e).GetCompanyID();
				if (AICompany.IsMine(c)) {
					::MT.finance.trouble = true;
					Log.Warn("BANK", "company in trouble: construction paused");
				}
				break;
			}
			case AIEvent.ET_ENGINE_PREVIEW: {
				local ev = AIEventEnginePreview.Convert(e);
				if (ev.GetCargoType() == Util.pax && ev.AcceptPreview()) Log.Info("FLEET", "accepted preview of " + ev.GetName());
				break;
			}
			case AIEvent.ET_DISASTER_ZEPPELINER_CRASHED: {
				local sid = AIEventDisasterZeppelinerCrashed.Convert(e).GetStationID();
				Log.Warn("SAFETY", "zeppelin wreck on the runway of " + AIStation.GetName(sid) + ": the game holds landings until it is cleared");
				break;
			}
			case AIEvent.ET_DISASTER_ZEPPELINER_CLEARED: {
				local sid = AIEventDisasterZeppelinerCleared.Convert(e).GetStationID();
				Log.Info("SAFETY", "runway of " + AIStation.GetName(sid) + " cleared");
				break;
			}
			case AIEvent.ET_AIRCRAFT_DEST_TOO_FAR: {
				local v = AIEventAircraftDestTooFar.Convert(e).GetVehicleID();
				::MT.safety.Veto("out of range", "" + v);
				::MT.fleet.Withdraw(v, "destination beyond its range");
				break;
			}
		}
	}
}

function MaxTransit::Save() {
	if (!("network" in ::MT)) return {};
	local sell = [];
	foreach (v, _ in ::MT.fleet.to_sell) sell.append(v);
	local calib = [];
	foreach (c in ::MT.time.calib) calib.append((c * 1000).tointeger());
	local fails = {};
	foreach (k, d in ::MT.planner.failures) fails[k] <- d;
	return {
		v = 1,
		network = ::MT.network.Save(),
		to_sell = sell,
		calib = calib,
		failures = fails,
		victims = ::MT.safety.victims,
		incidents = ::MT.safety.incidents.len(),
		delivered = ::MT.safety.delivered,
		danger = ::MT.safety.danger_tiles,
		lengths = ::MT.engines.length_cache,
		bad_pairs = ::MT.engines.bad_pairs
	};
}

function MaxTransit::Load(version, data) {
	this.loaded = data;
}

function MaxTransit::Restore(data) {
	if (!("network" in data)) return;
	try {
		::MT.network.Load(data.network);
		foreach (v in data.to_sell) ::MT.fleet.to_sell[v] <- "restored";
		foreach (i, c in data.calib) if (i < 3) ::MT.time.calib[i] = c / 1000.0;
		foreach (k, d in data.failures) ::MT.planner.failures[k] <- d;
		::MT.safety.victims = data.victims;
		::MT.safety.delivered = data.delivered;
		foreach (t, r in data.danger) ::MT.safety.danger_tiles[t] <- r;
		foreach (e, l in data.lengths) ::MT.engines.length_cache[e] <- l;
		foreach (k, b in data.bad_pairs) ::MT.engines.bad_pairs[k] <- b;
		Log.Info("MAIN", "restored " + ::MT.network.lines.len() + " lines from the savegame");
	} catch (e) {
		Log.Error("MAIN", "could not restore saved data (" + e + "); continuing with what is on the map");
	}
}
