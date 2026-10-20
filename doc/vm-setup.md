# The Windows reference VM

You need a Windows VM that runs the vendor driver and can be handed the real
hardware. Any working Windows 11 guest under libvirt will do; this is what the
harness expects and why. For a VirtualBox guest, the requirements are the
same and the specifics are in [VirtualBox](#virtualbox) below.

## Requirements

**Windows Pro, not Home.** The built-in RDP *server* is absent on Home. SSH
still works, and SSH is what most of the work uses, so a Home guest is usable
— but `winctl up/shot/click` will not be, and some vendor tools can only be
driven through their GUI.

**A USB controller the guest can enumerate properly.** `qemu-xhci` with enough
ports. Passthrough of a device that renumbers itself mid-operation (many
scanners and cameras do) fails on older controller models.

**The QEMU guest agent.** Not strictly required, but without it you must pin
`VM_HOST=` in `harness.conf` and keep it correct by hand. `win-bootstrap.ps1`
installs it from the virtio-win CD.

A minimal domain, as created by virt-manager, with these worth checking:

    <os firmware='efi'>          UEFI; Windows 11 wants secure boot available
      <feature enabled='yes' name='secure-boot'/>
    <features><smm state='on'/>  required for the secboot OVMF build
    <tpm model='tpm-crb'>        Windows 11 setup requires a TPM 2.0
      <backend type='emulator' version='2.0'/>
    <cpu mode='host-passthrough'>
    <controller type='usb' index='0' model='qemu-xhci' ports='15'>
    <interface type='network'>   virtio on the default NAT network is fine;
      <model type='virtio'/>     the host reaches the guest at its 192.168.122.x lease

Give it 4 vCPUs and 8GB if you can spare them. Vendor scanner and camera
software is not light, and a guest that swaps while you are timing a USB
operation will mislead you.

## Installation notes

1. Attach both the Windows installer ISO and **virtio-win.iso** before first
   boot. The installer will not see a virtio disk until you load the driver
   from that CD ("Load driver" → `vioscsi` or `viostor` for your disk model).
2. Install virtio-win guest tools after first boot; it wants a reboot.
3. Create a local account if you can. A Microsoft account works but splits
   your identity in two: SSH authenticates as the *local profile name*, while
   RDP authenticates as `MicrosoftAccount\your@email`. `winctl auth` asks for
   both separately for exactly this reason.

## Licensing an OEM guest

If the physical machine came with an OEM Windows licence, that licence lives
in the firmware's ACPI **MSDM** table. You can present the same table to the
guest, and Windows will activate against it:

    sudo cp /sys/firmware/acpi/tables/MSDM ~/VirtualMachines/msdm.bin
    sudo chmod 444 ~/VirtualMachines/msdm.bin

Then in the domain XML (note the `xmlns:qemu` attribute on `<domain>`):

    <domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
      ...
      <qemu:commandline>
        <qemu:arg value='-acpitable'/>
        <qemu:arg value='file=/home/YOU/VirtualMachines/msdm.bin'/>
      </qemu:commandline>
    </domain>

That file contains your product key — keep it out of any repository, and note
that `<qemu:commandline>` makes the domain unsupported by some management
tools. Whether running the OEM licence in a VM on the same physical machine
fits your licence terms is your call to make, not this document's.

## Bootstrapping the guest side

From the project directory on Linux:

    winctl auth       # generates the SSH keypair, stores the RDP password
    harness iso       # builds bootstrap.iso carrying the PUBLIC key only

Attach `bootstrap.iso` to the VM, and inside the guest, in an **elevated**
PowerShell:

    powershell -ExecutionPolicy Bypass -File D:\win-bootstrap.ps1

It installs OpenSSH Server, sets PowerShell as the default SSH shell, installs
the public key, enables RDP with NLA, and installs the guest agent. Then back
on Linux, `winctl status` should report `ssh: ok`.

### The one thing that always goes wrong

For accounts in the **Administrators** group, Windows OpenSSH ignores
`~/.ssh/authorized_keys` entirely and reads
`C:\ProgramData\ssh\administrators_authorized_keys` instead — and silently
refuses it unless its ACL grants only SYSTEM and Administrators. This is the
single most common cause of "key auth just doesn't work" on Windows.
`win-bootstrap.ps1` writes that file and fixes the ACL with `icacls`. If you
set it up by hand, do both.

## Why off-screen RDP rather than a VM window

`winctl up` starts a private `Xvfb` display and connects `xfreerdp` to it.
That buys two things:

- **Synthetic input is contained.** `winctl type`/`click` drive that display's
  own input devices. They cannot reach your real keyboard and mouse, so an
  automated GUI sequence cannot run away with your desktop.
- **It keeps rendering while unobserved.** The obvious alternative —
  a real window captured through the portal/PipeWire — does not work: GNOME
  stops producing frames for unmapped windows, so an "off-screen" window
  yields black frames. A separate X server is genuinely off-screen and keeps
  drawing.

Prefer `winctl exec` (SSH) over GUI automation whenever there is a scriptable
equivalent. Use the GUI only for things that have none — which, for vendor
scanner and camera software, is most of the interesting parts.

## Handing over the hardware

    hostdev to-vm      # guest owns the device; the host no longer sees it
    hostdev to-host    # back to Linux
    hostdev status     # who has it

`managed='yes'` in the generated snippet makes libvirt unbind the host driver
on attach and rebind it on detach, so no manual unbinding is needed. The host
can still trace the device through `usbmon` the whole time it belongs to the
guest — that is the point.

## VirtualBox

Set `VM_BACKEND=virtualbox` and `VM_NAME=<the VM's name in VBoxManage list vms>`
in `harness.conf`. `harness doctor` checks the points below on the VM itself.

**A host-only adapter.** The default NAT adapter gives the guest a 10.0.2.x
address that only VirtualBox can reach. Keep it for internet access and add a
second adapter on a host-only network:

    VBoxManage hostonlyif create          # -> vboxnet0, host side 192.168.56.1
    VBoxManage dhcpserver add --interface=vboxnet0 --server-ip=192.168.56.100 \
        --netmask=255.255.255.0 --lower-ip=192.168.56.101 \
        --upper-ip=192.168.56.254 --enable
    VBoxManage modifyvm <vm> --nic2 hostonly --hostonlyadapter2 vboxnet0   # VM off

The Linux host only allows host-only addresses in 192.168.56.0/21 unless
`/etc/vbox/networks.conf` says otherwise.

**The Guest Additions**, in place of qemu-ga. They publish the guest's
addresses as guest properties, and the harness picks the one on the host-only
adapter by its MAC address: the guest numbers its interfaces in its own order,
which is not VirtualBox's slot order. Without them, pin `VM_HOST=`. The
`virtualbox-guest-iso` package provides the CD (Devices -> Insert Guest
Additions CD image).

**No catch-all USB filter.** An active filter with every field empty grabs
*every* USB device plugged in while the VM runs - the device under study
included, behind `hostdev`'s back. Deactivate it:

    VBoxManage usbfilter modify <index> --target <vm> --active no

**A USB controller.** Prefer xHCI (`VBoxManage modifyvm <vm> --usbxhci on`,
VM off), for the same reason as `qemu-xhci` above; EHCI is enough for a USB
2.0 device.

**Windows 11 itself**: EFI, Secure Boot and TPM 2.0 are all native settings
in VirtualBox 7 (`--firmware efi --tpm-type 2.0`), with no extra package.

**Re-running the bootstrap after rebuilding the ISO.** Swapping the medium
with `storageattach` on a running VM is not enough: Windows can keep serving
the previous disc's files from D: (observed 2026-10-20, Windows 11 LTSC).
Once SSH works, skip the disc - `winctl run` stages the script over SSH, and
the SSH session of an administrator is already elevated:

    winctl push <clone>/probes/win-bootstrap.ps1 C:/Users/<you>/wb.ps1
    winctl push etc/id_vm.pub C:/Users/<you>/harness.pub
    winctl exec 'powershell -ExecutionPolicy Bypass -File C:\Users\<you>\wb.ps1 -KeyFile C:\Users\<you>\harness.pub'

### Passthrough

`hostdev to-vm` installs a VM filter named `hw-harness VID:PID` and attaches
the device already present; `hostdev to-host` removes the filter, then
detaches. The filter is the important half. `usbattach` takes one device by
UUID, and a device that renumbers itself mid-operation (firmware upload, mode
switch) comes back as a new one, which would land on the host halfway through
the session. The filter catches every re-enumeration, like libvirt's
vendor/product match. `hostdev persist` installs the filter alone.

`usbmon` sees a VirtualBox guest's traffic just as it sees QEMU's: on Linux,
VirtualBox replays the guest's URBs through usbfs on the host, so they cross
the host USB core like any other. Observed 2026-10-20 with VirtualBox 7.2.16:
a Windows 11 guest exchanging interrupt reports with an HP Prime G2 (03f0:2441)
produced about 4,400 URBs and 5 MB in 18 seconds, all captured by `usbcap`.
VirtualBox also resets the device on capture and again on release; the kernel
logs both (`reset high-speed USB device`), which makes the log the quickest
way to see when the device actually changed hands.

### Coexisting with KVM

On Manjaro, kernel 6.18 with VirtualBox 7.2.16, a VirtualBox guest ran fine
with `kvm_intel` loaded (observed 2026-10-20). If a VM refuses to start with
`VERR_VMX_IN_VMX_ROOT_MODE`, something else holds VT-x: unload `kvm_intel` or
boot with `kvm.enable_virt_at_load=0`.

### OEM licence

The MSDM table from [Licensing an OEM guest](#licensing-an-oem-guest) goes in
through extra data instead of a QEMU argument:

    VBoxManage setextradata <vm> "VBoxInternal/Devices/acpi/0/Config/CustomTable" \
        /home/YOU/VirtualMachines/msdm.bin
