# Hypershot — NYX v3

Standalone Luau script with a Rayfield interface. Run in Hypershot:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/troubledkiller69-lgtm/nyx-scripts/main/hypershot.luau"))()
```

The error-reporting entrypoint is `hypershot-loader.luau`. Hold **Right Mouse** to
aim, **K** toggles Rayfield, and **Delete** unloads this script. Configurations save
under `NYX/hypershot`. Release aim and press again to choose a fresh target.

## Targeting

- **Closest enemy (default):** smallest world-space distance from your character,
  among eligible visible targets inside the aim FOV and maximum target distance.
  Falls back to camera position while your character has no root part.
- **Closest to crosshair:** smallest screen-space offset.
- **Lowest health:** lowest current Humanoid health; ties use crosshair offset.
- **Sticky lock (default on):** retains the first target. A closer opponent does
  not steal the lock. Turn this off to continuously re-rank by your preference.
- **Lock retention FOV bonus:** extends the acquisition FOV for an existing lock.
  Death, team changes, protection, leaving the retention FOV, or leaving target
  range release it immediately. A hidden target retains its lock for the configured
  visibility grace (550 ms default), with no aiming while visibility is lost.
- **Ignore teammates (default on):** applies to aim, trigger, hitboxes, ESP and
  chams. Checks non-neutral Player.Team values and common character team attributes.
- **Target group:** players + bots, players only, or bots only. Here “bot” means a
  Humanoid model without a matching Player character; unrelated NPCs may qualify.
- **Skip spawn-protected targets:** checks ForceField, boolean protection/immunity
  attributes, and matching tags. Custom game protection/team data may need adapters.

Acquisition remains limited to the FOV: “closest” does not target enemies behind you.
Changing preferences clears the current lock. Aim release and focus loss also clear it.

## Visuals

Boxes, labels, health bars, distances, tracers and chams have independent controls.
**Rainbow ESP** colors all Drawing overlays; **Rainbow chams** colors highlight fill
and outline. They share an adjustable 1–20 second color cycle. Enable ESP and Chams
to display rainbow chams. Disabling rainbow restores each feature's static colors.

Chams opacity and through-wall visibility are adjustable. Visual bot and distance
filters apply to both overlays and chams. The ESP master toggle disables both.

## Performance and lifecycle

- Character discovery runs at most five times per second; active target validation
  and aim updates remain per frame. Discovery covers Player characters and Humanoid
  models at workspace root or directly inside workspace folders.
- Visual refresh is adjustable from 15–120 Hz (60 default, capped by actual FPS).
- One rainbow color is computed per visual refresh and shared across actors.
- Sticky lock avoids a full candidate scan while its target remains valid.
- Visibility rays are cached for 50 ms, independently of aim/trigger visibility
  settings. Brief visibility changes may therefore take up to 50 ms to reflect.
- Exponential smoothing uses delta time; camera turn and mouse-step limits are
  time-scaled. Actual mouse response still depends on executor/game sensitivity.
- Departed actors' drawings, highlights and visibility cache entries are removed.
  Delete disconnects this version's event handlers and render binding and restores
  modified hitbox sizes and saved walk speeds.

**Updating from v1/v2:** rejoin once before loading v3. Those versions did not retain
all their event connections, so v3 cannot disconnect every callback they left behind.
Subsequent v3 reloads use tracked cleanup.

## Interface and checks

Uses the existing **Gen2 fan-made Rayfield** classic-API implementation from
`SyncOfficialSpec/Rayfield_Gen_2_fanmade`, with `sirius.menu/rayfield` and the existing
raw-source mirror as fallbacks. These remotely loaded UI dependencies are not pinned.
If every UI source fails, the configuration remains accessible through
`getgenv().NYX_HYPERSHOT.config`.

Luau compilation and isolated regression scenarios check target ranking, lock
retention/expiry, team filtering, smoothing and visual lifecycle. They do not verify
live Hypershot camera behavior, executor compatibility or Rayfield rendering.
Drawing overlays require the executor's Drawing API. Mouse aim requires a locked
cursor and working `mousemoverel`; camera mode is selectable in Aim. Hitbox changes
are client-side; server acceptance is unverified.

In the parent repository, run:

```powershell
python tools/check-hypershot.py --luau <path-to-luau.exe>
```

Public releases mirror the parent repository's `scripts/` directory. Earlier
revisions remain available in Git history for rollback; the v2 public revision is
`f3eeb0062cfda60bdc25848465ae9352206d04b2`.
