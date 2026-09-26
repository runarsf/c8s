-- Settings every worker gets, applied by the loader on each check-in.
--
-- These are controller-owned: the loader sets any that differ, so changing
-- one here reaches every machine within a check-in, and changing one *on*
-- a machine with `set` is undone at the next sync. A role can override a
-- value for its own machines with a `settings` table in roles.lua.
--
-- Names are CC:Tweaked's own (see the `set` program with no arguments for
-- the full list). Dropping an entry from here stops it being enforced, but
-- won't restore the old value - set it back explicitly to do that.

return {
    ["motd.enable"]      = false,  -- no message of the day on every boot
    ["list.show_hidden"] = true,   -- ls shows /rom, .settings and friends
}
