# Screenshots

Marketing and README screenshots for MultiverseWP live in this folder. Drop
PNGs alongside this README and reference them from `../../README.md`.

## File naming

| Filename              | What it shows                                   |
| --------------------- | ----------------------------------------------- |
| `01-sidebar.png`      | Three-column shell (accounts, chat list, chat). |
| `02-onboarding.png`   | QR onboarding sheet.                            |
| `03-chat.png`         | A chat with a few messages.                     |
| `04-mcp-settings.png` | Settings → AI / MCP install pane.               |
| `05-dark.png`         | Dark-mode variant of the main view.             |

Keep filenames lowercase, hyphen-separated, two-digit prefix for ordering.

## Refresh procedure

macOS has `screencapture` built in. Capture the front window without the
drop-shadow so the image lands flush in the README:

```bash
# Interactive (click a window to capture)
screencapture -i -w -o docs/screenshots/01-sidebar.png

# Whole screen at retina resolution
screencapture -x docs/screenshots/05-dark.png
```

After capture, downscale to a reasonable display size:

```bash
sips -Z 1600 docs/screenshots/01-sidebar.png
```

That keeps the README load quick while preserving retina sharpness.

## Privacy

Never commit a screenshot that contains:

- A real phone number or contact name.
- Real message content from someone who hasn't consented.
- A real QR pairing code (it pairs the capturing device).

Use the demo / synthetic-data harness in `Tests/Fixtures/` when populating
the app before a capture session.
