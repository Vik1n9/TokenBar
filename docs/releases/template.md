Unofficial tool. Not affiliated with, endorsed by, or sponsored by any of the
services it reads from.

## Install

1. Download the `.dmg` below and open it.
2. Drag `TokenBar.app` onto the `Applications` shortcut, then eject the image.
3. **First launch only** — the app is not notarized by Apple (that requires a
   paid Developer ID), so macOS quarantines it. Clear the flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/TokenBar.app
   ```

   Then open it normally, or right-click the app → **Open** → **Open**.

Requires macOS 13 or later. The binary is universal (Apple Silicon and Intel).
