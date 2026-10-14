# Worked example: an internal MIPI camera

Target: Intel IPU7 + Sony IMX471 on a ThinkPad X1 Carbon Gen 14. The kernel
driver loads and the camera produces frames — they are just washed out and
soft. Nothing to sniff: the sensor sits on MIPI CSI-2 behind a PCIe IPU, and
the interesting configuration arrives through ACPI and i2c.

This is the shape of the problem when `usbcap` does not apply.

## What replaces tracing

**1. Ask Windows what the wiring is.**

    winctl probe 'ACPI\TBE*'

`dump-devices.ps1` returns the PnP tree, every property of the matched
devices, the registry `Enum`/`Class`/`Services` trees, the driver inventory,
the ACPI tables as Windows sees them, and the INF files. The INF is the prize:
it is text, it names the ACPI device it binds to, and it lists the init-time
values. Matching `ACPI\TBE20A0` in an INF against `Found supported sensor
TBE20A0:00` in your own kernel log confirms you are looking at the right part
before you spend a day on it.

**2. Read the firmware tables.**

    sudo hwdbg acpi
    iasl -d captures/acpi/SSDT*

On laptops the SSDTs carry the sensor data blobs and the GPIO/clock/regulator
wiring — reset lines, clock frequency, the INT3472 power companion. None of
this appears in any bus trace, and it is frequently the missing piece.

**3. Look at the vendor package without running it.**

Unpack installers with a decompressor (`innoextract`, `7z`, `msiexec /a`),
never by executing them, into a clearly marked untrusted directory. What you
are after is **structure, not code**: which files exist, what the tuning blobs
are named per camera module, and whether the blobs are tagged containers with
readable section headers. A vendor that ships an open-source stack for an
earlier generation may have published the type definitions for those very
sections, which turns an opaque blob into a parseable one.

**4. Read the module's own EEPROM.**

    sudo hwdbg i2cscan                    # find it; "UU" means a driver owns it
    sudo hwdbg eeprom 0 0x50 0 4096 16    # dump it

Per-unit calibration — lens shading, autofocus ranges, colour — is commonly
stored on the camera module itself rather than in any driver file. That is
worth internalising: it means the vendor binary never contained those values
either, so there was nothing there to copy. The data is on your hardware, and
reading it off your own hardware is unambiguously fine.

## Linux-side debugging

With `hwdbg.conf` installed (see [privilege-model.md](../../doc/privilege-model.md)):

    sudo hwdbg config          # confirm what this install is scoped to
    sudo hwdbg dyndbg on       # pr_debug for ipu7/isys/imx471/bridge
    sudo hwdbg reload          # cycle the stack, show the probe log
    sudo hwdbg klog 400
    sudo hwdbg topology        # media-ctl -p: the pipeline as the kernel sees it
    sudo hwdbg pm              # runtime PM, for works-until-suspend bugs
    sudo hwdbg i2creg 0x0016 2 # sensor register, 16-bit addressing

`reload` is the workhorse: teardown and bring-up order are configured
separately because they are not reverses of each other — a consumer module
must go down before the core it references.

## Note on the config

`hwdbg.conf` here is the real one for this device: module list, i2c bus 0
address 0x1a, 16-bit registers, IPU7 at PCI `0000:00:05.0`, ACPI globs `TBE*`
and `INT3472*`. Copy it, edit `ACPI_OUT` and `OWNER_UID`, and install it
root-owned — `hwdbg` refuses a config it does not trust, for the reasons in
[privilege-model.md](../../doc/privilege-model.md).
