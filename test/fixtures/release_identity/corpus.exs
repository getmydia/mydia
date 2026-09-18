# Release identity corpus. Every row is a fictional stand-in for a pattern seen
# when production grab history was replayed through ReleaseIdentity, including
# the real releases the rule knowingly rejects ("accepted loss").
[
  # --- names that are the item -------------------------------------------
  %{
    note: "scene dotted movie",
    type: :movie,
    title: "Glass Harbor",
    year: 2031,
    release: "Glass.Harbor.2031.1080p.WEB-DL.DDP5.1.H.264-GROUP",
    expect: :match
  },
  %{
    note: "spaced name, parenthesized year",
    type: :movie,
    title: "Glass Harbor",
    year: 2031,
    release: "Glass Harbor (2031) (1080p BluRay x265 HEVC 10bit AAC 5.1 Group)",
    expect: :match
  },
  %{
    note: "no year in the name",
    type: :movie,
    title: "Glass Harbor",
    year: 2031,
    release: "Glass.Harbor.1080p.WEB-DL.x264-GROUP",
    expect: :match
  },
  %{
    note: "year off by one",
    type: :movie,
    title: "Glass Harbor",
    year: 2031,
    release: "Glass.Harbor.2030.1080p.WEBRip.x265-GROUP",
    expect: :match
  },
  %{
    note: "hyphenated title written with a space",
    type: :movie,
    title: "Moth-Man: Far From Shore",
    year: 2029,
    release: "Moth Man.Far.from.Shore.2029.1080p.BluRay.DDP5.1.x265.10bit-GROUP",
    expect: :match
  },
  %{
    note: "hyphenated title written as one word",
    type: :movie,
    title: "Moth-Man: Far From Shore",
    year: 2029,
    release: "Mothman.Far.From.Shore.2029.720p.WEBRip.x264-GROUP",
    expect: :match
  },
  %{
    note: "apostrophe and number",
    type: :tv_show,
    title: "Q-Force '97",
    year: 2024,
    release: "Q Force '97 (2024) Season 2 S02 (1080p DSNP WEB-DL x265 HEVC 10bit DDP 5.1 Group)",
    expect: :match
  },
  %{
    note: "ampersand spelled out",
    type: :movie,
    title: "Salt & Cedar",
    year: 2031,
    release: "Salt.and.Cedar.2031.1080p.WEBRip.x265-GROUP",
    expect: :match
  },
  %{
    note: "year-suffixed show title",
    type: :tv_show,
    title: "Dark Lantern (2024)",
    year: 2024,
    release: "Dark.Lantern.2024.S02E02.1080p.HEVC.x265-GROUP",
    expect: :match
  },
  %{
    note: "site prefix the parser strips",
    type: :tv_show,
    title: "Dark Lantern (2024)",
    year: 2024,
    release:
      "www.UIndex.org    -    Dark Lantern 2024 S02E03 Everything Quiet 1080p ATVP WEB-DL DDP5 1 H 264-GROUP",
    expect: :match
  },
  %{
    note: "second site prefix style",
    type: :movie,
    title: "Quiet Orchard",
    year: 2031,
    release:
      "www.1TamilMV.top - Quiet Orchard (2031) HQ PreDVD - 1080p - x264 - [Tam + Tel + Hin + Eng] - HQ Clean - 5GB.mkv",
    expect: :match
  },
  %{
    note: "leading group tag",
    type: :tv_show,
    title: "Smoke Cat",
    year: 2025,
    release: "[geckyzz] Smoke Cat - S01E08 [UNCENSORED, WEB-DL 1080P AVC, AAC][E24BC7C7].mkv",
    expect: :match
  },
  %{
    note: "leading group tag, subtitle after a dash",
    type: :tv_show,
    title: "Ember Tide: Jobless Journey",
    year: 2021,
    alt_titles: ["Ember Tide"],
    release:
      "[Kitsune] Ember Tide - Jobless Journey (2021) - S01 [Bluray-1080p][Opus 2.0][Dual Audio]",
    expect: :match
  },
  %{
    note: "short alternative title on a pack",
    type: :tv_show,
    title: "Ember Tide: Jobless Journey",
    year: 2021,
    alt_titles: ["Ember Tide"],
    release: "Ember.Tide.S02E01-E12.1080p.BluRay.REMUX.Dual-Audio.AVC.FLAC2.0-GROUP",
    expect: :match
  },
  %{
    note: "franchise prefix from an alternative title",
    type: :movie,
    title: "The Lantern and Ash",
    year: 2031,
    alt_titles: ["Starfall: The Lantern and Ash"],
    release: "Starfall The Lantern And Ash 2031 1080p WEB-DL HEVC x265 5.1 GROUP",
    expect: :match
  },
  %{
    note: "Roman numeral written as a digit",
    type: :movie,
    title: "Harbor Watch II",
    year: 2031,
    release: "Harbor.Watch.2.2031.1080p.BluRay.x264-GROUP",
    expect: :match
  },
  %{
    note: "accents dropped",
    type: :movie,
    title: "Café Lumière",
    year: 2031,
    release: "Cafe.Lumiere.2031.1080p.WEB-DL.x264-GROUP",
    expect: :match
  },
  %{
    note: "country suffix",
    type: :tv_show,
    title: "The Ledger (US)",
    year: 2029,
    release: "The.Ledger.US.S01E01.1080p.WEB.h264-GROUP",
    expect: :match
  },
  %{
    note: "numeric title the parser reads as a year",
    type: :movie,
    title: "2043",
    year: 2031,
    release: "2043.2031.1080p.BluRay.x264-GROUP",
    expect: :match
  },
  %{
    note: "numeric-led title",
    type: :movie,
    title: "2071: A Long Night",
    year: 2019,
    release: "2071.A.Long.Night.2019.1080p.BluRay.x264-GROUP",
    expect: :match
  },
  %{
    note: "trailer: identity passes, trailer detection is a separate concern",
    type: :movie,
    title: "Glass Harbor",
    year: 2031,
    release: "glass-harbor-2031-leaked-2031-theatrical-trailer-2-better-version_203106",
    expect: :match
  },

  # --- names that are something else --------------------------------------
  %{
    note: "air-dated name the parser finds no title in",
    type: :movie,
    title: "Lantern",
    year: 2031,
    release: "2031-05-12 Lantern Vale (Harbor Chapter 1 Arrival) 1080p.mkv",
    expect: {:mismatch, :title}
  },
  %{
    note: "name that only starts with a short title",
    type: :movie,
    title: "Lantern",
    year: 2031,
    release: "Lantern Vale - Lantern Came Over For Dinner (01.06.2031)_1080p.mp4",
    expect: {:mismatch, :title}
  },
  %{
    note: "different show sharing the first word",
    type: :tv_show,
    title: "Star Harbor",
    year: 2025,
    release: "Star.Rover.Odyssey.S01E05.Dusty.Harbor.Rag.1080p.AMZN.WEB-DL.DDP5.1.H.264-GROUP",
    expect: {:mismatch, :title}
  },
  %{
    note: "different show sharing a word",
    type: :tv_show,
    title: "The New Seasons",
    year: 2024,
    release: "New Almanac S01-S03 (2018-)",
    expect: {:mismatch, :title}
  },
  %{
    note: "wanted title appears as an episode title",
    type: :tv_show,
    title: "Ember",
    year: 2024,
    release: "Tidewater S01E04 Ember 1080p AMZN WEB-DL DDP 5.1 H 264-GROUP",
    expect: {:mismatch, :title}
  },
  %{
    note: "sequel of the wanted title",
    type: :movie,
    title: "Sandglass",
    year: 2029,
    release: "Sandglass.Part.Two.2031.1080p.WEB-DL.x264-GROUP",
    expect: {:mismatch, :title}
  },
  %{
    note: "same title, decades apart",
    type: :movie,
    title: "Night Harbor",
    year: 2031,
    release: "Night.Harbor.1994.1080p.BluRay.x264-GROUP",
    expect: {:mismatch, :year}
  },

  # --- accepted losses: real releases the rule rejects ----------------------
  %{
    note: "accepted loss: second-language title appended",
    type: :movie,
    title: "The Salt Stars",
    year: 2031,
    release:
      "The Salt Stars - Le stelle di sale (2031)1080p x264 Ita hardsub ita MD eng - Group.mkv",
    expect: {:mismatch, :title}
  },
  %{
    note: "accepted loss: 'Complete' left in the title",
    type: :tv_show,
    title: "The Widening",
    year: 2015,
    release: "The WIDENING   Complete Season 5 S05 (2020 2021)   1080p AMZN WEB-DL x264",
    expect: {:mismatch, :title}
  }
]
