# Vendored WASI WIT

Source and licence: see `../../../NOTICE` (WebAssembly/WASI, Apache-2.0 WITH LLVM-exception).

- `io/`, `clocks/`, `sockets/`: the 0.2.0 files from wit-bindgen-cli 0.62.0 (commit
  c604ee01c03f50d7301984a3c920a650752cd136, `tests/codegen/wasi-http/wit/deps`).
  The only edit is a textual rewrite of `@0.2.0` to `@0.2.6`.
- `http/`: the `wasi:http@0.2.0` view printed by `wasm-tools component wit` from the
  guest component. It uses io at 0.2.6 already, so it is unedited.

Why the rewrite: the .NET guest imports wasi:io, wasi:clocks and wasi:sockets at 0.2.6.
The deny component must export types the guest's imports unify with, and rustc's
wasm32-wasip2 adapter merges its own full 0.2.6 copy of these packages, so ours must carry
the same package version and the full (unpruned) interfaces. The 0.2.0 to 0.2.6 interface
shapes used here are identical.
