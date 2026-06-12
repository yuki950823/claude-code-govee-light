# Govee light ↔ Claude Code status signaling

Drive a Govee **H8022 (Aura) lamp** from Claude Code: the light changes color to
show what Claude is doing (thinking, needs approval, idle, done…). Controlled
locally over Wi-Fi via the Govee **LAN API** (UDP) — no cloud, no API key at runtime.
Ships with a browser **control panel** to dial in colors/gradients per state.

> The cloud Govee API does **not** support the H8022 (it authenticates but lists no
> devices). The LAN API is the only path, so **"LAN Control" must be ON** in the Govee
> Home app: *Device → Settings → LAN Control*.
>
> **LAN limitation:** the LAN API only sets the *whole lamp* to one color at a time, so
> effects are **temporal** (fades/pulses over time). True **spatial** gradients (different
> colors on different segments at once, like the Home app) need Govee's segment/BLE
> protocol and are not in the LAN API. See "Roadmap" below.

---

## Quick start on a new PC

1. **Clone** this repo somewhere, e.g. `C:\Tools\govee` (path can be anything; you'll
   reference it in the hooks below).
2. **Enable LAN Control** in the Govee Home app (*Device → Settings → LAN Control*), and
   make sure this PC is on the **same Wi-Fi** as the lamp (not a guest/IoT VLAN).
3. **Find the lamp** (creates/updates `govee-config.json`):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\govee-light.ps1 -Discover
   ```
4. **Smoke test** — should turn the lamp green:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\govee-light.ps1 -Event done
   ```
5. **Wire up the Claude Code hooks** — add the block below to your settings
   (`%USERPROFILE%\.claude\settings.json` for all projects, or a project's
   `.claude\settings.json`). **Replace `CLONE_PATH` with where you cloned this repo.**
6. **(Optional) Control panel** — start the local server and open the UI:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\govee-server.ps1
   # then open http://localhost:8099/
   ```

### Hooks block (replace `CLONE_PATH`)

Every hook runs the same dispatcher; it reads the event from stdin. Set `CLONE_PATH`
to your clone location (use `\\` as the separator in JSON).

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "powershell", "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","CLONE_PATH\\govee-light.ps1"], "timeout": 10 }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "powershell", "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","CLONE_PATH\\govee-light.ps1"], "timeout": 10 }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "powershell", "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","CLONE_PATH\\govee-light.ps1"], "timeout": 10 }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "powershell", "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","CLONE_PATH\\govee-light.ps1"], "timeout": 10 }] }],
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "powershell", "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","CLONE_PATH\\govee-light.ps1"], "timeout": 10 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "powershell", "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","CLONE_PATH\\govee-light.ps1"], "timeout": 10 }] }]
  }
}
```

---

## States

| State        | Hook(s)                       | Default effect              |
|--------------|-------------------------------|-----------------------------|
| `thinking`   | `UserPromptSubmit`, `PostToolUse` | purple→magenta flow (working) |
| `permission` | `Notification` (approval)     | (customized — see panel)    |
| `waiting`    | `Notification` (idle)         | blue breathe                |
| `done`       | `Stop`, `SubagentStop`        | green breathe               |
| `start`      | `SessionStart`                | rainbow flow                |
| `rest`       | `SessionEnd`                  | solid green (animation off) |

Any state's color is **customizable** in the control panel (saved to
`govee-states.json`); saved colors override the built-in defaults above.

## How it works

- **`govee-light.ps1`** — dispatcher. Hooks call it; it maps the hook event to a state,
  bumps the **generation token**, sends the first color frame instantly, then launches
  the animator. Reads `govee-states.json` so the instant first frame matches your saved color.
- **`govee-animate.ps1`** — the per-state animation loop (runs until superseded).
- **`govee-gradient.ps1`** — generalized two-color gradient loop (used by the panel's live preview).
- **`govee-server.ps1`** — local HTTP server (`localhost:8099`) for the control panel; relays
  the browser's commands to the lamp over UDP.
- **`govee-control.html`** — the control panel UI (color wheel, gradients, per-state settings).
- **`govee-states.json`** — saved per-state colors/gradients.
- **`govee-config.json`** — `{ deviceIP, device, sku }`, the lamp's LAN address. Created by
  `-Discover`; gitignored (your IP/MAC stays local). Shape shown in `govee-config.example.json`.
- **`generation`** — runtime token (auto-managed; gitignored).

**Generation token = no process sweeps.** Every effect change just writes a new token to
the `generation` file; each running animator re-reads it every frame and self-exits the
instant it's superseded. So status changes are near-instant and animators never pile up.

## Manual use

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\govee-light.ps1 -Event done        # green breathe
powershell ... -Event thinking     # purple flow
powershell ... -Event permission   # the saved permission color
powershell ... -Event waiting      # blue breathe
powershell ... -Event start        # rainbow flow
powershell ... -Event rest         # stop animation, hold solid green
powershell ... -Event off          # stop animation, turn light off
powershell ... -Discover           # refresh the lamp IP in govee-config.json
```

## If the light stops responding

1. The lamp's IP probably changed (DHCP) — run `-Discover`. Best fix: give it a **DHCP
   reservation** (static IP) in your router.
2. Confirm **LAN Control** is still ON in the Govee Home app.
3. Confirm the PC and lamp are on the **same** Wi-Fi network/band (no guest/IoT VLAN).
4. Multicast discovery must go out the active Wi-Fi adapter; if discovery fails on a PC
   with multiple adapters/VPNs, disable the others temporarily and retry.

## Roadmap

- **Spatial multi-color gradients** (several colors across the lamp at once, like the Home
  app): requires Govee's segment protocol via a LAN `ptReal` tunnel or direct BLE — known
  but not yet implemented here.
