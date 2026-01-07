#!/usr/bin/env pwsh

param(
	[Parameter(Mandatory = $false)]
	[switch]$Help,

	[Parameter(Mandatory = $false)]
	[string]$ProjectDir = '',

	[Parameter(Mandatory = $false)]
	[int]$MaxIterations = 0,  # 0 means unlimited

	[Parameter(Mandatory = $false)]
	[string]$Spec = '',

	[Parameter(Mandatory = $false)]
	[int]$Timeout = 600,  # Default to 600 seconds

	[Parameter(Mandatory = $false)]
	[int]$IdleTimeout = 300,  # Default idle output timeout in seconds (increased from 180 to allow for longer AI responses)

	[Parameter(Mandatory = $false)]
	[string]$Model = '',

	[Parameter(Mandatory = $false)]
	[string]$InitModel = '',

	[Parameter(Mandatory = $false)]
	[string]$CodeModel = '',

	[Parameter(Mandatory = $false)]
	[switch]$NoClean

	[Parameter(Mandatory = $false)]
	[int]$QuitOnAbort = 0
)

# Show help if requested
if ($Help) {
	Write-Host 'Usage: aidd-o.ps1 -ProjectDir <dir> [-Spec <file>] [-MaxIterations <num>] [-Timeout <seconds>] [-IdleTimeout <seconds>] [-Model <model>] [-InitModel <model>] [-CodeModel <model>] [-NoClean] [-QuitOnAbort <num>] [-Help]'
	Write-Host ''
	Write-Host 'Options:'
	Write-Host '  -ProjectDir       Project directory (required)'
	Write-Host '  -Spec             Specification file (optional for existing codebases, required for new projects)'
	Write-Host '  -MaxIterations    Maximum iterations (optional, unlimited if not specified)'
	Write-Host '  -Timeout          Timeout in seconds (optional, default: 600)'
	Write-Host '  -IdleTimeout      Abort if opencode produces no output for N seconds (optional, default: 300)'
	Write-Host '  -Model            Model to use (optional)'
	Write-Host '  -InitModel        Model to use for initializer/onboarding prompts (optional, overrides -Model)'
	Write-Host '  -CodeModel        Model to use for coding prompt (optional, overrides -Model)'
	Write-Host '  -NoClean          Skip log cleaning on exit (optional)'
	Write-Host '  -QuitOnAbort      Quit after N consecutive failures (optional, default: 0=continue indefinitely)'
	Write-Host '  -Help             Show this help message'
	Write-Host ''
	exit 0
}

# Check required parameters
if ($ProjectDir -eq '') {
	Write-Error 'Error: Missing required argument -ProjectDir'
	Write-Host 'Use -Help for usage information'
	exit 1
}

# Function to find or create metadata directory
function Find-OrCreateMetadataDir {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Directory
	)

	# Check for existing directories in order of preference
	$aiddDir = Join-Path $Directory '.aidd'
	if (Test-Path $aiddDir -PathType Container) {
		return $aiddDir
	}

	# Migrate legacy metadata to .aidd as needed
	$autooDir = Join-Path $Directory '.autoo'
	if (Test-Path $autooDir -PathType Container) {
		Write-Host "Migrating legacy .autoo directory to .aidd..."
		New-Item -Path $aiddDir -ItemType Directory -Force | Out-Null
		Copy-Item -Path "$autooDir\*" -Destination $aiddDir -Recurse -ErrorAction SilentlyContinue
		return $aiddDir
	}

	$automakerDir = Join-Path $Directory '.automaker'
	if (Test-Path $automakerDir -PathType Container) {
		Write-Host "Migrating legacy .automaker directory to .aidd..."
		New-Item -Path $aiddDir -ItemType Directory -Force | Out-Null
		Copy-Item -Path "$automakerDir\*" -Destination $aiddDir -Recurse -ErrorAction SilentlyContinue
		return $aiddDir
	}

	# Create .aidd as default
	New-Item -Path $aiddDir -ItemType Directory -Force | Out-Null
	return $aiddDir
}

# Function to check if directory is an existing codebase
function Test-ExistingCodebase {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Directory
	)

	if (Test-Path $Directory -PathType Container) {
		# Check if directory has files excluding common ignored directories
		$hasFiles = Get-ChildItem -Path $Directory -Force | Where-Object {
			$_.Name -notin @('.git', '.aidd', '.auto', '.autok', '.automaker', '.autoo', '.DS_Store', 'node_modules', '.vscode', '.idea')
		} | Measure-Object | Select-Object -ExpandProperty Count

		return $hasFiles -gt 0
	}
	return $false
}

# Check if spec is required (only for new projects or when metadata dir doesn't have spec.txt)
$NeedsSpec = $false
$MetadataDir = Find-OrCreateMetadataDir -Directory $ProjectDir
if ((-not (Test-Path $ProjectDir -PathType Container)) -or (-not (Test-ExistingCodebase -Directory $ProjectDir))) {
	$NeedsSpec = $true
}

if ($NeedsSpec -and $Spec -eq '') {
	Write-Error 'Error: Missing required argument -Spec (required for new projects or when spec.txt does not exist)'
	Write-Host 'Use -Help for usage information'
	exit 1
}

$effectiveInitModel = $Model
if ($InitModel -ne '') { $effectiveInitModel = $InitModel }

$effectiveCodeModel = $Model
if ($CodeModel -ne '') { $effectiveCodeModel = $CodeModel }

function Invoke-OpenCodePrompt {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ProjectDir,

		[Parameter(Mandatory = $true)]
		[string]$PromptPath,

		[Parameter(Mandatory = $false)]
		[string]$EffectiveModel
	)

	$opencodeArgs = @('run')
	if ($EffectiveModel -ne '') { $opencodeArgs += @('--model', $EffectiveModel) }

	$promptText = Get-Content -Path $PromptPath -Raw

	$noAssistantPattern = 'The model returned no assistant messages'
	$providerErrorPattern = 'Provider returned error'

	$sawNoAssistant = $false
	$sawIdleTimeout = $false
	$sawProviderError = $false

	# Start opencode process
	$processInfo = New-Object System.Diagnostics.ProcessStartInfo
	$processInfo.FileName = 'opencode'
	$processInfo.Arguments = $opencodeArgs -join ' '
	$processInfo.WorkingDirectory = $ProjectDir
	$processInfo.UseShellExecute = $false
	$processInfo.RedirectStandardInput = $true
	$processInfo.RedirectStandardOutput = $true
	$processInfo.RedirectStandardError = $true
	$processInfo.CreateNoWindow = $true

	$process = New-Object System.Diagnostics.Process
	$process.StartInfo = $processInfo
	$process.Start() | Out-Null

	# Write prompt to stdin
	$process.StandardInput.Write($promptText)
	$process.StandardInput.Close()

	# Create async readers for stdout and stderr
	$stdoutBuilder = New-Object System.Text.StringBuilder
	$stderrBuilder = New-Object System.Text.StringBuilder

	$stdoutReadComplete = $false
	$stderrReadComplete = $false

	$outputLines = @()

	$stdoutTask = {
		param($process, $stdoutBuilder, $outputLines, $noAssistantPattern, $providerErrorPattern)
		while (-not $process.StandardOutput.EndOfStream) {
			$line = $process.StandardOutput.ReadLine()
			if ($null -ne $line) {
				[void]$stdoutBuilder.AppendLine($line)
				$outputLines += $line
				Write-Output $line

				if ($line -like "*$noAssistantPattern*") {
					return 70
				}
				if ($line -like "*$providerErrorPattern*") {
					return 72
				}
			}
		}
		return $null
	}

	$stderrTask = {
		param($process, $stderrBuilder)
		while (-not $process.StandardError.EndOfStream) {
			$line = $process.StandardError.ReadLine()
			if ($null -ne $line) {
				[void]$stderrBuilder.AppendLine($line)
				Write-Error $line
			}
		}
	}

	$stdoutHandle = $stdoutTask.BeginInvoke($process, $stdoutBuilder, $outputLines, $noAssistantPattern, $providerErrorPattern, $null, $null)
	$stderrHandle = $stderrTask.BeginInvoke($process, $stderrBuilder, $null, $null)

	$lastOutputTime = Get-Date

	while (-not $process.HasExited) {
		Start-Sleep -Milliseconds 100

		if ($outputLines.Count -gt 0) {
			$lastOutputTime = Get-Date
		} else {
			$elapsed = (Get-Date) - $lastOutputTime
			if ($elapsed.TotalSeconds -ge $IdleTimeout) {
				Write-Error "aidd-o.ps1: idle timeout (${IdleTimeout}s) waiting for opencode output; aborting."
				$sawIdleTimeout = $true
				$process.Kill()
				break
			}
		}

		if ($stdoutHandle.IsCompleted) {
			$result = $stdoutTask.EndInvoke($stdoutHandle)
			if ($result -eq 70) {
				Write-Error "aidd-o.ps1: detected 'no assistant messages' from model; aborting."
				$sawNoAssistant = $true
				$process.Kill()
				break
			}
			if ($result -eq 72) {
				Write-Error "aidd-o.ps1: detected 'provider error' from model; aborting."
				$sawProviderError = $true
				$process.Kill()
				break
			}
			$stdoutReadComplete = $true
		}

		if ($stderrHandle.IsCompleted) {
			$stderrTask.EndInvoke($stderrHandle)
			$stderrReadComplete = $true
		}
	}

	$process.WaitForExit()
	$exitCode = $process.ExitCode

	if ($sawNoAssistant) {
		return 70
	}

	if ($sawIdleTimeout) {
		return 71
	}

	if ($sawProviderError) {
		return 72
	}

	return $exitCode
}

function Get-NextIterationLogIndex {
	param(
		[Parameter(Mandatory = $true)]
		[string]$IterationsDir
	)

	$max = 0
	if (Test-Path $IterationsDir -PathType Container) {
		Get-ChildItem -Path $IterationsDir -Filter '*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
			$name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
			if ($name -match '^[0-9]+$') {
				$num = [int]$name
				if ($num -gt $max) { $max = $num }
			}
		}
	}

	return ($max + 1)
}

# Function to clean logs on exit
function Clear-IterationLogs {
	param(
		[Parameter(Mandatory = $true)]
		[string]$IterationsDir
	)

	if ($NoClean) {
		Write-Host 'Skipping log cleanup (-NoClean flag set).'
		return
	}

	Write-Host 'Cleaning iteration logs...'
	if ((Test-Path $IterationsDir -PathType Container) -and (Get-ChildItem -Path $IterationsDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
		$CleanLogsScript = Join-Path $PSScriptRoot 'clean-logs.js'
		& node $CleanLogsScript $IterationsDir --no-backup
		Write-Host 'Log cleanup complete.'
	}
}

# Function to copy artifacts to metadata directory
function Copy-Artifacts {
	param(
		[Parameter(Mandatory = $true)]
		[string]$ProjectDir
	)

	$ProjectMetadataDir = Find-OrCreateMetadataDir -Directory $ProjectDir
	Write-Host "Copying artifacts to '$ProjectMetadataDir'..."
	$ArtifactsSource = Join-Path $PSScriptRoot 'artifacts'
	New-Item -ItemType Directory -Path $ProjectMetadataDir -Force | Out-Null
	# Copy all artifacts contents, but don't overwrite existing files
	Get-ChildItem -Path $ArtifactsSource -Force | ForEach-Object {
		$DestinationPath = Join-Path $ProjectMetadataDir $_.Name
		if (-not (Test-Path $DestinationPath)) {
			Copy-Item -Path $_.FullName -Destination $ProjectMetadataDir -Recurse
		}
	}
}

# Set up trap to clean logs on script exit (both normal and interrupted)
$cleanupScript = {
	Clear-IterationLogs -IterationsDir $IterationsDir
}
# Register cleanup for normal exit, Ctrl+C, and script termination
try {
	$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupScript -ErrorAction SilentlyContinue
} catch { }
# Handle Ctrl+C
[Console]::TreatControlCAsInput = $false

# Ensure project directory exists (create if missing)
if (-not (Test-Path $ProjectDir -PathType Container)) {
	Write-Host "Project directory '$ProjectDir' does not exist; creating it..."
	New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
	$script:NewProjectCreated = $true

	# Copy scaffolding files to the new project directory (including hidden files)
	Write-Host "Copying scaffolding files to '$ProjectDir'..."
	$ScaffoldingSource = Join-Path $PSScriptRoot 'scaffolding'
	# Copy both regular and hidden files
	Get-ChildItem -Path $ScaffoldingSource -Force | ForEach-Object {
		Copy-Item -Path $_.FullName -Destination $ProjectDir -Recurse -Force
	}

	# Copy artifacts contents to project's metadata folder
	Write-Host "Copying artifacts to '$MetadataDir'..."
	$ArtifactsSource = Join-Path $PSScriptRoot 'artifacts'
	New-Item -ItemType Directory -Path $MetadataDir -Force | Out-Null
	# Copy all artifacts contents
	Get-ChildItem -Path $ArtifactsSource -Force | ForEach-Object {
		Copy-Item -Path $_.FullName -Destination $MetadataDir -Recurse -Force
	}
} else {
	$script:NewProjectCreated = $false
	# Check if this is an existing codebase
	if (Test-ExistingCodebase -Directory $ProjectDir) {
		Write-Host "Detected existing codebase in '$ProjectDir'"
	}
}

# Check if spec file exists (only if provided)
if ($Spec -ne '' -and (-not (Test-Path $Spec -PathType Leaf))) {
	Write-Error "Error: Spec file '$Spec' does not exist"
	exit 1
}

# Define the paths to check
$SpecCheckPath = Join-Path $MetadataDir 'spec.txt'
$FeatureListCheckPath = Join-Path $MetadataDir 'feature_list.json'

# Iteration transcript logs
$IterationsDir = Join-Path $MetadataDir 'iterations'
New-Item -ItemType Directory -Path $IterationsDir -Force | Out-Null
$NextLogIndex = Get-NextIterationLogIndex -IterationsDir $IterationsDir

$ConsecutiveFailures = 0

# Initialize onboarding state check (persist across iterations)
$OnboardingComplete = $false
if (Test-Path $FeatureListCheckPath -PathType Leaf) {
	# Check if feature_list.json contains actual data (not just template)
	$content = Get-Content $FeatureListCheckPath -Raw
	if ($content -notmatch '\{yyyy-mm-dd\}' -and $content -notmatch '\{Short name of the feature\}') {
		$OnboardingComplete = $true
	}
}

# Check for metadata dir/spec.txt
try {
	if ($MaxIterations -eq 0) {
		Write-Host 'Running unlimited iterations (use Ctrl+C to stop)'
		$i = 1
		while ($true) {
			$logFile = Join-Path $IterationsDir ('{0}.log' -f $NextLogIndex.ToString('D3'))
			$NextLogIndex++

			Write-Host "Iteration $i"
			Write-Host "Transcript: $logFile"
			Write-Host "Started: $(Get-Date -Format o)"
		  
			try {
				Start-Transcript -Path $logFile -Force | Out-Null
		  
				$opencodeExitCode = 0
				# Determine which prompt to send based on project state
				if ($OnboardingComplete -and (Test-Path $FeatureListCheckPath -PathType Leaf)) {
					# Onboarding is complete, ready for coding
					Write-Host 'Onboarding complete, sending coding prompt...'
					$opencodeExitCode = Invoke-OpenCodePrompt -ProjectDir $ProjectDir -PromptPath "$PSScriptRoot/prompts/coding.md" -EffectiveModel $effectiveCodeModel
				} elseif ($script:NewProjectCreated -and $Spec -ne '') {
					# New project with spec file - use initializer
					Write-Host 'New project detected, copying spec and sending initializer prompt...'
					Copy-Artifacts -ProjectDir $ProjectDir
					if ($Spec -ne '') {
						Copy-Item $Spec $SpecCheckPath
					}
					$opencodeExitCode = Invoke-OpenCodePrompt -ProjectDir $ProjectDir -PromptPath "$PSScriptRoot/prompts/initializer.md" -EffectiveModel $effectiveInitModel
				} elseif (Test-ExistingCodebase -Directory $ProjectDir) {
					# Existing codebase that needs onboarding
					if (-not $OnboardingComplete) {
						Write-Host 'Detected incomplete onboarding, resuming onboarding prompt...'
					} else {
						Write-Host 'Detected existing codebase without feature_list, using onboarding prompt...'
					}
					Copy-Artifacts -ProjectDir $ProjectDir
					$opencodeExitCode = Invoke-OpenCodePrompt -ProjectDir $ProjectDir -PromptPath "$PSScriptRoot/prompts/onboarding.md" -EffectiveModel $effectiveInitModel
				} else {
					# New project without spec file - use initializer
					Write-Host 'No spec provided, sending initializer prompt...'
					Copy-Artifacts -ProjectDir $ProjectDir
					$opencodeExitCode = Invoke-OpenCodePrompt -ProjectDir $ProjectDir -PromptPath "$PSScriptRoot/prompts/initializer.md" -EffectiveModel $effectiveInitModel
				}

				if ($opencodeExitCode -ne 0) {
					$ConsecutiveFailures++
					Write-Error "aidd-o.ps1: opencode failed (exit=$opencodeExitCode); this is failure #$ConsecutiveFailures."
					if ($QuitOnAbort -gt 0 -and $ConsecutiveFailures -ge $QuitOnAbort) {
						Write-Error "aidd-o.ps1: reached failure threshold ($QuitOnAbort); quitting."
						exit $opencodeExitCode
					}
					Write-Error "aidd-o.ps1: continuing to next iteration (threshold: $QuitOnAbort)."
				} else {
					$ConsecutiveFailures = 0
				}

				Write-Host "--- End of iteration $i ---"
				Write-Host "Finished: $(Get-Date -Format o)"
				Write-Host ''
			} finally {
				try { Stop-Transcript | Out-Null } catch { }
			}
 
			$i++
		}
	} else {
		Write-Host "Running $MaxIterations iterations"
		for ($i = 1; $i -le $MaxIterations; $i++) {
			$logFile = Join-Path $IterationsDir ('{0}.log' -f $NextLogIndex.ToString('D3'))
			$NextLogIndex++
		  
			Write-Host "Iteration $i of $MaxIterations"
			Write-Host "Transcript: $logFile"
			Write-Host "Started: $(Get-Date -Format o)"
			Write-Host ''
		  
			try {
				Start-Transcript -Path $logFile -Force | Out-Null
		  
				$opencodeExitCode = 0
				# Determine which prompt to send based on project state
				if ($OnboardingComplete -and (Test-Path $FeatureListCheckPath -PathType Leaf)) {
					# Onboarding is complete, ready for coding
					Write-Host 'Onboarding complete, sending coding prompt...'
					$opencodeExitCode = Invoke-OpenCodePrompt -ProjectDir $ProjectDir -PromptPath "$PSScriptRoot/prompts/coding.md" -EffectiveModel $effectiveCodeModel
				} elseif ($script:NewProjectCreated -and $Spec -ne '') {
					# New project with spec file - use initializer
					Write-Host 'New project detected, copying spec and sending initializer prompt...'
					Copy-Artifacts -ProjectDir $ProjectDir
					if ($Spec -ne '') {
						Copy-Item $Spec $SpecCheckPath
					}
					$opencodeExitCode = Invoke-OpenCodePrompt -ProjectDir $ProjectDir -PromptPath "$PSScriptRoot/prompts/initializer.md" -EffectiveModel $effectiveInitModel
				} elseif (Test-ExistingCodebase -Directory $ProjectDir) {
					# Existing codebase that needs onboarding
					if (-not $OnboardingComplete) {
						Write-Host 'Detected incomplete onboarding, resuming onboarding prompt...'
					} else {
						Write-Host 'Detected existing codebase without feature_list, using onboarding prompt...'
					}
					Copy-Artifacts -ProjectDir $ProjectDir
					$opencodeExitCode = Invoke-OpenCodePrompt -ProjectDir $ProjectDir -PromptPath "$PSScriptRoot/prompts/onboarding.md" -EffectiveModel $effectiveInitModel
				} else {
					# New project without spec file - use initializer
					Write-Host 'No spec provided, sending initializer prompt...'
					Copy-Artifacts -ProjectDir $ProjectDir
					$opencodeExitCode = Invoke-OpenCodePrompt -ProjectDir $ProjectDir -PromptPath "$PSScriptRoot/prompts/initializer.md" -EffectiveModel $effectiveInitModel
				}

				if ($opencodeExitCode -ne 0) {
					$ConsecutiveFailures++
					Write-Error "aidd-o.ps1: opencode failed (exit=$opencodeExitCode); this is failure #$ConsecutiveFailures."
					if ($QuitOnAbort -gt 0 -and $ConsecutiveFailures -ge $QuitOnAbort) {
						Write-Error "aidd-o.ps1: reached failure threshold ($QuitOnAbort); quitting."
						exit $opencodeExitCode
					}
					Write-Error "aidd-o.ps1: continuing to next iteration (threshold: $QuitOnAbort)."
				} else {
					$ConsecutiveFailures = 0
				}

				# If this is not the last iteration, add a separator
				if ($i -lt $MaxIterations) {
					Write-Host "--- End of iteration $i ---"
					Write-Host "Finished: $(Get-Date -Format o)"
					Write-Host ''
				} else {
					Write-Host "Finished: $(Get-Date -Format o)"
					Write-Host ''
				}
			} finally {
				try { Stop-Transcript | Out-Null } catch { }
			}
		}
	}
} finally {
	# Ensure cleanup runs even on error or interruption
	Clear-IterationLogs -IterationsDir $IterationsDir
}
