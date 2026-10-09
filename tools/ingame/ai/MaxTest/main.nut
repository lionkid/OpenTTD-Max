// QA helper AI for OpenTTD-Max. Every status line starts with "MAXTEST" and is parsed by run.py
// from the debug log (openttd -d script=4).
//   MAXTEST engine <air|rail> | name | speed | capacity | power | weight | price
//   MAXTEST pos <key> <tile>        position of each test vehicle, logged every few ticks
class MaxTest extends AIController {
    air_names = ["Airbus A380-800", "Boeing 777-300ER", "Boeing 787-8", "Airbus A321", "Boeing 737-800"];
    rail_names = ["E5 Series Shinkansen", "E6 Series Shinkansen", "E7 Series Shinkansen", "Transrapid SMT",
                  "N700 Series Shinkansen"];
    freighter_name = "Boeing 747-8F";
    hangar = null;
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
    local cx = AIMap.GetMapSizeX() / 2, cy = AIMap.GetMapSizeY() / 2;
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

function MaxTest::BuildTrain(name, key, y_start) {
    local engine = this.FindEngine(AIVehicle.VT_RAIL, name);
    if (engine == null) return y_start;
    local rt = AIEngine.GetRailType(engine);
    local cx = AIMap.GetMapSizeX() / 2;
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
    if (x0 == null) { Log("no row for " + name); return y_start; }
    if (!this.TryRail(x0, y, rt)) { Log("rail build failed for " + name + ": " + AIError.GetLastErrorString()); return y + 3; }
    local depot = AIMap.GetTileIndex(x0 - 1, y);
    local v = AIVehicle.BuildVehicle(depot, engine);
    if (!AIVehicle.IsValidVehicle(v)) { Log("train build failed: " + name + ": " + AIError.GetLastErrorString()); return y + 3; }
    AIOrder.AppendOrder(v, AIMap.GetTileIndex(x0 + 2, y), AIOrder.OF_NONE);
    AIOrder.AppendOrder(v, AIMap.GetTileIndex(x0 + 20, y), AIOrder.OF_NONE);
    AIVehicle.StartStopVehicle(v);
    Log("vehicle " + key + " train " + name + " length " + AIVehicle.GetLength(v) + " depot tile " + depot);
    this.vehicles.append([key, v]);
    return y + 3;
}

// One line per engine: what the player sees in the purchase list.
function MaxTest::DumpEngines() {
    foreach (vt in [AIVehicle.VT_AIR, AIVehicle.VT_RAIL]) {
        foreach (e, _ in AIEngineList(vt)) {
            if (!AIEngine.IsBuildable(e)) continue;
            local cargo = AIEngine.GetCargoType(e);
            Log("engine " + (vt == AIVehicle.VT_AIR ? "air" : "rail") + " | " + AIEngine.GetName(e) +
                " | speed " + AIEngine.GetMaxSpeed(e) + " | capacity " + AIEngine.GetCapacity(e) + " " + AICargo.GetCargoLabel(cargo) +
                " | power " + AIEngine.GetPower(e) + " | weight " + AIEngine.GetWeight(e) + " | price " + AIEngine.GetPrice(e));
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

function MaxTest::Start() {
    AICompany.SetName("OpenTTD-Max QA");
    AICompany.SetLoanAmount(AICompany.GetMaxLoanAmount());
    this.vehicles = [];
    Log("start year " + AIDate.GetYear(AIDate.GetCurrentDate()));
    this.DumpEngines();
    if (this.BuildAirports()) {
        foreach (i, n in this.air_names) this.BuildAircraft(n, "air" + i);
    }
    local y = AIMap.GetMapSizeY() / 2 + 8;
    foreach (i, n in this.rail_names) y = this.BuildTrain(n, "rail" + i, y);
    this.CheckFreighter();
    Log("ready");
    while (true) {
        foreach (kv in this.vehicles) Log("pos " + kv[0] + " " + AIVehicle.GetLocation(kv[1]));
        this.Sleep(5);
    }
}
