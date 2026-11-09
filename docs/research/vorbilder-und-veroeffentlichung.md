Interne Recherche vom 09.11.2026, unverändert bis auf Anonymisierung; die Entscheide stehen in docs/ARCHITECTURE.md.

# Vorbilder, Lizenzen, Name, README und Veröffentlichung

Stand: 09.11.2026. Grundlage: GitHub-REST-API (Repo-Metadaten, Issues), GitHub-Suche,
Websuche, Primärquellen (Lizenztexte, Microsoft- und GitHub-Dokumentation). Alle Abrufe
am 09.11.2026. Kein Rechtsrat: Die Lizenz- und Haftungsabschnitte ordnen ein, ersetzen
aber keine Fachperson, sobald SSDs verkauft oder in grösserer Zahl verteilt werden.

Arbeitsname im Text: **das Projekt** (Namensvorschläge in Abschnitt 3).

## Empfehlungen auf einen Blick

| Frage | Empfehlung |
|---|---|
| Gibt es das Konzept schon? | Nein, nicht in dieser Kombination (Windows-nativ von externer SSD, Modellgrösse nach Hardware, selbständige Reparatur mit geprüftem Katalog, Wiederherstellungspunkt, Protokoll, für Laien). Nächste Verwandte: Lares-Windows (autonom, lokal, Rücknahme, aber nur Härtung), RigWright (Reparatur mit Ollama und Rücknahme, aber KI schlägt nur vor), Kintsugi USB (Linux-Rettungsstick für Admins). |
| Wichtigste Lehre aus fremden Issues | Fehlschläge nie verschlucken: Downloads mit Grösse und SHA-256 prüfen, Laufwerksbuchstaben und Arbeitsverzeichnis nie annehmen, Ollama-Version festnageln, Hardware vor der Modellwahl messen, Fehlermeldungen für Laien verständlich und kopierbar machen. |
| Lizenz des Repos | **Apache-2.0** (Patentklausel, Markenklausel, NOTICE-Mechanik, passt zu Codex, Qwen3, Gemma 4). MIT wäre auch vertretbar. Beiträge per DCO (`Signed-off-by`). |
| Fremdlizenzen | Repo enthält nichts Fremdes, Erbauer lädt von den Quellen. Standard-Modellkatalog nur Apache-2.0/MIT. Erbauer legt `LICENSES/` und `THIRD-PARTY-NOTICES.txt` automatisch auf die SSD. Keine Sysinternals auf weitergegebenen SSDs. |
| Weitergabe befüllter SSD | Erlaubt für MIT/Apache-Komponenten mit Lizenztexten und NOTICE-Dateien; Llama, Gemma ≤ 3 und Qwen-Research nur mit Zusatzpflichten oder gar nicht. Protokolle vor Weitergabe löschen. Verkauf macht den Verkäufer zum Hersteller (EU-Produkthaftung ab 09.12.2026). |
| Name, Top 3 | **Plug'n'Heal**, **DocClick**, **HealDrive** (Begründung und Kollisionsprüfung in Abschnitt 3). Vor der Wahl Markenregister (Swissreg, TMview, WIPO) prüfen. |
| README | Englisches `README.md` als Hauptseite, `README.de.md` gleichwertig für den Nutzerteil, Entwicklerdoku getrennt unter `docs/`. Oben ein sichtbarer Warnkasten, eine Tabelle "Was schiefgehen kann", Liste "Was es nie tut". |
| Vertrauen | GitHub Releases mit `SHA256SUMS`, Build-Attestierung und unveränderlichen Releases; Erbauer prüft alle Downloads gegen festgenagelte Hashes. Signatur: SignPath Foundation (gratis) beantragen, sonst Certum Open Source (ca. 49 bis 69 EUR/Jahr, der Maintainer entscheidet). Azure Artifact Signing ist für eine Einzelperson in der Schweiz nicht verfügbar. |
| CI | GitHub Actions `windows-latest` (Windows Server 2025, Pester 5.9.0, PSScriptAnalyzer 1.25.0 vorinstalliert), Matrix `shell: powershell` (5.1, wie auf den Ziel-PCs) und `shell: pwsh`. Für öffentliche Repos kostenlos. Wiederherstellungspunkte lassen sich dort nicht testen (Server-OS), also mocken und auf echten Windows-10/11-VMs prüfen. |

---

## 1 Vorbilder

### 1.1 Übersicht

Sterne und letzter Push laut GitHub-API am 09.11.2026.

| Projekt | Was es kann | Plattform | Lizenz | Aktivität |
|---|---|---|---|---|
| [Kintsugi USB](https://github.com/jmagly/kintsugi-usb) | Ventoy-Multiboot mit Xubuntu 24.04, Persistenz, Rettungs-ISOs, Ollama + llama.cpp, acht vorinstallierte Agenten-CLIs, Runbooks pro Host; Bau-Assistent `kintsugi-build` | bootet Linux, Bau unter Linux | MIT (README; GitHub zeigt NOASSERTION), Drittlizenzen in `manifest/THIRD-PARTY-LICENSES.md` | 18 Sterne, erstellt 26.05.2026, letzter Push 31.07.2026; Issues auf eigener Gitea-Instanz (von hier nicht auflösbar) |
| [claude-code-live-usb](https://github.com/fidpa/claude-code-live-usb) | KI-CLI auf einem Ubuntu-Live-Stick als "Lead Operator" für Bare-Metal-Wartung (LVM, MD-RAID); jede destruktive Aktion braucht ein "JA" | bootet Linux | MIT | 1 Stern, letzter Push 29.08.2026, keine Issues |
| [BMASS](https://github.com/balaji-md/bmass) | "Bootable Model As System": bootet direkt in eine KI-Shell; Modell gibt `<shell>`-Aktionen aus, Ausgabe fliesst zurück | bootet Linux, llama.cpp, Qwen | MIT | 110 Sterne, letzter Push 03.08.2026, experimentell, nur auf Referenzumgebung getestet, Diskussionen statt Issues |
| [Portable-AI-USB](https://github.com/techjarves/Portable-AI-USB) | Ollama + AnythingLLM vom USB-Stick, Chat | Windows, macOS | MIT | 2278 Sterne, 605 Forks, 54 offene Issues, letzter Push 04.07.2026 |
| [USB-Uncensored-LLM](https://github.com/techjarves/USB-Uncensored-LLM) | eigene HTML-Chatoberfläche + Python-Server + Ollama, Modellauswahl | Windows, macOS, Linux | **keine Lizenzdatei** | 2094 Sterne, 37 offene Issues, letzter Push 04.07.2026 |
| [ClaudeCode-Portable](https://github.com/techjarves/ClaudeCode-Portable), [Hermes-USB-Portable](https://github.com/techjarves/Hermes-USB-Portable), [OpenClaw-USB-Portable](https://github.com/techjarves/OpenClaw-USB-Portable) | Agenten-CLIs portabel vom Stick | Windows, macOS, Linux | MIT / keine / MIT | 1620 / 572 / 142 Sterne; letzte Pushes 09/2026, 06/2026, 05/2026 |
| [llamafile](https://github.com/mozilla-ai/llamafile) | Modell + Laufzeit in einer ausführbaren Datei | Windows, macOS, Linux | Apache-2.0 (LICENSE-Datei) | 26 595 Sterne, 214 offene Issues, aktiv (Push 09.11.2026) |
| [Jan](https://github.com/janhq/jan) | Desktop-Chat offline, seit 2026 portable Windows-Variante (PR #7350, gemergt 10.01.2026; später PR #9302 "restore Windows portable ZIP distribution") | Windows, macOS, Linux | Apache-2.0 (LICENSE-Datei) | 45 636 Sterne, 570 offene Issues, aktiv |
| LM Studio | Desktop-Chat, keine offizielle portable Variante; nur Bastellösungen zum Verschieben des Modellordners | Windows, macOS, Linux | proprietär | als Grundlage für ein freies Projekt ungeeignet |
| [KoboldCpp](https://github.com/LostRuins/koboldcpp) | eine EXE ohne Installation, CPU/GPU | Windows, macOS, Linux | AGPL-3.0 | aktiv |
| [Ollama](https://github.com/ollama/ollama) | Laufzeit, standalone-ZIP für Windows | Windows 10 22H2+ | MIT | 186 443 Sterne, aktiv |

Nächste Verwandte im Windows-Reparaturbereich (aus GitHub-Suche, nicht vorgegeben):

| Projekt | Was es kann | Lizenz, Aktivität | Abstand zu unserem Konzept |
|---|---|---|---|
| [Lares-Windows](https://github.com/at0m-b0mb/Lares-Windows) | Autonomer Härtungsagent mit eingebettetem Modell (Qwen2.5-Coder, Stufe 0.5B bis 7B nach gemessenem RAM und Kernen). Modell wählt aus Katalog (Probe, Fix, Rollback), prüft, nimmt zurück. Separates "Freehand"-Programm, in dem das Modell PowerShell schreibt | MIT, 3 Sterne, Push 03.10.2026 | Am nächsten im Agentendesign. Aber Sicherheitshärtung statt Reparatur, EXE statt SSD, kein Ollama, nicht für Laien formuliert |
| [RigWright](https://github.com/Subzero121800/RigWright) | Windows 10/11 einrichten, tunen, reparieren; Journal mit exakter Rücknahme; Wiederherstellungspunkt vor jedem Paket; KI über Ollama oder Claude Code | MIT, 1 Stern, Push 01.11.2026 | KI schlägt nur vor, Mensch bestätigt; kein Modell mitgeliefert. Gute Laien-Downloadanleitung |
| [PC-AI](https://github.com/David-Martel/PC-AI) | PowerShell-Framework, Diagnose mit lokalem LLM, empfiehlt Optimierungen | MIT, 4 Sterne, Push 06.11.2026 | Für Fortgeschrittene, PowerShell 7 nötig |
| [pc-agent](https://github.com/usausa/pc-agent) | .NET-10-CLI (japanisch): Hardware/SMART/WLAN/Ereignisprotokoll, regelbasierte Diagnose, LLM-Chat, Reparatur nur nach Freigabe | MIT, 0 Sterne, Push 30.10.2026 | Entwicklerwerkzeug |
| [DESKTOP-DOCTOR](https://github.com/nimai1236/DESKTOP-DOCTOR) | Offline-Diagnose mit Ollama, erklärt Befunde, Excel-Bericht, Aufräumknopf | keine Lizenz, 0 Sterne | Python muss installiert sein |
| [Field Tech Copilot](https://github.com/ben4mn/field-tech-copilot) | Offline-Diagnose-Notizbuch für Techniker, gibt höchstens einen abgesicherten nächsten Schritt aus | NOASSERTION, 0 Sterne | ausdrücklich **keine** autonome Reparatur |
| [Coclico](https://github.com/Coclico-cy/Coclico) | Windows-Pflegewerkzeug mit lokaler KI, EN/FR-README, getrennte Entwickler-README | MIT, Push 09.11.2026 | Werkzeugkasten mit Bestätigung pro Aktion |
| [heinzel](https://github.com/wintermeyer/heinzel) | Regelwerk, das KI-Assistenten zu vorsichtigen Sysadmins macht (Linux, BSD, macOS) | 104 Sterne, Push 07.11.2026 | Linux; relevant als Muster für Verhaltensregeln und als Namenskollision |
| Microsoft "Agent in Settings" (Modell Mu) | ändert Einstellungen per natürlicher Sprache, mit Erlaubnis | nur Copilot+-PCs, Windows 11 24H2 | nur Einstellungen, keine Fehlersuche |

### 1.2 Lehren aus den Issues

Gelesen: alle Issues von Portable-AI-USB (72), USB-Uncensored-LLM (58), ClaudeCode-Portable
(49), Hermes-USB-Portable (26), OpenClaw-USB-Portable (5), usbunny (7), dazu gezielte
Suchen in Ollama, llamafile und Jan. Kintsugi-Issues liegen auf
`git.integrolabs.net`, das von hier aus nicht auflösbar war.

| Muster | Beleg | Was das Projekt daraus macht |
|---|---|---|
| **Erfolg gemeldet, obwohl es fehlschlug** | Portable-AI-USB #1: `curl: (35) ... CRYPT_E_NO_REVOCATION_CHECK`, danach "Model Download Complete!". USB-Uncensored-LLM #42: `$null = & ollama create ...` verschluckte Fehler, "imported successfully!" trotzdem. #48: leere ZIP, Entpacken scheitert | Jeder Schritt prüft sein Ergebnis (Dateigrösse, SHA-256, Exitcode, Health-Check per HTTP statt `sleep`, vgl. Portable-AI-USB #61). Fehler brechen ab und erklären sich |
| **TLS-Prüfung abgeschaltet statt Ursache benannt** | Portable-AI-USB #60: `curl.exe --ssl-no-revoke` auf allen Downloads; Hermes #4 "FIXED" mit derselben Abschaltung | Revocation-Fehler (Proxy, Firmen-TLS-Inspektion) klar melden, nie still abschalten; Integrität kommt zusätzlich aus festgenagelten Hashes |
| **Werkzeuge fehlen oder sind kaputt** | Portable-AI-USB #50: `curl.exe` nicht gefunden (ältere Windows 10); USB-Uncensored-LLM #49: `ConvertFrom-Json` nicht erkannt; OpenClaw #3: Windows 8.1 | Erbauer und Agent setzen nur auf das, was sie selbst mitbringen oder was zwingend da ist. Wichtiger als bei Chat-Projekten: **der Ziel-PC ist kaputt**, seine Werkzeuge können es auch sein. Systemprogramme nur mit absolutem Pfad unter `%SystemRoot%` aufrufen (vgl. Lares-Audit, Abschnitt 1.4) |
| **Laufzeit-Abhängigkeit fehlt** | Ollama #11527: Standalone-ZIP ab 0.9.6 bricht mit "exit status 2" ab, solange die VC++-Laufzeit (`vc_redist.x64.exe`) fehlt; DLLs neben `ollama.exe` helfen nicht | Agent prüft VC++-Laufzeit vor dem Start und installiert sie (er hat Adminrechte), Erbauer legt das Installationsprogramm von Microsoft auf die SSD. Mindestversion Windows 10 22H2 laut Ollama-Doku |
| **Pfade** | USB-Uncensored-LLM #24 (`E:\ollama\ollama.exe` nicht gefunden), #4/#25 (`..\Shared\chat_server.py` relativ zum falschen Arbeitsverzeichnis); Ollama #17591 (NTFS-Mount-Point statt Laufwerksbuchstabe bricht `ollama create`); portable-agent-README: 260-Zeichen-Grenze | Alles relativ zu `%~dp0` bzw. `$PSScriptRoot` auflösen, Laufwerksbuchstaben nie annehmen, kurze Ordnernamen, Pfadlänge im Selbsttest prüfen |
| **Dateisystem** | Hermes #8, #12: exFAT kann keine Symlinks, Python/venv-Entpacken scheitert; #14: "Can't restore time" beim Entpacken auf USB4-SSD; Portable-AI-USB #27: Entpacken bricht auf exFAT-Stick ab | Erbauer formatiert nicht selbst, prüft aber Dateisystem und warnt; keine Symlinks im Layout; Entpacken erst lokal, dann kopieren und Hashes prüfen |
| **Langsame oder billige Sticks** | Portable-AI-USB #40: 17 bis 20 MB/s, nach 2 Stunden kaum Fortschritt; #66: Geschwindigkeitstest mit falscher Logik; Ratgeber: billige Sticks verlieren bei grossen Dateien Daten | Externe **SSD** zur Pflicht machen, Schreib- und Lesetest im Erbauer, Hashes nach dem Kopieren erneut prüfen |
| **Modell zu gross für die Hardware** | Portable-AI-USB #46: 12B-Modell bricht mit "exit code 2" ab (24 GB RAM); USB-Uncensored-LLM #1, #20, #27: CPU-only extrem langsam, GPU ungenutzt; #8, #19: AMD-Unterstützung | Hardware messen, Modellstufe mit Reserve wählen, beim Laden scheitern dürfen und eine Stufe kleiner nehmen. Kontextgrösse ausdrücklich setzen (Agenten brauchen mehr als 4K; ein Ratgeber berichtet, dass das Modell sonst seine Werkzeuge vergisst) |
| **VRAM falsch gemessen** | `Win32_VideoController.AdapterRAM` ist `uint32` und deckelt bei rund 4 GB; Lösung über Registry `HardwareInformation.qwMemorySize` | VRAM über Registry bzw. `nvidia-smi` messen, nie über `AdapterRAM` allein |
| **Treiber** | Ollama-Doku: NVIDIA-Treiber ab 551.61; AMD braucht ROCm-Paket oder Vulkan; Vulkan ist Standard-Rückfall | Treiberversion messen, bei zu altem Treiber CPU/Vulkan nehmen und das im Protokoll begründen, statt still langsam zu sein |
| **Aufräumen und Auswerfen** | Portable-AI-USB #64: Server läuft nach "you may eject" weiter; Ratgeber: Port 11434 doppelt belegt, wenn Ollama auch installiert ist | Eigener Port, eigene Prozessverwaltung, beim Beenden alle Kindprozesse prüfen und erst dann "SSD kann entfernt werden" anzeigen |
| **Updates zerstören Zustand** | Ollama #17661: Modelle nach Update auf 0.32.7 weg | Ollama-Version auf der SSD festnageln, Selbstaktualisierung aus, `OLLAMA_MODELS` pro Prozess setzen, Benutzerprofil des Ziel-PCs nicht anfassen (vgl. Portable-AI-USB #54: Dateien landeten trotzdem in `AppData`) |
| **Vertrauen und Pflege** | Portable-AI-USB #3: "It might be virus, can you upload the source?"; #52: Autor startet neue Projekte und lässt alte liegen; USB-Uncensored-LLM #17: "Is this open source? What are the licensing terms?" (keine Lizenzdatei) | LICENSE ab dem ersten Commit, Pflegestatus im README, SECURITY.md, CHANGELOG, Antwortzeiten ehrlich angeben |
| **Laien melden mit Bildschirmfotos** | sehr viele Issues bestehen nur aus Screenshots (z. B. Portable-AI-USB #29, #36, #41, #73) | Knopf "Diagnosebericht kopieren" bzw. Datei auf der SSD, Issue-Vorlage, die genau diese Datei verlangt |
| **Erwartung an das Modell** | Portable-AI-USB #35: "uncensored" Modell verweigert; #7: "it does not work" (Erwartung zu hoch) | KI-Verhalten nicht versprechen; Reparatur aus deterministischem Katalog, KI wählt und erklärt |

### 1.3 Virenscanner, SmartScreen, Smart App Control

| Befund | Beleg | Folge für das Projekt |
|---|---|---|
| Neue Laufzeiten werden heuristisch als Trojaner erkannt | Ollama #2519 "Windows defender alert & false-positive detection" (62 Kommentare, 2024), #3168, #4409 (`Wacatac.B!ml`/`.H!ml`), #2855 (Kaspersky); llamafile #28, #37, #364 (Defender), #67 (SMADAV); Jan #3974 (Avast auf der Webseite) | FAQ-Eintrag von Anfang an; Meldeweg für Fehlalarme dokumentieren (Microsoft Security Intelligence Portal) |
| Gepackte EXE-Wrapper sind Fehlalarm-Magneten | KoboldCpp liefert eine PyInstaller-EXE; llamafile ist ein APE-Polyglott und muss unter Windows unter 4 GB bleiben | Kein eigener EXE-Wrapper (kein PS2EXE, kein PyInstaller). Start über `.cmd` + lesbare `.ps1` |
| Skriptinhalt wird zur Laufzeit gescannt (AMSI) | Muster, die RigWright ausdrücklich verweigert: `-EncodedCommand`, `iex`, `[scriptblock]::Create`, `Add-Type`, Download-und-Ausführen, Löschen von Schattenkopien | Diese Muster weder im eigenen Code noch in KI-generierten Befehlen zulassen. Schattenkopien sind zugleich die Wiederherstellungspunkte, also doppelt tabu |
| Smart App Control blockiert unsignierte EXE/DLL immer, Skripte mit Mark of the Web ohne Übersteuerung | Microsoft Learn (SAC, Stand 30.09.2026); Eric Lawrence, 28.04.2026: `.ps1`, `.bat`, `.cmd` mit MotW werden blockiert, der Dialog bietet keine Übersteuerung | Erbauer entfernt MotW (`Unblock-File`) von allem, was auf die SSD kommt. Nur signierte Binärdateien auf die SSD: Ollama signiert laut Build-Skript alle `.exe` und `.dll` mit dem Zertifikat von Ollama Inc. Bei llama.cpp-Release-Binärdateien ist die Signatur nicht geprüft |
| ASR-Regel "Block untrusted and unsigned processes that run from USB" | Microsoft-ASR-Referenz, GUID `b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4`; in CIS- und DISA-STIG-Vorgaben auf "Block" | Auf verwalteten Firmen-PCs scheitern unsignierte EXE von der SSD. Im README: "nicht für Firmencomputer" |

### 1.4 Designlehren der nächsten Verwandten

| Quelle | Lehre |
|---|---|
| Lares | "The model chooses from a catalogue. It never writes the code that runs." Katalogeinträge brauchen Erkennungsprobe, Fix und Rollback; jeder Parameter braucht ein Regex, sonst ist er eine Einschleusstelle. Ohne Modell läuft ein deterministischer Planer. Modellstufe nach gemessenem RAM und Kernen. |
| Lares, Sicherheitsaudit im README | Fünf Fehler, die uns genauso treffen würden: (1) `powershell.exe` ohne absoluten Pfad suchen, weil das aktuelle Verzeichnis zuerst durchsucht wird; (2) Dienst- und Produktnamen auf dem PC sind Angreifertext, also Prompt-Injection; (3) Steuerzeichen in diesen Namen fälschen die Terminalausgabe; (4) ein Rücknahme-Journal im Benutzerprofil wird zu erhöhtem Code, wenn es später als Admin ausgeführt wird; (5) eine vom Modell geschriebene Rücknahme darf nicht dieselbe Ausnahme bekommen wie eine geprüfte. |
| Lares, "Status, stated plainly" | "8 of the 30 controls have applied and verified against a live Windows 11 ARM64 VM. The other 22 have never executed on real hardware." Vorbild für ehrliche Statusangaben. |
| RigWright | Wiederherstellungspunkt vor jedem Paket, die 24-Stunden-Sperre nur für diesen Aufruf aufheben; Liste geschützter Dienste (Windows Update, Defender, BITS u. a.), die nie deaktiviert werden, auch wenn die KI es verlangt; unbekannte Katalog-IDs werden verworfen. |
| claude-code-live-usb | Jede destruktive Aktion braucht ein ausdrückliches "JA". Bei uns: Stufen festlegen, was autonom laufen darf und was eine Zustimmung braucht. |
| Field Tech Copilot | Höchstens ein abgesicherter nächster Schritt, "fails closed". |
| Kintsugi | Keine Modellgewichte im öffentlichen Abbild (ADR-005), Prüfsumme vor dem Flashen, Geheimnis-Scan vor dem Erstellen eines Abbilds. |

Windows-Eigenheit, die nur Microsoft-Doku belegt: `Checkpoint-Computer` läuft nur auf
Client-Windows (nicht auf Server) und legt höchstens einen Punkt pro 24 Stunden an
("A new system restore point cannot be created because one has already been created
within the past 24 hours"). Ist der Computerschutz aus, gibt es gar keinen Punkt. Das
Projekt muss diese drei Fälle unterscheiden und im Zweifel nur diagnostizieren.

### 1.5 Gibt es genau unser Konzept schon?

Nein, Stand 09.11.2026, soweit GitHub-Suche und Websuche reichen. Die Einzelteile gibt es:

| Merkmal | Wer hat es |
|---|---|
| Offline-KI von USB/SSD unter Windows | techjarves-Projekte, portable-agent, Jan portable, KoboldCpp |
| Modellgrösse nach Hardware | Lares (0.5B bis 7B nach RAM und Kernen) |
| Selbständige Änderungen mit Prüfung und Rücknahme | Lares (Härtung) |
| Windows-Reparatur mit Wiederherstellungspunkt und Journal | RigWright (aber KI nur beratend) |
| Rettungsstick mit KI und Runbooks | Kintsugi (Linux, für Admins) |
| Für völlige Laien, Doppelklick, Protokoll | niemand in dieser Kombination |

Die Lücke ist real, aber die Nachbarn zeigen auch, warum: Wer autonom ändern lässt, braucht
einen geprüften Katalog, eine Rücknahme pro Schritt und eine ehrliche Statusseite. Alle
ernsthaften Projekte im Feld sind entweder autonom **oder** für Laien, keines beides.

---

## 2 Lizenzen

### 2.1 Was gilt, wenn das Repo nichts Fremdes enthält

- Wer nur eigene Skripte, Doku und ein Manifest mit URLs und Hashes veröffentlicht,
  verbreitet keine fremden Werke. Die Pflichten aus MIT, Apache-2.0 usw. ("include the
  copyright notice", "give a copy of this License") entstehen erst beim Weitergeben.
- Der Erbauer lädt auf dem Rechner des Nutzers direkt von der Quelle. Der Nutzer wird
  dadurch selbst Lizenznehmer der Komponente. Für Modelle mit Nutzungsbedingungen (Llama,
  Gemma bis Version 3) heisst das: Er stimmt durch Nutzung zu, ohne sie gesehen zu haben.
  Deshalb soll der Erbauer Lizenzname und Link pro Komponente anzeigen und bei nicht
  freizügigen Lizenzen eine ausdrückliche Zustimmung verlangen.
- Fallstricke, die das Repo doch zum Verbreiter machen: fremde Binärdateien als
  Release-Assets, GGUF-Dateien in Git LFS, kopierte Modelfiles oder Chat-Templates aus
  Modellrepos, ein eigener Spiegel- oder Cache-Server. Alles vermeiden.
- Markennamen (Ollama, Codex, Qwen, Gemma, Windows) im Text sind beschreibend zulässig,
  Logos nicht. Satz im README: "Not affiliated with or endorsed by Microsoft, Ollama,
  OpenAI, Alibaba, Google or Meta."

### 2.2 Komponenten und ihre Bedingungen

| Komponente | Lizenz (geprüft) | Bedingungen bei Weitergabe |
|---|---|---|
| Ollama | MIT (LICENSE im Repo) | Copyright- und Lizenztext beilegen |
| Ollama-Windows-ZIP | enthält NVIDIA-CUDA-Laufzeit (`cudart`, `cublas`, `cublasLt`) | CUDA-EULA: nur als Teil einer Anwendung mit wesentlicher Zusatzfunktion, nicht einzeln, nicht unter eine Open-Source-Lizenz stellen |
| VC++-Laufzeit (`vc_redist.x64.exe`) | Microsoft-Lizenz | Für die eigene SSD unproblematisch; bei Weitergabe Graubereich, Erbauer lädt von Microsoft |
| Codex CLI | Apache-2.0, NOTICE: "OpenAI Codex, Copyright 2025 OpenAI" plus Ratatui (MIT) | Lizenz beilegen, NOTICE unverändert mitgeben |
| llama.cpp | MIT | Copyright- und Lizenztext |
| llamafile | Apache-2.0 | Lizenz, NOTICE |
| Qwen3, Qwen3.5 (z. B. Qwen3-4B, Qwen3-8B, Qwen3.5-4B, Qwen3.5-9B) | Apache-2.0 (Hugging-Face-Karte) | Lizenz beilegen |
| **Qwen2.5-3B-Instruct** | **Qwen Research License**, "FOR NON-COMMERCIAL PURPOSES ONLY" | Lizenz beilegen, Notice "Qwen is licensed under the Qwen RESEARCH LICENSE AGREEMENT ...", kein kommerzieller Einsatz. Falle: Qwen2.5-7B ist dagegen Apache-2.0 |
| Gemma 4 (z. B. gemma-4-E4B-it) | Apache-2.0 (Hugging-Face-Karte; die Gemma Terms nennen Gemma 4 ausdrücklich nicht) | Lizenz beilegen |
| Gemma 3 und älter | Gemma Terms of Use (Stand 01.04.2026) | Nutzungsbeschränkungen aus §3.2 durchsetzbar weitergeben, Kopie der Bedingungen, geänderte Dateien kennzeichnen, Notice-Datei mit "Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms" |
| Llama 3.1, 3.2 | Llama Community License | Kopie der Lizenz, "Built with Llama" sichtbar anzeigen, Notice "Llama 3.2 is licensed under the Llama 3.2 Community License, Copyright © Meta Platforms, Inc. All Rights Reserved.", Acceptable Use Policy; 700-Mio.-Nutzer-Klausel irrelevant |
| Phi-4-mini | MIT | Lizenztext |
| Ministral 3 8B, Granite 4.0 micro, gpt-oss-20b | Apache-2.0 | Lizenz beilegen |
| Sysinternals | Sysinternals-Lizenz: "You may not ... publish the software for others to copy ... transfer the software or this agreement to any third party" | **Nicht weitergeben.** Für eine eigene SSD erlaubt, auf einer weitergegebenen SSD nicht. Besser: Werkzeugkasten auf Windows-Bordmittel bauen (`sfc`, `DISM`, `chkdsk`, `pnputil`, `netsh`, `Get-WinEvent`, `wevtutil`) |

Empfehlung: Der **Standard-Modellkatalog enthält nur Apache-2.0 und MIT**. Llama, Gemma ≤ 3
und alles mit Research-Lizenz nur als Option mit ausdrücklicher Zustimmung, nie im
Weitergabe-Modus.

### 2.3 MIT oder Apache-2.0 für das Repo

| Kriterium | MIT | Apache-2.0 |
|---|---|---|
| Länge, Verständlichkeit | sehr kurz | länger |
| Patentlizenz und Patent-Vergeltung | nein | ja (§3) |
| Beitragsregel ohne CLA | nein | ja (§5: Beiträge gelten unter derselben Lizenz) |
| Markenschutz für den Projektnamen | nein | §6: keine Rechte am Namen. Wichtig bei einem Werkzeug, das mit Adminrechten Befehle ausführt: Forks dürfen nicht unter unserem Namen auftreten |
| Kennzeichnung geänderter Dateien | nein | §4(b): ja. Für ein Werkzeug mit Adminrechten eher ein Vorteil |
| NOTICE-Datei für Danksagungen | nein | ja |
| Passt zu | Ollama, llama.cpp | Codex, llamafile, Jan, Qwen3, Gemma 4 |
| SignPath-Voraussetzung (OSI-Lizenz) | erfüllt | erfüllt |

**Empfehlung: Apache-2.0**, dazu `NOTICE` (Projektname, Copyright, Hinweis "not
affiliated"), SPDX-Kopfzeile in jeder Skriptdatei (`# SPDX-License-Identifier: Apache-2.0`)
und DCO statt CLA. Doku und Katalog fallen unter dieselbe Lizenz; eine zweite Lizenz für
Texte (CC BY) bringt hier mehr Verwirrung als Nutzen.

### 2.4 THIRD-PARTY-NOTICES

Im Repo technisch nicht Pflicht, solange nichts Fremdes darin liegt, aber nützlich und
vertrauensbildend. Vorschlag:

- **Eine Quelle der Wahrheit:** `manifest/components.json` mit Name, Version, URL,
  SHA-256, SPDX-Lizenz, Lizenz-URL, Zusatzpflichten (z. B. `"requires": ["built-with-llama"]`),
  `redistributable: true|false`.
- `THIRD-PARTY-NOTICES.md` im Repo wird aus dem Manifest erzeugt und in der CI auf
  Gleichstand geprüft. Inhalt: Tabelle "Komponenten, die der Erbauer lädt", nicht
  "Komponenten in diesem Repo".
- Der Erbauer schreibt auf die SSD: `LICENSES/<komponente>/` mit den mitgelieferten
  Lizenz- und NOTICE-Dateien der heruntergeladenen Pakete, `THIRD-PARTY-NOTICES.txt` und
  bei Bedarf `NOTICE-Gemma.txt`, `NOTICE-Llama.txt`. Damit ist jede SSD von Anfang an
  weitergabefähig, soweit die Komponenten es erlauben.
- Sobald doch fremder Code ins Repo kommt (z. B. ein kleines PowerShell-Modul), gehört er
  in einen eigenen Ordner mit seiner Lizenz und einen Eintrag in `NOTICE`.

### 2.5 Wer eine befüllte SSD weitergibt

Dann ist der Weitergebende Verbreiter aller Komponenten auf der SSD.

| Pflicht | Gilt für |
|---|---|
| Lizenztexte und Copyright beilegen | alle (MIT, Apache-2.0) |
| NOTICE-Dateien unverändert mitgeben | Apache-2.0 (Codex, llamafile) |
| Kopie der Nutzungsbedingungen, Beschränkungen weitergeben, Notice-Datei | Gemma ≤ 3 |
| "Built with Llama" sichtbar, Notice-Datei, AUP | Llama |
| Nur nicht kommerziell | Qwen-Research-Modelle |
| Nicht erlaubt | Sysinternals |
| Nur als Teil der Anwendung | CUDA-DLLs im Ollama-Paket |
| **Protokolle löschen** | Protokolle enthalten Benutzernamen, Pfade, Ereignisse fremder PCs; das ist ein Datenschutzthema, kein Lizenzthema |

Empfehlung: Erbauer-Schalter **"Für Weitergabe vorbereiten"**: nur Komponenten mit
`redistributable: true`, Lizenzordner vollständig, Protokolle und Zustandsdateien gelöscht,
Manifest mit Hashes neu geschrieben, Liste der enthaltenen Komponenten im Startbildschirm.

Verkauf ist eine andere Liga:

- EU-Produkthaftungsrichtlinie 2024/2853: Software ist Produkt; Umsetzung bis
  09.12.2026. Freie Software ist nur ausgenommen, wenn sie "outside the course of a
  commercial activity" entwickelt oder geliefert wird. Wer SSDs verkauft, haftet als
  Hersteller.
- Cyber Resilience Act: nicht monetarisierte freie Software ist ausserhalb; Meldepflichten
  seit 11.09.2026, volle Anwendung ab 11.12.2027. Ein Händler mit befüllten SSDs wäre
  betroffen, das Repo selbst nicht.
- Schweiz: eigenes Produktehaftpflichtgesetz; die Frage "Software als Produkt" für den
  konkreten Fall von einer Fachperson prüfen lassen.

---

## 3 Name

Kriterien: kurz, merkbar, international verständlich, deutschfreundlich, Wortspiel
willkommen, keine Marken wie Windows, Microsoft, Copilot. Geprüft am 09.11.2026 per
`https://api.github.com/search/repositories?q=<name>`, Websuche und `whois` für die
.com-Domain. Markenregister (Swissreg, TMview, WIPO Global Brand Database) wurden
**nicht** durchsucht.

Hinweis für deutschsprachiges Publikum: Namen mit "Heil-" meiden (NS-Konnotation).
Englisch "Heal" wird als englisches Wort gelesen und ist unproblematisch.

### 3.1 Geprüfte Kandidaten

| Name | Idee | GitHub-Suche | Web, Domain | Urteil |
|---|---|---|---|---|
| **Plug'n'Heal** (Repo `plugnheal`) | "Plug and Play" wird "einstecken und heilen"; erklärt das Produkt in zwei Wörtern | 0 Treffer (`plugnheal`, `plugandheal`) | keine Software dieses Namens gefunden; `plugnheal.com` und `.org` **nicht registriert** | **sehr gut** |
| **DocClick** | Doppelklick führt zum Doktor; "doc" + "click" international | 1 Treffer: `iambumblehead/docclick` (JS-Hilfsfunktion, 0 Sterne, 2015) | kein Produkt gefunden; Marke DOCUCLICK erloschen 2019; `docclick.com` registriert seit 2014 | gut; "Doc" kann auch an Dokumente erinnern |
| **HealDrive** | Laufwerk, das heilt; SSD im Namen | 0 Treffer | keine Software; Marke HEALTHDRIVE aufgegeben 2016; `healdrive.com` registriert seit 2020 | gut, nüchtern |
| AIdKit ("First AIdKit") | AI + Aid Kit (Verbandskasten) | 37 Treffer, alle klein (Erste-Hilfe-Apps, Go-Werkzeug "aidkit") | `aidkit.com` vergeben | mittel; Schreibweise schwer zu sprechen |
| SOS-Drive | Notruf + Laufwerk | 7 Treffer, u. a. Organisation `SOSdrive/SOSdrive` (Push 05.11.2026, ohne Beschreibung) | Pannenhilfe-Apps "SOS Driver", "SOS Auto"; `sosdrive.com` vergeben | mittel bis schwach |
| Fixli | Schweizer Verkleinerung von "fix" | keine exakten Treffer | `fixli.com` und `fixli.ch` vergeben; ähnlich "Fixly" (Handwerker-Apps) | mittel; sehr schweizerisch |
| Fixpunkt | Deutsch "Fixpunkt", Fix im Wort | 5 kleine Treffer | gewöhnliches deutsches Wort | nur für deutschsprachiges Publikum |
| Nothelfer | Schweizer Begriff (Nothelferkurs) | 8 Treffer (Kurswebseiten) | `nothelfer.ai` ohne Auflösung | gut als deutscher Untertitel, nicht international |
| Flickzeug | Fahrrad-Flickzeug | `prefix-dev/flickzeug` (Rust-Crate, 15 Sterne) | nicht international | schwach |
| Heinzel | Heinzelmännchen arbeiten nachts | `wintermeyer/heinzel` (104 Sterne): KI-Regelwerk für Sysadmins, dazu Fork `jolitz` | direkte Kollision im selben Thema | **ausgeschieden** |

### 3.2 Weitere ausgeschiedene Ideen

| Name | Grund |
|---|---|
| FixStick | Verwechslung mit **FixMeStick**, einem kommerziellen USB-Reparaturstick |
| HouseCall | Trend Micro HouseCall, kostenloser Virenscanner, gleicher Markt |
| PatchPal | `amaiya/patchpal` (33 Sterne): Agenten-Assistent mit lokalen LLMs |
| Medikit | 202 Treffer, überlaufen |
| Kitt | Wortspiel KI + Kitt + Kit wäre schön, aber 38 144 Treffer und KITT aus Knight Rider |
| Lares, Kintsugi | bereits Projekte im selben Feld |
| Stetho | `facebook/stetho` |

### 3.3 Top 3

1. **Plug'n'Heal**: einzige Kandidatin ohne jede Kollision, Domain frei, das Wortspiel
   erklärt Bedienung und Zweck. Repo-Name `plugnheal`, Anzeige "Plug'n'Heal", deutscher
   Untertitel z. B. "Der Notfallhelfer für Windows".
2. **DocClick**: Bezug zum Doppelklick, sehr kurz, kaum belegt.
3. **HealDrive**: sachlich, gut aussprechbar, GitHub frei.

Vor der Festlegung: Swissreg (IGE), TMview (EUIPO) und WIPO Global Brand Database für
Klasse 9 und 42 durchsuchen, Domain sichern (das kostet Geld, also der Maintainer).

---

## 4 README für Laien und Entwickler

### 4.1 Was gute Endnutzer-READMEs ausmacht

| Beispiel | Was es gut macht |
|---|---|
| [Etcher](https://github.com/balena-io/etcher) | Ein Satz Versprechen mit dem Wort "safely": "Flash OS images to SD cards & USB drives, safely and easily." Darunter eine Linkleiste Download, Support, Documentation, Contributing, Roadmap. Unterstützte Systeme als kurze Liste. |
| [Rufus](https://github.com/pbatard/rufus) | Ein Satz, dann Funktionsliste. Bedienhilfe auf rufus.ie und im FAQ-Wiki, **eigene Sicherheitsseite** (Signatur, reproduzierbare Builds, signierte Downloads, opt-in für Updateprüfung). |
| [Raspberry Pi Imager](https://github.com/raspberrypi/rpi-imager) | Screenshot zuerst, Installation in zwei Zeilen, Benutzerdoku auf der Hersteller-Webseite. Telemetrie offen erklärt: warum, was, wo gespeichert, wie abschalten. |
| [Ventoy](https://github.com/ventoy/Ventoy) | Vertrauen durch Belege: "1300+ ISO files are tested" mit Liste. Lange Doku auf eigener Webseite mit Bildern. |
| [Rescuezilla](https://github.com/rescuezilla/rescuezilla) | Erklärt den Fachbegriff in Alltagssprache, sagt ehrlich, **wann man das Werkzeug nicht braucht**, Screenshots mit Alt-Text, Übersetzung über Weblate. |
| [RigWright](https://github.com/Subzero121800/RigWright) | "Easy download (no technical skills needed)" in drei nummerierten Schritten, inklusive "If Windows shows 'Windows protected your PC', click More info, Run anyway". Entwicklerweg eingeklappt in `<details>`. Abschnitt "How Rigwright keeps you safe". |
| [Lares-Windows](https://github.com/at0m-b0mb/Lares-Windows) | "Status, stated plainly" und "What it will not do"; das eigene Sicherheitsaudit offen im README. |
| [Coclico](https://github.com/Coclico-cy/Coclico) | Nutzer-README und Entwickler-README getrennt, je Englisch und Französisch, Sprachumschalter oben. |
| [RustDesk](https://github.com/rustdesk/rustdesk) | Sprachleiste oben, darunter ein `> [!Caution]`-Kasten mit Missbrauchshinweis. |
| [Field Tech Copilot](https://github.com/ben4mn/field-tech-copilot) | `> [!CAUTION]` gleich unter dem Titel: was das Werkzeug **nicht** ist. |

Gemeinsamer Kern: ein Satz Versprechen, ein Bild, drei Schritte, Voraussetzungen als
Tabelle, was es tut und was nicht, Hilfe bei den zwei, drei häufigsten Stolpersteinen,
Entwicklerkram weiter unten oder anderswo.

### 4.2 Sprache

**Empfehlung: `README.md` auf Englisch als Hauptseite, `README.de.md` gleichwertig für den
Nutzerteil, Entwicklerdoku nur Englisch unter `docs/`.**

- GitHub zeigt immer `README.md`; das Repo soll international nutzbar sein.
- Die erste Nutzergruppe spricht Deutsch und braucht den Nutzerteil vollständig, nicht
  als Kurzfassung.
- Übersetzungen veralten (RustDesk listet 27 Sprachen). Gegenmittel: beide READMEs tragen
  dieselbe Versionsmarke und dieselben Abschnittsanker; ein CI-Schritt prüft das.
- Sprachleiste ganz oben: `English | [Deutsch](README.de.md)`.
- Einfache Sprache (Niveau B1): kurze Sätze, keine Fachwörter ohne Erklärung, "Sie" im
  Deutschen.
- Die Oberfläche des Werkzeugs selbst muss mindestens Deutsch und Englisch können; das
  README ersetzt keine Bildschirmtexte.

### 4.3 Gliederung (Vorschlag)

```
README.md / README.de.md
  1  Name, ein Satz Versprechen, Sprachleiste, Status-Badge (z. B. "Beta")
  2  Warnkasten [!CAUTION]: ändert Windows mit Administratorrechten, Link zu "Risiken"
  3  Was es tut (drei Punkte) und ein Bild oder kurzes GIF
  4  Was Sie brauchen (Tabelle: Windows 10 22H2 / 11 x64, externe SSD ab ... GB,
     USB 3, RAM ab ... GB, für den Bau ein PC mit Internet)
  5  SSD vorbereiten (für Helfer): drei Schritte, inkl. SmartScreen-Hinweis mit Bild
  6  SSD benutzen (für Betroffene): einstecken, START doppelklicken, Bericht lesen
  7  Was bei einem Lauf passiert: Wiederherstellungspunkt, Diagnose, Reparatur,
     Prüfung, Bericht
  8  Was es nie tut (Liste)
  9  Risiken, ehrlich (Tabelle, siehe 4.4)
 10  Wenn etwas schiefgeht: Rücknahme, Systemwiederherstellung, wo das Protokoll liegt
 11  Häufige Fragen: Virenscanner warnt, "Windows hat den PC geschützt", langsam,
     welches Modell, braucht es Internet
 12  Datenschutz: offline, Protokoll nur auf der SSD, vor Weitergabe löschen
 13  Für Entwickler: Links in docs/
 14  Lizenz, Drittkomponenten, Haftung, "nicht verbunden mit Microsoft ..."

docs/
  BUILDING.md          Erbauer im Detail, Manifest, Hashes
  ARCHITECTURE.md      Agent, Katalog, Rücknahme, Modellwahl
  TOOLBOX.md           jeder Katalogeintrag mit Probe, Fix, Rollback, Risiko
  TESTING.md           Testmatrix, CI, Hardwaretests
  STATUS.md            welche Einträge auf echter Hardware gelaufen sind
SECURITY.md            Meldeweg (GitHub Private Vulnerability Reporting)
CONTRIBUTING.md        DCO, Stil, Tests
THIRD-PARTY-NOTICES.md erzeugt aus dem Manifest
CHANGELOG.md, LICENSE, NOTICE
.github/ISSUE_TEMPLATE  verlangt die Diagnosedatei statt Screenshots
```

### 4.4 Risiken ehrlich erklären

Grundsätze:

1. **Oben, nicht im Kleingedruckten.** Der Warnkasten steht vor der Anleitung.
2. **Konkret statt allgemein.** Nicht "Nutzung auf eigene Gefahr", sondern: was kann
   passieren, was tun wir dagegen, was können Sie tun.
3. **Weder Angst noch Beschwichtigung.** "Eine KI kann sich irren" ist wahr und
   verständlich; "100 % sicher" ist falsch.
4. **Belege statt Versprechen.** Wie viele Katalogeinträge auf echter Hardware getestet
   wurden (Vorbild Lares).
5. **Einwilligung im Programm**, nicht nur im README: Beim Start zwei Häkchen ("Meine
   wichtigen Dateien sind gesichert", "Ich bin einverstanden, dass das Programm Windows
   verändert"), und die Einwilligung ins Protokoll schreiben.

Mustertext Deutsch:

> **Wichtig: Dieses Programm verändert Ihren Computer.**
> Eine künstliche Intelligenz (KI) entscheidet selbst, was sie prüft und repariert. Dafür
> führt sie Befehle mit Administratorrechten aus. Eine KI kann sich irren: Sie kann die
> Ursache falsch erkennen und im schlimmsten Fall etwas verschlimmern.
> Deshalb legt das Programm vor jeder Änderung einen Wiederherstellungspunkt an, benutzt
> nur geprüfte Reparaturschritte aus einer festen Liste, prüft nach jedem Schritt, ob er
> geholfen hat, und macht ihn sonst rückgängig. Alles steht im Protokoll auf der SSD.
> Ihre persönlichen Dateien löscht es nie. Sichern Sie trotzdem Fotos und Dokumente,
> bevor Sie es benutzen. Nicht auf Firmencomputern verwenden.

Mustertext Englisch:

> **Important: this program changes your computer.**
> An artificial intelligence (AI) decides on its own what to check and repair, and runs
> commands with administrator rights to do it. AI can be wrong: it can misread the cause
> and, in the worst case, make things worse.
> That is why the program creates a restore point before any change, uses only reviewed
> repair steps from a fixed list, checks after every step whether it helped, and undoes
> it if not. Everything is written to a log on the SSD.
> It never deletes your personal files. Still, back up your photos and documents first.
> Do not use it on computers managed by your employer.

Tabelle "Was schiefgehen kann" (Vorschlag):

| Was passieren kann | Was das Programm dagegen tut | Was Sie tun können |
|---|---|---|
| Die KI erkennt die Ursache falsch, die Reparatur hilft nicht | nur Schritte aus dem geprüften Katalog, Wirkung wird gemessen, sonst Rücknahme | Bericht einer Fachperson zeigen |
| Eine Reparatur macht etwas schlimmer | Rücknahme pro Schritt, Wiederherstellungspunkt | Systemwiederherstellung (Anleitung im Abschnitt "Wenn etwas schiefgeht") |
| Kein Wiederherstellungspunkt möglich (Computerschutz aus, schon einer in den letzten 24 Stunden, kein Platz) | sagt es klar; ohne Punkt nur Diagnose oder nur risikoarme Schritte | – |
| Persönliche Daten gehen verloren | fasst persönliche Ordner nie an, keine Partitions- oder Formatierbefehle | vorher sichern |
| Virenscanner schlägt Alarm | lesbare Skripte, signierte Programme, FAQ | Schutz nicht blind abschalten, FAQ lesen |
| Sehr langsam auf altem PC | wählt automatisch ein kleineres Modell | Netzteil anschliessen, Geduld |
| Daten verlassen den PC | läuft offline, Protokoll nur auf der SSD | Protokoll vor Weitergabe der SSD löschen |

Liste "Was es nie tut" (Vorschlag): persönliche Dateien löschen; Datenträger
partitionieren oder formatieren; Schattenkopien oder Wiederherstellungspunkte löschen;
Virenschutz, Firewall oder Windows Update dauerhaft abschalten; BitLocker-Schlüssel
lesen oder speichern; Passwörter auslesen; etwas ins Internet senden; sich selbst auf dem
PC installieren.

### 4.5 Haftungsausschluss

- Apache-2.0 §7 (keine Gewährleistung) und §8 (Haftungsbeschränkung) gelten schon. Das
  README wiederholt sie in einem Satz Alltagssprache und verlinkt die Lizenz. Keine eigene
  zusätzliche EULA.
- Schweiz: Eine im Voraus vereinbarte Haftungsfreizeichnung für rechtswidrige Absicht
  oder grobe Fahrlässigkeit ist nichtig (OR 100 Abs. 1; BGE 102 II 256). Für Schenkungen
  haftet der Schenkende nach OR 248 nur bei Absicht oder grober Fahrlässigkeit; in
  Deutschland ähnlich §521 BGB. Diese beiden Hinweise stammen aus dem Gedächtnis und sind
  nicht an der Quelle geprüft.
- Folgerung: Der eigentliche Schutz ist nicht der Ausschlusstext, sondern sorgfältige
  Arbeit: ehrliche Risikobeschreibung, sichere Voreinstellungen, Rücknahme, Tests,
  dokumentierte Grenzen. Bei Verkauf befüllter SSDs (Abschnitt 2.5) eine Fachperson
  beiziehen.

Vorschlag für den README-Satz: "Provided as is, without warranty. You use it at your own
risk. See LICENSE, sections 7 and 8." bzw. "Ohne Gewähr. Die Nutzung erfolgt auf eigenes
Risiko. Siehe LICENSE, Abschnitte 7 und 8."

---

## 5 Verteilung und Vertrauen

### 5.1 Releases, Prüfsummen, Attestierung

| Baustein | Stand | Empfehlung |
|---|---|---|
| GitHub Releases | – | Release enthält nur das eigene Paket (ZIP der Skripte) und `SHA256SUMS`, nie Fremdbinärdateien |
| Unveränderliche Releases | allgemein verfügbar seit 28.10.2025; Prüfung mit `gh release verify <tag>` und `gh release verify-asset <tag> <datei>` | im Repo einschalten |
| Build-Attestierung | allgemein verfügbar seit 25.06.2024; `gh attestation verify <datei> -R <owner>/<repo>`; mit GitHub Free nur für öffentliche Repos | `actions/attest-build-provenance` im Release-Workflow |
| Zusätzliche Signatur | Kintsugi plant minisign (Ed25519) | optional für Fortgeschrittene; Laien prüfen keine Hashes |
| Integrität der Downloads im Erbauer | Lehre aus 1.2 | Version und SHA-256 jeder Komponente im Manifest festnageln, nur HTTPS, Abbruch bei Abweichung, Teil-Downloads als `.part` und atomar umbenennen (wie Lares) |
| Reproduzierbarkeit | Rufus seit 3.4 bitgleich nachbaubar | Release-ZIP deterministisch erzeugen (`git archive`), damit jeder es nachbauen kann |

Aktualisierungen der festgenagelten Versionen: ein geplanter Workflow sucht neue Versionen,
lädt sie, berechnet Hashes und öffnet einen Pull Request. Ein Mensch prüft, dann Merge.

### 5.2 Signieren: Optionen

Authenticode ohne von Windows vertrautes Zertifikat bringt nichts; selbstsigniert verhält
sich laut Microsoft wie unsigniert.

| Weg | Kosten | Für den Maintainer in der Schweiz | Wirkung | Bemerkung |
|---|---|---|---|---|
| Unsigniert + `SHA256SUMS` + Attestierung + unveränderliche Releases | 0 | ja | SmartScreen-Warnung beim Erbauer; SAC blockiert `.ps1`/`.cmd` mit MotW ohne Übersteuerung | Grundausstattung, sofort |
| **SignPath Foundation** | 0 | ja, wenn die Bedingungen erfüllt sind | gültige Signatur, Reputation baut sich auf | Herausgeber erscheint als "SignPath Foundation"; OSI-Lizenz, kein proprietärer Code, verifizierbarer CI-Build, manuelle Freigabe pro Release, MFA, Seite "Code signing policy", **"Software must not modify the user's system configuration without proper warnings"**, keine Hacking-Werkzeuge. Ob PowerShell-Skripte signiert werden, vor dem Antrag klären |
| **Certum Open Source Code Signing** | ab ca. 49 EUR (Cloud) bzw. 69 EUR, Set mit Karte ca. 359 EUR | ja, nur natürliche Personen | wie OV | Name erhält "Open Source Developer", Gültigkeit 1 Jahr. Kostet Geld, also bestellt der Maintainer |
| Azure Artifact Signing | 9.99 USD/Monat | **nein**: Einzelpersonen nur USA und Kanada; Organisationen USA, Kanada, EU, UK | wie OV | Schweiz ist nicht EU |
| OV-Zertifikat | 150–300 USD/Jahr, Schlüssel auf HSM/Token seit Juni 2023 | ja | Reputation baut sich auf | |
| EV-Zertifikat | ab 400 USD/Jahr | ja | seit 2024 **kein** SmartScreen-Vorteil mehr | nicht empfehlen |
| Microsoft Store | 0 | ja | keine Warnungen | passt nicht zu einem SSD-Erbauer |

Empfehlung: Mit der Grundausstattung starten, gleich nach dem ersten Release SignPath
beantragen. Wenn SignPath ablehnt oder PowerShell nicht abdeckt, Certum als Antrag an den Maintainer.

### 5.3 Was SmartScreen, Smart App Control und Execution Policy für den Start bedeuten

| Ort | Was greift | Lösung |
|---|---|---|
| Erbauer-PC, Release-ZIP aus dem Browser | Mark of the Web; SmartScreen prüft Reputation pro Datei-Hash (unsigniert: bei jeder Version wieder bei null) bzw. pro Zertifikat; SAC blockiert MotW-Skripte | README mit Bild: ZIP vor dem Entpacken unter "Eigenschaften, Zulassen" freigeben; danach entfernt der Erbauer per `Unblock-File` das MotW von allem, was er auf die SSD schreibt |
| Ziel-PC, Start von der SSD | Dateien auf der SSD tragen kein MotW (nicht heruntergeladen; exFAT kann ohnehin keine Alternate Data Streams) | SmartScreen bleibt still. SAC prüft aber jede EXE/DLL auf Signatur, unabhängig von MotW: nur signierte Binärdateien mitbringen (Ollama signiert `.exe` und `.dll`), keine eigene EXE |
| Execution Policy | Windows PowerShell 5.1 auf Clients: wenn nichts gesetzt ist, `Restricted`; laut Microsoft "isn't a security boundary" | Starter `START.cmd` ruft `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..."` auf. Gruppenrichtlinien (MachinePolicy, UserPolicy) gehen vor; auf Firmen-PCs kann es daran scheitern, deshalb "nicht für Firmencomputer" |
| UAC | Erhöhung über das Microsoft-signierte `powershell.exe` zeigt "Verifizierter Herausgeber: Microsoft Windows" statt "Unbekannter Herausgeber" | Selbst-Erhöhung mit `Start-Process -Verb RunAs` auf den absoluten Pfad |
| Firmen-PCs | ASR-Regel gegen unsignierte Prozesse von USB, Device Control, AllSigned-Richtlinien | nicht unterstützen, im Selbsttest erkennen und freundlich abbrechen |

### 5.4 Fehlalarmen vorbeugen

- Lesbarer Klartext, keine Verschleierung, kein `-EncodedCommand`, kein `iex`, kein
  `[scriptblock]::Create`, kein `Add-Type` mit Inline-C#, keine Download-und-Ausführen-Kette
  auf dem Ziel-PC (er ist offline).
- Defender-Einstellungen nie ändern, auch nicht "nur kurz für die Geschwindigkeit"; der
  Ratgeber-Tipp, den Modellordner vom Scan auszunehmen, ist für ein Laienwerkzeug falsch.
- Schattenkopien nie löschen (Ransomware-Muster und zugleich Wiederherstellungspunkte).
- Vor jedem Release optional VirusTotal-Prüfung des ZIP; bei Fehlalarm über das Microsoft
  Security Intelligence Portal (`microsoft.com/wdsi/filesubmission`) melden; Vorgehen im
  FAQ dokumentieren.

### 5.5 CI auf GitHub Actions

| Punkt | Stand (Quelle) |
|---|---|
| Kosten | Standard-Runner in **öffentlichen Repos kostenlos**, zählen nicht ans Kontingent. Privat: 12 USD Guthaben pro Monat (GitHub Free), Windows 2 Kerne 0.010 USD/min. Self-hosted-Runner bleiben gratis; die für 01.03.2026 angekündigte Plattformgebühr von 0.002 USD/min ist laut aktueller Doku nicht in Kraft |
| `windows-latest` | Windows Server 2025, Abbild 20261103.298.1: PowerShell 7.6.9, **Pester 3.4.0 und 5.9.0**, **PSScriptAnalyzer 1.25.0** vorinstalliert |
| Zielplattform | Ziel-PCs haben nur Windows PowerShell 5.1. Also Matrix `shell: powershell` (5.1) und `shell: pwsh` (7.x); 5.1 ist massgebend |
| Grenzen | Server-OS: keine Systemwiederherstellung (`Checkpoint-Computer` nur Client), keine GPU, keine Consumer-Funktionen. Wiederherstellungspunkt, Treiber, Modellwahl mit Pester mocken. Es gibt einen `windows-11-arm`-Runner (Client-OS, Arm64); ob dort Systemwiederherstellung geht, ist nicht geprüft |
| Was die CI prüfen soll | PSScriptAnalyzer (inkl. `PSAvoidUsingInvokeExpression`), Pester-Unit-Tests, Schema-Prüfung des Katalogs (jeder Eintrag mit Probe, Fix, Rollback, Risiko, Parameter-Regex), Sperrliste gefährlicher Muster, Gleichstand `README.md`/`README.de.md`, `THIRD-PARTY-NOTICES.md` aus Manifest, Lizenzfelder im Manifest vollständig |
| Was die CI nicht kann | echte Reparaturen auf Windows 10/11 mit verschiedenen Sprachen, GPUs, RAM-Grössen, SAC an/aus, Standardbenutzer. Dafür eine dokumentierte Testmatrix auf VMs (z. B. Proxmox) und `docs/STATUS.md` mit "auf echter Hardware gelaufen: ja/nein" |
| Lokalisierung | Testmatrix mit deutschem und englischem Windows: Ausgaben von `netsh`, Gruppennamen ("Administratoren"), Ereignistexte sind lokalisiert. Objekte und SIDs auswerten, nie übersetzten Text. (Erfahrungswert, nicht aus den Issues belegt) |

Release-Workflow: Tag, Tests, `git archive` zu ZIP, `SHA256SUMS`,
`actions/attest-build-provenance`, Release anlegen (unveränderlich).

---

## 6 Offene Punkte und Grenzen dieser Recherche

| Punkt | Warum offen |
|---|---|
| Kintsugi-Issues | Gitea-Instanz `git.integrolabs.net` von hier nicht auflösbar |
| Markenregister für die Namen | nicht durchsucht (Swissreg, TMview, WIPO) |
| Signatur der llama.cpp-Windows-Binärdateien | nicht geprüft; Ollama signiert laut Build-Skript, ob jedes Release tatsächlich signiert ist, an einer Datei nachmessen |
| SignPath und PowerShell-Skripte | in den Bedingungen nicht erwähnt, vor Antrag nachfragen |
| OR 248, §521 BGB | aus dem Gedächtnis |
| Systemwiederherstellung auf `windows-11-arm`-Runner | nicht getestet |
| Sterne und Lizenz von RigWright, Coclico | nur aus der Suchtrefferliste, Einzelabfrage scheiterte am API-Kontingent (60 Anfragen pro Stunde ohne Anmeldung) |

---

## Quellen

Alle abgerufen am 09.11.2026.

Vorbilder und Issues

- https://github.com/jmagly/kintsugi-usb (README, Metadaten)
- https://github.com/fidpa/claude-code-live-usb
- https://github.com/balaji-md/bmass
- https://github.com/techjarves (Repo-Liste); Issues von Portable-AI-USB, USB-Uncensored-LLM, ClaudeCode-Portable, Hermes-USB-Portable, OpenClaw-USB-Portable über `api.github.com/repos/<repo>/issues?state=all`
- https://github.com/techjarves/Portable-AI-USB/issues/1, /3, /27, /40, /46, /50, /52, /60, /61, /64
- https://github.com/techjarves/USB-Uncensored-LLM/issues/1, /17, /24, /25, /42, /48, /49
- https://github.com/techjarves/Hermes-USB-Portable/issues/4, /5, /8, /12, /14
- https://github.com/ollama/ollama/issues/2519, /3168, /4409, /2855, /11527, /17591, /17661
- https://github.com/mozilla-ai/llamafile/issues/28, /37, /67, /364 und README (4-GB-Grenze)
- https://github.com/janhq/jan/issues/3974, https://github.com/janhq/jan/pull/7350
- https://github.com/LostRuins/koboldcpp (README)
- https://github.com/at0m-b0mb/Lares-Windows (README: Modell, Sicherheitsaudit, Status)
- https://github.com/Subzero121800/RigWright (README: Download, Schutzmassnahmen)
- https://github.com/David-Martel/PC-AI, https://github.com/usausa/pc-agent, https://github.com/nimai1236/DESKTOP-DOCTOR, https://github.com/ben4mn/field-tech-copilot, https://github.com/Coclico-cy/Coclico, https://github.com/wintermeyer/heinzel, https://github.com/yossebastiands/portable-agent
- https://docs.ollama.com/windows
- https://raw.githubusercontent.com/ollama/ollama/main/scripts/build_windows.ps1 (Funktion `sign`)
- https://learn.microsoft.com/en-us/windows/configuration/settings/agent und https://www.windowscentral.com/software-apps/windows-11/heres-the-secret-behind-microsofts-ai-agents-meet-mu-the-compact-ai-model-transforming-settings-on-your-pc (Settings-Agent, Mu)
- https://learn.microsoft.com/en-us/answers/a/1989467 und https://forums.developer.nvidia.com/t/how-to-query-adapter-ram-for-cards-with-more-than-4-gb-c/69955 (AdapterRAM-Grenze)
- https://www.kunalganglani.com/blog/portable-llm-usb-stick, https://memstechtips.com/local-ai-agent-windows-ollama-opencode/ (Ratgeber: Kontextgrösse, Port, Defender)

Lizenzen

- https://raw.githubusercontent.com/ollama/ollama/main/LICENSE
- https://raw.githubusercontent.com/openai/codex/main/NOTICE
- https://raw.githubusercontent.com/mozilla-ai/llamafile/main/LICENSE
- https://raw.githubusercontent.com/janhq/jan/main/LICENSE
- https://huggingface.co/api/models/<modell> für Qwen/Qwen3-4B, Qwen3-8B, Qwen2.5-3B-Instruct, Qwen2.5-7B-Instruct, Qwen3.5-4B, Qwen3.5-9B, google/gemma-3-4b-it, google/gemma-4-E4B-it, google/gemma-4-31B-it, meta-llama/Llama-3.2-3B-Instruct, meta-llama/Llama-3.1-8B-Instruct, microsoft/Phi-4-mini-instruct, mistralai/Ministral-3-8B-Instruct-2512, ibm-granite/granite-4.0-micro, openai/gpt-oss-20b
- https://huggingface.co/Qwen/Qwen2.5-3B-Instruct/blob/main/LICENSE
- https://ai.google.dev/gemma/terms (zuletzt geändert 01.04.2026)
- https://dev.meta.ai/llama/llama3_2/license
- https://learn.microsoft.com/en-us/sysinternals/license-terms
- https://docs.nvidia.com/cuda/eula/index.html
- https://eur-lex.europa.eu/eli/dir/2024/2853/en und https://www.sidley.com/en/insights/newsupdates/2026/10/revised-eu-product-liability-directive (Produkthaftung)
- https://www.traverssmith.com/knowledge/knowledge-container/the-eu-cyber-resilience-acts-vulnerability-and-incident-reporting-requirements-are-now-live/ und https://www.orrick.com/en/Insights/2026/09/EU-Cyber-Resilience-Act-New-Guidance-Clarifies-Scope-Reporting (CRA)
- https://onlinekommentar.ch/de/kommentare/or100 (OR 100)

Name

- `https://api.github.com/search/repositories?q=<name>` für plugnheal, plugandheal, docclick, healdrive, fixstick, heinzel, fixwerk, nothelfer, sosdrive, medikit, kitt, fixli, aidkit, fixpunkt, patchpal, flickzeug
- `whois` für plugnheal.com, plugnheal.org, docclick.com, healdrive.com
- https://support.fixmestick.com (FixMeStick)

README

- https://github.com/balena-io/etcher, https://github.com/pbatard/rufus, https://github.com/pbatard/rufus/wiki/Security, https://github.com/raspberrypi/rpi-imager, https://github.com/ventoy/Ventoy, https://github.com/rescuezilla/rescuezilla, https://github.com/rustdesk/rustdesk

Verteilung und Vertrauen

- https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation (ms.date 04.05.2026)
- https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options (ms.date 29.08.2026)
- https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/overview (ms.date 30.09.2026)
- https://textslashplain.com/2026/04/28/smart-app-control/ (Eric Lawrence)
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies (ms.date 31.08.2026)
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/checkpoint-computer?view=powershell-5.1
- https://learn.microsoft.com/en-us/defender-endpoint/attack-surface-reduction-rules-reference
- https://signpath.org/terms
- https://shop.certum.eu/open-source-code-signing-on-simplysign.html, https://shop.certum.eu/open-source-code-signing-code.html
- https://github.com/Azure/artifact-signing-action/issues/42 (Einzelentwickler)
- https://learn.microsoft.com/en-us/defender-endpoint/defender-endpoint-false-positives-negatives (Fehlalarme melden)
- https://docs.github.com/en/billing/concepts/product-billing/github-actions
- https://github.blog/changelog/2025-12-16-coming-soon-simpler-pricing-and-a-better-experience-for-github-actions/
- https://raw.githubusercontent.com/actions/runner-images/main/images/windows/Windows2025-VS2026-Readme.md (Abbild 20261103.298.1)
- https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/
- https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations
- https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity
