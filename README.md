# scripts

Standalone game scripts. Nothing here is part of the NYX executor itself.

## hypershot.luau

Aim assist, ESP, triggerbot, chams and a hitbox helper for **Hypershot!** (Frosted Studio), running on
a Rayfield window.

Open the game, then run the loader:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/troubledkiller69-lgtm/nyx-scripts/main/hypershot.luau"))()
```

`scripts/` mirrors into the public `nyx-scripts` repository, which is what the loadstring above pulls
from. `scripts/hypershot-loader.luau` is the same call with error handling and a compile check.

### interface

Rayfield, loaded in this order until one works:

1. `SyncOfficialSpec/Rayfield_Gen_2_fanmade` — the Gen2 look, classic API
2. `sirius.menu/rayfield` — official stable channel
3. `sirius-menu/rayfield` raw source

If all three fail the script still runs headless: ESP and aim keep their defaults and `getgenv()`
holds the config. Rayfield hides with **K** by default, **DELETE** is the panic key.

### aim, how it actually turns

The v1 aim wrote `Camera.CFrame` every frame, which is what made it fight the game and jitter. v2
drives the game's own input instead:

- **Mouse method (default).** Measure the on-screen error between the crosshair and the target, then
  feed a capped fraction of that error into `mousemoverel`. The game rotates its own camera, so there
  is nothing to fight, and the loop is closed — if the error shrinks, the step shrinks, so it glides
  to a stop instead of overshooting.
- **Camera method.** Direct `CFrame` write with a 22°/frame ceiling, for executors where the mouse
  path is blocked.

`Smoothness` maps to the per-frame fraction on an exponential curve: `0` snaps at ~85% of the error
per frame, `100` creeps at ~6%, default `55` lands around 20% — about a fifth of the gap closed per
frame, which reads as a fast, smooth pull.

`Max step` caps how far the aim can drag in a single tick, so a target that jumps across the screen
cannot yank the view.

### stickiness

Locking is hysteresis, not a timer:

- the current target is kept while it is inside `FOV × (1 + Stickiness)` — wider than the acquire FOV,
  so a body drifting toward the edge does not get dropped
- a different body only steals the lock if it is `Switch margin` (22%) closer to the crosshair
- line of sight is cached for 100 ms, so a passing railing does not strobe the lock on and off
- the lock survives 0.55 s after the target disappears, which covers a dash, a slide or a corner peek
- when the target exists but is behind cover, the aim holds still instead of pulling through the wall

Defaults: FOV 110 px, stickiness 70%, head, hold Right Mouse, visible only.

### the rest

- **ESP** — box, name with `[P]` / `[BOT]` tag, health bar normalised to `MaxHealth` (200 in this
  game), distance, tracer, `Highlight` chams. Projects off `Head` and `HumanoidRootPart`, so R6 and
  R15 both work.
- **Bots** — anything not in `Players:GetPlayers()` is `[BOT]`. Hypershot outfits bots with real
  names; `Players:GetPlayerFromCharacter` is the only honest split.
- **Triggerbot** — fires through `mouse1press`, with a `VirtualInputManager` fallback, when the
  crosshair is inside a pixel window.
- **Hitbox expander** — client-side part scaling, restored on toggle-off and on panic.

### known limits

- Hitbox scaling is client-side. Hypershot resolves most weapon hits on the server, so treat it as an
  aid, not a guarantee.
- Spawn protection is detected from attributes and tags named `spawn`, `immune` or `protect`. If
  Frosted renames those, aim will hug protected players until the name changes.
- The Mouse method needs the cursor locked (`MouseBehavior` not `Default`); with an unlocked cursor it
  refuses to move so it cannot drag the pointer around the screen.
- Duels are not special-cased.
