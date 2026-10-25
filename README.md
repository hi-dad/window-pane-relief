# Window Pane Relief

<img src="images/icon.png" alt="Window Pane Relief app icon" width="128">

**A tiny Mac menu bar app: pin any window on top of everything, and keep working in both.**

<img src="images/ad.gif" alt="Window Pane Relief ad: clicking into notes buries a video; press Control-Option-P to pin it, and it stays on top while you type and open other apps; click it to jump back in, pin any window from the menu bar, press Control-Option-P again to unpin" width="720">

### [⬇️ Download Window Pane Relief](https://github.com/hi-dad/window-pane-relief/releases/latest/download/WindowPaneRelief.dmg)
Free · macOS 13 or newer · always the latest version

## Install

1. Open **WindowPaneRelief.dmg** and drag the app into **Applications**.
2. Open it, and click **Open** when macOS asks if you're sure. (It's signed and checked by Apple.)
3. Allow **Screen Recording** and **Accessibility** when asked, then quit and reopen it.

## How to use it

- Make the window you want small and put it where you like.
- Press **⌃⌥P** (or pick it from the pin icon in the menu bar) to pin it.
- Click into your big window and work as usual. The pinned one stays on top, and clicking it puts you straight back in it.
- Press **⌃⌥P** again, or right-click the pinned window, to unpin.

Good to know: both windows need to be on the same desktop (not full screen). To drag inside the pinned window, click it once first.

**Updates:** it offers new versions itself (or pin icon → **Check for Updates…**). **Remove:** pin icon → **Quit**, then drag it to the Trash.

<details><summary>Build it yourself</summary>

Needs Xcode or the Command Line Tools.

```bash
./scripts/build-app.sh        # builds, installs to Applications and opens it
./scripts/build-app.sh dist   # also makes dist/WindowPaneRelief.dmg
```

Run `swift run WindowPin --debug` to see what it's doing.

</details>

MIT License
