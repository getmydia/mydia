# Importing an Existing Collection

If you already have media files organized on disk, Mydia can bring them into a library by scanning, without searching for or downloading anything. If you want media you do not have yet, see [Adding Media](add-media.md) instead.

## Import Existing Media

If you have existing media files, Mydia can import them during library scanning:

1. Place your media files in the library directory
2. Trigger a library scan (or wait for a scheduled scan, if you have enabled one for this library)
3. Mydia will match files to metadata and import them

### File Naming

For best results, use standard naming conventions:

**Movies:**
```
Movie Title (Year)/Movie Title (Year).mkv
```

**TV Shows:**
```
Show Title (Year)/Season 01/Show Title - S01E01 - Episode Title.mkv
```

## The Import Page

For bulk imports, use **Import** in the sidebar. It scans a library you have
already configured; you do not browse to a folder from inside it.

1. Click **Import Files** on the dashboard, or go to **Import** in the sidebar
2. Pick the library you want to bring in from the tabs at the top
3. Click **Start scan**
4. Once the scan finishes, review the matches below it, correcting any Mydia
   got wrong, then accept them

If the library you want is not on the list, add it first. See
[Managing Libraries](manage-libraries.md).

The [Import Your First Movie](../tutorials/first-library-import.md) tutorial walks
through the same page with a single file, if you would rather see it once before
running it against a whole collection.

### Automatic Import

The **Automatically import confident matches in this run** checkbox on the scan
form controls what a scan does with a high-confidence match:

- **Checked** (the default): the scan matches and imports confident results on
  its own, leaving only uncertain or unmatched files for you to review.
- **Unchecked**: the scan discovers and matches files but leaves every result,
  confident or not, for you to review and accept by hand.

A library's **Automatic scanning** schedule (see
[Managing Libraries](manage-libraries.md)) uses the same distinction for its
own unattended runs: off, a scheduled scan only maintains files Mydia already
knows about; on, it also discovers new files and imports confident matches
without a manual scan.

### Reviewing Results

Below the scan controls, results are grouped by folder and filtered into
**Ready**, **Needs attention**, and **No match** chips, plus an **Ignored**
chip for anything you have dismissed. Dismissing a result is durable: it
survives later scans of the same library, and survives **Clear** too.

**Clear** removes unresolved scan results and finished scan history for the
selected library so the next scan starts fresh, but it never removes a result
you have already dismissed -- that decision stays exactly as you left it.

## Next Steps

- [Managing Libraries](manage-libraries.md) - Configure automatic and manual scanning
- [Adding Media](add-media.md) - Search for and download new media
