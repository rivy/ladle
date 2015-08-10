$scoopdir = $env:SCOOP, "~\appdata\local\scoop" | select -first 1
$globaldir = $env:SCOOP_GLOBAL, "$($env:programdata.tolower())\scoop" | select -first 1
$cachedir = "$scoopdir\cache" # always local

$envpipe = $env:SCOOP_ENVPIPE

# helper functions
function coalesce($a, $b) { if($a) { return $a } $b }
function format($str, $hash) {
	$hash.keys | % { set-variable $_ $hash[$_] }
	$executionContext.invokeCommand.expandString($str)
}
function is_admin {
	$admin = [security.principal.windowsbuiltinrole]::administrator
	$id = [security.principal.windowsidentity]::getcurrent()
	([security.principal.windowsprincipal]($id)).isinrole($admin)
}

# messages
function abort($msg) { write-host $msg -f darkred; exit 1 }
function warn($msg) { write-host $msg -f darkyellow; }
function success($msg) { write-host $msg -f darkgreen }

# dirs
function basedir($global) {	if($global) { return $globaldir } $scoopdir }
function appsdir($global) { "$(basedir $global)\apps" }
function shimdir($global) { "$(basedir $global)\shims" }
function appdir($app, $global) { "$(appsdir $global)\$app" }
function versiondir($app, $version, $global) { "$(appdir $app $global)\$version" }

# apps
function sanitary_path($path) { return [regex]::replace($path, "[/\\?:*<>|]", "") }
function installed($app, $global=$null) {
	if($global -eq $null) { return (installed $app $true) -or (installed $app $false) }
	return test-path (appdir $app $global)
}
function installed_apps($global) {
	$dir = appsdir $global
	if(test-path $dir) {
		gci $dir | where { $_.psiscontainer -and $_.name -ne 'scoop' } | % { $_.name }
	}
}

# paths
function fname($path) { split-path $path -leaf }
function strip_ext($fname) { $fname -replace '\.[^\.]*$', '' }

function ensure($dir) { if(!(test-path $dir)) { mkdir $dir > $null }; resolve-path $dir }
function fullpath($path) { # should be ~ rooted
	$executionContext.sessionState.path.getUnresolvedProviderPathFromPSPath($path)
}
function relpath($path) { "$($myinvocation.psscriptroot)\$path" } # relative to calling script
function friendly_path($path) {
	$h = $home; if(!$h.endswith('\')) { $h += '\' }
	return "$path" -replace ([regex]::escape($h)), "~\"
}
function is_local($path) {
	($path -notmatch '^https?://') -and (test-path $path)
}

# operations
function dl($url,$to) {
	$wc = new-object system.net.webClient
	$wc.headers.add('User-Agent', 'Scoop/1.0')
	$wc.downloadFile($url,$to)

}
function env { param($name,$value,$targetEnvironment)
    if ( $PSBoundParameters.ContainsKey('targetEnvironment') ) {
        # $targetEnvironment is expected to be $null, [bool], [string], or [System.EnvironmentVariableTarget]
        if ($targetEnvironment -eq $null) { $targetEnvironment = [System.EnvironmentVariableTarget]::Process }
        elseif ($targetEnvironment -is [bool]) {
            # from initial usage pattern
            if ($targetEnvironment) { $targetEnvironment = [System.EnvironmentVariableTarget]::Machine }
            else { $targetEnvironment = [System.EnvironmentVariableTarget]::User }
        }
        elseif (($targetEnvironment -eq '') -or ($targetEnvironment -eq 'Process') -or ($targetEnvironment -eq 'Session')) { $targetEnvironment = [System.EnvironmentVariableTarget]::Process }
        elseif ($targetEnvironment -eq 'User') { $targetEnvironment = [System.EnvironmentVariableTarget]::User }
        elseif (($targetEnvironment -eq 'Global') -or ($targetEnvironment -eq 'Machine')) { $targetEnvironment = [System.EnvironmentVariableTarget]::Machine }
        elseif ($targetEnvironment -is [System.EnvironmentVariableTarget]) { <# NoOP #> }
        else {
            throw "ERROR: logic: incorrect targetEnvironment parameter ('$targetEnvironment') used for env()"
        }
    }
    else { $targetEnvironment = [System.EnvironmentVariableTarget]::Process }

	if($PSBoundParameters.ContainsKey('value')) {
        [environment]::setEnvironmentVariable($name,$value,$targetEnvironment)
        if (($targetEnvironment -eq [System.EnvironmentVariableTarget]::Process) -and ($envpipe -ne $null)) {
            "set " + ( CMD_SET_encode_arg("$name=$value") ) | out-file $envpipe -encoding OEM -append
        }
    }
	else { [environment]::getEnvironmentVariable($name,$targetEnvironment) }
}
function unzip($path,$to) {
	if(!(test-path $path)) { abort "can't find $path to unzip"}
	try { add-type -assembly "System.IO.Compression.FileSystem" -ea stop }
	catch { unzip_old $path $to; return } # for .net earlier than 4.5
	try {
		[io.compression.zipfile]::extracttodirectory($path,$to)
	} catch [system.io.pathtoolongexception] {
		# try to fall back to 7zip if path is too long
		if(7zip_installed) {
			extract_7zip $path $to $false
			return
		} else {
			abort "unzip failed: Windows can't handle the long paths in this zip file.`nrun 'scoop install 7zip' and try again."
		}
	} catch {
		abort "unzip failed: $_"
	}
}
function unzip_old($path,$to) {
	# fallback for .net earlier than 4.5
	$shell = (new-object -com shell.application -strict)
	$zipfiles = $shell.namespace("$path").items()
	$to = ensure $to
	$shell.namespace("$to").copyHere($zipfiles, 4) # 4 = don't show progress dialog
}

function movedir($from, $to) {
	$from = $from.trimend('\')
	$to = $to.trimend('\')

	$out = robocopy "$from" "$to" /e /move
	if($lastexitcode -ge 8) {
		throw "error moving directory: `n$out"
	}
}

function shim($path, $global, $name, $arg) {
	if(!(test-path $path)) { abort "can't shim $(fname $path): couldn't find $path" }
	$abs_shimdir = ensure (shimdir $global)
	if(!$name) { $name = strip_ext (fname $path) }

	$shim = "$abs_shimdir\$($name.tolower()).ps1"

	# note: use > for first line to replace file, then >> to append following lines
	echo '# ensure $HOME is set for MSYS programs' > $shim
	echo "if(!`$env:home) { `$env:home = `"`$home\`" }" >> $shim
	echo 'if($env:home -eq "\") { $env:home = $env:allusersprofile }' >> $shim
	echo "`$path = `"$path`"" >> $shim
	if($arg) {
		echo "`$args = '$($arg -join "', '")', `$args" >> $shim
	}
	echo 'if($myinvocation.expectingInput) { $input | & $path @args } else { & $path @args }' >> $shim

	if($path -match '\.exe$') {
		# for programs with no awareness of any shell
		$shim_exe = "$(strip_ext($shim)).shim"
		cp "$(versiondir 'scoop' 'current')\supporting\shimexe\shim.exe" "$(strip_ext($shim)).exe" -force
		echo "path = $(resolve-path $path)" | out-file $shim_exe -encoding oem
		if($arg) {
			echo "args = $arg" | out-file $shim_exe -encoding oem -append
		}
	} elseif($path -match '\.((bat)|(cmd))$') {
		# shim .bat, .cmd so they can be used by programs with no awareness of PSH
		$shim_cmd = "$(strip_ext($shim)).cmd"
		':: ensure $HOME is set for MSYS programs'           | out-file $shim_cmd -encoding oem
		'@if "%home%"=="" set home=%homedrive%%homepath%\'   | out-file $shim_cmd -encoding oem -append
		'@if "%home%"=="\" set home=%allusersprofile%\'      | out-file $shim_cmd -encoding oem -append
		"@`"$(resolve-path $path)`" $arg %*"                 | out-file $shim_cmd -encoding oem -append
	} elseif($path -match '\.ps1$') {
		# make ps1 accessible from cmd.exe
		$shim_cmd = "$(strip_ext($shim)).cmd"
        # generate_shim_cmd_code $path $shim_cmd | out-file $shim_cmd -encoding oem
		"@powershell -noprofile -ex unrestricted `"& '$(resolve-path $path)' %*;exit `$lastexitcode`"" | out-file $shim_cmd -encoding oem
	}
}

# ToDO: better names for "shim_scoop" and "shim_scoop_CMD_code"
function shim_scoop($path, $global) {

    # generate_shim_cmd_text($path, $shim_cmd_path)
    # $name = strip_ext (fname $path)
    # if ($name -ine 'scoop') {
    #     # only scoop knows about and manipulates shims so no special care is needed for CMD shims for other executables
    #     $v = "@powershell -noprofile -ex unrestricted `"& '$(resolve-path $path)' $arg %*;exit `$lastexitcode`""
    # }
    # else ...

    # special handling is needed for updating in-progress BAT/CMD files to avoid unanticipated execution paths (and associated possible errors)
    # must assume that the CMD shim may be currently in-use (since there is no simple way to determine that condition)

    # save initial CMD shim content and length
    $CMD_shim_fullpath = resolve-path "$(shimdir $false)\scoop.cmd"     # resolve path into CMD/DOS compatible format
    $CMD_shim_content = Get-Content $CMD_shim_fullpath
    $CMD_shim_original_size = (Get-ChildItem $CMD_shim_fullpath).length

    # create the usual shims pointing to scoop
    shim $path $global

    # the scoop CMD shim is special
    # the CMD shim is created de-novo with special handling for in-progress updates and to add environment piping back up to the original calling CMD process

    # assume that the current CMD shim is either:
    # 1. old version == calls powershell with the last command in the script
    #    .... since control flow returns to the script (executing from the character position just past the end of the command calling scoop),
    #    .... special handling is needed
    #    .... we can use the fact the prior shims were all constructed to call scoop with the last command in the script to build a script which allows the usual return and completion of the current process without error *and* executes subsequent runs correctly
    #    .... To do this, we must embed code for future execution paths within the space before the point at which execution returns (which we assume is the end of the script) and then fill the script so that the current process returns to a known execution path and finishes correctly
    # ... or
    # 2. new self-update aware script which executes via a proxy allowing modification without limitation (tested via embedded signal text: "*(scoop:#self-update-ok)"). NOTE: the * is included because it's illegal in a filename making it's inclusion in some shim incarnation even less likely.


    $safe_update_signal_text = '*(scoop:#update-ok)' # "magic" signal string (constructed to be readable but also unique)

    "@::$safe_update_signal_text" | out-file $CMD_shim_fullpath -encoding OEM

    # if $CMD_shim_content contains $safe_update_signal_text there is no need to add the code in this section
    # * using this stops the otherwise exponential growth of the CMD shim due to the needed addition of null-execution buffer code for unprepared/unrecognized CMD shims
    if (-not ($CMD_shim_content -cmatch [regex]::Escape($safe_update_signal_text))) {
        # NOTE: we aren't testing only the first line as we may have code changes later which might need to be first and push the signal string lower into the file (is that correct/reasonable? or are leading comments in a BAT/CMD script always a NULL no matter what the other code)
        "@goto :__START__" | out-file $CMD_shim_fullpath -append -encoding OEM
        # buffer the hand-off code with code which safely deals with the prior shim design which has a silent return from scoop.ps1, continuing execution (though to EOF, which exits the script); any code placed following the character position at EOF in the prior shim must finish normally without error
        $buffer_text = ''
        $size_diff = $CMD_shim_original_size - (Get-ChildItem $CMD_shim_fullpath).length
        if ($size_diff -lt 0) {
            # ToDO: refactor this out of the function as $args_initial is in the scoop-update.ps1 file (although in-scope here, it's confusing); but the simple course of returning a bool error flag may be the best course either
            # minimally necessary proxy hand-off code was still longer than the initial shim which could lead to an execution error upon return to the shim script, request re-update
            # $reupdate_command = 'scoop update'
            # if ($args_initial) { $reupdate_command += " $args_initial" }
            # warn "scoop encountered an update inconsistency, please re-run '$reupdate_command'"
            warn "scoop encountered an update inconsistency, please re-run 'scoop update'"
        }
        elseif ( $size_diff -gt 0 ) {
            # note: '@' characters are used to reduce the risk of wrong command execution in the case that we've miscalculated the return/continue location of the execution pointer
            if ( $size_diff -eq 1 ) { $buffer_text = '@' <# no EOL CRLF #>}
            else { $buffer_text = $('@' * ($size_diff-2)) + "`r`n" }
        }
        $($buffer_text + '@goto :EOF &:: safely end a returning, and now modified, in-progress script') | out-file $CMD_shim_fullpath -append -encoding OEM
        '@:__START__' | out-file $CMD_shim_fullpath -append -encoding OEM
    }
    $code = shim_scoop_CMD_code $(resolve-path $path)
    $code | out-file $CMD_shim_fullpath -append -encoding OEM
}

function shim_scoop_CMD_code($path) {
# shim_scoop_cmd_code
# shim startup / initialization code
$retval = '
@setlocal
@echo off
set __ME=%~n0
set __dp0=%~dp0

:: NOTE: flow of control is passed (importantly, with no return) to a proxy BAT/CMD script; any modification(s) of this script are safe at any execution time after that control hand-off

:: require temporary files
:: * (needed for both out-of-source proxy contruction and for piping in-process environment variable updates)
call :_tempfile __oosource "%__ME%.oosource" ".bat"
if NOT DEFINED __oosource ( goto :TEMPFILE_ERROR )
call :_tempfile __pipe "%__ME%.pipe" ".bat"
if NOT DEFINED __pipe ( goto :TEMPFILE_ERROR )
goto :TEMPFILES_FOUND
:TEMPFILES_ERROR
echo %__ME%: ERROR: unable to open needed temporary file(s) [make sure to set TEMP or TMP to an available writable temporary directory {try "set TEMP=%%LOCALAPPDATA%%\Temp"}] 1>&2
exit /b -1
:TEMPFILES_FOUND
'
# shim code creating environment pipe
$retval += '
@::* initialize environment pipe
echo @:: TEMPORARY source/exec environment pipe [owner: "%~f0"] > "%__pipe%"
'
# shim code creating out-of-source proxy
$retval += '
@::* initialize out-of-source proxy and add proxy initialization code
echo @:: TEMPORARY out-of-source executable proxy [owner: "%~f0"] > "%__oosource%"
echo (set ERRORLEVEL=) >> "%__oosource%"
echo setlocal >> "%__oosource%"
'
$retval += "
@::* out-of-source proxy code to call scoop
echo call powershell -NoProfile -ExecutionPolicy unrestricted -Command ^`"^& '$path' -__cmdenvpipe '%__pipe%' %*^`" >> `"%__oosource%`"
"
$retval += '
@::* out-of-source proxy code to source environment changes and cleanup
echo (set __exit_code=%%ERRORLEVEL%%) >> "%__oosource%"
echo ^( endlocal >> "%__oosource%"
echo call ^"%__pipe%^"  >> "%__oosource%"
echo call erase /q ^"%__pipe%^" ^>NUL 2^>NUL >> "%__oosource%"
echo start ^"^" /b cmd /c del ^"%%~f0^" ^& exit /b %%__exit_code%% >> "%__oosource%"
echo ^) >> "%__oosource%"
'
# shim hand-off to out-of-source proxy
$retval += '
endlocal & "%__oosource%" &:: hand-off to proxy; intentional non-call (no return from proxy) to allow for safe updates of this script
'
# shim script subroutines
$retval += '
goto :EOF
::#### SUBs

::
:_tempfile ( ref_RETURN [PREFIX [EXTENSION]])
:: open a unique temporary file
:: RETURN == full pathname of temporary file (with given PREFIX and EXTENSION) [NOTE: has NO surrounding quotes]
:: PREFIX == optional filename prefix for temporary file
:: EXTENSION == optional extension (including leading ".") for temporary file [default == ".bat"]
setlocal
set "_RETval="
set "_RETvar=%~1"
set "prefix=%~2"
set "extension=%~3"
if NOT DEFINED extension ( set "extension=.bat")
:: find a temp directory (respect prior setup; default to creating/using "%LocalAppData%\Temp" as a last resort)
if NOT EXIST "%temp%" ( set "temp=%tmp%" )
if NOT EXIST "%temp%" ( mkdir "%LocalAppData%\Temp" 2>NUL & cd . & set "temp=%LocalAppData%\Temp" )
if NOT EXIST "%temp%" ( goto :_tempfile_RETURN )    &:: undefined TEMP, RETURN (with NULL result)
:: NOTE: this find unique/instantiate loop has an unavoidable race condition (but, as currently coded, the real risk of collision is virtually nil)
:_tempfile_find_unique_temp
set "_RETval=%temp%\%prefix%.%RANDOM%.%RANDOM%%extension%" &:: arbitrarily lower risk can be obtained by increasing the number of %RANDOM% entries in the file name
if EXIST "%_RETval%" ( goto :_tempfile_find_unique_temp )
:: instantiate tempfile
set /p OUTPUT=<nul >"%_RETval%"
:_tempfile_find_unique_temp_DONE
:_tempfile_RETURN
endlocal & set %_RETvar%^=%_RETval%
goto :EOF
::

goto :EOF
'
$retval
}

function ensure_in_path($dir, $global) {
	$path = env 'path' -t $global
	$dir = fullpath $dir
	if($path -notmatch [regex]::escape($dir)) {
		echo "adding $(friendly_path $dir) to $(if($global){'global'}else{'your'}) path"

		env 'path' -t $global "$dir;$path" # for future sessions...
		env 'path' "$dir;$env:path"        # for this session
	}
}

function strip_path($orig_path, $dir) {
	$stripped = [string]::join(';', @( $orig_path.split(';') | ? { $_ -and $_ -ne $dir } ))
	return ($stripped -ne $orig_path), $stripped
}

function remove_from_path($dir,$global) {
	$dir = fullpath $dir

	# future sessions
	$was_in_path, $newpath = strip_path (env 'path' -t $global) $dir
	if($was_in_path) {
		echo "removing $(friendly_path $dir) from your path"
		env 'path' -t $global $newpath
	}

	# current session
	$was_in_path, $newpath = strip_path $env:path $dir
	if($was_in_path) { env 'path' $newpath }
}

function ensure_scoop_in_path($global) {
	$abs_shimdir = ensure (shimdir $global)
	# be aggressive (b-e-aggressive) and install scoop first in the path
	ensure_in_path $abs_shimdir $global
}

function ensure_robocopy_in_path {
	if(!(gcm robocopy -ea ignore)) {
		shim "C:\Windows\System32\Robocopy.exe" $false
	}
}

function wraptext($text, $width) {
	if(!$width) { $width = $host.ui.rawui.windowsize.width };
	$width -= 1 # be conservative: doesn't seem to print the last char

	$text -split '\r?\n' | % {
		$line = ''
		$_ -split ' ' | % {
			if($line.length -eq 0) { $line = $_ }
			elseif($line.length + $_.length + 1 -le $width) { $line += " $_" }
			else { $lines += ,$line; $line = $_ }
		}
		$lines += ,$line
	}

	$lines -join "`n"
}

function pluralize($count, $singular, $plural) {
	if($count -eq 1) { $singular } else { $plural }
}

# for dealing with user aliases
$default_aliases = @{
	'cp' = 'copy-item'
	'echo' = 'write-output'
	'gc' = 'get-content'
	'gci' = 'get-childitem'
	'gcm' = 'get-command'
	'iex' = 'invoke-expression'
	'ls' = 'get-childitem'
	'mkdir' = { new-item -type directory @args }
	'mv' = 'move-item'
	'rm' = 'remove-item'
	'sc' = 'set-content'
	'select' = 'select-object'
	'sls' = 'select-string'
}

function reset_alias($name, $value) {
	if($existing = get-alias $name -ea ignore |? { $_.options -match 'readonly' }) {
		if($existing.definition -ne $value) {
			write-host "alias $name is read-only; can't reset it" -f darkyellow
		}
		return # already set
	}
	if($value -is [scriptblock]) {
		new-item -path function: -name "script:$name" -value $value | out-null
		return
	}

	set-alias $name $value -scope script -option allscope
}

function reset_aliases() {
	# for aliases where there's a local function, re-alias so the function takes precedence
	$aliases = get-alias |? { $_.options -notmatch 'readonly' } |% { $_.name }
	get-childitem function: | % {
		$fn = $_.name
		if($aliases -contains $fn) {
			set-alias $fn local:$fn -scope script
		}
	}

	# set default aliases
	$default_aliases.keys | % { reset_alias $_ $default_aliases[$_] }
}

function CMD_SET_encode_arg {
    # CMD_SET_encode_arg( @ )
    # encode string(s) to equivalent CMD command line interpretable version(s) as arguments for SET
    if ($args -ne $null) {
        $args | ForEach-Object {
            $val = $_
            $val = $($val -replace '\^','^^')
            $val = $($val -replace '\(','^(')
            $val = $($val -replace '\)','^)')
            $val = $($val -replace '<','^<')
            $val = $($val -replace '>','^>')
            $val = $($val -replace '\|','^|')
            $val = $($val -replace '&','^&')
            $val = $($val -replace '"','^"')
            $val = $($val -replace '%','^%')
            $val
            }
        }
    }
