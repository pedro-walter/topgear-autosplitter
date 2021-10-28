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
    vars.timerModel = new TimerModel { CurrentState = timer };
    string logfile = Directory.GetCurrentDirectory() + "\\SEGAMasterSplitter.log";
    if ( File.Exists( logfile ) ) {
        File.Delete( logfile );
    }


    vars.SwapEndianness = (Func<ushort,ushort>)((value) => {
        var b1 = (value >> 0) & 0xff;
        var b2 = (value >> 8) & 0xff;

        return (ushort) (b1 << 8 | b2 << 0);
    });

    vars.SwapEndiannessInt = (Func<uint, uint>)((value) => {
        return ((value & 0x000000ff) << 24) +
            ((value & 0x0000ff00) << 8) +
            ((value & 0x00ff0000) >> 8) +
            ((value & 0xff000000) >> 24);
    });

    vars.SwapEndiannessIntAndTruncate = (Func<uint, uint>)((value) => {
        return ((value & 0x00000000) << 24) +
            ((value & 0x0000ff00) << 8) +
            ((value & 0x00ff0000) >> 8) +
            ((value & 0xff000000) >> 24);
    });

    vars.SwapEndiannessLong = (Func<ulong, ulong>)((value) => {
        return 
            ((value & 0x00000000000000FF) << 56) +
            ((value & 0x000000000000FF00) << 40) +
            ((value & 0x0000000000FF0000) << 24) +
            ((value & 0x00000000FF000000) << 8) +
            ((value & 0x000000FF00000000) >> 8) +
            ((value & 0x0000FF0000000000) >> 24) +
            ((value & 0x00FF000000000000) >> 40) +
            ((value & 0xFF00000000000000) >> 56) 
            ;
    });

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


    refreshRate = 1;

    vars.DebugOutput = (Action<string>)((text) => {
        string time = System.DateTime.Now.ToString("dd/MM/yy hh:mm:ss:fff");
        File.AppendAllText(logfile, "[" + time + "]: " + text + "\r\n");
        print("[SEGA Master Splitter] "+text);
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

    vars.addUShortAddresses(new Dictionary<string, long>() {
        { "timer", 0x0558 }
    });
    vars.addULongAddresses(new Dictionary<string, long>() {
        { "init", 0x0000 }
    });
}


// init // Runs when the emulator process is found
// {
//     // For the variables to be defined later
//     vars.previousTracksCents = 0;
//     vars.isInARace = false;

//     var states = new Dictionary<int, long>
//     {
//         //Look for D0AF3505
//         { 9646080, 0x97EE04 },      // Snes9x-rr 1.60
//         { 13565952, 0x140925118 },  // Snes9x-rr 1.60 (x64)
//         { 9027584, 0x94DB54 },      // Snes9x 1.60
//         { 12836864, 0x1408D8BE8 },  // Snes9x 1.60 (x64)
//         { 16019456, 0x94D144 },     // higan v106
//         { 15360000, 0x8AB144 },     // higan v106.112
//         { 10096640, 0x72BECC },     // bsnes v107
//         { 10338304, 0x762F2C },     // bsnes v107.1
//         { 47230976, 0x765F2C },     // bsnes v107.2/107.3
//         { 131543040, 0xA9BD5C },    // bsnes v110
//         { 51924992, 0xA9DD5C },     // bsnes v111
//         { 52056064, 0xAAED7C },     // bsnes v112
//         { 52477952, 0xB16D7C },     // bsnes v115
//         { 7061504, 0x36F11500240 }, // BizHawk 2.3
//         { 7249920, 0x36F11500240 }, // BizHawk 2.3.1
//         { 6938624, 0x36F11500240 }, // BizHawk 2.3.2
//         { 4546560, 0x36F05F94040 }, // BizHawk 2.6.1
//         { 4538368, 0x36F05F94040 }, // BizHawk 2.6.2
//     };

//     long memoryOffset;
//     if (states.TryGetValue(modules.First().ModuleMemorySize, out memoryOffset)) {
//         if (memory.ProcessName.ToLower().Contains("snes9x")) {
//             memoryOffset = memory.ReadValue<int>((IntPtr)memoryOffset);
//         }
//     }

//     if (memoryOffset == 0) {
//         throw new Exception("Memory not yet initialized. modules.First().ModuleMemorySize=" + modules.First().ModuleMemorySize);
//     }

//     vars.watchers = new MemoryWatcherList {
//         new MemoryWatcher<ushort>((IntPtr)memoryOffset + 0x0558) { Name = "timer" }
//     };
// }

update {
    vars.watchers.UpdateAll(game);
    print("Timer is " + vars.watchers["timer"].Current);
    print("Init is " + vars.watchers["init"].Current);
} // Calls isloading, gameTime and reset

// start // Runs if update did not return false AND the timer is not running nor paused
// {
//     vars.previousTracksCents = 0;
//     // if(vars.isInARace){
//     // print("STARTING NOW");
//     // }
//     return vars.isInARace;
// }

// isLoading
// {
//     // From the AutoSplit documentation:
//     // "If you want the Game Time to not run in between the synchronization interval and only ever return
//     // the actual Game Time of the game, make sure to implement isLoading with a constant
//     // return value of true."
//     return true;
// }

// gameTime
// {
    
    
//     //return new TimeSpan(0,0,0,0,currentCents*10); // Constructor expects miliseconds
// }

// reset {
//     return false; // Never resets automatically
// } // Calls split if it didn't return true

// split {
//     if(vars.isInARace && vars.isRaceFinished()){
//         // print("A RACE JUST FINISHED");
//         vars.isInARace = false;
//         int cents = vars.counterToCents(vars.watchers["playerOneFinishTime"].Current);
//         vars.previousTracksCents += cents;
//         // print("Splitting now with time: " + cents/6000 + "\'" + (cents % 6000) / 100 + "\"" + cents % 100);
//         return true;
//     }
//     return false;
// }


