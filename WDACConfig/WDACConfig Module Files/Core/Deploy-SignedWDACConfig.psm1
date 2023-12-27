Function Deploy-SignedWDACConfig {
    [CmdletBinding(
        SupportsShouldProcess = $true,
        PositionalBinding = $false,
        ConfirmImpact = 'High'
    )]
    Param(
        [ValidatePattern('\.xml$')]
        [ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' }, ErrorMessage = 'The path you selected is not a file path.')]
        [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)][System.IO.FileInfo[]]$PolicyPaths,

        [Parameter(Mandatory = $false)][System.Management.Automation.SwitchParameter]$Deploy,

        [ValidatePattern('\.cer$')]
        [ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' }, ErrorMessage = 'The path you selected is not a file path.')]
        [parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)][System.IO.FileInfo]$CertPath,

        [ValidateScript({
                # Create an empty array to store the output objects
                [System.String[]]$Output = @()

                # Loop through each certificate that uses RSA algorithm (Because ECDSA is not supported for signing WDAC policies) in the current user's personal store and extract the relevant properties
                foreach ($Cert in (Get-ChildItem -Path 'Cert:\CurrentUser\My' | Where-Object -FilterScript { $_.PublicKey.Oid.FriendlyName -eq 'RSA' })) {

                    # Takes care of certificate subjects that include comma in their CN
                    # Determine if the subject contains a comma
                    if ($Cert.Subject -match 'CN=(?<RegexTest>.*?),.*') {
                        # If the CN value contains double quotes, use split to get the value between the quotes
                        if ($matches['RegexTest'] -like '*"*') {
                            $SubjectCN = ($Element.Certificate.Subject -split 'CN="(.+?)"')[1]
                        }
                        # Otherwise, use the named group RegexTest to get the CN value
                        else {
                            $SubjectCN = $matches['RegexTest']
                        }
                    }
                    # If the subject does not contain a comma, use a lookbehind to get the CN value
                    elseif ($Cert.Subject -match '(?<=CN=).*') {
                        $SubjectCN = $matches[0]
                    }
                    $Output += $SubjectCN
                }

                $Output -contains $_
            }, ErrorMessage = "A certificate with the provided common name doesn't exist in the personal store of the user certificates." )]
        [parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)][System.String]$CertCN,

        [ValidatePattern('\.exe$')]
        [ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' }, ErrorMessage = 'The path you selected is not a file path.')]
        [parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
        [System.IO.FileInfo]$SignToolPath,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.SwitchParameter]$Force,

        [Parameter(Mandatory = $false)][System.Management.Automation.SwitchParameter]$SkipVersionCheck
    )

    begin {
        # Detecting if Verbose switch is used
        $PSBoundParameters.Verbose.IsPresent ? ([System.Boolean]$Verbose = $true) : ([System.Boolean]$Verbose = $false) | Out-Null

        # Importing the $PSDefaultParameterValues to the current session, prior to everything else
        . "$ModuleRootPath\CoreExt\PSDefaultParameterValues.ps1"

        # Importing the required sub-modules
        Write-Verbose -Message 'Importing the required sub-modules'
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Update-self.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Get-SignTool.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Confirm-CertCN.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Write-ColorfulText.psm1" -Force

        # if -SkipVersionCheck wasn't passed, run the updater
        if (-NOT $SkipVersionCheck) { Update-self -InvocationStatement $MyInvocation.Statement }

        #Region User-Configurations-Processing-Validation
        # If any of these parameters, that are mandatory for all of the position 0 parameters, isn't supplied by user
        if (!$SignToolPath -or !$CertPath -or !$CertCN) {
            # Read User configuration file if it exists
            $UserConfig = Get-Content -Path "$UserAccountDirectoryPath\.WDACConfig\UserConfigurations.json" -ErrorAction SilentlyContinue
            if ($UserConfig) {
                # Validate the Json file and read its content to make sure it's not corrupted
                try { $UserConfig = $UserConfig | ConvertFrom-Json }
                catch {
                    Write-Error -Message 'User Configuration Json file is corrupted, deleting it...' -ErrorAction Continue
                    Remove-CommonWDACConfig
                }
            }
        }

        # Get SignToolPath from user parameter or user config file or auto-detect it
        if ($SignToolPath) {
            $SignToolPathFinal = Get-SignTool -SignToolExePath $SignToolPath
        } # If it is null, then Get-SignTool will behave the same as if it was called without any arguments.
        else {
            $SignToolPathFinal = Get-SignTool -SignToolExePath ($UserConfig.SignToolCustomPath ?? $null)
        }

        # If CertPath parameter wasn't provided by user
        if (!$CertPath) {
            if ($UserConfig.CertificatePath) {
                # validate user config values for Certificate Path
                if (Test-Path -Path $($UserConfig.CertificatePath)) {
                    # If the user config values are correct then use them
                    $CertPath = $UserConfig.CertificatePath
                }
                else {
                    throw 'The currently saved value for CertPath in user configurations is invalid.'
                }
            }
            else {
                throw 'CertPath parameter cannot be empty and no valid configuration was found for it.'
            }
        }

        # If CertCN was not provided by user
        if (!$CertCN) {
            if ($UserConfig.CertificateCommonName) {
                # Check if the value in the User configuration file exists and is valid
                if (Confirm-CertCN -CN $($UserConfig.CertificateCommonName)) {
                    # if it's valid then use it
                    $CertCN = $UserConfig.CertificateCommonName
                }
                else {
                    throw 'The currently saved value for CertCN in user configurations is invalid.'
                }
            }
            else {
                throw 'CertCN parameter cannot be empty and no valid configuration was found for it.'
            }
        }
        #Endregion User-Configurations-Processing-Validation

        # Detecting if Confirm switch is used to bypass the confirmation prompts
        if ($Force -and -Not $Confirm) {
            $ConfirmPreference = 'None'
        }
    }

    process {
        foreach ($PolicyPath in $PolicyPaths) {
            # The total number of the main steps for the progress bar to render
            [System.Int16]$TotalSteps = $Deploy ? 4 : 3
            [System.Int16]$CurrentStep = 0

            $CurrentStep++
            Write-Progress -Id 13 -Activity 'Gathering policy details' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

            Write-Verbose -Message "Gathering policy details from: $PolicyPath"
            $Xml = [System.Xml.XmlDocument](Get-Content -Path $PolicyPath)
            [System.String]$PolicyType = $Xml.SiPolicy.PolicyType
            [System.String]$PolicyID = $Xml.SiPolicy.PolicyID
            [System.String]$PolicyName = ($Xml.SiPolicy.Settings.Setting | Where-Object -FilterScript { $_.provider -eq 'PolicyInfo' -and $_.valuename -eq 'Name' -and $_.key -eq 'Information' }).value.string
            [System.String[]]$PolicyRuleOptions = $Xml.SiPolicy.Rules.Rule.Option

            Write-Verbose -Message 'Removing any existing .CIP file of the same policy being signed and deployed if any in the current working directory'
            Remove-Item -Path ".\$PolicyID.cip" -ErrorAction SilentlyContinue

            Write-Verbose -Message 'Checking if the policy type is Supplemental and if so, removing the -Supplemental parameter from the SignerRule command'
            if ($PolicyType -eq 'Supplemental Policy') {

                Write-Verbose -Message 'Policy type is Supplemental'

                # Make sure -User is not added if the UMCI policy rule option doesn't exist in the policy, typically for Strict kernel mode policies
                if ('Enabled:UMCI' -in $PolicyRuleOptions) {
                    Add-SignerRule -FilePath $PolicyPath -CertificatePath $CertPath -Update -User -Kernel
                }
                else {
                    Write-Verbose -Message 'UMCI policy rule option does not exist in the policy, typically for Strict kernel mode policies'
                    Add-SignerRule -FilePath $PolicyPath -CertificatePath $CertPath -Update -Kernel
                }
            }
            else {

                Write-Verbose -Message 'Policy type is Base'

                # Make sure -User is not added if the UMCI policy rule option doesn't exist in the policy, typically for Strict kernel mode policies
                if ('Enabled:UMCI' -in $PolicyRuleOptions) {
                    Add-SignerRule -FilePath $PolicyPath -CertificatePath $CertPath -Update -User -Kernel -Supplemental
                }
                else {
                    Write-Verbose -Message 'UMCI policy rule option does not exist in the policy, typically for Strict kernel mode policies'
                    Add-SignerRule -FilePath $PolicyPath -CertificatePath $CertPath -Update -Kernel -Supplemental
                }
            }

            $CurrentStep++
            Write-Progress -Id 13 -Activity 'Creating CIP file' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

            Write-Verbose -Message 'Setting HVCI to Strict'
            Set-HVCIOptions -Strict -FilePath $PolicyPath

            Write-Verbose -Message 'Removing the Unsigned mode option from the policy rules'
            Set-RuleOption -FilePath $PolicyPath -Option 6 -Delete

            Write-Verbose -Message 'Converting the policy to .CIP file'
            ConvertFrom-CIPolicy -XmlFilePath $PolicyPath -BinaryFilePath "$PolicyID.cip" | Out-Null

            $CurrentStep++
            Write-Progress -Id 13 -Activity 'Signing the policy' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

            # Configure the parameter splat
            $ProcessParams = @{
                'ArgumentList' = 'sign', '/v' , '/n', "`"$CertCN`"", '/p7', '.', '/p7co', '1.3.6.1.4.1.311.79.1', '/fd', 'certHash', ".\$PolicyID.cip"
                'FilePath'     = $SignToolPathFinal
                'NoNewWindow'  = $true
                'Wait'         = $true
                'ErrorAction'  = 'Stop'
            }
            # Hide the SignTool.exe's normal output unless -Verbose parameter was used
            if (!$Verbose) { $ProcessParams['RedirectStandardOutput'] = 'NUL' }

            # Sign the files with the specified cert
            Write-Verbose -Message 'Signing the policy with the specified certificate'
            Start-Process @ProcessParams

            Write-Verbose -Message 'Making sure a .CIP file with the same name is not present in the current working directory'
            Remove-Item -Path ".\$PolicyID.cip" -Force

            Write-Verbose -Message 'Renaming the .p7 file to .cip'
            Rename-Item -Path "$PolicyID.cip.p7" -NewName "$PolicyID.cip" -Force

            if ($Deploy) {

                $CurrentStep++
                Write-Progress -Id 13 -Activity 'Deploying' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

                # Prompt for confirmation before proceeding
                if ($PSCmdlet.ShouldProcess('This PC', 'Deploying the signed policy')) {

                    Write-Verbose -Message 'Deploying the policy'
                    &'C:\Windows\System32\CiTool.exe' --update-policy ".\$PolicyID.cip" -json | Out-Null

                    Write-ColorfulText -Color Lavender -InputText 'policy with the following details has been Signed and Deployed in Enforced Mode:'
                    Write-ColorfulText -Color MintGreen -InputText "PolicyName = $PolicyName"
                    Write-ColorfulText -Color MintGreen -InputText "PolicyGUID = $PolicyID"

                    Write-Verbose -Message 'Removing the .CIP file after deployment'
                    Remove-Item -Path ".\$PolicyID.cip" -Force

                    #Region Detecting Strict Kernel mode policy and removing it from User Configs
                    if ('Enabled:UMCI' -notin $PolicyRuleOptions) {

                        [System.String]$StrictKernelPolicyGUID = Get-CommonWDACConfig -StrictKernelPolicyGUID
                        [System.String]$StrictKernelNoFlightRootsPolicyGUID = Get-CommonWDACConfig -StrictKernelNoFlightRootsPolicyGUID

                        if (($PolicyName -like '*Strict Kernel mode policy Enforced*')) {

                            Write-Verbose -Message 'The deployed policy is Strict Kernel mode'

                            if ($StrictKernelPolicyGUID) {
                                if ($($PolicyID.TrimStart('{').TrimEnd('}')) -eq $StrictKernelPolicyGUID) {

                                    Write-Verbose -Message 'Removing the GUID of the deployed Strict Kernel mode policy from the User Configs'
                                    Remove-CommonWDACConfig -StrictKernelPolicyGUID | Out-Null
                                }
                            }
                        }
                        elseif (($PolicyName -like '*Strict Kernel No Flights mode policy Enforced*')) {

                            Write-Verbose -Message 'The deployed policy is Strict Kernel No Flights mode'

                            if ($StrictKernelNoFlightRootsPolicyGUID) {
                                if ($($PolicyID.TrimStart('{').TrimEnd('}')) -eq $StrictKernelNoFlightRootsPolicyGUID) {

                                    Write-Verbose -Message 'Removing the GUID of the deployed Strict Kernel No Flights mode policy from the User Configs'
                                    Remove-CommonWDACConfig -StrictKernelNoFlightRootsPolicyGUID | Out-Null
                                }
                            }
                        }
                    }
                    #Endregion Detecting Strict Kernel mode policy and removing it from User Configs
                }
            }
            else {
                Write-ColorfulText -Color Lavender -InputText 'policy with the following details has been Signed and is ready for deployment:'
                Write-ColorfulText -Color MintGreen -InputText "PolicyName = $PolicyName"
                Write-ColorfulText -Color MintGreen -InputText "PolicyGUID = $PolicyID"
            }
            Write-Progress -Id 13 -Activity 'Complete.' -Completed
        }
    }

    <#
.SYNOPSIS
    Signs and Deploys WDAC policies, accepts signed or unsigned policies and deploys them
.LINK
    https://github.com/HotCakeX/Harden-Windows-Security/wiki/Deploy-SignedWDACConfig
.DESCRIPTION
    Using official Microsoft methods, Signs and Deploys WDAC policies, accepts signed or unsigned policies and deploys them (Windows Defender Application Control)
.COMPONENT
    Windows Defender Application Control, ConfigCI PowerShell module
.FUNCTIONALITY
    Using official Microsoft methods, Signs and Deploys WDAC policies, accepts signed or unsigned policies and deploys them (Windows Defender Application Control)
.PARAMETER CertPath
    Path to the certificate .cer file
.PARAMETER PolicyPaths
    Path to the policy xml files that are going to be signed
.PARAMETER CertCN
    Certificate common name
.PARAMETER SignToolPath
    Path to the SignTool.exe - optional parameter
.PARAMETER Deploy
    Indicates that the cmdlet will deploy the signed policy on the current system
.PARAMETER Force
    Indicates that the cmdlet will bypass the confirmation prompts
.PARAMETER SkipVersionCheck
    Can be used with any parameter to bypass the online version check - only to be used in rare cases
.INPUTS
    System.String
    System.String[]
    System.Management.Automation.SwitchParameter
.OUTPUTS
    System.String
#>
}

# Importing argument completer ScriptBlocks
. "$ModuleRootPath\Resources\ArgumentCompleters.ps1"
Register-ArgumentCompleter -CommandName 'Deploy-SignedWDACConfig' -ParameterName 'CertCN' -ScriptBlock $ArgumentCompleterCertificateCN
Register-ArgumentCompleter -CommandName 'Deploy-SignedWDACConfig' -ParameterName 'PolicyPaths' -ScriptBlock $ArgumentCompleterPolicyPaths
Register-ArgumentCompleter -CommandName 'Deploy-SignedWDACConfig' -ParameterName 'CertPath' -ScriptBlock $ArgumentCompleterCerFilePathsPicker
Register-ArgumentCompleter -CommandName 'Deploy-SignedWDACConfig' -ParameterName 'SignToolPath' -ScriptBlock $ArgumentCompleterExeFilePathsPicker

# SIG # Begin signature block
# MIILhgYJKoZIhvcNAQcCoIILdzCCC3MCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCwRTLbYR2tyMkq
# Pwz7so9rkqBTBLu3TVqiK/UjQ3VBqKCCB88wggfLMIIFs6ADAgECAhNUAAAABzgp
# /t9ITGbLAAAAAAAHMA0GCSqGSIb3DQEBDQUAMEQxEzARBgoJkiaJk/IsZAEZFgNj
# b20xFDASBgoJkiaJk/IsZAEZFgRCaW5nMRcwFQYDVQQDEw5CaW5nLVNFUlZFUi1D
# QTAgFw0yMzEyMjcwODI4MDlaGA8yMTMzMTIyNzA4MzgwOVoweDELMAkGA1UEBhMC
# VUsxFjAUBgNVBAoTDVNweU5ldEdpcmwgQ28xKjAoBgNVBAMTIUhvdENha2VYIENv
# ZGUgU2lnbmluZyBDZXJ0aWZpY2F0ZTElMCMGCSqGSIb3DQEJARYWU3B5bmV0Z2ly
# bEBvdXRsb29rLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANsD
# szHV9Ea21AhOw4a35P1R30HHtmz+DlWKk/a4FvYQivl9dd+f+SZaybl0O96H6YNp
# qLnx7KD9TSEBbB+HxjE39GfWoX2R1VlPaDqkbGMA0XmnUB+/5CsbhktY4gbvJpW5
# LWXk0xUmCSvLMs7eiuBOGNs3zw5xVVNhsES6/aYMCWREI9YPTVbh7En6P4uZOisy
# K2tZtkSe/TXabfr1KtNhELr3DpTNtJBMBLzhz8d6ztJExKebFqpiaNqF7TpTOTRI
# 4P02k6u6lsWMz/rH9mMHdGSyBJ3DEyJGL9QT4jO4BFLHsxHuWTpjxnqxZNjwLTjB
# NEhH+VcKIIy2iWHfWwK2Nwr/3hzDbfqsWrMrXvvCqGpei+aZTxyplbMPpmd5myKo
# qLI58zc7cMi/HuAbbjo1YWxd/J1shHifMfhXfuncjHr7RTGC3BaEzwirQ12t1Z2K
# Zn2AhLnhSElbgZppt+WS4bmzT6L693srDxSMcBpRcu8NyDteLVCmgfBGXDdfAKEZ
# KXPi9liV0b66YQWnBp9/3bYwtYTh5VwjfSVAMfWsrMpIeGmvGUcsnQCqCxCulHKX
# onoYmbyotyOiXObXVgzB2G0k+VjxiFTSb1ENf3GJV1FJbzbch/p/tASY9w2L7kT/
# l+/Nnp4XOuPDYhm/0KWgEH7mUyq4KkP/BG/on7Q5AgMBAAGjggJ+MIICejA8Bgkr
# BgEEAYI3FQcELzAtBiUrBgEEAYI3FQjinCqC5rhWgdmZEIP42AqB4MldgT6G3Kk+
# mJFMAgFkAgEOMBMGA1UdJQQMMAoGCCsGAQUFBwMDMA4GA1UdDwEB/wQEAwIHgDAM
# BgNVHRMBAf8EAjAAMBsGCSsGAQQBgjcVCgQOMAwwCgYIKwYBBQUHAwMwHQYDVR0O
# BBYEFFr7G/HfmP3Om/RStyhaEtEFmSYKMB8GA1UdEQQYMBaBFEhvdGNha2V4QG91
# dGxvb2suY29tMB8GA1UdIwQYMBaAFChQ2b1sdIHklqMDHsFKcUCX6YREMIHIBgNV
# HR8EgcAwgb0wgbqggbeggbSGgbFsZGFwOi8vL0NOPUJpbmctU0VSVkVSLUNBLENO
# PVNlcnZlcixDTj1DRFAsQ049UHVibGljJTIwS2V5JTIwU2VydmljZXMsQ049U2Vy
# dmljZXMsQ049Q29uZmlndXJhdGlvbixEQz1CaW5nLERDPWNvbT9jZXJ0aWZpY2F0
# ZVJldm9jYXRpb25MaXN0P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9u
# UG9pbnQwgb0GCCsGAQUFBwEBBIGwMIGtMIGqBggrBgEFBQcwAoaBnWxkYXA6Ly8v
# Q049QmluZy1TRVJWRVItQ0EsQ049QUlBLENOPVB1YmxpYyUyMEtleSUyMFNlcnZp
# Y2VzLENOPVNlcnZpY2VzLENOPUNvbmZpZ3VyYXRpb24sREM9QmluZyxEQz1jb20/
# Y0FDZXJ0aWZpY2F0ZT9iYXNlP29iamVjdENsYXNzPWNlcnRpZmljYXRpb25BdXRo
# b3JpdHkwDQYJKoZIhvcNAQENBQADggIBAE/AISQevRj/RFQdRbaA0Ffk3Ywg4Zui
# +OVuCHrswpja/4twBwz4M58aqBSoR/r9GZo69latO74VMmki83TX+Pzso3cG5vPD
# +NLxwAQUo9b81T08ZYYpdWKv7f+9Des4WbBaW9AGmX+jJn+JLAFp+8V+nBkN2rS9
# 47seK4lwtfs+rVMGBxquc786fXBAMRdk/+t8G58MZixX8MRggHhVeGc5ecCRTDhg
# nN68MhJjpwqsu0sY2NeKz5gMSk6wvt+NDPcfSZyNo1uSEMKTl/w5UH7mnrv0D4fZ
# UOY3cpIwbIagwdBuFupKG/m1I2LXZdLgGfOtZyZyw+c5Kd0KlMxonBiVoqN7PvoA
# 7sfwDI7PMLMQ3mseFbIpSUQGXHGeyouN1jF5ciySfHnW1goiG8tfDKNAT7WEz+ZT
# c1iIH+lCDUV/LmFD1Bvj2A9Q01C9BsScH+9vb2CnIwaSmfFRI6PY9cKOEHdy/ULi
# hp72QBd6W6ZQMZWXI5m48DdiKlQGA1aCdNN6+C0of43a7L0rAtLPYKySpd6gc34I
# h7/DgGLqXg0CO4KtbGdEWfKHqvh0qYLRmo/obhyVMYib4ceKrCcdc9aVlng/25nE
# ExvokF0vVXKSZkRUAfNHmmfP3lqbjABHC2slbStolocXwh8CoN8o2iOEMnY/xez0
# gxGYBY5UvhGKMYIDDTCCAwkCAQEwWzBEMRMwEQYKCZImiZPyLGQBGRYDY29tMRQw
# EgYKCZImiZPyLGQBGRYEQmluZzEXMBUGA1UEAxMOQmluZy1TRVJWRVItQ0ECE1QA
# AAAHOCn+30hMZssAAAAAAAcwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIB
# DDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEE
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg9aAt62DFk68F
# gRSohKMBdVvji69lOf+ictPC11HAUVIwDQYJKoZIhvcNAQEBBQAEggIAB0oSrrUU
# GpkAjoqjlUA2FWdTB9KSLe3fqU14Vz2LfB3nUiX44gg5/qeWS+YTUayoPcOHEEjE
# egHxAXPzjhxFwFevSW9qzXAz93RPaOjkx0hImQkEN2MFlU997+reroFp1NEGLgOo
# j2ppH+MVVXVpEmE7QJyZhM2Ybr6bfLDtmsd40FUwHZ76uwaoT5lzaNzTiOlzk0gG
# LYyruAI/pXHVGfpGkf2R44yVFxRrkJLYFwClaFd67qvE6ezJYGVEIfbB3Y8XNtMd
# IPsSUY29i5Z2nNUBTHC6DfSi/yMIBUbek8ZgjUioMFAFPyhWUqkeXB6CiP/utKeJ
# +3h6x4PIawsz+hNCEpRmRnYSlJE6BIU2uIK0twToUadVAvzJDaOEzcMU04yoBTtL
# WMt2tm97aERXUfwAOm7/K9UVqqDPySwrzuAd2dpuyE9gbMNOkm5SEBPq0b+ROYpq
# rXtaya5ajrXyopO2oZMTYj+l/DslboTax1DPv6r4Rg96u1mUY9HAvwcnVRL7eha3
# xwFMA+H6mCZDg0dIxWM1HqJMkWqaD6fR5Cqx0bm0aIjtX4yTBH+dt62QvJ1Ye+QK
# 4qygqECm1EVDhqONeiKKVbMGsv1NDA9z06wPxc9ln+xOQ8BaB3XUPZAVsgaswy72
# EMcJvACHKi25TD1A6bVqLtOUprj/dja9fWw=
# SIG # End signature block
