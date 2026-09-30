//! Three-way merge between local state, remote state, and the last-agreed
//! snapshot, ported from `Mydia.WatchSync.Reconciler`. Two-way comparison
//! cannot express unwatch: "watched remotely, not watched locally" means either
//! "newly watched there" or "just unwatched here". The snapshot disambiguates
//! them. Pure: no host calls.
//!
//! With no snapshot the merge is a baseline, and a baseline never destroys
//! anything: it never propagates an unwatch in either direction, never pushes a
//! position lower than Plex's, and only unions watched = true and takes the
//! newer position. Env-declared native servers had no DB row, so their state was
//! never migrated, and their first plugin tick runs every item through here.

pub const POSITION_NOISE_THRESHOLD_SECONDS: i64 = 10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Side {
    pub watched: bool,
    pub position: Option<i64>,
    pub at: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Change {
    pub watched: bool,
    pub position: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Push(Change),
    Pull(Change),
    RecordOnly(Change),
    Noop,
}

pub fn resolve(local: &Side, remote: &Side, snapshot: Option<&Side>) -> Decision {
    let snapshot = match snapshot {
        None => return baseline(local, remote),
        Some(s) => s,
    };

    let local_changed = local.watched != snapshot.watched;
    let remote_changed = remote.watched != snapshot.watched;

    if local_changed && remote_changed {
        // Differing from the same boolean forces both sides to the same value.
        Decision::RecordOnly(change(local.watched, newest_position(local, remote)))
    } else if local_changed {
        Decision::Push(change(local.watched, local.position))
    } else if remote_changed {
        Decision::Pull(change(remote.watched, remote.position))
    } else {
        resolve_position(local, remote, snapshot)
    }
}

fn baseline(local: &Side, remote: &Side) -> Decision {
    match (local.watched, remote.watched) {
        (true, false) => Decision::Push(change(true, raised(local.position, remote.position))),
        (false, true) => Decision::Pull(change(true, remote.position)),
        (true, true) => Decision::RecordOnly(change(true, newest_position(local, remote))),
        (false, false) if local.at > remote.at => match raised(local.position, remote.position) {
            Some(p) => Decision::Push(change(false, Some(p))),
            None => Decision::RecordOnly(change(false, newest_position(local, remote))),
        },
        (false, false) => match remote.position {
            Some(p)
                if position_delta(Some(p), local.position) >= POSITION_NOISE_THRESHOLD_SECONDS
                    || local.position.is_none() =>
            {
                Decision::Pull(change(false, Some(p)))
            }
            _ => Decision::RecordOnly(change(false, newest_position(local, remote))),
        },
    }
}

/// `from`, when it is known and meaningfully above `to`. Used wherever a
/// baseline would write Plex, so Plex's resume point only ever moves forward.
fn raised(from: Option<i64>, to: Option<i64>) -> Option<i64> {
    let from = from?;
    match to {
        Some(to) if from - to < POSITION_NOISE_THRESHOLD_SECONDS => None,
        _ => Some(from),
    }
}

fn resolve_position(local: &Side, remote: &Side, snapshot: &Side) -> Decision {
    let local_delta = position_delta(local.position, snapshot.position);
    let remote_delta = position_delta(remote.position, snapshot.position);

    if local_delta >= POSITION_NOISE_THRESHOLD_SECONDS && local_delta >= remote_delta {
        Decision::Push(change(local.watched, local.position))
    } else if remote_delta >= POSITION_NOISE_THRESHOLD_SECONDS {
        Decision::Pull(change(remote.watched, remote.position))
    } else {
        Decision::Noop
    }
}

fn position_delta(a: Option<i64>, b: Option<i64>) -> i64 {
    match (a, b) {
        (Some(a), Some(b)) => (a - b).abs(),
        _ => 0,
    }
}

// `None < Some(_)` for Option, matching compare_times/2 in the Elixir original.
fn newest_position(local: &Side, remote: &Side) -> Option<i64> {
    if local.at < remote.at {
        remote.position
    } else {
        local.position
    }
}

fn change(watched: bool, position: Option<i64>) -> Change {
    Change { watched, position }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: i64 = 1_767_225_600;

    fn side(watched: bool) -> Side {
        Side {
            watched,
            position: None,
            at: None,
        }
    }

    fn full(watched: bool, position: Option<i64>, at: i64) -> Side {
        Side {
            watched,
            position,
            at: Some(T0 + at),
        }
    }

    fn ch(watched: bool, position: Option<i64>) -> Change {
        Change { watched, position }
    }

    // ported from reconciler_test.exs

    #[test]
    fn no_snapshot_unions_so_a_first_sync_never_deletes_history() {
        assert_eq!(
            resolve(&side(false), &side(true), None),
            Decision::Pull(ch(true, None))
        );
        assert_eq!(
            resolve(&side(true), &side(false), None),
            Decision::Push(ch(true, None))
        );
    }

    #[test]
    fn remote_changed_alone_pulls() {
        assert_eq!(
            resolve(&side(false), &side(true), Some(&side(false))),
            Decision::Pull(ch(true, None))
        );
    }

    #[test]
    fn local_changed_alone_pushes() {
        assert_eq!(
            resolve(&side(true), &side(false), Some(&side(false))),
            Decision::Push(ch(true, None))
        );
    }

    #[test]
    fn a_local_unwatch_propagates_when_the_snapshot_says_watched() {
        assert_eq!(
            resolve(&side(false), &side(true), Some(&side(true))),
            Decision::Push(ch(false, None))
        );
    }

    #[test]
    fn a_remote_unwatch_propagates() {
        assert_eq!(
            resolve(&side(true), &side(false), Some(&side(true))),
            Decision::Pull(ch(false, None))
        );
    }

    #[test]
    fn both_converged_records_only() {
        assert!(matches!(
            resolve(&side(true), &side(true), Some(&side(false))),
            Decision::RecordOnly(_)
        ));
    }

    #[test]
    fn nothing_changed_is_noop() {
        assert_eq!(
            resolve(&side(true), &side(true), Some(&side(true))),
            Decision::Noop
        );
    }

    #[test]
    fn only_local_moving_pushes_regardless_of_timestamps() {
        let snap = full(false, None, 0);
        assert_eq!(
            resolve(&full(true, None, 100), &full(false, None, 50), Some(&snap)),
            Decision::Push(ch(true, None))
        );
    }

    #[test]
    fn both_moving_off_the_snapshot_only_converges() {
        for snap_watched in [true, false] {
            let flipped = !snap_watched;
            let snap = full(snap_watched, None, 0);
            assert_eq!(
                resolve(
                    &full(flipped, None, 100),
                    &full(flipped, None, 50),
                    Some(&snap)
                ),
                Decision::RecordOnly(ch(flipped, None))
            );
        }
    }

    #[test]
    fn position_delta_below_noise_is_not_propagated() {
        let snap = full(false, Some(100), 0);
        assert_eq!(
            resolve(
                &full(false, Some(105), 10),
                &full(false, Some(100), 0),
                Some(&snap)
            ),
            Decision::Noop
        );
    }

    #[test]
    fn meaningful_local_position_delta_pushes() {
        let snap = full(false, Some(100), 0);
        assert_eq!(
            resolve(
                &full(false, Some(400), 10),
                &full(false, Some(100), 0),
                Some(&snap)
            ),
            Decision::Push(ch(false, Some(400)))
        );
    }

    #[test]
    fn meaningful_remote_position_delta_pulls() {
        let snap = full(false, Some(100), 0);
        assert_eq!(
            resolve(
                &full(false, Some(100), 0),
                &full(false, Some(900), 10),
                Some(&snap)
            ),
            Decision::Pull(ch(false, Some(900)))
        );
    }

    #[test]
    fn position_update_never_resurrects_an_agreed_watched_item() {
        let snap = full(true, Some(100), 0);
        assert_eq!(
            resolve(
                &full(true, Some(400), 10),
                &full(true, Some(100), 0),
                Some(&snap)
            ),
            Decision::Push(ch(true, Some(400)))
        );
    }

    // baseline (no snapshot)

    #[test]
    fn baseline_never_propagates_an_unwatch_either_way() {
        for (local, remote) in [(side(true), side(false)), (side(false), side(true))] {
            match resolve(&local, &remote, None) {
                Decision::Push(c) | Decision::Pull(c) | Decision::RecordOnly(c) => {
                    assert!(c.watched)
                }
                Decision::Noop => panic!("a baseline always records"),
            }
        }
    }

    #[test]
    fn baseline_never_pushes_a_lower_position_with_a_watch() {
        // Watched locally at 30 s, in progress on Plex at 900 s: scrobble, but
        // do not drag Plex's resume point back to 30.
        assert_eq!(
            resolve(
                &full(true, Some(30), 100),
                &full(false, Some(900), 50),
                None
            ),
            Decision::Push(ch(true, None))
        );
        assert_eq!(
            resolve(
                &full(true, Some(1200), 100),
                &full(false, Some(900), 50),
                None
            ),
            Decision::Push(ch(true, Some(1200)))
        );
    }

    #[test]
    fn baseline_never_pushes_a_lower_position_even_when_newer() {
        assert_eq!(
            resolve(
                &full(false, Some(100), 60),
                &full(false, Some(900), 0),
                None
            ),
            Decision::RecordOnly(ch(false, Some(100)))
        );
    }

    #[test]
    fn baseline_pushes_a_newer_higher_local_position() {
        assert_eq!(
            resolve(
                &full(false, Some(900), 60),
                &full(false, Some(100), 0),
                None
            ),
            Decision::Push(ch(false, Some(900)))
        );
    }

    #[test]
    fn baseline_takes_the_newer_remote_position() {
        assert_eq!(
            resolve(&full(false, Some(30), 0), &full(false, Some(600), 60), None),
            Decision::Pull(ch(false, Some(600)))
        );
        assert_eq!(
            resolve(&full(false, Some(600), 0), &full(false, Some(30), 60), None),
            Decision::Pull(ch(false, Some(30)))
        );
    }

    #[test]
    fn baseline_pulls_a_remote_watch_with_its_position() {
        assert_eq!(
            resolve(&full(false, Some(30), 0), &full(true, Some(10), 60), None),
            Decision::Pull(ch(true, Some(10)))
        );
    }

    #[test]
    fn baseline_with_agreeing_sides_records_the_newest_position() {
        assert_eq!(
            resolve(&full(true, Some(30), 0), &full(true, Some(600), 60), None),
            Decision::RecordOnly(ch(true, Some(600)))
        );
        assert_eq!(
            resolve(
                &full(false, Some(100), 0),
                &full(false, Some(104), 60),
                None
            ),
            Decision::RecordOnly(ch(false, Some(104)))
        );
    }
}
