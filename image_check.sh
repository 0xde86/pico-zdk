#!/usr/bin/env bash
# Validate the boot/runtime ELF layout for all pico-zdk firmware targets.
#
# The script deliberately inspects linked artifacts instead of trusting that a
# successful link implies a bootable image. It checks section locations and
# sizes, linker symbols, vector-table words, picobin metadata, startup
# instructions, and the RP2040 boot2 checksum.
#
# Usage:
#   ./image_check.sh
#
# Requirements:
#   bash, zig, llvm-readelf, llvm-objdump, llvm-objcopy, llvm-size, od, awk

set -u
set -o pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pico-zdk-m1-check.XXXXXX")"

pass_count=0
fail_count=0

cleanup() {
    rm -rf -- "${work_dir}"
}
trap cleanup EXIT

pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS  %s\n' "$1"
}

fail() {
    fail_count=$((fail_count + 1))
    printf 'FAIL  %s\n' "$1" >&2
    if (($# > 1)); then
        printf '      %s\n' "$2" >&2
    fi
}

# Compare normalized hexadecimal values. llvm-readelf omits the 0x prefix,
# while ELF program-header output includes it, so accept either representation.
check_hex() {
    local description="$1"
    local expected="${2#0x}"
    local actual="${3#0x}"
    local expected_value
    local actual_value

    expected="${expected,,}"
    actual="${actual,,}"

    if [[ ! "${expected}" =~ ^[0-9a-f]+$ || ! "${actual}" =~ ^[0-9a-f]+$ ]]; then
        fail "${description}" "expected 0x${expected}, got ${3:-<missing>}"
        return
    fi

    # Compare values rather than strings because readelf chooses different
    # zero-padding widths for addresses and section sizes.
    expected_value=$((16#${expected}))
    actual_value=$((16#${actual}))
    if ((actual_value == expected_value)); then
        printf -v actual '%08x' "${actual_value}"
        pass "${description} = 0x${actual}"
    else
        fail "${description}" "expected 0x${expected}, got ${3:-<missing>}"
    fi
}

check_text() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [[ "${actual}" == "${expected}" ]]; then
        pass "${description} = ${actual}"
    else
        fail "${description}" "expected ${expected}, got ${actual:-<missing>}"
    fi
}

check_contains() {
    local description="$1"
    local pattern="$2"
    local file="$3"

    if grep -Eq -- "${pattern}" "${file}"; then
        pass "${description}"
    else
        fail "${description}" "pattern not found: ${pattern}"
    fi
}

# Assert a section lies entirely within the first 4 KiB of flash - the window
# the RP2350 boot ROM scans for a valid IMAGE_DEF block loop (datasheet 5.1.12).
# This is the real placement contract; the exact offset is free to move as the
# vector table or IMAGE_DEF gains entries.
check_within_first_4k() {
    local description="$1"
    local addr="${2#0x}"
    local size="${3#0x}"
    local addr_value size_value end_value

    if [[ ! "${addr}" =~ ^[0-9a-fA-F]+$ || ! "${size}" =~ ^[0-9a-fA-F]+$ ]]; then
        fail "${description}" "unreadable address/size: 0x${addr:-?} / 0x${size:-?}"
        return
    fi

    addr_value=$((16#${addr}))
    size_value=$((16#${size}))
    end_value=$((addr_value + size_value))

    if ((addr_value >= 0x10000000 && end_value <= 0x10001000)); then
        pass "$(printf '%s (0x%x..0x%x)' "${description}" "${addr_value}" "${end_value}")"
    else
        fail "${description}" \
            "$(printf '0x%x..0x%x not within 0x10000000..0x10001000' "${addr_value}" "${end_value}")"
    fi
}

# Assert that end - start (two hex linker symbols) is strictly positive.
check_positive_size() {
    local description="$1"
    local start="${2#0x}"
    local end="${3#0x}"
    local size

    if [[ ! "${start}" =~ ^[0-9a-fA-F]+$ || ! "${end}" =~ ^[0-9a-fA-F]+$ ]]; then
        fail "${description}" "unreadable bounds: 0x${start:-?}..0x${end:-?}"
        return
    fi

    size=$((16#${end} - 16#${start}))
    if ((size > 0)); then
        pass "$(printf '%s (%d bytes)' "${description}" "${size}")"
    else
        fail "${description}" "size is ${size} bytes"
    fi
}

# Assert a hex value lies within the half-open range [lo, hi).
check_region() {
    local description="$1"
    local value="${2#0x}"
    local lo="$3"
    local hi="$4"
    local v

    if [[ ! "${value}" =~ ^[0-9a-fA-F]+$ ]]; then
        fail "${description}" "unreadable value: 0x${value:-?}"
        return
    fi

    v=$((16#${value}))
    if ((v >= 16#${lo} && v < 16#${hi})); then
        pass "${description} = 0x${value}"
    else
        fail "${description}" "0x${value} not in [0x${lo}, 0x${hi})"
    fi
}

# llvm-readelf -SW uses these fields:
#   [index] name type address offset size ...
section_address() {
    llvm-readelf -SW "$1" | awk -v section="$2" '$3 == section { print $5; exit }'
}

section_size() {
    llvm-readelf -SW "$1" | awk -v section="$2" '$3 == section { print $7; exit }'
}

symbol_address() {
    llvm-readelf -sW "$1" | awk -v symbol="$2" '$8 == symbol { print $2; exit }'
}

elf_machine() {
    llvm-readelf -h "$1" | awk -F: '/Machine:/ { value=$2; sub(/^[[:space:]]+/, "", value); print value; exit }'
}

elf_entry() {
    llvm-readelf -h "$1" | awk '/Entry point address:/ { print $4; exit }'
}

first_load_vaddr() {
    llvm-readelf -lW "$1" | awk '$1 == "LOAD" { print $3; exit }'
}

first_load_paddr() {
    llvm-readelf -lW "$1" | awk '$1 == "LOAD" { print $4; exit }'
}

# True if the ELF has a dedicated PT_LOAD describing initialized .data: a LOAD
# segment whose virtual address is in SRAM (0x20...) but whose physical/load
# address is in flash (0x10...). Columns: Type Offset VirtAddr PhysAddr ...
has_ram_init_segment() {
    llvm-readelf -lW "$1" |
        awk '$1 == "LOAD" && $3 ~ /^0x20/ && $4 ~ /^0x10/ { found = 1 } END { exit(found ? 0 : 1) }'
}

# Read a little-endian 32-bit word from a raw section dump without depending
# on the host byte order.
read_u32_le() {
    local file="$1"
    local offset="$2"
    local bytes
    local value

    # shellcheck disable=SC2207
    bytes=($(od -An -v -j "${offset}" -N 4 -tx1 "${file}"))
    if ((${#bytes[@]} != 4)); then
        return 1
    fi

    value=$((
        0x${bytes[0]} |
        (0x${bytes[1]} << 8) |
        (0x${bytes[2]} << 16) |
        (0x${bytes[3]} << 24)
    ))
    printf '%08x\n' "$((value & 0xffffffff))"
}

# Independently recompute CRC-32/MPEG-2 over the first 252 boot2 bytes.
# Parameters: poly=0x04c11db7, init=0xffffffff, refin=false, xorout=0.
boot2_crc32_mpeg2() {
    local file="$1"
    local crc=$((0xffffffff))
    local byte
    local bit

    while read -r byte; do
        [[ -z "${byte}" ]] && continue
        crc=$(((crc ^ (byte << 24)) & 0xffffffff))
        for ((bit = 0; bit < 8; bit++)); do
            if ((crc & 0x80000000)); then
                crc=$((((crc << 1) ^ 0x04c11db7) & 0xffffffff))
            else
                crc=$(((crc << 1) & 0xffffffff))
            fi
        done
    done < <(od -An -v -N 252 -tu1 "${file}" | tr -s ' ' '\n')

    printf '%08x\n' "${crc}"
}

build_target() {
    local label="$1"
    local prefix="$2"
    shift 2
    local log="${work_dir}/${label}.build.log"

    if (cd -- "${script_dir}" && zig build minimal "$@" --prefix "${prefix}") >"${log}" 2>&1; then
        pass "${label}: firmware builds"
        return 0
    fi

    fail "${label}: firmware builds" "build log follows"
    sed 's/^/      /' "${log}" >&2
    return 1
}

check_common_elf() {
    local label="$1"
    local elf="$2"
    local expected_machine="$3"
    local expected_stack="$4"
    local disassembly="${work_dir}/${label}.disassembly.txt"
    local text_size
    local start_symbol
    local entry_point

    check_text "${label}: ELF machine" "${expected_machine}" "$(elf_machine "${elf}")"

    # Relational invariant: the ELF entry point is whatever address _start
    # resolves to. Comparing the two symbols - instead of a hardcoded offset -
    # stays correct when the layout shifts (e.g. a new IMAGE_DEF item moves
    # _start without changing that the entry still equals it).
    start_symbol="$(symbol_address "${elf}" _start)"
    entry_point="$(elf_entry "${elf}")"
    check_hex "${label}: ELF entry point equals _start" "${start_symbol}" "${entry_point}"

    # _start must reside in the XIP flash region; its exact offset is not fixed.
    if [[ "${start_symbol}" == 100* ]]; then
        pass "${label}: _start resides in flash = 0x${start_symbol}"
    else
        fail "${label}: _start resides in flash" "got ${start_symbol:-<missing>}"
    fi

    check_hex "${label}: stack top" "${expected_stack}" "$(symbol_address "${elf}" __stack_top)"
    check_hex "${label}: first PT_LOAD virtual address" 10000000 "$(first_load_vaddr "${elf}")"
    check_hex "${label}: first PT_LOAD physical address" 10000000 "$(first_load_paddr "${elf}")"

    # Reset-time memory initialization must have real segments to act on. The
    # minimal fixture (examples/minimal/main.zig) carries an initialized global
    # (-> .data) and a zeroed global (-> .bss), so these checks prove an actual
    # load-in-flash / run-in-SRAM image exists rather than just verifying symbol
    # placement over empty sections.
    local data_load data_start data_end bss_start bss_end data_image
    data_load="$(symbol_address "${elf}" __data_load_start)"
    data_start="$(symbol_address "${elf}" __data_start)"
    data_end="$(symbol_address "${elf}" __data_end)"
    bss_start="$(symbol_address "${elf}" __bss_start)"
    bss_end="$(symbol_address "${elf}" __bss_end)"
    data_image="${work_dir}/${label}.data.bin"

    check_positive_size "${label}: .data has nonzero size" "${data_start}" "${data_end}"
    check_region "${label}: .data runtime VMA in SRAM" "${data_start}" 20000000 20090000
    check_region "${label}: .data load LMA in flash" "${data_load}" 10000000 11000000
    if [[ "${data_start}" != "${data_load}" ]]; then
        pass "${label}: .data LMA (flash) differs from VMA (SRAM)"
    else
        fail "${label}: .data LMA differs from VMA" "both 0x${data_start}"
    fi

    # A dedicated PT_LOAD must carry the .data initializer bytes: a LOAD segment
    # whose virtual address is in SRAM but whose load address is in flash.
    if has_ram_init_segment "${elf}"; then
        pass "${label}: dedicated PT_LOAD carries .data init image"
    else
        fail "${label}: dedicated PT_LOAD carries .data init image"
    fi

    # The flash image must actually hold the initializer, proving the LMA points
    # at real init bytes (fixture: initialized = 0x1234_5678).
    if llvm-objcopy --dump-section ".data=${data_image}" "${elf}"; then
        check_hex "${label}: .data flash image holds initializer" 12345678 "$(read_u32_le "${data_image}" 0)"
    else
        fail "${label}: .data flash image holds initializer" "could not extract .data"
    fi

    check_positive_size "${label}: .bss has nonzero size" "${bss_start}" "${bss_end}"
    check_region "${label}: .bss VMA in SRAM" "${bss_start}" 20000000 20090000
    if llvm-readelf -SW "${elf}" | grep -E "[[:space:]]\.bss[[:space:]]" | grep -q "NOBITS"; then
        pass "${label}: .bss is NOBITS (no flash footprint)"
    else
        fail "${label}: .bss is NOBITS (no flash footprint)"
    fi

    # An empty minimal application should remain small. This catches accidental
    # inclusion of the complete UBSan runtime, which previously added >90 KiB.
    text_size="$(llvm-size -A "${elf}" | awk '$1 == ".text" { print $2; exit }')"
    if [[ "${text_size}" =~ ^[0-9]+$ ]] && ((text_size < 4096)); then
        pass "${label}: minimal .text remains below 4 KiB (${text_size} bytes)"
    else
        fail "${label}: minimal .text remains below 4 KiB" "got ${text_size:-<missing>} bytes"
    fi

    llvm-objdump -d "${elf}" >"${disassembly}"
    check_contains "${label}: startup reaches application main" '<main\.main>' "${disassembly}"
}

check_rp2040() {
    local elf="$1"
    local boot2="${work_dir}/rp2040.boot2.bin"
    local vectors="${work_dir}/rp2040.vectors.bin"
    local calculated_crc
    local stored_crc
    local start_addr
    local stack_top

    check_common_elf rp2040 "${elf}" ARM 20042000
    start_addr="$(symbol_address "${elf}" _start)"
    stack_top="$(symbol_address "${elf}" __stack_top)"
    check_hex "rp2040: .boot2 address" 10000000 "$(section_address "${elf}" .boot2)"
    check_hex "rp2040: .boot2 size" 00000100 "$(section_size "${elf}" .boot2)"
    check_hex "rp2040: vector-table address" 10000100 "$(section_address "${elf}" .vectors)"
    check_hex "rp2040: vector-table size" 000000a8 "$(section_size "${elf}" .vectors)"

    if llvm-objcopy --dump-section ".boot2=${boot2}" "${elf}" &&
        llvm-objcopy --dump-section ".vectors=${vectors}" "${elf}"; then
        pass "rp2040: boot sections can be extracted"
    else
        fail "rp2040: boot sections can be extracted"
        return
    fi

    # Relational: the vector table's SP/reset words point at the linker's
    # __stack_top and _start, wherever those land.
    check_hex "rp2040: vector initial SP equals __stack_top" "${stack_top}" "$(read_u32_le "${vectors}" 0)"
    check_hex "rp2040: vector reset handler equals _start" "${start_addr}" "$(read_u32_le "${vectors}" 4)"

    calculated_crc="$(boot2_crc32_mpeg2 "${boot2}")"
    stored_crc="$(read_u32_le "${boot2}" 252)"
    check_hex "rp2040: independently calculated boot2 CRC" "${calculated_crc}" "${stored_crc}"
}

check_rp2350_arm() {
    local elf="$1"
    local image_def="${work_dir}/rp2350-arm.image_def.bin"
    local vectors="${work_dir}/rp2350-arm.vectors.bin"
    local disassembly="${work_dir}/rp2350-arm.disassembly.txt"
    local start_addr
    local stack_top

    check_common_elf rp2350-arm "${elf}" ARM 20082000
    start_addr="$(symbol_address "${elf}" _start)"
    stack_top="$(symbol_address "${elf}" __stack_top)"
    check_hex "rp2350-arm: vector-table address" 10000000 "$(section_address "${elf}" .vectors)"
    check_hex "rp2350-arm: vector-table size" 00000110 "$(section_size "${elf}" .vectors)"
    check_within_first_4k "rp2350-arm: IMAGE_DEF within first 4 KiB" \
        "$(section_address "${elf}" .image_def)" "$(section_size "${elf}" .image_def)"

    if llvm-objcopy --dump-section ".image_def=${image_def}" "${elf}" &&
        llvm-objcopy --dump-section ".vectors=${vectors}" "${elf}"; then
        pass "rp2350-arm: boot sections can be extracted"
    else
        fail "rp2350-arm: boot sections can be extracted"
        return
    fi

    check_hex "rp2350-arm: vector initial SP equals __stack_top" "${stack_top}" "$(read_u32_le "${vectors}" 0)"
    check_hex "rp2350-arm: vector reset handler equals _start" "${start_addr}" "$(read_u32_le "${vectors}" 4)"
    check_hex "rp2350-arm: block start marker" ffffded3 "$(read_u32_le "${image_def}" 0)"
    check_hex "rp2350-arm: ARM-S IMAGE_TYPE" 10210142 "$(read_u32_le "${image_def}" 4)"
    check_hex "rp2350-arm: LAST item" 000001ff "$(read_u32_le "${image_def}" 8)"
    check_hex "rp2350-arm: self-loop offset" 00000000 "$(read_u32_le "${image_def}" 12)"
    check_hex "rp2350-arm: block end marker" ab123579 "$(read_u32_le "${image_def}" 16)"

    llvm-objdump -d "${elf}" >"${disassembly}"
    # The startup must materialize the VTOR address 0xe000ed08. Accept either the
    # Cortex-M33 MOVW/MOVT pair (today's codegen) or a literal-pool load, so a
    # future code generator that lowers the constant differently still passes.
    check_contains "rp2350-arm: startup materializes VTOR low half (0xed08)" \
        '(movw[[:space:]].*#0xed08|0xe000ed08)' "${disassembly}"
    check_contains "rp2350-arm: startup materializes VTOR high half (0xe000)" \
        '(movt[[:space:]].*#0xe000|0xe000ed08)' "${disassembly}"
}

check_rp2350_riscv() {
    local elf="$1"
    local image_def="${work_dir}/rp2350-riscv.image_def.bin"
    local disassembly="${work_dir}/rp2350-riscv.disassembly.txt"
    local start_addr
    local stack_top
    local trap_addr
    local vectors_size

    check_common_elf rp2350-riscv "${elf}" RISC-V 20082000
    start_addr="$(symbol_address "${elf}" _start)"
    stack_top="$(symbol_address "${elf}" __stack_top)"
    check_hex "rp2350-riscv: trap-vector section at flash base" 10000000 "$(section_address "${elf}" .vectors)"
    check_within_first_4k "rp2350-riscv: IMAGE_DEF within first 4 KiB" \
        "$(section_address "${elf}" .image_def)" "$(section_size "${elf}" .image_def)"

    # RISC-V direct-mode mtvec only requires the trap vector to be 4-byte
    # aligned; its exact offset within .vectors is not fixed (the co-located
    # _default_trap handler may precede it). Verify the section is non-empty and
    # the trap symbol is aligned rather than pinning a byte offset.
    trap_addr="$(symbol_address "${elf}" _trap_vector)"
    vectors_size="$(section_size "${elf}" .vectors)"
    if [[ "${vectors_size}" =~ ^[0-9a-fA-F]+$ ]] && ((16#${vectors_size} > 0)); then
        pass "rp2350-riscv: trap vector present (.vectors = 0x${vectors_size} bytes)"
    else
        fail "rp2350-riscv: trap vector present" "got size ${vectors_size:-<missing>}"
    fi
    if [[ "${trap_addr}" =~ ^[0-9a-fA-F]+$ ]] && ((16#${trap_addr} % 4 == 0)); then
        pass "rp2350-riscv: _trap_vector is 4-byte aligned = 0x${trap_addr}"
    else
        fail "rp2350-riscv: _trap_vector is 4-byte aligned" "got ${trap_addr:-<missing>}"
    fi

    if llvm-objcopy --dump-section ".image_def=${image_def}" "${elf}"; then
        pass "rp2350-riscv: IMAGE_DEF can be extracted"
    else
        fail "rp2350-riscv: IMAGE_DEF can be extracted"
        return
    fi

    check_hex "rp2350-riscv: block start marker" ffffded3 "$(read_u32_le "${image_def}" 0)"
    check_hex "rp2350-riscv: RISC-V IMAGE_TYPE" 11010142 "$(read_u32_le "${image_def}" 4)"
    check_hex "rp2350-riscv: ENTRY_POINT header" 00000344 "$(read_u32_le "${image_def}" 8)"
    # Relational: the picobin ENTRY_POINT item encodes _start and __stack_top.
    check_hex "rp2350-riscv: encoded entry point equals _start" "${start_addr}" "$(read_u32_le "${image_def}" 12)"
    check_hex "rp2350-riscv: encoded stack pointer equals __stack_top" "${stack_top}" "$(read_u32_le "${image_def}" 16)"
    check_hex "rp2350-riscv: LAST item" 000004ff "$(read_u32_le "${image_def}" 20)"
    check_hex "rp2350-riscv: self-loop offset" 00000000 "$(read_u32_le "${image_def}" 24)"
    check_hex "rp2350-riscv: block end marker" ab123579 "$(read_u32_le "${image_def}" 28)"

    llvm-objdump -d "${elf}" >"${disassembly}"
    check_contains "rp2350-riscv: startup initializes gp" 'auipc[[:space:]]+gp' "${disassembly}"
    check_contains "rp2350-riscv: startup initializes sp" 'auipc[[:space:]]+sp' "${disassembly}"
    check_contains "rp2350-riscv: startup installs mtvec" 'csrw[[:space:]]+mtvec' "${disassembly}"
}

printf 'pico-zdk image validation\n'
printf 'Repository: %s\n\n' "${script_dir}"

# Report every missing prerequisite before stopping; subsequent checks cannot
# produce meaningful results without this toolchain.
missing_tools=0
for tool in zig llvm-readelf llvm-objdump llvm-objcopy llvm-size od awk grep sed tr; do
    if command -v "${tool}" >/dev/null 2>&1; then
        pass "tool available: ${tool}"
    else
        fail "tool available: ${tool}"
        missing_tools=1
    fi
done

if ((missing_tools)); then
    printf '\nSummary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
    exit 1
fi

printf '\nStatic and host checks\n'
if (cd -- "${script_dir}" && zig fmt --check build.zig src examples tools); then
    pass "Zig formatting is clean"
else
    fail "Zig formatting is clean"
fi

if (cd -- "${script_dir}" && zig build test); then
    pass "host unit tests pass"
else
    fail "host unit tests pass"
fi

readonly pico_prefix="${work_dir}/pico"
readonly arm_prefix="${work_dir}/pico2-arm"
readonly riscv_prefix="${work_dir}/pico2-riscv"

printf '\nFirmware builds\n'
pico_built=0
arm_built=0
riscv_built=0
build_target rp2040 "${pico_prefix}" -Dboard=pico && pico_built=1
build_target rp2350-arm "${arm_prefix}" -Dboard=pico2 -Darch=arm && arm_built=1
build_target rp2350-riscv "${riscv_prefix}" -Dboard=pico2 -Darch=riscv && riscv_built=1

printf '\nELF and boot-image checks\n'
if ((pico_built)); then
    check_rp2040 "${pico_prefix}/bin/minimal-pico"
fi
if ((arm_built)); then
    check_rp2350_arm "${arm_prefix}/bin/minimal-pico2-arm"
fi
if ((riscv_built)); then
    check_rp2350_riscv "${riscv_prefix}/bin/minimal-pico2-riscv"
fi

printf '\nSummary: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
if ((fail_count)); then
    exit 1
fi

printf 'M1 image validation succeeded.\n'
