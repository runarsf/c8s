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
        version = 15,
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
        version = 12,
        entrypoint = "me/server.lua",
        files = {
            { src = "me/protocol.lua" },
            { src = "me/bridge.lua" },
            { src = "me/server.lua" },
            { src = "me/diag.lua" },
            { src = "bin/alert.lua" },
        },
        config = {
            -- A peripheral type, or a specific name ("me_bridge_0", "back")
            -- when there is more than one bridge on the network.
            bridge = "me_bridge",

            -- A station is a peripheral on the server's wired network, named
            -- the way the network names it. Wiring a machine in is all it
            -- takes to be able to send to it, so there is no list of them
            -- here - only of what to leave out.
            --
            -- Lua patterns, matched against the peripheral name. The ME
            -- system's own interfaces and pattern providers are the usual
            -- entries - exporting into one puts the items straight back
            -- where they came from - along with any Advanced Peripherals
            -- gadget on the same network, which holds no items but cannot be
            -- told apart from a machine that does. The server prints its
            -- stations on boot, and `me/bridge.lua probe` lists every
            -- peripheral with its type.
            ignore = {},

            search_limit    = 60,
            cache_ttl       = 5,
            health_interval = 30,
        },
    },

    me_client = {
        version = 8,
        entrypoint = "me/client.lua",
        files = {
            { src = "me/protocol.lua" },
            { src = "me/client.lua" },
        },
    },
}
