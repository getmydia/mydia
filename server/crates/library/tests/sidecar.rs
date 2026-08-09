use mydia_library::sidecar::discover;

fn touch(dir: &std::path::Path, name: &str) {
    std::fs::write(dir.join(name), b"1\n00:00:00,000 --> 00:00:01,000\nhi\n").unwrap();
}

#[test]
fn a_bare_sidecar_is_found_and_defaults_to_unknown_language() {
    let dir = tempfile::tempdir().unwrap();
    touch(dir.path(), "Film (2019).mkv");
    touch(dir.path(), "Film (2019).srt");

    let found = discover(&dir.path().join("Film (2019).mkv"));

    assert_eq!(found.len(), 1);
    assert_eq!(found[0].language, "und");
    assert_eq!(found[0].format, "srt");
}

#[test]
fn a_language_suffix_is_read_off_the_filename() {
    let dir = tempfile::tempdir().unwrap();
    touch(dir.path(), "Film (2019).mkv");
    touch(dir.path(), "Film (2019).eng.srt");
    touch(dir.path(), "Film (2019).spa.ass");

    let mut found = discover(&dir.path().join("Film (2019).mkv"));
    found.sort_by(|a, b| a.language.cmp(&b.language));

    assert_eq!(found.len(), 2);
    assert_eq!(found[0].language, "eng");
    assert_eq!(found[0].format, "srt");
    assert_eq!(found[1].language, "spa");
    assert_eq!(found[1].format, "ass");
}

#[test]
fn a_two_letter_code_is_kept_as_written() {
    // The contract says ISO 639-2, but operators name files "en" all the time
    // and dropping the track would be worse than carrying a short code.
    let dir = tempfile::tempdir().unwrap();
    touch(dir.path(), "Film (2019).mkv");
    touch(dir.path(), "Film (2019).en.srt");

    let found = discover(&dir.path().join("Film (2019).mkv"));

    assert_eq!(found[0].language, "en");
}

#[test]
fn subtitles_belonging_to_another_video_are_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    touch(dir.path(), "Film (2019).mkv");
    touch(dir.path(), "Other Film (2021).mkv");
    touch(dir.path(), "Other Film (2021).eng.srt");

    assert!(discover(&dir.path().join("Film (2019).mkv")).is_empty());
}

#[test]
fn unsupported_extensions_are_ignored() {
    let dir = tempfile::tempdir().unwrap();
    touch(dir.path(), "Film (2019).mkv");
    touch(dir.path(), "Film (2019).nfo");
    touch(dir.path(), "Film (2019).txt");

    assert!(discover(&dir.path().join("Film (2019).mkv")).is_empty());
}
