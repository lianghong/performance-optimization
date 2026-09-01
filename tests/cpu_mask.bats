#!/usr/bin/env bats
#
# Unit tests for the CPU-mask helpers in network_optimize.sh.
#
# cpu_mask_for_cores builds the mask that gets written to rps_cpus/xps_cpus.
# normalize_cpu_mask exists because the kernel does not echo that mask back
# verbatim: it strips leading zeros from the most significant group, so a
# correctly applied mask compares unequal to what was written and --verify
# reports drift that is not there.

load helpers/extract_fn.sh

setup() {
    NET="$BATS_TEST_DIRNAME/../network_optimize.sh"
    eval "$(extract_fn "$NET" cpu_mask_for_cores)"
    eval "$(extract_fn "$NET" normalize_cpu_mask)"
}

# ----- cpu_mask_for_cores -----

@test "cpu_mask_for_cores covers cores within one 32-bit group" {
    [ "$(cpu_mask_for_cores 1)" = "00000001" ]
    [ "$(cpu_mask_for_cores 4)" = "0000000f" ]
    [ "$(cpu_mask_for_cores 28)" = "0fffffff" ]
    [ "$(cpu_mask_for_cores 32)" = "ffffffff" ]
}

@test "cpu_mask_for_cores spans multiple groups low-group-first" {
    [ "$(cpu_mask_for_cores 40)" = "000000ff,ffffffff" ]
    [ "$(cpu_mask_for_cores 64)" = "ffffffff,ffffffff" ]
    [ "$(cpu_mask_for_cores 96)" = "ffffffff,ffffffff,ffffffff" ]
}

@test "cpu_mask_for_cores clamps degenerate core counts to one CPU" {
    [ "$(cpu_mask_for_cores 0)" = "00000001" ]
    [ "$(cpu_mask_for_cores -3)" = "00000001" ]
}

# ----- normalize_cpu_mask -----

@test "normalize_cpu_mask strips leading zeros from the top group" {
    [ "$(normalize_cpu_mask 0fffffff)" = "fffffff" ]
    [ "$(normalize_cpu_mask 0000000f)" = "f" ]
    [ "$(normalize_cpu_mask ffffffff)" = "ffffffff" ]
}

@test "normalize_cpu_mask leaves lower groups padded" {
    # Only the most significant group is stripped; the rest stay 8 digits,
    # which is exactly how the kernel prints a multi-group mask.
    [ "$(normalize_cpu_mask 000000ff,ffffffff)" = "ff,ffffffff" ]
    [ "$(normalize_cpu_mask 00000001,00000000)" = "1,00000000" ]
}

@test "normalize_cpu_mask keeps an all-zero mask as a single zero" {
    [ "$(normalize_cpu_mask 00000000)" = "0" ]
    [ "$(normalize_cpu_mask 0)" = "0" ]
}

@test "normalize_cpu_mask makes written and read-back masks compare equal" {
    # The real defect: what cpu_mask_for_cores writes vs. what sysfs returns.
    # Assert against literals so this cannot pass by both sides being empty.
    local written
    written=$(cpu_mask_for_cores 28)
    [ "$written" = "0fffffff" ]
    [ "$(normalize_cpu_mask "$written")" = "fffffff" ]
    [ "$(normalize_cpu_mask fffffff)" = "fffffff" ]

    written=$(cpu_mask_for_cores 40)
    [ "$written" = "000000ff,ffffffff" ]
    [ "$(normalize_cpu_mask "$written")" = "ff,ffffffff" ]
    [ "$(normalize_cpu_mask ff,ffffffff)" = "ff,ffffffff" ]
}
