state("snes9x") {}
state("snes9x-x64") {}
state("bsnes") {}
state("higan") {}
state("emuhawk") {}

startup // Runs only once when the autosplitter is loaded
{
    refreshRate = 60;
}

init // Runs when the emulator process is found
{
    // For the variables to be defined later
    vars.previousTracksCents = 0;
    vars.isInARace = false;

    var states = new Dictionary<int, long>
    {
        //Look for D0AF3505
        { 9646080, 0x97EE04 },      // Snes9x-rr 1.60
        { 13565952, 0x140925118 },  // Snes9x-rr 1.60 (x64)
        { 9027584, 0x94DB54 },      // Snes9x 1.60
        { 12836864, 0x1408D8BE8 },  // Snes9x 1.60 (x64)
        { 16019456, 0x94D144 },     // higan v106
        { 15360000, 0x8AB144 },     // higan v106.112
        { 10096640, 0x72BECC },     // bsnes v107
        { 10338304, 0x762F2C },     // bsnes v107.1
        { 47230976, 0x765F2C },     // bsnes v107.2/107.3
        { 131543040, 0xA9BD5C },    // bsnes v110
        { 51924992, 0xA9DD5C },     // bsnes v111
        { 52056064, 0xAAED7C },     // bsnes v112
        { 52477952, 0xB16D7C },     // bsnes v115
        { 7061504, 0x36F11500240 }, // BizHawk 2.3
        { 7249920, 0x36F11500240 }, // BizHawk 2.3.1
        { 6938624, 0x36F11500240 }, // BizHawk 2.3.2
        { 4546560, 0x36F05F94040 }, // BizHawk 2.6.1
        { 4538368, 0x36F05F94040 }, // BizHawk 2.6.2
    };

    long memoryOffset;
    if (states.TryGetValue(modules.First().ModuleMemorySize, out memoryOffset)) {
        if (memory.ProcessName.ToLower().Contains("snes9x")) {
            memoryOffset = memory.ReadValue<int>((IntPtr)memoryOffset);
        }
    }

    if (memoryOffset == 0) {
        throw new Exception("Memory not yet initialized. modules.First().ModuleMemorySize=" + modules.First().ModuleMemorySize);
    }

    vars.watchers = new MemoryWatcherList {
        new MemoryWatcher<ushort>((IntPtr)memoryOffset + 0x1F26) { Name = "playerOneFinishTime" },
        new MemoryWatcher<byte>((IntPtr)memoryOffset + 0x1E58) { Name = "countdownOn" },
        new MemoryWatcher<ushort>((IntPtr)memoryOffset + 0x1EAE) { Name = "counter" },
        new MemoryWatcher<byte>((IntPtr)memoryOffset + 0x1E76) { Name = "playerOneCurrentLap" },
    };

    Func <bool> isRaceFinished = () => {
        var currentPlayerOneFinishTime = vars.watchers["playerOneFinishTime"].Current;
        var currentPlayerOneCurrentLap = vars.watchers["playerOneCurrentLap"].Current;
        return currentPlayerOneFinishTime > 0 &&
            currentPlayerOneFinishTime < 65535 &&
            currentPlayerOneCurrentLap > 1 &&
            currentPlayerOneCurrentLap < 10;
    };
    vars.isRaceFinished = isRaceFinished;

    Func <ushort, int> counterToCents = (ushort counter) => {
        return counter * 5 / 3;
    };
    vars.counterToCents = counterToCents;
}

update {
    vars.watchers.UpdateAll(game);

    if(vars.isInARace == false){
        var oldCountdownOn = vars.watchers["countdownOn"].Old;
        var currentCountdownOn = vars.watchers["countdownOn"].Current;
        vars.isInARace = oldCountdownOn == 1 && currentCountdownOn == 0;
        // if(vars.isInARace){
        //     print("A RACE JUST STARTED");
        // }
        return vars.isInARace;
    }
} // Calls isloading, gameTime and reset

start // Runs if update did not return false AND the timer is not running nor paused
{
    vars.previousTracksCents = 0;
    // if(vars.isInARace){
    // print("STARTING NOW");
    // }
    return vars.isInARace;
}

isLoading
{
    // From the AutoSplit documentation:
    // "If you want the Game Time to not run in between the synchronization interval and only ever return
    // the actual Game Time of the game, make sure to implement isLoading with a constant
    // return value of true."
    return true;
}

gameTime
{
    var currentCents = vars.previousTracksCents;
    if(vars.isRaceFinished() && vars.isInARace){
        currentCents += vars.counterToCents(vars.watchers["playerOneFinishTime"].Current);
    }
    else if (vars.isInARace) {
        currentCents += vars.counterToCents(vars.watchers["counter"].Current);
    }

    return new TimeSpan(0,0,0,0,currentCents*10); // Constructor expects miliseconds
}

reset {
    return false; // Never resets automatically
} // Calls split if it didn't return true

split {
    if(vars.isInARace && vars.isRaceFinished()){
        // print("A RACE JUST FINISHED");
        vars.isInARace = false;
        int cents = vars.counterToCents(vars.watchers["playerOneFinishTime"].Current);
        vars.previousTracksCents += cents;
        // print("Splitting now with time: " + cents/6000 + "\'" + (cents % 6000) / 100 + "\"" + cents % 100);
        return true;
    }
    return false;
}


