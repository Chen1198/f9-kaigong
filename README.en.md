# F9 Workday Launcher

> One keypress opens everything you need every morning. Built **only** from components that ship
> with Windows — no Python, no .NET runtime install, **no admin rights, no registry writes, no
> network**. Unzip and run.

**English** · [中文](README.md)

![Launchpad](screenshots/hub-1-launchpad.png)

Double-click the one desktop icon and this **launchpad** appears: a single wooden fish. Tap the fish
and your workday starts — it brightens on hover, and answers with a soft bounce and a short
electronic chime. The line underneath tells you how many items are on today's list.
**The launchpad deliberately shows one thing only: start work.**

Everything else lives behind the settings window, so the screen you look at every morning stays
simple.

---

## What it does

Put WeChat, WPS, DingTalk, your ERP, your supplier portals… into a list once. From then on, one
keypress opens all of them in order, and a small progress window in the bottom-right corner shows
what is happening.

It started as a favour for a friend who runs an office-supplies shop — he was clicking a dozen
icons by hand every morning before opening. It is generic now: **any repeated "getting started"
ritual can be handed to it.**

## Requirements

- Windows 10 or 11 (the built-in Windows scripting host is enough)
- Nothing else. No installation of runtimes, no administrator account.

## Quick start

1. Download this repo (`Code` → `Download ZIP`) and unzip anywhere, e.g. `D:\WorkdayLauncher`.
   > ⚠️ The path **may contain non-ASCII characters**, but do **not** put it under
   > `C:\Program Files` or any folder that needs administrator rights.
2. **Unblock the files first** — otherwise Windows will refuse to run the `.bat` files:
   right-click the ZIP → Properties → tick **Unblock** → OK, *before* extracting.
   (Already extracted? Run `Get-ChildItem -Path . -Recurse | Unblock-File` in that folder.)
3. Double-click **`install.bat`**. A single **F9开工** icon appears on your desktop.
4. Open the settings: search for **F9开工** in the Start menu → **F9开工 · 设置**
   (or double-click `设置.bat` in the program folder).
5. Tick the apps you want (【添加软件】 lets you browse for them), paste the URLs you want in ②.
6. Click **【保存并生效】 (Save and apply)** in the bottom-right.
7. Every morning from then on: press **`F9`** or **`Ctrl+Alt+W`**. Prefer the mouse?
   Double-click the desktop icon and tap the wooden fish — same thing.
8. Before you leave: press **`Ctrl+Alt+Q`** — shutdown / restart / sleep, with a countdown you can
   cancel at any point.

## Hotkeys

| Key | Action |
|---|---|
| `F9` or `Ctrl+Alt+W` | Start work (both work by default; fully configurable) |
| `Ctrl+Alt+Q` | Finish work — shutdown / restart / sleep |

Notes:

- `F9` is a single key, and it is **swallowed globally** by this tool, so pressing F9 inside Excel
  no longer recalculates formulas. That is why `Ctrl+Alt+W` ships as an extra default.
- Finish-work asks for an action, then **waits 60 seconds** (configurable, 5–600) before doing
  anything. Cancel / `Esc` / the window's × all stop it immediately.
- Shutdown deliberately does **not** pass `/f`, so Windows asks about unsaved documents exactly like
  the Start-menu shutdown does.

## Features

| | |
|---|---|
| **One icon, one action** | The desktop has a single **F9开工** icon. Double-click it and you get the launchpad. |
| **Settings stay out of the way** | Change the list, the skin or the easter eggs from **F9开工 · 设置** in the Start menu. |
| **Instant response** | ~0.1–0.2 s from keypress to the first app actually appearing. The progress window shows up 30–80 ms after the key. |
| **A progress bar that does not lie** | It keeps flowing until the app's window really exists on screen (e.g. `starting WeChat… (12.4 s so far)`), instead of pretending everything is done the moment a command was issued. |
| **Never opens the same thing twice** | If an app is already running it is skipped — and its existing window is **brought to the front**, so something always visibly responds. Duplicate list entries only launch once. |
| **Four skins** | Minimal / Ink / Morandi / Indigo. Switching takes effect immediately, desktop icon included. |
| **Launch easter eggs** | Float your own sticker on screen and play your own voice clip when work starts. |
| **Bilingual UI** | Chinese / English, one click in the settings window. |
| **Zero dependencies** | Windows' own script host + WinForms. No third-party components at all. |
| **No phone home** | No network calls whatsoever. Your list is a plain `config.json` next to the program — readable and deletable. |
| **Clean uninstall** | Double-click `uninstall.bat`: shortcuts removed, background process stopped, autostart removed. |

## Privacy

The tool makes **no network requests at all**. You can verify that yourself: search the sources for
`HttpClient`, `Invoke-WebRequest` or `WebClient` — there are none. Your app list and settings live
only in `config.json` on your own machine, and `config.json` / `logs/` are in `.gitignore` so they
are never committed.

## Inspecting before you run

Reasonable. Three things worth checking:

1. No network calls exist anywhere in the code (see above).
2. `Start-Workday.ps1 -Check` is a **read-only** self-check — it changes nothing and opens nothing.
   Run it first if you like.
3. `Start-Workday.ps1 -DryRun` prints what *would* be opened, and opens nothing.

```powershell
# read-only self-check
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Workday.ps1 -Check

# what would be opened, without opening it
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Workday.ps1 -DryRun
```

## FAQ

**Windows says "Windows protected your PC" / SmartScreen blocks it.**
Expected for any unsigned `.bat` / `.ps1`. Click **More info** → **Run anyway**. All the code is in
this repo, so you can read it first.

**After unzipping, double-clicking `install.bat` keeps showing confirmations or says the file is
blocked.**
That is the Mark-of-the-Web that Windows attaches to downloaded files — the file is not corrupt.
Unblock the ZIP before extracting, or run `Get-ChildItem -Path . -Recurse | Unblock-File`.
Clicking "Run anyway" works too, just once per file.

**Pressing `F9` does nothing.**
① Most often the background process is not running — it is started at login, so it will not come
back after a lock/unlock alone. **Double-click the desktop icon**: opening the panel now detects
this and starts it for you. ② The key may be taken by another program (single-key `F9` especially) —
pick a different key, or keep `Ctrl+Alt+W` in the list.

**WeChat itself takes 20+ seconds to appear — is that this tool's fault?**
No. On a 2012-era dual-core laptop that is simply how long a cold WeChat start takes when only
0.7–0.9 GB of RAM is free. Start-up method was measured four ways, and this tool's path was the
fastest of them. The useful fix is freeing memory, not changing the launcher.

**Can it start an app as administrator?**
Windows does not allow a normal program to elevate silently. Putting a shortcut in the list will not
work (UAC would prompt). Handle those programs separately.

## Skins, easter eggs and every other detail

See the full Chinese documentation — **[README.md](README.md)** — which covers the four skins with
screenshots, the finish-work window, the launch easter eggs, the complete `config.json` reference,
custom skins and the development notes. `README.txt` next to the program is the same guide in plain
text, for reading without a Markdown viewer.

## License

[MIT](LICENSE)
