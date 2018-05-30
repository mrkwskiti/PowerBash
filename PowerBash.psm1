$script:thisModulePath = $MyInvocation.MyCommand.ScriptBlock.Module.Path

function ConvertTo-LinuxPath
{
    param(
        [Parameter(Position=0, Mandatory=$true)]
        [string]$Path
    )

    if($Path.StartsWith("\\"))
    {
        Write-Error "UNC paths not currently supported"
        return
    }

    if($Path -match "^(\`"?)([A-Za-z])\:\\")
    {
        $quote = $Matches[1]
        $driveLetter = $Matches[2]

        if($driveLetter)
        {
            $Path = $Path -replace "^$quote$driveLetter\:\\","$quote/mnt/$($driveLetter.ToLower())/"
        }
    }

    $Path = $Path -replace "\\","/"
    $Path = $Path -replace " ","\ "
    $Path = $Path -replace "\(","\("
    $Path = $Path -replace "\)","\)"

    $Path
}
Set-Alias lxp ConvertTo-LinuxPath

function Get-AllBashApps
{
    $bashFSRoot = "$env:LOCALAPPDATA\Packages\CanonicalGroupLimited.UbuntuonWindows_79rhkp1fndgsc\LocalState\rootfs"
    $bashPATH = "/usr/local/sbin","/usr/local/bin","/usr/sbin","/usr/bin","/sbin","/bin","/usr/lib/gcc/x86_64-linux-gnu/5","/usr/games"
    $allBashApps = @()
    foreach($path in $bashPATH)
    {
        $allBashApps += Get-ChildItem "$bashFSRoot$path" | ?{ $_.Extension -eq "" -and ("[") -notcontains $_.Name } |
                            Foreach-Object { [pscustomobject]@{ Name = $_.Name; Path = "$path/$($_.Name)" } }
    }

    $allBashApps
}

function Add-BashWrappers
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0, Mandatory=$true)]
        $BashApps,
        [Parameter(Position=1, Mandatory=$false)]
        [string[]]$Overwrite=@()
    )

    $allPSCommandsHash = @{}
    foreach($c in ((Get-Command *).Name -replace "\.exe$","" | Where-Object { $Overwrite -notcontains $_ })){ $allPSCommandsHash[$c] = $true; }

    $BashApps | Where-Object { !$allPSCommandsHash[$_.Name] } -pv app |
        % { 
              New-Item -Path function: -Name $app.Name -Value {
                  begin
                  {
                      $allPipeArgs = @()

                      $hasPipeForward = $false
                      $invocationInfos = (Get-PSCallStack).InvocationInfo
                      foreach($invocation in ($invocationInfos | Select-Object -SkipLast 1))
                      {
                          if($hasPipeForward)
                          {
                              break
                          }

                          $hasPipeForward = ($invocation.PipelinePosition -ne $invocation.PipelineLength)
                          if(!$hasPipeForward)
                          {
                              $ast = [Management.Automation.Language.Parser]::ParseInput($invocation.Line, [ref]$null, [ref]$null)
                              $commandOffset = $invocation.OffsetInLine
                              $pipelineAst = $ast.EndBlock.Statements | Where-Object { $_.Extent.StartColumnNumber -le $commandOffset -and $_.Extent.EndColumnNumber -gt $commandOffset }
                              if($pipelineAst -isnot [System.Management.Automation.Language.PipelineAst])
                              {
                                  $hasPipeForward = $true
                              }
                              else
                              {
                                  $commandAst = $pipelineAst.PipelineElements | Where-Object { $_.Extent.StartColumnNumber -le $commandOffset -and $_.Extent.EndColumnNumber -gt $commandOffset }

                                  $hasPipeForward = (($commandAst -isnot [System.Management.Automation.Language.CommandAst]) -or ($commandAst.Redirections.Length -gt 0))
                              }
                          }
                      }
                  }

                  process
                  {
                      foreach($i in $input)
                      {
                          $hasPipeArgs = $true
                          $allPipeArgs += $i
                      }
                  }

                  end
                  {
                      try
                      {
                          $bashArgs = @()
                          foreach($a in $args)
                          {
                              if($a -ne "--%")
                              {
                                  $bashArgs += $a
                              }
                          }

                          $bashCommandStr = "$($app.Path) $bashArgs".Trim()
                          if($hasPipeArgs)
                          {
                              $tempStdIn = (New-TemporaryFile).FullName
                              [IO.File]::WriteAllLines($tempStdIn, $allPipeArgs)

                              $linuxStdIn = ConvertTo-LinuxPath $tempStdIn
                              $bashCommandStr += " <$linuxStdIn"
                          }

                          if($hasPipeForward)
                          {
                              $tempStdOut = (New-TemporaryFile).FullName
                              $tempStdErr = (New-TemporaryFile).FullName
                              $linuxStdOut = ConvertTo-LinuxPath $tempStdOut
                              $linuxStdErr = ConvertTo-LinuxPath $tempStdErr

                              $bashCommandStr += " >$linuxStdOut 2>$linuxStdErr"
                              $cmdCommandStr = "bash.exe -c `"$bashCommandStr`""
                              $p = start-process "cmd" -ArgumentList "/c",$cmdCommandStr -WindowStyle Hidden -PassThru
                              while(!$p.HasExited){ Start-Sleep -Milliseconds 1 }
                          }
                          else
                          {
                              bash.exe -c "$bashCommandStr"
                          }
                      }
                      finally
                      {
                          if($tempStdOut -and (Test-Path $tempStdOut))
                          {
                              Get-Content $tempStdOut
                              Remove-Item $tempStdOut
                          }

                          if($tempStdErr -and (Test-Path $tempStdErr))
                          {
                              Get-Content $tempStdErr | Write-Error
                              Remove-Item $tempStdErr
                          }

                          if($tempStdIn -and (Test-Path $tempStdIn))
                          {
                              Remove-Item $tempStdIn
                          }
                      }

                      if(($bashArgs.Length -ge 3 -and $app.Name -eq "sudo" -and $bashArgs[0] -eq "apt-get" -and $bashArgs[1] -eq "install") -or
                          ($bashArgs.Length -ge 2 -and $app.Name -eq "apt-get" -and $bashArgs[0] -eq "install"))
                      {
                          Import-Module $script:thisModulePath -Force -Global 3>$null
                      }
                  }
             }.GetNewClosure()
            
            Export-ModuleMember -Function $app.Name
            $allPSCommandsHash[$app.Name] = $true
        }
}

$script:allBashApps = Get-AllBashApps
. Add-BashWrappers $script:allBashApps $args

Set-PSReadlineKeyHandler -Key "Alt+l" `
                         -ScriptBlock {
    param($key, $arg)

    $ast = $null
    $tokens = $null
    $errors = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$ast, [ref]$tokens, [ref]$errors, [ref]$cursor)

    $tokenToChange = $null
    foreach ($token in $tokens)
    {
        $extent = $token.Extent
        if ($extent.StartOffset -le $cursor -and $extent.EndOffset -ge $cursor)
        {
            $tokenToChange = $token

            if ($extent.EndOffset -eq $cursor -and $foreach.MoveNext())
            {
                $nextToken = $foreach.Current
                if ($nextToken.Extent.StartOffset -eq $cursor)
                {
                    $tokenToChange = $nextToken
                }
            }
            break
        }
    }

    if ($tokenToChange -ne $null)
    {
        $extent = $tokenToChange.Extent
        $tokenText = $extent.Text
        $replacement = ConvertTo-LinuxPath $tokenText

        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
            $extent.StartOffset,
            $tokenText.Length,
            $replacement)
    }
}

Export-ModuleMember -Function ConvertTo-LinuxPath
Export-ModuleMember -Alias lxp
