# Library Types Reference

Complete reference of the library types Mydia supports and what each one does.

| Type | Description | Features |
|------|-------------|----------|
| **Movies** | Feature films | Full metadata, downloads, quality profiles |
| **Series** | TV shows with seasons/episodes | Episode tracking, air dates, season monitoring |
| **Mixed** | Combined movies and TV shows | Both movie and series features |

Every type scans for video files only. A library holding music, e-books, images
or any other non-video content has nothing for Mydia to index.

Movies, Series and Mixed libraries can all be imported from the **Import** page
(see [Importing an Existing Collection](../how-to/import-existing-collection.md)).
There is no per-type restriction on importing.

!!! warning "Music, Books and Adult libraries were removed in v0.13.3"
    Those three types were experimental, never got download automation or
    quality profiles, and are gone. An existing library path of one of those
    types converts to **Mixed** and stops being monitored on upgrade; its files
    are left where they are.

    Leave a converted path unmonitored. A Mixed scan looks for video files
    only, so everything else in the directory would be treated as deleted and
    moved to the trash store. Remove the path, or point it at video content.
