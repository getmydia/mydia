# Import Your First Movie

This tutorial picks up where [Get Mydia Running](get-mydia-running.md) left off. You have Mydia running with an admin account and an empty movies library. By the end of this one, that library holds one movie, matched and complete with a poster and metadata, without touching a download client, an indexer, or any external service. It takes about 5 minutes.

You need a running Mydia instance with the movies library from that tutorial. If you haven't done that yet, start there first.

## Step 1: Create a Placeholder File

Mydia doesn't need a real video to import something, just a file with the right name in the right place. On the host machine, inside the media directory you mapped in your compose file, create an empty file:

```bash
touch "/path/to/your/media/library/movies/Big Buck Bunny (2008).mkv"
```

Use that name exactly. Mydia reads the title and year straight out of the filename (`Title (Year).extension`) to search for a metadata match, so `Big Buck Bunny (2008).mkv` gives it exactly what it needs. A file named `bbb.mkv` would scan in just as easily but leave Mydia with nothing to search for. The name is the lesson: get it right and matching is automatic.

## Step 2: Trigger a Library Scan

Open Mydia in your browser and click **Import Files** on the dashboard, the same page you landed on after creating your admin account. Your **Movies** library tab is already selected.

Click **Start scan**. Mydia scans the folder and searches for a metadata match for anything it finds, with **Automatically import confident matches in this run** checked by default.

## Step 3: Watch It Get Matched and Imported

Because the filename parsed cleanly, the match is confident, and automatic import is on, Mydia imports it on its own once the scan finishes -- there is nothing left to review for this file.

## Step 4: See the Result

Open **Movies** in the sidebar. Big Buck Bunny is there with its poster. Click it to see the full metadata page, including the synopsis, all pulled from a filename and a scan.

## What You Just Did

You brought a file into a library with nothing but a correctly named placeholder and a scan; Mydia handled the search, the match, and the metadata itself. That is the same mechanism behind importing a real collection, just with one file instead of thousands.

- For a full existing collection, see [Importing an Existing Collection](../how-to/import-existing-collection.md).
- To have Mydia find and download media for you automatically, see [Connecting a Download Client](../how-to/connect-download-client.md).
