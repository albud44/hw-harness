# common.sh - shared plumbing for every harness tool. Sourced, never executed.
#
# The central idea of this repo: the TOOL and the per-device STATE are
# separate things.
#
#   tool    = this clone. Read-only, one copy, shared by every investigation.
#   project = a directory holding harness.conf + etc/ + .run/ + captures/.
#             One per device under investigation.
#
# Nothing here may hardcode an absolute path: the tool root is derived from
# the script's own location, and the project root from $HARNESS_PROJECT or by
# walking up from $PWD looking for harness.conf. That is what lets a single
# clone serve a scanner investigation and a camera investigation at once.

# shellcheck shell=bash

# readlink -f so that a symlink into ~/.local/bin still resolves the clone.
HARNESS_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
export HARNESS_ROOT

# Derived from the sourcing script's own name, so no tool has to declare it.
PROG=$(basename "$0")

die()  { echo "$PROG: $*" >&2; exit 1; }
info() { echo "[$PROG] $*" >&2; }
warn() { echo "[$PROG] WARNING: $*" >&2; }

need() {
    local t missing=()
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    [ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]} (see 'harness doctor')"
}

# ------------------------------------------------------------ project root
# Explicit $HARNESS_PROJECT wins. Otherwise walk up from $PWD: this makes the
# tools work from anywhere inside a project tree, like git does.
find_project() {
    if [ -n "${HARNESS_PROJECT:-}" ]; then
        [ -d "$HARNESS_PROJECT" ] || die "HARNESS_PROJECT=$HARNESS_PROJECT does not exist"
        (cd "$HARNESS_PROJECT" && pwd); return
    fi
    local d; d=$(pwd)
    while [ "$d" != / ]; do
        [ -f "$d/harness.conf" ] && { echo "$d"; return; }
        d=$(dirname "$d")
    done
    die "no harness.conf found here or above; run 'harness init <dir>' first"
}

# ----------------------------------------------------------------- config
# Defaults first, then harness.conf overrides them, then the environment
# overrides that - so a one-off 'WINCTL_GEOMETRY=1280x720 winctl up' works
# without editing any file.
# shellcheck disable=SC2034  # these are consumed by the tools that source us
load_config() {
    PROJECT=$(find_project)
    export PROJECT

    # Anything already set in the environment outranks the config file, so a
    # one-off 'WINCTL_GEOMETRY=1280x720 winctl up' works without editing
    # anything. Captured here, re-applied after the file is sourced.
    local env_vm=${VM_NAME:-}   env_host=${VM_HOST:-}
    local env_disp=${WINCTL_DISPLAY:-} env_geom=${WINCTL_GEOMETRY:-}
    local env_key=${SSH_KEY:-}  env_backend=${VM_BACKEND:-}

    VM_BACKEND=libvirt
    VM_NAME=win11
    VM_HOST=
    VM_LIBVIRT_URI=qemu:///system
    USB_VID=
    USB_PID=
    WINCTL_DISPLAY=:99
    WINCTL_GEOMETRY=1920x1080
    RDP_DOMAIN_DEFAULT=MicrosoftAccount
    SSH_KEY=

    # The config is shell, which means it is code. It lives in the user's own
    # project directory and is exactly as trusted as the shell that invoked us.
    # shellcheck source=/dev/null
    . "$PROJECT/harness.conf"

    [ -n "$env_vm" ]   && VM_NAME=$env_vm
    [ -n "$env_host" ] && VM_HOST=$env_host
    [ -n "$env_disp" ] && WINCTL_DISPLAY=$env_disp
    [ -n "$env_geom" ] && WINCTL_GEOMETRY=$env_geom
    [ -n "$env_key" ]  && SSH_KEY=$env_key
    [ -n "$env_backend" ] && VM_BACKEND=$env_backend

    case "$VM_BACKEND" in
      libvirt|virtualbox) ;;
      *) die "VM_BACKEND=$VM_BACKEND in $PROJECT/harness.conf: expected libvirt or virtualbox" ;;
    esac

    ETC="$PROJECT/etc"
    RUN="$PROJECT/.run"
    CAPTURES="$PROJECT/captures"
    [ -n "$SSH_KEY" ] || SSH_KEY="$ETC/id_vm"

    mkdir -p "$ETC" "$RUN" "$CAPTURES"
    chmod 700 "$ETC" "$RUN"
}

# -------------------------------------------------------------- guest host
# Resolving the guest address rather than hardcoding it: a VM that gets a new
# DHCP lease must not silently break every tool. The guest's own view is
# authoritative - qemu-ga under libvirt, the Guest Additions under VirtualBox.
# libvirt also falls back to the DHCP lease for a guest without the agent.
#
# Cached per session in .run/vm.host because 'winctl exec' is called in loops.
resolve_host() {
    [ -n "$VM_HOST" ] && { echo "$VM_HOST"; return; }

    local cache="$RUN/vm.host"
    if [ -f "$cache" ] && [ -s "$cache" ]; then
        # 10 minute TTL: long enough to cover a work session, short enough
        # that a reboot onto a new lease recovers on its own.
        if [ -z "$(find "$cache" -mmin +10 2>/dev/null)" ]; then
            cat "$cache"; return
        fi
    fi

    local ip=
    case "$VM_BACKEND" in
      libvirt)    ip=$(vm_ip_libvirt) ;;
      virtualbox) ip=$(vm_ip_virtualbox) ;;
    esac

    if [ -z "$ip" ]; then
        case "$VM_BACKEND" in
          libvirt) die "cannot resolve an address for VM '$VM_NAME'.
  Is it running ('virsh -c $VM_LIBVIRT_URI list')? Is qemu-ga installed in the
  guest (probes/win-bootstrap.ps1 installs it)? Otherwise pin VM_HOST= in
  harness.conf." ;;
          virtualbox) die "cannot resolve an address for VM '$VM_NAME'.
  Is it running ('VBoxManage list runningvms')? Does it have a host-only
  adapter, and are the Guest Additions running in the guest? See
  doc/vm-setup.md. Otherwise pin VM_HOST= in harness.conf." ;;
        esac
    fi

    printf '%s' "$ip" > "$cache"
    echo "$ip"
}

vm_ip_libvirt() {
    need virsh
    local ip=
    ip=$(virsh -c "$VM_LIBVIRT_URI" domifaddr "$VM_NAME" --source agent 2>/dev/null |
         awk '$3 == "ipv4" { split($4, a, "/"); print a[1]; exit }')
    [ -z "$ip" ] && ip=$(virsh -c "$VM_LIBVIRT_URI" domifaddr "$VM_NAME" --source lease 2>/dev/null |
         awk '$3 == "ipv4" { split($4, a, "/"); print a[1]; exit }')
    echo "$ip"
}

# Only a host-only adapter is reachable from the host: the NAT adapter's
# 10.0.2.x address is private to VirtualBox. The guest numbers its interfaces
# (GuestInfo/Net/<i>) in its own order, not by VirtualBox slot, so the
# host-only adapter is matched by MAC address rather than by index.
vm_ip_virtualbox() {
    need VBoxManage
    local mac i
    mac=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
          awk -F= '{ gsub(/"/, "", $2) }
                   $1 ~ /^macaddress[0-9]+$/ { mac[substr($1, 11)] = $2 }
                   $1 ~ /^nic[0-9]+$/ && $2 == "hostonly" && !n { n = substr($1, 4) }
                   END { if (n) print mac[n] }')
    [ -n "$mac" ] || return 0
    i=$(VBoxManage guestproperty enumerate "$VM_NAME" \
            --patterns '/VirtualBox/GuestInfo/Net/*/MAC' 2>/dev/null |
        awk -v mac="$mac" 'index(toupper($0), toupper(mac)) && match($0, /Net\/[0-9]+\//) {
                               print substr($0, RSTART + 4, RLENGTH - 5); exit }')
    [ -n "$i" ] || return 0
    VBoxManage guestproperty get "$VM_NAME" "/VirtualBox/GuestInfo/Net/$i/V4/IP" 2>/dev/null |
        awk '$1 == "Value:" { print $2 }'
}

# --------------------------------------------------------------- identities
# Two identities, because they are genuinely different principals:
#   SSH : the local Windows profile name, key auth, no password
#   RDP : often MicrosoftAccount\<email>, password auth
ssh_user()   { cat "$ETC/ssh.user" 2>/dev/null || die "run 'winctl auth' first"; }
rdp_user()   { cat "$ETC/rdp.user" 2>/dev/null || die "run 'winctl auth' first"; }
rdp_domain() { cat "$ETC/rdp.domain" 2>/dev/null || echo ''; }

# The RDP password lives in the login keyring, never on disk in the project.
# Keyed by VM name so several VMs can coexist.
secret_get() { secret-tool lookup service hw-harness vm "$VM_NAME" 2>/dev/null; }
secret_set() { secret-tool store --label="hw-harness RDP ($VM_NAME)" \
                                 service hw-harness vm "$VM_NAME"; }
