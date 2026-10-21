# Darkslide

## What this is, in plain words

When a photographer comes back from a shoot, the first job isn't editing. It's sorting. Hundreds or thousands of pictures have to come off the memory card, get checked, get the bad ones thrown out, get the good ones starred, get captions and names so they can be found again, and then get handed to the editing program.

The classic tools for that job are fast because they never open the full picture; they show the small preview the camera already saved inside each file. Darkslide is a home-built app that works the same way, natively on current Macs. It:

- **Copies pictures off a card** safely, checking every file against the original so a bad copy gets caught before the card is wiped. It can copy to two places at once, a drive and a backup.
- **Shows them fast** in a grid you can scroll through, with a big preview a keypress away and a filmstrip under it so you never lose your place. A folder navigator on the left (favorites, your places, cards and drives) gets you to the next shoot without a file dialog.
- **Lets you sort** with one key per star, a color label per picture, and a tag for the keepers. Filter down to just the five-stars, or just the reds.
- **Names the files** the way you want, with the date, place, and a running number filled in automatically.
- **Captions them** with the standard fields newspapers and stock agencies read: who, what, where, copyright, keywords. Save a template once, apply it to a whole shoot.
- **Knows where you were.** Paste a location, or match the pictures' times against the track your phone recorded and fill in the city automatically.
- **Hands pictures to your editor** (Affinity, Photoshop, anything) with one key, and when the edited version is saved back, it inherits the caption and stars from the original.
- **Can draft a caption for you.** Out of the box it uses a model running on your own Mac through Ollama (free, nothing leaves the machine). If you'd rather use a cloud model, paste an API key for Anthropic Claude, xAI Grok or Google Gemini in Preferences; the key stays in your Keychain. Either way nothing is written until you approve it.

Everything it writes into a picture is in the same format the legacy app uses, so the two programs can be used side by side on the same folders, and any other photo software reads the stars and labels too.

## Where it stands

The daily workflow (ingest, browse, sort, caption, rename, export) is built and has run a real card through it, and most of the long tail is in too: video, crop, keywords vocabulary, catalog search across folders, GPS from a phone track, FTP upload, HTML galleries, watermarks, printing, slideshow. The full list with what's done is in `CLAUDE.md`. What it needs now is use: a Canon RAW card, a round trip through the legacy app and Affinity, and real jobs.

## Install

```
brew install --cask ghostinthebus/tap/darkslide
```

Or download the zip from the Releases page and drag Darkslide.app to Applications. The app is not notarized: on first launch, right-click it and choose Open.

From source: `./build.sh install` makes an optimised build, copies it to `/Applications/Darkslide.app` and launches it. Settings and templates survive reinstalls; they live in your Library folder, not in the app.

## Caption suggestions (optional)

Preferences › AI. Pick a provider:

- **Ollama (local, free).** Install Ollama from ollama.com, run `ollama pull gemma3:12b` in Terminal (about 8 GB; `gemma3:4b` on small Macs), make sure Ollama is running, press Check. Nothing leaves your Mac.
- **Anthropic Claude, xAI Grok, Google Gemini.** Paste an API key from the provider's console. Keys are stored in the macOS Keychain. Each suggestion uploads one 1024 px preview and is billed to your account.

Then open any photo's IPTC Info (⌘I) and press Suggest. Review, edit, Save.

## Keys you'll use

| Key | Does |
| --- | --- |
| 1 to 5 | Stars (0 clears) |
| ⌘1 to ⌘8 | Color label (⌘0 clears) |
| T | Tag |
| Space or double-click | Open the big preview; arrows move through pictures |
| Click in the preview, or Z | Zoom to 100% at that spot |
| ⌘] and ⌘[ | Rotate |
| ⌘G, ⌘R, ⌘I, ⌘E, ⌘F | Ingest, Rename, Caption, Open in Editor, Find |

All of these can be changed in a small text file.

---

## For the technically minded

**Stack.** Swift and SwiftUI on macOS 14 and later, Apple Silicon only. The grid is an AppKit `NSCollectionView` because SwiftUI grids stutter past a couple thousand items. Built with Swift Package Manager; no Xcode project.

**Speed.** Thumbnails and previews come from the JPEG embedded in each RAW. For TIFF-based RAW (CR2, NEF, ARW, DNG) the app reads the IFD0 JPEG strip directly, which is about twice as fast as asking ImageIO. On a 5616 px Canon file on an M1 Max: thumbnail about 20 ms, fit-to-window preview about 40 ms (a half-size DCT decode), full-size for 100% zoom about 220 ms, loaded only on demand.

**Metadata.** All reads and writes go through one long-lived `exiftool -stay_open` process, bundled inside the app. It writes exactly what the legacy app writes: `xmp:Rating`, `photomechanic:ColorClass`, `photomechanic:Tagged`, `photomechanic:Prefs`, `photomechanic:PMVersion`, the legacy IPTC `Prefs` record, and IPTC fields both through the MWG tags and explicitly as legacy IPTC, embedded in the file rather than in sidecars. It also writes `xmp:Label`, which the legacy app doesn't, so Adobe and Affinity see color labels.

**Build and test.**

```
./build.sh          # debug build → build/Darkslide.app
./build.sh run      # build and launch
./build.sh release
./build.sh test     # engine tests: variables, rename, ingest, captions, GPS track matching
```

Needs Homebrew `exiftool` at build time (it's copied into the bundle) and Xcode or the Command Line Tools. Optional: Ollama with a vision model for caption suggestions.

**Files it keeps**, all plain text, in `~/Library/Application Support/Darkslide/`: `settings.json` (templates, counters, presets), `shortcuts.json`, `user.json`, `code-replacements.txt`, `ingest-logs/`, `ingested.json`, and `logs/darkslide.log` (errors, exiftool diagnostics, ingest results, crashes; Help › Show Log). Attach that log when reporting a problem. Quit the app before editing them by hand; it saves on quit.

**Layout.** `Sources/Darkslide/Models` holds the state, `Services` the engines (image loading, exiftool, variables, ingest, rename, export, GPS, Ollama), `Views` the SwiftUI screens. `Tests/main.swift` is the engine test suite; `Tools/main.swift` is a command-line ingest.

**Name.** "Darkslide" is a working title for a personal build. the legacy app is a trademark of its publisher; this project is not affiliated with them.

## Licence

Darkslide is free software under the GNU General Public License v3.0 or later. See `LICENSE`. Forks and derivatives stay open.
