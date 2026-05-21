//! Dialect-aware SQL helpers mirroring the macros in `lib/mydia/db.ex`.
//!
//! Phoenix picks `SQLite` vs Postgres at compile time and inlines the
//! correct SQL fragment at every call site. mydia-rs ships one binary
//! that selects at runtime, so each helper takes the [`Dialect`] and
//! returns the equivalent SQL fragment.
//!
//! All helpers produce the field/path verbatim as identifiers. Callers
//! are responsible for using parameter binding for user-supplied values;
//! these helpers compose SQL structure, not values.

use std::fmt::Write as _;

/// Runtime selector for which SQL dialect a query targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Dialect {
    Sqlite,
    Postgres,
}

impl Dialect {
    /// Extract a JSON value at the given SQLite-style `$.key.sub` path.
    ///
    /// - `SQLite`: `json_extract(<field>, '<path>')` -> TEXT/NULL
    /// - Postgres: `(<field>)::jsonb ->> '<key>'` -> TEXT/NULL
    pub fn json_extract(self, field: &str, path: &str) -> String {
        match self {
            Self::Sqlite => format!("json_extract({field}, '{path}')", path = escape_sql(path)),
            Self::Postgres => {
                let key = sqlite_path_to_postgres_key(path);
                format!("({field})::jsonb ->> '{key}'", key = escape_sql(&key))
            }
        }
    }

    /// Extract a JSON value at the path and cast to INTEGER.
    ///
    /// - `SQLite`: `CAST(json_extract(<field>, '<path>') AS INTEGER)`
    /// - Postgres: `((<field>)::jsonb ->> '<key>')::integer`
    pub fn json_extract_integer(self, field: &str, path: &str) -> String {
        match self {
            Self::Sqlite => format!(
                "CAST(json_extract({field}, '{path}') AS INTEGER)",
                path = escape_sql(path),
            ),
            Self::Postgres => {
                let key = sqlite_path_to_postgres_key(path);
                format!(
                    "(({field})::jsonb ->> '{key}')::integer",
                    key = escape_sql(&key),
                )
            }
        }
    }

    /// Extract a JSON boolean. `SQLite` stores JSON booleans as 1/0 or the
    /// strings "true"/"false"; Postgres stores them as native booleans.
    ///
    /// Returns a boolean SQL expression suitable for `WHERE`.
    pub fn json_extract_boolean(self, field: &str, path: &str) -> String {
        match self {
            Self::Sqlite => format!(
                "(json_extract({field}, '{path}') = 1 OR json_extract({field}, '{path}') = 'true')",
                path = escape_sql(path),
            ),
            Self::Postgres => {
                let key = sqlite_path_to_postgres_key(path);
                format!(
                    "(({field})::jsonb ->> '{key}')::boolean",
                    key = escape_sql(&key),
                )
            }
        }
    }

    /// `<field>->'<path>' IS NOT NULL` for the dialect.
    pub fn json_not_null(self, field: &str, path: &str) -> String {
        match self {
            Self::Sqlite => format!(
                "json_extract({field}, '{path}') IS NOT NULL",
                path = escape_sql(path),
            ),
            Self::Postgres => {
                let key = sqlite_path_to_postgres_key(path);
                format!(
                    "(({field})::jsonb ->> '{key}') IS NOT NULL",
                    key = escape_sql(&key),
                )
            }
        }
    }

    /// Cast an expression to a floating-point number.
    ///
    /// - `SQLite`: `CAST(<expr> AS REAL)`
    /// - Postgres: `(<expr>)::float`
    pub fn cast_to_real(self, expr: &str) -> String {
        match self {
            Self::Sqlite => format!("CAST({expr} AS REAL)"),
            Self::Postgres => format!("({expr})::float"),
        }
    }

    /// Cast an expression to an integer.
    pub fn cast_to_integer(self, expr: &str) -> String {
        match self {
            Self::Sqlite => format!("CAST({expr} AS INTEGER)"),
            Self::Postgres => format!("({expr})::integer"),
        }
    }

    /// Average of (end - start) in seconds, computed across rows.
    ///
    /// - `SQLite`: `AVG((julianday(end) - julianday(start)) * 86400)`
    /// - Postgres: `AVG(EXTRACT(EPOCH FROM (end - start)))`
    pub fn avg_timestamp_diff_seconds(self, end_field: &str, start_field: &str) -> String {
        match self {
            Self::Sqlite => {
                format!("AVG((julianday({end_field}) - julianday({start_field})) * 86400)")
            }
            Self::Postgres => {
                format!("AVG(EXTRACT(EPOCH FROM ({end_field} - {start_field})))")
            }
        }
    }

    /// Single-row (end - start) in seconds.
    pub fn timestamp_diff_seconds(self, end_field: &str, start_field: &str) -> String {
        match self {
            Self::Sqlite => {
                format!("(julianday({end_field}) - julianday({start_field})) * 86400")
            }
            Self::Postgres => format!("EXTRACT(EPOCH FROM ({end_field} - {start_field}))"),
        }
    }
}

/// Convert Ecto's `"$.foo"` JSON path to the Postgres `->>` key `"foo"`.
/// Strips a leading `$.` or `$`. Matches `lib/mydia/db.ex:605`.
pub fn sqlite_path_to_postgres_key(path: &str) -> String {
    let trimmed = path.strip_prefix("$.").unwrap_or(path);
    let trimmed = trimmed.strip_prefix('$').unwrap_or(trimmed);
    trimmed.to_owned()
}

/// Escape single quotes for inline SQL literals. The helpers in this
/// module only ever inline the JSON path / column-key constants the
/// developer wrote literally in code; never user input. We still escape
/// defensively so a stray apostrophe in a static path can't accidentally
/// break out.
fn escape_sql(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        if ch == '\'' {
            out.push('\'');
        }
        let _ = out.write_char(ch);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_extract_sqlite_format() {
        assert_eq!(
            Dialect::Sqlite.json_extract("metadata", "$.codec"),
            "json_extract(metadata, '$.codec')"
        );
    }

    #[test]
    fn json_extract_postgres_format() {
        assert_eq!(
            Dialect::Postgres.json_extract("metadata", "$.codec"),
            "(metadata)::jsonb ->> 'codec'"
        );
    }

    #[test]
    fn json_extract_integer_dialect_split() {
        assert_eq!(
            Dialect::Sqlite.json_extract_integer("d.metadata", "$.season"),
            "CAST(json_extract(d.metadata, '$.season') AS INTEGER)"
        );
        assert_eq!(
            Dialect::Postgres.json_extract_integer("d.metadata", "$.season"),
            "((d.metadata)::jsonb ->> 'season')::integer"
        );
    }

    #[test]
    fn json_not_null_dialect_split() {
        assert_eq!(
            Dialect::Sqlite.json_not_null("m.metadata", "$.release_date"),
            "json_extract(m.metadata, '$.release_date') IS NOT NULL"
        );
        assert_eq!(
            Dialect::Postgres.json_not_null("m.metadata", "$.release_date"),
            "((m.metadata)::jsonb ->> 'release_date') IS NOT NULL"
        );
    }

    #[test]
    fn cast_helpers() {
        assert_eq!(Dialect::Sqlite.cast_to_real("x"), "CAST(x AS REAL)");
        assert_eq!(Dialect::Postgres.cast_to_real("x"), "(x)::float");
        assert_eq!(Dialect::Sqlite.cast_to_integer("y"), "CAST(y AS INTEGER)");
        assert_eq!(Dialect::Postgres.cast_to_integer("y"), "(y)::integer");
    }

    #[test]
    fn timestamp_diff_dialect_split() {
        assert_eq!(
            Dialect::Sqlite.avg_timestamp_diff_seconds("j.completed_at", "j.attempted_at"),
            "AVG((julianday(j.completed_at) - julianday(j.attempted_at)) * 86400)"
        );
        assert_eq!(
            Dialect::Postgres.avg_timestamp_diff_seconds("j.completed_at", "j.attempted_at"),
            "AVG(EXTRACT(EPOCH FROM (j.completed_at - j.attempted_at)))"
        );
    }

    #[test]
    fn path_to_pg_key_strips_dollar_prefix() {
        assert_eq!(sqlite_path_to_postgres_key("$.codec"), "codec");
        assert_eq!(sqlite_path_to_postgres_key("$codec"), "codec");
        assert_eq!(sqlite_path_to_postgres_key("codec"), "codec");
    }
}
