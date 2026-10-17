/*
 * MaxTransit2 main controller: schedules the modules, handles events and saves the network.
 *
 * Loop (every 20 ticks):
 *   events -> sell withdrawn vehicles
 *   every 3 days: round-trip measurement
 *   every 7 days: fleet sizing
 *   every month: settings, neighbours, safety audit, closures, renewals
 *   every year: money review, modernisation, report
 *   when the cooldown allows: one construction project (planner)
 */

require("lib/util.nut");
require("lib/settings.nut");
require("lib/finance.nut");
require("lib/neighbours.nut");
require("lib/safety.nut");
require("lib/economy.nut");
require("lib/engines.nut");
require("lib/pathfinder.nut");
require("lib/landscape.nut");
require("lib/road.nut");
require("lib/rail.nut");
require("lib/air.nut");
require("lib/water.nut");
require("lib/routes.nut");
require("lib/cargodist.nut");
require("lib/fleet.nut");
require("lib/planner.nut");
require("lib/projects.nut");
require("lib/dump.nut");

MT <- {};

/*
 * Called from long construction loops (path searches, laying track) so that events, sales and the yearly review
 * are not held up for weeks: a construction across New Year used to skip a whole yearly review.
 */
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
	::MT.ai.Periodic(false);
}

class MaxTransit2 extends AIController {
	loaded = null;
	last_3 = 0;
	last_7 = 0;
	last_month = -1;
	last_year = -1;
	in_periodic = false;   // a map dump inside the yearly work calls the housekeeping again
	network_due = false;   // monthly work that changes the network waits for the main loop

	constructor() {
		this.loaded = null;
	}
}

function MaxTransit2::Init() {
	::MT.ai <- this;
	Geo.Init();
	Util.Init();
	AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
	::MT.game <- GameSnapshot();
	::MT.game.Refresh();
	::MT.finance <- Finance();
	::MT.routes <- Routes();
	::MT.nb <- Neighbours();
	::MT.safety <- SafetyOfficer();
	::MT.economy <- Economy();
	::MT.engines <- EngineAdvisor();
	::MT.bridges <- BridgeCache();
	::MT.landscape <- Landscape();
	::MT.road <- RoadBuilder(::MT.bridges);
	::MT.rail <- RailBuilder(::MT.bridges);
	::MT.air <- AirBuilder();
	::MT.water <- WaterBuilder();
	::MT.monitor <- LoadMonitor();
	::MT.fleet <- Fleet();
	::MT.planner <- Planner();
	::MT.projects <- Projects();
}

function MaxTransit2::NameCompany() {
	if (!AICompany.SetName("MaxTransit 2")) {
		for (local i = 2; i < 100; i++) if (AICompany.SetName("MaxTransit 2 #" + i)) break;
	}
	AICompany.SetPresidentName("M. Transit");
	::MT.landscape.Livery();
}

function MaxTransit2::Start() {
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

	Log.Info("MAIN", "MaxTransit2 1 started in " + Util.Year() + ". " + ::MT.game.Describe());
	::MT.nb.Refresh();
	::MT.nb.Survey();
	if (::MT.game.allow[MODE_AIR] && ::MT.game.pax_on) {
		if (!::MT.safety.FlyingAllowed()) Log.Info("SAFETY", "random plane crashes are on and the air_crashes setting says not to fly: no air routes");
		else Log.Info("SAFETY", "large aircraft never use small or commuter airports" + (::MT.game.plane_crashes > 0 ?
			"; the game's random landing crashes stay on (setting 'Plane crashes')" : ""));
	}
	::MT.finance.Ensure(AICompany.GetMaxLoanAmount());   // the whole loan goes to work at once

	while (true) {
		this.HandleEvents();
		local today = AIDate.GetCurrentDate();
		if (today - this.last_3 >= 3) {
			::MT.fleet.MeasureTrips();
			::MT.fleet.SellParked();
			this.last_3 = today;
		}
		this.Periodic(true);
		if (this.network_due) {
			::MT.fleet.HandleSafetyFlags();
			::MT.planner.FinishClosures();
			this.network_due = false;
		}
		::MT.planner.Step();
		::MT.finance.Repay();
		this.Sleep(20);
	}
}

/*
 * Monthly, weekly and yearly work. From inside a path search (all = false) only the yearly review and report
 * run: they cost little, while the weekly fleet work would take the search's share of the AI's time and slow
 * the construction down. Closing routes and rebuilding crossings wait for the main loop.
 */
function MaxTransit2::Periodic(all) {
	if (this.in_periodic) return;
	this.in_periodic = true;
	/* an error here may be caught by the construction around the path search: the flag must not stay set */
	try {
		local today = AIDate.GetCurrentDate();
		local month = AIDate.GetMonth(today), year = AIDate.GetYear(today);
		if (all && month != this.last_month) {
			this.Monthly();
			this.last_month = month;
			this.network_due = true;
		}
		if (all && today - this.last_7 >= 7) {
			::MT.fleet.Update();
			this.last_7 = today;
		}
		if (year != this.last_year) {
			if (this.last_year != -1) this.Yearly();
			this.last_year = year;
		}
	} catch (e) {
		this.in_periodic = false;
		throw e;
	}
	this.in_periodic = false;
}

function MaxTransit2::Monthly() {
	::MT.game.Refresh();
	::MT.finance.UpdateReserve();
	if (::MT.finance.trouble && ::MT.finance.Cash() > ::MT.finance.Reserve() * 2) ::MT.finance.trouble = false;
	::MT.nb.Monthly();
	::MT.safety.ServiceRound();
	::MT.safety.Audit();
	::MT.fleet.Renew();
	::MT.planner.SpendIdle();
	/* when money is plentiful a pound in a better vehicle costs less than the time to build another route */
	::MT.engines.capital_rate = ::MT.finance.Available() > 2000000 ? 0.1 : (::MT.finance.Available() > 600000 ? 0.2 : 0.3);
}

function MaxTransit2::Yearly() {
	::MT.fleet.Review();
	::MT.fleet.Modernise();
	this.Report();
	if (AIController.GetSetting("dump_map") == 1) {
		try { MapDump.Run(); } catch (e) { Log.Error("MAIN", "map dump failed: " + e); }
	}
}

function MaxTransit2::Report() {
	local counts = [0, 0, 0, 0], vehicles = [0, 0, 0, 0], profit = [0, 0, 0, 0];
	local freight = 0, pax = 0;
	foreach (route in ::MT.routes.Active()) {
		counts[route.mode]++;
		if (route.two_way) pax++; else freight++;
		foreach (v, _ in route.Vehicles()) {
			vehicles[route.mode]++;
			profit[route.mode] += AIVehicle.GetProfitLastYear(v);
		}
	}
	local total = profit[0] + profit[1] + profit[2] + profit[3];
	::MT.planner.scale = max(0, total);
	Log.Info("REPORT", "year " + (Util.Year() - 1) + ": routes road " + counts[0] + " / rail " + counts[1] + " / air " + counts[2] + " / water " +
		counts[3] + " (" + freight + " freight, " + pax + " passenger), vehicles " + vehicles[0] + " / " + vehicles[1] + " / " + vehicles[2] + " / " +
		vehicles[3] + ", vehicle profit " + Util.Money(total) + " (road " + Util.Money(profit[0]) + ", rail " + Util.Money(profit[1]) +
		", air " + Util.Money(profit[2]) + ", water " + Util.Money(profit[3]) + ")");
	Log.Info("REPORT", "company value " + Util.Money(AICompany.GetQuarterlyCompanyValue(AICompany.COMPANY_SELF, AICompany.CURRENT_QUARTER + 1)) +
		", " + ::MT.finance.Status());
	/* looks */
	local tiles = 0, turns = 0, crossings = 0, doubled = 0, share = 0, trees = 0;
	foreach (route in ::MT.routes.Active()) {
		trees += route.trees_cut;
		if (route.mode != MODE_RAIL) {
			if (route.mode == MODE_ROAD) foreach (t in route.track_tiles) if (AIRail.IsLevelCrossingTile(t)) crossings++;
			continue;
		}
		tiles += route.p1.len();
		turns += route.turns;
		foreach (t in route.track_tiles) if (AIRail.IsLevelCrossingTile(t)) crossings++;
		if (route.p2.len() > 0) {
			doubled++;
			share += ::MT.rail.ParallelShare(::MT.rail.Decode(route.p1), ::MT.rail.Decode(route.p2));
		}
	}
	Log.Info("REPORT", "looks: " + tiles + " rail route tiles with " + (tiles > 0 ? (100 * turns / tiles) : 0) + " curve steps per 100 tiles, " +
		doubled + " double lines with " + (doubled > 0 ? share / doubled : 0) + "% of the second track alongside the first, level crossings " +
		crossings + ", trees cut " + trees + " / planted " + ::MT.landscape.planted);
	Log.Info("REPORT", "courtesy: " + ::MT.nb.Report());
	Log.Info("REPORT", "safety: " + ::MT.safety.Report());
	foreach (route in ::MT.routes.Active()) {
		local p = 0, n = 0;
		foreach (v, _ in route.Vehicles()) { p += AIVehicle.GetProfitLastYear(v); n++; }
		local s = ::MT.monitor.Stats(route);
		Log.Info("REPORT", route.Name() + ": " + n + " vehicles, profit " + Util.Money(p) + ", built for " + Util.Money(route.cost) +
			", round trip " + route.Rtt().tointeger() + " d, use " + (s.util * 100).tointeger() + "%" + (s.rating_a >= 0 ? ", rating " + s.rating_a + "%" : ""));
	}
}

function MaxTransit2::HandleEvents() {
	while (AIEventController.IsEventWaiting()) {
		local e = AIEventController.GetNextEvent();
		switch (e.GetEventType()) {
			case AIEvent.ET_VEHICLE_CRASHED:
				::MT.safety.OnVehicleCrashed(AIEventVehicleCrashed.Convert(e));
				break;
			case AIEvent.ET_VEHICLE_LOST: {
				local v = AIEventVehicleLost.Convert(e).GetVehicleID();
				local route = ::MT.routes.RouteOfVehicle(v);
				Log.Warn("FLEET", "vehicle " + AIVehicle.GetName(v) + " is lost at " + Util.TileStr(AIVehicle.GetLocation(v)) +
					(route == null ? "" : " on " + route.Name()));
				if (route != null && route.mode == MODE_ROAD && route.state == ROUTE_ACTIVE) ::MT.fleet.Withdraw(v, "lost");
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
				if (ev.AcceptPreview()) Log.Info("FLEET", "accepted preview of " + ev.GetName());
				break;
			}
			case AIEvent.ET_AIRCRAFT_DEST_TOO_FAR: {
				local v = AIEventAircraftDestTooFar.Convert(e).GetVehicleID();
				::MT.fleet.Withdraw(v, "destination beyond its range");
				break;
			}
			case AIEvent.ET_INDUSTRY_CLOSE: {
				local ind = AIEventIndustryClose.Convert(e).GetIndustryID();
				::MT.planner.OnIndustryClosed(ind);
				break;
			}
			case AIEvent.ET_COMPANY_NEW:
			case AIEvent.ET_COMPANY_BANKRUPT:
			case AIEvent.ET_COMPANY_MERGER:
				::MT.nb.Refresh();
				break;
		}
	}
}

function MaxTransit2::Save() {
	if (!("routes" in ::MT)) return {};
	local sell = [];
	foreach (v, _ in ::MT.fleet.to_sell) sell.append(v);
	local calib = [];
	foreach (c in ::MT.economy.calib) calib.append((c * 1000).tointeger());
	local fails = {};
	foreach (k, d in ::MT.planner.failures) if (Util.Today() - d < 730) fails[k] <- d;
	local learn = {};
	::MT.planner.Factor(true, 0);
	foreach (k, f in ::MT.planner.learn) learn[k] <- (f * 1000).tointeger();
	return {
		v = 1,
		routes = ::MT.routes.Save(),
		to_sell = sell,
		calib = calib,
		failures = fails,
		victims = ::MT.safety.victims,
		danger = ::MT.safety.danger_tiles,
		lengths = ::MT.engines.length_cache,
		refit = ::MT.engines.refit_cap,
		bad_pairs = ::MT.engines.bad_pairs,
		planted = ::MT.landscape.planted,
		learn = learn,
		day_tile = ::MT.planner.DayTileSave(),
		contested = ::MT.nb.contested
	};
}

function MaxTransit2::Load(version, data) {
	this.loaded = data;
}

function MaxTransit2::Restore(data) {
	if (!("routes" in data)) return;
	try {
		::MT.routes.Load(data.routes);
		foreach (v in data.to_sell) ::MT.fleet.to_sell[v] <- "restored";
		foreach (i, c in data.calib) if (i < 4) ::MT.economy.calib[i] = c / 1000.0;
		foreach (k, d in data.failures) ::MT.planner.failures[k] <- d;
		::MT.safety.victims = data.victims;
		foreach (t, r in data.danger) ::MT.safety.danger_tiles[t] <- r;
		foreach (e, l in data.lengths) ::MT.engines.length_cache[e] <- l;
		foreach (k, c in data.refit) ::MT.engines.refit_cap[k] <- c;
		foreach (k, b in data.bad_pairs) ::MT.engines.bad_pairs[k] <- b;
		::MT.landscape.planted = data.planted;
		::MT.planner.Factor(true, 0);
		foreach (k, f in data.learn) ::MT.planner.learn[k] <- f / 1000.0;
		::MT.planner.DayTileLoad(data.day_tile);
		foreach (k, d in data.contested) ::MT.nb.contested[k] <- d;
		Log.Info("MAIN", "restored " + ::MT.routes.routes.len() + " routes from the savegame");
	} catch (e) {
		Log.Error("MAIN", "could not restore saved data (" + e + "); continuing with what is on the map");
	}
}
