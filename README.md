# REAPER Plugin Organizer

A macOS plugin visibility manager with a dockable window inside REAPER. The original local browser utility is also retained.

## Inside REAPER

Requires REAPER 7, ReaImGui 0.10+, and SWS. No Node, browser, server, or compiled extension is needed for this version.

### Install with ReaPack (recommended)

1. Install [ReaPack](https://reapack.com/), [ReaImGui](https://github.com/cfillion/reaimgui), and [SWS](https://www.sws-extension.org/) if needed. Dependencies are installed separately; restart REAPER after installing extensions.
2. Open **Extensions > ReaPack > Import repositories** and paste:

   ```text
   https://raw.githubusercontent.com/jamiethemorris/reaper-plugin-organizer/main/index.xml
   ```

3. Open **Extensions > ReaPack > Browse packages**, search for **REAPER Plugin Organizer**, choose **Install**, then **Apply**.
4. Run **Script: REAPER Plugin Organizer.lua** from **Actions > Show action list**. ReaPack installs the supporting libraries and registers this action automatically; do not run the manual installer.

This package is macOS-only. For updates, save pending organizer changes and close its window, run **Extensions > ReaPack > Synchronize packages**, then reopen the action.

If you previously used the manual installer, remove its old action from the Actions list and reassign any shortcut/toolbar button to the ReaPack action. The manual copy lives under `Scripts/REAPER Plugin Organizer`; ReaPack uses its own repository directory. Removing the old action does not delete your plug-in configuration or backups.

### Manual installation (without ReaPack)

1. In REAPER, open **Actions > Show action list**.
2. Choose **New action > Load ReaScript** and load `reaper/Install Plugin Organizer.lua` from this repository.
3. Run the installer once. It copies the app into your REAPER resource folder, registers **Script: REAPER Plugin Organizer.lua**, and opens it.
4. Use that registered action to reopen the organizer. Assign it a shortcut or add it to a toolbar from the Actions window.

Choose **View > Dock window** to dock or undock it. REAPER remembers the window/table layout.

**View > Follow REAPER theme** is on by default. The organizer uses REAPER's dialog and list colors for its window, table, selected text, inputs, buttons, menus, checkboxes, tooltips, and scrollbars, with compact spacing. Colors refresh within about a second of theme changes, including live color tweaks. Low-contrast text and control states are adjusted for readability; missing colors use neutral fallbacks. Turn this option off to use ReaImGui's default colors. The choice is remembered and does not modify your REAPER theme.

- Click Name, Manufacturer, or Type to sort. Shift-click headers for multiple sort columns.
- Command-click to select individual rows; Shift-click to select a range. Command-A selects the filtered list.
- Uncheck a selected row to hide the whole selection. Show/Hide selected and Space also apply to the selection.
- Existing leading `#` names are unchecked. Search, format, and visibility filters narrow the list.
- Hover any plugin row or checkbox to see likely duplicates, other formats, and their current visible/hidden states. Matching ignores architecture labels such as `x86_64`, manufacturer prefixes, and channel-layout suffixes, but keeps product version numbers distinct. Matches use the entire cache, including plugins outside the current filters; they are suggestions, not proof that two plugins sound or behave identically.
- Use **Format > AU > Uncheck all AU** (or VST, VST3, CLAP) to uncheck an entire format, including its instruments, regardless of search or visibility filters. The list switches to that whole format so you can recheck exceptions. Each format also has **Check all**; **Undo** restores the previous mixed states.
- Click **Save changes** (Command-S) to apply edits; **Undo** (Command-Z) reverses the last unsaved batch.
- Changes to global FX browser names require a **REAPER restart**. Save once finished organizing and restart before rescanning plugins or renaming them in the built-in FX browser.

The script reads the caches for the running macOS architecture, including VST shell entries, VST3, AU and CLAP. Old caches from other architectures and AU bridge metadata files are excluded. JSFX, ReWire, and built-in utility FX are not renamed. Cached entries can include plugins that have since been uninstalled.

Duplicate matching requires the same recognizable manufacturer and a normalized product name (or a cached original name/file identity when renamed). Unknown manufacturers and more substantial naming differences may not match. A "no other match found" result means no match in the loaded cache, not that the product is unavailable in that format.

For manual-install updates, rerun the installer. An already-open organizer is left running to protect unsaved changes; close and reopen it after saving or discarding them.

Saves preserve custom names, instrument markers, and plugin identifiers. They use SWS's INI API so REAPER's file cache stays coherent, check for conflicting edits, and back up all affected files before writing. Backups are under `PluginOrganizerBackups` in the REAPER resource folder; **File > Open backups folder** opens them. To restore, quit REAPER and copy the backed-up INI files to the resource folder. `manifest.txt` identifies any files that did not exist before that save.

REAPER's FX browser option **Show in FX list > Plug-ins whose name begins with #** must be off for these names to be hidden.

### Verification

Run `lua reaper/tests/run.lua` for parser and selection tests. Load the same test script into REAPER to also run save, backup, conflict, and rollback tests through the real SWS API. Tests use temporary fixtures under `build/`; they never edit your plugin configuration.

API references: [REAPER ReaScript](https://www.reaper.fm/sdk/reascript/reascripthelp.html), [ReaImGui](https://github.com/cfillion/reaimgui), [SWS profile API](https://github.com/reaper-oss/sws/blob/master/ReaScript.cpp).

### Publishing ReaPack updates

After changing the main script **or any supporting library**, increment `@version` and update `@changelog` in `reaper/REAPER Plugin Organizer.lua`, then commit and push to `main`. The **ReaPack index** GitHub workflow validates the package, runs portable tests, generates `index.xml` using the official `reapack-index` tool, checks its file list and commit-pinned source contents, and commits the updated index. It can also be run manually from GitHub Actions.

Download URLs are pinned to the source commit so published versions stay unchanged. The index includes only the main script and `reaper/lib/*.lua`, not the manual installer, browser utility, or tests. Existing versions remain in the index; publish a new version rather than editing a released one. To validate locally after generating the index, run `python3 -B tests/test_reapack.py`.

## Original Browser Version

- Reads plugin lists from `~/Library/Application Support/REAPER`.
- Supports VST/VST3, AU, and CLAP cache files.
- Detects plugins already hidden with a leading `#` and shows them as unchecked.
- Sorts by manufacturer, plugin type, name, and source file.
- Supports multi-select rows, then `Hide` or `Show` applies to every selected plugin.
- Clicking a checkbox on a selected row applies that checked state to all selected rows.
- Writes timestamped `.bak-YYYYMMDD-HHMMSS` backups before saving changed REAPER files.

### Run

```sh
npm start
```

The utility opens in your browser at `http://127.0.0.1:48271`.

Close REAPER before saving changes, then reopen REAPER or rescan your plugins so it reads the updated names.
