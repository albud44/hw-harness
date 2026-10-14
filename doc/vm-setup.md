# The Windows reference VM

You need a Windows VM that runs the vendor driver and can be handed the real
hardware. Any working Windows 11 guest under libvirt will do; this is what the
harness expects and why.

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
