// QA helper AI for OpenTTD-Max. Every status line starts with "MAXTEST" and is parsed by run.py
// from the debug log (openttd -d script=4).
class MaxTest extends AIController {
    air_engine_name = "Boeing 737-800";
    rail_engine_name = "N700 Series Shinkansen";
    freighter_name = "Boeing 747-8F";
    hangar = null;
    function Start();
}

function Log(s) { AILog.Info("MAXTEST " + s); }

function MaxTest::FindEngine(vt, name) {
    local list = AIEngineList(vt);
    foreach (e, _ in list) {
        if (AIEngine.GetName(e) == name) return e;
    }
    foreach (e, _ in list) Log("available engine: " + AIEngine.GetName(e));
    Log("engine not found: " + name);
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

function MaxTest::BuildAir() {
    local engine = this.FindEngine(AIVehicle.VT_AIR, this.air_engine_name);
    if (engine == null) return null;
    local type = AIAirport.IsValidAirportType(AIAirport.AT_INTERNATIONAL) ? AIAirport.AT_INTERNATIONAL : AIAirport.AT_LARGE;
    local cx = AIMap.GetMapSizeX() / 2, cy = AIMap.GetMapSizeY() / 2;
    // Squirrel 2 closures only see outer locals listed after the colon.
    local build = function(t) : (type) { return AIAirport.BuildAirport(t, type, AIStation.STATION_NEW); };
    local a = this.FindSpot(AIMap.GetTileIndex(cx - 25, cy - 20), 25, build);
    if (a == null || !AIAirport.BuildAirport(a, type, AIStation.STATION_NEW)) { Log("airport A failed: " + AIError.GetLastErrorString()); return null; }
    local b = this.FindSpot(AIMap.GetTileIndex(cx + 30, cy - 20), 25, build);
    if (b == null || !AIAirport.BuildAirport(b, type, AIStation.STATION_NEW)) { Log("airport B failed: " + AIError.GetLastErrorString()); return null; }
    Log("airport A tile " + a + " airport B tile " + b);
    local hangar = AIAirport.GetHangarOfAirport(a);
    Log("hangar tile " + hangar);
    this.hangar = hangar;
    local v = AIVehicle.BuildVehicle(hangar, engine);
    if (!AIVehicle.IsValidVehicle(v)) { Log("aircraft build failed: " + AIError.GetLastErrorString()); return null; }
    AIOrder.AppendOrder(v, a, AIOrder.OF_NONE);
    AIOrder.AppendOrder(v, b, AIOrder.OF_NONE);
    AIVehicle.StartStopVehicle(v);
    Log("aircraft built id " + v + " name " + AIEngine.GetName(engine));
    return v;
}

// Straight east-west line: depot, 8-tile station A, plain track, 8-tile station B (29 tiles).
// The strip is levelled first so any gently rolling map works.
function MaxTest::TryRail(x0, y, engine) {
    local rt = AIEngine.GetRailType(engine);
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

function MaxTest::BuildRail() {
    local engine = this.FindEngine(AIVehicle.VT_RAIL, this.rail_engine_name);
    if (engine == null) return null;
    local cx = AIMap.GetMapSizeX() / 2, cy = AIMap.GetMapSizeY() / 2;
    local x0 = null, y = null;
    for (local dy = 0; dy < 50 && x0 == null; dy++) {
        local yy = cy + 12 + (dy % 2 == 0 ? dy : -dy);
        for (local xx = cx - 25; xx < cx + 10 && x0 == null; xx += 4) {
            local ok;
            {
                local tm = AITestMode();
                ok = this.TryRail(xx, yy, engine);
            }
            if (ok) { x0 = xx; y = yy; }
        }
    }
    if (x0 == null) { Log("no usable row for the railway"); return null; }
    if (!this.TryRail(x0, y, engine)) { Log("rail build failed at x0=" + x0 + " y=" + y + ": " + AIError.GetLastErrorString()); return null; }
    local depot = AIMap.GetTileIndex(x0 - 1, y);
    local sa = AIMap.GetTileIndex(x0 + 2, y), sb = AIMap.GetTileIndex(x0 + 20, y);
    Log("rail depot tile " + depot + " station A tile " + sa + " station B tile " + sb);
    local v = AIVehicle.BuildVehicle(depot, engine);
    if (!AIVehicle.IsValidVehicle(v)) { Log("train build failed: " + AIError.GetLastErrorString()); return null; }
    AIOrder.AppendOrder(v, sa, AIOrder.OF_NONE);
    AIOrder.AppendOrder(v, sb, AIOrder.OF_NONE);
    AIVehicle.StartStopVehicle(v);
    Log("train built id " + v + " name " + AIEngine.GetName(engine) + " length " + AIVehicle.GetLength(v));
    return v;
}

// One line per engine: what the player sees in the purchase list (speed in km/h-ish internal units).
function MaxTest::DumpEngines() {
    foreach (vt in [AIVehicle.VT_AIR, AIVehicle.VT_RAIL]) {
        local list = AIEngineList(vt);
        foreach (e, _ in list) {
            if (!AIEngine.IsBuildable(e)) continue;
            local cargo = AIEngine.GetCargoType(e);
            Log("engine " + (vt == AIVehicle.VT_AIR ? "air" : "rail") + " | " + AIEngine.GetName(e) +
                " | speed " + AIEngine.GetMaxSpeed(e) + " | capacity " + AIEngine.GetCapacity(e) + " " + AICargo.GetCargoLabel(cargo) +
                " | power " + AIEngine.GetPower(e) + " | weight " + AIEngine.GetWeight(e) + " | price " + AIEngine.GetPrice(e));
        }
    }
}

function MaxTest::CheckFreighter() {
    if (this.hangar == null) return;
    local engine = this.FindEngine(AIVehicle.VT_AIR, this.freighter_name);
    if (engine == null) return;
    local v = AIVehicle.BuildVehicle(this.hangar, engine);
    if (!AIVehicle.IsValidVehicle(v)) { Log("freighter build failed: " + AIError.GetLastErrorString()); return; }
    foreach (c, _ in AICargoList()) {
        if (!AIEngine.CanRefitCargo(engine, c)) continue;
        Log("freighter refit " + AICargo.GetCargoLabel(c) + " capacity " + AIVehicle.GetRefitCapacity(v, c) +
            " (unit weight " + AICargo.GetWeight(c, 1) + " t)");
    }
}

function MaxTest::Start() {
    AICompany.SetName("OpenTTD-Max QA");
    AICompany.SetLoanAmount(AICompany.GetMaxLoanAmount());
    Log("start year " + AIDate.GetYear(AIDate.GetCurrentDate()));
    this.DumpEngines();
    local air = this.BuildAir();
    local rail = this.BuildRail();
    this.CheckFreighter();
    Log("ready");
    while (true) {
        if (air != null) Log("pos air " + AIVehicle.GetLocation(air) + " state " + AIVehicle.GetState(air));
        if (rail != null) Log("pos rail " + AIVehicle.GetLocation(rail) + " state " + AIVehicle.GetState(rail));
        this.Sleep(20);
    }
}
