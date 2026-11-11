# scripts

Standalone game scripts. Nothing here is part of the NYX executor itself.

## hypershot.luau

Aim assist, ESP, triggerbot, chams and a hitbox helper for **Hypershot!** (Frosted Studio).

Open the game, then run the loader:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/troubledkiller69-lgtm/nyx-scripts/main/hypershot.luau"))()
```

`scripts/` mirrors into the public `nyx-scripts` repository, which is what the loadstring above pulls
from. `scripts/hypershot-loader.luau` is the same call with error handling and a compile check.

| Input | Action |
| --- | --- |
| Right Shift | show / hide the panel |
| Right Mouse (hold) | aim assist |
| Delete | panic — removes every drawing, highlight and hook |

Defaults are all off except ESP. Config lives in the `CFG` table at the top if you would rather
edit values than click buttons.

### What actually holds up

- **ESP** — box, name with `[P]` / `[BOT]` tag, health bar normalised to `MaxHealth` (200 in this
  game), distance, optional tracer, head dot and `Highlight` chams. Projects off `Head` and
  `HumanoidRootPart`, so it survives R6 and R15 rigs.
- **Aim assist** — picks the target closest to the crosshair inside the FOV, sorts out spawn
  protection, then drives either `Camera.CFrame` (bound above `RenderPriority.Camera` so the game
  cannot overwrite it mid-frame) or `mousemoverel` in `Mouse` mode.
- **Triggerbot** — fires through `mouse1press` with a `VirtualInputManager` fallback when the
  crosshair is inside a small pixel window.
- **Bots** — enemies that are not in `Players:GetPlayers()` are tagged `[BOT]`. Hypershot fills
  lobbies with bots carrying real names, and `Players:GetPlayerFromCharacter` is the only reliable
  split between the two.

### Known limits

- The hitbox expander changes part sizes on the client only. Hypershot resolves most weapon hits
  on the server, so expect it to help with client-side raycasts and not much else.
- `Drawing` is required for ESP. Executors without it will still run the aim and trigger code but
  show nothing.
- Spawn protection detection is attribute/tag based (`spawn`, `immune`, `protect`). If Frosted
  renames those, the aim assist will briefly track protected players.
- Duels are not special-cased, unlike the big public hubs. Add a check on the current place or the
  match state if you care.
