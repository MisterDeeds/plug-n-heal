# PSScriptAnalyzer settings for Plug'n'Heal. Used by the CI job "lint" for src/, builder/ and tests/:
#
#   Invoke-ScriptAnalyzer -Path src -Recurse -Settings tests/PSScriptAnalyzerSettings.psd1
#
# Every diagnostic with severity Error or Warning fails the job. Information is not reported.
# Target runtime is Windows PowerShell 5.1 (64-bit) on Windows 10/11; the libraries must also run in PowerShell 7
# (docs/ARCHITECTURE.md, principle 8). The compatibility rules check both.
@{
    Severity     = @('Error', 'Warning')

    # All default rules run, except these. Each one is a deliberate project convention or a known false positive.
    ExcludeRules = @(
        # Function names are fixed by docs/ARCHITECTURE.md (Get-PnhPaths, Get-PnhActions, Get-PnhInstalledModels, ...).
        'PSUseSingularNouns',
        # Internal helpers, not user-facing cmdlets. Changes are confirmed by the toolbox's own -Confirm scriptblock
        # (docs/ARCHITECTURE.md 5.6), not by -WhatIf/-Confirm.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSupportsShouldProcess',
        # The builder's console mode (-NonInteractive) prints progress for people; the app writes only via Write-PnhLog.
        'PSAvoidUsingWriteHost',
        # Best-effort cleanup in the builder (killing curl, keep-awake, TLS switch) must never throw.
        # The CI job runs a second, strict pass over src/ that keeps this rule (see .github/workflows/ci.yml).
        'PSAvoidUsingEmptyCatchBlock',
        # False positives: script parameters read inside functions (builder), parameters of Pester mocks.
        'PSReviewUnusedParameter',
        # False positives with Pester 5: BeforeAll/BeforeDiscovery variables are used in It blocks, $global: state is
        # shared with mocks. The strict pass over src/ keeps both rules.
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSAvoidGlobalVars'
    )

    Rules        = @{
        # Syntax must parse in Windows PowerShell 5.1 and PowerShell 7 (no ternary, no ??, no && in scripts).
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        # Commands and parameters must exist on a stock Windows 10 in Windows PowerShell 5.1 and in PowerShell 7.
        # Profiles ship with PSScriptAnalyzer (folder compatibility_profiles).
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework', # Windows 10 Pro, Windows PowerShell 5.1
                'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core'                          # Windows 10, PowerShell 7.0
            )
            # Pester 5 is installed for the tests; the profiles only know the Pester 3.4 that ships with Windows.
            IgnoreCommands = @(
                'Describe', 'Context', 'It', 'Should', 'BeforeAll', 'AfterAll', 'BeforeEach', 'AfterEach',
                'BeforeDiscovery', 'Mock', 'InModuleScope', 'Set-ItResult', 'Assert-MockCalled', 'Assert-VerifiableMock',
                'Should-Invoke', 'New-MockObject', 'Invoke-Pester', 'New-PesterConfiguration', 'New-PesterContainer',
                'Export-JUnitReport', 'Export-NUnitReport', 'ConvertTo-JUnitReport', 'ConvertTo-NUnitReport'
            )
        }

        # PSUseCompatibleTypes is not enabled: it reports every WinForms type of src/Ui.ps1 and the WinRT bridge of
        # src/toolbox/helpers.ps1, which are loaded at run time with Add-Type and exist on every Windows 10/11.
    }
}
