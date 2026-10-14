# The method

The technique this repo automates, independent of the scripts.

## The idea

For most unsupported hardware there already exists a working driver: the
vendor's Windows one. It is the only artefact that definitely knows the
device's initialisation order, register map, timing requirements and quirks.

You cannot read it — legally you should not, and practically it is a stripped
binary. But you can **watch it work**. Run the vendor driver in a VM, give it
the real hardware, and record what crosses the wire from outside the VM. The
result is a ground-truth transcript of a working session against your exact
hardware, which you then reproduce from a Linux driver.

The whole approach rests on one asymmetry: **the guest cannot tell it is being
observed.** `usbmon` runs on the host kernel, below the passthrough layer. No
driver-level hooking, no debugger, nothing for anti-tamper to notice, and
critically: no behavioural difference between tracing the Windows driver and
tracing your own Linux driver. The two traces are directly comparable because
they were made by the same instrument at the same layer.

## The loop

    1. baseline       capture the device doing nothing, to learn what idle looks like
    2. observe        pass the device to the VM, exercise it from the vendor UI, capture
    3. reproduce      take the device back, run your Linux driver, capture the same operation
    4. diff           compare the two transcripts
    5. hypothesise    the first meaningful divergence is your bug
    6. repeat         narrow the operation until the two traces match

Most of the work is step 6, and the single most useful discipline is making
each capture answer **one** question. A 120-second capture of "a scan" tells
you much less than three 20-second captures of "lamp on", "carriage home" and
"one line at 300dpi".

## Capture hygiene

Four rules, each of which was learned by losing data:

**Capture the whole bus, filter at analysis time.** `usbcap` deliberately does
not filter to the target device. A physical event — a scan, a camera stream, a
calibration pass — may not be reproducible byte-for-byte, so a wrong filter
loses data you cannot re-capture. Disk is cheap, the scan you cannot repeat is
not.

**Write down what you did.** `usbcap` drops a `.meta` beside every capture:
device, bus address, duration, label. Add the setting you used in the label
(`scan-300dpi-negative`, not `test3`), and anything else in `USBCAP_NOTE=`.
Six weeks later an unlabelled trace is just noise.

**Record the matching pair.** Always capture the Linux side of the same
operation while the setup is still identical: same media in the scanner, same
lighting for the camera, same resolution. A Windows trace with no Linux
counterpart cannot be diffed, and reconstructing the conditions later is
harder than it sounds.

**Capture the attach, once.** `hostdev to-vm` with a capture already running
records the device's full enumeration — descriptors, configuration selection,
the vendor driver's first contact. That transcript answers a surprising number
of later questions.

## Reading a USB trace

Open in Wireshark, or filter from the shell:

    # everything to/from the device
    tshark -r capture.pcapng -Y 'usb.device_address == 18'

    # control transfers only: this is usually the register interface
    tshark -r capture.pcapng -Y 'usb.transfer_type == 0x02'

    # vendor-specific requests, with their payloads
    tshark -r capture.pcapng -Y 'usb.bmRequestType & 0x60' \
           -T fields -e usb.setup.bRequest -e usb.setup.wValue \
           -e usb.setup.wIndex -e usb.data_fragment

What you are looking for, in order of usefulness:

- **The init sequence.** The first few dozen control transfers after attach.
  This is the part your driver most often gets wrong, and the part no
  datasheet will tell you.
- **Register writes bracketing an operation.** The device is a state machine;
  the vendor driver sets it up, triggers, then polls. The polling loop reveals
  which status bit means "ready".
- **What changes between two settings.** Capture at 300dpi and at 600dpi, diff
  the control transfers, and the resolution register identifies itself. This
  is the highest-yield trick in the whole method: vary exactly one thing.
- **Bulk transfer sizes and timing.** Short reads, ZLPs and inter-packet gaps
  carry real protocol meaning, and timeouts are frequently the difference
  between a driver that works and one that hangs.

## When there is no bus to sniff

An internal MIPI camera, a PCIe accelerator, an I2C touchpad: the interesting
traffic never crosses a bus you can tap from the host. The method shifts from
tracing to **declarative archaeology**, and the Windows VM is still where the
answers are:

- `winctl probe` runs `dump-devices.ps1` in the guest and pulls back the PnP
  tree, every property of every matched device, the registry `Enum` and
  `Services` trees, the driver inventory, the USB topology, the ACPI tables as
  Windows sees them, and the **INF files**.
- The INF is the single best artefact in this whole exercise. It is text, it
  is declarative, it is meant to be read, and it contains exactly what you
  need: hardware and compatible IDs, the ACPI device it binds to, init-time
  registry values, quirk flags and power settings. Many driver questions are
  answered by one `grep` over an INF.
- ACPI tables (`hwdbg acpi`, then `iasl -d`) describe the platform wiring that
  no trace can show: which GPIO is the reset line, which regulator powers the
  sensor, what the clock frequency is, what the companion device is called.
- Vendor calibration blobs can often be understood as **containers** without
  disassembling any code — magic numbers, tagged sections, sizes. If the
  vendor also ships an open-source stack for a previous generation, the type
  definitions may be public and the blob becomes decodable rather than opaque.
- Per-unit calibration frequently lives in an **EEPROM on the module**, not in
  any file. `hwdbg i2cscan` finds it, `hwdbg eeprom` dumps it. This matters:
  it means no amount of reading the vendor driver would have given you the
  values, so there is nothing to be gained from trying.

## The boundary

Observe behaviour; do not read or translate code. See
[cleanroom.md](cleanroom.md). This is not only a legal position — it is also
why the result is usually *better* than a translation would be: a driver
written from observed protocol behaviour against a documented register map is
reviewable, upstreamable, and does not carry someone else's bugs.
