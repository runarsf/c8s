return {
    workstation = {
        version = 1,
        entrypoint = "bin/init-bin.lua",
        files = {
            { src = "bin/" },
            { src = "lib/" },
        },
    },

    smart_glasses = {
        version = 3,
        entrypoint = "bin/glasses.lua",
        files = {
            { src = "bin/glasses.lua" },
            { src = "bin/ntfy-consume.lua" },
            { src = "bin/toggle-night-vision.lua" },
            { src = "bin/alert.lua" },
            { src = "monitoring/protocol.lua" },
            { src = "monitoring/hud.lua" },
            { src = "monitoring/client.lua" },
        },
    },

    -- Owns the event state everything else reads. Put this on a computer
    -- in a chunk that stays loaded.
    monitoring_server = {
        version = 1,
        entrypoint = "monitoring/server.lua",
        files = {
            { src = "monitoring/protocol.lua" },
            { src = "monitoring/server.lua" },
        },
    },

    gps_node = {
        version = 1,
        files = {
            { src = "nodes/gps/main.lua", dest = "main.lua" },
        },
        -- resolved per-worker at request time using the worker's label
        -- (falls back to computer id if no label was set)
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

    -- Mekanism induction matrix watcher. Thresholds are fractions, so
    -- 0.5 is 50%; edit them here and the worker picks them up next sync.
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
}
