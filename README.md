# mod_manager

`/manage <mod|modpack> on|off [force]` turns mods on or off by editing the
world's `world.mt` (`load_mod_<name>` lines). Luanti reads it at startup, so a
change takes effect after the next restart.

- `/manage list` lists the mods and modpacks of the world (not the game's).
- `/manage <name>` shows whether a mod, or each mod of a modpack, is on.
- A modpack's name (a folder with `modpack.conf` or `modpack.txt`) covers
  every mod inside it, nested modpacks too. `/manage 3d_armor off` turns off
  the whole pack, even though it holds a mod called `3d_armor`.
- Turning something on needs its dependencies on; turning it off is refused
  while an enabled mod depends on it (the server wouldn't start). Add `force`
  to override.
- Game mods are always loaded, so they can't be switched; they count as on.
- It can't turn itself off.

Needs the `mod_manager` privilege (admins have it). It needs no insecure
environment: mods may write to the world folder.
