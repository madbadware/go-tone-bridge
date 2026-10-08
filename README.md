# GO Tone Bridge

A macOS MIDI bridge for using **JUNO-DS Tone Manager 1.01** with an original
**Roland GO:KEYS or GO:PIANO**. Translates MIDI identities and model IDs, supplies
Tone Manager catalogue data, and connects parameter reads and writes to the
keyboard. Not affiliated with Roland.

## Download

[**Download GO Tone Bridge for macOS**](https://github.com/madbadware/go-tone-bridge/releases/latest/download/GO-Tone-Bridge-macOS-universal.zip)

Requires macOS 13 or later. Supports Apple silicon and Intel Macs.
No build tools are required. JUNO-DS Tone Manager is installed separately.

Extract the ZIP, move **GO Tone Bridge.app** to **Applications**, and open it.
The app is locally signed and is not notarized. If macOS blocks the first launch,
open **System Settings → Privacy & Security → Open Anyway**.
See [Apple's instructions](https://support.apple.com/en-us/102445).

## Getting started

1. Open **GO Tone Bridge.app**.
2. Connect the keyboard by USB or Bluetooth and select its MIDI input/output.
3. Enable **Allow writes** for editing, Preview or Librarian Write, then click
   **Start**. Leave it off for read-only access.
4. Click **Open Tone Manager**. In its **System** tab, select
   **JUNO-DS GO Bridge** for both MIDI input and output.
5. Open **Editor → Performance → Read**. A part's **Edit** button opens its
   patch parameters, including the **WAVE** page.

Stop before changing bridge options or reconnecting the keyboard. Use one bridge
instance and one Roland application at a time. Stop or quit removes the virtual
MIDI ports and stops active Preview playback.

## Patches and performances

The Editor reads the current temporary sound. The Librarian reads stored user
memory: choose a mode, select rows, then click **Read**. Its initial INIT rows
are local defaults; they do not describe the keyboard's stored data.

For third-party files, use Tone Manager's Load/Import functions. Select rows to
**Preview** or **Write**, with **Allow writes** enabled. Preview loads a patch
into temporary memory and starts the keyboard's internal playback. Write
replaces selected user-memory slots. Back up stored data before replacing it.
Read destination rows back to check a transfer.

User memory provides 128 performance, 256 patch and 8 drum-kit slots. Catalogue
names are read from the keyboard. Factory choosers use bundled lists containing
59 performance entries and 1,377 patch/drum selections per model. These lists
do not enumerate every possible engine sound.

Addresses, parameter data and wave numbers are preserved. Missing samples are
not supplied. System, sample, multisample and expansion-storage functions are
unsupported.

## Logging

**Record MIDI log** is optional and off by default. Files are written to
`~/Library/Logs/GO Tone Bridge/`. Each connection gets a timestamped filename;
collisions receive `-1`, `-2`, and so on. Existing logs are preserved.
**Show log** opens the file location. No network access or
telemetry is used.

## Build from source

Requires Apple's Command Line Tools or Xcode.

```sh
./build.command
```

The build runs the automated checks and creates `dist/GO Tone Bridge.app`.
`Launch.command` builds the application if needed and opens it.

## Troubleshooting

- **No keyboard listed:** connect Bluetooth in macOS Audio MIDI Setup or connect
  USB, then click **Refresh devices**.
- **No identity reply:** check both selected keyboard ports and its connection,
  then retry **Start**.
- **Tone Manager reports no JUNO-DS:** start the bridge first, then select its
  virtual ports for both input and output in **System**.
- **Librarian Read does nothing:** select rows before clicking **Read**.
- **Patch mode, Preview or Write does nothing:** stop the bridge, enable
  **Allow writes**, then start it again.

See [PROTOCOL.md](PROTOCOL.md) for message formats and supported address ranges.

## License

[MIT](LICENSE).
