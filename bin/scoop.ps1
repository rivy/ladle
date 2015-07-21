#requires -v 3
param(
    [parameter(mandatory=$false)][string]$__CMDenvpipe = $null,
    [parameter(mandatory=$false,position=0)]$cmd,
    [parameter(ValueFromRemainingArguments=$true)][array]$args = @()
    )

set-strictmode -off

. "$psscriptroot\..\lib\core.ps1"
. (relpath '..\lib\commands')

$env:SCOOP_ENVPIPE = $__cmdenvpipe

reset_aliases

$commands = commands

if (@($null, '-h', '--help', '/?') -contains $cmd) { exec 'help' $args }
elseif ($commands -contains $cmd) { exec $cmd $args }
else { "scoop: '$cmd' isn't a scoop command. See 'scoop help'"; exit 1 }