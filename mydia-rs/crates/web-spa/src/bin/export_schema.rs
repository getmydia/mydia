use std::fs;
use std::path::PathBuf;

use async_graphql::Schema;
use clap::Parser;
use mydia_rs_graphql::schema::{MutationRoot, QueryRoot};
use mydia_rs_graphql::subscriptions::SubscriptionRoot;

#[derive(Parser)]
#[command(name = "export-schema")]
struct Cli {
    /// Output path for the generated SDL file.
    #[arg(short, long, default_value = "frontend/schema.graphql")]
    out: PathBuf,
}

fn main() {
    let cli = Cli::parse();

    let schema = Schema::build(
        QueryRoot::default(),
        MutationRoot::default(),
        SubscriptionRoot,
    )
    .finish();

    let sdl = schema.sdl();

    if let Some(parent) = cli.out.parent() {
        fs::create_dir_all(parent).expect("Failed to create output directory");
    }

    fs::write(&cli.out, sdl).expect("Failed to write SDL file");

    eprintln!("SDL written to {}", cli.out.display());
}
