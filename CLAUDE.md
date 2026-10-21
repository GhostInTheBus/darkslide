# Darkslide: developer notes

Darkslide is a native Apple Silicon photo ingest, culling and captioning app in Swift and SwiftUI, built with SwiftPM (no Xcode project). It works the way the classic ingest tools do: every thumbnail and preview is the JPEG already embedded in the RAW, never a RAW decode, and all metadata is read and written through one long-lived `exiftool -stay_open` process bundled inside the app.

## Build and test
`./build.sh run` builds and launches `build/Darkslide.app`; `./build.sh install` makes a release build in /Applications; `./build.sh test <scratch dir> <folder of RAW files>` runs the engine tests (variables, rename, ingest, captions, GPS track, catalog, export, and every RAW format when `~/Projects/raw-samples` exists); `./build.sh watch <scratch dir> <folder of RAW files>` runs the folder-watcher test headless (another app writing metadata, files added, renamed, removed, bursts, cache eviction). `build.sh` sets `DEVELOPER_DIR` to /Applications/Xcode.app when present. Settings, shortcuts, templates, catalog and ingest logs live in `~/Library/Application Support/Darkslide/` as plain files.

## Key decisions
The speed comes from showing the JPEG preview already embedded in each RAW file, the same trick the legacy app uses.

| Area | Choice | Why |
| --- | --- | --- |
| Language and UI | Swift and SwiftUI, Apple Silicon only, macOS 14 or newer | Native speed, no Rosetta, nothing to retire in 2027 |
| Distribution | Personal build with App Sandbox off, not on the App Store | The sandbox blocks running exiftool and opening any folder freely |
| Thumbnail grid | AppKit collection view wrapped for SwiftUI | SwiftUI grids stutter at thousands of items |
| Grid thumbnails | Apple ImageIO reading the embedded preview | Milliseconds per file, no RAW decode |
| Full screen preview | Largest embedded JPEG pulled by exiftool, cached on disk | Sharp enough to judge focus, still fast |
| Metadata read and write | exiftool kept running in batch mode | Handles IPTC and XMP for every camera format |
| Stars, labels, tags | Embedded XMP and IPTC in RAW and JPEG, same as the legacy app prefs; sidecar only for video or when a file already has one | the legacy app is set to embed (sidecar off), so every tagged RAW you own carries its data inside; both apps must agree while running side by side |
| Label fields | Write both `photomechanic:ColorClass` and `xmp:Label` | the legacy app only writes its own ColorClass field; Affinity and Adobe read `xmp:Label` |
| Copy safety | Checksum every copied file | A bad copy gets flagged before the card is wiped |
| Settings and templates | Plain JSON and text files | Easy to back up, edit by hand, or sync |

## Metadata compatibility
Cull state is written as `xmp:Rating`, `XMP-photomech:ColorClass`, `XMP-photomech:Tagged`, `XMP-photomech:Prefs` (`Tagged:ColorClass:Rating:FrameNum`) and `XMP-photomech:PMVersion`, plus the legacy IPTC `Prefs` record, embedded in RAW and JPEG rather than sidecars, so classic tools and this app can share a folder. `xmp:Label` is written with the color class name for Adobe and Affinity. IPTC fields go through the MWG tags and explicitly as legacy IPTC. Rotation is the EXIF orientation tag. Crops are Adobe `crs` fractions.

## Variables
These work in rename templates, folder templates and every caption field, so {datesort}, {filenamebase} and the rest behave the way you'm used to. the legacy app's short forms like {fbas} and {dats} work too.

| Group | In v1 |
| --- | --- |
| Dates and times | {date} {datesort} {datesortdash} {year4} {year2} {month0} {monthname} {day0} {hour24} {minute} {second} {time} {timesort} |
| Files | {filename} {filenamebase} {folder} {frame4} |
| Sequence | {seqn} (also {sequence}), {ingestseq} |
| Camera and exposure | {make} {model} {serial} {lens} {lenstype} {iso} {f} {shutter} {focallength} |
| IPTC fields | {caption} {headline} {byline} {credit} {copyright} {city} {state} {country} {location} {event} {keywords} {slug} |
| Job and rating | {jobname} {rating} {colorclass} |

Full list of 273 the legacy app variables with short aliases, pulled from the legacy app binary: [[the legacy app Variables]].

## Testing and performance targets
Has to feel at least as fast as the legacy app on the same folders. Starting targets, adjust after the first real test.

| Check | Target |
| --- | --- |
| First thumbnails after opening a folder | Under 1 second |
| 2,000 RAW files fully thumbnailed from a local SSD | Under 30 seconds (measured 2026-10-20: 6.7 s, first thumbnail 0.1 s; metadata read 10.6 s) |
| Next or previous image in full screen | Feels instant (under 0.1 second) |
| Ingest copy speed | Limited by the card reader, not the app |
| Copies with a checksum mismatch | Zero |

- Canon is the main target. CR3 and CR2 files carry a full size JPEG inside, so full screen and 100% zoom come straight from the preview.
- Any camera has to work: every format in the sample set must show thumbnails and full screen, and take stars and captions.
- Rename a test card with the usual the legacy app template; the names have to match what the legacy app produces, sequence numbers included.
- Edit a captioned CR3 in Affinity and save a JPEG; the app has to copy the caption and keywords into it.
- Run the new app and the legacy app on the same folders and compare stars, labels and captions with exiftool.
- Check what was written with `exiftool -a -G1` on a sidecar or JPEG.
- Don't trust a real assignment to the new app alone until ingest passes on three test cards.

## Feature checklist
Every feature of the classic ingest tools, ticked as it exists here. Items marked (skip) are licensing, demo or disc burning and will not be built.

**Core, in progress**
- [x] Contact sheet, Preview window, Zoomed thumbnail, video in the sheet with playback in preview
- [x] Rating, color class, tag, filters, Select similar rating/class
- [x] Ingest, Live ingest (polls the card every 10 s while on)
- [x] Rename photos, Set sequence, Variables palette
- [x] IPTC Info, IPTC Stationery Pad, Snapshot name, Customize IPTC fields (Preferences > Captions), Clear IPTC fields
- [x] Adjust capture times (Update IPTC/XMP, Revert RAW: later)
- [x] Copy/Move photos, Save As (export presets), editor mapping (single editor; droplets later)
- [x] Preferences (general, color classes, user, shortcuts, captions, local AI), Help > Keyboard Shortcuts (⌘/)

**Metadata and search**
- [x] Find, Find and replace (⌘F)
- [x] Quick search (filter bar), Custom sort (primary + secondary), Select date range, Select range, Save/Load selection
- [x] Search panel = Catalog window (⌘⇧F)
- [x] Structured keywords (`keywords.txt` vocabulary, hierarchy, synonyms, find), keywords panel, autocomplete history per field (Edit IPTC list)
- [x] Code replacement (`code-replacements.txt`, \code\ in caption fields)
- [x] Delete metadata, Remap color class, Remap rating
- [ ] Convert IPTC encodings, Mask/unmask (legacy, not planned)
- [x] Info variable (Preferences > Captions > preview info line)

**GPS**
- [x] Set GPS coordinates, Reverse geocode (Apple geocoder), Show map, Import GPS coordinates from a GPX track or Home Assistant phone history (camera zone and clock offset)
- [x] Set GPS home, Set GPS to home

**Output**
- [x] Send via email, AirDrop, Messages
- [~] FTP/FTPS/SFTP upload exists (⌘U) but is out of scope and untested; decided 2026-10-21 not to spend time on it
- [x] HTML gallery export, Export video clip (passthrough trim), Watermarking (text, per preset), Set DPI, Convert RAW to DNG (via Adobe DNG Converter if installed), Extract JPEG previews
- [ ] Embed ICC (not planned; export already converts to sRGB)
- [x] Print contact sheet (⌘P), Slideshow (⌘L)
- [x] Print proofs (one per page)
- [x] Rotate (⌘] ⌘[, EXIF orientation like the legacy app's soft rotation)
- [x] Mirror, Crop (C in preview, drag, Return; stored as Adobe crs crop and applied on export)
- [ ] Lossless JPEG rotation (soft rotation only)
- [x] Edits saved beside the original inherit its metadata; Affinity-only badge; Move to Trash; sort; select similar; context menu

**Catalog (the legacy app's catalog tier)**
- [x] Catalog (SQLite index of chosen folders, search across captions/keywords/places/ratings, results as a contact sheet), remove folder
- [x] Update folder location, saved searches

**(skip)** About, Registration, Activation, Demo, Software update, Tip of the day, Burn to disc, Help browser

## Layout
`Sources/Darkslide/Models` holds state (`Library` is the @MainActor app model), `Services` the engines (image loading and caches, exiftool, variables, ingest, rename, export, GPS, catalog, keywords, Ollama), `Views` the SwiftUI screens; the grid is an `NSCollectionView`. `Tests/main.swift` is the engine suite, `Tools/main.swift` a command-line ingest.
