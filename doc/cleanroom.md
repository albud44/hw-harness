# Staying clean-room

The point of this work is usually a driver that gets **merged** — into the
kernel, into SANE, into libcamera. That sets the constraint: the result has to
be something maintainers can accept, and something you can honestly say was
not derived from vendor code.

This is not legal advice. It is the working practice these tools are built
around, and the reason some obvious shortcuts are deliberately absent.

## In scope

Observing what the hardware does:

- USB/bus traces of the device in operation (`usbcap`)
- device descriptors, PnP properties, hardware and compatible IDs
- **INF files** — declarative, human-readable, meant to be read
- registry contents describing device and driver configuration
- ACPI/firmware tables (your own machine's firmware, describing your hardware)
- EEPROM contents from the device itself
- container structure of data blobs: magic numbers, section tags, sizes
- public documentation, datasheets, and the vendor's own open-source releases
  for related parts

All of this describes **the hardware**, or is published as text intended for
consumption. None of it is the vendor's program.

## Out of scope

- disassembling or decompiling `.sys`/`.dll` binaries
- stepping vendor code in a debugger to read its logic
- copying code, constants tables, or firmware blobs out of a driver binary and
  into your source
- translating vendor code structure into C, however loosely

`probes/dump-devices.ps1` collects descriptors, properties, registry data and
INF text, and deliberately does **not** copy or analyse vendor `.sys` code.
`bin/hwdbg` deliberately has no `insmod` of an arbitrary module. Those are not
oversights.

## The grey area, handled honestly

Two cases come up constantly and are worth being explicit about.

**Strings in a binary.** Running `strings` on a vendor driver and seeing
`[ReadModuleInfoFromEEPROM] lsc_width` tells you *that the driver reads lens
shading data from the module EEPROM*. That is a fact about the hardware's
design, and it points you at the EEPROM, which you then read from the device
itself. It is a long way from there to lifting an algorithm. Use such findings
as **signposts to hardware you then observe directly**, record them that way
in your notes, and do not let them become your implementation.

**Firmware the device needs.** Some devices must be fed a firmware blob at
init. You cannot write that blob yourself, and shipping the vendor's copy has
its own redistribution rules — handled upstream through `linux-firmware` or an
equivalent, not by embedding it in your driver.

## Practical hygiene

- Keep vendor packages in a clearly marked directory, unpacked with a
  decompressor (`innoextract`, `7z`, `msiexec /a`), never executed on the
  host. Treat the contents as untrusted data.
- Keep your notes in terms of **observed behaviour**: "after the 0x0b write
  the device reports ready within 40ms", not "the driver does X then Y".
- Write down, as you go, *which trace* each magic number came from. When a
  maintainer asks where a constant came from — and they will — "capture
  20261006-121138, frame 4471" is a complete answer. This is also simply good
  engineering: a constant whose origin nobody can reconstruct is a liability.
- Comment the protocol in your driver, not the vendor's implementation.

The discipline pays for itself at review time. A patch series whose constants
each trace back to a recorded observation is reviewable. One that cannot
explain its magic numbers is not mergeable no matter how well it works.
