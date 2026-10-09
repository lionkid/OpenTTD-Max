// QA helper AI: builds one airport pair with an aircraft and one railway with a train so that
// tools/ingame/run.py can screenshot the vehicles. Not part of the released NewGRFs.
class MaxTest extends AIInfo {
    function GetAuthor()      { return "OpenTTD-Max"; }
    function GetName()        { return "MaxTest"; }
    function GetDescription() { return "Builds vehicles for OpenTTD-Max sprite screenshots"; }
    function GetVersion()     { return 1; }
    function GetDate()        { return "2026-10-09"; }
    function CreateInstance() { return "MaxTest"; }
    function GetShortName()   { return "MAXT"; }
    function GetAPIVersion()  { return "13"; }
    function GetSettings() {
        AddSetting({name = "timeline", description = "Only log the available OpenTTD-Max vehicles every year",
                    min_value = 0, max_value = 1, easy_value = 0, medium_value = 0, hard_value = 0, custom_value = 0,
                    flags = CONFIG_BOOLEAN});
    }
}
RegisterAI(MaxTest());
