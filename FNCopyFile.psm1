function Copy-FNFileToSession
{
	[CmdletBinding()]

	param
	(
		[Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
		[Alias('PSPath')]
		[String] $Source,

		[Parameter(Mandatory, ValueFromPipelineByPropertyName, Position = 1)]
		[String] $Destination,

		[Parameter(Mandatory, ValueFromPipelineByPropertyName, Position = 2, ParameterSetName = 'ComputerName')]
		[String] $ComputerName,

		[Parameter(Mandatory, ValueFromPipelineByPropertyName, Position = 2, ParameterSetName = 'Session')]
		[System.Management.Automation.Runspaces.PSSession] $Session,

		[Parameter(ValueFromPipelineByPropertyName)]
		[Int] $BufferSize = 4MB,

		[Parameter(ValueFromPipelineByPropertyName)]
		[Switch] $Force,

		[Parameter(ValueFromPipelineByPropertyName)]
		[Int] $FileLockedMaxTries = 100
	)

	Begin
	{
		function InternalCopyFile
		{
			[CmdletBinding()]

			param
			(
				[Parameter(Mandatory)]
				[String] $SourceFile,

				[Parameter(Mandatory)]
				[String] $DestinationFile,

				[Parameter(Mandatory)]
				[System.Management.Automation.Runspaces.PSSession] $Session,

				[Int] $BufferSize,

				[Switch] $Force,

				[Int] $FileLockedMaxTries
			)

			$scriptBlockChecks = {
				$destinationFolder = ([IO.FileInfo] $using:destinationFile).Directory.FullName
			
				if (-not (Test-Path -Path $destinationFolder -PathType Container))
				{
					if ($using:Force)
					{
						[void] (New-Item -Path $destinationFolder -ItemType Directory -Force -ErrorAction Stop)
					}
					else
					{
						Write-Error 'Destination folder not found'
						return
					}
				}

				if ((Test-Path -Path $using:destinationFile -PathType Leaf) -and -not $using:Force)
				{
					Write-Error 'File already exists.'
					return
				}
			}

			$scriptBlockCopy = {
				try
				{
					if ($using:create)
					{
						[IO.File]::WriteAllBytes($using:DestinationFile, $using:buffer)
					}
					else
					{
						# If explorer is open on the folder we're copying the files to, it can have the file open for reading to determine it's size, 
						# causing an error because the file is open by another process
						# So if it fails to create the FileStream, we wait a bit and try again.
						$tries = 0
						
						do
						{
							try
							{
								$writeStream = New-Object IO.FileStream($using:DestinationFile, [IO.FileMode]::Append)
							}
							catch
							{
								$tries += 1

								if ($tries -ge $using:FileLockedMaxTries)
								{
									throw $_
								}

								Start-Sleep -Milliseconds 10
							}
						} while (-not $writeStream)

						$writeStream.Write($using:buffer, 0, $using:buffer.Length)
					}
				}
				catch
				{
					Write-Error -Exception $_.Exception.InnerException
				}
				finally
				{
					if ($writeStream)
					{
						$writeStream.Close()
					}

					[GC]::Collect()
				}
			}

			try
			{
				Invoke-Command -Session $Session -ScriptBlock $scriptBlockChecks -ErrorAction Stop
				
				$create = $true
				$readStream = [IO.File]::OpenRead($SourceFile)
				$buffer = New-Object byte[] $BufferSize
				
				while ($readStream.Length -gt $readStream.Position) 
				{
					# If the number of remaining bytes to read is lower than the buffer size, we set our buffer size accordingly and redim our array
					if ($BufferSize -gt $readStream.Length - $readStream.Position)
					{
						$BufferSize = $readStream.Length - $readStream.Position
						$buffer = New-Object byte[] $BufferSize
					}

					$bytesRead = 0

					# We do this to ensure that we always have a full buffer array
					while ($bytesRead -lt $BufferSize)
					{
						$bytesRead += $readStream.Read($buffer, $bytesRead, $BufferSize - $bytesRead)
					}

					Invoke-Command -Session $Session -ScriptBlock $scriptBlockCopy -ErrorAction Stop
					Write-Progress -Activity "Copying $SourceFile to $DestinationFile over WinRM, BufferSize = $BufferSize" -PercentComplete ($readStream.Position / $readStream.Length * 100) -Status "$($readStream.Position) / $($readStream.Length) bytes processed" -ParentId 1

					# Set flag to false, to stop attempting to create the file (again)
					$create = $false
				}
			}
			catch
			{
				throw $_
			}
			finally
			{
				if ($readStream)
				{
		            $readStream.Close()
	            }
			}
		}
	}

	Process
	{
		# If $source doesn't exist, exit
		if (-not (Test-Path $Source))
		{
			$PSCmdlet.WriteError((New-ErrorRecord -ErrorMessage "Source path not found: '$Source'" -ErrorCategory ObjectNotFound))
			return
		}

		# If we specified $ComputerName instead of a session, let's open the session now
		if ($ComputerName)
		{
			$Session = New-PSSession -ComputerName $ComputerName -ErrorVariable sessionError -ErrorAction SilentlyContinue

			if ($sessionError)
			{
				$PSCmdlet.WriteError((New-ErrorRecord -ErrorMessage $sessionError.Exception.Message))
				return
			}
		}
		
		try
		{
			# If $source is a container
			if (Test-Path $Source -PathType Container)
			{
				$files = Get-ChildItem -Path $Source -Recurse -File -Force

				for ($i = 0; $i -lt $files.Count; $i++)
				{
					# Build the destination file path, based on the relative $Source path
					Push-Location $Source
					$destinationFile = Join-Path $Destination (Resolve-Path $files[$i] -Relative)
					Pop-Location
				
					Write-Progress -Activity "Copying files from $Source to remote computer $($Session.ComputerName)" -Status "Processing file $file" -CurrentOperation "$i / $($files.Count)" -PercentComplete ($i / $files.Count * 100) -Id 1
					InternalCopyFile -Source $files[$i].FullName -Destination $destinationFile -BufferSize $BufferSize -Force:$Force -FileLockedMaxTries $FileLockedMaxTries -Session $Session
				}
			}
			else
			{
				InternalCopyFile -Source $Source -Destination $Destination -BufferSize $BufferSize -Force:$Force -FileLockedMaxTries $FileLockedMaxTries -Session $Session
			}
		}
		catch
		{
			throw $_
		}
		finally
		{
			# If we created our own PSSession, let's close it.
			if ($ComputerName)
			{
				Remove-PSSession -Session $Session
			}
		}
	}
}

function New-ErrorRecord
{
    [CmdletBinding(DefaultParameterSetName = 'ErrorMessageSet')]

    param
    (
        [Parameter(ValueFromPipeline = $true, Position = 0, ParameterSetName = 'ErrorMessageSet')]
        [String]$ErrorMessage,

        [Parameter(ValueFromPipeline = $true, Position = 0, ParameterSetName = 'ExceptionSet')]
        [System.Exception]$Exception,

        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 1, ParameterSetName = 'ErrorMessageSet')]
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 1, ParameterSetName = 'ExceptionSet')]
        [System.Management.Automation.ErrorCategory]$ErrorCategory = [System.Management.Automation.ErrorCategory]::NotSpecified,

        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 2, ParameterSetName = 'ErrorMessageSet')]
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 2, ParameterSetName = 'ExceptionSet')]
        [String]$ErrorId,

        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 3, ParameterSetName = 'ErrorMessageSet')]
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 3, ParameterSetName = 'ExceptionSet')]
        [Object]$TargetObject
    )
    
    Process
    {
        if (!$Exception)
        {
            $Exception = New-Object System.Exception $ErrorMessage
        }
    
        New-Object System.Management.Automation.ErrorRecord $Exception, $ErrorId, $ErrorCategory, $TargetObject
    }
}
