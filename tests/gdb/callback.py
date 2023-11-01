# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import json
import struct
from pathlib import Path
from typing import NamedTuple


class MMap(NamedTuple):
    start: int
    end: int
    mode: str
    offset: int
    ids: str
    inode: int
    name: str


class BasicCallbackBreakpoint(gdb.Breakpoint):
    def __init__(self, location: str, callback):
        self.callback = callback
        print(f"setting breakpoint @ {location}")
        super().__init__(location)

    def stop(self):
        return self.callback()


def get_bin_name() -> Path:
    """
    Get executable name from gdb
    """
    return Path(gdb.current_progspace().filename)


def get_program():
    return gdb.inferiors()[-1]


def get_pid() -> int:
    """
    Get pid of the running process
    """
    return get_program().pid


def get_entrypoint() -> int:
    """
    Get entrypoint offset from /proc
    """
    with open(f"/proc/{get_pid()}/exe", "rb") as fid:
        data = fid.read(32)
        value = struct.unpack("<Q", data[0x18:])
        return value[0]


def get_maps() -> list[MMap]:
    maps = []
    with open(f"/proc/{get_pid()}/maps", "rb") as fid:
        for line in fid.read().decode().splitlines():
            try:
                address_range, mode, offset, ids, inode, name = line.split()
            except ValueError:
                continue
            else:
                start, end = address_range.split("-")
                maps.append(
                    MMap(
                        int(start, 16),
                        int(end, 16),
                        mode,
                        int(offset, 16),
                        ids,
                        int(inode),
                        name,
                    )
                )
    return maps


def read_memory(address: int, length: int) -> bytes:
    """
    Read given length of bytes at address of memory
    """
    return bytes(get_program().read_memory(address, length))


def get_register(name: str) -> int:
    """
    Get value of register by its name
    """
    frame = gdb.selected_frame()
    value = int(frame.read_register(name))
    if value < 0:
        return value & 0xFFFFFFFFFFFFFFFF
    return value


# callback on _start that sets a second callback
def start_callback():
    """
    callback for _start

    then then sets breakpoint for entrypoint during which we can inspect
    the state of the program memory
    """
    print("callback on _start initiated")

    bin_path = get_bin_name()
    entrypoint_offset = get_entrypoint()
    mapping = next(i for i in get_maps() if i.name == str(bin_path) and "x" in i.mode)
    start = mapping.start
    offset = mapping.offset
    entrypoint = start + entrypoint_offset - offset

    print(f"binary = {bin_path}")
    print(f"entrypoint_offset = {hex(entrypoint_offset)}")
    print(f"start = {hex(start)}")
    print(f"offset = {hex(offset)}")
    print(f"entrypoint = {hex(entrypoint)}")

    try:
        # set NEW breakpoint with new callback
        BasicCallbackBreakpoint(f"*{hex(entrypoint)}", entry_callback)
    except Exception as e:
        print(e)

    return True


# callback on actual entrypoint that grabs memory and writes it to tmp file for checking
def entry_callback():
    print("callback on entrypoint initiated")

    pc = get_register("pc")
    memory = read_memory(pc, 0x20)

    print(f"pc = {pc:02x}")
    print(
        json.dumps(
            {
                "pc_memory": memory.hex(),
            },
            indent=2,
        )
    )


def setbp():
    # set breakpoint at _start to ensure callback is called
    BasicCallbackBreakpoint("_start", start_callback)
