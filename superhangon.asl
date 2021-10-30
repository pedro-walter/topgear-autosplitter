/*
    * SEGA Master Splitter
    Splitter designed to handle multiple 8 and 16 bit SEGA games running on various emulators
*/

state("retroarch") {}
state("Fusion") {}
state("gens") {}
state("SEGAGameRoom") {}
state("SEGAGenesisClassics") {}
state("blastem") {}
state("Sonic3AIR") {}


startup
{
    refreshRate = 61;

    string logfile = Directory.GetCurrentDirectory() + "\\superhangon-splitter.log";
    if ( File.Exists( logfile ) ) {
        File.Delete( logfile );
    }

    vars.LookUp = (Func<Process, SigScanTarget, IntPtr>)((proc, target) =>
    {
        vars.DebugOutput("Scanning memory");

        IntPtr result = IntPtr.Zero;
        foreach (var page in proc.MemoryPages())
        {
            var scanner = new SignatureScanner(proc, page.BaseAddress, (int)page.RegionSize);
            if ((result = scanner.Scan(target)) != IntPtr.Zero)
                break;
        }

        return result;
    });

    vars.LookUpInDLL = (Func<Process, ProcessModuleWow64Safe, SigScanTarget, IntPtr>)((proc, dll, target) =>
    {
        vars.DebugOutput("Scanning memory");

        IntPtr result = IntPtr.Zero;
        var scanner = new SignatureScanner(proc, dll.BaseAddress, (int)dll.ModuleMemorySize);
        result = scanner.Scan(target);
        return result;
    });


    vars.DebugOutput = (Action<string>)((text) => {
        string time = System.DateTime.Now.ToString("dd/MM/yy hh:mm:ss:fff");
        File.AppendAllText(logfile, "[" + time + "]: " + text + "\r\n");
        print("[Super Hang-on Splitter] "+text);
    });

    // SUPER HANG-ON SPECIFIC HELPERS
    vars.convertHexTimeToTimeSpan = (Func<ushort, TimeSpan>)((time) => {
        int centsInteger = time % 0x100;
        int cents = int.Parse(centsInteger.ToString("X"));
        int seconds = int.Parse((time - centsInteger).ToString("X")) / 100;
        return new TimeSpan(0,0,0,seconds,cents*10);
    });

    vars.getSectorCenths = (Func<int, int>)((sectorID) => {
        return int.Parse((vars.watchers["sector" + sectorID].Current % 0x100).ToString("X"));
    });    
}

init
{
    vars.gamename = timer.Run.GameName;
    vars.livesplitGameName = vars.gamename;
    vars.watchers = new MemoryWatcherList{};
    
    long memoryOffset = 0, smsMemoryOffset = 0;
    IntPtr baseAddress, codeOffset;

    long refLocation = 0, smsOffset = 0;
    baseAddress = modules.First().BaseAddress;
    bool isBigEndian = false, isFusion = false, isAir = false;
    SigScanTarget target;

    switch ( game.ProcessName.ToLower() ) {
        case "retroarch":
            ProcessModuleWow64Safe libretromodule = modules.Where(m => m.ModuleName == "genesis_plus_gx_libretro.dll" || m.ModuleName == "blastem_libretro.dll").First();
            baseAddress = libretromodule.BaseAddress;
            if ( libretromodule.ModuleName == "genesis_plus_gx_libretro.dll" ) {
                vars.DebugOutput("Retroarch - GPGX");
                if ( game.Is64Bit() ) {
                    target = new SigScanTarget(0x10, "85 C9 74 ?? 83 F9 02 B8 00 00 00 00 48 0F 44 05 ?? ?? ?? ?? C3");
                    codeOffset = vars.LookUpInDLL( game, libretromodule, target );
                    long memoryReference = memory.ReadValue<int>( codeOffset );
                    refLocation = ( (long) codeOffset + 0x04 + memoryReference );
                } else {
                    target = new SigScanTarget(0, "8B 44 24 04 85 C0 74 18 83 F8 02 BA 00 00 00 00 B8 ?? ?? ?? ?? 0F 45 C2 C3 8D B4 26 00 00 00 00");
                    codeOffset = vars.LookUpInDLL( game, libretromodule, target );
                    refLocation = (long) codeOffset + 0x11;
                }
            } else if ( libretromodule.ModuleName == "blastem_libretro.dll" ) {
                vars.DebugOutput("Retroarch - BlastEm!");
                goto case "blastem";
            }
            
            break;

        case "blastem":
            vars.DebugOutput("BlastEm!");
            target = new SigScanTarget(0, "81 F9 00 00 E0 00 72 10 81 E1 FF FF 00 00 83 F1 01 8A 89 ?? ?? ?? ?? C3");
            codeOffset = vars.LookUp( game, target );
            refLocation = (long) codeOffset + 0x13;

            target = new SigScanTarget(0, "66 41 81 FD FC FF 73 12 66 41 81 E5 FF 1F 45 0F B7 ED 45 8A AD ?? ?? ?? ?? C3");
            codeOffset = vars.LookUp( game, target );
            smsOffset = (long) codeOffset + 0x15;

            if ( refLocation == 0x13 && smsOffset == 0x15 ) {
                throw new NullReferenceException (String.Format("Memory offset not yet found. Base Address: 0x{0:X}", (long) baseAddress ));
            }
            break;
        case "gens":
            refLocation = memory.ReadValue<int>( IntPtr.Add(baseAddress, 0x40F5C ) );
            break;
        case "fusion":
            refLocation = (long) IntPtr.Add(baseAddress, 0x2A52D4);
            smsOffset = (long) IntPtr.Add(baseAddress, 0x2A52D8 );
            isBigEndian = true;
            isFusion = true;
            break;
        case "segagameroom":
            baseAddress = modules.Where(m => m.ModuleName == "GenesisEmuWrapper.dll").First().BaseAddress;
            refLocation = (long) IntPtr.Add(baseAddress, 0xB677E8);
            break;
        case "segagenesisclassics":
            refLocation = (long) IntPtr.Add(baseAddress, 0x71704);
            break;
        case "sonic3air":
            isAir = true;

            foreach (var page in game.MemoryPages()) {
                if ((int)page.RegionSize == 0x521000) {
                    refLocation = (long) page.BaseAddress + 0x3FFF00 + 0x120;
                    break;
                }
            }
            if ( refLocation > 0 ) {
                long injectionMem = (long) game.AllocateMemory(0x08);
                game.Suspend();
                game.WriteBytes(new IntPtr(injectionMem), BitConverter.GetBytes( (long) refLocation ) );
                game.Resume();
                refLocation = injectionMem;
            }
            isBigEndian = true;
            break;
    }

    vars.DebugOutput(String.Format("refLocation: 0x{0:X}", refLocation));
    if ( refLocation > 0 ) {
        memoryOffset = memory.ReadValue<int>( (IntPtr) refLocation );
        if ( memoryOffset == 0 ) {
            memoryOffset = refLocation;
        }
    }
    vars.DebugOutput(String.Format("memoryOffset: 0x{0:X}", memoryOffset));
    if ( smsOffset == 0 ) {
        smsOffset = refLocation;
    }
    vars.emuoffsets = new MemoryWatcherList
    {
        new MemoryWatcher<uint>( (IntPtr) refLocation ) { Name = "genesis", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
        new MemoryWatcher<uint>( (IntPtr) smsOffset   ) { Name = "sms", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull },
        new MemoryWatcher<uint>( (IntPtr) baseAddress ) { Name = "baseaddress", FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull }
    };

    if ( memoryOffset == 0 && smsOffset == 0 ) {
        Thread.Sleep(500);
        throw new NullReferenceException (String.Format("Memory offset not yet found. Base Address: 0x{0:X}", (long) baseAddress ));
    }

    vars.isBigEndian = isBigEndian;


    vars.addByteAddresses = (Action <Dictionary<string, long>>)(( addresses ) => {
        foreach ( var byteaddress in addresses ) {
            vars.watchers.Add( new MemoryWatcher<byte>( 
                (IntPtr) ( memoryOffset + byteaddress.Value ) 
                ) { Name = byteaddress.Key, Enabled = true } 
            );
        }
    });
    vars.addUShortAddresses = (Action <Dictionary<string, long>>)(( addresses ) => {
        foreach ( var ushortaddress in addresses ) {
            vars.DebugOutput(String.Format("Adding ushort {0}: 0x{1:X}", ushortaddress.Key, memoryOffset + ushortaddress.Value));
            vars.watchers.Add( new MemoryWatcher<ushort>( 
                (IntPtr) ( memoryOffset + ushortaddress.Value )
                ) { Name = ushortaddress.Key, Enabled = true } 
            );
        }
    });
    vars.addUIntAddresses = (Action <Dictionary<string, long>>)(( addresses ) => {
        foreach ( var uintaddress in addresses ) {
            vars.watchers.Add( new MemoryWatcher<uint>( 
                (IntPtr) ( memoryOffset + uintaddress.Value )
                ) { Name = uintaddress.Key, Enabled = true } 
            );
        }
    });
    vars.addULongAddresses = (Action <Dictionary<string, long>>)(( addresses ) => {
        foreach ( var ushortaddress in addresses ) {
            vars.DebugOutput(String.Format("Adding ulong {0}: 0x{1:X}", ushortaddress.Key, memoryOffset + ushortaddress.Value));
            vars.watchers.Add( new MemoryWatcher<ulong>( 
                (IntPtr) ( memoryOffset + ushortaddress.Value )
                ) { Name = ushortaddress.Key, Enabled = true } 
            );
        }
    });

    // GAME SPECIFIC VARIABLES
    vars.resetVariables = (Action)(() => {
        vars.lastSplitSector = 0;
        vars.lastSavedSector = 0;
        vars.originalMode = false;
        vars.timerIsRunning = false;
        vars.timeUntilLastSector = new TimeSpan();
    });
    vars.resetVariables();

    vars.addUShortAddresses(new Dictionary<string, long>() {
        { "timer", 0x0558 },
        { "originalModeScreen", 0xB648 },
        { "originalRaceSelected", 0xB602 },
        { "originalSponsor", 0xB610 },
    });
    for (int i = 1;i < 19;i++) {
        vars.addUShortAddresses(new Dictionary<string, long>() {
            { "sector" + i, 0x0400 + (i - 1) * 2 }
        });
    }
    vars.addByteAddresses(new Dictionary<string, long>() {
        { "originalTotalRaces", 0xB644 },
        { "screenID", 0xC704 }
    });
}

update {
    vars.watchers.UpdateAll(game);

    // DEBUG
    // print("Timer is " + vars.watchers["timer"].Current);
    // print("vars.lastSavedSector is " + vars.lastSavedSector);
    // print("vars.lastSplitSector is " + vars.lastSplitSector);
    // print("vars.timerIsRunning is " + vars.timerIsRunning);
    // print(String.Format("sector1 is {0} or 0x{0:X}", vars.watchers["sector1"].Current));
    // print(String.Format("sector2 is {0} or 0x{0:X}", vars.watchers["sector2"].Current));
    // print(String.Format("sector3 is {0} or 0x{0:X}", vars.watchers["sector3"].Current));
    // print(String.Format("sector4 is {0} or 0x{0:X}", vars.watchers["sector4"].Current));
    // print(String.Format("sector5 is {0} or 0x{0:X}", vars.watchers["sector5"].Current));
    // print(String.Format("sector6 is {0} or 0x{0:X}", vars.watchers["sector6"].Current));

    //Find the last sector that the game has in memory
    //TODO: make sure that the last export sector behaves properly
    if (vars.watchers["sector" + (vars.lastSavedSector + 1)].Current > 0 && vars.timerIsRunning){
        vars.lastSavedSector++;
    }

} // Calls isloading, gameTime and reset

start // Runs if update did not return false AND the timer is not running nor paused
{
    if (vars.watchers["originalModeScreen"].Current > 0){
        vars.originalMode = true;
        return true;
    }
    if (vars.watchers["timer"].Current > 0){
        vars.resetVariables();
        vars.timerIsRunning = true;
        return true;
    };
    return false;
}

isLoading
{
    // From the AutoSplit documentation:
    // "If you want the Game Time to not run in between the synchronization interval and only ever return
    // the actual Game Time of the game, make sure to implement isLoading with a constant
    // return value of true."
    return !vars.originalMode;
}

gameTime
{
    if (vars.originalMode) return;
    if (vars.lastSavedSector == 0 && vars.lastSplitSector == 0) {
        return vars.convertHexTimeToTimeSpan(vars.watchers["timer"].Current);
    }
    if (vars.lastSavedSector == 1 && vars.lastSplitSector == 0) {
        return vars.convertHexTimeToTimeSpan(vars.watchers["sector" + vars.lastSavedSector].Current);
    }
    if (vars.lastSavedSector == vars.lastSplitSector) {
        TimeSpan internalGameTime = vars.convertHexTimeToTimeSpan(vars.watchers["timer"].Current);
        int lastSectorCenths = vars.getSectorCenths(vars.lastSavedSector);
        return vars.timeUntilLastSector + internalGameTime - new TimeSpan(0,0,0,0,vars.getSectorCenths(vars.lastSavedSector) * 10);
    }
    if (vars.lastSavedSector > vars.lastSplitSector) {
        TimeSpan lastSectorTime = vars.convertHexTimeToTimeSpan(vars.watchers["sector" + vars.lastSavedSector].Current);
        int lastLastSectorCenths = vars.getSectorCenths(vars.lastSavedSector - 1);
        return vars.timeUntilLastSector + lastSectorTime - new TimeSpan(0,0,0,0,lastLastSectorCenths * 10);
    }
    return new TimeSpan(0,0,0,0,0);
}

reset {
    if (vars.watchers["screenID"].Current < 2 && vars.watchers["screenID"].Old > 1){
        vars.resetVariables();
        return true;
    }
    return false;
} // Calls split if it didn't return true

split {
    if (vars.originalMode) {
        if (vars.watchers["originalRaceSelected"].Current > 0 && vars.watchers["originalRaceSelected"].Old == 0) {
            if (vars.watchers["originalSponsor"].Current == 0 && vars.watchers["originalTotalRaces"].Current == 0) {
                return false;
            }
            return true;
        }
        return false;
    }
    if (vars.lastSavedSector > vars.lastSplitSector){
        vars.timeUntilLastSector += vars.convertHexTimeToTimeSpan(vars.watchers["sector" + vars.lastSavedSector].Current);
        if (vars.lastSplitSector > 0) {
            vars.timeUntilLastSector -= new TimeSpan(0,0,0,0,vars.getSectorCenths(vars.lastSavedSector - 1) * 10);
        }
        vars.lastSplitSector++;
        return true;
    }
    return false;
}


