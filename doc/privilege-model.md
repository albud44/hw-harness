# Privilege model

Hardware debugging needs root for a handful of specific things, and `sudo su`
for a whole working session is both unnecessary and a good way to break your
own machine at 2am. The harness splits it in three.

## What needs no privilege at all

More than people expect. On a typical desktop distribution:

- `journalctl -k` works for members of `wheel`/`adm`, even when `dmesg` is
  blocked by `kernel.dmesg_restrict=1`
- `/dev/video*`, `/dev/media*`, `/dev/v4l-subdev*` carry ACLs granting the
  seat's active user read/write
- `lsusb`, `lspci`, sysfs attributes, `media-ctl -p`
- everything `winctl` does: it is SSH and a private X display, both unprivileged

Check before reaching for sudo.

## What needs a group, not root

`usbmon` capture. `dumpcap` is installed `0750 root:wireshark`, so adding
yourself to `wireshark` makes captures possible without sudo:

    sudo usermod -aG wireshark $USER     # then log out and back in

`/dev/usbmon*` is still root-only on most distributions, so `usbcap` is
documented with `sudo` anyway. Group membership alone does not get past
that: `dumpcap`'s file capabilities are network ones, and they do not open
a root-only device node. A udev rule does, and makes the module load at
boot while you are at it:

    echo 'SUBSYSTEM=="usbmon", GROUP="wireshark", MODE="0640"' |
        sudo tee /etc/udev/rules.d/50-accessible-usbmon.rules
    echo usbmon | sudo tee /etc/modules-load.d/usbmon.conf
    sudo udevadm control --reload-rules
    sudo modprobe usbmon && sudo udevadm trigger --subsystem-match=usbmon

After that, `usbcap` runs as a plain member of `wireshark`, and
`harness doctor` reports `/dev/usbmon*` as readable.

## What genuinely needs root: hwdbg

Module reload, `dynamic_debug`, debugfs, raw i2c and ACPI table reads. These
are root-only and there is no group to join.

`bin/hwdbg` is a **fixed-function helper**. It takes no free-form command,
path or module name — every privileged operation it can perform is a named
subcommand with validated arguments. It is installed root-owned and granted
NOPASSWD for exactly that one path:

    sudo install -m 0755 -o root -g root bin/hwdbg /usr/local/sbin/hwdbg
    sed "s/@USER@/$USER/" templates/sudoers.in > /tmp/hwdbg.sudoers
    sudo install -m 0440 -o root -g root /tmp/hwdbg.sudoers /etc/sudoers.d/hwdbg
    sudo visudo -c -f /etc/sudoers.d/hwdbg      # validate before relying on it

Then the device-specific scope:

    cp templates/hwdbg.conf.example myproject/hwdbg.conf
    # edit: module names, i2c bus/address, debugfs paths, PCI slot, ACPI_OUT
    sudo install -m 0644 -o root -g root myproject/hwdbg.conf /usr/local/etc/hwdbg.conf

## Why the config must be root-owned

This is the part that is easy to get wrong, and it is worth understanding
before copying the pattern into your own work.

`hwdbg`'s security claim is "it accepts no free-form input". But a
config-driven helper takes its module names, i2c addresses and PCI slots from
a file — so if that file were writable by the caller, the claim would be
hollow: the caller would be choosing what `modprobe` loads and which i2c
addresses get written, which is most of the way to arbitrary root.

So `hwdbg`:

- reads a **fixed** config path, `/usr/local/etc/hwdbg.conf`, which cannot be
  redirected by an environment variable or an argument
- refuses to run if that file is not owned by uid 0
- refuses to run if it is group- or world-writable
- validates every value it uses — module names against `[A-Za-z0-9_-]+`,
  addresses and PCI slots against their expected shapes — because root
  ownership protects against a malicious caller, not against your own typos

Keep the editable copy in your project directory and reinstall it after each
change. If the installed copy of either file is writable by you, the scoping
is decoration.

## What is deliberately missing

`insmod`/`modprobe` of an **arbitrary** module. Loading an unsigned module of
your choosing is equivalent to root, so wrapping it in a NOPASSWD helper would
hand back everything the scoping just bought. `hwdbg reload` cycles a
*configured* list of modules, which is what diagnosis actually needs. Loading
your own freshly built driver is a separate step, done with explicit sudo,
with your eyes open.
