#!/usr/bin/env bats
#
# Tests for the --isolate-cpus range validator. Reimplements the same logic
# the script runs after format validation (system_optimize.sh), so we can
# test it in isolation.

validate_isolate_cpus() {
    local spec=$1 max=$2
    if [[ ! "$spec" =~ ^[0-9]+([,\-][0-9]+)*$ ]]; then
        echo "format error"
        return 2
    fi
    local max_cpu=$((max - 1))
    local IFS=','
    read -ra parts <<<"$spec"
    local part lo hi
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            lo=${part%-*}
            hi=${part#*-}
            [[ $lo -gt $hi ]] && { echo "reversed range"; return 1; }
            [[ $hi -gt $max_cpu ]] && { echo "out of range: $hi"; return 1; }
        else
            [[ $part -gt $max_cpu ]] && { echo "out of range: $part"; return 1; }
        fi
    done
    echo ok
}

@test "accepts single CPU within range" {
    run validate_isolate_cpus "3" 8
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "accepts range within bounds" {
    run validate_isolate_cpus "2-5" 8
    [ "$status" -eq 0 ]
}

@test "accepts mixed comma-and-range list" {
    run validate_isolate_cpus "1,3-5,7" 8
    [ "$status" -eq 0 ]
}

@test "rejects CPU equal to core count (off-by-one)" {
    run validate_isolate_cpus "8" 8
    [ "$status" -eq 1 ]
    [[ "$output" == *"out of range"* ]]
}

@test "rejects CPU beyond core count" {
    run validate_isolate_cpus "9999" 8
    [ "$status" -eq 1 ]
}

@test "rejects upper bound of range beyond core count" {
    run validate_isolate_cpus "2-99" 8
    [ "$status" -eq 1 ]
    [[ "$output" == *"out of range"* ]]
}

@test "rejects reversed range" {
    run validate_isolate_cpus "5-2" 8
    [ "$status" -eq 1 ]
    [[ "$output" == *"reversed"* ]]
}

@test "rejects non-numeric input" {
    run validate_isolate_cpus "abc" 8
    [ "$status" -eq 2 ]
    [[ "$output" == *"format"* ]]
}

@test "rejects trailing comma" {
    run validate_isolate_cpus "1,2," 8
    [ "$status" -eq 2 ]
}

@test "accepts CPU 0 on single-core system" {
    run validate_isolate_cpus "0" 1
    [ "$status" -eq 0 ]
}
