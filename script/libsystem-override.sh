#!/bin/sh
# Adapted from Ghostty's libsystem_override.sh (MIT License).
# Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
# Keep Zig compiler-rt intrinsics in the embedded archive while ensuring
# ordinary libc and libm calls resolve to Apple's optimized libSystem.
set -eu

input="$1"
output="$2"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

cp "$input" "$output"
chmod u+w "$output"

cat >"$temporary_directory/localize.txt" <<'EOF'
_bcmp
_memcmp
_memcpy
_memmove
_memset
_strlen
___memcpy_chk
___memmove_chk
___memset_chk
___strcat_chk
___strcpy_chk
_ceil
_ceilf
_ceill
_cos
_cosf
_cosl
_exp
_exp2
_exp2f
_exp2l
_expf
_expl
_fabs
_fabsf
_fabsl
_floor
_floorf
_floorl
_fma
_fmaf
_fmal
_fmax
_fmaxf
_fmaxl
_fmin
_fminf
_fminl
_fmod
_fmodf
_fmodl
_log
_log10
_log10f
_log10l
_log2
_log2f
_log2l
_logf
_logl
_round
_roundf
_roundl
_sin
_sinf
_sinl
_sqrt
_sqrtf
_sqrtl
_tan
_tanf
_tanl
_trunc
_truncf
_truncl
EOF

cd "$temporary_directory"
xcrun ar x "$output" compiler_rt.o
chmod 644 compiler_rt.o

# nmedit accepts a keep-list rather than a localization list. Preserve every
# global compiler-rt definition except the stable libSystem exports above.
xcrun nm -g compiler_rt.o | awk '$2 ~ /^[A-TV-Z]$/ {print $3}' | sort -u >all.txt
sort -u localize.txt >localize-sorted.txt
comm -23 all.txt localize-sorted.txt >keep.txt
xcrun nmedit -s keep.txt compiler_rt.o

xcrun ar r "$output" compiler_rt.o
xcrun ranlib "$output" 2>/dev/null || true
