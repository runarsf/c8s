# Cubernetes (c8s)

## Layout

    controller/
      startup.lua           - the code-serving daemon
      roles.lua             - role -> file list + per-worker config
      settings.lua          - CC settings every worker gets
      files/                 - role source
      loader/
        loader.lua              - loader source - edit to push an update
        version.lua              - bump whenever loader.lua changes
      tools/
        make-worker-disk.lua    - provisions a new worker

## Setup

1. **Controller**: attach a modem, copy `controller/` onto it, reboot.

2. **Each worker**: get `tools/make-worker-disk.lua` onto a networked
   computer with a disk drive (the controller works fine) and run:

       tools/make-worker-disk

   Take the resulting disk to the new computer/turtle and turn it on -
   CC:Tweaked boots from a disk's `startup.lua` before its own root
   one, so an installer runs automatically, copies everything into
   place, and ejects itself. If the worker already has a modem and
   network access, skip the disk and run
   `make-worker-disk self` directly on it instead.

3. On the new worker:

       label set turtle-03
       set role turtle_miner
       reboot

   From here on nothing about the worker needs touching by hand - role
   code, config, and the loader itself all sync from the controller
   automatically. You only need to repeat step 2 if `/startup.lua`
   itself needs replacing (rare - see below), not for ordinary updates.

## How it works

- The ROM (`/startup.lua`) is frozen by design and never touched by
  sync. It runs `/boot/loader.lua` via `shell.run` and falls back to
  `/boot/loader.default.lua` if that fails.
  Loader updates are syntax-checked before ever being written.
- The loader fetches its role's files each check-in, resolves the
  controller by `rednet.lookup`, and writes whatever changed.
  Any change triggers an `os.reboot()` to apply it.
  Sync also confirms every expected file (and `/boot/loader.lua`) actually exists locally,
  so a wiped or interrupted install still gets repaired even if the version
  marker claims it's current.
- A background loop checks in every 10-60s (backing off while
  unreachable, resetting once it answers) for as long as the computer
  runs. A worker that's never synced just waits rather than failing.
- Per-worker config (e.g. `gps_node`'s coordinates) is resolved by labels.
- `settings.lua` is a baseline of CC settings (motd off, hidden files
  shown, ...) served with every bundle and applied by the loader on each
  check-in. It is declarative: whatever differs gets set, so an edit there
  reaches every machine within a check-in, and `set`ting one of those
  values on a worker is undone at its next sync. A role can override a
  value for its own machines with a `settings` table in `roles.lua`.
  Dropping an entry stops enforcing it rather than restoring the old value.
- A role with no entrypoint file (`main.lua` if not overwritten) is **provision-only**
  (synced once at boot, then falls through to a normal interactive shell).
  A role that *does* name an entrypoint which isn't there says so at boot.
- An entrypoint can take arguments, written as a list of words:
  `entrypoint = { "bin/run-many.lua", "--restart", "app/bin/a.lua" }`.
  Only the first word is a path. Writing the whole command as one string
  works too, but then no argument can contain a space.
- A role can also define `dest = "setup.lua"`, which will run once via `shell.run`
  right after every sync regardless.

## Monitoring

Events are *state*, not notifications: something raises one, and it stays
up on every pair of smart glasses until it is resolved - over rednet by
whatever raised it, or by hand from the list UI.

- `monitoring_server` owns the events and writes them to `/state/events.lua`.
  Run it on a computer in a chunk that stays loaded; it has to keep state
  while nobody is nearby. One per world.
- `smart_glasses` runs the client, which pulls a snapshot at startup and
  follows numbered deltas after that. So a player who was logged out sees
  the same open events as everyone else the moment they log back in.
  Sounds only ever play for deltas - a snapshot is the world as it already
  was, and makes no noise.
- Resolving is global (the condition is handled, for everybody). Snoozing
  (`s`) is local: it hides a line on your own HUD for
  `monitoring.snooze_minutes` and nobody else is affected.

The role's entrypoint is `run-many`, supervising the client, the
night-vision toggle and the ntfy listener, each restarted if it falls over.
It starts `--focus`ed on the client, which gives that program the whole
screen and stops run-many reading the keyboard, so the arrow keys are the
client's; ctrl+tab goes back to the program list and the other two.

Raise and resolve with `bin/alert.lua`, which is both a command and a
one-file library, so an emitting role ships it and nothing else:

    alert critical "Coolant below 20%" --id reactor/coolant --topic energy
    alert resolve reactor/coolant
    alert list

    local alert = dofile("/app/bin/alert.lua")
    alert.raise{ id = "reactor/coolant", message = "Coolant below 20%",
                 severity = "critical", ttl = 60 }
    alert.resolve("reactor/coolant")

Re-raising the same `id` is free: the server keeps one event per id, and
only sends an update (and only makes a noise) if the wording or severity
actually changed. So a polling script needs no memory of what it already
reported - it just says what is true right now, every cycle:

    local alert = dofile("/app/bin/alert.lua")

    while true do
      if batteryPercent() < 50 then
        alert.raise{ id = "battery/main", severity = "warning",
                     message = "Battery below 50%", ttl = 60 }
      else
        alert.resolve("battery/main")     -- a no-op if it wasn't open
      end
      sleep(30)
    end

That is the whole emitter. `raise` deduplicates, `resolve` is harmless
when nothing is open, and `ttl` means the event clears itself a minute
after this script stops saying it - whether the battery recovered or the
computer got unloaded.

`power_monitor` is that pattern as a real role
(`files/nodes/power_monitor/main.lua`): it watches a Mekanism induction
matrix, raises `warning` under 50% and `critical` under 20% on one event
id, and also reports when it can't see the matrix at all. Its thresholds
live in `roles.lua` rather than on the worker, so tuning them is an edit
on the controller:

    power_monitor = {
        config = { peripheral = "inductionPort", warning_at = 0.5,
                   critical_at = 0.2, interval = 30 },
        ...

Two things to get right:

- **Always pass a stable `id`.** Without one the id is derived from the
  message, so a message with a live number in it ("Battery at 43%") opens
  a new event per reading. The server caps open events per computer to
  stop that burying everyone's HUD, but the id is the real fix.
- **Keep the message stable too** while a condition holds. Putting a
  changing number in it is allowed and won't re-alert anybody, but it does
  broadcast an update to every client each cycle.

The `phone` role is a pocket computer with no interface at all: it syncs,
puts `/app/bin` on PATH and drops into a shell, so `alert` and `test-event`
are there to hand. `test-event` covers what raising events by hand needs
and `alert` doesn't - generated ids, bursts, escalating an open event:

    test-event critical "Reactor"   -- one event, id test/<phone>/<n>
    test-event burst 8              -- eight at once, to see the HUD overflow
    test-event up                   -- escalate the newest, which re-alerts
    test-event clear                -- resolve everything this phone raised

Its events carry no topics, so they reach every pair of glasses whatever it
subscribes to, and a ten minute ttl, so forgotten ones tidy themselves up.

Per-client options, set with `set`:

    set monitoring.topics energy,security -- subscribe to topics (default: all)
    set monitoring.hud_lines 6            -- HUD entries before "+N more"
    set monitoring.snooze_minutes 10
    set monitoring.volume 1               -- 0 to 3
    set monitoring.sounds.critical minecraft:block.bell.use

A sound is either a Minecraft sound event or a `.dfpwm` file, told apart by
the extension. The `smart_glasses` role is already set up for the latter: it
ships `files/sounds/` and its `settings` point each severity at
`sounds/<severity>.dfpwm`, so the sounds are configured centrally and not on
each pair of glasses. Put `info.dfpwm`, `warning.dfpwm` and
`critical.dfpwm` in `files/sounds/` on the controller.

**`files/sounds/` has to exist**, or every `smart_glasses` sync fails with
`missing source: sounds/` and the glasses keep running their cached code. A
file that is missing individually is fine: that severity falls back to its
built-in Minecraft sound and the client says so on its footer, because an
alert nobody hears is worse than one that sounds wrong.

A relative sound path is resolved against `/app`, not the working directory.

Files with a `.dfpwm` extension are carried through the bundle as hex and
written as bytes. Everything else is sent as text, which is what used to
happen to dfpwm too - it arrived subtly altered and played as static. Hex
doubles the size on the wire, so keep alert sounds short; add another
extension to `BINARY_EXTENSIONS` in `startup.lua` if something else needs
the same treatment.

The client streams the file a chunk at a time from its own event loop, so a
long sound doesn't stop it noticing events while it plays.

## Gotchas

- `shell` isn't a real global in CC:Tweaked - it's injected only into
  programs launched via `shell.run`/`shell.execute`. `dofile` doesn't
  get it, which is why the ROM launches the loader with `shell.run`
  and not `dofile`.
- The controller resolves `roles.lua`/`files/`/`loader/` relative to
  `shell.getRunningProgram()`, not a hardcoded root, so it works
  whether it's copied onto the computer or run from a disk - even one
  that isn't the first drive attached.
- No auth on the protocol - fine for a private world; add a shared
  secret to the messages if that matters to you.

