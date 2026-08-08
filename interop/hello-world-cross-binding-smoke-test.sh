#!/usr/bin/env bash
# HelloWorld cross-binding interoperability smoke test: builds all four
# hello_world ports (zig, c, cpp, java), then runs every ordered
# (publisher, subscriber) pair across different languages -- the full
# 4x3=12-pair mesh among {zig, c, cpp, java} -- over real UDP DDS discovery.
#
# Unlike shape_main, each hello_world port is two separate binaries
# (publisher/subscriber), not one binary with a -P/-S role flag.
#
# A pair only counts as passing if all 10 samples were actually received in
# order, not just that both processes exited 0 -- see
# shape-cross-binding-smoke-test.sh's comment for why that distinction
# matters (a QoS/wire mismatch can still exit 0).
#
# Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./hello-world-cross-binding-smoke-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZZDDS_ZIG_OUT="${ZZDDS_ZIG_OUT:-"$REPO_ROOT/../zzdds/zig-out"}"

# Dedicated domain, distinct from custom-allocator's (7), shape's (9), and
# the default (0) every hello_world binary would otherwise use -- so this
# can't cross-talk with anything else that might be running nearby.
DOMAIN=10

ZIG_DIR="$REPO_ROOT/zig/hello_world"
C_DIR="$REPO_ROOT/c/hello_world"
CPP_DIR="$REPO_ROOT/cpp/hello_world"
JAVA_DIR="$REPO_ROOT/java/hello_world"

JAVA_CP="$JAVA_DIR/build/classes"

# ── Build ────────────────────────────────────────────────────────────────

echo "== Building zig/hello_world =="
mkdir -p "$ZIG_DIR/zig-out"
if ! ( cd "$ZIG_DIR" && zig build -Doptimize=ReleaseSafe > zig-out/build.log 2>&1 ); then
    echo "FAIL: zig/hello_world build -- see $ZIG_DIR/zig-out/build.log" >&2
    exit 1
fi

build_cmake_hello_world() {
    local dir="$1" name="$2"
    echo "== Building $name =="
    rm -rf "$dir/build"
    mkdir -p "$dir/build"
    if ! ( cmake -DCMAKE_PREFIX_PATH="$ZZDDS_ZIG_OUT" -B "$dir/build" -S "$dir" > "$dir/build/cmake.log" 2>&1 \
        && cmake --build "$dir/build" >> "$dir/build/cmake.log" 2>&1 ); then
        echo "FAIL: $name build -- see $dir/build/cmake.log" >&2
        exit 1
    fi
}
build_cmake_hello_world "$C_DIR" "c/hello_world"
build_cmake_hello_world "$CPP_DIR" "cpp/hello_world"

echo "== Building java/hello_world =="
mkdir -p "$JAVA_DIR/build"
if ! ( cd "$JAVA_DIR" && ZZDDS_ZIG_OUT="$ZZDDS_ZIG_OUT" ./build.sh > build/build.log 2>&1 ); then
    echo "FAIL: java/hello_world build -- see $JAVA_DIR/build/build.log" >&2
    exit 1
fi

for bin in "$ZIG_DIR/zig-out/bin/hello_world_pub" "$ZIG_DIR/zig-out/bin/hello_world_sub" \
           "$C_DIR/build/hello_world_pub" "$C_DIR/build/hello_world_sub" \
           "$CPP_DIR/build/hello_world_pub" "$CPP_DIR/build/hello_world_sub"; do
    [ -x "$bin" ] || { echo "FAIL: expected binary not found: $bin" >&2; exit 1; }
done
[ -d "$JAVA_CP" ] || { echo "FAIL: expected Java classes dir not found: $JAVA_CP" >&2; exit 1; }

# pub_cmd/sub_cmd <lang> -- sets the global CMD array to that language's
# publisher/subscriber argv, ready to have "-d $DOMAIN" appended by the caller.
pub_cmd() {
    case "$1" in
        zig)  CMD=("$ZIG_DIR/zig-out/bin/hello_world_pub") ;;
        c)    CMD=("$C_DIR/build/hello_world_pub") ;;
        cpp)  CMD=("$CPP_DIR/build/hello_world_pub") ;;
        java) CMD=(java --enable-native-access=ALL-UNNAMED \
                  -Djava.library.path="$ZZDDS_ZIG_OUT/lib" -cp "$JAVA_CP" Publisher) ;;
        *) echo "FAIL: unknown lang '$1'" >&2; exit 1 ;;
    esac
}
sub_cmd() {
    case "$1" in
        zig)  CMD=("$ZIG_DIR/zig-out/bin/hello_world_sub") ;;
        c)    CMD=("$C_DIR/build/hello_world_sub") ;;
        cpp)  CMD=("$CPP_DIR/build/hello_world_sub") ;;
        java) CMD=(java --enable-native-access=ALL-UNNAMED \
                  -Djava.library.path="$ZZDDS_ZIG_OUT/lib" -cp "$JAVA_CP" Subscriber) ;;
        *) echo "FAIL: unknown lang '$1'" >&2; exit 1 ;;
    esac
}

# run_pair <pub_lang> <sub_lang>
run_pair() {
    local pub_lang="$1" sub_lang="$2"
    local label="$pub_lang pub -> $sub_lang sub"
    local logdir; logdir="$(mktemp -d)"

    sub_cmd "$sub_lang"; local sub_run=("${CMD[@]}")
    pub_cmd "$pub_lang"; local pub_run=("${CMD[@]}")

    LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" timeout 15 "${sub_run[@]}" -d "$DOMAIN" \
        > "$logdir/sub.log" 2>&1 &
    local sub_pid=$!
    sleep 1
    LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" timeout 15 "${pub_run[@]}" -d "$DOMAIN" \
        > "$logdir/pub.log" 2>&1
    local pub_rc=$?
    wait "$sub_pid"
    local sub_rc=$?

    local ok=1
    [ "$pub_rc" -eq 0 ] || ok=0
    [ "$sub_rc" -eq 0 ] || ok=0
    grep -q "Publisher: done." "$logdir/pub.log" || ok=0
    grep -q "Subscriber: received all 10 samples in order." "$logdir/sub.log" || ok=0

    if [ "$ok" -eq 1 ]; then
        echo "OK: $label"
        rm -rf "$logdir"
        return 0
    fi
    echo "FAIL: $label (pub_rc=$pub_rc sub_rc=$sub_rc)" >&2
    echo "-- publisher log --" >&2; cat "$logdir/pub.log" >&2
    echo "-- subscriber log --" >&2; cat "$logdir/sub.log" >&2
    rm -rf "$logdir"
    return 1
}

# ── Full mesh: every ordered pair of distinct languages ───────────────────

LANGS=(zig c cpp java)
FAILED=0
for pub_lang in "${LANGS[@]}"; do
    for sub_lang in "${LANGS[@]}"; do
        [ "$pub_lang" = "$sub_lang" ] && continue
        run_pair "$pub_lang" "$sub_lang" || FAILED=1
    done
done

if [ "$FAILED" -ne 0 ]; then
    echo "FAIL: hello_world cross-binding smoke test" >&2
    exit 1
fi
echo "OK: all 12 hello_world cross-binding pairs (zig, c, cpp, java) interoperate."
