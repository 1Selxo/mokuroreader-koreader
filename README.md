# Mokuro Reader & Catalog Plugin for KOReader

Browse, download, and read manga with mokuro OCR support directly in KOReader — online browsing with full offline reading support!

## Features

- ✅ **Browse Mokuro Catalog**: Search and browse thousands of volumes directly from [Mokuro Bunko](https://mokuro.moe/catalog/) inside KOReader
- ✅ **Offline Downloading**: Fetch both CBZ archives and `.mokuro` OCR sidecar files straight to your device storage for offline reading
- ✅ **Batch Download**: One-tap "Download All Missing Volumes" for an entire series
- ✅ **Flexible Title Display**: Show series titles in Japanese (Native), English, Romaji, or original folder names
- ✅ **Rich Search & Sorting**: Search by English, Romaji, Japanese kanji/kana, or genre; sort by A–Z, Rating, Wordiest (total characters), Volume count, or Newest
- ✅ **Automatic Detection**: Supports both embedded `.mokuro` files inside CBZ archives and external sidecar `.mokuro` files on disk
- ✅ **Comic Panel Zoom Support**: Long-press on any comic panel to zoom in on the artwork, while tapping on text bubbles opens the Mokuro OCR popup
- ✅ **Japanese Right-to-Left (RTL) Reading**: Automatically defaults to Japanese reading direction (tap left to advance) with a one-tap menu toggle
- ✅ **Tap on text bubbles** to see OCR'd Japanese text in a clean popup
- ✅ **Dictionary integration** - long press on words to look them up in your installed dictionaries
- ✅ **Sentence mining** support for VocabBuilder and Anki plugins
- ✅ **Adjustable font size** for better readability
- ✅ **Works on all platforms** - Kindle, Kobo, PocketBook, Android, Linux, etc.

## Installation

1. **Download** the `mokuro.koplugin` folder
2. **Copy** it to your KOReader plugins directory:
   - **Kindle**: `/mnt/us/koreader/plugins/`
   - **Kobo**: `.adds/koreader/plugins/`
   - **PocketBook**: `/system/config/koreader/plugins/`
   - **Android**: `/sdcard/koreader/plugins/`
3. **Restart** KOReader
4. Open a mokuro-processed CBZ and start reading!

## Usage

### Browsing & Downloading from the Mokuro Catalog

1. In KOReader (from either the File Manager or Reader view), open the top menu: **Tools (wrench) → Mokuro Reader → Browse Mokuro Catalog**
2. Browse series, search by name or genre, or change sort order (A-Z, Rating, Wordiest, Volumes, Newest).
3. Tap any series to view its volumes and metadata.
4. Tap **Download** on any volume (or **Download All Missing Volumes**) to download both the CBZ images and the Mokuro OCR data directly to your local storage.
5. Once downloaded, tap **Open in Reader** to start reading immediately offline!

### Preparing Your Own Manga (Optional)

If you have your own manga not on the catalog:

1. Process your manga with mokuro:
   ```bash
   pip install mokuro
   mokuro "path/to/manga/folder"
   ```

2. Either:
   - Create a CBZ with the `.mokuro` file inside, or
   - Keep `Volume.mokuro` alongside `Volume.cbz` in the same directory (sidecar support).

3. Transfer to your e-reader and open in KOReader!

### Reading

1. Open any mokuro CBZ in KOReader.
2. The plugin automatically detects the mokuro OCR data (whether inside the CBZ or as a sidecar `.mokuro` file).
3. **Tap on text bubbles** to see the OCR'd text in a popup at the bottom.
4. **Long press and drag on words** to look them up in your installed dictionaries.
5. Add words to VocabBuilder with automatic context sentence mining!

## Settings

Access plugin settings via: **Menu → Tools → Mokuro Reader**

- **Browse Mokuro Catalog**: Launch the online catalog browser
- **Mokuro Catalog Settings**:
  - **Download Folder**: Choose where downloaded manga and OCR files are saved on your e-reader (e.g. `/mnt/us/manga`, `/sdcard/Books/manga`, etc.)
  - **Series Title Language**: Choose between Native Japanese, English, Romaji, or original folder names
  - **Server URL**: Customize the catalog server URL (default: `https://mokuro.moe`)
  - **Refresh / Clear Catalog Cache**: Force refresh the local cached catalog
- **Enable Mokuro**: Toggle OCR popup detection
- **Font Size**: Medium (32), Large (48), Extra Large (64), Huge (80)
- **Status**: Check currently loaded mokuro document statistics

## Compatibility

- **KOReader**: v2020.01 or newer
- **Mokuro**: v0.2.0 or newer
- **Platforms**: All KOReader platforms (Kindle, Kobo, PocketBook, Android, etc.)
- **File format**: CBZ (ZIP with images + .mokuro file)

## Troubleshooting

### Plugin doesn't detect mokuro file

- Ensure your CBZ contains a `.mokuro` file
- Check the file is valid JSON
- Try re-creating the CBZ with standard compression

### Tap zones don't work

- Make sure the plugin is enabled (Menu → Mokuro Reader)
- Check that the CBZ was correctly processed by mokuro
- Restart KOReader after installing the plugin

## Technical Details

The plugin uses:
- `ffi/archiver` for reading CBZ files (supports all compression types)
- `rapidjson` for parsing .mokuro files
- `DictQuickLookup` for displaying text with dictionary integration
- Touch zones for detecting taps on text bubbles

## License

AGPL-3.0 (same as KOReader)

## Credits

Created for the KOReader community
Based on the mokuro OCR project by kha-white
