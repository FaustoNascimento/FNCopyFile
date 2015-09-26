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
		[Switch] $Force
	)

	Begin
	{
		function InternalCopyToSession
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

				[Switch] $Force
			)

			try
			{
				Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock `
                {
                    if ((Test-Path -Path $using:DestinationFile -PathType Leaf) -and -not $using:Force)
                    {
                        if (-not $using:Force)
                        {
                            Write-Error 'File already exists.'
                            return
                        }
                    }

                    $writeStream = ([IO.FileInfo]$using:DestinationFile).Open([IO.FileMode]::Create)
                }

				$readStream = [IO.File]::OpenRead($SourceFile)
				
				# Initial buffer size
				if ($BufferSize -gt $readStream.Length)
				{
					$BufferSize = $readStream.Length
				}

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

					Invoke-Command -Session $Session -ScriptBlock {$writeStream.Write($using:buffer, 0, $using:BufferSize)} -ErrorAction Stop
					Write-Progress -Activity "Copying $SourceFile to $DestinationFile over WinRM, BufferSize = $BufferSize" -PercentComplete ($readStream.Position / $readStream.Length * 100) -Status "$($readStream.Position) / $($readStream.Length) bytes processed"
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

				Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock `
                {
                    if ($writeStream)
                    {
                        $writeStream.Close()

                        [GC]::Collect()
                    }
                }
			}
		}
	}

	Process
	{
		$Source = Convert-Path $Source -ErrorAction SilentlyContinue

		# If $source doesn't exist, exit
		if ($Source)
		{
			$PSCmdlet.WriteError((New-ErrorRecord -ErrorMessage "Source path not found: '$Source'" -ErrorCategory ObjectNotFound))
			return
		}

		# We have the try up here so we can have a finally block where we check if the session needs closing
		# This means that even if the command is aborted, the finally statement is always executed and we don't leave PSSessions lingering around
		try
		{
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
						
			# We need to use Convert-Path at the destination to ensure we're not dealing with a relative path, but this needs to be invoked on the remote computer
			# Since if it is a relative path, it will be relative to the remote computer.
			$Destination = Invoke-Command -Session $Session -ErrorAction Stop -Command `
			{
				$destination = Convert-Path $using:Destination -ErrorAction SilentlyContinue -ErrorVariable tempError

				if (!$destination)
				{
					if ($tempError[0].FullyQualifiedErrorId -eq 'PathNotFound,Microsoft.PowerShell.Commands.ConvertPathCommand')
					{
						$destination = $tempError[0].TargetObject
					}
				}

				return $destination
			}
			
			# If $Source is a container
			if (Test-Path $Source -PathType Container)
			{
				$directories = Get-ChildItem -Path $Source -Recurse -Directory -Force

                Push-Location $Source
                foreach ($directory in $directories)
                {
                    $destinationDirectory = Join-Path $Destination (Resolve-Path $directory.FullName -Relative)
                    
                    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock `
                    {
                        if (-not (Test-Path $using:destinationDirectory -PathType Container))
                        {
                            [void] (New-Item -Path $using:destinationDirectory -ItemType Directory -Force -ErrorAction Stop)
                        }
                    }

                    $files = Get-ChildItem -Path $directory.FullName -File -Force

                    foreach ($file in $files)
                    {
                        $destinationFile = Join-Path $destinationDirectory $file.Name
                        InternalCopyToSession -Source $file.FullName -Destination $destinationFile -BufferSize $BufferSize -Force:$Force -Session $Session
                    }
                }
			}
			else
			{
				InternalCopyToSession -SourceFile $Source -DestinationFile $Destination -BufferSize $BufferSize -Force:$Force -Session $Session
			}
		}
		catch
		{
			throw $_
		}
		finally
		{
			# If we created our own PSSession, let's close it.
			if ($ComputerName -and $Session)
			{
				Remove-PSSession -Session $Session
			}

            Pop-Location
		}
	}
}

function Copy-FNFileFromSession
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
		[Switch] $Force
	)

    Begin
	{
		function InternalCopyFromSession
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

				[Switch] $Force
			)

            try
            {
                if ((Test-Path -Path $DestinationFile -PathType Leaf) -and -not $Force)
	            {
		            if (-not $Force)
		            {
			            Write-Error 'File already exists.'
			            return
		            }
	            }

	            $writeStream = ([IO.FileInfo]$DestinationFile).Open([IO.FileMode]::Create)

                $totalBytes = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock `
                {
                    $readStream = [IO.File]::OpenRead($using:SourceFile)

                    #Initial buffer size
                    $bufferSize = $using:BufferSize

                    if ($bufferSize -gt $readStream.Length)
				    {
					    $bufferSize = $readStream.Length
				    }

				    $buffer = New-Object byte[] $bufferSize

                    $readStream.Length
                }

                $bytesWritten = 0

                while ($bytesWritten -lt $totalBytes)
                {
                    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock `
                    {
                        # If the number of remaining bytes to read is lower than the buffer size, we set our buffer size accordingly and redim our array
					    if ($bufferSize -gt $readStream.Length - $readStream.Position)
					    {
						    $bufferSize = $readStream.Length - $readStream.Position
						    $buffer = New-Object byte[] $bufferSize
					    }

                        $bytesRead = 0

                        # We do this to ensure that we always have a full buffer array
					    while ($bytesRead -lt $bufferSize)
					    {
						    $bytesRead += $readStream.Read($buffer, $bytesRead, $bufferSize - $bytesRead)
					    }
                        
                        # Cheap way to stop the pipeline from expanding the $buffer
                        @{'buffer' = $buffer}
                    } | ForEach-Object {
                        $writeStream.Write($_.Buffer, 0, $_.Buffer.Length)
                        
                        $bytesWritten += $_.Buffer.Length
                        Write-Progress -Activity "Copying $SourceFile to $DestinationFile over WinRM, BufferSize = $($_.Buffer.Length)" -PercentComplete ($bytesWritten / $totalBytes * 100) -Status "$bytesWritten / $totalBytes bytes processed"
                    }
                }
            }
            catch
			{
				throw $_
			}
			finally
			{
				if ($writeStream)
				{
		            $writeStream.Close()
	            }

				Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock `
                {             
                    if ($readStream)
                    {
                        $readStream.Close()

                        [GC]::Collect()
                    }
                }
			}
        }
    }

    Process
	{
        # We have the try up here so we can have a finally block where we check if the session needs closing
		# This means that even if the command is aborted, the finally statement is always executed and we don't leave PSSessions lingering around
		try
		{
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

            # Expand $Source to ensure we are not dealing with relative paths
			$Source = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {Convert-Path $using:Source}

			# If $source doesn't exist, exit
		    if (!$Source)
		    {
			    $PSCmdlet.WriteError((New-ErrorRecord -ErrorMessage "Source path not found: '$Source'" -ErrorCategory ObjectNotFound))
			    return
		    }

			$Destination = Convert-Path $Destination -ErrorAction SilentlyContinue -ErrorVariable tempError

			if (!$Destination)
			{
				if ($tempError[0].FullyQualifiedErrorId -eq 'PathNotFound,Microsoft.PowerShell.Commands.ConvertPathCommand')
				{
					$Destination = $tempError[0].TargetObject
				}
			}
			
            # If $source is a container
            if (Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {Test-Path $using:Source -PathType Container})
            {
                $directories = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {Get-ChildItem -Path $using:Source -Recurse -Directory -Force}
                
				# Push location to our source path
                Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {Push-Location $using:Source}

                foreach ($directory in $directories)
                {
                    $destinationDirectory = Join-Path $Destination (Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {Resolve-Path $using:directory.FullName -Relative})
                    
                    if (-not (Test-Path $destinationDirectory -PathType Container))
                    {
                        [void] (New-Item -Path $destinationDirectory -ItemType Directory -Force -ErrorAction Stop)
                    }

                    $files = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {Get-ChildItem -Path $using:directory.FullName -File -Force}

                    foreach ($file in $files)
                    {
                        $destinationFile = Join-Path $destinationDirectory $file.Name
                        InternalCopyFromSession -SourceFile $file.FullName -DestinationFile $destinationFile -BufferSize $BufferSize -Force:$Force -Session $Session
                    }
                }
            }
            else
            {
                InternalCopyFromSession -SourceFile $Source -DestinationFile $Destination -BufferSize $BufferSize -Force:$Force -Session $Session
            }
        }
        catch
		{
			throw $_
		}
		finally
		{
			if ($Session)
            {
                Invoke-Command -Session $Session -ScriptBlock {Pop-Location}

                # If we created our own PSSession, let's close it.
			    if ($ComputerName)
			    {
				    Remove-PSSession -Session $Session
			    }
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
