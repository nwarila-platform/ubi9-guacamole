#!/usr/bin/env python3
"""Read the small ELF surface used by GUAC01 without parsing binutils prose."""
from pathlib import Path
import struct


PT_LOAD = 1
PT_DYNAMIC = 2
PT_GNU_STACK = 0x6474E551
PT_GNU_RELRO = 0x6474E552

DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_STRSZ = 10
DT_SONAME = 14
DT_RPATH = 15
DT_TEXTREL = 22
DT_BIND_NOW = 24
DT_FLAGS = 30
DT_RUNPATH = 29
DT_FLAGS_1 = 0x6FFFFFFB

DF_BIND_NOW = 0x8
DF_1_NOW = 0x1
PF_X = 0x1
ET_DYN = 3


class ElfError(ValueError):
    """An ELF file is malformed or uses an unsupported representation."""


def inspect_elf(path):
    data = Path(path).read_bytes()
    if len(data) < 16 or data[:4] != b"\x7fELF":
        raise ElfError(f"not ELF: {path}")
    elf_class, encoding = data[4], data[5]
    if elf_class not in (1, 2) or encoding not in (1, 2):
        raise ElfError(f"unsupported ELF class/encoding: {path}")
    byte_order = "<" if encoding == 1 else ">"
    if elf_class == 1:
        header_format = byte_order + "HHIIIIIHHHHHH"
        program_format = byte_order + "IIIIIIII"
        dynamic_format = byte_order + "iI"
    else:
        header_format = byte_order + "HHIQQQIHHHHHH"
        program_format = byte_order + "IIQQQQQQ"
        dynamic_format = byte_order + "qQ"

    header_size = struct.calcsize(header_format)
    if len(data) < 16 + header_size:
        raise ElfError(f"truncated ELF header: {path}")
    header = struct.unpack_from(header_format, data, 16)
    elf_type, program_offset, program_entry_size, program_count = (
        header[0], header[4], header[8], header[9]
    )
    expected_program_size = struct.calcsize(program_format)
    if program_count == 0xFFFF or (program_count and program_entry_size < expected_program_size):
        raise ElfError(f"unsupported ELF program-header table: {path}")

    programs = []
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        if offset + expected_program_size > len(data):
            raise ElfError(f"truncated ELF program headers: {path}")
        values = struct.unpack_from(program_format, data, offset)
        if elf_class == 1:
            p_type, p_offset, p_vaddr, _, p_filesz, p_memsz, p_flags, _ = values
        else:
            p_type, p_flags, p_offset, p_vaddr, _, p_filesz, p_memsz, _ = values
        programs.append({
            "type": p_type,
            "flags": p_flags,
            "offset": p_offset,
            "vaddr": p_vaddr,
            "filesz": p_filesz,
            "memsz": p_memsz,
        })

    dynamic_entry_size = struct.calcsize(dynamic_format)
    dynamic = []
    for program in programs:
        if program["type"] != PT_DYNAMIC:
            continue
        start = program["offset"]
        end = start + program["filesz"]
        if end > len(data):
            raise ElfError(f"truncated ELF dynamic table: {path}")
        for offset in range(start, end, dynamic_entry_size):
            if offset + dynamic_entry_size > end:
                raise ElfError(f"misaligned ELF dynamic table: {path}")
            tag, value = struct.unpack_from(dynamic_format, data, offset)
            if tag == DT_NULL:
                break
            dynamic.append((tag, value))

    def dynamic_value(tag):
        return next((value for candidate, value in dynamic if candidate == tag), None)

    def virtual_to_offset(address):
        for program in programs:
            if (program["type"] == PT_LOAD and
                    program["vaddr"] <= address < program["vaddr"] + program["filesz"]):
                return program["offset"] + address - program["vaddr"]
        raise ElfError(f"unmapped ELF virtual address: {path}")

    strings = b""
    string_address = dynamic_value(DT_STRTAB)
    string_size = dynamic_value(DT_STRSZ)
    if string_address is not None and string_size is not None:
        string_offset = virtual_to_offset(string_address)
        if string_offset + string_size > len(data):
            raise ElfError(f"truncated ELF string table: {path}")
        strings = data[string_offset:string_offset + string_size]

    def string_at(offset):
        if offset >= len(strings):
            raise ElfError(f"invalid ELF string offset: {path}")
        end = strings.find(b"\0", offset)
        if end < 0:
            raise ElfError(f"unterminated ELF string: {path}")
        return strings[offset:end].decode("utf-8", errors="strict")

    needed = [string_at(value) for tag, value in dynamic if tag == DT_NEEDED]
    soname_values = [string_at(value) for tag, value in dynamic if tag == DT_SONAME]
    stack = next((program for program in programs if program["type"] == PT_GNU_STACK), None)
    flags = dynamic_value(DT_FLAGS) or 0
    flags_1 = dynamic_value(DT_FLAGS_1) or 0
    tags = {tag for tag, _ in dynamic}
    checks = {
        "ET_DYN": elf_type == ET_DYN,
        "NONEXEC_STACK": stack is not None and not (stack["flags"] & PF_X),
        "GNU_RELRO": any(program["type"] == PT_GNU_RELRO for program in programs),
        "BIND_NOW": DT_BIND_NOW in tags or bool(flags & DF_BIND_NOW) or bool(flags_1 & DF_1_NOW),
        "NO_TEXTREL": DT_TEXTREL not in tags,
        "NO_RPATH": DT_RPATH not in tags and DT_RUNPATH not in tags,
    }
    return {"checks": checks, "needed": needed, "sonames": soname_values}
