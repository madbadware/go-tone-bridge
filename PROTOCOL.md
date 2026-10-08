# MIDI protocol

## Identity and translation

| Endpoint | Model ID | Device ID |
|---|---|---|
| JUNO-DS Tone Manager | `00 00 3A` | `10` |
| Original GO:KEYS | `00 00 00 3C` | Keyboard identity reply |
| Original GO:PIANO | `00 00 00 3D` | Keyboard identity reply |

The bridge checks the keyboard identity before creating its virtual ports.
Tone Manager receives this JUNO-DS-compatible identity reply:

`F0 7E 10 06 02 41 3A 02 02 00 00 03 00 00 F7`

The revision bytes identify the compatibility profile, not keyboard firmware.
Roland checksums and seven-bit payloads are checked and recalculated. Addresses,
sizes, parameter payloads and wave numbers are preserved. Split SysEx, running
status and interleaved realtime messages are supported. Hardware sends have a
minimum 4 ms gap. Unrecognized SysEx is rejected.

## Catalogue and compatibility replies

| Address or request | Handling |
|---|---|
| `0F 00 00 04` | Bridge catalogue-cache version `01` |
| `0F 00 00 00` | No-expansion response |
| `0F 00 01 01`, `0F 00 01 03` | Bundled wave-name lists: 861 / 184 entries |
| `0F 00 03 31` | Bundled patch/drum names, selections and categories |
| `0F 00 02 01`, request LSB `40` | Bundled list of 59 factory performances |
| Sample/multisample names and sample-memory queries | Empty/zero responses |
| `0F 00 7F 00`, data `00` or `01` | PC-mode housekeeping handled locally |
| User patch/drum/performance catalogue requests | Individual keyboard name reads converted to Tone Manager catalogue records |

Bundled catalogues are lookup lists; parameter blocks are read directly from
the keyboard. Factory performance program `00` is GM2 Template; the remaining
entries use programs `01` through `3A`. Catalogue lists are not exhaustive. Resource files include neutral source identifiers,
version fields where applicable, and SHA-256 data fingerprints.

User-name reads use `20 slot 00 00` for 128 performances, `30…31 slot 00 00` for
256 patches, and `40 (slot × 10h) 00 00` for 8 drum kits. Names are 12 bytes;
patch reads include the category byte. Drum classification is zero. Name reads
are retried once after a timeout; an incomplete list is reported. Catalogue
completion is sent after all slots answer. Native bulk catalogue requests are
not forwarded. An INIT name does not establish initialized parameter data.

## Write control

**Allow writes** is off by default. When enabled, the bridge forwards ordinary
MIDI except System Reset and DT1 within these address ranges:

| Address | Operation |
|---|---|
| `10…`–`14…` | Temporary performance and parts |
| `1F 00…`–`1F 3F…` | Temporary Patch-mode buffers |
| `01 00 00 00`, one byte `00` or `01` | Patch/Performance mode selection |
| `01 00 00 01`, `…04`, `…07`, three bytes | Bank/program selection |
| `0F 00 20 00`, one byte `00` or `01` | Preview stop/start |
| `20 00 00 00`–`20 7F 7F 7F` | 128 user performances |
| `30 00 00 00`–`31 7F 7F 7F` | 256 user patches |
| `40 00 00 00`–`40 7F 7F 7F` | 8 user drum kits |

Writes crossing a supported range are rejected. All user slots are available,
including whole-bank selections. Write replaces stored data; backups and
destination selection are the operator's responsibility.

Tone Manager's Librarian completion message, `0F 00 10 01` with data `01`, is
handled locally after direct user-memory DT1 writes. No acknowledgement,
readback or save confirmation is fabricated. Read destination data to check a
transfer. System, user-pattern, vocal-effect and sample-storage writes are
outside the supported ranges.

## Preview

Librarian Preview switches to Patch mode and transfers the selected patch to
the temporary Patch-mode buffer. DT1 at `0F 00 20 00` starts playback with data
`01` and stops it with `00`. The keyboard generates playback internally. The
bridge sends Preview Stop on Stop/quit when Preview is active.

The Preview commands are implemented by Tone Manager's
`js/config/editor_setting.js` and `js/config/librarian_setting.js`. Keyboard
model and device IDs are substituted; command address and payload are preserved.

## Reference documents

- [JUNO-DS MIDI implementation](https://static.roland.com/assets/media/pdf/JUNO-DS_MIDI_Imple_eng02_W.pdf)
- [JUNO-DS Tone Manager manual](https://static.roland.com/assets/media/pdf/JUNO-DS_TM_eng02_W.pdf)
