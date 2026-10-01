return {
    workstation = {
        version = 2,
        entrypoint = "bin/init-bin.lua",
        files = {
            { src = "bin/" },
            { src = "lib/" },
        },
    },

    smart_glasses = {
        version = 12,
        settings = {
            ["monitoring.sounds.info"]     = "sounds/info.dfpwm",
            ["monitoring.sounds.warning"]  = "sounds/warning.dfpwm",
            ["monitoring.sounds.critical"] = "sounds/critical.dfpwm",
        },
        entrypoint = {
            "bin/run-many.lua", "--restart",
            "/app/monitoring/client.lua",
            "/app/me/client.lua",
            "/app/bin/toggle-night-vision.lua",
            "/app/bin/ntfy-consume.lua",
        },
        files = {
            { src = "bin/run-many.lua" },
            { src = "lib/tasks.lua" },
            { src = "bin/ntfy-consume.lua" },
            { src = "bin/toggle-night-vision.lua" },
            { src = "bin/alert.lua" },
            { src = "monitoring/protocol.lua" },
            { src = "monitoring/hud.lua" },
            { src = "monitoring/client.lua" },
            { src = "me/protocol.lua" },
            { src = "me/client.lua" },
            -- Alert sounds: files/sounds/<severity>.dfpwm on the controller.
            { src = "sounds/" },
        },
    },

    monitoring_server = {
        version = 1,
        entrypoint = "monitoring/server.lua",
        files = {
            { src = "monitoring/protocol.lua" },
            { src = "monitoring/server.lua" },
        },
    },

    phone = {
        version = 1,
        entrypoint = "bin/init-bin.lua",
        files = {
            { src = "bin/init-bin.lua" },
            { src = "bin/alert.lua" },
            { src = "bin/test-event.lua" },
        },
    },

    gps_node = {
        version = 1,
        files = {
            { src = "nodes/gps/main.lua", dest = "main.lua" },
        },
        config = function(workerId, label)
            local anchors = {
                gps_east_1 = { x = 100, y = 64, z = -32 },
                gps_east_2 = { x = 100, y = 64, z = 32 },
                gps_west_1 = { x = -60, y = 64, z = -32 },
                gps_west_2 = { x = -60, y = 64, z = 32 },
            }
            local key = label or tostring(workerId)
            return anchors[key] or error("no gps anchor configured for '" .. key .. "'")
        end,
    },

    outer_wilds = {
        version = 3,
        entrypoint = "bin/ntfy-emit.lua",
        files = {
            { src = "bin/ntfy-emit.lua" }
        };
    };

    power_monitor = {
        version = 1,
        files = {
            { src = "nodes/power_monitor/main.lua", dest = "main.lua" },
            { src = "bin/alert.lua" },
        },
        config = {
            peripheral  = "inductionPort",
            warning_at  = 0.5,
            critical_at = 0.2,
            interval    = 30,
        },
    },

    presence_detector = {
        version = 3,
        files = {
            { src = "nodes/presence_detector/main.lua", dest = "main.lua" },
        },
    },

    me_server = {
        version = 5,
        entrypoint = "me/server.lua",
        files = {
            { src = "me/protocol.lua" },
            { src = "me/bridge.lua" },
            { src = "me/stations.lua" },
            { src = "me/server.lua" },
            { src = "bin/alert.lua" },
        },
        config = {
            -- A peripheral type, or a specific name ("me_bridge_0", "back")
            -- when there is more than one bridge on the network.
            bridge = "me_bridge",

            -- Destinations are discovered: every inventory on the server's
            -- wired network is offered, so a new machine needs no entry here.
            -- These two lists are the exceptions.

            -- Everything on the server's network is offered except what
            -- these patterns (Lua patterns, matched against the peripheral
            -- name) match. The ME system's own interfaces and pattern
            -- providers are the usual entries - exporting into one puts the
            -- items straight back where they came from - along with any
            -- Advanced Peripherals gadget on the same network, which holds
            -- no items but cannot be told apart from a machine that does.
            -- Fill this in from what `me/stations.lua list` prints.
            ignore = {},

            -- Stations worth naming by hand, and worth being told about when
            -- they go missing: a declared one keeps its name, stays on the
            -- list while it is off the network, and raises a monitoring
            -- event. Everything else is discovered and named after its block.
            destinations = {
                { name = "furnace",  container = "minecraft:chest_0" },
                { name = "crushing", container = "minecraft:barrel_1" },
            },

            search_limit    = 60,
            cache_ttl       = 5,
            health_interval = 30,
        },
    },

    me_client = {
        version = 5,
        entrypoint = "me/client.lua",
        files = {
            { src = "me/protocol.lua" },
            { src = "me/client.lua" },
        },
    },
}
