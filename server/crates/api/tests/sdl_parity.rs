//! The contract gate.
//!
//! The Flutter player talks to both the Elixir server and this one. GraphQL
//! treats an unknown field as a document-level validation error, so a schema
//! that is missing one field fails the entire query it appears in. Structural
//! parity is therefore not a nicety, it is what keeps the player working.
//!
//! If this test fails, either this schema drifted or the Elixir schema did.
//! Run `mix schema.export` in the repo root to find out which.

use mydia_api::sdl::canonicalize;

fn reference_sdl() -> String {
    std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../player/lib/graphql/schema.graphql"
    ))
    .expect("reference schema not found")
}

#[test]
fn schema_matches_the_contract() {
    let ours = canonicalize(&mydia_api::schema_sdl()).unwrap();
    let reference = canonicalize(&reference_sdl()).unwrap();

    if ours != reference {
        let ours_lines: Vec<&str> = ours.lines().collect();
        let reference_lines: Vec<&str> = reference.lines().collect();

        let missing: Vec<&&str> = reference_lines
            .iter()
            .filter(|l| !ours_lines.contains(l))
            .collect();
        let extra: Vec<&&str> = ours_lines
            .iter()
            .filter(|l| !reference_lines.contains(l))
            .collect();

        panic!(
            "schema does not match the contract.\n\nmissing from this server:\n{}\n\nnot in the contract:\n{}",
            missing.iter().map(|l| format!("  {l}")).collect::<Vec<_>>().join("\n"),
            extra.iter().map(|l| format!("  {l}")).collect::<Vec<_>>().join("\n"),
        );
    }
}
