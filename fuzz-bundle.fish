#!/usr/bin/env fish
# Run from anywhere inside the innigkeit checkout (the one with 01d0738 applied).
# Produces ./fuzz-bundle.tar.gz. Does not push or modify tracked files.
# Needs fish >= 3.4.

# --- config ---------------------------------------------------------------
set -g OUT fuzz-bundle
set -g bar_width 30

# Regex whose first capture group is the current iteration number, matched
# against the tail of the build log and the guest debugcon logs. This is a
# guess at the fuzzer's output format: adjust it, or set it to '' to get a
# bar that only advances when a whole run finishes.
set -g iter_regex '(?i)\biter(?:ation)?s?\D{0,3}(\d+)'

# One entry per run: name, iterations, seed.
set -g run_names check
set -g run_iters 40
set -g run_seeds 0x1234
for s in 0x1 0x2 0x3 0x4
    set -a run_names seed_$s
    set -a run_iters 2000
    set -a run_seeds $s
end

# --- setup ----------------------------------------------------------------
# Resolve the root first: a bare `cd (failed command)` would cd to $HOME,
# and the rm -rf below must never run there.
set -l root (git rev-parse --show-toplevel 2>/dev/null)
or begin
    echo "error: not inside a git checkout" >&2
    exit 1
end
cd $root; or exit 1

rm -rf $OUT fuzz-bundle.tar.gz
mkdir -p $OUT/guest-logs
rm -rf zig-out/fuzz-corpus # old crash files name the wrong descriptors

set -g total_iters (math (string join + $run_iters))
set -g done_iters 0
set -g t_start (date +%s)

# --- progress bar ---------------------------------------------------------
function fmt_time -a secs
    if test $secs -ge 3600
        printf '%d:%02d:%02d' (math "floor($secs / 3600)") (math "floor($secs % 3600 / 60)") (math "$secs % 60")
    else
        printf '%d:%02d' (math "floor($secs / 60)") (math "$secs % 60")
    end
end

# Highest iteration number seen so far in this run's logs (0 if none).
function current_iter -a log stamp iters
    if test -z "$iter_regex"
        echo 0
        return
    end
    set -l files $log (find .zig-cache -name test.log -newer $stamp 2>/dev/null)
    set -l n (tail -q -c 8192 $files 2>/dev/null | string match -rag -- $iter_regex | sort -n | tail -1)
    if test -z "$n"
        echo 0
    else
        math "min($n, $iters)"
    end
end

# Overall bar, weighted by iterations across all runs.
function draw_bar -a label cur iters
    isatty stderr; or return
    set -l frac (math "($done_iters + $cur) / $total_iters")
    set -l pct (math "floor($frac * 100)")
    set -l filled (math "floor($frac * $bar_width)")
    # Separate variables: `string repeat -n 0` yields no elements, which would
    # collapse an unquoted (a)(b) concatenation to nothing at 0% and 100%.
    set -l full (string repeat -n $filled █)
    set -l rest (string repeat -n (math $bar_width - $filled) ░)
    set -l bar "$full$rest"
    set -l elapsed (math (date +%s) - $t_start)

    set -l line (printf '[%s] %3d%%  %s' $bar $pct $label)
    if test $cur -gt 0
        set line "$line  iter $cur/$iters"
    end
    set line "$line  $(fmt_time $elapsed)"
    if test $pct -ge 2 -a $pct -lt 100
        set -l eta (math "floor($elapsed * (1 - $frac) / $frac)")
        set line "$line  ETA $(fmt_time $eta)"
    end
    printf '\r%s\e[K' $line >&2
end

function clear_bar
    isatty stderr; and printf '\r\e[K' >&2
end

# --- environment ----------------------------------------------------------
begin
    echo "== date"; date -u
    echo "== git log"; git log --oneline -5
    echo "== git status"; git status --short
    echo "== zig"; zig version
    echo "== qemu"; qemu-system-x86_64 --version | head -1
    echo "== cpus"; nproc
    echo "== kvm"; ls -l /dev/kvm 2>&1
    echo "== uname"; uname -a
    echo "== stale qemu"; pgrep -a qemu-system; or echo none
end >$OUT/env.txt 2>&1

# --- runs -----------------------------------------------------------------
function run_one -a idx
    set -l name $run_names[$idx]
    set -l iters $run_iters[$idx]
    set -l seed $run_seeds[$idx]
    set -l log $OUT/$name.log
    set -l label "$name ($idx/$(count $run_names))"

    pkill -f "[q]emu-system-x86_64" 2>/dev/null
    sleep 1
    set -l stamp (mktemp)
    set -l rcfile (mktemp)
    set -l t0 (date +%s)

    # Build runs in the background so the bar can be redrawn meanwhile; the
    # wrapper records the exit status, since fish can't background a block.
    sh -c 'timeout 3600 zig build test_x64 -Dfuzz_channel=true \
            -Dfuzz_iterations="$1" -Dfuzz_seed="$2" >"$3" 2>&1
           echo $? >"$4"' sh $iters $seed $log $rcfile &
    set -l pid $last_pid

    while not test -s $rcfile; and kill -0 $pid 2>/dev/null
        draw_bar $label (current_iter $log $stamp $iters) $iters
        sleep 1
    end
    wait $pid 2>/dev/null

    set -l rc (cat $rcfile)
    test -n "$rc"; or set rc '?'
    set -l secs (math (date +%s) - $t0)
    echo "exit=$rc seconds=$secs" >>$log

    # guest debugcon logs written by this run
    for f in (find .zig-cache -name test.log -newer $stamp 2>/dev/null)
        cp $f $OUT/guest-logs/{$name}_(echo $f | md5sum | string sub -l 6).log
    end
    rm -f $stamp $rcfile
    pkill -f "[q]emu-system-x86_64" 2>/dev/null

    set -g done_iters (math $done_iters + $iters)

    set -l mark ✓
    set -l note
    if test "$rc" != 0
        set mark ✗
        test "$rc" = 124; and set note '  (timed out)'
    end
    clear_bar
    printf '%s %-10s exit=%-3s %s%s\n' $mark $name $rc (fmt_time $secs) $note
    draw_bar $label 0 $iters
end

for i in (seq (count $run_names))
    run_one $i
end
clear_bar

# --- corpus ---------------------------------------------------------------
begin
    echo "== crashes"; ls -l zig-out/fuzz-corpus/crashes 2>&1
    echo "== interesting"; ls zig-out/fuzz-corpus/interesting 2>&1 | wc -l
end >$OUT/corpus-listing.txt
if test -d zig-out/fuzz-corpus/crashes
    cp -r zig-out/fuzz-corpus/crashes $OUT/crashes
end

# --- one-line digest per run ----------------------------------------------
for f in $OUT/*.log
    echo "--- $f"
    grep -E "kernel_fuzz:|mutation loop|timed out|panic|PANIC|exit=" $f | tail -8
end >$OUT/digest.txt

tar czf fuzz-bundle.tar.gz $OUT
ls -l fuzz-bundle.tar.gz
echo "Done. Send fuzz-bundle.tar.gz."
