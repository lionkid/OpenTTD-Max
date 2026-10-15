// QA helper AI for OpenTTD-Max. Every status line starts with "MAXTEST" and is parsed by run.py
// from the debug log (openttd -d script=4).
//   MAXTEST engine <air|rail> | name | speed | capacity | power | weight | price
//   MAXTEST pos <key> <tile>        position of each test vehicle, logged every few ticks
//   MAXTEST ld <key> <tick> <state> <cargo on board>   loading progress, logged with the position
class MaxTest extends AIController {
    air_names = ["Airbus A380-800", "Boeing 777-300ER", "Boeing 787-8", "Airbus A321", "Boeing 737-800"];
    rail_names = ["E5 Series Shinkansen", "E6 Series Shinkansen", "E7 Series Shinkansen", "Transrapid SMT",
                  "N700 Series Shinkansen"];
    freighter_name = "Boeing 747-8F";
    free_trains = [["E5 Series Shinkansen", 4], ["Transrapid SMT", 2]];   // series, intermediate cars
    hangar = null;
    cx = 0;            // centre of the test area (map centre, or near the largest town with near_town=1)
    cy = 0;
    town = null;       // the town the stations are joined to (near_town=1)
    rail_station = null;
    free_head = null;  // the first free formation (vehicle id) and its depot, for the coupling test
    free_depot = null;
    air_a = null;
    air_b = null;
    vehicles = null;   // [key, vehicle id]
    function Start();
}

function Log(s) { AILog.Info("MAXTEST " + s); }

function MaxTest::FindEngine(vt, name) {
    foreach (e, _ in AIEngineList(vt)) {
        if (AIEngine.GetName(e) == name && AIEngine.IsBuildable(e)) return e;
    }
    Log("engine not available: " + name);
    return null;
}

// Spiral outwards from `center` and return the first tile where fn(tile) succeeds in test mode.
function MaxTest::FindSpot(center, radius, fn) {
    local cx = AIMap.GetTileX(center), cy = AIMap.GetTileY(center);
    for (local r = 0; r <= radius; r++) {
        for (local dx = -r; dx <= r; dx++) {
            for (local dy = -r; dy <= r; dy++) {
                if (abs(dx) != r && abs(dy) != r) continue;
                local x = cx + dx, y = cy + dy;
                if (x < 2 || y < 2 || x >= AIMap.GetMapSizeX() - 2 || y >= AIMap.GetMapSizeY() - 2) continue;
                local t = AIMap.GetTileIndex(x, y);
                local ok;
                {
                    local tm = AITestMode();
                    ok = fn(t);
                }
                if (ok) return t;
            }
        }
    }
    return null;
}

function MaxTest::BuildAirports() {
    local type = AIAirport.IsValidAirportType(AIAirport.AT_INTERNATIONAL) ? AIAirport.AT_INTERNATIONAL : AIAirport.AT_LARGE;
    local cx = this.cx, cy = this.cy;
    // Squirrel 2 closures only see outer locals listed after the colon.
    local build = function(t) : (type) { return AIAirport.BuildAirport(t, type, AIStation.STATION_NEW); };
    local a = this.FindSpot(AIMap.GetTileIndex(cx - 25, cy - 20), 25, build);
    if (a == null || !AIAirport.BuildAirport(a, type, AIStation.STATION_NEW)) { Log("airport A failed: " + AIError.GetLastErrorString()); return false; }
    local b = this.FindSpot(AIMap.GetTileIndex(cx + 30, cy - 20), 25, build);
    if (b == null || !AIAirport.BuildAirport(b, type, AIStation.STATION_NEW)) { Log("airport B failed: " + AIError.GetLastErrorString()); return false; }
    this.air_a = a;
    this.air_b = b;
    this.hangar = AIAirport.GetHangarOfAirport(a);
    Log("airport A tile " + a + " airport B tile " + b + " hangar tile " + this.hangar);
    return true;
}

function MaxTest::BuildAircraft(name, key) {
    local engine = this.FindEngine(AIVehicle.VT_AIR, name);
    if (engine == null || this.hangar == null) return;
    local v = AIVehicle.BuildVehicle(this.hangar, engine);
    if (!AIVehicle.IsValidVehicle(v)) { Log("aircraft build failed: " + name + ": " + AIError.GetLastErrorString()); return; }
    AIOrder.AppendOrder(v, this.air_a, AIOrder.OF_NONE);
    AIOrder.AppendOrder(v, this.air_b, AIOrder.OF_NONE);
    AIVehicle.StartStopVehicle(v);
    Log("vehicle " + key + " aircraft " + name);
    this.vehicles.append([key, v]);
}

// Straight east-west line: depot, 8-tile station A, plain track, 8-tile station B (29 tiles), levelled first.
function MaxTest::TryRail(x0, y, rt) {
    AIRail.SetCurrentRailType(rt);
    local T = function(x, yy) { return AIMap.GetTileIndex(x, yy); };
    local ok = AITile.LevelTiles(T(x0 - 1, y), T(x0 + 29, y + 1));
    ok = ok && AIRail.BuildRailDepot(T(x0 - 1, y), T(x0, y));
    for (local x = x0; x < x0 + 2; x++) ok = ok && AIRail.BuildRailTrack(T(x, y), AIRail.RAILTRACK_NE_SW);
    ok = ok && AIRail.BuildRailStation(T(x0 + 2, y), AIRail.RAILTRACK_NE_SW, 1, 8, AIStation.STATION_NEW);
    for (local x = x0 + 10; x < x0 + 20; x++) ok = ok && AIRail.BuildRailTrack(T(x, y), AIRail.RAILTRACK_NE_SW);
    ok = ok && AIRail.BuildRailStation(T(x0 + 20, y), AIRail.RAILTRACK_NE_SW, 1, 8, AIStation.STATION_NEW);
    return ok;
}

// Build a railway row for `rt` at or below y_start; returns [x0, y] or null.
function MaxTest::BuildRow(name, rt, y_start) {
    local cx = this.cx;
    local x0 = null, y = null;
    for (local yy = y_start; yy < y_start + 40 && x0 == null; yy++) {
        for (local xx = cx - 25; xx < cx + 10 && x0 == null; xx += 4) {
            local ok;
            {
                local tm = AITestMode();
                ok = this.TryRail(xx, yy, rt);
            }
            if (ok) { x0 = xx; y = yy; }
        }
    }
    if (x0 == null) { Log("no row for " + name); return null; }
    if (!this.TryRail(x0, y, rt)) { Log("rail build failed for " + name + ": " + AIError.GetLastErrorString()); return null; }
    return [x0, y];
}

function MaxTest::StartTrain(v, key, name, x0, y) {
    AIOrder.AppendOrder(v, AIMap.GetTileIndex(x0 + 2, y), AIOrder.OF_NONE);
    AIOrder.AppendOrder(v, AIMap.GetTileIndex(x0 + 20, y), AIOrder.OF_NONE);
    AIVehicle.StartStopVehicle(v);
    if (this.rail_station == null) this.rail_station = AIMap.GetTileIndex(x0 + 2, y);
    Log("vehicle " + key + " train " + name + " length " + AIVehicle.GetLength(v) + " depot tile " + AIMap.GetTileIndex(x0 - 1, y));
    this.vehicles.append([key, v]);
}

function MaxTest::BuildTrain(name, key, y_start) {
    local engine = this.FindEngine(AIVehicle.VT_RAIL, name);
    if (engine == null) return y_start;
    local row = this.BuildRow(name, AIEngine.GetRailType(engine), y_start);
    if (row == null) return y_start + 3;
    local x0 = row[0], y = row[1];
    local v = AIVehicle.BuildVehicle(AIMap.GetTileIndex(x0 - 1, y), engine);
    if (!AIVehicle.IsValidVehicle(v)) { Log("train build failed: " + name + ": " + AIError.GetLastErrorString()); return y + 3; }
    this.StartTrain(v, key, name, x0, y);
    return y + 3;
}

// Free formation: the series' head cars (one dual-headed engine) plus `cars` intermediate cars, each
// coupled right behind the front head car (the rear head car stays at the end).
function MaxTest::BuildFreeTrain(name, key, cars, y_start) {
    local head = this.FindEngine(AIVehicle.VT_RAIL, name + " head cars");
    local car = this.FindEngine(AIVehicle.VT_RAIL, name + " intermediate car");
    if (head == null || car == null) return y_start;
    local row = this.BuildRow(name, AIEngine.GetRailType(head), y_start);
    if (row == null) return y_start + 3;
    local x0 = row[0], y = row[1];
    local depot = AIMap.GetTileIndex(x0 - 1, y);
    local v = AIVehicle.BuildVehicle(depot, head);
    if (!AIVehicle.IsValidVehicle(v)) { Log("head build failed: " + name + ": " + AIError.GetLastErrorString()); return y + 3; }
    for (local i = 0; i < cars; i++) {
        local w = AIVehicle.BuildVehicle(depot, car);
        if (!AIVehicle.IsValidVehicle(w)) { Log("car build failed: " + AIError.GetLastErrorString()); break; }
        if (!AIVehicle.MoveWagon(w, 0, v, 0)) Log("car couple failed: " + AIError.GetLastErrorString());
    }
    Log("free " + key + " " + name + " wagons " + AIVehicle.GetNumWagons(v) + " length " + AIVehicle.GetLength(v) +
        " head power " + AIEngine.GetPower(head) + " head price " + AIEngine.GetPrice(head) + " car price " + AIEngine.GetPrice(car) +
        " capacity " + AIVehicle.GetCapacity(v, 0));
    if (this.free_head == null) { this.free_head = v; this.free_depot = depot; }
    this.StartTrain(v, key, name + " head cars", x0, y);
    return y + 3;
}

// Coupling a car of another series to the free formation must be refused by the attach callback.
function MaxTest::CheckAttach(other) {
    if (this.free_head == null) return;
    local car = this.FindEngine(AIVehicle.VT_RAIL, other + " intermediate car");
    if (car == null) return;
    local w = AIVehicle.BuildVehicle(this.free_depot, car);
    if (!AIVehicle.IsValidVehicle(w)) { Log("attach test: car build failed: " + AIError.GetLastErrorString()); return; }
    local ok = AIVehicle.MoveWagon(w, 0, this.free_head, 0);
    Log("attach test: " + other + " car onto the free formation: " + (ok ? "ACCEPTED (wrong)" : "refused, " + AIError.GetLastErrorString()));
    if (!ok) AIVehicle.SellWagonChain(w, 0);
}

// Join a drive-through bus stop in the town centre to station `sid` so that the station receives the
// town's passengers (a distant join; the QA config raises station_spread to 64 for this).
function MaxTest::JoinTown(sid) {
    if (this.town == null || sid == null) return;
    AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
    local X = AIMap.GetMapSizeX();
    local fn = function(t) : (sid, X) {
        if (!AIRoad.IsRoadTile(t) || AIRoad.IsRoadStationTile(t)) return false;
        foreach (d in [1, X]) {
            if (AIRoad.AreRoadTilesConnected(t, t + d) && AIRoad.AreRoadTilesConnected(t, t - d) &&
                AIRoad.BuildDriveThroughRoadStation(t, t + d, AIRoad.ROADVEHTYPE_BUS, sid)) return true;
        }
        return false;
    };
    local t = this.FindSpot(AITown.GetLocation(this.town), 6, fn);
    if (t == null || !fn(t)) { Log("bus stop for station " + sid + " failed: " + AIError.GetLastErrorString()); return; }
    Log("bus stop at " + t + " joined to station " + sid);
}

// One line per engine: what the player sees in the purchase list.
function MaxTest::DumpEngines() {
    foreach (vt in [AIVehicle.VT_AIR, AIVehicle.VT_RAIL]) {
        foreach (e, _ in AIEngineList(vt)) {
            if (!AIEngine.IsBuildable(e)) continue;
            local cargo = AIEngine.GetCargoType(e);
            Log("engine " + (vt == AIVehicle.VT_AIR ? "air" : "rail") + " | " + AIEngine.GetName(e) +
                " | speed " + AIEngine.GetMaxSpeed(e) + " | capacity " + AIEngine.GetCapacity(e) + " " + AICargo.GetCargoLabel(cargo) +
                " | power " + AIEngine.GetPower(e) + " | weight " + AIEngine.GetWeight(e) + " | price " + AIEngine.GetPrice(e) +
                " | running " + AIEngine.GetRunningCost(e) + " | intro " + AIDate.GetYear(AIEngine.GetDesignDate(e)) +
                " | id " + e);
        }
    }
}

function MaxTest::CheckFreighter() {
    local engine = this.FindEngine(AIVehicle.VT_AIR, this.freighter_name);
    if (engine == null || this.hangar == null) return;
    local v = AIVehicle.BuildVehicle(this.hangar, engine);
    if (!AIVehicle.IsValidVehicle(v)) { Log("freighter build failed: " + AIError.GetLastErrorString()); return; }
    foreach (c, _ in AICargoList()) {
        if (!AIEngine.CanRefitCargo(engine, c)) continue;
        Log("freighter refit " + AICargo.GetCargoLabel(c) + " capacity " + AIVehicle.GetRefitCapacity(v, c));
    }
}

function IsOurs(name) {
    foreach (key in ["Boeing", "Airbus", "Aerospatiale", "Shinkansen", "Transrapid", "SCMaglev", "CRRC", "Linimo",
                     "Beijing", "Doctor Yellow"]) {
        if (name.find(key) != null) return true;
    }
    return false;
}

// Timeline mode (AI setting timeline=1): no building, no loan; one line per game year:
//   MAXTEST year <y> air <n> rail <n> orig_air <n> orig_rail <n> | air: a; b | rail: c; d
function MaxTest::Timeline() {
    AICompany.SetName("OpenTTD-Max Timeline");
    AICompany.SetLoanAmount(0);
    Log("ready");
    local last = -1;
    while (true) {
        local y = AIDate.GetYear(AIDate.GetCurrentDate());
        if (y != last) {
            last = y;
            local counts = [0, 0, 0, 0];
            local names = ["", ""];
            foreach (k, vt in [AIVehicle.VT_AIR, AIVehicle.VT_RAIL]) {
                foreach (e, _ in AIEngineList(vt)) {
                    if (!AIEngine.IsBuildable(e)) continue;
                    if (vt == AIVehicle.VT_RAIL && AIEngine.IsWagon(e)) continue;
                    local n = AIEngine.GetName(e);
                    if (IsOurs(n)) {
                        counts[k] += 1;
                        names[k] += n + "; ";
                    } else {
                        counts[k + 2] += 1;
                    }
                }
            }
            Log("year " + y + " air " + counts[0] + " rail " + counts[1] + " orig_air " + counts[2] + " orig_rail " +
                counts[3] + " | air: " + names[0] + "| rail: " + names[1]);
        }
        this.Sleep(30);
    }
}

function MaxTest::Start() {
    if (AIController.GetSetting("timeline") == 1) {
        this.Timeline();
        return;
    }
    AICompany.SetName("OpenTTD-Max QA");
    AICompany.SetLoanAmount(AICompany.GetMaxLoanAmount());
    this.vehicles = [];
    this.cx = AIMap.GetMapSizeX() / 2;
    this.cy = AIMap.GetMapSizeY() / 2;
    if (AIController.GetSetting("near_town") == 1) {
        local towns = AITownList();
        towns.Valuate(AITown.GetPopulation);
        towns.Sort(AIList.SORT_BY_VALUE, false);
        if (!towns.IsEmpty()) {
            local t = towns.Begin();
            this.town = t;
            // Keep the test area inside the map: the rail rows need 45 tiles to the east and 50 to the south.
            this.cx = max(40, min(AIMap.GetTileX(AITown.GetLocation(t)), AIMap.GetMapSizeX() - 45));
            this.cy = max(30, min(AIMap.GetTileY(AITown.GetLocation(t)), AIMap.GetMapSizeY() - 50));
            Log("town " + AITown.GetName(t) + " population " + AITown.GetPopulation(t) + " tile " + AITown.GetLocation(t));
        }
    }
    Log("start year " + AIDate.GetYear(AIDate.GetCurrentDate()));
    this.DumpEngines();
    if (this.BuildAirports()) {
        foreach (i, n in this.air_names) this.BuildAircraft(n, "air" + i);
    }
    local y = this.cy + 8;
    foreach (i, n in this.rail_names) y = this.BuildTrain(n, "rail" + i, y);
    foreach (i, ft in this.free_trains) y = this.BuildFreeTrain(ft[0], "free" + i, ft[1], y);
    this.CheckAttach("E6 Series Shinkansen");
    this.CheckFreighter();
    if (this.air_a != null) this.JoinTown(AIStation.GetStationID(this.air_a));
    if (this.rail_station != null) this.JoinTown(AIStation.GetStationID(this.rail_station));
    Log("ready");
    local pass = 0;   // passengers: the first cargo of class CC_PASSENGERS
    foreach (c, _ in AICargoList()) {
        if (AICargo.HasCargoClass(c, AICargo.CC_PASSENGERS)) { pass = c; break; }
    }
    while (true) {
        foreach (kv in this.vehicles) {
            Log("pos " + kv[0] + " " + AIVehicle.GetLocation(kv[1]));
            Log("ld " + kv[0] + " " + AIController.GetTick() + " " + AIVehicle.GetState(kv[1]) + " " +
                AIVehicle.GetCargoLoad(kv[1], pass));
        }
        this.Sleep(5);
    }
}
