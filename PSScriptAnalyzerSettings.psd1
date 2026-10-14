@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The scripts in probes/ are run by hand in a Windows VM, and their
        # coloured step-by-step console output IS the interface: it is how you
        # see which capability installed, which ACL was fixed, and what the
        # guest's address turned out to be. Nothing consumes their stdout as
        # objects, so Write-Output would be wrong here, not merely different.
        'PSAvoidUsingWriteHost'
    )
}
