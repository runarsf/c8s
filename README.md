# Cubernetes (c8s)

## Layout

    controller/
      startup.lua           - the code-serving daemon
      roles.lua             - role -> file list + per-worker config
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
- A role with no entrypoint file (`main.lua` if not overwritten) is **provision-only**
  (synced once at boot, then falls through to a normal interactive shell).
- A role can also define `dest = "setup.lua"`, which will run once via `shell.run`
  right after every sync regardless.

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

