# dump-devices.ps1 - exhaustive device/driver/firmware dump for Linux enablement.
#
# Behavioural observation only: descriptors, properties, resources, ACPI tables
# and INF text. It deliberately does NOT disassemble or copy vendor .sys code -
# that would taint any resulting Linux driver and make it unupstreamable.
#
#   powershell -ExecutionPolicy Bypass -File dump-devices.ps1 [-Filter 'USB\VID_27C6*']
#
# Output: a timestamped folder, intended to be pulled with `winctl pull`.

param(
    [string]$Filter = '*',
    [string]$OutDir = "$env:USERPROFILE\probe-$(Get-Date -Format yyyyMMdd-HHmmss)"
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }

# ------------------------------------------------------- device inventory
Say 'Enumerating devices...'
$devs = Get-PnpDevice | Where-Object { $_.InstanceId -like $Filter }
$devs | Select-Object Status, Class, FriendlyName, InstanceId |
    Sort-Object Class, FriendlyName |
    Export-Csv "$OutDir\devices.csv" -NoTypeInformation
Say "  $($devs.Count) devices matched"

# Every property of every matched device. This is where hardware IDs,
# compatible IDs, bus numbers, location paths and driver bindings live -
# i.e. everything needed to match a device to a Linux driver ID table.
Say 'Dumping per-device properties...'
$all = foreach ($d in $devs) {
    foreach ($p in (Get-PnpDeviceProperty -InstanceId $d.InstanceId)) {
        [pscustomobject]@{
            InstanceId = $d.InstanceId
            Name       = $d.FriendlyName
            Key        = $p.KeyName
            Type       = $p.Type
            Value      = if ($p.Data -is [array]) { $p.Data -join '|' } else { $p.Data }
        }
    }
}
$all | Export-Csv "$OutDir\device-properties.csv" -NoTypeInformation

# -------------------------------------------------------------- registry
# The Enum tree holds the raw, authoritative view the kernel's PnP manager
# uses - often richer than the WMI surface.
Say 'Exporting registry Enum + Class trees...'
reg export 'HKLM\SYSTEM\CurrentControlSet\Enum'                "$OutDir\reg-enum.txt"  /y 2>$null | Out-Null
reg export 'HKLM\SYSTEM\CurrentControlSet\Control\Class'       "$OutDir\reg-class.txt" /y 2>$null | Out-Null
reg export 'HKLM\SYSTEM\CurrentControlSet\Services'            "$OutDir\reg-services.txt" /y 2>$null | Out-Null

# --------------------------------------------------------------- drivers
Say 'Inventorying drivers...'
pnputil /enum-drivers > "$OutDir\pnputil-drivers.txt" 2>&1
Get-CimInstance Win32_PnPSignedDriver |
    Select-Object DeviceName, DriverVersion, DriverDate, Manufacturer,
                  InfName, DeviceID, DriverProviderName |
    Export-Csv "$OutDir\signed-drivers.csv" -NoTypeInformation

# INF text for matched devices: declarative, human-readable, and the single
# best source for init sequences, quirk flags and device/driver bindings.
Say 'Collecting INF files...'
New-Item -ItemType Directory -Force -Path "$OutDir\inf" | Out-Null
$infs = $all | Where-Object { $_.Key -match 'DriverInfPath|InfPath' } |
        Select-Object -ExpandProperty Value -Unique
foreach ($i in $infs) {
    foreach ($root in @("$env:SystemRoot\INF", "$env:SystemRoot\System32\DriverStore\FileRepository")) {
        Get-ChildItem -Path $root -Filter $i -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName "$OutDir\inf\" -Force -ErrorAction SilentlyContinue }
    }
}

# ----------------------------------------------------------- usb topology
Say 'USB topology...'
# NB: Get-CimInstance returns CimInstance, so the legacy [wmi] cast fails here.
# Association endpoints already carry their key properties; look the rest up by DeviceID.
$byId = @{}
Get-CimInstance Win32_PnPEntity | ForEach-Object { $byId[$_.DeviceID] = $_ }
Get-CimInstance Win32_USBControllerDevice | ForEach-Object {
    $depId = $_.Dependent.DeviceID
    $e = $byId[$depId]
    [pscustomobject]@{
        Controller = $_.Antecedent.DeviceID
        DeviceID   = $depId
        Name       = $e.Name
        Service    = $e.Service
        Status     = $e.Status
    }
} | Export-Csv "$OutDir\usb-devices.csv" -NoTypeInformation

# --------------------------------------------------------- acpi / firmware
# Raw firmware tables. DSDT/SSDT describe platform devices and their GPIO /
# I2C / interrupt wiring - frequently the missing piece for laptop sensors,
# touchpads and fingerprint readers that are not plain USB.
Say 'Dumping ACPI firmware tables...'
New-Item -ItemType Directory -Force -Path "$OutDir\acpi" | Out-Null
Add-Type -Namespace Fw -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern uint EnumSystemFirmwareTables(uint sig, byte[] buf, uint size);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern uint GetSystemFirmwareTable(uint sig, uint id, byte[] buf, uint size);
'@
$ACPI = 0x41435049  # 'ACPI'
$n = [Fw.Native]::EnumSystemFirmwareTables($ACPI, $null, 0)
if ($n -gt 0) {
    $ids = New-Object byte[] $n
    [void][Fw.Native]::EnumSystemFirmwareTables($ACPI, $ids, $n)
    for ($i = 0; $i -lt $n; $i += 4) {
        $name = [Text.Encoding]::ASCII.GetString($ids, $i, 4)
        $id   = [BitConverter]::ToUInt32($ids, $i)
        $sz   = [Fw.Native]::GetSystemFirmwareTable($ACPI, $id, $null, 0)
        if ($sz -gt 0) {
            $buf = New-Object byte[] $sz
            [void][Fw.Native]::GetSystemFirmwareTable($ACPI, $id, $buf, $sz)
            $safe = ($name -replace '[^A-Za-z0-9]', '_')
            [IO.File]::WriteAllBytes("$OutDir\acpi\$safe.bin", $buf)
        }
    }
    Say "  $([int]($n/4)) ACPI tables written (decompile on Linux with: iasl -d *.bin)"
}

# ------------------------------------------------------------- event log
Say 'Driver-related event log entries...'
Get-WinEvent -FilterHashtable @{LogName='System'} -MaxEvents 3000 -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Kernel-PnP|UserPnp|DriverFrameworks' } |
    Select-Object TimeCreated, Id, ProviderName, Message |
    Export-Csv "$OutDir\pnp-events.csv" -NoTypeInformation

Say "Done -> $OutDir"
Write-Host "Pull with:  winctl pull '$OutDir' ./captures/" -ForegroundColor Green
