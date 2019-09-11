# ------------------------------------------------------------
# Copyright (c) Microsoft Corporation.  All rights reserved.
# Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
# ------------------------------------------------------------

function Read-XmlElementAsHashtable
{
    Param (
        [System.Xml.XmlElement]
        $Element
    )

    $hashtable = @{}
    if ($Element.Attributes)
    {
        $Element.Attributes | 
            ForEach-Object {
                $boolVal = $null
                if ([bool]::TryParse($_.Value, [ref]$boolVal)) {
                    $hashtable[$_.Name] = $boolVal
                }
                else {
                    $hashtable[$_.Name] = $_.Value
                }
            }
    }

    return $hashtable
}

function Read-PublishProfile
{
    Param (
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [String]
        $PublishProfileFile
    )

    $publishProfileXml = [Xml] (Get-Content $PublishProfileFile)
    $publishProfile = @{}

    $publishProfile.ClusterConnectionParameters = Read-XmlElementAsHashtable $publishProfileXml.PublishProfile.Item("ClusterConnectionParameters")
    $publishProfile.UpgradeDeployment = Read-XmlElementAsHashtable $publishProfileXml.PublishProfile.Item("UpgradeDeployment")
    $publishProfile.CopyPackageParameters = Read-XmlElementAsHashtable $publishProfileXml.PublishProfile.Item("CopyPackageParameters")
    $publishProfile.RegisterApplicationParameters = Read-XmlElementAsHashtable $publishProfileXml.PublishProfile.Item("RegisterApplicationParameters")

    if ($publishProfileXml.PublishProfile.Item("UpgradeDeployment"))
    {
        $publishProfile.UpgradeDeployment.Parameters = Read-XmlElementAsHashtable $publishProfileXml.PublishProfile.Item("UpgradeDeployment").Item("Parameters")
        if ($publishProfile.UpgradeDeployment["Mode"])
        {
            $publishProfile.UpgradeDeployment.Parameters[$publishProfile.UpgradeDeployment["Mode"]] = $true
        }
    }

    $publishProfileFolder = (Split-Path $PublishProfileFile)

    $publishProfile.ApplicationParameterFile = [System.IO.Path]::Combine($PublishProfileFolder, $publishProfileXml.PublishProfile.ApplicationParameterFile.Path)
    $publishProfile.ApplicationName = Get-ApplicationNameFromApplicationParameterFile $publishProfile.ApplicationParameterFile
    $publishProfile.ApplicationParameters = Get-ApplicationParametersFromApplicationParameterFile $publishProfile.ApplicationParameterFile
    $appNames = @{}
    (Get-NamesFromApplicationManifest "$PublishProfileFolder\..\ApplicationPackageRoot\ApplicationManifest.xml").psobject.properties | Foreach { $appNames[$_.Name] = $_.Value }

    $publishProfile = Merge-HashTables $publishProfile $appNames

    if ($publishProfile.UpgradeDeployment.Parameters)
    {
        $publishProfile.UpgradeParams = $publishProfile.UpgradeDeployment.Parameters
        $publishProfile.UpgradeParams["ApplicationName"] = $publishProfile.ApplicationName
        $publishProfile.UpgradeParams["ApplicationTypeVersion"] = $publishProfile.ApplicationTypeVersion
        $publishProfile.UpgradeParams["ApplicationParameter"] = $publishProfile.ApplicationParameters
    }

    return $publishProfile
}

function Copy-ToTemp
{
    <#
    .SYNOPSIS 
    Copies files to a temp folder.

    .PARAMETER From
    Source location from which to copy files.

    .PARAMETER Name
    Folder name within temp location to store the files.
    #>

    [CmdletBinding()]
    Param
    (
        [String]
        $From,
        
        [String]
        $Name
    )

    if (!(Test-Path $From))
    {
        return $null
    }

    $To = $env:Temp + '\' + $Name
    
    if (Test-Path $To)
    {
        Remove-Item -Path $To -Recurse -ErrorAction Stop | Out-Null
    }

    New-Item $To -ItemType directory | Out-Null

    robocopy "$From" "$To" /E /MT | Out-Null

    # robocopy has non-standard exit values that are documented here: https://support.microsoft.com/en-us/kb/954404
    # Exit codes 0-8 are considered success, while all other exit codes indicate at least one failure.
    # Some build systems treat all non-0 return values as failures, so we massage the exit code into
    # something that they can understand.
    if (($LASTEXITCODE -ge 0) -and ($LASTEXITCODE -le 8))
    {
        # Simply setting $LASTEXITCODE in this script will not override the script's exit code.
        # We need to start a new process and let it exit.
        PowerShell -NoProfile -Command "exit 0"
    }

    return $env:Temp + '\' + $Name
}

function Expand-ToFolder
{
    <#
    .SYNOPSIS 
    Unzips the zip file to the specified folder.

    .PARAMETER From
    Source location to unzip

    .PARAMETER Name
    Folder name to expand the files to.
    #>

    [CmdletBinding()]
    Param
    (
        [String]
        $File,
        
        [String]
        $Destination
    )

    if (!(Test-Path $File))
    {
        return
    }    
    
    if (Test-Path $Destination)
    {
        Remove-Item -Path $Destination -Recurse -ErrorAction Stop | Out-Null
    }

    New-Item $Destination -ItemType directory | Out-Null


    Write-Verbose -Message "Attempting to Unzip $File to location $Destination" 
    try 
    {
        [System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null 
        [System.IO.Compression.ZipFile]::ExtractToDirectory("$File", "$Destination") 
    } 
    catch 
    { 
        Write-Error -Message "Unexpected Error. Error details: $_.Exception.Message" 
    } 
}

function Compress-ToFile
{
   <#
    .SYNOPSIS 
    Compress the Source Directory to a zip file.

    .PARAMETER SourceDir
    Path of the directory to zip

    .PARAMETER FileName
    Name of the zip file to generate. 
    #>
    
   [CmdletBinding()]
    Param
    (
        [String]
        $SourceDir,
        
        [String]
        $FileName
    )
    
    if (!(Test-Path $SourceDir))
    {
        return
    }  
    
    try 
    {
        [System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null 
        $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal
        [System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir,$FileName, $compressionLevel, $false)
    }
    catch 
    { 
        Write-Error -Message "Unexpected Error. Error details: $_.Exception.Message" 
    } 
}

function Get-NamesFromApplicationManifest
{
    <#
    .SYNOPSIS 
    Returns an object containing common information from the application manifest.

    .PARAMETER ApplicationManifestPath
    Path to the application manifest file.    
    #>

    [CmdletBinding()]
    Param
    (
        [String]
        $ApplicationManifestPath
    )

    if (!(Test-Path $ApplicationManifestPath))
    {
        throw "$ApplicationManifestPath is not found."
    }

    
    $appXml = [xml] (Get-Content $ApplicationManifestPath)
    if (!$appXml)
    {
        return
    }

    $appMan = $appXml.ApplicationManifest
    $FabricNamespace = 'fabric:'
    $appTypeSuffix = 'Type'

    $h = @{
        FabricNamespace = $FabricNamespace;
        ApplicationTypeName = $appMan.ApplicationTypeName;
        ApplicationTypeVersion = $appMan.ApplicationTypeVersion;
    }   

    Write-Output (New-Object psobject -Property $h)
}

function Get-ImageStoreConnectionString
{
    $xml = [xml](Get-ServiceFabricClusterManifest)
    Get-ImageStoreConnectionStringFromClusterManifest -ClusterManifest $xml
}

function Get-ImageStoreConnectionStringFromClusterManifest
{
    <#
    .SYNOPSIS 
    Returns the value of the image store connection string from the cluster manifest.

    .PARAMETER ClusterManifest
    Contents of cluster manifest file.
    #>

    [CmdletBinding()]
    Param
    (
        [xml]
        $ClusterManifest
    )

    $managementSection = $ClusterManifest.ClusterManifest.FabricSettings.Section | ? { $_.Name -eq "Management" }
    return $managementSection.ChildNodes | ? { $_.Name -eq "ImageStoreConnectionString" } | Select-Object -Expand Value
}


function Get-ApplicationNameFromApplicationParameterFile
{
    <#
    .SYNOPSIS 
    Returns Application Name from ApplicationParameter xml file.

    .PARAMETER ApplicationParameterFilePath
    Path to the application parameter file
    #>

    [CmdletBinding()]
    Param
    (
        [String]
        $ApplicationParameterFilePath
    )
    
    if (!(Test-Path $ApplicationParameterFilePath))
    {
        $errMsg = "$ApplicationParameterFilePath is not found."
        throw $errMsg
    }

    return ([xml] (Get-Content $ApplicationParameterFilePath)).Application.Name
}


function Get-ApplicationParametersFromApplicationParameterFile
{
    <#
    .SYNOPSIS 
    Reads ApplicationParameter xml file and returns HashTable containing ApplicationParameters.

    .PARAMETER ApplicationParameterFilePath
    Path to the application parameter file
    #>

    [CmdletBinding()]
    Param
    (
        [String]
        $ApplicationParameterFilePath
    )
    
    if (!(Test-Path $ApplicationParameterFilePath))
    {
        throw "$ApplicationParameterFilePath is not found."
    }
    
    $xml = [xml] (Get-Content $ApplicationParameterFilePath)
    $ParametersXml = $xml.Application.Parameters

    $hash = @{}
    $ParametersXml.ChildNodes | foreach {
       if ($_.LocalName -eq 'Parameter') {
       $hash[$_.Name] = $_.Value
       }
    }

    return $hash
}

function Merge-HashTables
{
    <#
    .SYNOPSIS 
    Merges 2 hashtables. Key, value pairs form HashTableNew are preserved if any duplciates are found between HashTableOld & HashTableNew.

    .PARAMETER HashTableOld
    First Hashtable.
    
    .PARAMETER HashTableNew
    Second Hashtable 
    #>

    [CmdletBinding()]
    Param
    (
        [HashTable]
        $HashTableOld,
        
        [HashTable]
        $HashTableNew
    )
    
    $keys = $HashTableOld.getenumerator() | foreach-object {$_.key}
    $keys | foreach-object {
        $key = $_
        if ($HashTableNew.containskey($key))
        {
            $HashTableOld.remove($key)
        }
    }
    $HashTableNew = $HashTableOld + $HashTableNew
    return $HashTableNew
}

function Publish-DevAppInstance
{
    Param
    (
        [Parameter(
           Position=0, 
           Mandatory=$true, 
           ValueFromPipeline=$true)
        ]
        $profile
    )

    $c = $profile.ClusterConnectionParameters
    connect-servicefabriccluster @c
    $profile | % { Copy-ServiceFabricApplicationPackage -ApplicationPackagePath .\pkg\Debug\ -ApplicationPackagePathInImageStore $_.ApplicationTypeName}
    $profile | % { Register-ServiceFabricApplicationType -ApplicationPathInImageStore $_.ApplicationTypeName}
    $profile | % { New-ServiceFabricApplication -ApplicationName $_.ApplicationName -ApplicationTypeName $_.ApplicationTypeName -ApplicationTypeVersion $_.ApplicationTypeVersion -ApplicationParameter $_.ApplicationParameters}
    $profile | % { Remove-ServiceFabricApplicationPackage -ApplicationPackagePathInImageStore $_.ApplicationTypeName }

}

function Remove-DevAppInstance
{
    Param
    (
        [Parameter(
           Position=0, 
           Mandatory=$true, 
           ValueFromPipeline=$true)
        ]
        $profile    
    )

    $c = $profile.ClusterConnectionParameters
    connect-servicefabriccluster @c

    $profile | % {Remove-ServiceFabricApplication -ApplicationName $_.ApplicationName -Force}
    
    $profile | % {Unregister-ServiceFabricApplicationType -ApplicationTypeName $_.ApplicationTypeName -ApplicationTypeVersion $_.ApplicationTypeVersion -Force}
}

function Republish-DevAppInstance
{
    Param
    (
        [Parameter(
           Position=0, 
           Mandatory=$true, 
           ValueFromPipeline=$true)
        ]
        $profile    
    )

    $profile | Remove-DevAppInstance 
    $profile | Publish-DevAppInstance 
}

function Upgrade-DevAppInstance
{
    Param
    (
        [Parameter(
           Position=0, 
           Mandatory=$true, 
           ValueFromPipeline=$true)
        ]
        $profile
    )

    $c = $profile.ClusterConnectionParameters
    connect-servicefabriccluster @c

    $upgradeParams = $profile.UpgradeDeployment.Parameters
    $upgradeParams["ApplicationName"] = $profile.ApplicationName
    $upgradeParams["ApplicationTypeVersion"] = $profile.ApplicationTypeVersion
    $upgradeParams["ApplicationParameter"] = $profile.ApplicationParameters

    $profile | % { Copy-ServiceFabricApplicationPackage -ApplicationPackagePath .\pkg\Debug\ -ImageStoreConnectionString $imageStore -ApplicationPackagePathInImageStore $_.ApplicationTypeName}

    $profile | % { Register-ServiceFabricApplicationType -ApplicationPathInImageStore $_.ApplicationTypeName}

    Start-ServiceFabricApplicationUpgrade @upgradeParam

    $profile | % { Remove-ServiceFabricApplicationPackage -ImageStoreConnectionString $imageStore -ApplicationPackagePathInImageStore $_.ApplicationTypeName }

}
