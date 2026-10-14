# Worked example: a USB film scanner

Target: Plustek film scanner, `07b3:1825`, device class `0xff` — vendor
specific, so no standard protocol applies and nothing is documented. Goal: a
SANE backend. This is the case the USB half of the harness exists for.

## Setup

    harness init ~/projects/scanner
    cd ~/projects/scanner
    cp .../examples/plustek-film-scanner/harness.conf .   # then edit VM_NAME
    winctl auth && harness iso
    # boot the ISO in the guest, run win-bootstrap.ps1 elevated
    winctl status            # ssh: ok

## What the device says about itself, before any tracing

    lsusb -d 07b3:1825 -v > captures/lsusb-verbose.txt
    for f in /sys/bus/usb/devices/*/idVendor; do ... done   # see sysfs-summary

    vendor=07b3 product=1825 rev=0702
    bDeviceClass       ff        <- vendor specific
    bDeviceProtocol    ff
    bMaxPacketSize0    64
    bNumConfigurations 1
    speed              480
    manufacturer       PLUSTEK INC
    product            Film Scanner(A2M)

Two useful facts immediately: one configuration (no mode switching to worry
about), and high speed (so bulk endpoints will carry image data in 512-byte
multiples).

## The capture series

Each capture answers one question. In order, with the labels actually used:

| label | what it establishes |
|---|---|
| `attach-only` | enumeration: descriptors, configuration selection, the vendor driver's first contact |
| `prescan-01` | what a low-resolution preview pass looks like end to end |
| `scan-300dpi` | a real scan at a known resolution, from the vendor app |
| `win-fullframe-300` | the same, full frame, to separate geometry from resolution |
| `sf-scan600-neg` | 600dpi negative — vary *one* axis against the 300dpi capture |
| `sf-prescan-pos` | positive film — vary the media type, nothing else |
| `linux-scan-300` | our own driver attempting the same 300dpi scan |
| `linux-scan-9216` | our driver at a different resolution, to check the scaling |

The method in one line: **the Windows captures are the specification, the
`linux-` captures are the test, and the diff between them is the bug list.**

Run them like this — the capture starts first, the device is exercised second:

    hostdev to-vm
    sudo -E ./bin/usbcap sf-scan600-neg 120 &
    winctl up                        # drive the vendor app in the off-screen session
    winctl shot                      # confirm where the GUI actually is
    winctl click 840 620             # press Scan

Then take the device back and do the Linux side with the same media in place:

    hostdev to-host
    sudo -E ./bin/usbcap linux-scan-600 120 &
    scanimage --resolution 600 > /dev/null

## Reading the diff

    tshark -r 20261006-121138-sf-scan600-neg.pcapng \
           -Y 'usb.transfer_type == 0x02 && usb.device_address == 18' \
           -T fields -e usb.setup.bRequest -e usb.setup.wValue \
           -e usb.setup.wIndex -e usb.data_fragment > win-600.txt
    # same for the linux capture, then:
    diff win-600.txt linux-600.txt | head -40

The first divergence that is not a timestamp is where to look. In practice the
early ones are almost always in the **init sequence** — a register the vendor
driver sets that yours does not — and the later ones are **timing**: a poll
loop your driver exits too early.

Comparing the 300dpi and 600dpi Windows captures against each other, rather
than against Linux, is what identifies the resolution and geometry registers:
everything that stays the same is setup, and the handful of bytes that change
are the parameters.

## Notes

- `bDeviceClass ff` means `usbcap`'s device-address filter is the only
  reliable one. Vendor requests will not decode into anything meaningful in
  Wireshark's dissector, so work from `usb.data_fragment` and your own notes.
- A scan is a physical, timed event. Capture the whole bus (`usbcap` does) and
  never try to re-derive a trace you discarded.
- Keep the film and the frame position identical between a Windows capture and
  its Linux counterpart, or the image data will differ for reasons that have
  nothing to do with your driver.
