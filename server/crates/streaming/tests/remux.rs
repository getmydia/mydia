//! Remux output is verified by probing it, not by trusting the exit code.
//! ffmpeg exits 0 on plenty of output nobody can play.

use std::io::Write;

use futures_util::StreamExt;

fn synthesize_mkv(dir: &std::path::Path) -> std::path::PathBuf {
    let path = dir.join("source.mkv");

    let status = std::process::Command::new("ffmpeg")
        .args([
            "-v",
            "quiet",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=640x360:rate=24:duration=2",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=2",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
        ])
        .arg(&path)
        .status()
        .expect("ffmpeg must be on PATH");

    assert!(status.success());
    path
}

#[tokio::test]
async fn a_remuxed_mkv_probes_as_playable_fragmented_mp4() {
    let dir = tempfile::tempdir().unwrap();
    let source = synthesize_mkv(dir.path());

    let mut stream = mydia_streaming::remux::start(source.to_str().unwrap(), Some(2.0)).unwrap();

    let mut out = Vec::new();
    while let Some(chunk) = stream.next().await {
        out.extend_from_slice(&chunk.unwrap());
    }

    assert!(out.len() > 1024, "remux produced only {} bytes", out.len());

    // Write it out and probe it. A truncated moov or a missing track would
    // pass a length assertion and fail here.
    let remuxed = dir.path().join("out.mp4");
    std::fs::File::create(&remuxed)
        .unwrap()
        .write_all(&out)
        .unwrap();

    let probe = std::process::Command::new("ffprobe")
        .args([
            "-v",
            "quiet",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
        ])
        .arg(&remuxed)
        .output()
        .unwrap();

    let parsed: serde_json::Value = serde_json::from_slice(&probe.stdout).unwrap();
    let streams = parsed["streams"].as_array().unwrap();

    assert!(streams.iter().any(|s| s["codec_name"] == "h264"));
    assert!(streams.iter().any(|s| s["codec_name"] == "aac"));
    assert!(parsed["format"]["format_name"]
        .as_str()
        .unwrap()
        .contains("mp4"));
}

#[tokio::test]
async fn dropping_the_stream_kills_the_ffmpeg_child() {
    let dir = tempfile::tempdir().unwrap();
    let source = synthesize_mkv(dir.path());

    let stream = mydia_streaming::remux::start(source.to_str().unwrap(), None).unwrap();
    let pid = stream.child_id().expect("the child should be running");

    drop(stream);

    // The kill is issued from Drop; give the OS a moment to reap.
    tokio::time::sleep(std::time::Duration::from_millis(250)).await;

    let alive = std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .status()
        .unwrap()
        .success();

    assert!(!alive, "ffmpeg {pid} outlived the stream that owned it");
}

#[tokio::test]
async fn a_missing_source_fails_before_any_bytes() {
    let err = mydia_streaming::remux::start("/nowhere/at/all.mkv", None);
    assert!(err.is_err());
}
