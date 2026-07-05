
solution 'csv'
    configurations { 'Debug', 'Release' }
    language 'C'
    defines { 'WIN32', '_WINDOWS' }
    flags { 'StaticRuntime', 'NoManifest', }

    location 'build'
    objdir 'obj'

    filter { 'action:vs*' }
        defines { '_CRT_SECURE_NO_WARNINGS' }

    filter { 'configurations:Debug' }
        defines { '_DEBUG' }
        flags { 'Symbols' }
        optimize 'Debug'
        targetsuffix '_d'

    filter { 'configurations:Release' }
        defines { 'NDEBUG' }
        optimize 'Full'

project 'csv_parser'
    kind 'StaticLib'
    targetdir 'lib'

    includedirs {
        'parser',
    }

    files {
        'parser/csv_parser.h',
        'parser/csv_parser.c',
--        'parser/csv_parser.rl',
    }

    prebuildcommands {
        '@echo on',
        "ragel -C -G2 ../parser/csv_parser.rl",
    }

project 'test'
    kind 'ConsoleApp'
    targetdir 'bin'

    includedirs {
        'parser',
    }
    libdirs {
        'lib',
    }
    links {
        'csv_parser',
    }

    files {
        'test/test.c',
    }

    configuration 'Debug'
        debugdir '$(TargetDir)'
        debugargs 'header.csv >1'

project 'wlx_csv'
    kind 'SharedLib'
    targetdir 'bin'
--    targetdir '$(COMMANDER_PATH)/Plugins/wlx/csv'
    
    includedirs {
        'parser',
    }
    links {
        'csv_parser',
    }

    files {
        'parser/csv_parser.h',
        'wlx/listplug.h',
        'wlx/listplug.def',
        'wlx/wlx_csv.c',
    }

    targetname 'wlx_csv'
    targetextension '.wlx'

    configuration 'Debug'
        debugdir '$(TargetDir)'
        debugcommand '$(COMMANDER_PATH)/TOTALCMD.EXE'

project 'csv'
    kind 'SharedLib'
    targetdir 'bin'

    defines { 'LUA_BUILD_AS_DLL', 'LUA_LIB' }

    includedirs {
        'include',
        'parser',
    }
    libdirs {
        'lib',
    }
    links {
        'csv_parser',
        'lua5.1',
    }

    files {
        'lua/*.h', 
        'lua/*.c', 
    }
