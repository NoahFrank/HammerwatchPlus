"""Patch Heroes of Hammerwatch 2 PACKAGER.exe so it runs without Steam.

Usage:  python patch_packager.py <pristine PACKAGER.exe> <output PACKAGER.exe>

What it does
------------
SteamService::Initialize (a virtual method) does, in order:

    SetEnvironmentVariableA("SteamAppId", ...)
    call [SteamAPI_Init]                 ; result ignored
    mov  ecx, [rbx+14h]
    call [SteamAPI_RestartAppIfNecessary]
    test al, al / je ...
    ... SteamInternal_ContextInit -> null check -> "Failed to initialize Steam!" -> exit(1)
    ... SetUnhandledExceptionFilter, log "Steam ID: %llx" (uses ISteamUser), ...
    mov  ecx, 8 / call operator new      ; <- allocates the cloud-save service, sets flags, returns

The patch overwrites the 6-byte `call [SteamAPI_Init]` with `jmp <mov ecx,8>` + nop,
so every Steam call in that function is skipped and only the non-Steam tail runs.

Signature (no fixed offsets):
  FF 15 r32  8B 4B 14  FF 15 r32  84 C0  74 xx
where the first FF15 must resolve to the SteamAPI_Init IAT slot and the second to
SteamAPI_RestartAppIfNecessary. The jump target is the first `B9 08 00 00 00 E8`
after the instruction that references the "Steam ID: %llx" string (searched within
0x200 bytes of the Init call). Both must be unique or the script refuses to patch.
"""
import re
import sys

import pefile


def iat_slots(pe):
    base = pe.OPTIONAL_HEADER.ImageBase
    slots = {}
    for entry in pe.DIRECTORY_ENTRY_IMPORT:
        if entry.dll.lower() == b"steam_api64.dll":
            for imp in entry.imports:
                if imp.name:
                    slots[imp.name.decode()] = imp.address - base
    return slots


def main(src, dst):
    data = bytearray(open(src, "rb").read())
    pe = pefile.PE(data=bytes(data))
    slots = iat_slots(pe)
    init_slot = slots["SteamAPI_Init"]
    restart_slot = slots["SteamAPI_RestartAppIfNecessary"]

    text = next(s for s in pe.sections if s.Name.rstrip(b"\0") == b".text")
    traw, tva, tsize = text.PointerToRawData, text.VirtualAddress, text.SizeOfRawData
    tdata = bytes(data[traw:traw + tsize])

    sig = re.compile(rb"\xFF\x15(....)\x8B\x4B\x14\xFF\x15(....)\x84\xC0\x74.", re.S)
    hits = []
    for m in sig.finditer(tdata):
        rva = tva + m.start()
        d1 = int.from_bytes(m.group(1), "little", signed=True)
        d2 = int.from_bytes(m.group(2), "little", signed=True)
        if rva + 6 + d1 == init_slot and rva + 15 + d2 == restart_slot:
            hits.append(m.start())
    if len(hits) != 1:
        sys.exit(f"init-call signature matched {len(hits)} times; refusing to patch")
    call_off = hits[0]
    call_rva = tva + call_off

    # Locate the "Steam ID: %llx" string and its rip-relative lea near the call.
    sid = data.find(b"Steam ID: %llx\0")
    if sid < 0:
        sys.exit('"Steam ID: %llx" string not found')
    sid_rva = pe.get_rva_from_offset(sid)
    window = tdata[call_off:call_off + 0x200]
    lea_end = None
    for i in range(len(window) - 7):
        if window[i] in (0x48, 0x4C) and window[i + 1] == 0x8D and (window[i + 2] & 0xC7) == 5:
            disp = int.from_bytes(window[i + 3:i + 7], "little", signed=True)
            if call_rva + i + 7 + disp == sid_rva:
                lea_end = i + 7
                break
    if lea_end is None:
        sys.exit('no lea of "Steam ID: %llx" within 0x200 bytes of SteamAPI_Init call')
    tgt = window.find(b"\xB9\x08\x00\x00\x00\xE8", lea_end)
    if tgt < 0:
        sys.exit("jump target (mov ecx,8; call new) not found")
    target_rva = call_rva + tgt

    rel = target_rva - (call_rva + 5)
    patch = b"\xE9" + rel.to_bytes(4, "little", signed=True) + b"\x90"
    file_off = traw + call_off
    orig = bytes(data[file_off:file_off + 6])
    data[file_off:file_off + 6] = patch
    open(dst, "wb").write(data)
    print(f"patched file offset 0x{file_off:X} (RVA 0x{call_rva:X}): "
          f"{orig.hex(' ')} -> {patch.hex(' ')}  (jmp RVA 0x{target_rva:X})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
