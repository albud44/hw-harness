# hw-harness

Tooling for working out how a piece of hardware behaves, so you can write a
Linux driver for it.

The premise: for most unsupported hardware, a working driver already exists —
the vendor's Windows one. You should not read it, and you do not need to. Run
it in a VM, give it the real device, and record what crosses the wire **from
outside the VM**. You get a ground-truth transcript of a working session
against your exact hardware, which you then reproduce from Linux.

`usbmon` runs on the host kernel, below the passthrough layer, so the guest
cannot tell it is being watched — and the same instrument records your Linux
driver doing the same operation. The two traces are directly comparable. That
comparison is the method; everything here exists to make it routine.

Built while writing a SANE backend for a Plustek film scanner and fixing an
Intel IPU7 + IMX471 laptop camera. Start with **[doc/method.md](doc/method.md)**.

## What you get

| | |
|---|---|
| `harness` | scaffold a project, check your machine, build the guest bootstrap ISO |
| `winctl`  | drive the Windows VM: SSH, off-screen RDP, synthetic input, device probes |
| `usbcap`  | time-boxed `usbmon` capture of the device, with metadata sidecars |
| `hostdev` | move the device between host and guest |
| `hwdbg`   | scoped root helper for Linux-side debugging: modules, debugfs, i2c, ACPI |

Plus `probes/`: a PowerShell device/driver/firmware dumper that collects
descriptors, PnP properties, registry trees, ACPI tables and INF files — and
deliberately does not touch vendor `.sys` code.

## Requirements

Developed and tested on Fedora. You need libvirt/KVM and a **Windows 11 Pro**
guest (Home has no RDP server):

    sudo dnf install libvirt virt-manager freerdp xorg-x11-server-Xvfb \
                     xdotool libsecret wireshark-cli usbutils ImageMagick \
                     acpica-tools xorriso
    sudo usermod -aG libvirt,wireshark $USER    # then log out and back in

`harness doctor` checks all of it and tells you what is missing and why it
matters.

## Quickstart

One clone of this repo serves every investigation. The clone is the *tool*; a
*project directory* holds one device's configuration, keys and captures.

    git clone https://github.com/YOU/hw-harness ~/src/hw-harness
    export PATH="$HOME/src/hw-harness/bin:$PATH"

    harness doctor
    harness init ~/projects/myscanner
    cd ~/projects/myscanner
    $EDITOR harness.conf            # VM_NAME, USB_VID/USB_PID from lsusb

    winctl auth                     # generates an SSH key, stores the RDP password
    harness iso                     # bootstrap.iso, carrying the PUBLIC key only

Attach `bootstrap.iso` to the VM and, in an **elevated** PowerShell in the
guest:

    powershell -ExecutionPolicy Bypass -File D:\win-bootstrap.ps1

Back on Linux:

    winctl status                   # ssh: ok

Then the actual work:

    hostdev to-vm                           # guest gets the hardware
    sudo -E ./bin/usbcap win-scan-300 90 &  # host records it anyway
    winctl up                               # drive the vendor app off-screen
    winctl shot                             # see where its GUI really is
    winctl click 840 620

    hostdev to-host                         # take the device back
    sudo -E ./bin/usbcap linux-scan-300 90 &
    scanimage --resolution 300 > /dev/null  # your driver, same operation

    # the diff between those two captures is your bug list

For a device with no bus to tap — an internal MIPI camera, say — the Windows
VM is still where the answers are, but through `winctl probe` (INF files,
registry, ACPI) and `hwdbg` rather than `usbcap`. See
[examples/ipu7-imx471](examples/ipu7-imx471/).

## Documentation

- **[doc/method.md](doc/method.md)** — the technique itself: the capture loop,
  capture hygiene, how to read a trace, and what to do when there is no bus
- [doc/vm-setup.md](doc/vm-setup.md) — building the Windows reference VM, the
  Windows OpenSSH gotcha that costs everyone an afternoon, why off-screen RDP
- [doc/privilege-model.md](doc/privilege-model.md) — what needs root, what
  only needs a group, and how `hwdbg` stays scoped
- [doc/cleanroom.md](doc/cleanroom.md) — the observe-don't-decompile boundary,
  and why it makes the result better rather than merely safer
- [examples/](examples/) — two real investigations: a USB film scanner and an
  internal MIPI camera

## Two things to know before you start

**Keep your project state out of git.** `harness init` writes a `.gitignore`
for you: `etc/` holds a private SSH key, and `captures/` holds traces that may
contain device serial numbers. The project directory usually lives inside the
repo holding your driver work, so this matters.

**Stay on the observation side of the line.** Traces, descriptors, INF text,
registry data, firmware tables and EEPROM contents describe *the hardware*.
Disassembling the vendor's driver is a different activity with different
consequences, and the tools here deliberately do not help with it — mostly
because a driver whose every constant traces back to a recorded observation is
one a maintainer can actually merge.

## Contributing

Shell is bash with `set -euo pipefail`, checked with `shellcheck`; PowerShell
is checked with `PSScriptAnalyzer`. Both run in CI.

Comments explain *why*, especially where the code looks odd — there is
generally a lost afternoon behind it, and the next person deserves to keep
theirs. The comment above `winctl`'s use of `/args-from:file:` is the model.

MIT licensed.
