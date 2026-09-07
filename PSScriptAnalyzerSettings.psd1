@{
    # Errors and warnings fail CI. Information-level rules (positional
    # parameters in the test matrices, for example) are reported nowhere.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # install.ps1 and the tests are console scripts; Write-Host is the point.
        'PSAvoidUsingWriteHost',
        # The hooks swallow errors on purpose: a broken hook must not brick a
        # session, and logging is best effort. Every empty catch has a comment
        # saying why.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
