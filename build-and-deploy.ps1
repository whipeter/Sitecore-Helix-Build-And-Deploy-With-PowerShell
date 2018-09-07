function build-and-deploy
{
	param(
	[parameter(Mandatory=$false)]
	[string]$inputParameter="WriteUnicornToEnable"
	)
	
	# If there is no active solution the build-and-deploy function would fail.
	if (-not $dte.Solution.FullName)
	{
		throw [System.ArgumentException] "There is no active solution. Load a Sitecore Helix solution first which contains an build-and-deploy-configuration.json file."
	}
	
	# Save all files before publish. 
	$dte.ExecuteCommand("File.SaveAll")
	
	$solutionRootFolder = [System.IO.Path]::GetDirectoryName($dte.Solution.FullName)

	# Get solution folder where .json config is stored and populate variables
	$jsonObject = getJsonConfig
	[String]$msBuildExe = Find-MsBuild($jsonObject.config.msBuildExe)
	[String]$unicornScriptSource = $jsonObject.config.unicornScript
	[String]$unicornScript = "$solutionRootFolder\$unicornScriptSource"
	[String]$solutionFile = $dte.Solution.FullName
	[String]$appPoolName = $jsonObject.config.appPoolName
	[String]$siteUrl = $jsonObject.config.siteUrl
	[String]$devConfigPath = $jsonObject.config.devConfigPath
	[bool]$nugetRestore = $jsonObject.config.nugetRestore

	#Get the paths to the site, based on site inputname
	[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Web.Administration")
	$iis = new-object Microsoft.Web.Administration.ServerManager "C:\Windows\System32\inetsrv\config\applicationHost.config"
	$site = $iis.sites | Where-Object {$_.Name -eq $siteUrl} 
	[String]$publishTarget = $site.Applications["/"].VirtualDirectories["/"].PhysicalPath

	# Nuget restore (external application dependancy https://docs.microsoft.com/en-us/nuget/tools/nuget-exe-cli-reference).
	if ($nugetRestore) {
		Write-Host "Restoring NuGet packages..." -foregroundcolor Magenta
		$sw = [Diagnostics.Stopwatch]::StartNew()
		Try{
			nuget restore "$($solutionFile)"
		}
		Catch{
			throw [System.ArgumentException] "Cannot execute nuget command. Check your external application dependancy (https://docs.microsoft.com/en-us/nuget/tools/nuget-exe-cli-reference)"
		}
		$sw.Stop()
		$timeTaken = $sw.Elapsed.TotalSeconds
		Write-Host "Nuget took $timeTaken seconds" -foregroundcolor Magenta
	}
	
	# Find our websites apppool workerprocess and kill it. This is done instead of start and stop IIS AppPool
	[System.Object[]]$allWorkerProcesses = gwmi -NS 'root\WebAdministration' -class 'WorkerProcess' | select AppPoolName,ProcessId
	[System.Object[]]$currentWorkerProcess = $allWorkerProcesses | Where-Object { $_.AppPoolName -eq $appPoolName } | select ProcessId
	[string]$currentWorkerProcessId = $currentWorkerProcess.ProcessId
	
	if ([string]::IsNullOrEmpty($currentWorkerProcessId)){
		write-host "No active IIS worker process. Resuming script..." -foregroundcolor Magenta
	}
	else{
		write-host "Killing active IIS worker process for: "$siteUrl" ("$currentWorkerProcessId")" -foregroundcolor Magenta
		Stop-Process -id $currentWorkerProcessId -Force
	}

	# Build and deploy.
	Write-Host "Starting MSBuild and deployment - $($solutionFile)..." -foregroundcolor Magenta
	& "$($msBuildExe)" "$($solutionFile)" /m /nr:false /p:DeployOnBuild=true /p:DeployDefaultTarget=WebPublish /p:WebPublishMethod=FileSystem /p:Configuration=debug /p:PublishUrl=$publishTarget
	
	if ($LastExitCode -ne 0){
		Write-Host "Build failed" -foregroundcolor Magenta
	}
	elseif(($inputParameter) -eq "unicorn"){
		Write-Host "Starting site and running unicorn... (this will take a while)" -foregroundcolor Magenta
		$sw = [Diagnostics.Stopwatch]::StartNew()
		&$unicornScript $siteUrl
		$sw.Stop()
		$timeTaken = $sw.Elapsed.TotalSeconds
		Write-Host "Unicorn took $timeTaken seconds" -foregroundcolor Magenta
	}
	else{
		Write-Host "Starting site: $siteUrl..." -foregroundcolor Magenta
		$sw = [Diagnostics.Stopwatch]::StartNew()
		[String] $statusCode = (Invoke-WebRequest -Uri $siteUrl).StatusCode
		$sw.Stop()
		$timeTaken = $sw.Elapsed.TotalSeconds
		Write-Host "Site started with statuscode: $statusCode, after $timeTaken seconds" -foregroundcolor Magenta
	}
}

Function Find-MsBuild([string] $path)
{
	# https://alastaircrabtree.com/how-to-find-latest-version-of-msbuild-in-powershell/
	$rootPath = "C:\Program Files (x86)\Microsoft Visual Studio\2017"
	$buildPart = "MSBuild\15.0\Bin\msbuild.exe"
	$agentPath = "$rootPath$vsPart\BuildTools\$buildPart"
	If (Test-Path $agentPath) { return $agentPath } 
	$agentPath = "$rootPath$vsPart\Enterprise\$buildPart"
	If (Test-Path $agentPath) { return $agentPath } 
	$agentPath = "$rootPath$vsPart\Professional\$buildPart"
	If (Test-Path $agentPath) { return $agentPath } 
	$agentPath = "$rootPath$vsPart\Community\$buildPart"
	If (Test-Path $agentPath) { return $agentPath } 

	$rootPath = "C:\Program Files\Microsoft Visual Studio\2017"
	$agentPath = "$rootPath$vsPart\BuildTools\$buildPart"
	If (Test-Path $agentPath) { return $agentPath } 
	$agentPath = "$rootPath$vsPart\Enterprise\$buildPart"
	If (Test-Path $agentPath) { return $agentPath } 
	$agentPath = "$rootPath$vsPart\Professional\$buildPart"
	If (Test-Path $agentPath) { return $agentPath } 
	$agentPath = "$rootPath$vsPart\Community\$buildPart"
	If (Test-Path $agentPath) { return $agentPath } 

    return $path
}

function unicorn
{
	# If there is no active solution the build-and-deploy function would fail.
	if (-not $dte.Solution.FullName)
	{
		throw [System.ArgumentException] "There is no active solution. Load a Sitecore Helix solution first which contains an build-and-deploy-configuration.json file."
	}

	$jsonObject = getJsonConfig

	[String]$unicornScript = $jsonObject.config.unicornScript
	[String]$siteUrl = $jsonObject.config.siteUrl
	
	Write-Host "Running unicorn... (this will take a while)" -foregroundcolor Magenta
	&$unicornScript $siteUrl

}

function getJsonConfig{
	$solutionRootFolder = [System.IO.Path]::GetDirectoryName($dte.Solution.FullName)
	$jsonConfig = $solutionRootFolder + "\build-and-deploy-configuration.json"
	
	if ((Test-Path $jsonConfig) -eq $true){$jsonObject = Get-Content $jsonConfig | ConvertFrom-Json}
	else{throw [System.ArgumentException] "$jsonConfig does not exist."}
	
	return $jsonObject
}
