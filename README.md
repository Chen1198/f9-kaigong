# F9 Workday Launcher

**English** · [中文](README.zh-CN.md)

[![platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?logo=windows&logoColor=white)](#requirements)
[![powershell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#requirements)
[![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](#privacy)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

> **One hotkey opens your whole morning.** Every app and website you use every day, opened in
> order, in one keypress. Made only from what already ships with Windows — **no runtime to
> install, no admin rights, no registry writes, no network**.

![The launchpad](screenshots/hub-1-launchpad.png)

Double-click the single desktop icon and this **launchpad** appears: one wooden fish. Tap the
fish and your workday starts — it brightens when you hover, and answers with a small bounce and
a soft wooden *tap*. The line underneath tells you how many items are on today's list.

The launchpad deliberately does **one thing only**: start work. Everything else lives in the
settings window, so the screen you look at every morning stays quiet.

---

## What it does

Put WeChat, WPS, DingTalk, your ERP, your supplier portals… into a list once. From then on:

- Press **`F9`** (or `Ctrl+Alt+W`) and they all open, in order.
- A small progress window slides in at the bottom-right and shows what is happening.
- If something is already running, it is **skipped** — and its existing window is brought to the
  front, so something always visibly responds.

It began as a favour for a friend who runs an office-supplies shop: he was clicking a dozen icons
by hand every morning before opening. It is generic now — **any repeated "getting started" ritual
can be handed to it.**

---

## Requirements

- **Windows 10 or 11.** The PowerShell 5.1 that ships with Windows is all it needs.
- Nothing else. No Python, no .NET runtime download, no administrator account.

---

## Quick start

1. **Download** this repo (`Code` → `Download ZIP`) and unzip it anywhere, e.g. `D:\WorkdayLauncher`.

   > ⚠️ The path **may contain non-ASCII characters**, but do **not** put it under
   > `C:\Program Files` or any other folder that needs administrator rights.

2. **Unblock the files first** — otherwise Windows refuses to run the `.bat` files.
   Right-click the downloaded **ZIP** → Properties → tick **Unblock** → OK, *then* extract.
   Already extracted? Run this in the folder instead:

   ```powershell
   Get-ChildItem -Path . -Recurse | Unblock-File
   ```

3. **Double-click `install.bat`.**

   > On a first install it asks one question — the interface language:
   > `[1] English` / `[2] 中文`.
   > **Doing nothing is fine**: after 10 seconds it continues with your system language
   > (English system → English). You can change it later in Settings.

4. A single **`F9开工`** icon appears on your desktop. (The name is the app's own — it means
   "start work". The icon is the wooden fish.) Your config file is created for you, so it works
   straight away.

5. **Open the settings:** search for **F9开工** in the Start menu → **F9开工 · 设置**
   (or double-click `设置.bat` in the program folder).

6. Tick the apps you want (【添加软件】 lets you browse for them) and paste the URLs you want
   into section ②.

7. Click **【保存并生效】** (*Save and apply*) at the bottom-right.

8. From then on, every morning: press **`F9`** — done.
   Prefer the mouse? Double-click the desktop icon and tap the wooden fish.

9. Before you leave: press **`Ctrl+Alt+Q`** — shutdown / restart / sleep, with a countdown you
   can cancel at any point.

---

## Hotkeys

| Key | What it does |
|---|---|
| `F9` or `Ctrl+Alt+W` | **Start work.** Both work by default; fully configurable. |
| `Ctrl+Alt+Q` | **Finish work** — shutdown / restart / sleep, with a cancellable countdown. |

Notes:

- `F9` is a **single key**, and it is swallowed globally while this tool runs — so pressing F9 in
  Excel no longer recalculates formulas. That is exactly why `Ctrl+Alt+W` ships as a second
  default. If `F9` clashes with something you use, pick a different key in the settings.
- You can put more than one key in a slot, separated by `/`.

---

## Interface language

Chinese and English are both fully written out — not placeholder machine translation.

- **Choosing it at install time.** On a first install, `install.bat` shows a two-line prompt:
  press `1` for English or `2` for 中文, then Enter. If you press nothing for 10 seconds it just
  continues with your **system language** — an English Windows stays English, a Chinese Windows
  stays Chinese. So the common case needs no input at all.
- **Changing it later.** Open the settings → **界面语言 / Language** → pick 简体中文 or English →
  Save. Only the labels change; your list is untouched.
- **Where it is stored.** One line in `config.json`:

  ```json
  "lang": "en"
  ```

  Everything the tool prints — the launchpad, the progress window, the finish-work window and the
  installer — follows that one value.

> On a re-install the installer **keeps whatever language you already chose** and does not ask
> again, so it can never silently flip your setup back.

---

## What you get

| | |
|---|---|
| **One icon, one action** | The desktop holds a **single** icon. Double-click it and you get the launchpad; tap the fish and work starts. |
| **Settings stay out of the way** | List, skin, hotkeys and extras live in **F9开工 · 设置** in the Start menu. The launchpad itself shows one thing only. |
| **Instant response** | Measured: **0.1–0.2 s** from keypress to the first app actually launching. The progress window is on screen 30–80 ms after the key. |
| **A progress bar that does not lie** | It keeps flowing until the app's window really exists on screen — `starting WeChat… (12.4 s so far)` — instead of pretending everything is done the moment a command was issued. On a slow machine it waits as long as your machine really needs. |
| **Never opens the same thing twice** | If an app is already running it is skipped **and its window is brought to the front**, so pressing the key always produces a visible result. Duplicate entries in the list only launch once. |
| **Finish work in one key** | `Ctrl+Alt+Q` → shutdown / restart / sleep, with a **60-second countdown** you can cancel with `Esc`, the Cancel button, or the window's ×. Shutdown deliberately does **not** pass `/f`, so Windows asks about unsaved documents just like the Start-menu shutdown does. |
| **Heals itself** | If the background watcher is not running (for example after a lock/unlock), double-clicking the desktop icon starts it again and tells you so. |
| **Four quiet skins** | Minimal / Ink / Morandi / Indigo. Switch from the dropdown and it applies **immediately**, desktop icon included. |
| **Launch extras** | Optionally float your own sticker on screen and play your own voice clip (or have Windows speak a line) when work starts. Off by default. |
| **Zero dependencies** | Windows' own script host plus WinForms. Nothing third-party to install. |
| **No phone home** | No network requests anywhere. Your list is a plain `config.json` next to the program — readable, editable, deletable. |
| **Clean uninstall** | Double-click `uninstall.bat`: shortcuts removed, background process stopped, auto-start removed. The folder is left for you to delete. |

---

## Appearance

Four skins, applied instantly — the desktop icon changes with them:

| Minimal (default) | Ink |
|---|---|
| ![Minimal](screenshots/skin-1-minimal.png) | ![Ink](screenshots/skin-2-ink.png) |

| Morandi | Indigo |
|---|---|
| ![Morandi](screenshots/skin-3-morandi.png) | ![Indigo](screenshots/skin-4-indigo.png) |

The progress window uses the same palette — left: running, right: finished:

| Minimal | Ink |
|---|---|
| ![Running](screenshots/progress-minimal-run.png) | ![Running](screenshots/progress-ink-run.png) |
| ![Done](screenshots/progress-minimal-done.png) | ![Done](screenshots/progress-ink-done.png) |

## Finish work

| Pick an action | Countdown |
|---|---|
| ![Pick](screenshots/quit-en-1-pick.png) | ![Countdown](screenshots/quit-en-2-count.png) |

Pick how long to wait (60 s by default, 5–600), then shutdown / restart / sleep. The window turns
into a **large countdown number** — nothing happens until it reaches zero, and you can cancel at
any moment. The last seconds are visible, so you always have time to change your mind.

---

## Privacy

The tool makes **no network requests at all**. You do not have to take that on faith — search the
sources for `HttpClient`, `Invoke-WebRequest` or `WebClient`: there are none.

Your app list and settings live only in `config.json` on your own machine, and `config.json` plus
`logs/` are listed in `.gitignore` so they are never committed.

## Inspecting it before you run it

Reasonable. Three things worth checking:

1. **No network calls** anywhere in the code (above).
2. **`Start-Workday.ps1 -Check`** is a read-only self-check: it opens nothing and changes nothing.
3. **`Start-Workday.ps1 -DryRun`** prints what *would* be opened, and opens nothing.

```powershell
# read-only self-check
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Workday.ps1 -Check

# show what would be opened, without opening it
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Workday.ps1 -DryRun
```

---

## FAQ

**Windows says "Windows protected your PC" / SmartScreen blocks it.**
Expected for any unsigned `.bat` / `.ps1`. Click **More info** → **Run anyway**. The entire source
is in this repo, so you can read it first.

**After unzipping, double-clicking `install.bat` keeps showing confirmations or says the file is blocked.**
That is the Mark-of-the-Web Windows attaches to downloaded files — the file is not corrupt.
Unblock the ZIP *before* extracting, or run `Get-ChildItem -Path . -Recurse | Unblock-File`.
Clicking "Run anyway" works too, once per file.

**Pressing `F9` does nothing.**
① Most often the background process is not running — it starts at login, so it does not come back
after a lock/unlock alone. **Double-click the desktop icon**: opening the panel now detects this
and starts it for you. ② The key may be taken by another program (a single-key `F9` especially) —
pick a different key, or keep `Ctrl+Alt+W`.

**I want it in my own language.**
Chinese and English ship today; the switch is in the settings. The wording lives in one lookup
table per script, so adding a language is a translation job, not a rewrite — PRs welcome.

**WeChat itself takes 20+ seconds to appear — is that this tool's fault?**
No. On a 2012-era dual-core laptop, that is simply how long a cold WeChat start takes when only
0.7–0.9 GB of RAM is free. Four different start-up methods were measured and this tool's path was
the fastest of them. The useful fix is freeing memory, not changing the launcher.

**Can it start an app as administrator?**
Windows does not allow a normal program to elevate silently. Putting a shortcut in the list will
not work (UAC would prompt). Handle those programs separately.

**Does it slow down my boot?**
The background watcher is started at login and then waits for a keypress — it does no polling and
no disk work while idle. It also pre-warms its own windows so the first keypress after boot is not
slower than the rest.

---

## Files, and how to remove it

| File | What it is |
|---|---|
| `install.bat` / `uninstall.bat` | Install and remove |
| `Start-Workday.ps1` | The main program (background watcher + launchpad + progress window) |
| `Settings-GUI.ps1` | The settings window |
| `config.json` | **Your list and settings** — created on install, safe to edit or delete |
| `logs/` | Plain-text log, one file per month |
| `run-*.vbs` | Tiny launchers so nothing flashes a black console window |

Everything is plain text. If the tool ever does something you do not expect, the log says exactly
what happened and why.

---

## More detail

The Chinese guide — **[README.zh-CN.md](README.zh-CN.md)** — is the full documentation: every
option with screenshots, the complete `config.json` reference, custom skins, and notes for anyone
changing the code. `README.txt` in the program folder is the same guide as plain text, for reading
without a Markdown viewer.

## License

[MIT](LICENSE)
