# Blaze

A native macOS app for flashing disk images to SD and microSD cards. Pick an image, pick a card, press Flash.

<p align="center">
  <img src="docs/images/main-window.png" width="480" alt="Blaze main window: a Raspberry Pi OS .img.xz selected, showing '524.9 MB compressed → 2.98 GB image' and its SHA-256, with the bootfs card preselected">
</p>

Blaze is a single-purpose system tool built entirely on Apple frameworks — SwiftUI, DiskArbitration, ServiceManagement, Security, Compression, CryptoKit — with zero third-party dependencies. Writing raw bytes to a disk device requires root, and Blaze's rule is **authorize once, never prompt again**: a privileged helper is installed through `SMAppService` behind a single admin prompt, and every flash after that — across relaunches and reboots — runs without asking for anything.

## Features

- **Raw and compressed images** — flashes `.img` directly, and streams `.img.xz` and `.img.gz` through Apple's Compression framework while writing, no temporary decompressed file. The exact image size is read from the xz index (or the gzip trailer) in milliseconds, shown as *"525 MB compressed → 2.98 GB image"*.
- **Verify after write** (on by default) — reads the card back and compares it byte-for-byte against the image, reporting the exact byte offset of the first mismatch. Compressed images are re-decoded for the comparison.
- **SHA-256 of the image** — computed in the background and shown compacted (`4518dba…863e907`); click to copy the full digest for checking against a publisher's checksum.
- **Smart card picker** — external disks are score-ranked by how likely they are to be an SD card (removability, size, bus, media name), the best candidate is preselected, and non-removable drives (external NVMe/SSD/HDD enclosures) never appear at all. The list updates live on insert/remove via DiskArbitration — no polling, no rescan button mashing (though ⌘R exists).
- **Mount blocking** — while a flash runs, the helper dissents every mount of the target disk, so macOS can't auto-mount a half-written filesystem and scribble Spotlight/fseventsd metadata over it (a real corruption mode this feature was born from). Optionally (Settings, on by default) Blaze blocks auto-mounting of *all* removable media while the app is open; disk images and fixed external drives are unaffected, and normal behavior returns on quit.
- **Defense in depth** — the root helper re-derives every fact about the target itself and refuses to write anything that is not an external, non-boot whole disk that the image fits on. It validates its XPC peer's code signature (team + bundle ID), and the app pins the helper's identity in return. A UI bug cannot overwrite your boot drive.
- **Won't-fit handling** — a too-large image disables Flash up front with both sizes named; when the size is unknowable (gzip images over 4 GB), the helper stops cleanly at the device boundary instead.
- **Progress you can trust** — determinate bar with real MB/s and ETA through Unmounting → Writing → Syncing → Verifying → Ejecting; indeterminate with a live byte counter when the total genuinely isn't known.
- **Silent helper updates** — the daemon exits when idle, so launchd always spawns the binary shipped inside the current app bundle; updating Blaze never re-prompts.
- **Simulate mode** — hold ⌥ and the Flash button becomes *Simulate (no write)*: the full pipeline runs (safety gates, decode, progress, verify-read) against `/dev/null` with the card untouched.
- **Native throughout** — keyboard-first (⌘O open, ⌘R rescan, ⌘↩ flash, ⎋ cancel), drag-and-drop, destructive confirmation sheet that names exactly what will be erased, light/dark, remembers the last image and card across launches.

## Screenshots

| Confirmation before an unrecoverable write | Settings |
|:---:|:---:|
| <img src="docs/images/confirm-sheet.png" width="380" alt="Erase this card? sheet naming the card, its size, and the image with its hash, with a Verify after writing checkbox and a red Erase and Flash button"> | <img src="docs/images/settings.png" width="380" alt="Settings: Verify after writing, Block auto-mount of removable disks, and Privileged helper status showing Installed"> |

## Building

Requirements: macOS 26, Xcode 26, and an Apple Development signing identity.

1. Clone and open:

   ```sh
   git clone <repo-url> blaze && cd blaze
   open blaze.xcodeproj
   ```

2. **Set your signing team** on both targets (`blaze` and `BlazeHelper`). If your team is not `27FVN4FG7D`, also update the pinned team ID in the two code-signing requirement strings — `BlazeHelper/PeerValidator.swift` (helper validates the app) and `blaze/Service/HelperManager.swift` (app validates the helper). These pins are the privilege boundary; don't remove them.

3. Build and run (⌘R in Xcode, or):

   ```sh
   xcodebuild -scheme blaze -configuration Debug build
   ```

   The build produces `blaze.app` with the helper embedded in `Contents/MacOS/` and its launchd plist in `Contents/Library/LaunchDaemons/`.

4. **First launch** — onboarding installs the privileged helper: one admin password prompt, never again.

5. **First flash** — macOS asks once to allow Blaze access to files on removable volumes (this permission is what gates raw device access; Full Disk Access is *not* needed). Click Allow and the write proceeds; subsequent flashes are prompt-free.

### Development notes

- The helper binary supports a standalone gate check: `com.klockenga.blaze.helper --validate diskN` prints `ALLOW`/`REFUSE` with the reason, without XPC or a UI.
- The safest way to exercise the real write/verify path is a disk image: `hdiutil create -size 100m -layout NONE -o scratch -type UDIF && hdiutil attach -nomount scratch.dmg` yields a user-owned `/dev/rdiskN` the full pipeline can run against.
- Helper changes deploy on the next launch after the daemon idle-exits (~15 s after the app quits). Protocol changes must bump `blazeHelperVersion` in `Shared/BlazeHelperProtocol.swift`, which triggers an automatic re-registration.
