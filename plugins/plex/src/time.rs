//! RFC3339 <-> unix seconds without a date crate. Output is always UTC ("Z");
//! input may carry a fractional second and a numeric offset.

pub fn to_rfc3339(unix: i64) -> String {
    let days = unix.div_euclid(86_400);
    let secs = unix.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y,
        m,
        d,
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60
    )
}

pub fn parse_rfc3339(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> { s.get(from..to)?.parse::<i64>().ok() };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, se) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
        return None;
    }
    let mut rest = s.get(19..)?;
    if let Some(frac) = rest.strip_prefix('.') {
        let digits = frac.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return None;
        }
        rest = &frac[digits..];
    }
    let offset = match rest {
        "Z" | "z" => 0,
        _ if rest.len() == 6
            && (rest.starts_with('+') || rest.starts_with('-'))
            && rest.get(3..4) == Some(":") =>
        {
            let sign = if rest.starts_with('-') { -1 } else { 1 };
            let oh = rest.get(1..3)?.parse::<i64>().ok()?;
            let om = rest.get(4..6)?.parse::<i64>().ok()?;
            sign * (oh * 3600 + om * 60)
        }
        _ => return None,
    };
    Some(days_from_civil(y, mo as u32, d as u32) * 86_400 + h * 3600 + mi * 60 + se - offset)
}

// Howard Hinnant's civil calendar algorithms.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let m = m as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_utc() {
        assert_eq!(to_rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(to_rfc3339(1_767_225_600), "2026-01-01T00:00:00Z");
        assert_eq!(to_rfc3339(951_782_400), "2000-02-29T00:00:00Z");
    }

    #[test]
    fn parses_z_fraction_and_offset() {
        assert_eq!(parse_rfc3339("2026-01-01T00:00:00Z"), Some(1_767_225_600));
        assert_eq!(
            parse_rfc3339("2026-01-01T00:00:00.123456Z"),
            Some(1_767_225_600)
        );
        assert_eq!(
            parse_rfc3339("2026-01-01T02:00:00+02:00"),
            Some(1_767_225_600)
        );
        assert_eq!(
            parse_rfc3339("2025-12-31T19:00:00-05:00"),
            Some(1_767_225_600)
        );
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(parse_rfc3339(""), None);
        assert_eq!(parse_rfc3339("2026-13-01T00:00:00Z"), None);
        assert_eq!(parse_rfc3339("yesterday"), None);
    }

    #[test]
    fn round_trips() {
        for t in [0, 86_399, 1_000_000_000, 1_767_225_600, 4_102_444_800] {
            assert_eq!(parse_rfc3339(&to_rfc3339(t)), Some(t));
        }
    }
}
