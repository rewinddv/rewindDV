# Local CLI and MCP control

`rewinddv` is a native command-line client for the running rewindDV LAB app. The
same executable also serves MCP over standard input/output. Commands use the
app's existing playback, preservation, capture and driver models; the app owns
all source files, capture state and deck connections. Start the app and accept
its alpha notice before sending commands.

Build the client with the selected Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build \
  --package-path Foundation --product rewinddv
```

Run `Foundation/.build/debug/rewinddv status` or put the built executable on
`PATH`. Commands take `key=value` arguments and print one JSON object. Use an
absolute path for every file or directory argument. Quote arguments containing
spaces:

```sh
rewinddv playback.open "path=/Volumes/DV/Capture 001.dv"
rewinddv playback.seek seconds=12.5
rewinddv playback.metadata
rewinddv surgery.range first=100 end=125
rewinddv surgery.export "destination=/Volumes/Derived"
```

Operations that scan or export return immediately. Poll the matching `.status`
command for completion, error, progress, and output path. A new export creates
a separate directory; the source is never overwritten. `rewinddv` without a
command lists the available commands. Omitting a command's required arguments
prints the required argument names.

For an MCP client, configure a local stdio server with command set to the
absolute path of the `rewinddv` executable and arguments set to `["mcp"]`.
The server implements MCP `2025-06-18` `initialize`, `ping`, `tools/list` and
`tools/call`. Each command appears as a tool named `rewinddv_...`, with dots
replaced by underscores. For example, `playback.metadata` is exposed as
`rewinddv_playback_metadata`. Tools return JSON in both text content and
`structuredContent`; rejected operations set `isError`.

The app listens on a mode-0600 Unix socket in its own temporary container and
checks that each peer has the same user ID. The MCP process writes protocol
messages only to stdout. It accepts no remote connections.

The app sandbox requires a user grant before it can open a new external file
or write to a new external folder. Choose that source or destination in the
app for the current session, then use its path in CLI/MCP commands. Grants may
need to be renewed after restarting the app. A path that the shell can read
is not automatically readable by the app. The app's own container paths are
available without a new grant. This is a current limit on unattended use of
previously ungranted paths; commands report it explicitly.

Playback, Surgery, archive verification, evidence maps, scene review, review
queues, multi-pass comparison, forensic prefix export, and recovery-plan
preparation work without the DriverKit extension. Deck and capture commands
require the matching driver, a selected operational deck, and the app's normal
operation guards. `driver.activate` only presents the app's confirmation;
macOS approval remains interactive. Recovery-plan commands never move tape.
Physical supervised recovery passes remain an attended GUI operation with
physical-tape and STOP confirmations. Do not use generic deck/capture tools as
a substitute for that supervised recovery workflow.
