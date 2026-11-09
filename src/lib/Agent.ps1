# Plug'n'Heal - the agent loop.
# Contract: docs/ARCHITECTURE.md section 5.7. Runs on Windows PowerShell 5.1 and PowerShell 7.
#
# Uses (by contract, loaded by the caller):
#   Common.ps1   Write-PnhLog, Get-PnhText, Get-PnhLanguage, Start-PnhHidden
#   Ollama.ps1   Invoke-PnhChat
#   Diagnose.ps1 Invoke-PnhDiagnose, Invoke-PnhSuccessCheck
#   Toolbox.ps1  Get-PnhActions, ConvertTo-PnhToolDefinitions, Invoke-PnhAction, Test-PnhCommandDenied,
#                New-PnhRestorePoint
# Reads toolbox\categories.json and toolbox\findings.json next to this lib folder (derived from the file location).
#
# Public:   Invoke-PnhAgent
# Helpers (tested directly): ConvertTo-PnhAgentPlainText, ConvertTo-PnhAgentArguments, Test-PnhAgentReadOnlyCommand,
#           ConvertTo-PnhAgentTrimmedJson, Get-PnhAgentSalvagedCalls

# ---------------------------------------------------------------------------------------------------------------
# Texts. User-visible keys are looked up with Get-PnhText first (i18n files); the built-in text is the fallback, so
# the agent never shows a raw key. Keys starting with "model." are only sent to the language model.
# ---------------------------------------------------------------------------------------------------------------

function Get-PnhAgentTextTable {
    @{
        'step.diagnose'                = @{ de = 'Ich untersuche den Computer'; en = 'I am examining the computer' }
        'agent.step.isolation'         = @{ de = 'Ich prüfe, ob der Computer absichtlich vom Netz getrennt wurde'; en = 'Checking whether the computer was cut off from the network on purpose' }
        'step.repair'                  = @{ de = 'Ich behebe das Problem'; en = 'I am fixing the problem' }
        'step.verify'                  = @{ de = 'Ich prüfe, ob es jetzt geht'; en = 'I am checking whether it works now' }
        'agent.action.shell'           = @{ de = 'Einen Befehl ausführen'; en = 'Run a command' }
        'agent.confirm.command.title'  = @{ de = 'Darf ich diesen Befehl ausführen?'; en = 'May I run this command?' }
        'agent.confirm.command.explain'= @{ de = "{0}`n`nBefehl: {1}"; en = "{0}`n`nCommand: {1}" }
        'report.title'                 = @{ de = "Plug'n'Heal – Bericht"; en = "Plug'n'Heal – report" }
        'report.computer'              = @{ de = 'Computer: {0}'; en = 'Computer: {0}' }
        'report.date'                  = @{ de = 'Datum: {0}'; en = 'Date: {0}' }
        'report.problem'               = @{ de = 'Problem: {0}'; en = 'Problem: {0}' }
        'report.user_text'             = @{ de = 'Ihre Beschreibung: {0}'; en = 'Your description: {0}' }
        'report.readonly'              = @{ de = "Plug'n'Heal hatte keine Erlaubnis zum Reparieren und hat nur nachgeschaut."; en = "Plug'n'Heal had no permission to repair and only looked." }
        'report.log'                   = @{ de = 'Ausführliches Protokoll: {0}'; en = 'Detailed log: {0}' }
        'result.readonly.text'         = @{ de = "Ohne Ihre Erlaubnis konnte ich nur nachschauen. Wenn ich reparieren soll: Starten Sie Plug'n'Heal noch einmal und klicken Sie bei der Frage von Windows auf «Ja»."; en = 'Without your permission I could only look. If you want me to repair: start Plug''n''Heal again and click “Yes” when Windows asks.' }
        'event.action_readonly'        = @{ de = 'Nicht gemacht, weil ich keine Erlaubnis zum Reparieren habe: {0}'; en = 'Not done, because I have no permission to repair: {0}' }
        'agent.summary.wouldhelp'      = @{ de = 'Das würde wahrscheinlich helfen:'; en = 'This would probably help:' }
        'agent.summary.model'          = @{ de = 'Sprachmodell: {0}'; en = 'Language model: {0}' }
        'result.solved.title'          = @{ de = 'Geschafft! Das Problem ist behoben.'; en = 'Done! The problem is fixed.' }
        'result.solved.text'           = @{ de = 'Ich habe nachgeprüft: Es funktioniert jetzt wieder.'; en = 'I checked it: it works again now.' }
        'result.unsolved.title'        = @{ de = 'Ich konnte das Problem leider nicht ganz lösen.'; en = 'Sorry, I could not completely fix the problem.' }
        'agent.summary.nothingfound'   = @{ de = 'Die automatische Prüfung findet bei diesem Thema keinen Fehler.'; en = 'The automatic check finds no fault in this area.' }
        'result.stopped.isolated'      = @{ de = 'Die Informatik Ihrer Firma hat diesen Computer vom Netz getrennt. Das ist eine Schutzmassnahme, daran ändere ich nichts. Bitte rufen Sie die Informatik Ihrer Firma an.'; en = 'The IT department of your company has disconnected this computer from the network. This is a safety measure, I will not change it. Please call the IT department of your company.' }
        'agent.summary.note'           = @{ de = 'Hinweis: {0}'; en = 'Note: {0}' }
        'agent.summary.stop'           = @{ de = 'Ich habe nichts verändert, weil: {0}'; en = 'I did not change anything because: {0}' }
        'result.actions.title'         = @{ de = 'Was ich gemacht habe:'; en = 'What I did:' }
        'agent.summary.none'           = @{ de = 'Ich habe nichts verändert.'; en = 'I did not change anything.' }
        'agent.summary.item.ok'        = @{ de = '- {0}: hat geklappt.'; en = '- {0}: worked.' }
        'agent.summary.item.unverified'= @{ de = '- {0}: ausgeführt, Wirkung nicht bestätigt.'; en = '- {0}: done, effect not confirmed.' }
        'agent.summary.item.failed'    = @{ de = '- {0}: hat nicht geklappt.'; en = '- {0}: did not work.' }
        'agent.summary.item.rolledback'= @{ de = '- {0}: hat nicht geklappt, ich habe es wieder rückgängig gemacht.'; en = '- {0}: did not work, I undid it.' }
        'agent.summary.item.declined'  = @{ de = '- {0}: nicht gemacht, weil Sie Nein gesagt haben.'; en = '- {0}: not done, because you said no.' }
        'agent.summary.item.blocked'   = @{ de = '- {0}: aus Sicherheitsgründen nicht erlaubt.'; en = '- {0}: not allowed for safety reasons.' }
        'agent.summary.check'          = @{ de = 'Prüfung: {0}'; en = 'Check: {0}' }
        'result.reboot'                = @{ de = 'Bitte starten Sie den Computer neu, damit alles wirkt.'; en = 'Please restart the computer so that everything takes effect.' }
        'agent.summary.words'          = @{ de = 'Erklärung: {0}'; en = 'Explanation: {0}' }
        'agent.summary.guess'          = @{ de = 'Vermutung des Assistenten (nicht geprüft): {0}'; en = "The assistant's guess (not checked): {0}" }
        'result.unsolved.text'         = @{ de = 'Das ist nicht schlimm. Zeigen Sie den Bericht einer Person, die sich mit Computern auskennt. Darin steht, was ich gefunden und versucht habe.'; en = 'That is not bad. Show the report to someone who knows computers. It says what I found and what I tried.' }
        'result.stopped.max_rounds'    = @{ de = 'Ich habe alles versucht, was ich gefahrlos machen kann.'; en = 'I have tried everything I can do safely.' }
        'result.stopped.no_progress' = @{ de = 'Ich bin nicht weitergekommen und habe deshalb aufgehört.'; en = 'I did not get any further, so I stopped.' }
        'result.stopped.errors'        = @{ de = 'Mehrere Schritte haben nicht geklappt, deshalb habe ich aufgehört.'; en = 'Several steps did not work, so I stopped.' }
        'agent.summary.malformed'      = @{ de = 'Ich habe aufgehört, weil das Sprachmodell keine brauchbaren Antworten mehr gab.'; en = 'I stopped because the language model gave no usable answers.' }
        'agent.summary.error'          = @{ de = 'Es ist ein technischer Fehler aufgetreten: {0}'; en = 'A technical error happened: {0}' }

        'model.user.topic'      = @{ de = 'Thema: {0}'; en = 'Topic: {0}' }
        'model.user.words'      = @{ de = 'Worte der Person: "{0}"'; en = 'The person says: "{0}"' }
        'model.user.nowords'    = @{ de = 'Die Person hat nichts dazu geschrieben.'; en = 'The person wrote nothing about it.' }
        'model.user.checknow'   = @{ de = 'Automatische Prüfung vorher: {0}. {1}'; en = 'Automatic check before: {0}. {1}' }
        'model.user.findings'   = @{ de = 'Befunde der Diagnose:'; en = 'Findings of the diagnosis:' }
        'model.user.nofindings' = @{ de = 'Befunde der Diagnose: keine.'; en = 'Findings of the diagnosis: none.' }
        'model.user.facts'      = @{ de = 'Fakten (JSON):'; en = 'Facts (JSON):' }
        'model.user.task'       = @{ de = 'Aufgabe: Finde die Ursache und behebe sie mit den Werkzeugen, eine Änderung nach der anderen. Nimm Werte nur aus den Fakten. Wenn du fertig bist oder nicht helfen kannst, rufe finish auf.'; en = 'Task: find the cause and fix it with the tools, one change at a time. Take values only from the facts. When you are done or cannot help, call finish.' }
        'model.user.task.all'   = @{ de = 'Aufgabe: Die Person weiss nicht, was nicht stimmt. Bearbeite die Befunde der Reihe nach, der wichtigste steht oben. Eine Änderung nach der anderen. Nimm Werte nur aus den Fakten. Wenn du fertig bist oder nicht helfen kannst, rufe finish auf.'; en = 'Task: the person does not know what is wrong. Work through the findings in order, the most important one is first. One change at a time. Take values only from the facts. When you are done or cannot help, call finish.' }
        'model.user.readonly'   = @{ de = 'Nur-Lese-Modus: Die Person hat keine Erlaubnis zum Reparieren gegeben. Du darfst nur nachschauen. Rufst du eine Reparatur auf, wird sie nicht ausgeführt, sondern als Empfehlung notiert.'; en = 'Read-only mode: the person gave no permission to repair. You may only look. If you call a repair, it is not done but noted as a recommendation.' }
        'model.readonly.skipped'= @{ de = 'Nicht ausgeführt, Nur-Lese-Modus. Als Empfehlung notiert. Schau weiter nach oder rufe finish auf und sage, was helfen würde.'; en = 'Not done, read-only mode. Noted as a recommendation. Look further or call finish and say what would help.' }
        'model.passed'          = @{ de = 'bestanden'; en = 'passed' }
        'model.failed'          = @{ de = 'nicht bestanden'; en = 'not passed' }
        'model.correct'         = @{ de = 'Deine letzte Antwort war kein gültiger Werkzeugaufruf. Antworte nur mit genau einem Werkzeugaufruf. Gültige Namen: {0}. Wenn du fertig bist, rufe finish mit einer kurzen Zusammenfassung auf.'; en = 'Your last answer was not a valid tool call. Answer with exactly one tool call. Valid names: {0}. When you are done, call finish with a short summary.' }
        'model.unknown'         = @{ de = 'Das Werkzeug "{0}" gibt es nicht. Gültige Namen: {1}.'; en = 'There is no tool "{0}". Valid names: {1}.' }
        'model.badargs'         = @{ de = 'Ungültige Angaben für {0}: {1}. Nimm Werte nur aus den Fakten und erfinde nichts.'; en = 'Invalid arguments for {0}: {1}. Take values only from the facts and do not invent anything.' }
        'model.repeated'        = @{ de = 'Diesen Aufruf hast du schon gemacht, ohne dass sich etwas geändert hat. Ich beende hier.'; en = 'You already made this call and nothing changed. I stop here.' }
        'model.declined'        = @{ de = 'Die Person hat Nein gesagt. Versuche das nicht noch einmal. Wähle etwas anderes oder rufe finish auf.'; en = 'The person said no. Do not try this again. Choose something else or call finish.' }
        'model.answer.yes'      = @{ de = 'Die Person hat geantwortet: Ja.'; en = 'The person answered: yes.' }
        'model.answer.no'       = @{ de = 'Die Person hat geantwortet: Nein.'; en = 'The person answered: no.' }
        'model.blocked'         = @{ de = 'Dieser Befehl ist aus Sicherheitsgründen verboten. Versuche ihn nicht noch einmal.'; en = 'This command is forbidden for safety reasons. Do not try it again.' }
        'model.syntax'          = @{ de = 'Der Befehl hat einen Syntaxfehler: {0}'; en = 'The command has a syntax error: {0}' }
        'model.check.passed'    = @{ de = 'Die automatische Prüfung ist bestanden: {0} Das Problem ist behoben. Mache keine weiteren Änderungen. Rufe jetzt finish auf und erkläre in einfachen Worten, was du gemacht hast.'; en = 'The automatic check passed: {0} The problem is fixed. Make no further changes. Call finish now and explain in simple words what you did.' }
        'model.check.failed'    = @{ de = 'Die automatische Prüfung ist noch nicht bestanden: {0}'; en = 'The automatic check has not passed yet: {0}' }
        'model.notverified'     = @{ de = 'Die Aktion lief, aber ihre eigene Prüfung sagt, dass sie nicht gewirkt hat.'; en = 'The action ran, but its own check says it had no effect.' }
        'model.skipped.one'     = @{ de = 'Übersprungen: immer nur eine Änderung auf einmal. Schau zuerst das Ergebnis an.'; en = 'Skipped: only one change at a time. Look at the result first.' }
        'model.skipped.solved'  = @{ de = 'Übersprungen: das Problem ist schon behoben.'; en = 'Skipped: the problem is already fixed.' }
        'model.stopped'         = @{ de = 'Stopp: {0} Keine Reparaturen mehr. Ich beende hier.'; en = 'Stop: {0} No more repairs. I stop here.' }
        'model.user.stop'       = @{ de = 'Wichtig, gilt für alle Schritte: {0}'; en = 'Important, applies to every step: {0}' }

        'tool.finish'           = @{ de = 'Beendet die Hilfe. Rufe das auf, wenn das Problem behoben ist oder wenn du nicht weiterhelfen kannst.'; en = 'Ends the help. Call it when the problem is fixed or when you cannot help further.' }
        'tool.finish.summary'   = @{ de = 'Zwei bis vier kurze, einfache Sätze für die Person: was du gefunden hast, was du gemacht hast und was sie jetzt tun soll.'; en = 'Two to four short, simple sentences for the person: what you found, what you did and what they should do now.' }
        'tool.ask'              = @{ de = 'Stellt der Person eine Ja/Nein-Frage, die sie ohne Fachwissen beantworten kann, zum Beispiel ob der Drucker eingeschaltet ist.'; en = 'Asks the person a yes/no question they can answer without technical knowledge, for example whether the printer is switched on.' }
        'tool.ask.question'     = @{ de = 'Die Frage in einfachen Worten.'; en = 'The question in simple words.' }
        'tool.shell'            = @{ de = 'Führt einen PowerShell-Befehl auf diesem Computer aus. Nur lesende Befehle laufen sofort, alles andere muss die Person erlauben. Verbotene Befehle werden blockiert.'; en = 'Runs a PowerShell command on this computer. Only read-only commands run at once, everything else needs the person''s permission. Forbidden commands are blocked.' }
        'tool.shell.command'    = @{ de = 'Der PowerShell-Befehl.'; en = 'The PowerShell command.' }
        'tool.shell.why'        = @{ de = 'Ein kurzer Satz für die Person, warum der Befehl nötig ist.'; en = 'One short sentence for the person why the command is needed.' }
    }
}

function Get-PnhAgentText {
    param([Parameter(Mandatory)][string]$Key, [string]$Language = 'en', [object[]]$Arguments = @())
    $table = Get-PnhAgentTextTable
    $cmd = $null
    if (-not $Key.StartsWith('model.') -and -not $Key.StartsWith('tool.')) { $cmd = Get-Command -Name Get-PnhText -ErrorAction SilentlyContinue }
    if ($cmd) {
        $p = @{ Key = $Key }
        if ($Arguments.Count -gt 0) { $p['Arguments'] = $Arguments }
        $usable = $true
        if ($cmd.Parameters -and $cmd.Parameters.ContainsKey('Language')) { $p['Language'] = $Language }
        else { try { $usable = ((Get-PnhLanguage) -eq $Language) } catch { $usable = $false } }
        if ($usable) {
            try {
                $t = [string](Get-PnhText @p)
                if ($t -and $t -ne $Key) { return $t }
            } catch { Write-Verbose ('Agent: ' + $_.Exception.Message) }
        }
    }
    $entry = $table[$Key]
    if (-not $entry) { return $Key }
    $fmt = if ($entry.ContainsKey($Language)) { $entry[$Language] } else { $entry['en'] }
    if ($Arguments.Count -gt 0) { return ($fmt -f $Arguments) }
    return $fmt
}

function Get-PnhAgentLocalized {
    # Returns the text for a value that is either a string or an object with de/en members.
    param($Value, [string]$Language = 'en')
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    $h = ConvertTo-PnhAgentHashtable -InputObject $Value
    if ($h) {
        if ($h.ContainsKey($Language) -and $h[$Language]) { return [string]$h[$Language] }
        if ($h.ContainsKey('en') -and $h['en']) { return [string]$h['en'] }
        foreach ($k in $h.Keys) { if ($h[$k]) { return [string]$h[$k] } }
    }
    return [string]$Value
}

# ---------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------

function ConvertTo-PnhAgentHashtable {
    # Hashtable from hashtable, PSCustomObject or JSON string. Returns $null if the input is not an object.
    param($InputObject)
    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [string]) {
        $s = $InputObject.Trim()
        if ($s -eq '') { return @{} }
        if (-not $s.StartsWith('{')) { return $null }
        try { $InputObject = ConvertFrom-Json -InputObject $s -ErrorAction Stop } catch { return $null }
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    return $null
}

function Get-PnhAgentMember {
    # Member of a hashtable or object, $null if missing (works for both shapes, no StrictMode surprises).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        foreach ($k in $Object.Keys) { if ([string]$k -eq $Name) { return $Object[$k] } }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-PnhAgentLibDir {
    $file = $MyInvocation.MyCommand.ScriptBlock.File
    if ($file) { return (Split-Path -Parent $file) }
    return $PSScriptRoot
}

function Get-PnhAgentAppDir {
    Split-Path -Parent (Get-PnhAgentLibDir)
}

function Read-PnhAgentJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return (ConvertFrom-Json -InputObject $raw)
}

function Write-PnhAgentLog {
    param([string]$Message, [string]$Level = 'Info', $Data)
    if (Get-Command -Name Write-PnhLog -ErrorAction SilentlyContinue) {
        try {
            if ($null -ne $Data) { Write-PnhLog -Message $Message -Level $Level -Data $Data }
            else { Write-PnhLog -Message $Message -Level $Level }
        } catch { Write-Verbose ('Agent: ' + $_.Exception.Message) }
    }
}

function Add-PnhAgentFileLine {
    param([string]$Path, [string]$Line)
    try {
        [System.IO.File]::AppendAllText($Path, $Line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Verbose ('Agent: ' + $_.Exception.Message) }
}

function ConvertTo-PnhAgentCompactJson {
    param($InputObject)
    if ($null -eq $InputObject) { return 'null' }
    return (ConvertTo-Json -InputObject $InputObject -Depth 10 -Compress)
}

function Get-PnhAgentShortText {
    param([string]$Text, [int]$Max = 2000)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    $marker = ' ...[gekuerzt/trimmed]'
    return $Text.Substring(0, [Math]::Max(0, $Max - $marker.Length)) + $marker
}

# ---------------------------------------------------------------------------------------------------------------
# Text cleaning: think tags, Markdown, emoji
# ---------------------------------------------------------------------------------------------------------------

function ConvertTo-PnhAgentPlainText {
    param([string]$Text, [int]$MaxLength = 0)
    if (-not $Text) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, '(?is)<think>.*?</think>', '')
    $t = [regex]::Replace($t, '(?is)^.*?</think>', '')          # opening tag was swallowed, closing tag leaked
    $t = [regex]::Replace($t, '(?is)<think>.*$', '')            # unterminated thinking
    $t = [regex]::Replace($t, '(?is)<tool_call>.*?</tool_call>', '')
    $t = [regex]::Replace($t, '(?is)</?tool_call>', '')
    $t = [regex]::Replace($t, '(?m)^[ \t]*```[a-zA-Z]*[ \t]*$', '')
    $t = [regex]::Replace($t, '(?m)^[ \t]{0,3}#{1,6}[ \t]*', '')
    $t = [regex]::Replace($t, '(?m)^[ \t]*(?:[-*+]|•)[ \t]+', '')
    $t = [regex]::Replace($t, '\*\*|__|`', '')
    $t = [regex]::Replace($t, '(?<![\w*])\*(?=\S)([^*\r\n]+?)\*(?![\w*])', '$1')
    $t = [regex]::Replace($t, '[\uD800-\uDBFF][\uDC00-\uDFFF]', '')
    $t = [regex]::Replace($t, '[☀-➿⬀-⯿⌚⌛⏩-⏺️‍⃣]', '')
    $t = [regex]::Replace($t, '[ \t]+(\r?\n)', '$1')
    $t = [regex]::Replace($t, '(\r?\n){3,}', "`n`n")
    $t = [regex]::Replace($t, '[ \t]{2,}', ' ')
    $t = $t.Trim()
    if ($MaxLength -gt 0 -and $t.Length -gt $MaxLength) {
        $cut = $t.Substring(0, $MaxLength)
        $sp = $cut.LastIndexOf(' ')
        if ($sp -gt ($MaxLength / 2)) { $cut = $cut.Substring(0, $sp) }
        $t = $cut.TrimEnd() + ' ...'
    }
    return $t
}

# ---------------------------------------------------------------------------------------------------------------
# Diagnosis trimming (loop rule 1: ~1500 tokens)
# ---------------------------------------------------------------------------------------------------------------

function Get-PnhAgentShrunk {
    param($Value, [int]$Str, [int]$Items, [int]$Depth)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Value.Length -gt $Str) { return $Value.Substring(0, $Str) + '...' }
        return $Value
    }
    if ($Value -is [datetime]) { return $Value.ToString('s') }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [single] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [int16] -or $Value -is [byte]) {
        return $Value
    }
    if ($Value -is [enum] -or $Value -is [guid] -or $Value -is [timespan]) { return $Value.ToString() }
    if ($Depth -le 0) { return '...' }
    $h = $null
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        $h = ConvertTo-PnhAgentHashtable -InputObject $Value
    }
    if ($h) {
        $o = [ordered]@{}
        $keys = @($h.Keys)
        if ($Value -is [System.Management.Automation.PSCustomObject]) { $keys = @($Value.PSObject.Properties | ForEach-Object { $_.Name }) }
        elseif ($Value -is [System.Collections.Specialized.OrderedDictionary]) { $keys = @($Value.Keys) }
        foreach ($k in $keys) {
            $v = $h[$k]
            if ($null -eq $v -or ($v -is [string] -and $v -eq '')) { continue }
            $o[[string]$k] = Get-PnhAgentShrunk -Value $v -Str $Str -Items $Items -Depth ($Depth - 1)
        }
        return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $all = @($Value)
        $out = New-Object System.Collections.Generic.List[object]
        $n = [Math]::Min($Items, $all.Count)
        for ($i = 0; $i -lt $n; $i++) { $out.Add((Get-PnhAgentShrunk -Value $all[$i] -Str $Str -Items $Items -Depth ($Depth - 1))) }
        if ($all.Count -gt $Items) { $out.Add(('... +{0}' -f ($all.Count - $Items))) }
        return , $out.ToArray()
    }
    $s = [string]$Value
    if ($s.Length -gt $Str) { $s = $s.Substring(0, $Str) + '...' }
    return $s
}

function ConvertTo-PnhAgentTrimmedJson {
    param($InputObject, [int]$MaxChars = 6000)
    $json = 'null'
    $levels = @(
        @{ Str = 400; Items = 25; Depth = 8 },
        @{ Str = 200; Items = 12; Depth = 6 },
        @{ Str = 120; Items = 6; Depth = 5 },
        @{ Str = 60; Items = 3; Depth = 4 },
        @{ Str = 40; Items = 2; Depth = 3 }
    )
    foreach ($l in $levels) {
        $shrunk = Get-PnhAgentShrunk -Value $InputObject -Str $l.Str -Items $l.Items -Depth $l.Depth
        $json = ConvertTo-Json -InputObject $shrunk -Depth 12 -Compress
        if ($json.Length -le $MaxChars) { return $json }
    }
    return (Get-PnhAgentShortText -Text $json -Max $MaxChars)
}

# ---------------------------------------------------------------------------------------------------------------
# Catalogue access: categories, findings, tool registry
# ---------------------------------------------------------------------------------------------------------------

function Get-PnhAgentCategory {
    param([Parameter(Mandatory)][string]$Id)
    $path = Join-Path (Join-Path (Get-PnhAgentAppDir) 'toolbox') 'categories.json'
    $doc = Read-PnhAgentJsonFile -Path $path
    if (-not $doc) { return $null }
    $list = Get-PnhAgentMember -Object $doc -Name 'categories'
    if ($null -eq $list) { $list = $doc }
    foreach ($c in @($list)) {
        if ([string](Get-PnhAgentMember -Object $c -Name 'id') -eq $Id) { return $c }
    }
    return $null
}

function Get-PnhAgentFindings {
    # -> hashtable code -> @{Code; Meaning; Candidates; Stop}. Tolerates the field names of the research draft.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set')]
    param([string]$Language = 'en')
    $result = @{}
    $path = Join-Path (Join-Path (Get-PnhAgentAppDir) 'toolbox') 'findings.json'
    $doc = Read-PnhAgentJsonFile -Path $path
    if (-not $doc) { return $result }
    $items = $null
    foreach ($n in 'findings', 'befund_codes', 'codes') {
        $items = Get-PnhAgentMember -Object $doc -Name $n
        if ($null -ne $items) { break }
    }
    if ($null -eq $items) { $items = $doc }
    $list = @()
    if ($items -is [System.Array]) { $list = $items }
    else {
        $h = ConvertTo-PnhAgentHashtable -InputObject $items
        if ($h) {
            foreach ($k in $h.Keys) {
                $v = ConvertTo-PnhAgentHashtable -InputObject $h[$k]
                if (-not $v) { continue }
                if (-not $v.ContainsKey('code')) { $v['code'] = $k }
                $list += , $v
            }
        }
    }
    $index = 0
    foreach ($f in $list) {
        $index++
        $code = [string](Get-PnhAgentMember -Object $f -Name 'code')
        if (-not $code) { $code = [string](Get-PnhAgentMember -Object $f -Name 'id') }
        if (-not $code) { continue }
        $cands = $null
        foreach ($n in 'candidates', 'actions', 'kandidaten') {
            $cands = Get-PnhAgentMember -Object $f -Name $n
            if ($null -ne $cands) { break }
        }
        $meaning = $null
        foreach ($n in 'meaning', 'title', 'text', 'bedeutung') {
            $meaning = Get-PnhAgentMember -Object $f -Name $n
            if ($null -ne $meaning) { break }
        }
        $stop = Get-PnhAgentMember -Object $f -Name 'stop'
        if ($null -eq $stop) { $stop = Get-PnhAgentMember -Object $f -Name 'stopp' }
        $result[$code] = @{
            Code       = $code
            Meaning    = (Get-PnhAgentLocalized -Value $meaning -Language $Language)
            Candidates = @(@($cands) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            Stop       = (Get-PnhAgentLocalized -Value $stop -Language $Language)
            Blocks     = @(@(Get-PnhAgentMember -Object $f -Name 'blocks') | Where-Object { $_ } | ForEach-Object { [string]$_ })
            Severity   = (Get-PnhAgentMember -Object $f -Name 'severity')
            Index      = $index
        }
    }
    return $result
}

function Get-PnhAgentFlagOrder {
    # Most important first: explicit severity (critical, high, medium, low, info or a number) if the catalogue has
    # one; otherwise stop findings, then findings with repair candidates, then the rest; ties in catalogue order.
    param([string[]]$Flags, $Findings)
    $sev = @{ critical = 0; high = 1; medium = 2; low = 3; info = 4 }
    $rows = @()
    $pos = 0
    foreach ($f in @($Flags)) {
        $pos++
        $fi = if ($Findings.ContainsKey($f)) { $Findings[$f] } else { $null }
        $rank = 5; $idx = 99999
        if ($fi) {
            $idx = [int]$fi.Index
            $s = $fi.Severity
            if ($null -ne $s -and $sev.ContainsKey([string]$s)) { $rank = $sev[[string]$s] }
            elseif ($null -ne $s -and ([string]$s) -match '^\d+$') { $rank = [int]$s }
            elseif ($fi.Stop -or @($fi.Blocks).Count -gt 0) { $rank = 0 }
            elseif (@($fi.Candidates).Count -gt 0) { $rank = 2 }
            else { $rank = 4 }
        }
        $rows += , [pscustomobject]@{ Code = $f; Rank = $rank; Index = $idx; Pos = $pos }
    }
    return @($rows | Sort-Object -Property Rank, Index, Pos | ForEach-Object { $_.Code })
}

function Test-PnhAgentIdMatch {
    param([string]$Id, $Patterns)
    foreach ($p in @($Patterns)) {
        if ($p -and $Id -like [string]$p) { return $true }
    }
    return $false
}

function Get-PnhAgentToolKey {
    param([string]$Name)
    if (-not $Name) { return '' }
    $n = $Name.Trim().ToLowerInvariant()
    $n = [regex]::Replace($n, '^(functions?|tools?)[.:/]', '')
    $n = [regex]::Replace($n, '[^a-z0-9]+', '_')
    return $n.Trim('_')
}

function Resolve-PnhAgentToolName {
    param([string]$Name, $Registry)
    if (-not $Name) { return $null }
    if ($Registry.Contains($Name)) { return $Name }
    $key = Get-PnhAgentToolKey -Name $Name
    foreach ($k in $Registry.Keys) {
        $e = $Registry[$k]
        if ((Get-PnhAgentToolKey -Name $k) -eq $key) { return $k }
        if ($e.ActionId -and (Get-PnhAgentToolKey -Name $e.ActionId) -eq $key) { return $k }
    }
    return $null
}

function New-PnhAgentBuiltinTool {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds data in memory only')]
    param([string]$Name, [string]$Description, [System.Collections.IDictionary]$Properties, [string[]]$Required)
    $props = [ordered]@{}
    foreach ($k in $Properties.Keys) { $props[$k] = @{ type = 'string'; description = $Properties[$k] } }
    return [ordered]@{
        type     = 'function'
        function = [ordered]@{
            name        = $Name
            description = $Description
            parameters  = [ordered]@{ type = 'object'; properties = $props; required = $Required }
        }
    }
}

function New-PnhAgentToolRegistry {
    # -> @{Registry (ordered name -> entry); Definitions (array for Ollama)}
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds data in memory only')]
    param($Actions, [bool]$FreeShell, [string]$Language = 'en', [int]$MaxActionTools = 20, [bool]$NoAsk = $false)
    $reg = [ordered]@{}
    $defs = New-Object System.Collections.Generic.List[object]
    $count = 0
    foreach ($a in @($Actions)) {
        if ($null -eq $a) { continue }
        if ($count -ge $MaxActionTools) { break }
        $id = [string](Get-PnhAgentMember -Object $a -Name 'id')
        $def = $null
        try { $def = @(ConvertTo-PnhToolDefinitions -Actions @($a) -Language $Language)[0] } catch { $def = $null }
        if ($null -eq $def) { continue }
        $fn = Get-PnhAgentMember -Object $def -Name 'function'
        $name = [string](Get-PnhAgentMember -Object $fn -Name 'name')
        if (-not $name) { $name = $id }
        if ($reg.Contains($name)) { continue }
        $reg[$name] = @{
            Name     = $name
            Kind     = 'action'
            ActionId = $id
            Action   = $a
            Changes  = [bool](Get-PnhAgentMember -Object $a -Name 'changes')
            Title    = (Get-PnhAgentLocalized -Value (Get-PnhAgentMember -Object $a -Name 'title') -Language $Language)
            Schema   = (Get-PnhAgentMember -Object $fn -Name 'parameters')
        }
        $defs.Add($def)
        $count++
    }
    $builtins = @()
    if (-not $NoAsk) { $builtins += , @('ask_user', 'ask', (New-PnhAgentBuiltinTool -Name 'ask_user' -Description (Get-PnhAgentText 'tool.ask' $Language) -Properties @{ question = (Get-PnhAgentText 'tool.ask.question' $Language) } -Required @('question'))) }
    if ($FreeShell) {
        $builtins += , @('run_powershell', 'shell', (New-PnhAgentBuiltinTool -Name 'run_powershell' -Description (Get-PnhAgentText 'tool.shell' $Language) -Properties ([ordered]@{ command = (Get-PnhAgentText 'tool.shell.command' $Language); why = (Get-PnhAgentText 'tool.shell.why' $Language) }) -Required @('command', 'why')))
    }
    $builtins += , @('finish', 'finish', (New-PnhAgentBuiltinTool -Name 'finish' -Description (Get-PnhAgentText 'tool.finish' $Language) -Properties @{ summary = (Get-PnhAgentText 'tool.finish.summary' $Language) } -Required @('summary')))
    foreach ($b in $builtins) {
        $reg[$b[0]] = @{
            Name = $b[0]; Kind = $b[1]; ActionId = $null; Action = $null; Changes = $false; Title = $b[0]
            Schema = $b[2].function.parameters
        }
        $defs.Add($b[2])
    }
    return @{ Registry = $reg; Definitions = $defs.ToArray() }
}

# ---------------------------------------------------------------------------------------------------------------
# Argument normalization (small models: "C:" for a drive letter, numbers as strings, wrong key case)
# ---------------------------------------------------------------------------------------------------------------

function ConvertTo-PnhAgentArgValue {
    # -> @{Value; Problem}
    param($Value, [string]$PropName, $Prop)
    $type = Get-PnhAgentMember -Object $Prop -Name 'type'
    if ($type -is [System.Array]) { $type = @($type | Where-Object { $_ -ne 'null' })[0] }
    $type = [string]$type
    $enum = Get-PnhAgentMember -Object $Prop -Name 'enum'
    $pattern = [string](Get-PnhAgentMember -Object $Prop -Name 'pattern')
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    if ($Value -is [string]) {
        $Value = $Value.Trim()
        if ($Value.Length -ge 2 -and (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or ($Value.StartsWith("'") -and $Value.EndsWith("'")))) {
            $Value = $Value.Substring(1, $Value.Length - 2).Trim()
        }
    }

    switch ($type) {
        'integer' {
            if ($Value -is [string]) {
                $l = 0L; $d = 0.0
                if ([long]::TryParse($Value, [System.Globalization.NumberStyles]::Integer, $inv, [ref]$l)) { return @{ Value = $l } }
                if ([double]::TryParse(($Value -replace ',', '.'), [System.Globalization.NumberStyles]::Float, $inv, [ref]$d) -and $d -eq [Math]::Floor($d)) { return @{ Value = [long]$d } }
                return @{ Value = $Value; Problem = "'$PropName' must be a whole number" }
            }
            if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
                if ($Value -eq [Math]::Floor($Value)) { return @{ Value = [long]$Value } }
                return @{ Value = $Value; Problem = "'$PropName' must be a whole number" }
            }
            if ($Value -is [bool]) { return @{ Value = $Value; Problem = "'$PropName' must be a whole number" } }
            return @{ Value = $Value }
        }
        'number' {
            if ($Value -is [string]) {
                $d = 0.0
                if ([double]::TryParse(($Value -replace ',', '.'), [System.Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return @{ Value = $d } }
                return @{ Value = $Value; Problem = "'$PropName' must be a number" }
            }
            return @{ Value = $Value }
        }
        'boolean' {
            if ($Value -is [bool]) { return @{ Value = $Value } }
            $s = ([string]$Value).Trim().ToLowerInvariant()
            if ($s -in @('true', 'yes', 'ja', '1', 'y', 'j', 'wahr')) { return @{ Value = $true } }
            if ($s -in @('false', 'no', 'nein', '0', 'n', 'falsch')) { return @{ Value = $false } }
            return @{ Value = $Value; Problem = "'$PropName' must be true or false" }
        }
        'array' {
            if ($Value -is [string]) { $Value = @($Value -split '\s*[,;]\s*' | Where-Object { $_ -ne '' }) }
            $itemProp = Get-PnhAgentMember -Object $Prop -Name 'items'
            $out = @()
            foreach ($v in @($Value)) {
                if ($itemProp) {
                    $r = ConvertTo-PnhAgentArgValue -Value $v -PropName $PropName -Prop $itemProp
                    if ($r.Problem) { return @{ Value = $Value; Problem = $r.Problem } }
                    $out += , $r.Value
                } else { $out += , $v }
            }
            return @{ Value = $out }
        }
        default {
            if ($type -eq 'object') { return @{ Value = $Value } }
            if ($null -ne $Value -and $Value -isnot [string]) {
                if ($Value -is [bool]) { $Value = ([string]$Value).ToLowerInvariant() }
                elseif ($Value -is [System.Collections.IEnumerable]) { $Value = (@($Value) -join ',') }
                else { $Value = [string]$Value }
            }
            $s = [string]$Value
            $cands = New-Object System.Collections.Generic.List[string]
            $cands.Add($s)
            $t = $s.TrimEnd(':', '\', '/', ' ', '.')
            if ($t -ne $s) { $cands.Add($t) }
            if ($s -match '^([A-Za-z])(:[\\/]?)?$') { $cands.Add($Matches[1]); $cands.Add($Matches[1].ToUpperInvariant()) }
            $cands.Add($t.ToUpperInvariant())
            $cands.Add($t.ToLowerInvariant())
            if ($enum) {
                foreach ($c in $cands) {
                    foreach ($e in @($enum)) { if ([string]$e -eq $c) { return @{ Value = $e } } }
                }
                foreach ($c in $cands) {
                    foreach ($e in @($enum)) { if (([string]$e).ToLowerInvariant() -eq $c.ToLowerInvariant()) { return @{ Value = $e } } }
                }
                return @{ Value = $s; Problem = ("'{0}' must be one of: {1}" -f $PropName, (@($enum) -join ', ')) }
            }
            if ($pattern) {
                foreach ($c in $cands) {
                    $ok = $false
                    try { $ok = [regex]::IsMatch($c, $pattern) } catch { $ok = $true }
                    if ($ok) { return @{ Value = $c } }
                }
                return @{ Value = $s; Problem = ("'{0}' has the wrong form" -f $PropName) }
            }
            $hint = ($PropName + ' ' + [string](Get-PnhAgentMember -Object $Prop -Name 'description'))
            if ($s -match '^([A-Za-z]):[\\/]?$' -and $hint -match '(?i)drive|laufwerk|letter|buchstabe') { return @{ Value = $Matches[1].ToUpperInvariant() } }
            return @{ Value = $s }
        }
    }
}

function ConvertTo-PnhAgentArguments {
    # -> @{Arguments (hashtable); Problems (string[])}
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set')]
    param($Arguments, $Schema)
    $problems = New-Object System.Collections.Generic.List[string]
    $in = ConvertTo-PnhAgentHashtable -InputObject $Arguments
    if ($null -eq $in) {
        $problems.Add('the arguments are not a JSON object')
        return @{ Arguments = @{}; Problems = $problems.ToArray() }
    }
    $props = ConvertTo-PnhAgentHashtable -InputObject (Get-PnhAgentMember -Object $Schema -Name 'properties')
    if (-not $props -or $props.Count -eq 0) { return @{ Arguments = @{}; Problems = @() } }
    $required = @(@(Get-PnhAgentMember -Object $Schema -Name 'required') | Where-Object { $_ } | ForEach-Object { [string]$_ })

    $out = @{}
    $unknown = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($in.Keys)) {
        $match = $null
        foreach ($p in $props.Keys) { if ($p -eq $k) { $match = $p; break } }
        if (-not $match) {
            $kk = Get-PnhAgentToolKey -Name $k
            foreach ($p in $props.Keys) { if ((Get-PnhAgentToolKey -Name $p) -eq $kk) { $match = $p; break } }
        }
        if ($match) { $out[$match] = $in[$k] } else { $unknown.Add($k) }
    }
    # A single unknown key and a single missing required value: the model used another name for it.
    $missing = @($required | Where-Object { -not $out.ContainsKey($_) })
    if ($missing.Count -eq 1 -and $unknown.Count -eq 1) { $out[$missing[0]] = $in[$unknown[0]] }

    $final = @{}
    foreach ($p in @($out.Keys)) {
        $v = $out[$p]
        if ($null -eq $v -or ($v -is [string] -and $v.Trim() -eq '')) { continue }
        $r = ConvertTo-PnhAgentArgValue -Value $v -PropName $p -Prop $props[$p]
        if ($r.Problem) { $problems.Add($r.Problem) }
        $final[$p] = $r.Value
    }
    foreach ($req in $required) {
        if (-not $final.ContainsKey($req)) { $problems.Add("'$req' is missing") }
    }
    return @{ Arguments = $final; Problems = $problems.ToArray() }
}

# ---------------------------------------------------------------------------------------------------------------
# Tool calls hidden in text (small models) and isolation detection
# ---------------------------------------------------------------------------------------------------------------

function Get-PnhAgentSalvagedCalls {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set')]
    param([string]$Content, $Registry)
    $calls = New-Object System.Collections.Generic.List[object]
    if (-not $Content) { return }
    $snippets = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Content, '(?s)<tool_call>(.*?)</tool_call>')) { $snippets.Add($m.Groups[1].Value.Trim()) }
    foreach ($m in [regex]::Matches($Content, '(?s)```(?:json)?(.*?)```')) { $snippets.Add($m.Groups[1].Value.Trim()) }
    $plain = [regex]::Replace($Content, '(?is)<think>.*?</think>', '').Trim()
    if ($plain.StartsWith('{') -and $plain.EndsWith('}')) { $snippets.Add($plain) }
    $i = 0
    foreach ($s in $snippets) {
        if (-not $s.StartsWith('{')) { continue }
        $o = $null
        try { $o = ConvertFrom-Json -InputObject $s -ErrorAction Stop } catch { continue }
        $name = Get-PnhAgentMember -Object $o -Name 'name'
        $callArgs = Get-PnhAgentMember -Object $o -Name 'arguments'
        if ($null -eq $callArgs) { $callArgs = Get-PnhAgentMember -Object $o -Name 'parameters' }
        $fn = Get-PnhAgentMember -Object $o -Name 'function'
        if (-not $name -and $fn) {
            $name = Get-PnhAgentMember -Object $fn -Name 'name'
            $callArgs = Get-PnhAgentMember -Object $fn -Name 'arguments'
        }
        if (-not $name) { continue }
        $resolved = Resolve-PnhAgentToolName -Name ([string]$name) -Registry $Registry
        if (-not $resolved) { continue }
        $calls.Add(@{ Id = ('salvaged_{0}' -f $i); Name = $resolved; Arguments = $callArgs })
        $i++
    }
    return $calls.ToArray()
}

function ConvertTo-PnhAgentBool {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    $t = ([string]$Value).Trim().ToLowerInvariant()
    if ($t -in @('true', 'yes', 'ja', '1', '$true')) { return $true }
    if ($t -in @('false', 'no', 'nein', '0', '$false', '')) { return $false }
    return $null
}

function Get-PnhAgentStopWhenValue {
    # Catalogue rule "stopWhen": {property; finding}. Reads the property from the action result (Data object, or
    # Output as JSON, "Name : Value" or "Name=Value"). -> $true (stop), $false (explicitly not), $null (unknown).
    param($Action, $Result)
    $sw = Get-PnhAgentMember -Object $Action -Name 'stopWhen'
    if ($null -eq $sw -or $null -eq $Result) { return $null }
    $prop = [string](Get-PnhAgentMember -Object $sw -Name 'property')
    if (-not $prop) { return $null }
    if ((Get-PnhAgentMember -Object $Result -Name 'Ok') -eq $false) { return $null }
    foreach ($n in 'Data', 'Output') {
        $v = Get-PnhAgentMember -Object $Result -Name $n
        if ($null -eq $v) { continue }
        if ($v -isnot [string]) {
            $pv = Get-PnhAgentMember -Object @($v)[0] -Name $prop
            if ($null -ne $pv) { return (ConvertTo-PnhAgentBool $pv) }
            continue
        }
        $t = $v.Trim()
        if ($t.StartsWith('{') -or $t.StartsWith('[')) {
            try {
                $o = @(ConvertFrom-Json -InputObject $t -ErrorAction Stop)[0]
                $pv = Get-PnhAgentMember -Object $o -Name $prop
                if ($null -ne $pv) { return (ConvertTo-PnhAgentBool $pv) }
            } catch { Write-Verbose ('Agent: output is not JSON: ' + $_.Exception.Message) }
        }
        $m = [regex]::Match($t, '(?im)"?\b' + [regex]::Escape($prop) + '\b"?\s*[:=]\s*"?(true|false|yes|no|ja|nein|1|0)\b')
        if ($m.Success) { return (ConvertTo-PnhAgentBool $m.Groups[1].Value) }
    }
    return $null
}

function Test-PnhAgentBlocked {
    # A changing action is blocked when it matches a "blocks" pattern of an active stop finding ("@reboot" = needs
    # a restart, "*" = every change). Read-only actions are never blocked: looking is always allowed.
    param($Action, [string[]]$Blocks)
    if ((Get-PnhAgentMember -Object $Action -Name 'changes') -ne $true) { return $false }
    $id = [string](Get-PnhAgentMember -Object $Action -Name 'id')
    foreach ($b in @($Blocks)) {
        if (-not $b) { continue }
        if ($b -eq '@reboot') { if ((Get-PnhAgentMember -Object $Action -Name 'reboot') -eq $true) { return $true }; continue }
        if ($id -like $b) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------------------------------------------
# Free PowerShell (only for catalogue entries with freeShell = true)
# ---------------------------------------------------------------------------------------------------------------

function Get-PnhAgentReadOnlyAliases {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set')]
    param()
    @{
        'gci' = 'Get-ChildItem'; 'ls' = 'Get-ChildItem'; 'dir' = 'Get-ChildItem'; 'gc' = 'Get-Content'; 'cat' = 'Get-Content'
        'type' = 'Get-Content'; 'gp' = 'Get-ItemProperty'; 'gpv' = 'Get-ItemPropertyValue'; 'gi' = 'Get-Item'
        'gsv' = 'Get-Service'; 'gps' = 'Get-Process'; 'ps' = 'Get-Process'; 'gwmi' = 'Get-WmiObject'; 'gcim' = 'Get-CimInstance'
        '?' = 'Where-Object'; 'where' = 'Where-Object'; '%' = 'ForEach-Object'; 'foreach' = 'ForEach-Object'
        'select' = 'Select-Object'; 'sort' = 'Sort-Object'; 'ft' = 'Format-Table'; 'fl' = 'Format-List'; 'fw' = 'Format-Wide'
        'measure' = 'Measure-Object'; 'group' = 'Group-Object'; 'echo' = 'Write-Output'; 'write' = 'Write-Output'
        'gm' = 'Get-Member'; 'gl' = 'Get-Location'; 'pwd' = 'Get-Location'; 'gcm' = 'Get-Command'; 'gal' = 'Get-Alias'
        'sls' = 'Select-String'; 'compare' = 'Compare-Object'; 'diff' = 'Compare-Object'; 'rvpa' = 'Resolve-Path'
        'gdr' = 'Get-PSDrive'; 'gv' = 'Get-Variable'; 'gjb' = 'Get-Job'; 'ghy' = 'Get-History'; 'h' = 'Get-History'
        'history' = 'Get-History'
    }
}

function Test-PnhAgentReadOnlyExe {
    param([string]$Base, [string[]]$Arguments)
    $a = @($Arguments | ForEach-Object { $_.ToLowerInvariant() })
    $first = if ($a.Count -gt 0) { $a[0] } else { '' }
    switch ($Base) {
        'ipconfig' { return (@($a | Where-Object { $_ -notin @('/all', '-all', '/displaydns', '-displaydns', '/?') }).Count -eq 0) }
        { $_ -in @('ping', 'tracert', 'pathping', 'whoami', 'systeminfo', 'driverquery', 'hostname', 'getmac', 'netstat', 'tasklist') } { return $true }
        'nslookup' { return ($a.Count -ge 1 -and $first -ne '-') }
        'arp' { return (@($a | Where-Object { $_ -in @('-s', '-d', '/s', '/d') }).Count -eq 0) }
        'route' { return ($first -eq 'print') }
        'netsh' {
            if ($a -notcontains 'show') { return $false }
            foreach ($w in $a) {
                if ($w -in @('set', 'add', 'delete', 'reset', 'install', 'uninstall', 'import', 'export', 'connect', 'disconnect', 'flush', 'trace', 'start', 'stop', 'dump')) { return $false }
                if ($w -match '^key\s*=\s*clear$') { return $false }   # would reveal a Wi-Fi password
            }
            return $true
        }
        'w32tm' {
            if (@($a | Where-Object { $_ -in @('/resync', '/config', '/register', '/unregister', '/debug') }).Count -gt 0) { return $false }
            return (@($a | Where-Object { $_ -in @('/query', '/tz', '/stripchart', '/monitor') }).Count -gt 0)
        }
        'sc' { return ($first -in @('query', 'queryex', 'qc', 'qdescription', 'qfailure', 'qtriggerinfo', 'qprivs', 'qsidtype', 'getdisplayname', 'getkeyname', 'enumdepend')) }
        'wevtutil' { return ($first -in @('el', 'enum-logs', 'gl', 'get-log', 'qe', 'query-events', 'gp', 'get-publisher', 'ep', 'enum-publishers', 'gli', 'get-loginfo')) }
        'powercfg' { return ($first -in @('/l', '/list', '/q', '/query', '/a', '/availablesleepstates', '/getactivescheme', '/requests', '/lastwake')) }
        'dsregcmd' { return ($a.Count -eq 1 -and $first -eq '/status') }
        'gpresult' { return (@($a | Where-Object { $_ -notin @('/r', '/v', '/z', '/scope', 'user', 'computer') }).Count -eq 0 -and $a.Count -gt 0) }
        'pnputil' { return ($first -like '/enum-*') }
        'reg' { return ($first -eq 'query') }
        'vssadmin' { return ($first -eq 'list') }
        'bcdedit' { return ($a.Count -eq 0 -or $first -in @('/enum', '/v')) -and (@($a | Where-Object { $_ -in @('/set', '/delete', '/create', '/deletevalue', '/import', '/export', '/copy') }).Count -eq 0) }
        'wmic' {
            if (@($a | Where-Object { $_ -in @('call', 'set', 'delete', 'create') }).Count -gt 0) { return $false }
            return (@($a | Where-Object { $_ -in @('get', 'list') }).Count -gt 0)
        }
        default { return $false }
    }
}

function Test-PnhAgentReadOnlyCommandName {
    param([string]$Name, $CommandAst)
    $leaf = @($Name -split '[\\/]')[-1]
    $lower = $leaf.ToLowerInvariant()
    $isExe = $lower.EndsWith('.exe')
    $base = if ($isExe) { $lower.Substring(0, $lower.Length - 4) } else { $lower }
    $aliases = Get-PnhAgentReadOnlyAliases
    $cmdlet = $leaf
    if (-not $isExe -and $aliases.ContainsKey($lower)) { $cmdlet = $aliases[$lower] }
    if ($base -eq 'sc' -and -not $isExe) { return $false }   # "sc" is Set-Content in Windows PowerShell

    $argList = New-Object System.Collections.Generic.List[string]
    $params = New-Object System.Collections.Generic.List[string]
    $elements = @($CommandAst.CommandElements)
    for ($i = 1; $i -lt $elements.Count; $i++) {
        $e = $elements[$i]
        if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
            $params.Add($e.ParameterName)
            $argList.Add($e.Extent.Text)
        } elseif ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $argList.Add($e.Value)
        } else {
            $argList.Add($e.Extent.Text)
        }
    }

    if (-not $isExe -and $cmdlet -match '^(Get|Test|Measure|Select|Resolve|Find)-\w+$') {
        if ($cmdlet -in @('Get-Credential')) { return $false }
        foreach ($p in $params) { if ($p -in @('Repair', 'Fix', 'Reset', 'Delete', 'Remove', 'Clear', 'Kill', 'Online')) { return $false } }
        return $true
    }
    $extra = @('Format-Table', 'Format-List', 'Format-Wide', 'Format-Custom', 'Format-Hex', 'Where-Object', 'ForEach-Object',
        'Sort-Object', 'Group-Object', 'Out-String', 'Out-Null', 'Write-Output', 'ConvertTo-Json', 'ConvertTo-Csv',
        'ConvertTo-Html', 'ConvertTo-Xml', 'ConvertFrom-Json', 'ConvertFrom-Csv', 'ConvertFrom-StringData', 'Compare-Object')
    if (-not $isExe -and $cmdlet -in $extra) { return $true }
    return (Test-PnhAgentReadOnlyExe -Base $base -Arguments $argList.ToArray())
}

function Test-PnhAgentReadOnlyCommand {
    # -> @{ReadOnly(bool); Reason; ParseError}. Conservative: anything not clearly read-only needs a "Yes".
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return @{ ReadOnly = $false; Reason = 'empty'; ParseError = 'empty command' } }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { return @{ ReadOnly = $false; Reason = 'parse'; ParseError = $errors[0].Message } }

    foreach ($r in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)) {
        if ($r.Location.Extent.Text -notmatch '^\$null$') { return @{ ReadOnly = $false; Reason = 'redirection' } }
    }
    $safeMethods = @('ToString', 'Trim', 'TrimStart', 'TrimEnd', 'Split', 'Substring', 'ToLower', 'ToUpper', 'ToLowerInvariant',
        'ToUpperInvariant', 'Contains', 'StartsWith', 'EndsWith', 'IndexOf', 'LastIndexOf', 'Replace', 'PadLeft', 'PadRight',
        'GetType', 'Equals', 'CompareTo', 'Format', 'Join', 'Round', 'Floor', 'Ceiling', 'Abs', 'Max', 'Min', 'Parse',
        'TryParse', 'IsNullOrEmpty', 'IsNullOrWhiteSpace', 'GetHostEntry', 'GetHostAddresses', 'GetHostName',
        'GetEnvironmentVariable', 'GetFolderPath', 'GetLogicalDrives', 'GetDrives', 'Exists', 'GetFiles', 'GetDirectories',
        'ReadAllText', 'ReadAllLines', 'ToShortDateString', 'ToLongDateString', 'ToShortTimeString', 'AddDays', 'AddHours',
        'AddMinutes', 'AddSeconds', 'Subtract', 'GetValue', 'GetValueNames', 'GetSubKeyNames', 'IsInRole', 'GetCurrent',
        'Where', 'ForEach')
    foreach ($i in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $m = $i.Member
        if ($m -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return @{ ReadOnly = $false; Reason = 'dynamic method' } }
        if ($m.Value -notin $safeMethods) { return @{ ReadOnly = $false; Reason = ('method ' + $m.Value) } }
    }
    foreach ($as in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        foreach ($v in $as.Left.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $drive = $v.VariablePath.DriveName
            if ($drive -and $drive -notin @('env', 'variable', 'local', 'script', 'global', 'private', 'using')) { return @{ ReadOnly = $false; Reason = 'provider write' } }
        }
    }
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($c.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) { return @{ ReadOnly = $false; Reason = 'dot-source' } }
        $name = $c.GetCommandName()
        if (-not $name) { return @{ ReadOnly = $false; Reason = 'dynamic command' } }
        if (-not (Test-PnhAgentReadOnlyCommandName -Name $name -CommandAst $c)) { return @{ ReadOnly = $false; Reason = ('command ' + $name) } }
    }
    return @{ ReadOnly = $true; Reason = 'read-only' }
}

function Get-PnhAgentShellHost {
    if ($env:SystemRoot) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $ps) { return $ps }
    }
    return (Get-Process -Id $PID).Path
}

function Invoke-PnhAgentConfirm {
    param($St, [hashtable]$Request)
    try {
        $ans = @(& $St.Confirm $Request)
        if ($ans.Count -eq 0) { return $false }
        return ($ans[-1] -eq $true)
    } catch {
        Write-PnhAgentLog -Message ('Confirm failed: ' + $_.Exception.Message) -Level Warn
        return $false
    }
}

function Invoke-PnhAgentShell {
    param($St, [string]$Command, [string]$Why)
    $r = [ordered]@{
        Id = 'run_powershell'; Command = $Command; Ok = $false; Verified = $null; Declined = $false; Blocked = $false
        ReadOnly = $false; Output = ''; Error = $null; RolledBack = $false; NeedsReboot = $false; ExitCode = $null; TimedOut = $false
    }
    $denied = $true
    if (Get-Command -Name Test-PnhCommandDenied -ErrorAction SilentlyContinue) {
        try { $denied = [bool](Test-PnhCommandDenied -Command $Command) } catch { $denied = $true }
    } else {
        Write-PnhAgentLog -Message 'Deny-list (Test-PnhCommandDenied) not loaded: free commands are blocked.' -Level Warn
    }
    if ($denied) {
        $r.Blocked = $true; $r.Error = 'blocked by the deny-list'
        Write-PnhAgentLog -Message 'Free command blocked' -Level Warn -Data @{ command = $Command }
        return $r
    }
    $ro = Test-PnhAgentReadOnlyCommand -Command $Command
    if ($ro.ParseError) { $r.Error = 'syntax: ' + $ro.ParseError; return $r }
    $r.ReadOnly = [bool]$ro.ReadOnly
    if (-not $ro.ReadOnly -and $St.ReadOnly) { $r['Skipped'] = $true; return $r }
    if (-not $ro.ReadOnly -and $St.ShellReadOnlyOnly) {
        $r.Blocked = $true; $r.Error = 'blocked: a stop finding allows only read-only commands'
        Write-PnhAgentLog -Message 'Free command blocked by a stop finding' -Level Warn -Data @{ command = $Command }
        return $r
    }
    if (-not $ro.ReadOnly) {
        if (-not $Why) { $Why = Get-PnhAgentText 'agent.action.shell' $St.Lang }
        $req = @{
            Title   = (Get-PnhAgentText 'agent.confirm.command.title' $St.Lang)
            Explain = (Get-PnhAgentText 'agent.confirm.command.explain' $St.Lang @($Why, $Command))
            Risk    = 'medium'; Reboot = $false; Kind = 'command'; Command = $Command
        }
        if (-not (Invoke-PnhAgentConfirm -St $St -Request $req)) {
            $r.Declined = $true
            Write-PnhAgentLog -Message 'Free command declined' -Data @{ command = $Command }
            return $r
        }
        if (Get-Command -Name New-PnhRestorePoint -ErrorAction SilentlyContinue) {
            try {
                $rp = New-PnhRestorePoint -Description "Plug'n'Heal"
                Write-PnhAgentLog -Message 'Restore point before free command' -Data $rp
            } catch { Write-PnhAgentLog -Message ('Restore point failed: ' + $_.Exception.Message) -Level Warn }
        }
    }
    $script = "`$ProgressPreference = 'SilentlyContinue'`ntry { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { Write-Verbose ('Agent: ' + $_.Exception.Message) }`n& {`n" + $Command + "`n} 2>&1 | Out-String -Width 160"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    try {
        $p = Start-PnhHidden -FilePath (Get-PnhAgentShellHost) -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $enc) -TimeoutSeconds 120
        $r.ExitCode = Get-PnhAgentMember -Object $p -Name 'ExitCode'
        $r.TimedOut = [bool](Get-PnhAgentMember -Object $p -Name 'TimedOut')
        $out = [string](Get-PnhAgentMember -Object $p -Name 'StdOut')
        $err = [string](Get-PnhAgentMember -Object $p -Name 'StdErr')
        if ($err.Trim()) { $out = $out.TrimEnd() + "`n" + $err.Trim() }
        $r.Output = Get-PnhAgentShortText -Text $out.Trim() -Max 2000
        $r.Ok = (-not $r.TimedOut) -and ($r.ExitCode -eq 0 -or $null -eq $r.ExitCode)
        if ($r.TimedOut) { $r.Error = 'timeout after 120 s' }
    } catch {
        $r.Error = $_.Exception.Message
    }
    Write-PnhAgentLog -Message 'Free command run' -Data @{ command = $Command; readOnly = $r.ReadOnly; ok = $r.Ok; exitCode = $r.ExitCode; timedOut = $r.TimedOut }
    return $r
}

# ---------------------------------------------------------------------------------------------------------------
# Loop internals. $St is one hashtable that holds the whole run state.
# ---------------------------------------------------------------------------------------------------------------

function Send-PnhAgentEvent {
    param($St, [Alias('Event')][hashtable]$Payload)
    if (-not $St.OnEvent) { return }
    try { & $St.OnEvent $Payload } catch { Write-PnhAgentLog -Message ('OnEvent failed: ' + $_.Exception.Message) -Level Warn }
}

function Add-PnhAgentChatLog {
    param($St, $Entry)
    if (-not $St.ChatLog) { return }
    $Entry['t'] = (Get-Date).ToString('o')
    try { Add-PnhAgentFileLine -Path $St.ChatLog -Line (ConvertTo-PnhAgentCompactJson $Entry) } catch { Write-Verbose ('Agent: ' + $_.Exception.Message) }
}

function Stop-PnhAgentLoop {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds data in memory only')]
    param($St, [string]$Reason)
    if (-not $St.Stop) {
        $St.Stop = $true
        $St.StoppedReason = $Reason
        Write-PnhAgentLog -Message ('Agent loop stops: ' + $Reason) -Data @{ round = $St.Rounds }
    }
}

function Get-PnhAgentValidNames {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set')]
    param($St)
    return (@($St.Registry.Keys) -join ', ')
}

function Add-PnhAgentToolMessage {
    param($St, $Call, [string]$Name, [string]$Content)
    $msg = [ordered]@{ role = 'tool'; tool_name = $Name; content = (Get-PnhAgentShortText -Text $Content -Max 2000) }
    $id = Get-PnhAgentMember -Object $Call -Name 'Id'
    if ($id) { $msg['tool_call_id'] = [string]$id }
    $St.Messages.Add($msg)
}

function Register-PnhAgentFormatProblem {
    # Malformed or empty answer: one corrective message per streak; a second one in a row stops the loop.
    param($St, [string]$Reason)
    $St.Errors++
    Write-PnhAgentLog -Message ('Model answer unusable: ' + $Reason) -Level Warn -Data @{ round = $St.Rounds; errors = $St.Errors }
    if ($St.Errors -ge 3) { Stop-PnhAgentLoop -St $St -Reason 'errors'; return }
    if ($St.CorrectionSent) { Stop-PnhAgentLoop -St $St -Reason 'malformed'; return }
    $St.Messages.Add([ordered]@{ role = 'user'; content = (Get-PnhAgentText 'model.correct' $St.Lang @((Get-PnhAgentValidNames $St))) })
    $St.CorrectionSent = $true
}

function Register-PnhAgentError {
    param($St)
    $St.Errors++
    if ($St.Errors -ge 3) { Stop-PnhAgentLoop -St $St -Reason 'errors' }
}

function Invoke-PnhAgentCheck {
    param($St, [switch]$Quiet)
    if (-not $St.CheckId) { return $null }
    if (-not $Quiet) { Send-PnhAgentEvent -St $St -Payload @{ Type = 'step-start'; Key = 'verify'; Text = (Get-PnhAgentText 'step.verify' $St.Lang) } }
    $c = $null
    try { $c = Invoke-PnhSuccessCheck -Id $St.CheckId }
    catch { $c = @{ Passed = $false; Details = @{}; Summary = ('check failed: ' + $_.Exception.Message) } }
    if ($null -eq $c) { $c = @{ Passed = $false; Details = @{}; Summary = '' } }
    $passed = ((Get-PnhAgentMember -Object $c -Name 'Passed') -eq $true)
    $St.LastCheck = @{ Passed = $passed; Summary = [string](Get-PnhAgentMember -Object $c -Name 'Summary'); Details = (Get-PnhAgentMember -Object $c -Name 'Details') }
    $St.CheckFresh = $true
    if ($passed) { $St.CheckPassed = $true }
    Write-PnhAgentLog -Message ('Success check ' + $St.CheckId + ': ' + $passed) -Data $St.LastCheck
    if (-not $Quiet) { Send-PnhAgentEvent -St $St -Payload @{ Type = 'step-done'; Key = 'verify'; Ok = $passed } }
    return $St.LastCheck
}

function Add-PnhAgentActionRecord {
    param($St, $Result, [string]$Title, [bool]$Changes, [string]$Kind)
    $St.Actions.Add($Result)
    $St.ActionLog.Add(@{ Result = $Result; Title = $Title; Changes = $Changes; Kind = $Kind })
}

function Skip-PnhAgentChange {
    # Read-only mode: a changing action or command is not run and not confirmed; it becomes a recommendation.
    param($St, $Call, [string]$Name, [string]$Id, [string]$Title, $Result)
    if (-not $Result) {
        $Result = [ordered]@{ Id = $Id; Ok = $false; Verified = $false; Declined = $false; Output = ''; Error = $null; RolledBack = $false; NeedsReboot = $false }
        Send-PnhAgentEvent -St $St -Payload @{ Type = 'action'; Id = $Id; Title = $Title }
    }
    $Result['Skipped'] = $true
    $Result['Reason'] = 'read-only'
    Send-PnhAgentEvent -St $St -Payload @{ Type = 'action-result'; Result = $Result }
    Send-PnhAgentEvent -St $St -Payload @{ Type = 'message'; Text = (Get-PnhAgentText 'event.action_readonly' $St.Lang @($Title)); Source = 'agent' }
    Add-PnhAgentActionRecord -St $St -Result $Result -Title $Title -Changes $true -Kind 'skipped'
    if ($Title -and -not $St.WouldHelp.Contains($Title)) { $St.WouldHelp.Add($Title) }
    Write-PnhAgentLog -Message ('Read-only mode, change skipped: ' + $Id) -Data @{ title = $Title }
    Add-PnhAgentToolMessage -St $St -Call $Call -Name $Name -Content (Get-PnhAgentText 'model.readonly.skipped' $St.Lang)
}

function Invoke-PnhAgentToolCall {
    # Executes one tool call and appends exactly one tool message. Returns $true if a change was made.
    param($St, $Call, [bool]$ChangeDoneThisRound)
    $rawName = [string](Get-PnhAgentMember -Object $Call -Name 'Name')
    $name = Resolve-PnhAgentToolName -Name $rawName -Registry $St.Registry
    if (-not $name) {
        Add-PnhAgentToolMessage -St $St -Call $Call -Name $rawName -Content (Get-PnhAgentText 'model.unknown' $St.Lang @($rawName, (Get-PnhAgentValidNames $St)))
        Write-PnhAgentLog -Message ('Unknown tool: ' + $rawName) -Level Warn
        Register-PnhAgentError -St $St
        return $false
    }
    $entry = $St.Registry[$name]
    $norm = ConvertTo-PnhAgentArguments -Arguments (Get-PnhAgentMember -Object $Call -Name 'Arguments') -Schema $entry.Schema
    $argError = [string](Get-PnhAgentMember -Object $Call -Name 'ArgumentsError')
    if ($argError -and $norm.Problems.Count -gt 0) { $norm.Problems = @($argError) + @($norm.Problems) }
    if ($norm.Problems.Count -gt 0) {
        Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.badargs' $St.Lang @($name, ($norm.Problems -join '; ')))
        Write-PnhAgentLog -Message ('Invalid arguments for ' + $name) -Level Warn -Data @{ problems = $norm.Problems; raw = (Get-PnhAgentMember -Object $Call -Name 'Arguments') }
        Register-PnhAgentError -St $St
        return $false
    }
    $callArgs = $norm.Arguments

    if ($entry.Kind -eq 'finish') {
        $St.ModelWords = ConvertTo-PnhAgentPlainText -Text ([string]$callArgs['summary']) -MaxLength 600
        $St.Finished = $true
        Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content 'ok'
        Stop-PnhAgentLoop -St $St -Reason $(if ($St.CheckPassed) { 'solved' } else { 'finished' })
        return $false
    }
    if ($St.CheckPassed) {
        Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.skipped.solved' $St.Lang)
        Stop-PnhAgentLoop -St $St -Reason 'solved'
        return $false
    }
    if ($ChangeDoneThisRound -and ($entry.Kind -eq 'shell' -or $entry.Changes)) {
        Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.skipped.one' $St.Lang)
        return $false
    }

    # Loop rule 4: the same call twice without any effect in between stops the loop.
    $sorted = [ordered]@{}
    foreach ($k in (@($callArgs.Keys) | Sort-Object)) { $sorted[$k] = $callArgs[$k] }
    $key = $name + '|' + (ConvertTo-PnhAgentCompactJson $sorted)
    if ($St.Seen.ContainsKey($key) -and $St.Seen[$key] -eq $St.StateVersion) {
        Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.repeated' $St.Lang)
        Stop-PnhAgentLoop -St $St -Reason 'repeated-call'
        return $false
    }
    $St.Seen[$key] = $St.StateVersion

    switch ($entry.Kind) {
        'ask' {
            $q = ConvertTo-PnhAgentPlainText -Text ([string]$callArgs['question']) -MaxLength 300
            $yes = Invoke-PnhAgentConfirm -St $St -Request @{ Title = $q; Explain = ''; Risk = 'low'; Reboot = $false; Kind = 'question' }
            Write-PnhAgentLog -Message 'ask_user' -Data @{ question = $q; answer = $yes }
            $St.StateVersion++
            $St.CheckFresh = $false
            $St.Errors = 0
            Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content $(if ($yes) { Get-PnhAgentText 'model.answer.yes' $St.Lang } else { Get-PnhAgentText 'model.answer.no' $St.Lang })
            return $false
        }
        'shell' {
            $why = ConvertTo-PnhAgentPlainText -Text ([string]$callArgs['why']) -MaxLength 200
            $title = if ($why) { $why } else { Get-PnhAgentText 'agent.action.shell' $St.Lang }
            Send-PnhAgentEvent -St $St -Payload @{ Type = 'action'; Id = 'run_powershell'; Title = $title }
            $r = Invoke-PnhAgentShell -St $St -Command ([string]$callArgs['command']) -Why $why
            if ($r.Contains('Skipped') -and $r['Skipped']) {
                Skip-PnhAgentChange -St $St -Call $Call -Name $name -Id 'run_powershell' -Title $title -Result $r
                return $false
            }
            Send-PnhAgentEvent -St $St -Payload @{ Type = 'action-result'; Result = $r }
            Add-PnhAgentActionRecord -St $St -Result $r -Title $title -Changes (-not $r.ReadOnly) -Kind 'shell'
            $data = [ordered]@{ ok = $r.Ok; readOnly = $r.ReadOnly; output = (Get-PnhAgentShortText -Text $r.Output -Max 1500) }
            if ($r.Blocked) {
                Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.blocked' $St.Lang)
                Register-PnhAgentError -St $St
                return $false
            }
            if ($r.Declined) {
                Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.declined' $St.Lang)
                return $false
            }
            if ($r.Error -and $r.Error.StartsWith('syntax')) {
                Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.syntax' $St.Lang @($r.Error))
                Register-PnhAgentError -St $St
                return $false
            }
            if ($r.Error) { $data['error'] = $r.Error }
            $changed = $false
            if (-not $r.ReadOnly -and $r.Ok) {
                $changed = $true
                $St.StateVersion++
                $St.CheckFresh = $false
                $c = Invoke-PnhAgentCheck -St $St
                if ($c) { $data['check'] = [ordered]@{ passed = $c.Passed; summary = $c.Summary } }
                if ($c -and $c.Passed) { $data['hint'] = Get-PnhAgentText 'model.check.passed' $St.Lang @($c.Summary) }
            }
            if ($r.Ok) { $St.Errors = 0 } else { Register-PnhAgentError -St $St }
            Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (ConvertTo-PnhAgentCompactJson $data)
            return $changed
        }
        default {
            $a = $entry.Action
            if ($St.ReadOnly -and $entry.Changes) {
                Skip-PnhAgentChange -St $St -Call $Call -Name $name -Id $entry.ActionId -Title $entry.Title
                return $false
            }
            Send-PnhAgentEvent -St $St -Payload @{ Type = 'action'; Id = $entry.ActionId; Title = $entry.Title }
            $r = $null
            $actionArgs = @{ Id = $entry.ActionId; Parameters = $callArgs; RunFolder = $St.RunFolder; Confirm = $St.Confirm }
            # Small models (confirmAllChanges / tier 1) ask before every change, whatever the action's own rule says;
            # Test-PnhConfirmRequired decides what counts as a change.
            if ($St.ConfirmAll) { $actionArgs['ForceConfirm'] = $true }
            try {
                $r = Invoke-PnhAction @actionArgs
            } catch {
                $r = @{ Id = $entry.ActionId; Ok = $false; Verified = $false; Declined = $false; Output = ''; Error = $_.Exception.Message; RolledBack = $false; NeedsReboot = $false }
            }
            if ($null -eq $r) { $r = @{ Id = $entry.ActionId; Ok = $false; Verified = $false; Declined = $false; Output = ''; Error = 'no result'; RolledBack = $false; NeedsReboot = $false } }
            Send-PnhAgentEvent -St $St -Payload @{ Type = 'action-result'; Result = $r }
            Add-PnhAgentActionRecord -St $St -Result $r -Title $entry.Title -Changes $entry.Changes -Kind 'action'

            $ok = ((Get-PnhAgentMember -Object $r -Name 'Ok') -eq $true)
            $verified = Get-PnhAgentMember -Object $r -Name 'Verified'
            $declined = ((Get-PnhAgentMember -Object $r -Name 'Declined') -eq $true)
            $err = [string](Get-PnhAgentMember -Object $r -Name 'Error')

            if ((Get-PnhAgentStopWhenValue -Action $a -Result $r) -eq $true) {
                $code = [string](Get-PnhAgentMember -Object (Get-PnhAgentMember -Object $a -Name 'stopWhen') -Name 'finding')
                $text = if ($St.Findings.ContainsKey($code)) { $St.Findings[$code].Stop } else { '' }
                $St.StopText = $text
                if ($code -match '(?i)isolat') { $St.Isolated = $true }
                Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.stopped' $St.Lang @($text))
                Stop-PnhAgentLoop -St $St -Reason $(if ($St.Isolated) { 'isolation' } else { 'stop-finding' })
                return $false
            }
            if ($declined) {
                Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (Get-PnhAgentText 'model.declined' $St.Lang)
                return $false
            }
            $data = [ordered]@{ ok = $ok }
            if ($entry.Changes) { $data['verified'] = $verified }
            $out = [string](Get-PnhAgentMember -Object $r -Name 'Output')
            if ($out) { $data['output'] = Get-PnhAgentShortText -Text $out -Max 1500 }
            if ($err) { $data['error'] = Get-PnhAgentShortText -Text $err -Max 300 }
            if ((Get-PnhAgentMember -Object $r -Name 'RolledBack') -eq $true) { $data['rolledBack'] = $true }
            if ((Get-PnhAgentMember -Object $r -Name 'NeedsReboot') -eq $true) { $data['needsReboot'] = $true }
            if ($entry.Changes -and $ok -and $verified -ne $true) { $data['note'] = Get-PnhAgentText 'model.notverified' $St.Lang }

            $changed = $false
            if ($entry.Changes -and $ok) {
                $changed = $true
                if ($verified -eq $true) { $St.StateVersion++; $St.AnyChangeVerified = $true }
                $St.CheckFresh = $false
                # Loop rule 3: after each changing action run the category success check.
                $c = Invoke-PnhAgentCheck -St $St
                if ($c) {
                    $data['check'] = [ordered]@{ passed = $c.Passed; summary = $c.Summary }
                    if ($c.Passed) { $data['hint'] = Get-PnhAgentText 'model.check.passed' $St.Lang @($c.Summary) }
                    else { $data['hint'] = Get-PnhAgentText 'model.check.failed' $St.Lang @($c.Summary) }
                }
            }
            if ($ok) { $St.Errors = 0 } else { Register-PnhAgentError -St $St }
            Add-PnhAgentToolMessage -St $St -Call $Call -Name $name -Content (ConvertTo-PnhAgentCompactJson $data)
            return $changed
        }
    }
}

function Invoke-PnhAgentChatRound {
    param($St)
    $msgs = $St.Messages.ToArray()
    $req = [ordered]@{
        type = 'request'; round = $St.Rounds; model = $St.Model; think = $St.Think; numCtx = $St.NumCtx
        messageCount = $msgs.Count
        newMessages = @(if ($St.LoggedMessages -lt $msgs.Count) { $msgs[$St.LoggedMessages..($msgs.Count - 1)] })
    }
    if (-not $St.ToolsLogged) { $req['tools'] = $St.ToolDefs; $St.ToolsLogged = $true }
    Add-PnhAgentChatLog -St $St -Entry $req
    $St.LoggedMessages = $msgs.Count
    $params = @{ Server = $St.Server; Model = $St.Model; Messages = $msgs; Tools = $St.ToolDefs; Think = [bool]$St.Think; TimeoutSeconds = $St.ChatTimeout }
    if ($St.NumCtx -gt 0) { $params['NumCtx'] = [int]$St.NumCtx }
    $resp = Invoke-PnhChat @params
    $calls = @()
    foreach ($tc in @(Get-PnhAgentMember -Object $resp -Name 'ToolCalls')) {
        if ($null -eq $tc) { continue }
        $calls += , @{ Id = (Get-PnhAgentMember -Object $tc -Name 'Id'); Name = (Get-PnhAgentMember -Object $tc -Name 'Name'); Arguments = (Get-PnhAgentMember -Object $tc -Name 'Arguments'); ArgumentsError = (Get-PnhAgentMember -Object $tc -Name 'ArgumentsError') }
    }
    Add-PnhAgentChatLog -St $St -Entry ([ordered]@{
        type = 'response'; round = $St.Rounds; content = [string](Get-PnhAgentMember -Object $resp -Name 'Content')
        thinking = [string](Get-PnhAgentMember -Object $resp -Name 'Thinking'); toolCalls = $calls
        durationMs = (Get-PnhAgentMember -Object $resp -Name 'DurationMs'); error = (Get-PnhAgentMember -Object $resp -Name 'Error')
        promptTokens = (Get-PnhAgentMember -Object $resp -Name 'PromptTokens'); outputTokens = (Get-PnhAgentMember -Object $resp -Name 'OutputTokens')
    })
    # Invoke-PnhChat reports HTTP 500, timeouts and unreadable answers in Error instead of throwing.
    $err = [string](Get-PnhAgentMember -Object $resp -Name 'Error')
    if ($err -and $calls.Count -eq 0 -and -not [string](Get-PnhAgentMember -Object $resp -Name 'Content')) {
        throw ('{0}: {1}' -f [string](Get-PnhAgentMember -Object $resp -Name 'ErrorKind'), $err)
    }
    return @{ Content = [string](Get-PnhAgentMember -Object $resp -Name 'Content'); Thinking = [string](Get-PnhAgentMember -Object $resp -Name 'Thinking'); ToolCalls = $calls }
}

function New-PnhAgentUserMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds data in memory only')]
    param($St, [string]$TopicTitle, [string]$UserText, $Diagnosis, [string[]]$Flags, $Findings)
    $L = $St.Lang
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-PnhAgentText 'model.user.topic' $L @($TopicTitle)))
    $words = ConvertTo-PnhAgentPlainText -Text $UserText -MaxLength 600
    if ($words) { $lines.Add((Get-PnhAgentText 'model.user.words' $L @($words))) } else { $lines.Add((Get-PnhAgentText 'model.user.nowords' $L)) }
    if ($St.InitialCheck) {
        $state = if ($St.InitialCheck.Passed) { Get-PnhAgentText 'model.passed' $L } else { Get-PnhAgentText 'model.failed' $L }
        $lines.Add((Get-PnhAgentText 'model.user.checknow' $L @($state, $St.InitialCheck.Summary)))
    }
    if ($Flags.Count -gt 0) {
        $lines.Add((Get-PnhAgentText 'model.user.findings' $L))
        foreach ($f in $Flags) {
            $m = if ($Findings.ContainsKey($f)) { $Findings[$f].Meaning } else { '' }
            if ($m) { $lines.Add(('{0}: {1}' -f $f, $m)) } else { $lines.Add($f) }
        }
    } else { $lines.Add((Get-PnhAgentText 'model.user.nofindings' $L)) }
    foreach ($n in $St.StopNotes) { $lines.Add((Get-PnhAgentText 'model.user.stop' $L @($n))) }
    $facts = Get-PnhAgentMember -Object $Diagnosis -Name 'Facts'
    $lines.Add((Get-PnhAgentText 'model.user.facts' $L))
    $lines.Add((ConvertTo-PnhAgentTrimmedJson -InputObject $facts -MaxChars 6000))
    if ($St.ReadOnly) { $lines.Add((Get-PnhAgentText 'model.user.readonly' $L)) }
    $lines.Add((Get-PnhAgentText $(if ($St.Category -eq 'all') { 'model.user.task.all' } else { 'model.user.task' }) $L))
    return ($lines -join "`n")
}

function Get-PnhAgentSystemPrompt {
    param([string]$Language)
    $path = Join-Path (Join-Path (Get-PnhAgentAppDir) 'prompts') ('system.{0}.md' -f $Language)
    if (Test-Path -LiteralPath $path) {
        $t = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8).Trim()
        if ($t) { return $t }
    }
    if ($Language -eq 'de') {
        return 'Du bist ein vorsichtiger Helfer auf diesem Windows-Computer. Benutze nur die Werkzeuge. Erfinde keine Werte. Sage nie, dass etwas behoben ist, bevor die automatische Prüfung bestanden ist. Schreibe kurz und einfach, ohne Markdown und ohne Emoji. Wenn du fertig bist, rufe finish auf.'
    }
    return 'You are a careful helper on this Windows computer. Use only the tools. Never invent values. Never say something is fixed before the automatic check passed. Write short and simple, no Markdown, no emoji. When you are done, call finish.'
}

function New-PnhAgentSummary {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds data in memory only')]
    param($St, [bool]$Solved)
    $L = $St.Lang
    $lines = New-Object System.Collections.Generic.List[string]
    $changesTried = @($St.ActionLog | Where-Object { $_.Kind -ne 'skipped' } | Where-Object { $_.Changes -or (Get-PnhAgentMember -Object $_.Result -Name 'Declined') -eq $true -or (Get-PnhAgentMember -Object $_.Result -Name 'Blocked') -eq $true })
    switch ($St.StoppedReason) {
        'isolation' { $lines.Add((Get-PnhAgentText 'result.stopped.isolated' $L)) }
        'stop-finding' { $lines.Add((Get-PnhAgentText 'agent.summary.stop' $L @($St.StopText))) }
        'error' { $lines.Add((Get-PnhAgentText 'result.unsolved.title' $L)); $lines.Add((Get-PnhAgentText 'agent.summary.error' $L @($St.ErrorText))) }
        default {
            if ($Solved) { $lines.Add(((Get-PnhAgentText 'result.solved.title' $L) + ' ' + (Get-PnhAgentText 'result.solved.text' $L))) }
            elseif ($St.LastCheck -and $St.LastCheck.Passed -and -not $St.AnyChangeVerified) { $lines.Add((Get-PnhAgentText 'agent.summary.nothingfound' $L)) }
            elseif ($St.ReadOnly) { $lines.Add((Get-PnhAgentText 'result.readonly.text' $L)) }
            else { $lines.Add((Get-PnhAgentText 'result.unsolved.title' $L)) }
        }
    }
    $lines.Add('')
    if ($changesTried.Count -gt 0) {
        $lines.Add((Get-PnhAgentText 'result.actions.title' $L))
        foreach ($e in $changesTried) {
            $r = $e.Result
            $title = ConvertTo-PnhAgentPlainText -Text $e.Title -MaxLength 120
            $key = 'agent.summary.item.failed'
            if ((Get-PnhAgentMember -Object $r -Name 'Blocked') -eq $true) { $key = 'agent.summary.item.blocked' }
            elseif ((Get-PnhAgentMember -Object $r -Name 'Declined') -eq $true) { $key = 'agent.summary.item.declined' }
            elseif ((Get-PnhAgentMember -Object $r -Name 'RolledBack') -eq $true) { $key = 'agent.summary.item.rolledback' }
            elseif ((Get-PnhAgentMember -Object $r -Name 'Ok') -eq $true) {
                if ((Get-PnhAgentMember -Object $r -Name 'Verified') -eq $true) { $key = 'agent.summary.item.ok' }
                else { $key = 'agent.summary.item.unverified' }
            }
            $lines.Add((Get-PnhAgentText $key $L @($title)))
        }
    } elseif ($St.StoppedReason -notin @('stop-finding')) {
        $lines.Add((Get-PnhAgentText 'agent.summary.none' $L))
    }
    if ($St.ReadOnly -and -not $Solved -and $St.StoppedReason -notin @('isolation', 'stop-finding', 'error')) {
        $help = @($St.WouldHelp)
        if ($help.Count -eq 0) { $help = @($St.OfferedChanging | Select-Object -First 3) }
        if ($help.Count -gt 0) {
            $lines.Add((Get-PnhAgentText 'agent.summary.wouldhelp' $L))
            foreach ($h in $help) { $lines.Add('- ' + (ConvertTo-PnhAgentPlainText -Text $h -MaxLength 120)) }
        }
    }
    if ($St.LastCheck -and $St.LastCheck.Summary) {
        $lines.Add((Get-PnhAgentText 'agent.summary.check' $L @((ConvertTo-PnhAgentPlainText -Text $St.LastCheck.Summary -MaxLength 300))))
    }
    if ($St.StoppedReason -notin @('isolation', 'stop-finding')) {
        foreach ($n in $St.StopNotes) { $lines.Add((Get-PnhAgentText 'agent.summary.note' $L @((ConvertTo-PnhAgentPlainText -Text $n -MaxLength 400)))) }
    }
    $reboot = @($St.Actions | Where-Object { (Get-PnhAgentMember -Object $_ -Name 'NeedsReboot') -eq $true -and (Get-PnhAgentMember -Object $_ -Name 'Ok') -eq $true })
    if ($reboot.Count -gt 0) { $lines.Add((Get-PnhAgentText 'result.reboot' $L)) }
    # Loop rule 5: the model's words are wording only. They never decide the result, and are marked as a guess
    # unless the script confirmed the fix.
    if ($St.ModelWords -and $St.StoppedReason -notin @('isolation', 'stop-finding')) {
        $lines.Add('')
        if ($Solved) { $lines.Add((Get-PnhAgentText 'agent.summary.words' $L @($St.ModelWords))) }
        else { $lines.Add((Get-PnhAgentText 'agent.summary.guess' $L @($St.ModelWords))) }
    }
    if (-not $Solved) {
        $whyKeys = @{ 'max-rounds' = 'result.stopped.max_rounds'; 'repeated-call' = 'result.stopped.no_progress'; 'errors' = 'result.stopped.errors'; 'malformed' = 'agent.summary.malformed' }
        if ($whyKeys.ContainsKey([string]$St.StoppedReason)) { $lines.Add((Get-PnhAgentText $whyKeys[[string]$St.StoppedReason] $L)) }
        if ($St.StoppedReason -notin @('isolation', 'stop-finding') -and -not $St.ReadOnly) { $lines.Add((Get-PnhAgentText 'result.unsolved.text' $L)) }
    }
    return (($lines -join "`n") -replace "(`n){3,}", "`n`n").Trim()
}

function Write-PnhAgentSummaryFile {
    param($St, [string]$Summary, [string]$TopicTitle, [string]$UserText)
    if (-not $St.RunFolder) { return }
    $L = $St.Lang
    $nl = "`r`n"
    $head = @(
        (Get-PnhAgentText 'report.title' $L),
        (Get-PnhAgentText 'report.computer' $L @([Environment]::MachineName)),
        (Get-PnhAgentText 'report.date' $L @((Get-Date).ToString('dd.MM.yyyy HH:mm'))),
        (Get-PnhAgentText 'report.problem' $L @($TopicTitle))
    )
    $words = ConvertTo-PnhAgentPlainText -Text $UserText -MaxLength 300
    if ($words) { $head += (Get-PnhAgentText 'report.user_text' $L @($words)) }
    $head += (Get-PnhAgentText 'agent.summary.model' $L @($St.Model))
    if ($St.ReadOnly) { $head += (Get-PnhAgentText 'report.readonly' $L) }
    $text = ($head -join $nl) + $nl + $nl + ($Summary -replace "`r?`n", $nl) + $nl + $nl + (Get-PnhAgentText 'report.log' $L @($St.RunFolder)) + $nl
    try {
        [System.IO.File]::WriteAllText((Join-Path $St.RunFolder 'summary.txt'), $text, (New-Object System.Text.UTF8Encoding($true)))
    } catch { Write-PnhAgentLog -Message ('summary.txt not written: ' + $_.Exception.Message) -Level Warn }
}

# ---------------------------------------------------------------------------------------------------------------
# Public: Invoke-PnhAgent (contract 5.7)
# ---------------------------------------------------------------------------------------------------------------

function Invoke-PnhAgent {
    <#
    .SYNOPSIS
        The agent loop (ARCHITECTURE.md 5.7): diagnose, offer tools, let the model choose, act, verify, summarize.
    .DESCRIPTION
        Returns [pscustomobject]@{Solved; Summary; Rounds; Actions; StoppedReason; Check; Model; Category; Seconds; Error}.
        StoppedReason: solved, finished, max-rounds, repeated-call, errors, malformed, isolation, stop-finding, error.
        Categories "all" and "other" run the full diagnosis; "all" works through the findings by importance, "other"
        offers only the candidates of the findings (no extra diagnostics, no free PowerShell).
    .PARAMETER ReadOnly
        The user refused administrator rights: only read-only actions run, -Confirm is never called, every change
        the model chooses is skipped with an event and listed in the summary as what would help.
        Solved is $true only when the category success check passed at the end (and the problem existed before or a
        verified change was made). Never throws; errors end with StoppedReason 'error'.
        Writes chat.jsonl, diagnose.json and summary.txt into -RunFolder and logs actions with Write-PnhLog.
    .PARAMETER ModelEntry
        Catalogue entry of the model (Select-PnhModel Candidates[i].Model). Its ctx is the num_ctx of every request
        (the server's ContextLength only when ctx is missing), so a fallback model keeps its own context length.
        Models with confirmAllChanges = true (or tier 1) ask before every changing catalogue action, also when the
        action itself would not ask (Invoke-PnhAction -ForceConfirm).
    .PARAMETER Confirm
        Callback (not ShouldProcess): gets @{Title; Explain; Risk; Reboot; Kind} and returns $true or $false.
    .PARAMETER OnEvent
        Callback that gets one hashtable per event (Type: step-start, step-done, thinking, action, action-result,
        message, done, error). message has Source 'model' (the model's own words, not verified) or 'agent'.
        action-result of a change skipped in read-only mode has Result.Skipped = $true.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = '-Confirm is the contract callback, not ShouldProcess')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Server,
        [Parameter(Mandatory)] $ModelEntry,
        [Parameter(Mandatory)] [string] $Category,
        [string] $UserText,
        [Parameter(Mandatory)] [string] $RunFolder,
        [Parameter(Mandatory)] [scriptblock] $OnEvent,
        [Parameter(Mandatory)] [scriptblock] $Confirm,
        [int] $MaxRounds = 12,
        [ValidateSet('de', 'en')] [string] $Language,
        [switch] $ReadOnly
    )
    $lang = $Language
    if (-not $lang) {
        $lang = 'en'
        if (Get-Command -Name Get-PnhLanguage -ErrorAction SilentlyContinue) { try { $lang = [string](Get-PnhLanguage) } catch { Write-Verbose ('Agent: ' + $_.Exception.Message) } }
    }
    if ($lang -notin @('de', 'en')) { $lang = 'en' }
    # num_ctx belongs to the model (Get-PnhModelContext via Select-PnhModel Candidates), not to the server: after a
    # step-down the server still has the first model's OLLAMA_CONTEXT_LENGTH, so the entry's ctx goes with each request.
    $numCtx = [int](Get-PnhAgentMember -Object $ModelEntry -Name 'ctx')
    if ($numCtx -le 0) { $numCtx = [int](Get-PnhAgentMember -Object $Server -Name 'ContextLength') }
    if ($numCtx -le 0) { $numCtx = 16384 }
    $chatTimeout = [int](Get-PnhAgentMember -Object $ModelEntry -Name 'timeoutSeconds')
    if ($chatTimeout -le 0) { $chatTimeout = 600 }

    $St = @{
        Lang = $lang; Server = $Server; Model = [string](Get-PnhAgentMember -Object $ModelEntry -Name 'tag')
        Think = ((Get-PnhAgentMember -Object $ModelEntry -Name 'think') -eq $true)
        FreeShell = ((Get-PnhAgentMember -Object $ModelEntry -Name 'freeShell') -eq $true)
        NumCtx = $numCtx; ChatTimeout = $chatTimeout
        RunFolder = $RunFolder; ChatLog = $null; OnEvent = $OnEvent; Confirm = $Confirm
        ReadOnly = [bool]$ReadOnly; Category = $Category; Tier = [int](Get-PnhAgentMember -Object $ModelEntry -Name 'tier')
        ConfirmAll = (((Get-PnhAgentMember -Object $ModelEntry -Name 'confirmAllChanges') -eq $true) -or ([int](Get-PnhAgentMember -Object $ModelEntry -Name 'tier') -eq 1))
        WouldHelp = (New-Object System.Collections.Generic.List[string]); OfferedChanging = @()
        Messages = (New-Object System.Collections.Generic.List[object])
        Actions = (New-Object System.Collections.Generic.List[object])
        ActionLog = (New-Object System.Collections.Generic.List[object])
        Registry = [ordered]@{}; ToolDefs = @(); LoggedMessages = 0; ToolsLogged = $false
        Rounds = 0; Errors = 0; CorrectionSent = $false; StateVersion = 0; Seen = @{}
        CheckId = $null; InitialCheck = $null; LastCheck = $null; CheckFresh = $false; CheckPassed = $false
        AnyChangeVerified = $false; ModelWords = $null; Finished = $false; Isolated = $false
        Stop = $false; StoppedReason = $null; StopText = $null; ErrorText = $null
        Findings = @{}; StopNotes = (New-Object System.Collections.Generic.List[string]); ShellReadOnlyOnly = $false
    }
    if ($ReadOnly) { $St.Confirm = { param($Request) Write-PnhAgentLog -Message 'Read-only mode: confirmation answered no' -Data @{ title = [string]$Request.Title }; $false } }
    if ($RunFolder) {
        if (-not (Test-Path -LiteralPath $RunFolder)) { New-Item -ItemType Directory -Path $RunFolder -Force | Out-Null }
        $St.ChatLog = Join-Path $RunFolder 'chat.jsonl'
    }
    $topic = $Category
    $solved = $false
    $started = Get-Date
    Write-PnhAgentLog -Message 'Agent starts' -Data @{ category = $Category; model = $St.Model; think = $St.Think; freeShell = $St.FreeShell; language = $lang; maxRounds = $MaxRounds; readOnly = [bool]$ReadOnly; numCtx = $numCtx; confirmAllChanges = $St.ConfirmAll }

    try {
        # --- category and diagnosis ------------------------------------------------------------------------------
        $cat = Get-PnhAgentCategory -Id $Category
        if (-not $cat) { throw ("Unknown category '{0}'" -f $Category) }
        $titleKey = [string](Get-PnhAgentMember -Object $cat -Name 'titleKey')
        if ($titleKey) {
            $t = Get-PnhAgentText -Key $titleKey -Language $lang
            if ($t -and $t -ne $titleKey) { $topic = $t }
        }
        $St.CheckId = [string](Get-PnhAgentMember -Object $cat -Name 'success')
        $sections = @(@(Get-PnhAgentMember -Object $cat -Name 'diagnose') | Where-Object { $_ })
        $patterns = @(@(Get-PnhAgentMember -Object $cat -Name 'actions') | Where-Object { $_ })

        Send-PnhAgentEvent -St $St -Payload @{ Type = 'step-start'; Key = 'diagnose'; Text = (Get-PnhAgentText 'step.diagnose' $lang) }
        $fullDiagnosis = ($Category -in @('all', 'other')) -or $sections.Count -eq 0
        $diag = if ($fullDiagnosis) { Invoke-PnhDiagnose } else { Invoke-PnhDiagnose -Sections $sections }
        if ($RunFolder) {
            try { [System.IO.File]::WriteAllText((Join-Path $RunFolder 'diagnose.json'), (ConvertTo-Json -InputObject $diag -Depth 10), (New-Object System.Text.UTF8Encoding($false))) } catch { Write-Verbose ('Agent: ' + $_.Exception.Message) }
        }
        $flags = @(@(Get-PnhAgentMember -Object $diag -Name 'Flags') | Where-Object { $_ } | ForEach-Object {
                if ($_ -is [string]) { $_ } else { [string](Get-PnhAgentMember -Object $_ -Name 'Code') } } | Where-Object { $_ } | Select-Object -Unique)
        $findings = Get-PnhAgentFindings -Language $lang
        $St.Findings = $findings
        $flags = @(Get-PnhAgentFlagOrder -Flags $flags -Findings $findings)
        if ($St.CheckId) {
            $St.InitialCheck = Invoke-PnhAgentCheck -St $St -Quiet
        }
        Send-PnhAgentEvent -St $St -Payload @{ Type = 'step-done'; Key = 'diagnose'; Ok = $true }
        Write-PnhAgentLog -Message 'Diagnosis done' -Data @{ flags = $flags; durationMs = (Get-PnhAgentMember -Object $diag -Name 'DurationMs') }

        $allActions = @(Get-PnhActions)

        # --- stop findings (findings.json "stop"/"blocks", actions.json "stopWhen") ------------------------------
        # A stop finding that has a read-only probe (an action whose stopWhen names it) is measured first:
        # positive -> stop everything and explain (isolation: loop rule 4), explicitly negative -> suspicion cleared.
        $stopFlags = @($flags | Where-Object { $findings.ContainsKey($_) -and ($findings[$_].Stop -or $findings[$_].Blocks.Count -gt 0) })
        $active = New-Object System.Collections.Generic.List[string]
        foreach ($f in $stopFlags) {
            if ($St.Stop) { break }
            $probe = @($allActions | Where-Object {
                    (Get-PnhAgentMember -Object $_ -Name 'changes') -ne $true -and
                    [string](Get-PnhAgentMember -Object (Get-PnhAgentMember -Object $_ -Name 'stopWhen') -Name 'finding') -eq $f }) | Select-Object -First 1
            if (-not $probe) { $active.Add($f); continue }
            $isIso = ($f -match '(?i)isolat')
            $probeId = [string](Get-PnhAgentMember -Object $probe -Name 'id')
            $title = Get-PnhAgentLocalized -Value (Get-PnhAgentMember -Object $probe -Name 'title') -Language $lang
            $stepText = if ($isIso) { Get-PnhAgentText 'agent.step.isolation' $lang } else { $title }
            Send-PnhAgentEvent -St $St -Payload @{ Type = 'step-start'; Key = $(if ($isIso) { 'isolation' } else { 'probe' }); Text = $stepText }
            Send-PnhAgentEvent -St $St -Payload @{ Type = 'action'; Id = $probeId; Title = $title }
            $r = $null
            try { $r = Invoke-PnhAction -Id $probeId -Parameters @{} -RunFolder $RunFolder -Confirm $St.Confirm }
            catch { $r = @{ Id = $probeId; Ok = $false; Verified = $false; Declined = $false; Output = ''; Error = $_.Exception.Message; RolledBack = $false; NeedsReboot = $false } }
            Send-PnhAgentEvent -St $St -Payload @{ Type = 'action-result'; Result = $r }
            Add-PnhAgentActionRecord -St $St -Result $r -Title $title -Changes $false -Kind 'action'
            $hit = Get-PnhAgentStopWhenValue -Action $probe -Result $r
            Write-PnhAgentLog -Message ('Stop finding measured: ' + $f) -Data @{ probe = $probeId; result = $hit }
            Send-PnhAgentEvent -St $St -Payload @{ Type = 'step-done'; Key = $(if ($isIso) { 'isolation' } else { 'probe' }); Ok = ($hit -ne $true) }
            if ($hit -eq $true) {
                $St.StopText = $findings[$f].Stop
                if ($isIso) { $St.Isolated = $true }
                Stop-PnhAgentLoop -St $St -Reason $(if ($isIso) { 'isolation' } else { 'stop-finding' })
            } elseif ($null -eq $hit) {
                $active.Add($f)   # could not measure: the finding stays in force
            }
        }
        $blocks = New-Object System.Collections.Generic.List[string]
        foreach ($f in $active) {
            $b = @($findings[$f].Blocks)
            if ($b.Count -eq 0) { $b = @('*') }
            foreach ($x in $b) { if (-not $blocks.Contains($x)) { $blocks.Add($x) } }
            if ($findings[$f].Stop -and -not $St.StopNotes.Contains($findings[$f].Stop)) { $St.StopNotes.Add($findings[$f].Stop) }
        }
        $St.ShellReadOnlyOnly = ($active.Count -gt 0)
        if ($active.Count -gt 0) { Write-PnhAgentLog -Message 'Stop findings in force' -Data @{ findings = $active.ToArray(); blocks = $blocks.ToArray() } }

        # --- the loop ------------------------------------------------------------------------------------------------
        if (-not $St.Stop) {
            $candIds = New-Object System.Collections.Generic.List[string]
            foreach ($f in $flags) {
                if (-not $findings.ContainsKey($f)) { continue }
                foreach ($id in $findings[$f].Candidates) { if (-not $candIds.Contains($id)) { $candIds.Add($id) } }
            }
            $offered = New-Object System.Collections.Generic.List[object]
            $seenIds = @{}
            foreach ($id in $candIds) {
                $a = @($allActions | Where-Object { [string](Get-PnhAgentMember -Object $_ -Name 'id') -eq $id }) | Select-Object -First 1
                if (-not $a -or $seenIds.ContainsKey($id)) { continue }
                $seenIds[$id] = $true
                if (Test-PnhAgentBlocked -Action $a -Blocks $blocks.ToArray()) { Write-PnhAgentLog -Message ('Action blocked by a stop finding: ' + $id); continue }
                $offered.Add($a)
            }
            # "other": only the candidates of the findings; "*" (all): the candidates already are the diagnostics.
            $diagnostics = @()
            if ($Category -ne 'other' -and $patterns -notcontains '*') {
                $diagnostics = if ($patterns.Count -gt 0) {
                    @($allActions | Where-Object { (Test-PnhAgentIdMatch -Id ([string](Get-PnhAgentMember -Object $_ -Name 'id')) -Patterns $patterns) })
                } else { @(Get-PnhActions -Category $Category) }
            }
            foreach ($a in $diagnostics) {
                $id = [string](Get-PnhAgentMember -Object $a -Name 'id')
                if ((Get-PnhAgentMember -Object $a -Name 'changes') -eq $true) { continue }
                if (-not $seenIds.ContainsKey($id)) { $offered.Add($a); $seenIds[$id] = $true }
            }
            if ($active.Count -gt 0 -and @($offered | Where-Object { (Get-PnhAgentMember -Object $_ -Name 'changes') -eq $true }).Count -eq 0) {
                # Every repair for this problem is blocked by a stop finding: explain and stop, no model needed.
                $St.StopText = ($St.StopNotes -join ' ')
                Stop-PnhAgentLoop -St $St -Reason 'stop-finding'
            }
        }
        if (-not $St.Stop) {
            # Small models get fewer tools (candidates of the most important findings first).
            $maxTools = 20
            if ($St.Tier -eq 1) { $maxTools = 12 } elseif ($St.Tier -eq 2) { $maxTools = 16 }
            $tools = New-PnhAgentToolRegistry -Actions $offered.ToArray() -FreeShell ($St.FreeShell -and $Category -ne 'other') -Language $lang -MaxActionTools $maxTools -NoAsk $St.ReadOnly
            $St.Registry = $tools.Registry
            $St.ToolDefs = $tools.Definitions
            $St.OfferedChanging = @($St.Registry.Values | Where-Object { $_.Kind -eq 'action' -and $_.Changes } | ForEach-Object { $_.Title })
            Write-PnhAgentLog -Message 'Tools offered' -Data @{ tools = @($St.Registry.Keys) }

            $St.Messages.Add([ordered]@{ role = 'system'; content = (Get-PnhAgentSystemPrompt -Language $lang) })
            $St.Messages.Add([ordered]@{ role = 'user'; content = (New-PnhAgentUserMessage -St $St -TopicTitle ('{0} ({1})' -f $topic, $Category) -UserText $UserText -Diagnosis $diag -Flags $flags -Findings $findings) })

            Send-PnhAgentEvent -St $St -Payload @{ Type = 'step-start'; Key = 'repair'; Text = (Get-PnhAgentText 'step.repair' $lang) }
            while (-not $St.Stop) {
                if ($St.Rounds -ge $MaxRounds) { Stop-PnhAgentLoop -St $St -Reason $(if ($St.CheckPassed) { 'solved' } else { 'max-rounds' }); break }
                $St.Rounds++
                Send-PnhAgentEvent -St $St -Payload @{ Type = 'thinking'; Round = $St.Rounds }
                $resp = $null
                try { $resp = Invoke-PnhAgentChatRound -St $St }
                catch {
                    Add-PnhAgentChatLog -St $St -Entry ([ordered]@{ type = 'error'; round = $St.Rounds; error = $_.Exception.Message })
                    Register-PnhAgentFormatProblem -St $St -Reason ('chat failed: ' + $_.Exception.Message)
                    continue
                }
                $text = ConvertTo-PnhAgentPlainText -Text $resp.Content -MaxLength 600
                $calls = @($resp.ToolCalls)
                $salvaged = $false
                if ($calls.Count -eq 0) {
                    $calls = @(Get-PnhAgentSalvagedCalls -Content $resp.Content -Registry $St.Registry)
                    if ($calls.Count -eq 0 -and $resp.Thinking) { $calls = @(Get-PnhAgentSalvagedCalls -Content (($resp.Thinking -split '</?think>') -join "`n") -Registry $St.Registry | Select-Object -First 1) }
                    $salvaged = ($calls.Count -gt 0)
                    if ($salvaged) { Write-PnhAgentLog -Message 'Tool call recovered from text' -Level Warn -Data @{ round = $St.Rounds } }
                }
                if ($calls.Count -eq 0) {
                    if ($St.CheckPassed) {
                        if ($text) { $St.ModelWords = $text }
                        Stop-PnhAgentLoop -St $St -Reason 'solved'
                        break
                    }
                    if ($text) {
                        Send-PnhAgentEvent -St $St -Payload @{ Type = 'message'; Text = $text; Source = 'model' }
                        $St.Messages.Add([ordered]@{ role = 'assistant'; content = $text })
                        $St.ModelWords = $text
                    }
                    Register-PnhAgentFormatProblem -St $St -Reason $(if ($text) { 'text without tool call' } else { 'empty answer' })
                    continue
                }
                $St.CorrectionSent = $false
                if ($text -and -not $salvaged) { Send-PnhAgentEvent -St $St -Payload @{ Type = 'message'; Text = $text; Source = 'model' } }

                $calls = @($calls | Select-Object -First 3)
                $tc = @()
                for ($i = 0; $i -lt $calls.Count; $i++) {
                    $argsObj = ConvertTo-PnhAgentHashtable -InputObject $calls[$i].Arguments
                    if ($null -eq $argsObj) { $argsObj = @{} }
                    $one = [ordered]@{ function = [ordered]@{ index = $i; name = [string]$calls[$i].Name; arguments = $argsObj } }
                    if ($calls[$i].Id -and -not $salvaged) { $one.Insert(0, 'id', [string]$calls[$i].Id) }
                    $tc += , $one
                }
                $St.Messages.Add([ordered]@{ role = 'assistant'; content = $(if ($salvaged) { '' } else { $text }); tool_calls = $tc })

                $changeDone = $false
                foreach ($call in $calls) {
                    if ($St.Stop) {
                        Add-PnhAgentToolMessage -St $St -Call $call -Name ([string]$call.Name) -Content (Get-PnhAgentText 'model.skipped.solved' $lang)
                        continue
                    }
                    if (Invoke-PnhAgentToolCall -St $St -Call $call -ChangeDoneThisRound $changeDone) { $changeDone = $true }
                }
            }
            if ($St.Stop -and -not $St.StoppedReason) { $St.StoppedReason = 'finished' }
        }

        # --- final verdict: decided by the script, never by the model ------------------------------------------------
        if ($St.CheckId -and -not $St.CheckFresh -and $St.StoppedReason -notin @('isolation', 'stop-finding')) {
            [void](Invoke-PnhAgentCheck -St $St)
        }
        $finalPassed = ($St.LastCheck -and $St.LastCheck.Passed)
        $initialFailed = -not ($St.InitialCheck -and $St.InitialCheck.Passed)
        $solved = [bool]($finalPassed -and ($initialFailed -or $St.AnyChangeVerified) -and -not $St.Isolated)
        if ($solved -and $St.StoppedReason -in @('finished')) { $St.StoppedReason = 'solved' }
        if (-not $solved -and $St.StoppedReason -eq 'solved') { $St.StoppedReason = 'finished' }
        Send-PnhAgentEvent -St $St -Payload @{ Type = 'step-done'; Key = 'repair'; Ok = $solved }
    } catch {
        $St.ErrorText = $_.Exception.Message
        $St.StoppedReason = 'error'
        $solved = $false
        Write-PnhAgentLog -Message ('Agent error: ' + $St.ErrorText) -Level Error -Data @{ at = [string]$_.InvocationInfo.PositionMessage }
        Send-PnhAgentEvent -St $St -Payload @{ Type = 'error'; Text = $St.ErrorText }
    }

    $summary = New-PnhAgentSummary -St $St -Solved $solved
    Write-PnhAgentSummaryFile -St $St -Summary $summary -TopicTitle $topic -UserText $UserText
    $seconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    Write-PnhAgentLog -Message 'Agent done' -Data @{ solved = $solved; stoppedReason = $St.StoppedReason; rounds = $St.Rounds; actions = $St.Actions.Count; seconds = $seconds }
    Send-PnhAgentEvent -St $St -Payload @{ Type = 'done'; Solved = $solved; Summary = $summary }
    return [pscustomobject]@{
        Solved        = $solved
        Summary       = $summary
        Rounds        = $St.Rounds
        Actions       = $St.Actions.ToArray()
        StoppedReason = $St.StoppedReason
        Check         = $St.LastCheck
        Model         = $St.Model
        Category      = $Category
        Seconds       = $seconds
        Error         = $St.ErrorText
        ReadOnly      = [bool]$ReadOnly
        WouldHelp     = $St.WouldHelp.ToArray()
    }
}
