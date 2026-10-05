# Desktop Files

A Noctalia v5 desktop widget that shows your Desktop folder (`XDG_DESKTOP_DIR`,
usually `~/Desktop`) as a themed, paginated icon grid.

## Features

- Folders and files on a grid, paged when they don't fit, with arrows and page dots.
- Recolorable Adwaita (Nautilus) folder and file icons that follow your Noctalia
  palette, or your own images. Image files show thumbnails, `.desktop` files show the
  app's icon and name, and known file types use your icon theme.
- Click to select. Double-click to open with `xdg-open` (launchers use `gio launch`).
- Arrange mode lets you rearrange icons. Positions are saved across restarts.

## Rearranging

Press the lock button in the pager, or run `arrange` over IPC, to enter arrange mode.

1. Click an icon to pick it up. A preview follows the cell under the pointer.
2. Click a cell to drop it. Dropping on another icon swaps the two icons.
3. Hold the pointer on the left or right edge to flip to the adjacent page. Set the
   delay with **Edge page-flip delay**.
4. Hover a page dot to jump to that page. The hollow dot after the last page is a new
   page.
5. With **Snap to grid** off, the icon lands where the pointer is inside the cell.

Desktop widgets can't do press-and-hold dragging in Noctalia. Hover is frozen while a
mouse button is held, and drag-and-drop is only available in panels. So moving is done
as a click to pick up and a click to drop.

## Settings

Folder, layout name, columns, rows, grid size, icon size, snap to grid, edge flip delay,
background color and opacity, folder, file icon and label colors, custom icons, image
thumbnails, file-type icons, and hidden files.

The grid is drawn at its natural size and Noctalia scales it into the box you draw in
the desktop-widget editor. Pick columns and rows that match the box's aspect ratio.

## IPC

```sh
noctalia msg plugin vedantd/desktop-files:desktop focused next
noctalia msg plugin vedantd/desktop-files:desktop focused prev
noctalia msg plugin vedantd/desktop-files:desktop focused page 3
noctalia msg plugin vedantd/desktop-files:desktop focused first
noctalia msg plugin vedantd/desktop-files:desktop focused last
noctalia msg plugin vedantd/desktop-files:desktop focused arrange toggle   # on | off | toggle
noctalia msg plugin vedantd/desktop-files:desktop focused cancel
noctalia msg plugin vedantd/desktop-files:desktop focused rescan
```

`next` and `prev` wrap around at the ends. `page N` is 1-based and is clamped to the
pages that exist. Use a connector name such as `DP-1`, or `all`, instead of `focused`
to target other monitors.

## Install (development)

```sh
noctalia msg plugins source add dev path ~/noctalia-desktop-files
noctalia msg plugins enable vedantd/desktop-files
```

Then add **Desktop Files** in the desktop-widgets editor.

Requires `xdg-utils`. `file` is used for type detection and falls back to file
extensions if missing. `gio` launches `.desktop` files.
