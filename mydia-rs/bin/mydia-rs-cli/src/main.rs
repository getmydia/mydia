// U1: clap stub for the user-management CLI. The real `user list/add/delete/
// reset-password` subcommands land alongside the auth port (U6).

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "mydia-rs-cli",
    version,
    about = "Administrative CLI for mydia-rs (analog of `mix mydia.user`)"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// User management (stub; full implementation lands with the auth port).
    User,
}

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Some(Command::User) | None => {
            println!("mydia-rs-cli: stub — full CLI lands with the auth port.");
        }
    }
}
