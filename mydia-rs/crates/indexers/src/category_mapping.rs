//! Torznab category mapping.
//!
//! Port of `lib/mydia/indexers/category_mapping.ex`. Newznab-style
//! numeric category IDs.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LibraryType {
    Movies,
    Series,
    Music,
    Books,
    Adult,
    Mixed,
    Other,
}

// Movies (2000-2999)
pub const MOVIES_PARENT: i32 = 2000;
pub const MOVIES_FOREIGN: i32 = 2010;
pub const MOVIES_OTHER: i32 = 2020;
pub const MOVIES_SD: i32 = 2030;
pub const MOVIES_HD: i32 = 2040;
pub const MOVIES_UHD: i32 = 2045;
pub const MOVIES_BLURAY: i32 = 2050;
pub const MOVIES_3D: i32 = 2060;
pub const MOVIES_DVD: i32 = 2070;

// Audio/Music (3000-3999)
pub const AUDIO_PARENT: i32 = 3000;
pub const AUDIO_MP3: i32 = 3010;
pub const AUDIO_VIDEO: i32 = 3020;
pub const AUDIO_AUDIOBOOK: i32 = 3030;
pub const AUDIO_LOSSLESS: i32 = 3040;
pub const AUDIO_OTHER: i32 = 3050;
pub const AUDIO_FOREIGN: i32 = 3060;

// TV (5000-5999)
pub const TV_PARENT: i32 = 5000;
pub const TV_WEBDL: i32 = 5010;
pub const TV_FOREIGN: i32 = 5020;
pub const TV_SD: i32 = 5030;
pub const TV_HD: i32 = 5040;
pub const TV_UHD: i32 = 5045;
pub const TV_OTHER: i32 = 5050;
pub const TV_SPORT: i32 = 5060;
pub const TV_ANIME: i32 = 5070;
pub const TV_DOCUMENTARY: i32 = 5080;

// Adult/XXX (6000-6999)
pub const XXX_PARENT: i32 = 6000;
pub const XXX_DVD: i32 = 6010;
pub const XXX_WMV: i32 = 6020;
pub const XXX_XVID: i32 = 6030;
pub const XXX_X264: i32 = 6040;
pub const XXX_UHD: i32 = 6045;
pub const XXX_PACK: i32 = 6050;
pub const XXX_IMAGESET: i32 = 6060;
pub const XXX_PACKS: i32 = 6070;
pub const XXX_SD: i32 = 6080;
pub const XXX_WEBDL: i32 = 6090;

// Books (7000-7999)
pub const BOOKS_PARENT: i32 = 7000;
pub const BOOKS_FOREIGN: i32 = 7010;
pub const BOOKS_EBOOK: i32 = 7020;
pub const BOOKS_COMICS: i32 = 7030;
pub const BOOKS_MAGAZINES: i32 = 7040;
pub const BOOKS_TECHNICAL: i32 = 7050;
pub const BOOKS_OTHER: i32 = 7060;
pub const BOOKS_AUDIOBOOK: i32 = 7070;

// Other (8000-8999)
pub const OTHER_PARENT: i32 = 8000;
pub const OTHER_MISC: i32 = 8010;
pub const OTHER_HASHED: i32 = 8020;

/// All Torznab category IDs for the given [`LibraryType`].
#[must_use]
pub fn categories_for_type(t: LibraryType) -> Vec<i32> {
    match t {
        LibraryType::Movies => vec![
            MOVIES_PARENT,
            MOVIES_FOREIGN,
            MOVIES_OTHER,
            MOVIES_SD,
            MOVIES_HD,
            MOVIES_UHD,
            MOVIES_BLURAY,
            MOVIES_3D,
            MOVIES_DVD,
        ],
        LibraryType::Series => vec![
            TV_PARENT,
            TV_WEBDL,
            TV_FOREIGN,
            TV_SD,
            TV_HD,
            TV_UHD,
            TV_OTHER,
            TV_SPORT,
            TV_ANIME,
            TV_DOCUMENTARY,
        ],
        LibraryType::Music => vec![
            AUDIO_PARENT,
            AUDIO_MP3,
            AUDIO_VIDEO,
            AUDIO_AUDIOBOOK,
            AUDIO_LOSSLESS,
            AUDIO_OTHER,
            AUDIO_FOREIGN,
        ],
        LibraryType::Books => vec![
            BOOKS_PARENT,
            BOOKS_FOREIGN,
            BOOKS_EBOOK,
            BOOKS_COMICS,
            BOOKS_MAGAZINES,
            BOOKS_TECHNICAL,
            BOOKS_OTHER,
            BOOKS_AUDIOBOOK,
        ],
        LibraryType::Adult => vec![
            XXX_PARENT,
            XXX_DVD,
            XXX_WMV,
            XXX_XVID,
            XXX_X264,
            XXX_UHD,
            XXX_PACK,
            XXX_IMAGESET,
            XXX_PACKS,
            XXX_SD,
            XXX_WEBDL,
        ],
        LibraryType::Mixed => {
            let mut out = categories_for_type(LibraryType::Movies);
            out.extend(categories_for_type(LibraryType::Series));
            out
        }
        LibraryType::Other => Vec::new(),
    }
}

/// Parent (non-subcategory) ID for a [`LibraryType`].
#[must_use]
pub fn parent_category(t: LibraryType) -> Option<i32> {
    match t {
        LibraryType::Movies => Some(MOVIES_PARENT),
        LibraryType::Series => Some(TV_PARENT),
        LibraryType::Music => Some(AUDIO_PARENT),
        LibraryType::Books => Some(BOOKS_PARENT),
        LibraryType::Adult => Some(XXX_PARENT),
        LibraryType::Mixed | LibraryType::Other => None,
    }
}

/// Human-readable label for a category ID.
#[must_use]
pub fn category_name(id: i32) -> String {
    match id {
        MOVIES_PARENT => "Movies".into(),
        MOVIES_FOREIGN => "Movies/Foreign".into(),
        MOVIES_OTHER => "Movies/Other".into(),
        MOVIES_SD => "Movies/SD".into(),
        MOVIES_HD => "Movies/HD".into(),
        MOVIES_UHD => "Movies/UHD".into(),
        MOVIES_BLURAY => "Movies/BluRay".into(),
        MOVIES_3D => "Movies/3D".into(),
        MOVIES_DVD => "Movies/DVD".into(),
        AUDIO_PARENT => "Audio".into(),
        AUDIO_MP3 => "Audio/MP3".into(),
        AUDIO_VIDEO => "Audio/Video".into(),
        AUDIO_AUDIOBOOK => "Audio/Audiobook".into(),
        AUDIO_LOSSLESS => "Audio/Lossless".into(),
        AUDIO_OTHER => "Audio/Other".into(),
        AUDIO_FOREIGN => "Audio/Foreign".into(),
        TV_PARENT => "TV".into(),
        TV_WEBDL => "TV/WEB-DL".into(),
        TV_FOREIGN => "TV/Foreign".into(),
        TV_SD => "TV/SD".into(),
        TV_HD => "TV/HD".into(),
        TV_UHD => "TV/UHD".into(),
        TV_OTHER => "TV/Other".into(),
        TV_SPORT => "TV/Sport".into(),
        TV_ANIME => "TV/Anime".into(),
        TV_DOCUMENTARY => "TV/Documentary".into(),
        XXX_PARENT => "XXX".into(),
        XXX_DVD => "XXX/DVD".into(),
        XXX_WMV => "XXX/WMV".into(),
        XXX_XVID => "XXX/XviD".into(),
        XXX_X264 => "XXX/x264".into(),
        XXX_UHD => "XXX/UHD".into(),
        XXX_PACK => "XXX/Pack".into(),
        XXX_IMAGESET => "XXX/ImageSet".into(),
        XXX_PACKS => "XXX/Packs".into(),
        XXX_SD => "XXX/SD".into(),
        XXX_WEBDL => "XXX/WEB-DL".into(),
        BOOKS_PARENT => "Books".into(),
        BOOKS_FOREIGN => "Books/Foreign".into(),
        BOOKS_EBOOK => "Books/EBook".into(),
        BOOKS_COMICS => "Books/Comics".into(),
        BOOKS_MAGAZINES => "Books/Magazines".into(),
        BOOKS_TECHNICAL => "Books/Technical".into(),
        BOOKS_OTHER => "Books/Other".into(),
        BOOKS_AUDIOBOOK => "Books/Audiobook".into(),
        OTHER_PARENT => "Other".into(),
        OTHER_MISC => "Other/Misc".into(),
        OTHER_HASHED => "Other/Hashed".into(),
        other => format!("Unknown ({other})"),
    }
}

#[must_use]
pub fn category_matches_type(id: i32, t: LibraryType) -> bool {
    categories_for_type(t).contains(&id)
}

#[must_use]
pub fn type_for_category(id: i32) -> LibraryType {
    match id {
        i if (2000..3000).contains(&i) => LibraryType::Movies,
        i if (3000..4000).contains(&i) => LibraryType::Music,
        i if (5000..6000).contains(&i) => LibraryType::Series,
        i if (6000..7000).contains(&i) => LibraryType::Adult,
        i if (7000..8000).contains(&i) => LibraryType::Books,
        _ => LibraryType::Other,
    }
}

/// Resolve a Cardigann category name to a Torznab ID. The match is
/// case-insensitive on the lowercased form (`"Movies/HD"` → `2040`).
#[must_use]
#[allow(clippy::too_many_lines)]
pub fn category_id_from_name(name: &str) -> Option<i32> {
    let normalized = name.to_lowercase();
    let id = match normalized.as_str() {
        // Movies
        "movies" => MOVIES_PARENT,
        "movies/foreign" => MOVIES_FOREIGN,
        "movies/other" => MOVIES_OTHER,
        "movies/sd" => MOVIES_SD,
        "movies/hd" => MOVIES_HD,
        "movies/uhd" => MOVIES_UHD,
        "movies/bluray" | "movies/blu-ray" => MOVIES_BLURAY,
        "movies/3d" => MOVIES_3D,
        "movies/dvd" => MOVIES_DVD,
        "movies/divx/xvid" | "movies/mp4" | "movies/svcd/vcd" => MOVIES_SD,
        "movies/h.264/x264" | "movies/hevc/x265" => MOVIES_HD,
        "movies/dubs/dual audio" | "movies/bollywood" => MOVIES_FOREIGN,
        // Audio
        "audio" | "music" | "music/dvd" | "music/album" | "music/box set" | "music/discography"
        | "music/single" => AUDIO_PARENT,
        "audio/mp3" | "music/mp3" | "music/aac" => AUDIO_MP3,
        "audio/video" | "music/video" | "music/concerts" => AUDIO_VIDEO,
        "audio/audiobook" => AUDIO_AUDIOBOOK,
        "audio/lossless" | "music/lossless" => AUDIO_LOSSLESS,
        "audio/other" | "music/radio" | "music/other" => AUDIO_OTHER,
        "audio/foreign" => AUDIO_FOREIGN,
        // TV
        "tv" | "tv/dvd" => TV_PARENT,
        "tv/web-dl" | "tv/webdl" => TV_WEBDL,
        "tv/foreign" => TV_FOREIGN,
        "tv/sd" | "tv/divx/xvid" | "tv/svcd/vcd" => TV_SD,
        "tv/hd" | "tv/hevc/x265" => TV_HD,
        "tv/uhd" => TV_UHD,
        "tv/other" => TV_OTHER,
        "tv/sport" => TV_SPORT,
        "tv/anime" | "tv/cartoons" => TV_ANIME,
        "tv/documentary" => TV_DOCUMENTARY,
        // Adult
        "xxx" | "xxx/magazine" | "xxx/hentai" | "xxx/games" => XXX_PARENT,
        "xxx/dvd" | "xxx/video" => XXX_DVD,
        "xxx/wmv" => XXX_WMV,
        "xxx/xvid" => XXX_XVID,
        "xxx/x264" => XXX_X264,
        "xxx/uhd" => XXX_UHD,
        "xxx/pack" => XXX_PACK,
        "xxx/imageset" | "xxx/picture" => XXX_IMAGESET,
        "xxx/packs" => XXX_PACKS,
        "xxx/sd" => XXX_SD,
        "xxx/web-dl" => XXX_WEBDL,
        // Books
        "books" => BOOKS_PARENT,
        "books/foreign" => BOOKS_FOREIGN,
        "books/ebook" | "other/e-books" => BOOKS_EBOOK,
        "books/comics" | "other/comics" => BOOKS_COMICS,
        "books/magazines" => BOOKS_MAGAZINES,
        "books/technical" | "other/tutorial" => BOOKS_TECHNICAL,
        "books/other" => BOOKS_OTHER,
        "books/audiobook" | "other/audiobook" => BOOKS_AUDIOBOOK,
        // Other / PC / Console
        "other"
        | "other/emulation"
        | "other/images"
        | "other/mobile phone"
        | "other/nulled script"
        | "pc"
        | "pc/games"
        | "pc/mac"
        | "pc/mobile-android"
        | "pc/mobile-ios"
        | "pc/mobile-other"
        | "console"
        | "console/ps3"
        | "console/ps4"
        | "console/psp"
        | "console/xbox"
        | "console/xbox 360"
        | "console/wii"
        | "console/nds"
        | "console/3ds"
        | "console/other" => OTHER_PARENT,
        "other/misc" | "other/other" => OTHER_MISC,
        "other/hashed" => OTHER_HASHED,
        "other/sounds" => AUDIO_OTHER,
        _ => return None,
    };
    Some(id)
}

/// Site-specific category ID → Torznab via a definition's
/// `categorymappings` block.
#[must_use]
pub fn map_site_category_to_torznab(
    site_category_id: Option<&str>,
    mappings: &[serde_json::Value],
) -> Option<i32> {
    let id = site_category_id?;
    let id_int: Option<i64> = id.parse().ok();

    let matched = mappings.iter().find(|m| {
        let mid = m.get("id");
        match mid {
            Some(serde_json::Value::String(s)) => s == id,
            Some(serde_json::Value::Number(n)) => match id_int {
                Some(want) => n.as_i64() == Some(want),
                None => n.to_string() == id,
            },
            _ => false,
        }
    })?;

    let cat = matched.get("cat").and_then(|v| v.as_str())?;
    category_id_from_name(cat)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn movies_categories_match() {
        let cats = categories_for_type(LibraryType::Movies);
        assert!(cats.contains(&MOVIES_HD));
        assert_eq!(cats.len(), 9);
    }

    #[test]
    fn category_id_lookup_is_case_insensitive() {
        assert_eq!(category_id_from_name("Movies/HD"), Some(MOVIES_HD));
        assert_eq!(category_id_from_name("MOVIES/HD"), Some(MOVIES_HD));
        assert_eq!(category_id_from_name("TV/Anime"), Some(TV_ANIME));
    }

    #[test]
    fn type_for_category_buckets_by_range() {
        assert_eq!(type_for_category(2040), LibraryType::Movies);
        assert_eq!(type_for_category(5040), LibraryType::Series);
        assert_eq!(type_for_category(3000), LibraryType::Music);
        assert_eq!(type_for_category(9999), LibraryType::Other);
    }

    #[test]
    fn site_mapping_routes_to_torznab() {
        let mappings = vec![serde_json::json!({ "id": 42, "cat": "Movies/HD" })];
        assert_eq!(
            map_site_category_to_torznab(Some("42"), &mappings),
            Some(MOVIES_HD)
        );
        assert_eq!(map_site_category_to_torznab(Some("999"), &mappings), None);
    }
}
