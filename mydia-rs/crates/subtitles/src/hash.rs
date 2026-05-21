//! OpenSubtitles `moviehash` algorithm.
//!
//! Faithful port of `lib/mydia/subtitles/hash.ex`. The algorithm:
//!
//! 1. Read the first 64 KiB of the file.
//! 2. Read the last 64 KiB.
//! 3. Sum every 64-bit little-endian word in both chunks together with
//!    the file size; keep only the low 64 bits.
//! 4. Format the result as a 16-character lowercase hex string.
//!
//! This produces a small, deterministic fingerprint OpenSubtitles uses
//! to match subtitles to videos without comparing full byte streams.

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use tokio::io::{AsyncReadExt, AsyncSeekExt};

/// 64 KiB read chunk size.
pub const CHUNK_SIZE: u64 = 65_536;

/// Sync version — useful for CLI tools and tests.
pub fn calculate_hash_sync(path: impl AsRef<Path>) -> Result<(String, u64), std::io::Error> {
    let path = path.as_ref();
    let metadata = std::fs::metadata(path)?;
    let file_size = metadata.len();
    let mut file = std::fs::File::open(path)?;

    if file_size < CHUNK_SIZE {
        let mut buf = Vec::with_capacity(file_size as usize);
        file.read_to_end(&mut buf)?;
        let hash = checksum(&buf, file_size);
        return Ok((format_hash(hash), file_size));
    }

    let mut first = vec![0u8; CHUNK_SIZE as usize];
    file.seek(SeekFrom::Start(0))?;
    file.read_exact(&mut first)?;

    let mut last = vec![0u8; CHUNK_SIZE as usize];
    file.seek(SeekFrom::Start(file_size - CHUNK_SIZE))?;
    file.read_exact(&mut last)?;

    let mut combined = first;
    combined.extend(last);
    let hash = checksum(&combined, file_size);
    Ok((format_hash(hash), file_size))
}

/// Async variant. Workers will call this so the BLAS scanner stays
/// off the runtime's blocking pool.
pub async fn calculate_hash(path: impl AsRef<Path>) -> Result<(String, u64), std::io::Error> {
    let path = path.as_ref();
    let metadata = tokio::fs::metadata(path).await?;
    let file_size = metadata.len();
    let mut file = tokio::fs::File::open(path).await?;

    if file_size < CHUNK_SIZE {
        let mut buf = Vec::with_capacity(file_size as usize);
        file.read_to_end(&mut buf).await?;
        let hash = checksum(&buf, file_size);
        return Ok((format_hash(hash), file_size));
    }

    let mut first = vec![0u8; CHUNK_SIZE as usize];
    file.seek(SeekFrom::Start(0)).await?;
    file.read_exact(&mut first).await?;

    let mut last = vec![0u8; CHUNK_SIZE as usize];
    file.seek(SeekFrom::Start(file_size - CHUNK_SIZE)).await?;
    file.read_exact(&mut last).await?;

    let mut combined = first;
    combined.extend(last);
    let hash = checksum(&combined, file_size);
    Ok((format_hash(hash), file_size))
}

fn checksum(data: &[u8], file_size: u64) -> u64 {
    let mut hash = file_size;
    let mut i = 0;
    while i + 8 <= data.len() {
        let word = u64::from_le_bytes(data[i..i + 8].try_into().unwrap());
        hash = hash.wrapping_add(word);
        i += 8;
    }
    hash
}

fn format_hash(hash: u64) -> String {
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn small_file_hashes_the_whole_body() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("small.bin");
        let mut f = std::fs::File::create(&path).unwrap();
        // 16 bytes of known content: 0x01 0x02 ... 0x10
        f.write_all(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
            .unwrap();
        drop(f);

        let (hash, size) = calculate_hash_sync(&path).unwrap();
        assert_eq!(size, 16);
        assert_eq!(hash.len(), 16);
        // Re-running on the same file returns the same hash.
        let (again, _) = calculate_hash_sync(&path).unwrap();
        assert_eq!(hash, again);
    }

    #[test]
    fn known_pattern_round_trips_through_format() {
        // 0x0000000000000010 — file size 16, chunks all-zero
        let hash = checksum(&[0u8; 16], 16);
        assert_eq!(format_hash(hash), "0000000000000010");
    }

    #[tokio::test]
    async fn async_and_sync_agree() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bigger.bin");
        let mut f = std::fs::File::create(&path).unwrap();
        // 200 KiB of pseudo-random-ish bytes
        let data: Vec<u8> = (0..(200 * 1024)).map(|i| (i % 251) as u8).collect();
        f.write_all(&data).unwrap();
        drop(f);

        let (s_hash, s_size) = calculate_hash_sync(&path).unwrap();
        let (a_hash, a_size) = calculate_hash(&path).await.unwrap();
        assert_eq!(s_hash, a_hash);
        assert_eq!(s_size, a_size);
    }
}
