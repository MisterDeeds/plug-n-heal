#Requires -Version 5.1
<#
.SYNOPSIS
    Plug'n'Heal builder: fills an empty external SSD so that it later works without internet.

.DESCRIPTION
    Without parameters a wizard opens (Windows Forms, for laypeople): pick the drive, pick the size, click "Build".
    With -NonInteractive the same steps run without a window (experts, CI):

        BUILD.cmd -NonInteractive -Drive E: -Profile standard

    Steps (docs/ARCHITECTURE.md 5.9): check drive (exFAT/NTFS, FAT32 is refused, never formatted) and free space,
    download the pinned Ollama runtime with curl.exe (retry loop, resume, sha256), extract with tar.exe, copy src\,
    start ollama.exe from the drive and POST /api/pull every model of the profile, verify every blob of every
    manifest, write licences, drive.json and README.txt, stop Ollama.

    Writes only <drive>\PlugNHeal\, <drive>\START.cmd and <drive>\README.txt. Re-running skips what is complete
    and resumes partial downloads.

    Exit codes (-NonInteractive): 0 done, 1 failed (run again to resume), 2 refused (usage, FAT32, space, catalogue),
    3 cancelled.

.PARAMETER NonInteractive
    No window; progress goes to the console.
.PARAMETER Drive
    Drive letter (E, E: or E:\) or, for tests, an existing folder.
.PARAMETER Profile
    small, standard (default) or full, as defined in src\catalog\models.json.
.PARAMETER Catalog
    Another models.json (tests).
.PARAMETER Language
    de or en; default from the Windows display language.
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$Drive,
    [Alias('Profile')]
    [ValidateSet('small', 'standard', 'full')]
    [string]$BuildProfile = 'standard',
    [string]$Catalog,
    [ValidateSet('', 'de', 'en')]
    [string]$Language = ''
)

$script:PnhScriptPath = $PSCommandPath
$script:PnhBuilderRoot = $PSScriptRoot
$script:PnhRepoRoot = Split-Path -Parent $PSScriptRoot
$script:PnhBuildLang = 'en'
$script:PnhBuildLogFile = $null
$script:PnhBuildLogDir = $null
$script:PnhReport = $null
$script:PnhCancel = $null
$script:PnhProgress = $null
$script:PnhVersions = $null

# ---------------------------------------------------------------------------------------------------------------------
# Texts (the builder is not part of src\, so it carries its own strings)
# ---------------------------------------------------------------------------------------------------------------------
$script:PnhBuildText = @{
    de = @{
        'title'               = "Plug'n'Heal – SSD vorbereiten"
        'drive.heading'       = '1. Welche SSD soll vorbereitet werden?'
        'drive.hint'          = 'Stecken Sie die SSD an diesen PC an. Sie erscheint dann in der Liste. Was schon auf der SSD ist, bleibt erhalten.'
        'drive.showAll'       = 'Alle Laufwerke anzeigen'
        'drive.refresh'       = 'Liste aktualisieren'
        'drive.none'          = 'Keine externe SSD gefunden. Bitte anstecken und «Liste aktualisieren» klicken.'
        'drive.pick'          = 'Bitte wählen Sie zuerst eine SSD in der Liste.'
        'col.drive'           = 'Laufwerk'
        'col.label'           = 'Name'
        'col.size'            = 'Grösse'
        'col.free'            = 'Frei'
        'col.fs'              = 'Dateisystem'
        'fat.short'           = 'Diese SSD ist mit FAT32 formatiert und muss zuerst mit exFAT formatiert werden.'
        'fs.short'            = 'Diese SSD hat das Dateisystem «{0}». Plug''n''Heal braucht exFAT oder NTFS.'
        'fat.howButton'       = 'So formatieren Sie die SSD mit exFAT'
        'fat.title'           = 'SSD zuerst mit exFAT formatieren'
        'fat.text'            = "Die SSD ist mit «{0}» formatiert. Darauf passen keine Dateien über 4 GB, die Sprachmodelle sind aber grösser.`r`n`r`nSo formatieren Sie die SSD mit exFAT. ACHTUNG: Dabei wird ALLES auf der SSD gelöscht.`r`n`r`n1. Wichtige Dateien von der SSD zuerst anderswo sichern.`r`n2. Im Explorer mit der rechten Maustaste auf die SSD klicken und «Formatieren ...» wählen.`r`n3. Dateisystem: exFAT. Volumebezeichnung: PLUGNHEAL. «Schnellformatierung» angehakt lassen.`r`n4. «Starten» klicken und bestätigen.`r`n5. Danach diesen Helfer noch einmal starten.`r`n`r`nPlug'n'Heal formatiert nie selbst."
        'profile.heading'     = '2. Wie viel soll auf die SSD?'
        'profile.small'       = 'Klein, etwa {0}'
        'profile.small.text'  = 'Die zwei kleinen Modelle 2B und 4B ({1}). Genügt für PCs ohne eigene Grafikkarte und für Grafikkarten bis 8 GB. Mit einer grösseren Grafikkarte läuft dann auch nur das 4B. Braucht eine SSD ab {0} GB.'
        'profile.standard'    = 'Standard, etwa {0} (empfohlen)'
        'profile.standard.text' = 'Wie «Klein», dazu 9B für Grafikkarten ab 10 GB, das 27B und seine unzensierte Version (beide laufen auf kleineren Grafikkarten teils im Arbeitsspeicher; ist das zu langsam, wird automatisch ein kleineres Modell benutzt, {1} mehr). Passt für fast jeden PC. Braucht eine SSD ab {0} GB.'
        'profile.full'        = 'Vollständig, etwa {0}'
        'profile.full.text'   = 'Wie «Standard», dazu zwei Modelle ({1} mehr), die nur PCs mit einer Grafikkarte mit 16 oder 20 GB nützen: das 9B in höherer Genauigkeit und ein schnelles Modell, das zusätzlich 32 GB Arbeitsspeicher braucht. Braucht eine SSD ab {0} GB.'
        'profile.free'        = 'Auf der SSD {0} sind {1} frei.'
        'profile.tooBig'      = 'Diese Auswahl passt nicht auf die SSD. Bitte eine kleinere Auswahl oder eine grössere SSD nehmen.'
        'btn.next'            = 'Weiter'
        'btn.back'            = 'Zurück'
        'btn.build'           = 'SSD erstellen'
        'btn.cancel'          = 'Abbrechen'
        'btn.close'           = 'Schliessen'
        'progress.heading'    = '3. Die SSD wird erstellt'
        'progress.keepOpen'   = 'Bitte den PC eingeschaltet und mit dem Internet verbunden lassen. Sie können jederzeit abbrechen: Beim nächsten Start geht es dort weiter.'
        'progress.line'       = '{0} von {1} geladen, {2}'
        'progress.cancelling' = 'Wird abgebrochen ...'
        'phase.check'         = 'Prüfe die SSD und die Modellliste ...'
        'phase.runtime'       = 'Lade das Programm Ollama ...'
        'phase.verify'        = 'Prüfe das heruntergeladene Programm ...'
        'phase.extract'       = 'Entpacke das Programm auf die SSD ...'
        'phase.app'           = "Kopiere Plug'n'Heal auf die SSD ..."
        'phase.ollama'        = 'Starte Ollama von der SSD ...'
        'phase.hf'            = 'Lade die Sprachmodelldatei {0} von Hugging Face ...'
        'phase.model'         = 'Lade Sprachmodell {0} ({1} von {2}) ...'
        'phase.verifyModels'  = 'Prüfe die Sprachmodelle ...'
        'phase.finish'        = 'Schreibe Lizenzen und Anleitung ...'
        'eta.calc'            = 'Restzeit wird berechnet'
        'eta.lessMinute'      = 'noch weniger als eine Minute'
        'eta.minute'          = 'noch etwa 1 Minute'
        'eta.minutes'         = 'noch etwa {0} Minuten'
        'eta.hour'            = 'noch etwa 1 Stunde'
        'eta.hourMinutes'     = 'noch etwa 1 Stunde und {0} Minuten'
        'eta.hours'           = 'noch etwa {0} Stunden'
        'eta.hoursMinutes'    = 'noch etwa {0} Stunden und {1} Minuten'
        'done.ok.heading'     = 'Fertig! Die SSD ist bereit.'
        'done.ok.text'        = "Auf der SSD sind jetzt diese Sprachmodelle:`r`n{0}`r`n`r`nWerfen Sie die SSD im Explorer aus (rechte Maustaste, «Auswerfen»), bevor Sie sie abziehen. Danach hilft sie an jedem Windows-PC, auch ohne Internet."
        'done.fail.heading'   = 'Das hat leider nicht geklappt'
        'done.fail.text'      = "{0}`r`n`r`nStarten Sie den Helfer einfach noch einmal. Was schon geladen ist, bleibt erhalten.`r`n`r`nProtokoll: {1}"
        'done.cancel.heading' = 'Abgebrochen'
        'done.cancel.text'    = 'Beim nächsten Start geht es dort weiter, wo Sie aufgehört haben.'
        'confirm.cancel'      = 'Wirklich abbrechen? Was schon geladen ist, bleibt auf der SSD.'
        'err.catalogMissing'  = "Die Modellliste fehlt: {0}. Bitte das vollständige Plug'n'Heal-Paket herunterladen."
        'err.catalogInvalid'  = 'Die Modellliste ist beschädigt: {0} ({1})'
        'err.profile'         = 'Die Auswahl «{0}» ist in der Modellliste nicht festgelegt.'
        'err.unknownModel'    = 'Die Auswahl «{0}» nennt ein unbekanntes Modell: {1}'
        'err.versions'        = 'builder\versions.json fehlt oder ist beschädigt: {0}'
        'err.src'             = "Programmdateien fehlen: {0}. Bitte das vollständige Plug'n'Heal-Paket herunterladen."
        'err.noDrive'         = 'Das Laufwerk {0} ist nicht bereit. Ist die SSD angesteckt?'
        'err.systemDrive'     = 'Das ist das Windows-Laufwerk. Bitte eine externe SSD wählen.'
        'err.space'           = 'Auf der SSD ist zu wenig Platz: nötig sind {0}, frei sind {1}. Bitte eine kleinere Auswahl oder eine grössere SSD nehmen.'
        'err.sizeMismatch'    = 'Die Grösse von {0} passt nicht zur Modellliste (Liste {1}, Server {2}). Bitte eine neuere Plug''n''Heal-Version verwenden.'
        'err.registry'        = 'Der Modellserver ist nicht erreichbar ({0}). Ist der PC mit dem Internet verbunden?'
        'err.hf'              = 'Der Modellserver (Hugging Face) ist nicht erreichbar ({0}). Ist der PC mit dem Internet verbunden?'
        'err.hfPin'           = 'Die Quelldaten für das Modell {0} fehlen oder sind beschädigt: {1}. Bitte die vollständige Plug''n''Heal-Version verwenden.'
        'err.download'        = 'Der Download ist nach {0} Versuchen gescheitert: {1}'
        'err.hash'            = 'Die heruntergeladene Datei ist beschädigt (Prüfsumme falsch): {0}'
        'err.extract'         = 'Entpacken gescheitert: {0}'
        'err.ollamaStart'     = 'Ollama liess sich von der SSD nicht starten: {0}'
        'err.pull'            = 'Das Sprachmodell {0} liess sich nicht laden: {1}'
        'err.verify'          = 'Das Sprachmodell {0} ist unvollständig: {1}'
        'err.license'         = 'Der Lizenztext liess sich nicht laden: {0}'
        'err.path'            = 'Interner Fehler: Pfad ausserhalb von PlugNHeal: {0}'
        'err.cancelled'       = 'Abgebrochen.'
        'cli.done'            = 'Fertig. Die SSD {0} ist bereit:'
        'cli.usage'           = 'Aufruf: BUILD.cmd [-NonInteractive -Drive E: -Profile small|standard|full]'
        'cli.noWindows'       = 'Der Assistent braucht Windows. Auf Linux/macOS: builder/build-drive.sh'
    }
    en = @{
        'title'               = "Plug'n'Heal – prepare the SSD"
        'drive.heading'       = '1. Which SSD should be prepared?'
        'drive.hint'          = 'Plug the SSD into this PC. It then appears in the list. Files already on the SSD are kept.'
        'drive.showAll'       = 'Show all drives'
        'drive.refresh'       = 'Refresh list'
        'drive.none'          = 'No external SSD found. Plug it in and click "Refresh list".'
        'drive.pick'          = 'Please pick an SSD in the list first.'
        'col.drive'           = 'Drive'
        'col.label'           = 'Name'
        'col.size'            = 'Size'
        'col.free'            = 'Free'
        'col.fs'              = 'File system'
        'fat.short'           = 'This SSD is formatted with FAT32 and must first be formatted with exFAT.'
        'fs.short'            = 'This SSD uses the file system "{0}". Plug''n''Heal needs exFAT or NTFS.'
        'fat.howButton'       = 'How to format the SSD with exFAT'
        'fat.title'           = 'Format the SSD with exFAT first'
        'fat.text'            = "The SSD is formatted with ""{0}"". It cannot hold files larger than 4 GB, and the language models are larger.`r`n`r`nHow to format the SSD with exFAT. CAUTION: this ERASES everything on the SSD.`r`n`r`n1. Copy important files from the SSD somewhere else first.`r`n2. In File Explorer, right-click the SSD and choose ""Format ..."".`r`n3. File system: exFAT. Volume label: PLUGNHEAL. Keep ""Quick Format"" ticked.`r`n4. Click ""Start"" and confirm.`r`n5. Then start this helper again.`r`n`r`nPlug'n'Heal never formats a drive by itself."
        'profile.heading'     = '2. How much should go onto the SSD?'
        'profile.small'       = 'Small, about {0}'
        'profile.small.text'  = 'The two small models, 2B and 4B ({1}). Enough for PCs without their own graphics card and for graphics cards up to 8 GB. A larger graphics card then also runs only the 4B. Needs an SSD of {0} GB or more.'
        'profile.standard'    = 'Standard, about {0} (recommended)'
        'profile.standard.text' = 'Like "Small", plus 9B for cards from 10 GB, the 27B (24 GB cards) and its unfiltered version (partly in memory on smaller cards; if that is too slow a smaller model is used, {1} more). Right for almost every PC. Needs an SSD of {0} GB or more.'
        'profile.full'        = 'Full, about {0}'
        'profile.full.text'   = 'Like "Standard", plus two models ({1} more) that only help PCs with a 16 or 20 GB graphics card: the 9B in higher precision, and a fast model that also needs 32 GB of RAM. Needs an SSD of {0} GB or more.'
        'profile.free'        = 'The SSD {0} has {1} free.'
        'profile.tooBig'      = 'This choice does not fit on the SSD. Please pick a smaller choice or a larger SSD.'
        'btn.next'            = 'Next'
        'btn.back'            = 'Back'
        'btn.build'           = 'Build the SSD'
        'btn.cancel'          = 'Cancel'
        'btn.close'           = 'Close'
        'progress.heading'    = '3. Building the SSD'
        'progress.keepOpen'   = 'Please keep the PC switched on and connected to the internet. You can cancel at any time: the next start continues where it stopped.'
        'progress.line'       = '{0} of {1} downloaded, {2}'
        'progress.cancelling' = 'Cancelling ...'
        'phase.check'         = 'Checking the SSD and the model list ...'
        'phase.runtime'       = 'Downloading the Ollama program ...'
        'phase.verify'        = 'Checking the downloaded program ...'
        'phase.extract'       = 'Unpacking the program onto the SSD ...'
        'phase.app'           = "Copying Plug'n'Heal onto the SSD ..."
        'phase.ollama'        = 'Starting Ollama from the SSD ...'
        'phase.hf'            = 'Downloading the language model file {0} from Hugging Face ...'
        'phase.model'         = 'Downloading language model {0} ({1} of {2}) ...'
        'phase.verifyModels'  = 'Checking the language models ...'
        'phase.finish'        = 'Writing licences and instructions ...'
        'eta.calc'            = 'estimating the time left'
        'eta.lessMinute'      = 'less than a minute left'
        'eta.minute'          = 'about 1 minute left'
        'eta.minutes'         = 'about {0} minutes left'
        'eta.hour'            = 'about 1 hour left'
        'eta.hourMinutes'     = 'about 1 hour and {0} minutes left'
        'eta.hours'           = 'about {0} hours left'
        'eta.hoursMinutes'    = 'about {0} hours and {1} minutes left'
        'done.ok.heading'     = 'Done! The SSD is ready.'
        'done.ok.text'        = "These language models are now on the SSD:`r`n{0}`r`n`r`nEject the SSD in File Explorer (right-click, ""Eject"") before unplugging it. After that it helps on any Windows PC, even without internet."
        'done.fail.heading'   = 'Sorry, that did not work'
        'done.fail.text'      = "{0}`r`n`r`nJust start the helper again. Everything already downloaded is kept.`r`n`r`nLog: {1}"
        'done.cancel.heading' = 'Cancelled'
        'done.cancel.text'    = 'The next start continues where you stopped.'
        'confirm.cancel'      = 'Really cancel? Everything already downloaded stays on the SSD.'
        'err.catalogMissing'  = "The model list is missing: {0}. Please download the complete Plug'n'Heal package."
        'err.catalogInvalid'  = 'The model list is damaged: {0} ({1})'
        'err.profile'         = 'The choice "{0}" is not defined in the model list.'
        'err.unknownModel'    = 'The choice "{0}" names an unknown model: {1}'
        'err.versions'        = 'builder\versions.json is missing or damaged: {0}'
        'err.src'             = "Program files are missing: {0}. Please download the complete Plug'n'Heal package."
        'err.noDrive'         = 'Drive {0} is not ready. Is the SSD plugged in?'
        'err.systemDrive'     = 'This is the Windows drive. Please pick an external SSD.'
        'err.space'           = 'Not enough space on the SSD: {0} needed, {1} free. Please pick a smaller choice or a larger SSD.'
        'err.sizeMismatch'    = 'The size of {0} does not match the model list (list {1}, server {2}). Please use a newer Plug''n''Heal version.'
        'err.registry'        = 'The model server cannot be reached ({0}). Is the PC connected to the internet?'
        'err.hf'              = 'The model server (Hugging Face) cannot be reached ({0}). Is the PC connected to the internet?'
        'err.hfPin'           = 'The source data for the model {0} is missing or damaged: {1}. Please use the complete Plug''n''Heal version.'
        'err.download'        = 'The download failed after {0} attempts: {1}'
        'err.hash'            = 'The downloaded file is damaged (wrong checksum): {0}'
        'err.extract'         = 'Unpacking failed: {0}'
        'err.ollamaStart'     = 'Ollama could not be started from the SSD: {0}'
        'err.pull'            = 'The language model {0} could not be downloaded: {1}'
        'err.verify'          = 'The language model {0} is incomplete: {1}'
        'err.license'         = 'The licence text could not be downloaded: {0}'
        'err.path'            = 'Internal error: path outside PlugNHeal: {0}'
        'err.cancelled'       = 'Cancelled.'
        'cli.done'            = 'Done. The SSD {0} is ready:'
        'cli.usage'           = 'Usage: BUILD.cmd [-NonInteractive -Drive E: -Profile small|standard|full]'
        'cli.noWindows'       = 'The wizard needs Windows. On Linux/macOS use builder/build-drive.sh'
    }
}

function Set-PnhBuildLanguage {
    param([string]$Language)
    if ($Language -in @('de', 'en')) { $script:PnhBuildLang = $Language; return }
    $script:PnhBuildLang = 'en'
    try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'de') { $script:PnhBuildLang = 'de' } } catch { }
}

function Get-PnhBuildText {
    param([Parameter(Mandatory)][string]$Key, [object[]]$Arguments)
    $table = $script:PnhBuildText[$script:PnhBuildLang]
    $text = $null
    if ($table -and $table.ContainsKey($Key)) { $text = $table[$Key] }
    elseif ($script:PnhBuildText.en.ContainsKey($Key)) { $text = $script:PnhBuildText.en[$Key] }
    else { $text = $Key }
    if ($Arguments) { return ($text -f $Arguments) }
    return $text
}

# ---------------------------------------------------------------------------------------------------------------------
# Errors, logging, events
# ---------------------------------------------------------------------------------------------------------------------
function New-PnhBuildError {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message)
    $ex = New-Object System.Exception($Message)
    $ex.Data['PnhCode'] = $Code
    return $ex
}

function Get-PnhErrorCode {
    param($ErrorRecord)
    $ex = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    while ($ex) {
        if ($ex.Data -and $ex.Data.Contains('PnhCode')) { return [string]$ex.Data['PnhCode'] }
        if ($ex -is [System.OperationCanceledException]) { return 'cancelled' }
        $ex = $ex.InnerException
    }
    return 'error'
}

function Get-PnhErrorText {
    param($ErrorRecord)
    $ex = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    $cur = $ex
    while ($cur) {
        if ($cur.Data -and $cur.Data.Contains('PnhCode')) { return $cur.Message }
        $cur = $cur.InnerException
    }
    return $ex.Message
}

function Get-PnhExitCode {
    param([string]$Code)
    if ($Code -eq 'cancelled') { return 3 }
    if ($Code -in @('fat', 'fs', 'space', 'systemDrive', 'catalog', 'profile', 'src', 'noDrive', 'sizeMismatch', 'usage', 'versions', 'hfPin')) { return 2 }
    return 1
}

function Write-PnhBuildLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:PnhBuildLogFile) {
        try { [System.IO.File]::AppendAllText($script:PnhBuildLogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
    if ($Level -ne 'Info') { Send-PnhBuildEvent @{ Type = 'log'; Level = $Level; Text = $Message } }
}

function Send-PnhBuildEvent {
    param([hashtable]$BuildEvent)
    if ($script:PnhReport) { & $script:PnhReport $BuildEvent }
}

function Send-PnhPhase {
    param([Parameter(Mandatory)][string]$Key, [object[]]$Arguments)
    $text = Get-PnhBuildText -Key $Key -Arguments $Arguments
    Write-PnhBuildLog -Message $text
    Send-PnhBuildEvent @{ Type = 'phase'; Key = $Key; Text = $text }
}

function Assert-PnhNotCancelled {
    if ($script:PnhCancel -and $script:PnhCancel['Requested']) {
        throw (New-PnhBuildError -Code 'cancelled' -Message (Get-PnhBuildText 'err.cancelled'))
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Pure helpers: paths, file system, catalogue, sizes, time
# ---------------------------------------------------------------------------------------------------------------------
function ConvertTo-PnhDriveRoot {
    param([Parameter(Mandatory)][string]$Drive)
    $d = $Drive.Trim().Trim('"')
    if ($d -match '^[A-Za-z]$') { return ($d.ToUpperInvariant() + ':\') }
    if ($d -match '^[A-Za-z]:[\\/]?$') { return ($d.Substring(0, 1).ToUpperInvariant() + ':\') }
    $full = Resolve-PnhUserPath -Path $d
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full -ne $root) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Resolve-PnhUserPath {
    # relative paths are meant relative to the PowerShell location, .NET would take the process directory
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Get-PnhBuildPaths {
    param([Parameter(Mandatory)][string]$DriveRoot)
    $c = { param([string[]]$Parts) [System.IO.Path]::Combine($Parts) }
    $root = & $c @($DriveRoot, 'PlugNHeal')
    $ollama = & $c @($root, 'runtime', 'ollama')
    $models = & $c @($root, 'models')
    return [pscustomobject]@{
        DriveRoot     = $DriveRoot
        Root          = $root
        App           = & $c @($root, 'app')
        Runtime       = & $c @($root, 'runtime')
        OllamaDir     = $ollama
        OllamaExe     = & $c @($ollama, 'ollama.exe')
        VulkanDir     = & $c @($ollama, 'lib', 'ollama', 'vulkan')
        RuntimeMarker = & $c @($root, 'runtime', 'runtime.json')
        Models        = $models
        Blobs         = & $c @($models, 'blobs')
        Manifests     = & $c @($models, 'manifests')
        Home          = & $c @($root, 'home')
        Logs          = & $c @($root, 'logs')
        Licenses      = & $c @($root, 'licenses')
        Downloads     = & $c @($root, 'downloads')
        DriveJson     = & $c @($root, 'drive.json')
        StartCmd      = & $c @($DriveRoot, 'START.cmd')
        Readme        = & $c @($DriveRoot, 'README.txt')
    }
}

function Test-PnhPathAllowed {
    # $true only for <drive>\PlugNHeal (and below), <drive>\START.cmd and <drive>\README.txt
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Paths)
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetFullPath($Paths.Root).TrimEnd('\', '/')
    if ($full.Equals($root, $cmp)) { return $true }
    foreach ($sep in @('\', '/')) {
        if ($full.StartsWith($root + $sep, $cmp)) { return $true }
    }
    foreach ($f in @($Paths.StartCmd, $Paths.Readme)) {
        if ($full.Equals([System.IO.Path]::GetFullPath($f), $cmp)) { return $true }
    }
    return $false
}

function Assert-PnhPathAllowed {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Paths)
    if (-not (Test-PnhPathAllowed -Path $Path -Paths $Paths)) {
        throw (New-PnhBuildError -Code 'path' -Message (Get-PnhBuildText 'err.path' @($Path)))
    }
}

function Test-PnhFileSystem {
    # exFAT and NTFS are fine; FAT32 cannot hold files over 4 GiB and is refused (never formatted by us)
    param([string]$FileSystem)
    $fs = ("$FileSystem").Trim().ToUpperInvariant()
    if ($fs -in @('EXFAT', 'NTFS')) { return [pscustomobject]@{ Ok = $true; Reason = 'ok'; FileSystem = $FileSystem } }
    if ($fs -in @('FAT32', 'FAT', 'FAT16', 'FAT12', 'VFAT', 'MSDOS')) {
        return [pscustomobject]@{ Ok = $false; Reason = 'fat'; FileSystem = $FileSystem }
    }
    return [pscustomobject]@{ Ok = $false; Reason = 'fs'; FileSystem = $FileSystem }
}

function Test-PnhSystemDrive {
    param([Parameter(Mandatory)][string]$DriveRoot, [string]$SystemDrive = $env:SystemDrive)
    if (-not $SystemDrive) { return $false }
    return ($DriveRoot.TrimEnd('\', '/').Equals($SystemDrive.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase))
}

function Read-PnhJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($text | ConvertFrom-Json)
}

function Read-PnhVersions {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $v = Read-PnhJsonFile -Path $Path
        if (-not $v.ollama.version -or -not $v.ollama.url -or [int64]$v.ollama.size -le 0 -or "$($v.ollama.sha256)" -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'ollama.version/url/size/sha256'
        }
        return $v
    } catch {
        throw (New-PnhBuildError -Code 'versions' -Message (Get-PnhBuildText 'err.versions' @("$Path ($($_.Exception.Message))")))
    }
}

function Read-PnhBuildCatalog {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-PnhBuildError -Code 'catalog' -Message (Get-PnhBuildText 'err.catalogMissing' @($Path)))
    }
    try { $c = Read-PnhJsonFile -Path $Path }
    catch { throw (New-PnhBuildError -Code 'catalog' -Message (Get-PnhBuildText 'err.catalogInvalid' @($Path, $_.Exception.Message))) }
    $models = @($c.models | Where-Object { $null -ne $_ })
    if ($models.Count -eq 0) {
        throw (New-PnhBuildError -Code 'catalog' -Message (Get-PnhBuildText 'err.catalogInvalid' @($Path, 'models')))
    }
    if ($null -eq $c.profiles) {
        throw (New-PnhBuildError -Code 'catalog' -Message (Get-PnhBuildText 'err.catalogInvalid' @($Path, 'profiles')))
    }
    foreach ($m in $models) {
        if (-not $m.id -or -not $m.tag) {
            throw (New-PnhBuildError -Code 'catalog' -Message (Get-PnhBuildText 'err.catalogInvalid' @($Path, 'model without id/tag')))
        }
    }
    return $c
}

function Resolve-PnhBuildProfile {
    # -> catalogue entries of the profile, in profile order, each tag once
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$Name)
    if (-not ($Catalog.profiles.PSObject.Properties.Name -contains $Name)) {
        throw (New-PnhBuildError -Code 'profile' -Message (Get-PnhBuildText 'err.profile' @($Name)))
    }
    # a profile is a list of model ids/tags, or an object with such a list under "models"
    $def = $Catalog.profiles.$Name
    if ($null -ne $def -and $def -isnot [string] -and $def -isnot [array] -and ($def.PSObject.Properties.Name -contains 'models')) { $def = $def.models }
    $refs = @($def | Where-Object { $null -ne $_ })
    $result = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($ref in $refs) {
        $m = @($Catalog.models | Where-Object { $_.id -eq $ref })
        if ($m.Count -eq 0) { $m = @($Catalog.models | Where-Object { $_.tag -eq $ref }) }
        if ($m.Count -eq 0) {
            throw (New-PnhBuildError -Code 'profile' -Message (Get-PnhBuildText 'err.unknownModel' @($Name, $ref)))
        }
        if (-not $seen.ContainsKey($m[0].tag)) { $seen[$m[0].tag] = $true; $result.Add($m[0]) }
    }
    if ($result.Count -eq 0) { throw (New-PnhBuildError -Code 'profile' -Message (Get-PnhBuildText 'err.profile' @($Name))) }
    return $result.ToArray()
}

function Get-PnhProfileBytes {
    # catalogue estimate of a profile: sum of the model sizes (each tag once)
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$Name)
    [int64]$sum = 0
    foreach ($m in @(Resolve-PnhBuildProfile -Catalog $Catalog -Name $Name)) { $sum += [int64]$m.bytes }
    return $sum
}

function Get-PnhSuggestedDriveGB {
    # smallest usual SSD size (GB as printed on the box) whose formatted capacity (~93 %) holds the bytes
    param([Parameter(Mandatory)][int64]$Bytes)
    foreach ($gb in @(16, 32, 64, 128, 256, 512, 1000, 2000, 4000)) {
        if ($gb * 1e9 * 0.93 -ge $Bytes) { return $gb }
    }
    return 8000
}

function Get-PnhProfileOption {
    # wizard page 2, one profile: bytes on the drive (models + unpacked runtime + reserve, the same sum the space
    # check uses), suggested SSD size, radio title and explanation; the explanation names the model bytes this
    # profile adds to the next smaller one (small: all of its models)
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$Versions, [Parameter(Mandatory)][string]$Name)
    $order = @('small', 'standard', 'full')
    $models = [int64](Get-PnhProfileBytes -Catalog $Catalog -Name $Name)
    $added = $models
    $i = [array]::IndexOf($order, $Name)
    if ($i -gt 0) {
        try { $added = $models - [int64](Get-PnhProfileBytes -Catalog $Catalog -Name $order[$i - 1]) } catch { $added = $models }
    }
    $total = $models + [int64]$Versions.ollama.extractedBytes + [int64]$Versions.reserveBytes
    $gb = Get-PnhSuggestedDriveGB -Bytes $total
    return [pscustomobject]@{
        Name       = $Name
        ModelBytes = $models
        DriveBytes = $total
        DriveGB    = $gb
        Title      = (Get-PnhBuildText "profile.$Name" @((Format-PnhBytes $total)))
        Text       = (Get-PnhBuildText "profile.$Name.text" @($gb, (Format-PnhBytes ([math]::Max([int64]0, $added)))))
    }
}

function Split-PnhModelTag {
    # 'qwen3:0.6b' -> library/qwen3/0.6b ; 'user/model' -> user/model/latest
    param([Parameter(Mandatory)][string]$Tag)
    $name = $Tag; $t = 'latest'
    $colon = $Tag.LastIndexOf(':'); $slash = $Tag.LastIndexOf('/')
    if ($colon -gt $slash) { $name = $Tag.Substring(0, $colon); $t = $Tag.Substring($colon + 1) }
    $ns = 'library'
    if ($name.Contains('/')) {
        $parts = $name.Split('/')
        if ($parts.Count -ne 2) { throw (New-PnhBuildError -Code 'catalog' -Message "Unsupported model name (only registry.ollama.ai): $Tag") }
        $ns = $parts[0]; $name = $parts[1]
    }
    foreach ($p in @($ns, $name, $t)) {
        if ($p -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw (New-PnhBuildError -Code 'catalog' -Message "Invalid model tag: $Tag") }
    }
    return [pscustomobject]@{ Namespace = $ns; Name = $name; Tag = $t }
}

function Get-PnhManifestPath {
    param([Parameter(Mandatory)][string]$ModelsDir, [Parameter(Mandatory)][string]$Tag, [string]$RegistryHost = 'registry.ollama.ai')
    $p = Split-PnhModelTag -Tag $Tag
    return [System.IO.Path]::Combine([string[]]@($ModelsDir, 'manifests', $RegistryHost, $p.Namespace, $p.Name, $p.Tag))
}

function Get-PnhBlobPath {
    param([Parameter(Mandatory)][string]$ModelsDir, [Parameter(Mandatory)][string]$Digest)
    if ($Digest -notmatch '^sha256:([0-9a-f]{64})$') { throw "Invalid digest: $Digest" }
    return [System.IO.Path]::Combine($ModelsDir, 'blobs', ('sha256-' + $Matches[1]))
}

function Get-PnhSafeTagName {
    param([Parameter(Mandatory)][string]$Tag)
    return ($Tag.Replace('/', '_').Replace(':', '_'))
}

function Get-PnhManifestEntries {
    # config + layers -> @{Digest; Size; MediaType}
    param([Parameter(Mandatory)]$Manifest)
    if ($null -eq $Manifest.config -or $null -eq $Manifest.layers) { throw 'Not an Ollama manifest (config/layers missing)' }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(@($Manifest.config) + @($Manifest.layers))) {
        if ($null -eq $e) { continue }
        if ("$($e.digest)" -notmatch '^sha256:[0-9a-f]{64}$') { throw "Bad digest in manifest: $($e.digest)" }
        $out.Add([pscustomobject]@{ Digest = [string]$e.digest; Size = [int64]$e.size; MediaType = [string]$e.mediaType })
    }
    return $out.ToArray()
}

function Test-PnhManifestCopyEntry {
    # Ollama 0.40.15 keeps the registry manifest itself as a blob and lists it as an extra layer of the manifest
    # it writes (mediaType application/vnd.docker.distribution.manifest.v2+json). Not part of the model.
    param([Parameter(Mandatory)]$Entry)
    return ([string]$Entry.MediaType -match 'distribution\.manifest\.v2\+json$')
}

function Get-PnhManifestBytes {
    # model size: config + layers, without Ollama's copy of the registry manifest
    param([Parameter(Mandatory)]$Manifest)
    [int64]$sum = 0
    foreach ($e in @(Get-PnhManifestEntries -Manifest $Manifest)) { if (-not (Test-PnhManifestCopyEntry $e)) { $sum += $e.Size } }
    return $sum
}

function Get-PnhManifestKey {
    # identity of a manifest: its model digests in order (registry manifest and Ollama's local one compare equal)
    param([Parameter(Mandatory)]$Manifest)
    return ((@(Get-PnhManifestEntries -Manifest $Manifest) | Where-Object { -not (Test-PnhManifestCopyEntry $_) } | ForEach-Object { $_.Digest }) -join ',')
}

function Test-PnhSizeMatch {
    param([int64]$Expected, [int64]$Actual, [double]$TolerancePercent = 1)
    if ($Expected -le 0) { return $true }
    return ([math]::Abs([double]($Actual - $Expected)) * 100.0 -le [double]$Expected * $TolerancePercent)
}

function Measure-PnhBuildNeed {
    # -> @{DownloadBytes; DiskBytes}. Blobs: @{Digest; Size; Complete; PartialBytes}, deduplicated by digest.
    # PartialBytes = size of Ollama's preallocated "-partial" file, already on the disk.
    param(
        [bool]$RuntimeInstalled,
        [int64]$ZipSize,
        [int64]$ZipHave,
        [int64]$ExtractedBytes,
        [object[]]$Blobs,
        [int64]$ReserveBytes
    )
    [int64]$download = 0; [int64]$disk = 0
    if (-not $RuntimeInstalled) {
        $zipRest = [math]::Max([int64]0, $ZipSize - $ZipHave)
        $download += $zipRest
        $disk += $zipRest + $ExtractedBytes
    }
    $seen = @{}
    foreach ($b in @($Blobs | Where-Object { $null -ne $_ })) {
        if ($seen.ContainsKey($b.Digest)) { continue }
        $seen[$b.Digest] = $true
        if ($b.Complete) { continue }
        $download += [int64]$b.Size
        $disk += [math]::Max([int64]0, [int64]$b.Size - [int64]$b.PartialBytes)
    }
    return [pscustomobject]@{ DownloadBytes = $download; DiskBytes = $disk + $ReserveBytes }
}

function Format-PnhBytes {
    param([int64]$Bytes)
    return ([double]$Bytes / 1e9).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + ' GB'
}

function Format-PnhDuration {
    # remaining time in plain words; $null or negative -> "estimating"
    param($Seconds)
    if ($null -eq $Seconds -or [double]$Seconds -lt 0) { return (Get-PnhBuildText 'eta.calc') }
    $s = [double]$Seconds
    if ($s -lt 60) { return (Get-PnhBuildText 'eta.lessMinute') }
    if ($s -lt 5400) {
        $m = [int][math]::Ceiling($s / 60)
        if ($m -le 1) { return (Get-PnhBuildText 'eta.minute') }
        return (Get-PnhBuildText 'eta.minutes' @($m))
    }
    $total5 = [int]([math]::Round($s / 300) * 5)       # whole hours and minutes rounded to 5
    $h = [int][math]::Floor($total5 / 60); $m = $total5 % 60
    if ($h -eq 1 -and $m -eq 0) { return (Get-PnhBuildText 'eta.hour') }
    if ($h -eq 1) { return (Get-PnhBuildText 'eta.hourMinutes' @($m)) }
    if ($m -eq 0) { return (Get-PnhBuildText 'eta.hours' @($h)) }
    return (Get-PnhBuildText 'eta.hoursMinutes' @($h, $m))
}

function New-PnhProgress {
    param([int64]$TotalBytes, [int]$WindowSeconds = 30)
    return @{
        Total = $TotalBytes; Done = [int64]0; Resumed = [int64]0; RuntimeDone = [int64]0; BlobDone = @{}
        Samples = New-Object System.Collections.Generic.List[object]; Window = $WindowSeconds
        LastEvent = [datetime]::MinValue
    }
}

function Add-PnhProgressSample {
    # moving window of (time, bytes really transferred); resumed bytes do not count as speed
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][datetime]$Time, [int64]$Done)
    $State.Done = $Done
    $State.Samples.Add(@{ Time = $Time; Bytes = $Done - $State.Resumed })
    while ($State.Samples.Count -gt 2 -and ($Time - $State.Samples[0].Time).TotalSeconds -gt $State.Window) {
        $State.Samples.RemoveAt(0)
    }
}

function Get-PnhRemainingSeconds {
    param([Parameter(Mandatory)][hashtable]$State)
    if ($State.Done -ge $State.Total) { return 0 }
    if ($State.Samples.Count -lt 2) { return $null }
    $first = $State.Samples[0]; $last = $State.Samples[$State.Samples.Count - 1]
    $dt = ($last.Time - $first.Time).TotalSeconds
    if ($dt -lt 3) { return $null }
    $rate = ($last.Bytes - $first.Bytes) / $dt
    if ($rate -le 0) { return $null }
    return (($State.Total - $State.Done) / $rate)
}

function Format-PnhProgressText {
    param([int64]$Done, [int64]$Total, $RemainingSeconds)
    return (Get-PnhBuildText 'progress.line' @((Format-PnhBytes $Done), (Format-PnhBytes $Total), (Format-PnhDuration $RemainingSeconds)))
}

function Update-PnhProgress {
    # recompute Done from runtime + blob counters, send a throttled progress event
    param([switch]$Force)
    $st = $script:PnhProgress
    if (-not $st) { return }
    [int64]$done = $st.RuntimeDone
    foreach ($v in $st.BlobDone.Values) { $done += [int64]$v }
    if ($done -gt $st.Total) { $done = $st.Total }
    $now = [datetime]::UtcNow
    Add-PnhProgressSample -State $st -Time $now -Done $done
    if (-not $Force -and ($now - $st.LastEvent).TotalMilliseconds -lt 400) { return }
    $st.LastEvent = $now
    $rem = Get-PnhRemainingSeconds -State $st
    Send-PnhBuildEvent @{
        Type = 'progress'; Done = $done; Total = $st.Total; Remaining = $rem
        Text = (Format-PnhProgressText -Done $done -Total $st.Total -RemainingSeconds $rem)
    }
}

function Format-PnhReadme {
    # placeholders {{BUILT_AT}} {{BUILDER}} {{OLLAMA_VERSION}} {{PROFILE}} {{MODELS}}; result has CRLF line ends
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][hashtable]$Values, [object[]]$Models)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($m in @($Models | Where-Object { $null -ne $_ })) { $lines.Add(('  - {0}  ({1})' -f $m.tag, (Format-PnhBytes ([int64]$m.bytes)))) }
    $text = $Template
    $all = @{} + $Values
    $all['MODELS'] = if ($lines.Count -gt 0) { $lines -join "`n" } else { '  -' }
    foreach ($k in $all.Keys) { $text = $text.Replace('{{' + $k + '}}', [string]$all[$k]) }
    $parts = [regex]::Split($text, "`r`n|`n|`r")
    $count = $parts.Count
    if ($count -gt 0 -and $parts[$count - 1] -eq '') { $count-- }
    return ((($parts[0..([math]::Max(0, $count - 1))]) -join "`r`n") + "`r`n")
}

function ConvertTo-PnhDriveJson {
    # drive.json (ARCHITECTURE.md 5.9), formatted like build-drive.sh writes it
    param([string]$BuiltAt, [string]$Builder, [string]$Ollama, [string]$ProfileName, [object[]]$Models)
    $q = { param($s) '"' + ([string]$s).Replace('\', '\\').Replace('"', '\"') + '"' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`n")
    [void]$sb.Append('  "builtAt": ' + (& $q $BuiltAt) + ",`n")
    [void]$sb.Append('  "builder": ' + (& $q $Builder) + ",`n")
    [void]$sb.Append('  "ollama": ' + (& $q $Ollama) + ",`n")
    [void]$sb.Append('  "profile": ' + (& $q $ProfileName) + ",`n")
    $list = @($Models | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { [void]$sb.Append("  `"models`": []`n") }
    else {
        [void]$sb.Append("  `"models`": [`n")
        for ($i = 0; $i -lt $list.Count; $i++) {
            $m = $list[$i]
            [void]$sb.Append("    {`n")
            [void]$sb.Append('      "id": ' + (& $q $m.id) + ",`n")
            [void]$sb.Append('      "tag": ' + (& $q $m.tag) + ",`n")
            [void]$sb.Append('      "bytes": ' + ([int64]$m.bytes).ToString([System.Globalization.CultureInfo]::InvariantCulture) + "`n")
            [void]$sb.Append($(if ($i -lt $list.Count - 1) { "    },`n" } else { "    }`n" }))
        }
        [void]$sb.Append("  ]`n")
    }
    [void]$sb.Append("}`n")
    return $sb.ToString()
}

function New-PnhCurlArguments {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Destination, [switch]$RevokeBestEffort)
    $a = '-L --fail -C - -sS --connect-timeout 30 --speed-limit 1024 --speed-time 60'
    if ($RevokeBestEffort) { $a += ' --ssl-revoke-best-effort' }
    return ('{0} -o "{1}" "{2}"' -f $a, $Destination, $Url)
}

function Get-PnhOllamaEnvironment {
    # per-process environment for "ollama serve" on the drive (never system-wide)
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)][int]$Port, [string]$CurrentPath = $env:PATH)
    return @{
        OLLAMA_MODELS  = $Paths.Models
        OLLAMA_HOST    = "127.0.0.1:$Port"
        OLLAMA_NOPRUNE = '1'          # keep partial downloads of an interrupted build (Ollama prunes them on start)
        USERPROFILE    = $Paths.Home  # Ollama's key pair stays on the drive
        HOME           = $Paths.Home
        PATH           = ('{0};{1};{2}' -f $Paths.VulkanDir, $Paths.OllamaDir, $CurrentPath)
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Files, processes, HTTP
# ---------------------------------------------------------------------------------------------------------------------
function Get-PnhFileLength {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) { return [int64](Get-Item -LiteralPath $Path -Force).Length }
    return [int64]0
}

function Get-PnhSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-PnhTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Bom, [Parameter(Mandatory)]$Paths)
    Assert-PnhPathAllowed -Path $Path -Paths $Paths
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = $Path + '.pnh-tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Remove-PnhOwnFile {
    param([Parameter(Mandatory)][string]$Path, $Paths)
    if ($Paths) { Assert-PnhPathAllowed -Path $Path -Paths $Paths }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force }
}

function Start-PnhBuildProcess {
    # no console window: UseShellExecute=$false + CreateNoWindow=$true, output read asynchronously
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ArgumentList = '',
        [System.Collections.IDictionary]$Environment,
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Environment) { foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] } }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    return [pscustomobject]@{
        Process    = $p
        StdOutTask = $p.StandardOutput.ReadToEndAsync()
        StdErrTask = $p.StandardError.ReadToEndAsync()
    }
}

function Get-PnhTaskText {
    param($Task, [int]$WaitMs = 2000)
    if ($null -eq $Task) { return '' }
    try { if ($Task.Wait($WaitMs)) { return [string]$Task.Result } } catch { }
    return ''
}

function Stop-PnhBuildProcess {
    param($Handle)
    try { if ($Handle -and $Handle.Process -and -not $Handle.Process.HasExited) { $Handle.Process.Kill(); [void]$Handle.Process.WaitForExit(10000) } } catch { }
}

function Enable-PnhTls {
    # Windows PowerShell 5.1 on .NET 4.x may still default to TLS 1.0; GitHub and the registry need 1.2+
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
}

function Get-PnhWebErrorText {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
    if ($ex -and $ex.Response) {
        try {
            $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            return ('{0} {1}' -f [int]$ex.Response.StatusCode, $body.Trim())
        } catch { }
    }
    return $ErrorRecord.Exception.Message
}

function Invoke-PnhHttpGetString {
    param([Parameter(Mandatory)][string]$Url, [string]$Accept, [switch]$NoProxy, [int]$TimeoutSeconds = 120)
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.Timeout = $TimeoutSeconds * 1000
    $req.ReadWriteTimeout = $TimeoutSeconds * 1000
    $ver = '0'
    if ($script:PnhVersions) { $ver = [string]$script:PnhVersions.builder.version }
    $req.UserAgent = "plug-n-heal-builder/$ver"
    if ($Accept) { $req.Accept = $Accept }
    if ($NoProxy) { $req.Proxy = $null }
    $resp = $req.GetResponse()
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        return $sr.ReadToEnd()
    } finally { $resp.Close() }
}

function Get-PnhCurlPath {
    # always the real curl.exe: in Windows PowerShell 5.1 "curl" is an alias of Invoke-WebRequest
    if (-not $env:SystemRoot) { return 'curl' }
    return [System.IO.Path]::Combine([string[]]@($env:SystemRoot, 'System32', 'curl.exe'))
}

# ---------------------------------------------------------------------------------------------------------------------
# Download with curl.exe in a PowerShell retry loop (technik.md 6.1)
# ---------------------------------------------------------------------------------------------------------------------
function Invoke-PnhDownload {
    # Every attempt is a new curl -L -C - : fresh signed redirect, resume from the bytes on disk.
    # curl --retry would throw away the data of a failed attempt, so the loop lives here.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int64]$ExpectedSize,
        [string]$Sha256,
        [scriptblock]$OnProgress,
        [int]$MaxAttempts = 100,
        [int]$PollMilliseconds = 500,
        [string]$CurlPath = (Get-PnhCurlPath)
    )
    $revoke = $true
    $hashRetries = 0
    $attempt = 0
    while ($true) {
        $have = Get-PnhFileLength $Destination
        if ($have -ge $ExpectedSize) {
            if ($have -gt $ExpectedSize) {
                Write-PnhBuildLog -Level Warn -Message "$Destination is larger than expected ($have > $ExpectedSize), starting over"
                Remove-PnhOwnFile -Path $Destination
                if ($hashRetries -ge 1) { throw (New-PnhBuildError -Code 'hash' -Message (Get-PnhBuildText 'err.hash' @($Url))) }
                $hashRetries++
                continue
            }
            if (-not $Sha256) { break }
            Send-PnhPhase 'phase.verify'
            $hash = Get-PnhSha256 -Path $Destination
            if ($hash -eq $Sha256.ToLowerInvariant()) { break }
            Write-PnhBuildLog -Level Warn -Message "sha256 mismatch for $Destination ($hash), downloading again"
            Remove-PnhOwnFile -Path $Destination
            if ($hashRetries -ge 1) { throw (New-PnhBuildError -Code 'hash' -Message (Get-PnhBuildText 'err.hash' @($Url))) }
            $hashRetries++
            continue
        }
        $attempt++
        if ($attempt -gt $MaxAttempts) {
            throw (New-PnhBuildError -Code 'download' -Message (Get-PnhBuildText 'err.download' @($MaxAttempts, $Url)))
        }
        Assert-PnhNotCancelled
        $arguments = New-PnhCurlArguments -Url $Url -Destination $Destination -RevokeBestEffort:$revoke
        Write-PnhBuildLog -Message "curl attempt $attempt, $have bytes on disk"
        $h = Start-PnhBuildProcess -FilePath $CurlPath -ArgumentList $arguments
        while (-not $h.Process.HasExited) {
            if ($script:PnhCancel -and $script:PnhCancel['Requested']) { Stop-PnhBuildProcess $h; Assert-PnhNotCancelled }
            if ($OnProgress) { & $OnProgress (Get-PnhFileLength $Destination) }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        $code = [int]$h.Process.ExitCode
        $err = (Get-PnhTaskText $h.StdErrTask).Trim()
        if ($OnProgress) { & $OnProgress (Get-PnhFileLength $Destination) }
        if ($code -eq 0) { continue }
        Write-PnhBuildLog -Level Warn -Message "curl exit $code (attempt $attempt): $err"
        if ($code -eq 2 -and $revoke) { $revoke = $false; continue }   # old curl.exe without --ssl-revoke-best-effort
        if ($code -eq 33) { Remove-PnhOwnFile -Path $Destination }      # range refused: start this file over
        Start-Sleep -Seconds ([math]::Min(60, 5 * $attempt))
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Drive, runtime, app
# ---------------------------------------------------------------------------------------------------------------------
function Get-PnhDriveInfo {
    param([Parameter(Mandatory)][string]$DriveRoot)
    $root = [System.IO.Path]::GetPathRoot($DriveRoot)
    $di = New-Object System.IO.DriveInfo($root)
    if (-not $di.IsReady) { throw (New-PnhBuildError -Code 'noDrive' -Message (Get-PnhBuildText 'err.noDrive' @($root))) }
    return [pscustomobject]@{
        Root = $di.Name; Label = $di.VolumeLabel; FileSystem = $di.DriveFormat; FreeBytes = [int64]$di.AvailableFreeSpace
        SizeBytes = [int64]$di.TotalSize; DriveType = [string]$di.DriveType
    }
}

function Get-PnhUsbDriveLetters {
    $letters = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($disk in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
            if ($disk.InterfaceType -ne 'USB' -and "$($disk.MediaType)" -notmatch 'External|Removable') { continue }
            foreach ($part in @(Get-CimAssociatedInstance -InputObject $disk -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue)) {
                foreach ($ld in @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
                    if ($ld.DeviceID) { $letters.Add([string]$ld.DeviceID) }
                }
            }
        }
    } catch { }
    try {
        # USB-attached SCSI (UAS) SSDs report InterfaceType SCSI above, but BusType USB here
        foreach ($disk in @(Get-Disk -ErrorAction Stop | Where-Object { "$($_.BusType)" -in @('USB', 'SD', 'MMC', '1394') })) {
            foreach ($part in @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
                if ($part.DriveLetter -and "$($part.DriveLetter)".Trim()) { $letters.Add(("{0}:" -f $part.DriveLetter)) }
            }
        }
    } catch { }
    return @($letters | Select-Object -Unique)
}

function Get-PnhCandidateDrives {
    # external and removable drives (never the Windows drive); -All adds internal ones (e.g. Thunderbolt NVMe)
    param([switch]$All)
    $sys = "$env:SystemDrive".TrimEnd('\')
    $usb = @(Get-PnhUsbDriveLetters)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $d.IsReady) { continue }
            $letter = $d.Name.Substring(0, 2)
            if ($letter -eq $sys) { continue }
            if ("$($d.DriveType)" -notin @('Removable', 'Fixed')) { continue }
            $external = ("$($d.DriveType)" -eq 'Removable') -or ($usb -contains $letter)
            if (-not $All -and -not $external) { continue }
            $list.Add([pscustomobject]@{
                    Letter = $letter; Root = $d.Name; Label = $d.VolumeLabel; SizeBytes = [int64]$d.TotalSize
                    FreeBytes = [int64]$d.AvailableFreeSpace; FileSystem = $d.DriveFormat; External = $external
                })
        } catch { }
    }
    return $list.ToArray()
}

function Get-PnhExistingBuildBytes {
    # bytes a previous run already put on the drive (counted as available again for the size check)
    param([Parameter(Mandatory)]$Paths)
    [int64]$sum = 0
    foreach ($dir in @($Paths.Blobs, $Paths.OllamaDir, $Paths.Downloads)) {
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)) { $sum += $f.Length }
        }
    }
    return $sum
}

function Test-PnhRuntimeInstalled {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)]$Runtime)
    if (-not (Test-Path -LiteralPath $Paths.OllamaExe -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Paths.RuntimeMarker -PathType Leaf)) { return $false }
    try {
        $m = Read-PnhJsonFile -Path $Paths.RuntimeMarker
        return ($m.ollama -eq $Runtime.version -and "$($m.sha256)".ToLowerInvariant() -eq "$($Runtime.sha256)".ToLowerInvariant())
    } catch { return $false }
}

function Expand-PnhRuntime {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)]$Runtime)
    Assert-PnhPathAllowed -Path $Paths.OllamaDir -Paths $Paths
    if (Test-Path -LiteralPath $Paths.OllamaDir) {
        # another version (or an interrupted extraction) is there: the runtime folder belongs to the builder
        Write-PnhBuildLog -Message "replacing $($Paths.OllamaDir)"
        Remove-Item -LiteralPath $Paths.OllamaDir -Recurse -Force
    }
    Remove-PnhOwnFile -Path $Paths.RuntimeMarker -Paths $Paths
    [void](New-Item -ItemType Directory -Path $Paths.OllamaDir -Force)
    $tar = [System.IO.Path]::Combine([string[]]@($env:SystemRoot, 'System32', 'tar.exe'))
    if (Test-Path -LiteralPath $tar) {
        $h = Start-PnhBuildProcess -FilePath $tar -ArgumentList ('-xf "{0}" -C "{1}"' -f $ZipPath, $Paths.OllamaDir)
        while (-not $h.Process.HasExited) { Start-Sleep -Milliseconds 500 }
        if ($h.Process.ExitCode -ne 0) {
            throw (New-PnhBuildError -Code 'extract' -Message (Get-PnhBuildText 'err.extract' @("tar exit $($h.Process.ExitCode): $((Get-PnhTaskText $h.StdErrTask).Trim())")))
        }
    } else {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $Paths.OllamaDir -Force
    }
    if (-not (Test-Path -LiteralPath $Paths.OllamaExe -PathType Leaf)) {
        throw (New-PnhBuildError -Code 'extract' -Message (Get-PnhBuildText 'err.extract' @('ollama.exe missing')))
    }
    $marker = '{{"ollama": "{0}", "asset": "{1}", "sha256": "{2}", "extractedAt": "{3}"}}' -f $Runtime.version, $Runtime.asset, "$($Runtime.sha256)".ToLowerInvariant(), (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-PnhTextFile -Path $Paths.RuntimeMarker -Text ($marker + "`n") -Paths $Paths
}

function Copy-PnhApp {
    # <drive>\PlugNHeal\app\ becomes a copy of src\ (stale files of an older version are removed)
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)][string]$SourceDir)
    $src = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\', '/')
    $startCmd = [System.IO.Path]::Combine($src, 'START.cmd')
    if (-not (Test-Path -LiteralPath $startCmd -PathType Leaf)) { throw (New-PnhBuildError -Code 'src' -Message (Get-PnhBuildText 'err.src' @($startCmd))) }
    Assert-PnhPathAllowed -Path $Paths.App -Paths $Paths
    [void](New-Item -ItemType Directory -Path $Paths.App -Force)
    $keep = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/')
        $dst = [System.IO.Path]::Combine($Paths.App, $rel)
        Assert-PnhPathAllowed -Path $dst -Paths $Paths
        $dir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        $keep[$rel.Replace('/', '\').ToLowerInvariant()] = $true
    }
    $appFull = [System.IO.Path]::GetFullPath($Paths.App).TrimEnd('\', '/')
    foreach ($f in @(Get-ChildItem -LiteralPath $appFull -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($appFull.Length).TrimStart('\', '/').Replace('/', '\').ToLowerInvariant()
        if (-not $keep.ContainsKey($rel)) { Remove-PnhOwnFile -Path $f.FullName -Paths $Paths }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $appFull -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending)) {
        if (@(Get-ChildItem -LiteralPath $d.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath $d.FullName -Force }
    }
    Copy-Item -LiteralPath $startCmd -Destination $Paths.StartCmd -Force
}

function Unblock-PnhDriveFiles {
    # Removes the Mark-of-the-Web (Zone.Identifier stream) from <drive>\PlugNHeal and <drive>\START.cmd. Files
    # copied from a downloaded ZIP that was not unblocked keep that mark on an NTFS drive, and Windows then warns
    # or blocks when START.cmd is double-clicked (security warning, SmartScreen). exFAT has no alternate data
    # streams, so there it changes nothing. Best effort: never fails the build; returns the number of files
    # handed to Unblock-File.
    param([Parameter(Mandatory)]$Paths)
    if (-not (Get-Command -Name Unblock-File -ErrorAction SilentlyContinue)) {
        Write-PnhBuildLog -Message 'Unblock-File is not available here, Mark-of-the-Web not checked'
        return 0
    }
    $files = New-Object System.Collections.Generic.List[string]
    try {
        if (Test-Path -LiteralPath $Paths.Root -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $Paths.Root -Recurse -File -Force -ErrorAction SilentlyContinue)) { $files.Add($f.FullName) }
        }
        if (Test-Path -LiteralPath $Paths.StartCmd -PathType Leaf) { $files.Add($Paths.StartCmd) }
        $failed = 0
        $firstError = ''
        foreach ($f in $files) {
            Assert-PnhPathAllowed -Path $f -Paths $Paths
            try { Unblock-File -LiteralPath $f -ErrorAction Stop } catch {
                $failed++
                if (-not $firstError) { $firstError = "$f`: $($_.Exception.Message)" }
            }
        }
        # one log line, no warning event: on exFAT a failure only means there is no stream to remove
        Write-PnhBuildLog -Message "Mark-of-the-Web removed where present: $($files.Count) files checked, $failed not unblocked $firstError"
    } catch {
        Write-PnhBuildLog -Level Warn -Message "Unblock-File skipped: $($_.Exception.Message)"
    }
    return $files.Count
}

# ---------------------------------------------------------------------------------------------------------------------
# Models: registry manifests, Ollama on the drive, /api/pull, verification
# ---------------------------------------------------------------------------------------------------------------------
function Get-PnhRegistryManifest {
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)]$Versions)
    $p = Split-PnhModelTag -Tag $Tag
    $url = '{0}/v2/{1}/{2}/manifests/{3}' -f "$($Versions.registry.url)".TrimEnd('/'), $p.Namespace, $p.Name, $p.Tag
    $last = $null
    for ($i = 1; $i -le 5; $i++) {
        Assert-PnhNotCancelled
        try {
            $raw = Invoke-PnhHttpGetString -Url $url -Accept $Versions.registry.manifestAccept
            return [pscustomobject]@{ Raw = $raw; Manifest = ($raw | ConvertFrom-Json); Url = $url }
        } catch {
            $last = Get-PnhWebErrorText $_
            Write-PnhBuildLog -Level Warn -Message "GET $url failed (attempt $i): $last"
            if ($last -match '^404') { break }
            Start-Sleep -Seconds (3 * $i)
        }
    }
    throw (New-PnhBuildError -Code 'registry' -Message (Get-PnhBuildText 'err.registry' @("$Tag, $last")))
}

function Get-PnhValue {
    # Read a key or property from a hashtable or object without failing (the builder is not part of src\, so it
    # carries its own copy of the helper instead of loading src\lib\Common.ps1).
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name, [AllowNull()][object]$Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    try { return $prop.Value } catch { return $Default }
}

# ---------------------------------------------------------------------------------------------------------------------
# Hugging Face models (catalogue entries with source 'huggingface')
#
# Those models are not in the Ollama registry. The builder downloads their GGUF files from Hugging Face and
# copies the small Ollama metadata blobs (config, params, license) from the pinned files in this repository,
# then writes the Ollama-style manifest itself. The layout is byte-for-byte what a registry pull produces, so
# Ollama reads the model offline afterwards. builder\hf-models.json pins every file by sha256 and size; for the
# Hugging Face files the sha256 is the repository's Git-LFS object id, so a download is verified by content.
# ---------------------------------------------------------------------------------------------------------------------
function Read-PnhHfPins {
    # -> parsed builder\hf-models.json; throws 'hfPin' when it is missing or broken
    param([string]$Path)
    if (-not $Path) { $Path = [System.IO.Path]::Combine($script:PnhBuilderRoot, 'hf-models.json') }
    try {
        $v = Read-PnhJsonFile -Path $Path
        if ($null -eq (Get-PnhValue $v 'models')) { throw 'models' }
        return $v
    } catch {
        throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @('$Path', $_.Exception.Message)))
    }
}

function Get-PnhHfModelPin {
    # the pin entry (blobs, repo, revision, baseUrl) of one model; throws 'hfPin' when the tag has no pin
    param([Parameter(Mandatory)]$PinFile, [Parameter(Mandatory)][string]$Tag)
    $entry = Get-PnhValue (Get-PnhValue $PinFile 'models') $Tag
    if ($null -eq $entry -or $null -eq (Get-PnhValue $entry 'blobs')) {
        throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @($Tag, 'no pin in builder\hf-models.json')))
    }
    return $entry
}

function Get-PnhHfBlobPath {
    # 'hf-models/params.json' from the pin file, relative to the builder root
    param([Parameter(Mandatory)][string]$File)
    return [System.IO.Path]::Combine($script:PnhBuilderRoot, ($File.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
}

function Get-PnhHfUrl {
    param([Parameter(Mandatory)]$Pin, [Parameter(Mandatory)][string]$Name)
    $base = [string](Get-PnhValue $Pin 'baseUrl')
    if (-not $base) { $base = 'https://huggingface.co' }
    $repo = [string](Get-PnhValue $Pin 'repo')
    $rev = [string](Get-PnhValue $Pin 'revision')
    if (-not $repo -or -not $rev) {
        throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @($repo, 'repo/revision missing')))
    }
    return ('{0}/{1}/resolve/{2}/{3}' -f $base.TrimEnd('/'), $repo, $rev, $Name)
}

function New-PnhHfManifest {
    # Ollama-style manifest for the pinned blobs; layer order like registry.ollama.ai (projector, model, license, params)
    param([Parameter(Mandatory)]$Pin)
    $blobs = @(Get-PnhValue $Pin 'blobs' @())
    if ($blobs.Count -eq 0) { throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @('', 'blobs missing'))) }
    $layers = New-Object System.Collections.Generic.List[object]
    $config = $null
    foreach ($b in $blobs) {
        $role = [string](Get-PnhValue $b 'role')
        $sha = [string](Get-PnhValue $b 'sha256')
        $size = Get-PnhValue $b 'size'
        if (-not $sha -or $null -eq $size) { throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @($role, 'sha256/size missing'))) }
        if ($role -eq 'config') {
            $config = @{ mediaType = 'application/vnd.docker.container.image.v1+json'; digest = ('sha256:' + $sha); size = [int64]$size }
        } else {
            $layers.Add(@{ mediaType = ('application/vnd.ollama.image.' + $role); digest = ('sha256:' + $sha); size = [int64]$size })
        }
    }
    if (-not $config) { throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @('', 'config blob missing'))) }
    return [pscustomobject]@{ schemaVersion = 2; mediaType = 'application/vnd.docker.distribution.manifest.v2+json'; config = $config; layers = $layers.ToArray() }
}

function Test-PnhHfPins {
    # the pinned repository blobs of every model exist with the pinned size and sha256 (fail early with 'hfPin', exit 2)
    param([Parameter(Mandatory)]$PinFile)
    $models = Get-PnhValue $PinFile 'models'
    foreach ($entry in @($models)) {
        foreach ($b in @(Get-PnhValue $entry 'blobs' @())) {
            if ((Get-PnhValue $b 'source') -ne 'repo') { continue }
            $role = [string](Get-PnhValue $b 'role')
            $sha = [string](Get-PnhValue $b 'sha256')
            $file = Get-PnhHfBlobPath -File ([string](Get-PnhValue $b 'file'))
            if (-not [System.IO.File]::Exists($file)) {
                throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @($role, "missing file $file")))
            }
            $len = (Get-Item -LiteralPath $file).Length
            if ($len -ne [int64](Get-PnhValue $b 'size')) {
                throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @($role, "size of $file is $len, pinned " + [int64](Get-PnhValue $b 'size'))))
            }
            $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -ne $sha) {
                throw (New-PnhBuildError -Code 'hfPin' -Message (Get-PnhBuildText 'err.hfPin' @($role, "sha256 of $file is $hash, pinned $sha")))
            }
        }
    }
}

function Set-PnhHfRepoBlobs {
    # copies the pinned repository blobs (config, params, license) into models\blobs as sha256-<hex>; skips what is there
    param([Parameter(Mandatory)]$Pin, [Parameter(Mandatory)]$Paths)
    foreach ($b in @(Get-PnhValue $Pin 'blobs' @())) {
        if ((Get-PnhValue $b 'source') -ne 'repo') { continue }
        $sha = [string](Get-PnhValue $b 'sha256')
        $blob = Get-PnhBlobPath -ModelsDir $Paths.Models -Digest ('sha256:' + $sha)
        if ((Get-PnhFileLength $blob) -eq [int64](Get-PnhValue $b 'size')) { continue }
        $src = Get-PnhHfBlobPath -File ([string](Get-PnhValue $b 'file'))
        Write-PnhBuildLog -Message ("pinned blob " + [string](Get-PnhValue $b 'role') + ' (' + (Format-PnhBytes ([int64](Get-PnhValue $b 'size'))) + ')')
        Copy-Item -LiteralPath $src -Destination $blob -Force
    }
}

function Invoke-PnhHfDownload {
    # downloads the Hugging Face GGUF files (resume, sha256, verified by Invoke-PnhDownload) into models\blobs and
    # writes the Ollama-style manifest into models\manifests. An interrupted download leaves the "-partial" file for
    # the next run; the manifest is written last, like the registry path, so a half-built model is never complete.
    param([Parameter(Mandatory)]$Pin, [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)]$Paths, [Parameter(Mandatory)]$Manifest)
    foreach ($b in @(Get-PnhValue $Pin 'blobs' @())) {
        if ((Get-PnhValue $b 'source') -ne 'hf') { continue }
        $sha = [string](Get-PnhValue $b 'sha256')
        $size = [int64](Get-PnhValue $b 'size')
        $blob = Get-PnhBlobPath -ModelsDir $Paths.Models -Digest ('sha256:' + $sha)
        if ((Get-PnhFileLength $blob) -eq $size) {
            $script:PnhProgress.BlobDone[$sha] = $size
            Update-PnhProgress -Force
            continue
        }
        $role = [string](Get-PnhValue $b 'role')
        $name = [string](Get-PnhValue $b 'name')
        Send-PnhPhase 'phase.hf' @($name)
        $onProgress = { param([int64]$len) $script:PnhProgress.BlobDone[$sha] = [math]::Min([int64]$len, [int64]$size); Update-PnhProgress }
        Invoke-PnhDownload -Url (Get-PnhHfUrl -Pin $Pin -Name $name) -Destination ($blob + '-partial') `
            -ExpectedSize $size -Sha256 $sha -OnProgress $onProgress
        $part = $blob + '-partial'
        $tmp = $blob + '.pnh-tmp'
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        Move-Item -LiteralPath $part -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $blob -Force
        Write-PnhBuildLog -Message ("Hugging Face file " + $role + ' is in place and verified')
        $script:PnhProgress.BlobDone[$sha] = $size
        Update-PnhProgress -Force
    }
    $p = Split-PnhModelTag -Tag $Tag
    $dir = [System.IO.Path]::Combine([string[]]@($Paths.Models, 'manifests', 'registry.ollama.ai', $p.Namespace, $p.Name))
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $mp = [System.IO.Path]::Combine($dir, $p.Tag)
    $tmp = $mp + '.pnh-tmp'
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Manifest -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $mp -Force
}

function Get-PnhBlobState {
    param([Parameter(Mandatory)][string]$ModelsDir, [Parameter(Mandatory)]$Entry)
    $path = Get-PnhBlobPath -ModelsDir $ModelsDir -Digest $Entry.Digest
    $len = Get-PnhFileLength $path
    return [pscustomobject]@{
        Digest = $Entry.Digest; Size = [int64]$Entry.Size; Complete = ($len -eq [int64]$Entry.Size)
        PartialBytes = (Get-PnhFileLength ($path + '-partial'))
    }
}

function Test-PnhModelComplete {
    # manifest on the drive, (optionally) identical to the registry's, and every blob there with the right size
    param([Parameter(Mandatory)][string]$ModelsDir, [Parameter(Mandatory)][string]$Tag, $Expected, [string]$RegistryHost = 'registry.ollama.ai')
    $mp = Get-PnhManifestPath -ModelsDir $ModelsDir -Tag $Tag -RegistryHost $RegistryHost
    if (-not (Test-Path -LiteralPath $mp -PathType Leaf)) { return [pscustomobject]@{ Complete = $false; Reason = 'no manifest'; Manifest = $null; Bytes = 0 } }
    try { $local = Read-PnhJsonFile -Path $mp; $entries = @(Get-PnhManifestEntries -Manifest $local) }
    catch { return [pscustomobject]@{ Complete = $false; Reason = 'manifest unreadable'; Manifest = $null; Bytes = 0 } }
    if ($Expected -and (Get-PnhManifestKey $local) -ne (Get-PnhManifestKey $Expected)) {
        return [pscustomobject]@{ Complete = $false; Reason = 'manifest differs from registry'; Manifest = $local; Bytes = 0 }
    }
    $missing = @()
    [int64]$bytes = 0
    foreach ($e in $entries) {
        if (-not (Test-PnhManifestCopyEntry $e)) { $bytes += $e.Size }
        if (-not (Get-PnhBlobState -ModelsDir $ModelsDir -Entry $e).Complete) { $missing += $e.Digest }
    }
    $reason = 'ok'
    if ($missing.Count -gt 0) { $reason = 'missing or wrong size: ' + ($missing -join ', ') }
    return [pscustomobject]@{ Complete = ($missing.Count -eq 0); Reason = $reason; Manifest = $local; Bytes = $bytes }
}

function Get-PnhInstalledCatalogModels {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$ModelsDir)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Catalog.models)) {
        $st = Test-PnhModelComplete -ModelsDir $ModelsDir -Tag $m.tag
        if ($st.Complete) { $out.Add([pscustomobject]@{ id = $m.id; tag = $m.tag; bytes = $st.Bytes }) }
    }
    return $out.ToArray()
}

function Get-PnhFreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    try { return $l.LocalEndpoint.Port } finally { $l.Stop() }
}

function Start-PnhBuildOllama {
    param([Parameter(Mandatory)]$Paths, [int]$TimeoutSeconds = 60)
    $port = Get-PnhFreePort
    $envVars = Get-PnhOllamaEnvironment -Paths $Paths -Port $port
    Write-PnhBuildLog -Message "starting $($Paths.OllamaExe) serve on 127.0.0.1:$port"
    $h = Start-PnhBuildProcess -FilePath $Paths.OllamaExe -ArgumentList 'serve' -Environment $envVars -WorkingDirectory $Paths.OllamaDir
    $base = "http://127.0.0.1:$port"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($h.Process.HasExited) {
            $tail = (Get-PnhTaskText $h.StdErrTask).Trim()
            if ($tail.Length -gt 600) { $tail = $tail.Substring($tail.Length - 600) }
            throw (New-PnhBuildError -Code 'ollamaStart' -Message (Get-PnhBuildText 'err.ollamaStart' @("exit $($h.Process.ExitCode): $tail")))
        }
        try {
            $v = (Invoke-PnhHttpGetString -Url "$base/api/version" -NoProxy -TimeoutSeconds 3) | ConvertFrom-Json
            Write-PnhBuildLog -Message "ollama $($v.version) is up"
            return [pscustomobject]@{ BaseUrl = $base; Port = $port; Handle = $h; Version = $v.version }
        } catch { Start-Sleep -Milliseconds 500 }
    }
    Stop-PnhBuildProcess $h
    throw (New-PnhBuildError -Code 'ollamaStart' -Message (Get-PnhBuildText 'err.ollamaStart' @("no answer from $base/api/version")))
}

function Stop-PnhBuildOllama {
    param($Server)
    if (-not $Server) { return }
    Stop-PnhBuildProcess $Server.Handle
    if ($script:PnhBuildLogDir) {
        $log = (Get-PnhTaskText $Server.Handle.StdErrTask) + (Get-PnhTaskText $Server.Handle.StdOutTask)
        try { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:PnhBuildLogDir, 'ollama-serve.log'), $log, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
}

function Invoke-PnhOllamaPull {
    # POST /api/pull with a streamed answer: one JSON object per line (status, digest, total, completed)
    param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$Tag, [scriptblock]$OnEvent)
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create("$BaseUrl/api/pull")
    $req.Method = 'POST'
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Proxy = $null
    $req.Timeout = 120000
    $req.ReadWriteTimeout = 900000
    $body = [System.Text.Encoding]::UTF8.GetBytes(('{{"model": "{0}", "stream": true}}' -f $Tag))
    $req.ContentLength = $body.Length
    $s = $req.GetRequestStream(); $s.Write($body, 0, $body.Length); $s.Close()
    $resp = $req.GetResponse()
    $success = $false
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        while ($null -ne ($line = $sr.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $evt = $line | ConvertFrom-Json
            if ($evt.error) { throw "ollama: $($evt.error)" }
            if ($OnEvent) { & $OnEvent $evt }
            if ($evt.status -eq 'success') { $success = $true }
            if ($script:PnhCancel -and $script:PnhCancel['Requested']) { $req.Abort(); Assert-PnhNotCancelled }
        }
    } finally { $resp.Close() }
    if (-not $success) { throw 'pull ended without "success"' }
}

function Invoke-PnhModelPull {
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Paths, [int]$MaxAttempts = 5)
    $needed = @{}
    foreach ($e in @(Get-PnhManifestEntries -Manifest $Item.Manifest)) {
        if (-not (Get-PnhBlobState -ModelsDir $Paths.Models -Entry $e).Complete) { $needed[$e.Digest] = [int64]$e.Size }
    }
    $seen = @{}
    $onEvent = {
        param($evt)
        $d = [string]$evt.digest
        if ($d -and $needed.ContainsKey($d) -and $null -ne $evt.completed) {
            $c = [math]::Min([int64]$evt.completed, $needed[$d])
            if (-not $seen.ContainsKey($d)) { $seen[$d] = $true; $script:PnhProgress.Resumed += $c }
            $script:PnhProgress.BlobDone[$d] = $c
            Update-PnhProgress
        }
    }
    $attempt = 0
    while ($true) {
        $attempt++
        Assert-PnhNotCancelled
        try {
            Invoke-PnhOllamaPull -BaseUrl $Server.BaseUrl -Tag $Item.Tag -OnEvent $onEvent
            break
        } catch {
            if ((Get-PnhErrorCode $_) -eq 'cancelled') { throw }
            $msg = Get-PnhWebErrorText $_
            Write-PnhBuildLog -Level Warn -Message "pull $($Item.Tag) attempt $attempt failed: $msg"
            if ($attempt -ge $MaxAttempts -or $Server.Handle.Process.HasExited) {
                throw (New-PnhBuildError -Code 'pull' -Message (Get-PnhBuildText 'err.pull' @($Item.Tag, $msg)))
            }
            Start-Sleep -Seconds (10 * $attempt)
            $seen.Clear()   # resumed bytes of the next attempt do not count as speed
        }
    }
    foreach ($d in $needed.Keys) { $script:PnhProgress.BlobDone[$d] = $needed[$d] }
    Update-PnhProgress -Force
}

function Write-PnhLicenses {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)]$Versions, [Parameter(Mandatory)][object[]]$Plan, [Parameter(Mandatory)][string]$RepoRoot)
    $notices = [System.IO.Path]::Combine($RepoRoot, 'THIRD-PARTY-NOTICES.md')
    if (Test-Path -LiteralPath $notices -PathType Leaf) {
        $dst = [System.IO.Path]::Combine($Paths.Licenses, 'THIRD-PARTY-NOTICES.md')
        Assert-PnhPathAllowed -Path $dst -Paths $Paths
        Copy-Item -LiteralPath $notices -Destination $dst -Force
    } else {
        Write-PnhBuildLog -Level Warn -Message 'THIRD-PARTY-NOTICES.md not found in the repository root, not copied'
    }
    $text = $null; $last = $null
    for ($i = 1; $i -le 3 -and $null -eq $text; $i++) {
        try { $text = Invoke-PnhHttpGetString -Url $Versions.ollama.licenseUrl } catch { $last = Get-PnhWebErrorText $_; Start-Sleep -Seconds (3 * $i) }
    }
    if ($null -eq $text) { throw (New-PnhBuildError -Code 'license' -Message (Get-PnhBuildText 'err.license' @("$($Versions.ollama.licenseUrl): $last"))) }
    Write-PnhTextFile -Path ([System.IO.Path]::Combine($Paths.Licenses, 'ollama-LICENSE.txt')) -Text $text -Paths $Paths
    # licences shipped inside the runtime ZIP (llama.cpp, Go, cpp-httplib, ...)
    $bundled = [System.IO.Path]::Combine($Paths.OllamaDir, 'lib', 'ollama')
    if (Test-Path -LiteralPath $bundled) {
        $dstDir = [System.IO.Path]::Combine($Paths.Licenses, 'runtime')
        Assert-PnhPathAllowed -Path $dstDir -Paths $Paths
        [void](New-Item -ItemType Directory -Path $dstDir -Force)
        foreach ($f in @(Get-ChildItem -LiteralPath $bundled -File -Filter '*LICENSE*' -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $f.FullName -Destination ([System.IO.Path]::Combine($dstDir, $f.Name + '.txt')) -Force
        }
    }
    foreach ($item in $Plan) {
        $st = Test-PnhModelComplete -ModelsDir $Paths.Models -Tag $item.Tag
        if (-not $st.Manifest) { continue }
        $texts = New-Object System.Collections.Generic.List[string]
        foreach ($e in @(Get-PnhManifestEntries -Manifest $st.Manifest)) {
            if ($e.MediaType -like '*.license') {
                $bytes = [System.IO.File]::ReadAllBytes((Get-PnhBlobPath -ModelsDir $Paths.Models -Digest $e.Digest))
                $texts.Add((New-Object System.Text.UTF8Encoding($false)).GetString($bytes).Trim())
            }
        }
        if ($texts.Count -eq 0) { continue }
        $body = "Licence of the model $($item.Tag) (from its Ollama registry manifest)`n`n" + ($texts -join ("`n`n" + ('-' * 70) + "`n`n")) + "`n"
        $file = [System.IO.Path]::Combine([string[]]@($Paths.Licenses, 'models', ((Get-PnhSafeTagName $item.Tag) + '.LICENSE.txt')))
        Write-PnhTextFile -Path $file -Text ($body.Replace("`r`n", "`n")) -Paths $Paths
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The build (used by the wizard in a background runspace and by -NonInteractive)
# ---------------------------------------------------------------------------------------------------------------------
function Invoke-PnhBuild {
    param(
        [Parameter(Mandatory)][string]$DriveRoot,
        [Parameter(Mandatory)][string]$ProfileName,
        [string]$CatalogPath,
        [string]$RepoRoot = $script:PnhRepoRoot,
        [scriptblock]$Report,
        [hashtable]$Cancel
    )
    $ErrorActionPreference = 'Stop'
    $script:PnhReport = $Report
    $script:PnhCancel = $Cancel
    $RepoRoot = Resolve-PnhUserPath -Path $RepoRoot
    if (-not $CatalogPath) { $CatalogPath = [System.IO.Path]::Combine([string[]]@($RepoRoot, 'src', 'catalog', 'models.json')) }
    $CatalogPath = Resolve-PnhUserPath -Path $CatalogPath
    $srcDir = [System.IO.Path]::Combine($RepoRoot, 'src')

    Send-PnhPhase 'phase.check'
    $versions = Read-PnhVersions -Path ([System.IO.Path]::Combine($script:PnhBuilderRoot, 'versions.json'))
    $script:PnhVersions = $versions
    $catalog = Read-PnhBuildCatalog -Path $CatalogPath
    $models = @(Resolve-PnhBuildProfile -Catalog $catalog -Name $ProfileName)
    foreach ($f in @('START.cmd')) {
        $p = [System.IO.Path]::Combine($srcDir, $f)
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw (New-PnhBuildError -Code 'src' -Message (Get-PnhBuildText 'err.src' @($p))) }
    }
    $template = [System.IO.Path]::Combine($script:PnhBuilderRoot, 'README.txt.template')
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { throw (New-PnhBuildError -Code 'src' -Message (Get-PnhBuildText 'err.src' @($template))) }

    $root = ConvertTo-PnhDriveRoot -Drive $DriveRoot
    if (Test-PnhSystemDrive -DriveRoot $root) { throw (New-PnhBuildError -Code 'systemDrive' -Message (Get-PnhBuildText 'err.systemDrive')) }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw (New-PnhBuildError -Code 'noDrive' -Message (Get-PnhBuildText 'err.noDrive' @($root))) }
    $drive = Get-PnhDriveInfo -DriveRoot $root
    $fsCheck = Test-PnhFileSystem -FileSystem $drive.FileSystem
    if (-not $fsCheck.Ok) {
        $msg = if ($fsCheck.Reason -eq 'fat') { Get-PnhBuildText 'fat.text' @($drive.FileSystem) } else { Get-PnhBuildText 'fs.short' @($drive.FileSystem) }
        throw (New-PnhBuildError -Code $fsCheck.Reason -Message $msg)
    }
    $paths = Get-PnhBuildPaths -DriveRoot $root
    foreach ($d in @($paths.Root, $paths.App, $paths.Runtime, $paths.Blobs, $paths.Manifests, $paths.Home, $paths.Logs, $paths.Licenses, $paths.Downloads)) {
        Assert-PnhPathAllowed -Path $d -Paths $paths
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    }
    $script:PnhBuildLogDir = [System.IO.Path]::Combine($paths.Logs, ('build-{0}-{1}' -f [System.Environment]::MachineName, (Get-Date).ToString('yyyyMMdd-HHmmss')))
    [void](New-Item -ItemType Directory -Path $script:PnhBuildLogDir -Force)
    $script:PnhBuildLogFile = [System.IO.Path]::Combine($script:PnhBuildLogDir, 'build.log')
    Write-PnhBuildLog -Message ("plug-n-heal builder {0}, drive {1} ({2}, {3} free), profile {4}, PowerShell {5}" -f $versions.builder.version, $root, $drive.FileSystem, (Format-PnhBytes $drive.FreeBytes), $ProfileName, $PSVersionTable.PSVersion)

    # Manifests from the registry: exact sizes, catalogue check (> tolerance = refuse), what is already complete.
    # Hugging Face models (source 'huggingface') build the same manifest from the pin in builder\hf-models.json.
    $tolerance = 1.0
    if ($versions.sizeTolerancePercent) { $tolerance = [double]$versions.sizeTolerancePercent }
    $hfPins = $null
    if (@($models | Where-Object { [string](Get-PnhValue $_ 'source') -eq 'huggingface' }).Count -gt 0) {
        $hfPins = Read-PnhHfPins
        Test-PnhHfPins -Pin $hfPins
    }
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($m in $models) {
        if ([string](Get-PnhValue $m 'source') -eq 'huggingface') {
            $reg = [pscustomobject]@{ Raw = $null; Manifest = (New-PnhHfManifest -Pin (Get-PnhHfModelPin -PinFile $hfPins -Tag $m.tag)); Url = '' }
        } else {
            $reg = Get-PnhRegistryManifest -Tag $m.tag -Versions $versions
        }
        $bytes = Get-PnhManifestBytes -Manifest $reg.Manifest
        if (-not (Test-PnhSizeMatch -Expected ([int64]$m.bytes) -Actual $bytes -TolerancePercent $tolerance)) {
            throw (New-PnhBuildError -Code 'sizeMismatch' -Message (Get-PnhBuildText 'err.sizeMismatch' @($m.tag, $m.bytes, $bytes)))
        }
        $st = Test-PnhModelComplete -ModelsDir $paths.Models -Tag $m.tag -Expected $reg.Manifest
        Write-PnhBuildLog -Message ("model {0}: {1} bytes, on drive: {2}" -f $m.tag, $bytes, $st.Reason)
        $plan.Add([pscustomobject]@{ Entry = $m; Tag = $m.tag; Manifest = $reg.Manifest; Bytes = $bytes; Complete = $st.Complete })
    }

    # Space
    $blobStates = New-Object System.Collections.Generic.List[object]
    foreach ($item in $plan) {
        if ($item.Complete) { continue }
        foreach ($e in @(Get-PnhManifestEntries -Manifest $item.Manifest)) { $blobStates.Add((Get-PnhBlobState -ModelsDir $paths.Models -Entry $e)) }
    }
    $runtimeInstalled = Test-PnhRuntimeInstalled -Paths $paths -Runtime $versions.ollama
    $zipPath = [System.IO.Path]::Combine($paths.Downloads, [string]$versions.ollama.asset)
    $zipHave = Get-PnhFileLength $zipPath
    $need = Measure-PnhBuildNeed -RuntimeInstalled $runtimeInstalled -ZipSize ([int64]$versions.ollama.size) -ZipHave $zipHave `
        -ExtractedBytes ([int64]$versions.ollama.extractedBytes) -Blobs $blobStates.ToArray() -ReserveBytes ([int64]$versions.reserveBytes)
    Write-PnhBuildLog -Message ("download {0}, disk needed {1}, free {2}" -f (Format-PnhBytes $need.DownloadBytes), (Format-PnhBytes $need.DiskBytes), (Format-PnhBytes $drive.FreeBytes))
    if ($need.DiskBytes -gt $drive.FreeBytes) {
        throw (New-PnhBuildError -Code 'space' -Message (Get-PnhBuildText 'err.space' @((Format-PnhBytes $need.DiskBytes), (Format-PnhBytes $drive.FreeBytes))))
    }
    $script:PnhProgress = New-PnhProgress -TotalBytes $need.DownloadBytes
    Update-PnhProgress -Force

    # Runtime
    if (-not $runtimeInstalled) {
        Send-PnhPhase 'phase.runtime'
        $onProgress = { param([int64]$len) $script:PnhProgress.RuntimeDone = [math]::Max([int64]0, $len - $zipHave); Update-PnhProgress }
        Invoke-PnhDownload -Url $versions.ollama.url -Destination $zipPath -ExpectedSize ([int64]$versions.ollama.size) `
            -Sha256 $versions.ollama.sha256 -OnProgress $onProgress
        $script:PnhProgress.RuntimeDone = [int64]$versions.ollama.size - $zipHave
        Update-PnhProgress -Force
        Send-PnhPhase 'phase.extract'
        Expand-PnhRuntime -Paths $paths -ZipPath $zipPath -Runtime $versions.ollama
        Remove-PnhOwnFile -Path $zipPath -Paths $paths
    }
    Assert-PnhNotCancelled

    # App
    Send-PnhPhase 'phase.app'
    Copy-PnhApp -Paths $paths -SourceDir $srcDir
    [void](Unblock-PnhDriveFiles -Paths $paths)

    # Models: Hugging Face models straight from the pin (resume, sha256), all others through Ollama itself
    $hfPending = @($plan | Where-Object { -not $_.Complete -and [string](Get-PnhValue $_.Entry 'source') -eq 'huggingface' })
    foreach ($item in $hfPending) {
        $mPin = Get-PnhHfModelPin -PinFile $hfPins -Tag $item.Tag
        Set-PnhHfRepoBlobs -Pin $mPin -Paths $paths
        Invoke-PnhHfDownload -Pin $mPin -Tag $item.Tag -Paths $paths -Manifest $item.Manifest
    }
    $toPull = @($plan | Where-Object { -not $_.Complete -and [string](Get-PnhValue $_.Entry 'source') -ne 'huggingface' })
    if ($toPull.Count -gt 0) {
        Send-PnhPhase 'phase.ollama'
        $server = Start-PnhBuildOllama -Paths $paths
        try {
            $i = 0
            foreach ($item in $toPull) {
                $i++
                Send-PnhPhase 'phase.model' @($item.Tag, $i, $toPull.Count)
                Invoke-PnhModelPull -Server $server -Item $item -Paths $paths
            }
        } finally {
            Stop-PnhBuildOllama -Server $server
        }
    }

    # Every blob of every manifest present with its size
    Send-PnhPhase 'phase.verifyModels'
    foreach ($item in $plan) {
        $st = Test-PnhModelComplete -ModelsDir $paths.Models -Tag $item.Tag
        if (-not $st.Complete) { throw (New-PnhBuildError -Code 'verify' -Message (Get-PnhBuildText 'err.verify' @($item.Tag, $st.Reason))) }
        if ((Get-PnhManifestKey $st.Manifest) -ne (Get-PnhManifestKey $item.Manifest)) {
            Write-PnhBuildLog -Level Warn -Message "$($item.Tag): Ollama pulled other model blobs than the registry listed before"
        }
    }

    # Licences, drive.json, README.txt
    Send-PnhPhase 'phase.finish'
    Write-PnhLicenses -Paths $paths -Versions $versions -Plan $plan.ToArray() -RepoRoot $RepoRoot
    $installed = @(Get-PnhInstalledCatalogModels -Catalog $catalog -ModelsDir $paths.Models)
    $builtAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $builderId = '{0} {1}' -f $versions.builder.name, $versions.builder.version
    Write-PnhTextFile -Path $paths.DriveJson -Paths $paths -Text (ConvertTo-PnhDriveJson -BuiltAt $builtAt -Builder $builderId -Ollama $versions.ollama.version -ProfileName $ProfileName -Models $installed)
    $readme = Format-PnhReadme -Template ([System.IO.File]::ReadAllText($template, [System.Text.Encoding]::UTF8)) -Models $installed -Values @{
        BUILT_AT = $builtAt; BUILDER = $builderId; OLLAMA_VERSION = [string]$versions.ollama.version; PROFILE = $ProfileName
    }
    Write-PnhTextFile -Path $paths.Readme -Paths $paths -Text $readme -Bom
    if ((Test-Path -LiteralPath $paths.Downloads) -and @(Get-ChildItem -LiteralPath $paths.Downloads -Force).Count -eq 0) {
        Remove-Item -LiteralPath $paths.Downloads -Force
    }
    Write-PnhBuildLog -Message ('done: ' + (($installed | ForEach-Object { $_.tag }) -join ', '))
    return [pscustomobject]@{ Ok = $true; DriveRoot = $root; Models = $installed; LogPath = $script:PnhBuildLogFile }
}

# ---------------------------------------------------------------------------------------------------------------------
# Keep the PC awake while building (Windows only, best effort)
# ---------------------------------------------------------------------------------------------------------------------
function Set-PnhKeepAwake {
    param([bool]$On)
    try {
        if (-not ('PnhNative.Power' -as [type])) {
            Add-Type -Namespace PnhNative -Name Power -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
        }
        # ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1)
        if ($On) { [void][PnhNative.Power]::SetThreadExecutionState([uint32]2147483649) }
        else { [void][PnhNative.Power]::SetThreadExecutionState([uint32]2147483648) }
    } catch { }
}

# ---------------------------------------------------------------------------------------------------------------------
# Console mode (-NonInteractive)
# ---------------------------------------------------------------------------------------------------------------------
function New-PnhConsoleReporter {
    $state = @{ Last = [datetime]::MinValue }
    return {
        param($e)
        switch ($e.Type) {
            'phase' { Write-Host $e.Text }
            'progress' {
                $now = [datetime]::UtcNow
                if (($now - $state.Last).TotalSeconds -ge 5 -or $e.Done -ge $e.Total) { $state.Last = $now; Write-Host ('  ' + $e.Text) }
            }
            'log' { Write-Host ('  ' + $e.Level.ToUpperInvariant() + ': ' + $e.Text) }
        }
    }.GetNewClosure()
}

function Invoke-PnhConsoleBuild {
    param([string]$Drive, [string]$ProfileName, [string]$CatalogPath)
    if (-not $Drive) { Write-Host (Get-PnhBuildText 'cli.usage'); return 2 }
    Set-PnhKeepAwake $true
    try {
        $r = Invoke-PnhBuild -DriveRoot $Drive -ProfileName $ProfileName -CatalogPath $CatalogPath -Report (New-PnhConsoleReporter)
        Write-Host ''
        Write-Host (Get-PnhBuildText 'cli.done' @($r.DriveRoot))
        foreach ($m in $r.Models) { Write-Host ('  {0}  ({1})' -f $m.tag, (Format-PnhBytes $m.bytes)) }
        return 0
    } catch {
        $code = Get-PnhErrorCode $_
        Write-Host ''
        Write-Host (Get-PnhErrorText $_)
        if ($code -notin @('fat', 'fs', 'cancelled', 'usage')) {
            Write-PnhBuildLog -Level Error -Message ("{0}`r`n{1}" -f $_.Exception.ToString(), $_.ScriptStackTrace)
            if ($script:PnhBuildLogFile) { Write-Host ('Log: ' + $script:PnhBuildLogFile) }
        }
        return (Get-PnhExitCode $code)
    } finally {
        Set-PnhKeepAwake $false
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Wizard (Windows Forms). The build runs in a background runspace; a 200 ms timer drains its event queue.
# ---------------------------------------------------------------------------------------------------------------------
function Show-PnhBuildWizard {
    param([string]$CatalogPath, [string]$InitialProfile = 'standard')
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    if (-not $CatalogPath) { $CatalogPath = [System.IO.Path]::Combine([string[]]@($script:PnhRepoRoot, 'src', 'catalog', 'models.json')) }
    $T = { param($k, $a) Get-PnhBuildText -Key $k -Arguments $a }
    $ui = @{ Page = 'drive'; Drive = $null; Profile = $InitialProfile; Running = $false; CloseWhenDone = $false; CatalogError = $null; CatalogPath = $CatalogPath }
    $script:PnhUi = $ui
    try {
        $ui.Versions = Read-PnhVersions -Path ([System.IO.Path]::Combine($script:PnhBuilderRoot, 'versions.json'))
        $ui.Catalog = Read-PnhBuildCatalog -Path $CatalogPath
    } catch { $ui.CatalogError = Get-PnhErrorText $_ }

    $font = New-Object System.Drawing.Font('Segoe UI', 10.5)
    $fontBig = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $fontBold = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $grey = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $warnColor = [System.Drawing.Color]::FromArgb(170, 60, 0)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = & $T 'title'
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = $font
    $form.ClientSize = New-Object System.Drawing.Size(760, 540)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $ui.Form = $form

    $mk = {
        param($type, $x, $y, $w, $h, $text)
        $c = New-Object ("System.Windows.Forms.$type")
        $c.Location = New-Object System.Drawing.Point($x, $y)
        $c.Size = New-Object System.Drawing.Size($w, $h)
        if ($null -ne $text) { $c.Text = $text }
        return $c
    }

    # Buttons
    $btnBack = & $mk 'Button' 380 490 110 36 (& $T 'btn.back')
    $btnNext = & $mk 'Button' 500 490 130 36 (& $T 'btn.next')
    $btnCancel = & $mk 'Button' 640 490 105 36 (& $T 'btn.cancel')
    $form.Controls.AddRange(@($btnBack, $btnNext, $btnCancel))
    $form.AcceptButton = $btnNext

    # Page 1: drive
    $pDrive = & $mk 'Panel' 0 0 760 480 $null
    $lblH1 = & $mk 'Label' 20 18 720 34 (& $T 'drive.heading'); $lblH1.Font = $fontBig
    $lblHint = & $mk 'Label' 20 58 720 44 (& $T 'drive.hint'); $lblHint.ForeColor = $grey
    $lv = & $mk 'ListView' 20 106 720 220 $null
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
    [void]$lv.Columns.Add((& $T 'col.drive'), 90)
    [void]$lv.Columns.Add((& $T 'col.label'), 220)
    [void]$lv.Columns.Add((& $T 'col.size'), 130)
    [void]$lv.Columns.Add((& $T 'col.free'), 130)
    [void]$lv.Columns.Add((& $T 'col.fs'), 130)
    $chkAll = & $mk 'CheckBox' 20 334 300 28 (& $T 'drive.showAll')
    $btnRefresh = & $mk 'Button' 560 332 180 32 (& $T 'drive.refresh')
    $lblDriveMsg = & $mk 'Label' 20 374 720 48 ''; $lblDriveMsg.ForeColor = $warnColor
    $btnHow = & $mk 'Button' 20 426 360 34 (& $T 'fat.howButton'); $btnHow.Visible = $false
    $pDrive.Controls.AddRange(@($lblH1, $lblHint, $lv, $chkAll, $btnRefresh, $lblDriveMsg, $btnHow))

    # Page 2: profile
    $pProfile = & $mk 'Panel' 0 0 760 480 $null
    $lblH2 = & $mk 'Label' 20 18 720 34 (& $T 'profile.heading'); $lblH2.Font = $fontBig
    $pProfile.Controls.Add($lblH2)
    $radios = @{}; $radioTexts = @{}
    $y = 66
    foreach ($name in @('small', 'standard', 'full')) {
        $rb = & $mk 'RadioButton' 20 $y 720 30 ''
        $rb.Font = $fontBold; $rb.Tag = $name
        $lt = & $mk 'Label' 44 ($y + 30) 690 62 ''
        $lt.ForeColor = $grey
        $radios[$name] = $rb; $radioTexts[$name] = $lt
        $pProfile.Controls.AddRange(@($rb, $lt))
        $y += 94
    }
    $lblFree = & $mk 'Label' 20 352 720 28 ''
    $lblFit = & $mk 'Label' 20 384 720 48 ''; $lblFit.ForeColor = $warnColor
    $pProfile.Controls.AddRange(@($lblFree, $lblFit))

    # Page 3: progress
    $pProgress = & $mk 'Panel' 0 0 760 480 $null
    $lblH3 = & $mk 'Label' 20 18 720 34 (& $T 'progress.heading'); $lblH3.Font = $fontBig
    $lblPhase = & $mk 'Label' 20 80 720 30 ''; $lblPhase.Font = $fontBold
    $bar = & $mk 'ProgressBar' 20 120 720 34 $null; $bar.Minimum = 0; $bar.Maximum = 1000
    $lblAmount = & $mk 'Label' 20 164 720 30 ''
    $lblKeep = & $mk 'Label' 20 220 720 70 (& $T 'progress.keepOpen'); $lblKeep.ForeColor = $grey
    $lblWarn = & $mk 'Label' 20 300 720 60 ''; $lblWarn.ForeColor = $grey
    $pProgress.Controls.AddRange(@($lblH3, $lblPhase, $bar, $lblAmount, $lblKeep, $lblWarn))

    # Page 4: result
    $pResult = & $mk 'Panel' 0 0 760 480 $null
    $lblH4 = & $mk 'Label' 20 18 720 40 ''; $lblH4.Font = $fontBig
    $txtResult = & $mk 'TextBox' 20 70 720 390 ''
    $txtResult.Multiline = $true; $txtResult.ReadOnly = $true; $txtResult.ScrollBars = 'Vertical'
    $txtResult.BorderStyle = 'None'; $txtResult.BackColor = $form.BackColor
    $pResult.Controls.AddRange(@($lblH4, $txtResult))

    $form.Controls.AddRange(@($pDrive, $pProfile, $pProgress, $pResult))
    $ui.Controls = @{
        pDrive = $pDrive; pProfile = $pProfile; pProgress = $pProgress; pResult = $pResult; lv = $lv; chkAll = $chkAll
        lblDriveMsg = $lblDriveMsg; btnHow = $btnHow; radios = $radios; radioTexts = $radioTexts; lblFree = $lblFree
        lblFit = $lblFit; lblPhase = $lblPhase; bar = $bar; lblAmount = $lblAmount; lblWarn = $lblWarn; lblH4 = $lblH4
        txtResult = $txtResult; btnBack = $btnBack; btnNext = $btnNext; btnCancel = $btnCancel
    }

    $showPage = {
        param($page)
        $c = $script:PnhUi.Controls
        $script:PnhUi.Page = $page
        $c.pDrive.Visible = ($page -eq 'drive'); $c.pProfile.Visible = ($page -eq 'profile')
        $c.pProgress.Visible = ($page -eq 'progress'); $c.pResult.Visible = ($page -eq 'result')
        $c.btnBack.Visible = ($page -eq 'profile')
        $c.btnNext.Visible = ($page -ne 'progress')
        $c.btnCancel.Visible = ($page -ne 'result')
        $c.btnCancel.Enabled = $true
        $c.btnCancel.Text = Get-PnhBuildText 'btn.cancel'
        switch ($page) {
            'drive' { $c.btnNext.Text = Get-PnhBuildText 'btn.next' }
            'profile' { $c.btnNext.Text = Get-PnhBuildText 'btn.build' }
            'result' { $c.btnNext.Text = Get-PnhBuildText 'btn.close' }
        }
    }
    $ui.ShowPage = $showPage

    $showResult = {
        param([string]$heading, [string]$text)
        $c = $script:PnhUi.Controls
        $c.lblH4.Text = $heading
        $c.txtResult.Text = $text
        & $script:PnhUi.ShowPage 'result'
    }
    $ui.ShowResult = $showResult

    $fillDrives = {
        $c = $script:PnhUi.Controls
        $c.lv.Items.Clear()
        $script:PnhUi.Drives = @(Get-PnhCandidateDrives -All:$c.chkAll.Checked)
        foreach ($d in $script:PnhUi.Drives) {
            $it = New-Object System.Windows.Forms.ListViewItem($d.Letter)
            [void]$it.SubItems.Add([string]$d.Label)
            [void]$it.SubItems.Add((Format-PnhBytes $d.SizeBytes))
            [void]$it.SubItems.Add((Format-PnhBytes $d.FreeBytes))
            [void]$it.SubItems.Add([string]$d.FileSystem)
            $it.Tag = $d
            [void]$c.lv.Items.Add($it)
        }
        if ($c.lv.Items.Count -eq 1) { $c.lv.Items[0].Selected = $true }
        $c.lblDriveMsg.Text = $(if ($c.lv.Items.Count -eq 0) { Get-PnhBuildText 'drive.none' } else { '' })
        $c.btnHow.Visible = $false
    }

    $checkDrive = {
        # -> $true if the selected drive can be used; shows the exFAT hint otherwise
        $c = $script:PnhUi.Controls
        $c.btnHow.Visible = $false
        if ($c.lv.SelectedItems.Count -eq 0) { $c.lblDriveMsg.Text = $(if ($c.lv.Items.Count -eq 0) { Get-PnhBuildText 'drive.none' } else { Get-PnhBuildText 'drive.pick' }); return $false }
        $d = $c.lv.SelectedItems[0].Tag
        $script:PnhUi.Drive = $d
        $fs = Test-PnhFileSystem -FileSystem $d.FileSystem
        if ($fs.Ok) { $c.lblDriveMsg.Text = ''; return $true }
        $c.lblDriveMsg.Text = $(if ($fs.Reason -eq 'fat') { Get-PnhBuildText 'fat.short' } else { Get-PnhBuildText 'fs.short' @($d.FileSystem) })
        $c.btnHow.Visible = $true
        return $false
    }

    $updateProfile = {
        $ui2 = $script:PnhUi; $c = $ui2.Controls
        $d = $ui2.Drive
        $paths = Get-PnhBuildPaths -DriveRoot $d.Root
        $existing = Get-PnhExistingBuildBytes -Paths $paths
        $available = [int64]$d.FreeBytes + $existing
        $ui2.Fits = @{}
        foreach ($name in @('small', 'standard', 'full')) {
            $rb = $c.radios[$name]
            try {
                $opt = Get-PnhProfileOption -Catalog $ui2.Catalog -Versions $ui2.Versions -Name $name
                $rb.Text = $opt.Title
                $c.radioTexts[$name].Text = $opt.Text
                $rb.Enabled = $true
                $ui2.Fits[$name] = ($opt.DriveBytes -le $available)
            } catch {
                $rb.Text = $name; $rb.Enabled = $false; $c.radioTexts[$name].Text = Get-PnhErrorText $_; $ui2.Fits[$name] = $false
            }
        }
        $c.lblFree.Text = Get-PnhBuildText 'profile.free' @($d.Letter, (Format-PnhBytes $d.FreeBytes))
        $sel = $ui2.Profile
        if (-not $c.radios[$sel].Enabled) { $sel = 'small' }
        $c.radios[$sel].Checked = $true
    }

    $updateFit = {
        $ui2 = $script:PnhUi; $c = $ui2.Controls
        foreach ($name in @('small', 'standard', 'full')) { if ($c.radios[$name].Checked) { $ui2.Profile = $name } }
        $fits = $ui2.Fits -and $ui2.Fits[$ui2.Profile]
        $c.lblFit.Text = $(if ($fits) { '' } else { Get-PnhBuildText 'profile.tooBig' })
        $c.btnNext.Enabled = [bool]$fits
    }
    foreach ($rb in $radios.Values) { $rb.Add_CheckedChanged($updateFit) }

    $startBuild = {
        $ui2 = $script:PnhUi; $c = $ui2.Controls
        & $ui2.ShowPage 'progress'
        $c.lblPhase.Text = Get-PnhBuildText 'phase.check'
        $c.lblAmount.Text = ''; $c.lblWarn.Text = ''; $c.bar.Value = 0
        $ui2.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $ui2.Cancel = [hashtable]::Synchronized(@{ Requested = $false })
        $ui2.Running = $true
        Set-PnhKeepAwake $true
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
                param($BgScript, $BgDrive, $BgProfile, $BgCatalog, $BgLang, $BgQueue, $BgCancel)
                try {
                    . $BgScript
                    Set-PnhBuildLanguage -Language $BgLang
                    Enable-PnhTls
                    $report = { param($e) $BgQueue.Enqueue($e) }.GetNewClosure()
                    $r = Invoke-PnhBuild -DriveRoot $BgDrive -ProfileName $BgProfile -CatalogPath $BgCatalog -Report $report -Cancel $BgCancel
                    $BgQueue.Enqueue(@{ Type = 'done'; Ok = $true; Models = $r.Models; LogPath = $r.LogPath })
                } catch {
                    $code = 'error'; $text = $_.Exception.Message; $log = $null
                    if (Get-Command Get-PnhErrorCode -ErrorAction SilentlyContinue) {
                        $code = Get-PnhErrorCode $_; $text = Get-PnhErrorText $_; $log = $script:PnhBuildLogFile
                        Write-PnhBuildLog -Level Error -Message ("{0}`r`n{1}" -f $_.Exception.ToString(), $_.ScriptStackTrace)
                    }
                    $BgQueue.Enqueue(@{ Type = 'done'; Ok = $false; Code = $code; Text = $text; LogPath = $log })
                }
            })
        [void]$ps.AddArgument($script:PnhScriptPath).AddArgument($ui2.Drive.Root).AddArgument($ui2.Profile)
        [void]$ps.AddArgument($ui2.CatalogPath).AddArgument($script:PnhBuildLang).AddArgument($ui2.Queue).AddArgument($ui2.Cancel)
        $ui2.PowerShell = $ps
        $ui2.Runspace = $rs
        $ui2.Async = $ps.BeginInvoke()
        $ui2.Timer.Start()
    }

    $onEvent = {
        param($e)
        $ui2 = $script:PnhUi; $c = $ui2.Controls
        switch ($e.Type) {
            'phase' { $c.lblPhase.Text = $e.Text }
            'progress' {
                if ($e.Total -gt 0) { $c.bar.Value = [int][math]::Min(1000, [math]::Max(0, 1000.0 * $e.Done / $e.Total)) }
                $c.lblAmount.Text = $e.Text
            }
            'log' { if ($e.Level -ne 'Info') { $c.lblWarn.Text = $e.Text } }
            'done' {
                $ui2.Timer.Stop()
                $ui2.Running = $false
                Set-PnhKeepAwake $false
                try { [void]$ui2.PowerShell.EndInvoke($ui2.Async) } catch { }
                try { $ui2.PowerShell.Dispose(); $ui2.Runspace.Close() } catch { }
                if ($ui2.CloseWhenDone) { $ui2.Form.Close(); return }
                if ($e.Ok) {
                    $c.bar.Value = 1000
                    $list = (@($e.Models) | ForEach-Object { '  - {0}  ({1})' -f $_.tag, (Format-PnhBytes $_.bytes) }) -join "`r`n"
                    & $ui2.ShowResult (Get-PnhBuildText 'done.ok.heading') (Get-PnhBuildText 'done.ok.text' @($list))
                } elseif ($e.Code -eq 'cancelled') {
                    & $ui2.ShowResult (Get-PnhBuildText 'done.cancel.heading') (Get-PnhBuildText 'done.cancel.text')
                } else {
                    & $ui2.ShowResult (Get-PnhBuildText 'done.fail.heading') (Get-PnhBuildText 'done.fail.text' @($e.Text, "$($e.LogPath)"))
                }
            }
        }
    }
    $ui.OnEvent = $onEvent

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
            $item = $null
            while ($script:PnhUi.Queue -and $script:PnhUi.Queue.TryDequeue([ref]$item)) { & $script:PnhUi.OnEvent $item }
        })
    $ui.Timer = $timer

    $chkAll.Add_CheckedChanged($fillDrives)
    $btnRefresh.Add_Click($fillDrives)
    $lv.Add_SelectedIndexChanged({ $script:PnhUi.Controls.lblDriveMsg.Text = ''; $script:PnhUi.Controls.btnHow.Visible = $false })
    $btnHow.Add_Click({
            $fsName = 'FAT32'
            if ($script:PnhUi.Drive) { $fsName = $script:PnhUi.Drive.FileSystem }
            [void][System.Windows.Forms.MessageBox]::Show((Get-PnhBuildText 'fat.text' @($fsName)), (Get-PnhBuildText 'fat.title'), 'OK', 'Information')
        })
    $btnBack.Add_Click({ & $script:PnhUi.ShowPage 'drive'; $script:PnhUi.Controls.btnNext.Enabled = $true })
    $btnNext.Add_Click({
            $ui2 = $script:PnhUi
            switch ($ui2.Page) {
                'drive' { if (& $ui2.CheckDrive) { & $ui2.UpdateProfile; & $ui2.ShowPage 'profile'; & $ui2.UpdateFit } }
                'profile' { & $ui2.StartBuild }
                'result' { $ui2.Form.Close() }
            }
        })
    $btnCancel.Add_Click({
            $ui2 = $script:PnhUi
            if ($ui2.Running) {
                $answer = [System.Windows.Forms.MessageBox]::Show((Get-PnhBuildText 'confirm.cancel'), (Get-PnhBuildText 'title'), 'YesNo', 'Question')
                if ($answer -eq 'Yes') { $ui2.Cancel['Requested'] = $true; $ui2.Controls.btnCancel.Enabled = $false; $ui2.Controls.btnCancel.Text = Get-PnhBuildText 'progress.cancelling' }
            } else { $ui2.Form.Close() }
        })
    $form.Add_FormClosing({
            param($formSender, $closingArgs)
            $ui2 = $script:PnhUi
            if ($ui2.Running) {
                $closingArgs.Cancel = $true
                if ($ui2.CloseWhenDone) { return }
                $answer = [System.Windows.Forms.MessageBox]::Show((Get-PnhBuildText 'confirm.cancel'), (Get-PnhBuildText 'title'), 'YesNo', 'Question')
                if ($answer -eq 'Yes') { $ui2.Cancel['Requested'] = $true; $ui2.CloseWhenDone = $true; $ui2.Controls.btnCancel.Enabled = $false }
            }
        })
    $ui.CheckDrive = $checkDrive
    $ui.UpdateProfile = $updateProfile
    $ui.UpdateFit = $updateFit
    $ui.StartBuild = $startBuild

    if ($ui.CatalogError) {
        & $showResult (Get-PnhBuildText 'done.fail.heading') $ui.CatalogError
    } else {
        & $fillDrives
        & $showPage 'drive'
    }
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
}

# ---------------------------------------------------------------------------------------------------------------------
# Entry point (skipped when the file is dot-sourced, e.g. by the tests or the wizard's background runspace)
# ---------------------------------------------------------------------------------------------------------------------
function Invoke-PnhBuilderMain {
    Set-PnhBuildLanguage -Language $Language
    Enable-PnhTls
    if ($NonInteractive) {
        return (Invoke-PnhConsoleBuild -Drive $Drive -ProfileName $BuildProfile -CatalogPath $Catalog)
    }
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
    if (-not $onWindows) { Write-Host (Get-PnhBuildText 'cli.noWindows'); return 2 }
    Show-PnhBuildWizard -CatalogPath $Catalog -InitialProfile $BuildProfile
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    $rc = @(Invoke-PnhBuilderMain)
    exit ([int]$rc[$rc.Count - 1])
}
