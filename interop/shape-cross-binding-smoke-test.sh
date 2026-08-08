#!/usr/bin/env bash
# Shape cross-binding interoperability smoke test: builds all four shape_main
# ports (zig/shape, c/shape, cpp/shape, java/shape) against a single zzdds
# checkout, then runs every ordered (publisher, subscriber) pair across
# different languages -- the full 4x3=12-pair mesh among {zig, c, cpp, java},
# not just the minimal zig->c->cpp->java->zig ring -- over real UDP DDS
# discovery.
#
# A pair only counts as passing if a real sample was actually received, not
# just that both processes exited 0 -- a QoS mismatch also exits 0 by design
# (see java/shape/README.md's "Cross-binding interop" section for exactly
# the bug this distinction caught: Java's codegen used to silently negotiate
# an incompatible wire format with itself and everyone else, always exiting
# clean either way). So each pair additionally requires: the publisher log
# shows on_publication_matched(), the subscriber log shows at least one real
# received-sample line, and neither log mentions incompatible_qos.
#
# Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./shape-cross-binding-smoke-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZZDDS_ZIG_OUT="${ZZDDS_ZIG_OUT:-"$REPO_ROOT/../zzdds/zig-out"}"

# Dedicated domain so this can't cross-talk with cross-binding-smoke-test.sh
# or anything else that might be running nearby -- every port defaults to
# domain 0.
DOMAIN=9
ITERATIONS=8
PERIOD_MS=300

ZIG_DIR="$REPO_ROOT/zig/shape"
C_DIR="$REPO_ROOT/c/shape"
CPP_DIR="$REPO_ROOT/cpp/shape"
JAVA_DIR="$REPO_ROOT/java/shape"

ZIG_BIN="$ZIG_DIR/zig-out/bin/shape_main"
C_BIN="$C_DIR/build/shape_main"
CPP_BIN="$CPP_DIR/build/shape_main"
JAVA_CP="$JAVA_DIR/build/classes"

# ── Build ────────────────────────────────────────────────────────────────

echo "== Building zig/shape =="
mkdir -p "$ZIG_DIR/zig-out"
if ! ( cd "$ZIG_DIR" && zig build -Doptimize=ReleaseSafe > zig-out/build.log 2>&1 ); then
    echo "FAIL: zig/shape build -- see $ZIG_DIR/zig-out/build.log" >&2
    exit 1
fi

build_cmake_shape() {
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
build_cmake_shape "$C_DIR" "c/shape"
build_cmake_shape "$CPP_DIR" "cpp/shape"

echo "== Building java/shape =="
mkdir -p "$JAVA_DIR/build"
if ! ( cd "$JAVA_DIR" && ZZDDS_ZIG_OUT="$ZZDDS_ZIG_OUT" ./build.sh > build/build.log 2>&1 ); then
    echo "FAIL: java/shape build -- see $JAVA_DIR/build/build.log" >&2
    exit 1
fi

for bin in "$ZIG_BIN" "$C_BIN" "$CPP_BIN"; do
    [ -x "$bin" ] || { echo "FAIL: expected binary not found: $bin" >&2; exit 1; }
done
[ -d "$JAVA_CP" ] || { echo "FAIL: expected Java classes dir not found: $JAVA_CP" >&2; exit 1; }

# build_cmd <lang> -- sets the global CMD array to that language's argv0(+
# fixed args), ready to have role/common flags appended by the caller.
build_cmd() {
    case "$1" in
        zig)  CMD=("$ZIG_BIN") ;;
        c)    CMD=("$C_BIN") ;;
        cpp)  CMD=("$CPP_BIN") ;;
        java) CMD=(java --enable-native-access=ALL-UNNAMED \
                  -Djava.library.path="$ZZDDS_ZIG_OUT/lib" -cp "$JAVA_CP" ShapeMain) ;;
        *) echo "FAIL: unknown lang '$1'" >&2; exit 1 ;;
    esac
}

# run_pair <pub_lang> <sub_lang>
run_pair() {
    local pub_lang="$1" sub_lang="$2"
    local label="$pub_lang pub -> $sub_lang sub"
    local logdir; logdir="$(mktemp -d)"

    build_cmd "$sub_lang"; local sub_cmd=("${CMD[@]}")
    build_cmd "$pub_lang"; local pub_cmd=("${CMD[@]}")

    LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" timeout 15 "${sub_cmd[@]}" \
        -S -d "$DOMAIN" -i "$ITERATIONS" --read-period "$PERIOD_MS" \
        > "$logdir/sub.log" 2>&1 &
    local sub_pid=$!
    sleep 1
    LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" timeout 15 "${pub_cmd[@]}" \
        -P -w -d "$DOMAIN" -i "$ITERATIONS" --write-period "$PERIOD_MS" \
        > "$logdir/pub.log" 2>&1
    local pub_rc=$?
    wait "$sub_pid"
    local sub_rc=$?

    local ok=1
    [ "$pub_rc" -eq 0 ] || ok=0
    [ "$sub_rc" -eq 0 ] || ok=0
    grep -q "on_publication_matched()" "$logdir/pub.log" || ok=0
    grep -Eq '^[A-Za-z_]+ +[A-Za-z_]+ +[0-9]{3} +[0-9]{3} +\[[0-9]+\]' "$logdir/sub.log" || ok=0
    grep -qi "incompatible_qos" "$logdir/pub.log" "$logdir/sub.log" && ok=0

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
    echo "FAIL: shape cross-binding smoke test" >&2
    exit 1
fi
echo "OK: all 12 shape_main cross-binding pairs (zig, c, cpp, java) interoperate."

# ── ContentFilteredTopic (--cft) check, one per binding ───────────────────
#
# Filtering happens entirely on the subscriber side (each binding's own
# generated get_field_from_cdr), so a same-language pair per binding is
# enough to prove each backend's filter codegen actually works -- this
# isn't about wire interop (already proven above), it's about "does this
# binding's ContentFilteredTopic reader actually drop non-matching samples."
#
# Publisher cycles shapesize 1,2,3,4,1,2,3,4 deterministically (-z 0
# --size-modulo 4); subscriber filters for "shapesize > 2", so exactly half
# of 8 published samples (the 3s and 4s) should ever reach it.

run_cft_check() {
    local lang="$1"
    local label="$lang --cft"
    local logdir; logdir="$(mktemp -d)"

    build_cmd "$lang"; local sub_run=("${CMD[@]}")
    build_cmd "$lang"; local pub_run=("${CMD[@]}")

    # Subscriber -i gates the outer poll-loop count, not "samples received",
    # and there's no way to stop early once satisfied (only SIGINT sets
    # shape_main's g_all_done). Give it a generous 12s budget (-i 40 at the
    # same read-period) -- comfortably more than the publisher's own 2.4s
    # write window (8 * 300ms) plus realistic SPDP/SEDP discovery/match
    # settling time, including on a slower/noisier CI runner than a local
    # dev box. A longer pre-publish sleep (2s, up from the plain mesh
    # check's 1s) gives discovery extra room to complete *before* the
    # publisher's first write -- VOLATILE durability (the default) means a
    # sample written before the reader has actually matched is lost for
    # that reader forever, not just delayed.
    LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" timeout 20 "${sub_run[@]}" \
        -S -d "$DOMAIN" --cft "shapesize > 2" -i 40 --read-period "$PERIOD_MS" \
        > "$logdir/sub.log" 2>&1 &
    local sub_pid=$!
    sleep 2
    LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" timeout 20 "${pub_run[@]}" \
        -P -w -d "$DOMAIN" -z 0 --size-modulo 4 -i 8 --write-period "$PERIOD_MS" \
        > "$logdir/pub.log" 2>&1
    local pub_rc=$?
    wait "$sub_pid"
    local sub_rc=$?

    # Exact-count check, not presence-only: shapesize cycles 1,2,3,4,1,2,3,4
    # across the 8 published samples, so a correctly filtering subscriber
    # (shapesize > 2) must receive exactly two 3s and two 4s -- no 1s/2s
    # (filter actually filters) and no fewer than 4 matches (delivery wasn't
    # silently incomplete).
    local n1 n2 n3 n4
    n1=$(grep -cE '\[1\]$' "$logdir/sub.log")
    n2=$(grep -cE '\[2\]$' "$logdir/sub.log")
    n3=$(grep -cE '\[3\]$' "$logdir/sub.log")
    n4=$(grep -cE '\[4\]$' "$logdir/sub.log")

    local ok=1
    [ "$pub_rc" -eq 0 ] || ok=0
    [ "$sub_rc" -eq 0 ] || ok=0
    [ "$n1" -eq 0 ] || ok=0
    [ "$n2" -eq 0 ] || ok=0
    [ "$n3" -eq 2 ] || ok=0
    [ "$n4" -eq 2 ] || ok=0

    if [ "$ok" -eq 1 ]; then
        echo "OK: $label"
        rm -rf "$logdir"
        return 0
    fi
    echo "FAIL: $label (pub_rc=$pub_rc sub_rc=$sub_rc, received [1]=$n1 [2]=$n2 [3]=$n3 [4]=$n4, expected 0 0 2 2)" >&2
    echo "-- publisher log --" >&2; cat "$logdir/pub.log" >&2
    echo "-- subscriber log --" >&2; cat "$logdir/sub.log" >&2
    rm -rf "$logdir"
    return 1
}

CFT_FAILED=0
for lang in "${LANGS[@]}"; do
    run_cft_check "$lang" || CFT_FAILED=1
done

if [ "$CFT_FAILED" -ne 0 ]; then
    echo "FAIL: shape ContentFilteredTopic check" >&2
    exit 1
fi
echo "OK: --cft filters correctly in all 4 bindings (zig, c, cpp, java)."
