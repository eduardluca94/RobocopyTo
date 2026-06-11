# RobocopyTo module root: composes the part-files inside module scope.
# Import with: Import-Module <path>\RobocopyTo.psm1
# Event-handler closures created inside module functions resolve through this
# module's scope, which is why the parts live in a module instead of dot-sourced
# script scope (delegates would otherwise fail to find our functions).

. $PSScriptRoot\RobocopyTo.Common.ps1
. $PSScriptRoot\RobocopyTo.Engine.ps1
. $PSScriptRoot\RobocopyTo.Undo.ps1
. $PSScriptRoot\RobocopyTo.UI.ps1
. $PSScriptRoot\RobocopyTo.Settings.ps1

Export-ModuleMember -Function *
