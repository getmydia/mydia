# Library Types Reference

Complete reference of the library types Mydia supports and what each one does.

| Type | Description | Features |
|------|-------------|----------|
| **Movies** | Feature films | Full metadata, downloads, quality profiles |
| **Series** | TV shows with seasons/episodes | Episode tracking, air dates, season monitoring |
| **Mixed** | Combined movies and TV shows | Both movie and series features |
| **Music** | Music collections | Scanning, browsing, and MusicBrainz metadata (experimental) |
| **Books** | E-books and audiobooks | Scanning, browsing, and Open Library metadata (experimental) |
| **Adult** | Adult content | Scanning and browsing only (experimental) |

!!! warning "Experimental Library Types"
    Music, Books, and Adult libraries are experimental and do far less than the
    Movies and Series types. None of them get download automation or quality
    profiles: nothing searches indexers or grabs releases for them, so they only
    ever show files you already have on disk.

    They do differ in metadata, though:

    - **Music** enriches artists and albums from MusicBrainz through the metadata
      relay, and fetches album cover art.
    - **Books** enriches from Open Library, matching on ISBN where the file
      provides one.
    - **Adult** is genuinely scan-only. Everything shown comes from the files and
      their paths.
