#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
    .NAME
    AzLogDcrIngestPSLogHub

    .SYNOPSIS
    Normally, REST API endpoints sends directly to Azure Pipeline via DCEs/DCRs/Log Ingestion API
    If you have endpoints for example servers which are not connected to the internet - or
    they are not secured with TLS 1.2, then you can't send the data.
    
    AzLogDcrIngestPSLogHub acts as an intermediate to handle this flow.
    Server sends JSON-file to specific UNC-path (LogHubPath).
    
    On the Log-hub server, there is a job (this script), which is scanning the LogHubPath for new files (every 10 sec)
    It will process the files and send it to the correct DCE – with DCR information – and if succesfully, delete the file.
  
    .AUTHOR
    Morten Knudsen, Microsoft MVP - https://mortenknudsen.net

    .LICENSE
    Licensed under the MIT license

    .PROJECTURI
    https://github.com/KnudsenMorten/AzLogDcrIngestPSLogHub

    .EXAMPLE

    .WARRANTY
    Use at your own risk, no warranty given!
#>

param(
      [parameter(Mandatory=$false)]
          [ValidateSet("Download","LocalPath","DevMode","PsGallery")]
          [string]$Function = "PsGallery",        # it will default to download if not specified
      [parameter(Mandatory=$false)]
          [ValidateSet("CurrentUser","AllUsers")]
          [string]$Scope = "AllUsers"        # it will default to download if not specified
     )


$LogFile = [System.Environment]::GetEnvironmentVariable('TEMP','Machine') + "\AzLogDcrIngestPSLogHub.txt"
Try
    {
        Stop-Transcript   # if running
        Start-Transcript -Path $LogFile -IncludeInvocationHeader
    }
Catch
    {
    }


Write-Output ""
Write-Output "AzLogDcrIngestPSLogHub | Upload of logdata for no-internet support & legacy support"
Write-Output "Developed by Morten Knudsen, Microsoft MVP"
Write-Output ""
  
##########################################
# VARIABLES
##########################################

<# ----- onboarding lines ----- BEGIN #>

    $TenantId                                   = "" 
    $LogIngestAppId                             = "" 
    $LogIngestAppSecret                         = "" 

    $DceName                                    = "" 
    $LogAnalyticsWorkspaceResourceId            = "" 
    $AzDcrResourceGroup                         = ""
    $AzDcrPrefix                                = "" 
    $AzDcrSetLogIngestApiAppPermissionsDcrLevel = $false
    $AzDcrLogIngestServicePrincipalObjectId     = "" 
    $AzLogDcrTableCreateFromReferenceMachine    = @()
    $AzLogDcrTableCreateFromAnyMachine          = $false

    $LogHubUploadPath                           = "\\<servername>\logupload$\INBOUND"
    $LogHubPsModulePath                         = "\\<servername>\logupload$\MODULES"


<#  ----- onboading lines -----  END  #>

    # script run mode - normal or verbose
    If ($psBoundParameters['verbose'] -eq $true)
        {
            Write-Output "Verbose mode ON"
            $global:Verbose = $true
            $VerbosePreference = "Continue"  # Stop, Inquire, Continue, SilentlyContinue
        }
    Else
        {
            $global:Verbose = $false
            $VerbosePreference = "SilentlyContinue"  # Stop, Inquire, Continue, SilentlyContinue
        }


############################################################################################################################################
# FUNCTIONS
############################################################################################################################################

    # directory where the script was started
    $ScriptDirectory = $PSScriptRoot

    switch ($Function)
        {   
            "Download"            # Typically used in Microsoft Intune environments
                {
                    # force download using Github. This is needed for Intune remediations, since the functions library are large, and Intune only support 200 Kb at the moment
                    Write-Output "Downloading latest version of module AzLogDcrIngestPS from https://github.com/KnudsenMorten/AzLogDcrIngestPS"
                    Write-Output "into local path $($ScriptDirectory)"

                    # delete existing file if found to download newest version
                    If (Test-Path "$($ScriptDirectory)\AzLogDcrIngestPS.psm1")
                        {
                            Remove-Item -Path "$($ScriptDirectory)\AzLogDcrIngestPS.psm1"
                        }

                     # download newest version
                    $Download = (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/KnudsenMorten/AzLogDcrIngestPS/main/AzLogDcrIngestPS.psm1", "$($ScriptDirectory)\AzLogDcrIngestPS.psm1")
                    
                    Start-Sleep -s 3
                    
                    # load file if found - otherwise terminate
                    If (Test-Path "$($ScriptDirectory)\AzLogDcrIngestPS.psm1")
                        {
                            Import-module "$($ScriptDirectory)\AzLogDcrIngestPS.psm1" -Global -force -DisableNameChecking  -WarningAction SilentlyContinue
                        }
                    Else
                        {
                            Write-Output "Powershell module AzLogDcrIngestPS was NOT found .... terminating !"
                            break
                        }
                }

            "PsGallery"   # Can be used on any machine, where you want to install the PS module for continuesly usage
                {
                    $ModuleCheck = Get-Module -Name AzLogDcrIngestPS -ListAvailable -ErrorAction SilentlyContinue
                        If (!($ModuleCheck))
                            {
                                Write-Output "Powershell module was not found !"
                                Write-Output "Installing in scope $Scope .... Please Wait !"
                                Try
                                    {
                                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                                        Write-Output ""
                                        Write-Output "Checking Powershell PackageProvider NuGet ... Please Wait !"
                                            if (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) 
                                                {
                                                    Write-Host "  OK - PackageProvider NuGet is installed"
                                                } 
                                            else 
                                                {
                                                    try {
                                                        Install-PackageProvider -Name NuGet -Scope $Scope -Confirm:$false -Force
                                                    }
                                                    catch [Exception] {
                                                        $_.message 
                                                        exit
                                                    }
                                                }

                                        Install-module -Name AzLogDcrIngestPS -Repository PSGallery -Force -Scope $Scope
                                        import-module -Name AzLogDcrIngestPS -Global -force -DisableNameChecking  -WarningAction SilentlyContinue
                                    }
                                Catch
                                    {
                                    }
                            }

                        Elseif ($ModuleCheck)
                            {
                                # sort to get highest version, if more versions are installed
                                $ModuleCheck = Sort-Object -Descending -Property Version -InputObject $ModuleCheck
                                $ModuleCheck = $ModuleCheck[0]

                                Write-Output "Checking latest version at PsGallery for AzLogDcrIngestPS module"
                                $online = Find-Module -Name AzLogDcrIngestPS -Repository PSGallery

                                #compare versions
                                if ( ([version]$online.version) -gt ([version]$ModuleCheck.version) ) 
                                    {
                                        Write-Output "Newer version ($($online.version)) detected"
                                        Write-Output "Updating AzLogDcrIngestPS module .... Please Wait !"
                                        Update-module -Name AzLogDcrIngestPS -Force
                                        import-module -Name AzLogDcrIngestPS -Global -force -DisableNameChecking  -WarningAction SilentlyContinue
                                    }
                                else
                                    {
                                        # No new version detected ... continuing !
                                        Write-Output "OK - Running latest version"
                                        $UpdateAvailable = $False
                                    }
                            }
                }
            "LocalPath"        # Typucaly used in ConfigMgr environment (or similar) where you run the script locally
                {
                    If (Test-Path "$($ScriptDirectory)\AzLogDcrIngestPS.psm1")
                        {
                            Write-Output "Using AzLogDcrIngestPS module from local path $($ScriptDirectory)"
                            Import-module "$($ScriptDirectory)\AzLogDcrIngestPS.psm1" -Global -force -DisableNameChecking  -WarningAction SilentlyContinue
                        }
                    Else
                        {
                            Write-Output "Required Powershell function was NOT found .... terminating !"
                            Exit
                        }
                }

            # Used by Morten Knudsen for development
            "DevMode"
                {
                    If (Test-Path "$Env:OneDrive\Documents\GitHub\AzLogDcrIngestPS-Dev\AzLogDcrIngestPS.psm1")
                        {
                            Import-module "$Env:OneDrive\Documents\GitHub\AzLogDcrIngestPS-Dev\AzLogDcrIngestPS.psm1" -Global -force -DisableNameChecking  -WarningAction SilentlyContinue
                        }
                    Else
                        {
                            Write-Output "Required Powershell function was NOT found .... terminating !"
                            break
                        }
                }
        }


############################################################################################################################################
# POWERSHELL CHECK
############################################################################################################################################

    #-------------------------------------------------------------------------------------------------------------
    # Initial Powershell module check
    #-------------------------------------------------------------------------------------------------------------

        Try
            {
                Import-Module -Name PSWindowsUpdate
            }
        Catch
            {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                Write-Output ""
                Write-Output "Checking Powershell PackageProvider NuGet ... Please Wait !"
                    if (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) 
                        {
                            Write-Host "  OK - PackageProvider NuGet is installed"
                        } 
                    else 
                        {
                            try {
                                Install-PackageProvider -Name NuGet -Scope AllUsers -Confirm:$false -Force
                            }
                            catch [Exception] {
                                $_.message 
                                exit
                            }
                        }

                Write-Output ""
                Write-Output "Checking Powershell Module PSWindowsUpdate ... Please Wait !"
                    if (Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) 
                        {
                            Write-output "  OK - Powershell Modue PSWindowsUpdate is installed"
                        } 
                    else 
                        {
                            try {
                                Write-Output "  Installing Powershell Module PSWindowsUpdate .... Please Wait !"
                                Install-Module -Name PSWindowsUpdate -AllowClobber -Scope AllUsers -Confirm:$False -Force
                                Import-Module -Name PSWindowsUpdate
                            }
                            catch [Exception] {
                                $_.message 
                                exit
                            }
                        }
            }


###############################################################
# MAIN PROGRAM
###############################################################

    # verbose
        $verbose = $false

    # We force script to use existing structure and NOT trying to adjust. Sometimes data structure can be garbage !!
        $AzLogDcrTableCreateFromReferenceMachine    = @()
        $AzLogDcrTableCreateFromAnyMachine          = $false

    # create folders
        MD $LogHubPsModulePath -Force | Out-Null -ErrorAction SilentlyContinue
        MD $LogHubUploadPath -Force | Out-Null -ErrorAction SilentlyContinue

    # force download of PsModule using Github. This is needed for Intune remediations, since the functions library are large, and Intune only support 200 Kb at the moment
        Write-Output ""
        Write-Output "Downloading latest version of module AzLogDcrIngestPS from https://github.com/KnudsenMorten/AzLogDcrIngestPS"
        Write-Output "into local path $($LogHubPsModulePath)"
        Write-Output ""
        Write-Output "This module will be used from legacy servers with PS version < 5.1"
        Write-Output ""

        # delete existing file if found to download newest version
        If (Test-Path "$($LogHubPsModulePath)\AzLogDcrIngestPS.psm1")
            {
                Remove-Item -Path "$($LogHubPsModulePath)\AzLogDcrIngestPS.psm1"
            }

        Start-Sleep -Seconds 2

        # download newest version
        $Download = (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/KnudsenMorten/AzLogDcrIngestPS/main/AzLogDcrIngestPS.psm1", "$($LogHubPsModulePath)\AzLogDcrIngestPS.psm1")
                    
    # building DCR/DCE details
        # building global variable with all DCEs, which can be viewed by Log Ingestion app
        $global:AzDceDetails = Get-AzDceListAll -AzAppId $LogIngestAppId -AzAppSecret $LogIngestAppSecret -TenantId $TenantId -Verbose:$Verbose
    
        # building global variable with all DCRs, which can be viewed by Log Ingestion app
        $global:AzDcrDetails = Get-AzDcrListAll -AzAppId $LogIngestAppId -AzAppSecret $LogIngestAppSecret -TenantId $TenantId -Verbose:$Verbose

    Write-output ""
    Write-output "#########################################################################################"
    Write-output "Processing files in loghub path $($LogHubUploadPath)"
    Write-output ""

    # Loop through all files
    Do
        {
            $InBoundFiles = Get-Childitem -Path "$($LogHubUploadPath)\*.json" -Recurse

            $DataCount  = ($InBoundFiles | Measure-Object).Count

            $InBoundFiles | ForEach-Object -Begin  {
                    $i = 0
            } -Process {

                        Write-Output ""
                        Write-Output "Processing $($_.Name)"
                        $LogHubDataJson = Get-Content -Path $_.Fullname | ConvertFrom-Json

                        $DceName                  = $LogHubDataJson.DceName
                        $DcrName                  = $LogHubDataJson.DcrName
                        $TableName                = $LogHubDataJson.TableName
                        $Data                     = $LogHubDataJson.Data
                        $AzAppId                  = $LogIngestAppId
                        $AzAppSecret              = $LogIngestAppSecret
                        $TenantId                 = $TenantId
                        $AzLogWorkspaceResourceId = $LogAnalyticsWorkspaceResourceId

                        # Checking if required values exist, otherwise deleting file
                        If ( ($DceName) -and ($DcrName) -and ($TableName) -and ($Data) -and ($AzLogWorkspaceResourceId) )
                            {

                                #-----------------------------------------------------------------------------------------------
                                # Check if table and DCR exist - or schema must be updated due to source object schema changes
                                #-----------------------------------------------------------------------------------------------
                    
                                    # Get insight about the schema structure
                                    $Schema = Get-ObjectSchemaAsArray -Data $Data
                                    $StructureCheck = Get-AzLogAnalyticsTableAzDataCollectionRuleStatus -AzLogWorkspaceResourceId $AzLogWorkspaceResourceId -TableName $TableName -DcrName $DcrName -SchemaSourceObject $Schema `
                                                                                                        -AzAppId $AzAppId -AzAppSecret $AzAppSecret -TenantId $TenantId -Verbose:$Verbose

                                #-----------------------------------------------------------------------------------------------
                                # Structure check = $true -> Create/update table & DCR with necessary schema
                                #-----------------------------------------------------------------------------------------------

                                    If ($StructureCheck -eq $true)
                                        {
                                            If ( ( $env:COMPUTERNAME -in $AzLogDcrTableCreateFromReferenceMachine) -or ($AzLogDcrTableCreateFromAnyMachine -eq $true) )    # manage table creations
                                                {
                                    
                                                    # build schema to be used for LogAnalytics Table
                                                    $Schema = Get-ObjectSchemaAsHash -Data $Data -ReturnType Table -Verbose:$Verbose

                                                    CreateUpdate-AzLogAnalyticsCustomLogTableDcr -AzLogWorkspaceResourceId $AzLogWorkspaceResourceId -SchemaSourceObject $Schema -TableName $TableName `
                                                                                                    -AzAppId $AzAppId -AzAppSecret $AzAppSecret -TenantId $TenantId -Verbose:$Verbose 


                                                    # build schema to be used for DCR
                                                    $Schema = Get-ObjectSchemaAsHash -Data $Data -ReturnType DCR

                                                    CreateUpdate-AzDataCollectionRuleLogIngestCustomLog -AzLogWorkspaceResourceId $AzLogWorkspaceResourceId -SchemaSourceObject $Schema `
                                                                                                        -DceName $DceName -DcrName $DcrName -DcrResourceGroup $DcrResourceGroup -TableName $TableName `
                                                                                                        -LogIngestServicePricipleObjectId $LogIngestServicePricipleObjectId `
                                                                                                        -AzDcrSetLogIngestApiAppPermissionsDcrLevel $AzDcrSetLogIngestApiAppPermissionsDcrLevel `
                                                                                                        -AzAppId $AzAppId -AzAppSecret $AzAppSecret -TenantId $TenantId -Verbose:$Verbose
                                                }
                                        }

                                #-----------------------------------------------------------------------------------------------
                                # Upload data to LogAnalytics using DCR / DCE / Log Ingestion API
                                #-----------------------------------------------------------------------------------------------

                                    $AzDcrDceDetails = Get-AzDcrDceDetails -DcrName $DcrName -DceName $DceName `
                                                                            -AzAppId $AzAppId -AzAppSecret $AzAppSecret -TenantId $TenantId -Verbose:$Verbose

                                    $Result = Post-AzLogAnalyticsLogIngestCustomLogDcrDce  -DceUri $AzDcrDceDetails[2] -DcrImmutableId $AzDcrDceDetails[6] -TableName $TableName `
                                                                                            -DcrStream $AzDcrDceDetails[7] -Data $Data -BatchAmount $BatchAmount `
                                                                                            -AzAppId $AzAppId -AzAppSecret $AzAppSecret -TenantId $TenantId -Verbose:$Verbose
                                    If ($Result.StatusCode -eq "204") # 204 = succes
                                        {
                                            # Delete file from inbound as it has been uploaded sucessfully !
                                            Write-Output ""
                                            Write-Output "  Deleting file $($_.Name)"

                                            Remove-Item -Path $_.Fullname -Force
                                        }
                            }
                        Else
                            {
                                # File is invalid - deleting !
                                Write-Output ""
                                Write-Output "Deleting file $($_.name) - invalid structure"
                                Remove-Item -Path $_.Fullname -Force
                            }

                        # Increment the $i counter variable which is used to create the progress bar.
                        $i = $i+1

                        # Determine the completion percentage
                        $Completed = ($i/$DataCount) * 100
                    Write-Progress -Activity "Uploading log-data to Azure LogAnalytics (log-hub)" -Status "Progress:" -PercentComplete $Completed
            } -End {
                $Data = $DataVariableQA
                Write-Progress -Activity "Uploading log-data to Azure LogAnalytics (log-hub)" -Status "Ready" -Completed
            }

            Write-Output ""
            Write-Output "Waiting 10 sec ..."
            Start-Sleep -Seconds 10
        }
    Until ($Finished -eq $true)   # variable will never be set, so it continues !