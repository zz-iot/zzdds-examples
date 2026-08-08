# interop

Cross-language/cross-binding tests: these don't belong under `c/`, `cpp/`,
`java/`, or `zig/` individually because they exercise more than one binding
at once.

- `cross-binding-smoke-test.sh` — builds `c/custom-allocator` and
  `cpp/custom-allocator`, then runs each one's publisher against the other's
  subscriber (both directions), over real UDP DDS discovery. Confirms the C
  and C++ bindings are wire-compatible, not just each internally consistent.

  ```sh
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./cross-binding-smoke-test.sh
  ```

- `shape-cross-binding-smoke-test.sh` — builds all four `shape` ports
  (`zig/shape`, `c/shape`, `cpp/shape`, `java/shape`) and runs every ordered
  publisher/subscriber pair across all four bindings (12 pairs total). Also
  checks each binding's `--cft` (`ContentFilteredTopic`) support: a
  same-language pub/sub pair with the subscriber filtering on `shapesize`,
  confirming every binding's reader actually drops non-matching samples.

  ```sh
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./shape-cross-binding-smoke-test.sh
  ```

- `hello-world-cross-binding-smoke-test.sh` — builds all four `hello_world`
  ports and runs every ordered publisher/subscriber pair across all four
  bindings (12 pairs total).

  ```sh
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./hello-world-cross-binding-smoke-test.sh
  ```
