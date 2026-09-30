//! Plex GUID parsing (`imdb://`, `tmdb://`, `tvdb://`).

use crate::api::Guid;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExternalIds {
    pub imdb: Option<String>,
    pub tmdb: Option<i64>,
    pub tvdb: Option<i64>,
}

pub fn parse_guids(guids: &[Guid]) -> ExternalIds {
    let mut ids = ExternalIds::default();
    for g in guids {
        if let Some(v) = g.id.strip_prefix("imdb://") {
            if !v.is_empty() {
                ids.imdb = Some(v.to_string());
            }
        } else if let Some(v) = g.id.strip_prefix("tmdb://") {
            if let Ok(n) = v.parse() {
                ids.tmdb = Some(n);
            }
        } else if let Some(v) = g.id.strip_prefix("tvdb://") {
            if let Ok(n) = v.parse() {
                ids.tvdb = Some(n);
            }
        }
    }
    ids
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::Guid;

    fn g(id: &str) -> Guid {
        Guid { id: id.to_string() }
    }

    #[test]
    fn reads_all_three_sources() {
        let ids = parse_guids(&[g("imdb://tt0000001"), g("tmdb://123"), g("tvdb://456")]);
        assert_eq!(
            ids,
            ExternalIds {
                imdb: Some("tt0000001".into()),
                tmdb: Some(123),
                tvdb: Some(456)
            }
        );
    }

    #[test]
    fn ignores_unknown_schemes_and_non_numeric_ids() {
        let ids = parse_guids(&[g("plex://movie/5d77"), g("tmdb://abc"), g("local://9")]);
        assert_eq!(ids, ExternalIds::default());
    }

    #[test]
    fn empty_is_empty() {
        assert_eq!(parse_guids(&[]), ExternalIds::default());
    }
}
