use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=MYDIA_RS_SKIP_FRONTEND_BUILD");

    if std::env::var("MYDIA_RS_SKIP_FRONTEND_BUILD").is_ok() {
        println!("cargo:warning=MYDIA_RS_SKIP_FRONTEND_BUILD set, skipping frontend build");
        return;
    }

    // Paths are relative to the crate root (crates/web-spa/).
    let frontend_dir = std::path::Path::new("../../frontend");

    // Emit rerun-if-changed so Cargo knows when to re-run this script.
    // Touch any of these and the frontend gets rebuilt on the next
    // `cargo build`.
    println!(
        "cargo:rerun-if-changed=../../frontend/package.json"
    );
    println!(
        "cargo:rerun-if-changed=../../frontend/pnpm-lock.yaml"
    );
    println!(
        "cargo:rerun-if-changed=../../frontend/vite.config.ts"
    );
    println!(
        "cargo:rerun-if-changed=../../frontend/tsconfig.json"
    );
    println!(
        "cargo:rerun-if-changed=../../frontend/index.html"
    );
    println!(
        "cargo:rerun-if-changed=../../frontend/src"
    );

    // Install dependencies only when node_modules is missing or outdated.
    let node_modules = frontend_dir.join("node_modules");
    let lockfile = frontend_dir.join("pnpm-lock.yaml");
    let needs_install = !node_modules.exists()
        || !node_modules.join(".modules.yaml").exists()
        || lockfile_modified_since(&lockfile, &node_modules);

    if needs_install {
        println!("cargo:warning=pnpm install (node_modules missing or stale)");
        run_pnpm(frontend_dir, &["install", "--frozen-lockfile"]);
    }

    // Build the production bundle.
    println!("cargo:warning=pnpm build");
    run_pnpm(frontend_dir, &["run", "build"]);
}

fn lockfile_modified_since(lockfile: &std::path::Path, node_modules: &std::path::Path) -> bool {
    let Ok(lm) = std::fs::metadata(lockfile) else {
        return false;
    };
    let Ok(lm_time) = lm.modified() else {
        return false;
    };
    let Ok(nm) = std::fs::metadata(node_modules) else {
        return true;
    };
    let Ok(nm_time) = nm.modified() else {
        return true;
    };
    lm_time > nm_time
}

fn run_pnpm(dir: &std::path::Path, args: &[&str]) {
    let status = Command::new("pnpm")
        .args(args)
        .current_dir(dir)
        .status()
        .unwrap_or_else(|e| {
            panic!(
                "Failed to run pnpm {} in {}: {e}",
                args.join(" "),
                dir.display()
            )
        });

    if !status.success() {
        panic!(
            "pnpm {} exited with status {}",
            args.join(" "),
            status.code().unwrap_or(-1)
        );
    }
}
