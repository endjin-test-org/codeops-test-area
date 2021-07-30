[CmdletBinding()]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ConfigDirectory = (Join-Path -Resolve (Split-Path -Parent $PSCommandPath) '../repos/test'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $BranchName = "dependjinbot/nuget",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    $PrTitle = "[DEPENDJINBOT] Bumping NuGet Package Dependencies",

    [switch] $WhatIf
)
$ErrorActionPreference = $ErrorAction ? $ErrorAction : "Stop"
$InformationPreference = $InformationAction ? $InformationAction : "Continue"

$here = Split-Path -Parent $PSCommandPath

# Install other module dependencies
$requiredModules = @(
    @{Name="Endjin.GitHubActions"; Version="1.0.3"}
    @{Name="Endjin.CodeOps"; Version="0.2.7-beta0004" }
)
$requiredModules | ForEach-Object {
    $name = $_.Name
    $version = $_.Version
    if ( !(Get-Module -ListAvailable $name | ? { $_.Version -eq ($version -split "-")[0] }) ) {
        $splat = @{
            Name=$name
            RequiredVersion=$version
            Scope="CurrentUser"
            Repository="PSGallery"
            Force=$true
            AllowPrerelease=$version.Contains("-")
        }
        Install-Module @splat
    }
    if (!(Get-Module $name)) {
        # Lookup the required version of the installed module to get the path to the module manifest
        Import-Module (Get-Module -ListAvailable $name | ? { $_.Version -eq ($version -split "-")[0] } | Select -ExpandProperty Path)
    }
}

#
# Helper functions
#
function _logError
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [Parameter(Mandatory=$true)]
        [string] $Message,

        [switch] $IsTerminating
    )

    switch($IsTerminating)
    {
        $true { $errorAction = "Stop" }
        $false { $errorAction = "Continue" }
    }

    # GitHub Actions-formatted error logging
    Log-Error -Message $Message `
                -FileName $ErrorRecord.InvocationInfo.ScriptName `
                -Line $ErrorRecord.InvocationInfo.ScriptLineNumber `
                -Column $ErrorRecord.InvocationInfo.OffsetInLine

    Write-Information $ErrorRecord.InvocationInfo.PositionMessage -InformationAction:Continue
    Write-Information $ErrorRecord.ScriptStackTrace -InformationAction:Continue
    Write-Error $Message -ErrorAction $errorAction
}


#
# This function implements the logic that executes the dotnet-updated tool
#
function _repoChanges {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string] $SolutionsDir,

        [Parameter(Mandatory=$true)]
        [bool] $CheckOnly,

        [Parameter(Mandatory=$true)]
        [ValidateSet("Major","Minor","None")]
        [string] $VersionLock,

        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [string[]] $Exclusions,

        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        [string[]] $Inclusions,

        [Parameter(Mandatory=$true)]
        [string] $OutputFile
    )

    Write-Information "`n`nRunning dotnet-outdated global tool..."

    # Ensure we can handle being passed a relative or absolute path
    $solutionsPath = (Resolve-Path ([IO.Path]::Combine($PWD, $SolutionsDir))).Path

    $outdatedParams = @(
        "--version-lock $VersionLock"
        "--output `"$OutputFile`""
        "--output-format json"
        "--fail-on-updates"
        $Exclusions | Where-Object { $_ } | ForEach-Object { "--exclude `"$_`"" }
        $Inclusions | Where-Object { $_ } | ForEach-Object { "--include `"$_`"" }
    )

    if (!$CheckOnly) {
        $outdatedParams += @( "--upgrade" )
    }
    
    Write-Information "PWD: $(Get-Location)"
    
    $cmd = Get-Command "dotnet-outdated"
    Write-Verbose "cmdline: $($cmd.Path) $($outdatedParams -join ' ') $solutionsPath"
    & $cmd.Path @outdatedParams $solutionsPath | Write-Information

    if ($LASTEXITCODE -ne 0) {
        # At least one package dependency was updated
        return $true
    }
    else {
        return $false
    }
}

function _main
{
    $runResults = [ordered]@{}
    $runMetadata = [ordered]@{ 
        start_time = [datetime]::UtcNow
        is_dry_run = [bool]$WhatIf
        success = $true
        repos_analysed = 0
        repos_updated = 0
    }

    $repos = [array](Get-AllRepoConfiguration -ConfigDirectory $ConfigDirectory -LocalMode | Where-Object { $_ })

    $results = [ordered]@{}
    foreach ($repo in $repos) {
        try {
            $orgName = $repo.org

            # Tries to generate an AppInstallationAccessToken for the current Org when running
            # as a GitHub App and the SSH_PRIVATE_KEY and GITHUB_APP_ID environment variables
            # have been set.  Otherwise interactive authentication will be attempted on-demand.
            Connect-GitHubOrg -OrgName $orgName

            if (!$repo.ContainsKey("nugetDependencyUpdates") -or `
                    !$repo.nugetDependencyUpdates.ContainsKey("enabled") -or `
                    $repo.nugetDependencyUpdates.enabled -ne $true `
            ) {
                # skip the org/repo as this feature is not enabled
                continue
            }

            # Setup the arguments we will pass to the main processing script by extracting them
            # from the configuration for the current set of repos
            $solutionsDir = $repo.nugetDependencyUpdates.solutionsDir ? $repo.nugetDependencyUpdates.solutionsDir : "."
            [bool]$checkOnly = $repo.nugetDependencyUpdates.checkOnly ? $repo.nugetDependencyUpdates.checkOnly : $false
            $versionLock = $repo.nugetDependencyUpdates.versionLock ? $repo.nugetDependencyUpdates.versionLock : "Minor"
            $exclusions = $repo.nugetDependencyUpdates.exclusions ? $repo.nugetDependencyUpdates.exclusions : @()
            $inclusions = $repo.nugetDependencyUpdates.inclusions ? $repo.nugetDependencyUpdates.inclusions : @()

            # Process repos
            $failedRepos = @()
            foreach ($repoName in $repo.name) {
                $outputFile = New-TemporaryFile
                try {
                    Write-Information "`n************`n** Processing $orgName/$repoName ($($repo.description))`n************`n"
                    $prUri = Update-Repo `
                                -OrgName $orgName `
                                -RepoName $repoName `
                                -BranchName $BranchName `
                                -RepoChanges (Get-ChildItem function:\_repoChanges).ScriptBlock `
                                -RepoChangesArguments @($solutionsDir, $checkOnly, $versionLock, $exclusions, $inclusions, $outputFile) `
                                -CommitMessage "Updated NuGet package dependencies" `
                                -PrTitle $PrTitle `
                                -PrBody "Updates package dependencies for solutions in ``$solutionsDir``" `
                                -PrLabels @() `
                                -PassThruPullRequestUri `
                                -WhatIf:$WhatIf `
                                -Verbose

                    # Extract the JSON output from dotnet-outdated
                    $output = Get-Content -Raw $outputFile | ConvertFrom-Json -Depth 100 -AsHashtable

                    # Setup an entry for the repo if this is the first time we've processed it
                    # The configuration allows for repositories to be analysed multiple times
                    # using different criteria (e.g. to diffeentiate between internal vs external
                    # dependencies)
                    if ($null -ne $output -and ![string]::IsNullOrEmpty($prUri)) {
                        if ("$orgName/$repoName" -notin $results.Keys) {
                            $results += @{
                                "$orgName/$repoName" = @{
                                    reports = @()
                                    pull_request = $null
                                }
                            }
                        }
                        # Store the dotnet-outdated analysis report and the PR associated with any changes
                        $results["$orgName/$repoName"].reports += @{ 
                            description = $repo.description
                            report = $output
                        }
                        $results["$orgName/$repoName"].pull_request = $prUri
                    }
                    elseif ( ($null -eq $output -and ![string]::IsNullOrEmpty($prUri)) `
                                -or ($null -ne $output -and [string]::IsNullOrEmpty($prUri))
                    ) {
                        throw "What happened here???"
                    }
                    else {
                        Write-Information "No changes, no report"
                    }

                    # Update the counters in the runMetadata
                    $runMetadata.repos_analysed++
                    if ( !([string]::IsNullOrEmpty($prUri)) ) {
                        # Treat the presence of a PR as a signal that repo was updated
                        $runMetadata.repos_updated++
                    }
                }
                # Log any exceptions for the current repo, then continue on to the next
                catch {
                    $failedRepos += "$orgName/$repoName"
                    $runMetadata.success = $false
                    _logError -Message "Error processing '$orgName/$repoName' - $($_.Exception.Message)" `
                              -ErrorRecord $_
                    # set the error property on the result object
                    $results += @{ "$orgName/$repoName" = @{ error = $_.Exception.Message } }
                }
                finally {
                    Remove-Item $outputFile
                }
            }
        }
        # Log any exceptions in the outer loop, then continue processing
        catch {
            $runMetadata.success = $false
            _logError -Message $_.Exception.Message `
                      -ErrorRecord $_
        }
    }

    $runMetadata += @{ end_time = [datetime]::UtcNow }
    $runResults += @{ metadata = $runMetadata }
    $runResults += @{ repos = $results }

    # Produce a JSON report file
    $reportFile = "update-nuget-package-dependencies.json"
    $runResults | ConvertTo-Json -Depth 100 | Out-File $reportFile -Force

    # Upload JSON report to datalake
    Publish-CodeOpsResultsToBlobStorage -StorageAccountName $env:DATALAKE_NAME `
                                        -ContainerName $env:DATALAKE_FILESYSTEM `
                                        -BlobPath "$($env:DATALAKE_DIRECTORY)/nuget_package_dependencies/raw" `
                                        -SasToken $env:DATALAKE_SASTOKEN `
                                        -JsonFilePath $reportFile `
                                        -Timestamp $runMetadata.start_time.ToString('yyyyMMddHHmmssfff') `
                                        -WhatIf:$WhatIf

    if ($runMetadata.success) {
        return 0
    }
    else {
        return 1
    }
}

# Detect when dot sourcing the script, so we don't immediately execute anything when running Pester
if (!$MyInvocation.Line.StartsWith('. ')) {

    $statusCode = _main
    exit $statusCode
}