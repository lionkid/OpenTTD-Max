/*
 * MaxTycoon main controller: schedules the modules, handles events and saves the network.
 *
 * Loop (every 20 ticks):
 *   events
 *   every 3 days: round-trip measurement, selling withdrawn vehicles
 *   every 15 days: fleet sizing
 *   every month: settings refresh, audits, renewals, town care
 *   every quarter: score components, culling, phase (growth / harvest)
 *   when the cooldown allows: one construction project (planner)
 */

require("lib/util.nut");
require("lib/settings.nut");
require("lib/finance.nut");
require("lib/score.nut");
require("lib/safety.nut");
require("lib/timemodel.nut");
require("lib/engines.nut");
require("lib/pathfinder.nut");
require("lib/road.nut");
require("lib/air.nut");
require("lib/rail.nut");
require("lib/marine.nut");
require("lib/network.nut");
require("lib/cargodist.nut");
require("lib/industry.nut");
require("lib/town.nut");
require("lib/fleet.nut");
require("lib/planner.nut");

TY <- {};

/* Called from long construction loops so that events and sales are not delayed by pathfinding. */
TY_last_housekeeping <- 0;
function TY_Housekeeping() {
	local today = AIDate.GetCurrentDate();
	if (today == ::TY_last_housekeeping || !("ai" in ::TY)) return;
	::TY_last_housekeeping = today;
	::TY.ai.HandleEvents();
	::TY.fleet.SellParked();
	if (today - ::TY.ai.last_3 >= 3) {
		::TY.fleet.MeasureTrips();
		::TY.ai.last_3 = today;
	}
}

class MaxTycoon extends AIController {
	loaded = null;
	month_count = 0;
	last_3 = 0;
	last_quarter = -1;

	constructor() {
		this.loaded = null;
	}
}

function MaxTycoon::Init() {
	::TY.ai <- this;
	Geo.Init();
	Util.Init();
	AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
	::TY.levels <- Levels();
	::TY.levels.Refresh();
	::TY.game <- GameSnapshot();
	::TY.game.Refresh();
	::TY.finance <- Finance();
	::TY.score <- ScoreKeeper();
	::TY.safety <- SafetyOfficer();
	::TY.time <- TimeModel();
	::TY.time.Refresh();
	::TY.engines <- EngineAdvisor();
	::TY.bridges <- BridgeCache();
	::TY.road <- RoadBuilder(::TY.bridges);
	::TY.air <- AirBuilder();
	::TY.rail <- RailBuilder(::TY.bridges);
	::TY.marine <- MarineBuilder();
	::TY.network <- Network();
	::TY.cdist <- CargoDistMonitor();
	::TY.industry <- IndustryMap();
	::TY.towns <- TownCare();
	::TY.fleet <- Fleet();
	::TY.planner <- Planner();
	if (AIController.GetSetting("debug") == 1) this.CostProbe();
}

/* Debug: what a game call, a table lookup and a test build cost in opcodes (the budget is script_max_opcode_till_suspend per run). */
function MaxTycoon::CostProbe() {
	local t = AIMap.GetTileIndex(10, 10), tab = {}, x = 0, out = "";
	for (local i = 0; i < 100; i++) tab[i] <- i;
	local tests = [
		["100 GetSlope", function() : (t) { local y = 0; for (local i = 0; i < 100; i++) y += AITile.GetSlope(t); return y; }],
		["100 IsBuildable", function() : (t) { local y = 0; for (local i = 0; i < 100; i++) if (AITile.IsBuildable(t)) y++; return y; }],
		["100 table lookups", function() : (tab) { local y = 0; for (local i = 0; i < 100; i++) y += tab[i]; return y; }],
		["100 empty loops", function() { local y = 0; for (local i = 0; i < 100; i++) y++; return y; }],
		["20 test builds", function() : (t) { local tm = AITestMode(); local y = 0; for (local i = 0; i < 20; i++) if (AIRail.BuildRail(t, t + 1, t + 2)) y++; return y; }],
		["20 DistanceManhattan", function() : (t) { local y = 0; for (local i = 0; i < 20; i++) y += AIMap.DistanceManhattan(t, t + i); return y; }],
	];
	foreach (test in tests) {
		AIController.Sleep(1);   // a fresh budget
		local a = AIController.GetOpsTillSuspend();
		x += test[1]();
		local b = AIController.GetOpsTillSuspend();
		out += test[0] + " " + (a - b) + " ops; ";
	}
	Log.Info("DEBUG", "cost probe: " + out + "budget " + ::TY.game.opcodes + " per run (" + x + ")");

}

function MaxTycoon::NameCompany() {
	if (!AICompany.SetName("MaxTycoon")) {
		for (local i = 2; i < 100; i++) if (AICompany.SetName("MaxTycoon #" + i)) break;
	}
	AICompany.SetPresidentName("M. Tycoon");
}

function MaxTycoon::Start() {
	this.Init();
	if (this.loaded != null) {
		this.Restore(this.loaded);
		this.loaded = null;
	} else {
		this.NameCompany();
	}
	AICompany.SetAutoRenewStatus(true);
	AICompany.SetAutoRenewMonths(-6);
	AICompany.SetAutoRenewMoney(100000);

	Log.Info("MAIN", "MaxTycoon 1 started in " + Util.Year() + ": " + ::TY.levels.Describe());
	Log.Info("MAIN", ::TY.game.Describe());
	::TY.industry.Refresh();
	Log.Info("INDUSTRY", ::TY.industry.Describe());
	if (AIController.GetSetting("debug") == 1) ::TY.engines.DebugDump();

	local last_month = -1, last_year = -1, last_15 = 0;
	this.last_quarter = Util.Quarter();
	while (true) {
		this.HandleEvents();
		local today = AIDate.GetCurrentDate();
		local month = AIDate.GetMonth(today), year = AIDate.GetYear(today);
		if (today - this.last_3 >= 3) {
			::TY.fleet.MeasureTrips();
			::TY.fleet.SellParked();
			this.last_3 = today;
		}
		if (month != last_month) {
			if (last_month != -1) this.Monthly();
			last_month = month;
			local q = Util.Quarter(today);
			if (q != this.last_quarter) {
				this.last_quarter = q;
				this.Quarterly();
			}
		}
		if (today - last_15 >= 15) {
			::TY.fleet.Update();
			last_15 = today;
		}
		if (year != last_year) {
			if (last_year != -1) this.Yearly();
			last_year = year;
		}
		::TY.planner.Step();
		::TY.finance.Repay();
		this.Sleep(20);
	}
}

function MaxTycoon::Monthly() {
	this.month_count++;
	::TY.levels.Refresh();
	::TY.game.Refresh();
	::TY.time.Refresh();
	::TY.finance.UpdateReserve();
	if (::TY.finance.trouble && ::TY.finance.Cash() > ::TY.finance.Reserve() * 2) ::TY.finance.trouble = false;
	::TY.safety.ServiceRound();
	::TY.safety.Audit();
	::TY.fleet.HandleSafetyFlags();
	::TY.fleet.FinishClosures();
	::TY.fleet.Renew();
	::TY.towns.Monthly();
	if (this.month_count % 2 == 0) ::TY.industry.Refresh();
}

function MaxTycoon::Quarterly() {
	::TY.score.NewQuarter();
	::TY.fleet.Cull();
}

function MaxTycoon::Yearly() {
	::TY.fleet.Modernise();
	this.Report();
}

function MaxTycoon::Report() {
	local counts = array(MODE_COUNT, 0), vehicles = array(MODE_COUNT, 0);
	local profit = 0;
	foreach (line in ::TY.network.lines) {
		if (line.state == LINE_CLOSED) continue;
		counts[line.mode]++;
		foreach (v, _ in line.Vehicles()) {
			vehicles[line.mode]++;
			profit += AIVehicle.GetProfitLastYear(v);
		}
	}
	Log.Info("REPORT", "year " + (Util.Year() - 1) + ": lines road/rail/air/water " + counts[0] + "/" + counts[1] + "/" + counts[2] + "/" + counts[3] +
		", vehicles " + vehicles[0] + "/" + vehicles[1] + "/" + vehicles[2] + "/" + vehicles[3] + ", vehicle profit " + Util.Money(profit) +
		", " + ::TY.finance.Status());
	Log.Info("REPORT", "safety: " + ::TY.safety.Report());
	Log.Info("REPORT", "towns: " + ::TY.towns.Report());
	foreach (line in ::TY.network.Active()) {
		local s = ::TY.cdist.LineStats(line);
		local p = 0;
		foreach (v, _ in line.Vehicles()) p += AIVehicle.GetProfitLastYear(v);
		Log.Info("REPORT", line.Name() + ": " + s.n + " vehicles, round trip " + line.Rtt().tointeger() + " d (est " +
			line.est_rtt.tointeger() + "), headway " + s.headway.tointeger() + " d, flow " + s.plan_ab + "/" + s.plan_ba +
			" per month vs capacity " + s.cap_month.tointeger() + ", waiting " + s.wait_ab + "/" + s.wait_ba + ", profit " + Util.Money(p));
	}
}

function MaxTycoon::HandleEvents() {
	while (AIEventController.IsEventWaiting()) {
		local e = AIEventController.GetNextEvent();
		switch (e.GetEventType()) {
			case AIEvent.ET_VEHICLE_CRASHED:
				::TY.safety.OnVehicleCrashed(AIEventVehicleCrashed.Convert(e));
				break;
			case AIEvent.ET_VEHICLE_LOST: {
				local v = AIEventVehicleLost.Convert(e).GetVehicleID();
				local line = ::TY.network.LineOfVehicle(v);
				Log.Warn("FLEET", "vehicle " + AIVehicle.GetName(v) + " is lost at " + Util.TileStr(AIVehicle.GetLocation(v)) +
					" heading for " + Util.TileStr(AIOrder.GetOrderDestination(v, AIOrder.ORDER_CURRENT)) + (line == null ? "" : " on " + line.Name()));
				if (line != null) ::TY.fleet.OnLost(line, v);
				break;
			}
			case AIEvent.ET_VEHICLE_WAITING_IN_DEPOT: {
				local v = AIEventVehicleWaitingInDepot.Convert(e).GetVehicleID();
				if (v in ::TY.fleet.to_sell) {
					AIVehicle.SellVehicle(v);
					if (!AIVehicle.IsValidVehicle(v)) delete ::TY.fleet.to_sell[v];
				}
				break;
			}
			case AIEvent.ET_COMPANY_IN_TROUBLE: {
				local c = AIEventCompanyInTrouble.Convert(e).GetCompanyID();
				if (AICompany.IsMine(c)) {
					::TY.finance.trouble = true;
					Log.Warn("BANK", "company in trouble: construction paused");
				}
				break;
			}
			case AIEvent.ET_ENGINE_PREVIEW: {
				local ev = AIEventEnginePreview.Convert(e);
				if (ev.AcceptPreview()) Log.Info("FLEET", "accepted preview of " + ev.GetName());
				break;
			}
			case AIEvent.ET_INDUSTRY_CLOSE: {
				local ind = AIEventIndustryClose.Convert(e).GetIndustryID();
				::TY.planner.OnIndustryClosed(ind);
				break;
			}
			case AIEvent.ET_INDUSTRY_OPEN:
				::TY.industry.dirty = true;
				break;
			case AIEvent.ET_AIRCRAFT_DEST_TOO_FAR: {
				local v = AIEventAircraftDestTooFar.Convert(e).GetVehicleID();
				::TY.fleet.Withdraw(v, "destination beyond its range");
				break;
			}
			case AIEvent.ET_SUBSIDY_OFFER: {
				::TY.planner.OnSubsidy(AIEventSubsidyOffer.Convert(e).GetSubsidyID());
				break;
			}
		}
	}
}

function MaxTycoon::Save() {
	if (!("network" in ::TY)) return {};
	local sell = [];
	foreach (v, _ in ::TY.fleet.to_sell) sell.append(v);
	local calib = [];
	foreach (c in ::TY.time.calib) calib.append((c * 1000).tointeger());
	local fails = {};
	foreach (k, d in ::TY.planner.failures) fails[k] <- d;
	return {
		v = 1,
		network = ::TY.network.Save(),
		to_sell = sell,
		calib = calib,
		failures = fails,
		victims = ::TY.safety.victims,
		danger = ::TY.safety.danger_tiles,
		lengths = ::TY.engines.length_cache,
		bad_pairs = ::TY.engines.bad_pairs,
		towns = ::TY.towns.Save(),
		first_quarter = ::TY.score.first_quarter
	};
}

function MaxTycoon::Load(version, data) {
	this.loaded = data;
}

function MaxTycoon::Restore(data) {
	if (!("network" in data)) return;
	try {
		::TY.network.Load(data.network);
		foreach (v in data.to_sell) ::TY.fleet.to_sell[v] <- "restored";
		foreach (i, c in data.calib) if (i < MODE_COUNT) ::TY.time.calib[i] = c / 1000.0;
		foreach (k, d in data.failures) ::TY.planner.failures[k] <- d;
		::TY.safety.victims = data.victims;
		foreach (t, r in data.danger) ::TY.safety.danger_tiles[t] <- r;
		foreach (e, l in data.lengths) ::TY.engines.length_cache[e] <- l;
		foreach (k, b in data.bad_pairs) ::TY.engines.bad_pairs[k] <- b;
		if ("towns" in data) ::TY.towns.Load(data.towns);
		if ("first_quarter" in data) ::TY.score.first_quarter = data.first_quarter;
		Log.Info("MAIN", "restored " + ::TY.network.lines.len() + " lines from the savegame");
	} catch (e) {
		Log.Error("MAIN", "could not restore saved data (" + e + "); continuing with what is on the map");
	}
}
