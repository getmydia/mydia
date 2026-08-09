# Built-in custom formats for French-language audio tags.
#
# Loaded at compile time by Mydia.Settings.CustomFormats.Manifest. Each entry is
# a plain map. Patterns are Erlang :re source strings compiled with :caseless,
# so do not add inline (?i) flags.
#
# Editing this file changes the shipped definition for every install that has
# not overridden that format in the database.

[
  %{
    slug: "lang-vff",
    name: "VFF",
    description: "France French dub. TRUEFRENCH is the older name for the same thing.",
    patterns: ["\\bVFF\\b", "\\bTRUEFRENCH\\b"]
  },
  %{
    slug: "lang-vf2",
    name: "VF2",
    description: "Second French dub, typically a France redub of an older release.",
    patterns: ["\\bVF2\\b"]
  },
  %{
    slug: "lang-vfi",
    name: "VFI",
    description: "International French dub, produced in France for non-France markets.",
    patterns: ["\\bVFI\\b"]
  },
  %{
    slug: "lang-vfq",
    name: "VFQ",
    description: "Quebec French dub.",
    patterns: ["\\bVFQ\\b", "\\bVQ\\b"]
  },
  %{
    slug: "lang-multi",
    name: "MULTI",
    description: "Multiple audio tracks, usually the original plus one or more dubs.",
    patterns: ["\\bMULTI\\b"]
  },
  %{
    slug: "lang-vostfr",
    name: "VOSTFR",
    description: "Original audio with French subtitles. Not a dub.",
    patterns: ["\\bVOSTFR\\b"]
  }
]
