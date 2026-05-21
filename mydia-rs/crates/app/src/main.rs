// U1: workspace scaffolding only. The real supervision tree, config loader,
// tracing subscriber, DB pool, and HTTP server land in U3+. For now we just
// prove the binary boots a tokio runtime and exits cleanly.

fn main() -> std::process::ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            eprintln!("mydia-rs: failed to build tokio runtime: {err}");
            return std::process::ExitCode::FAILURE;
        }
    };

    runtime.block_on(async {
        println!(
            "mydia-rs {}: workspace scaffolding boot OK; exiting (U1).",
            env!("CARGO_PKG_VERSION")
        );
    });

    std::process::ExitCode::SUCCESS
}
