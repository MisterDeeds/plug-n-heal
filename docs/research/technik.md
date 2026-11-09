Interne Recherche vom 09.11.2026, unverändert bis auf Anonymisierung; die Entscheide stehen in docs/ARCHITECTURE.md.

# Notfall-KI auf externer SSD: Technik-Recherche

Stand 09.11.2026. Ziel: Ein Laie steckt eine SSD an einen Windows-10/11-PC, doppelklickt, und ein lokaler
KI-Agent (offline) findet und behebt Windows-Probleme.

**So ist der Bericht entstanden**
- **Gemessen auf einem Linux-Testrechner** (Linux-VM mit 16 vCPU auf einem AMD Threadripper PRO 7975WX, Docker, ohne GPU):
  - Windows-Pakete über Range-Requests oder als Download zerlegt: Inhalt, DLL-Importe (`objdump -p`) und
    Authenticode-Signatur.
  - Ollama 0.40.15 und llama.cpp b12233 (Linux-Builds) in einem Docker-Netz ohne Internet betrieben.
  - Darin Tool-Calling, Codex 0.167.0 sowie das Laden von Modellen ohne Ollama und das Fortsetzen von
    Downloads getestet.
- **Nicht gemessen** wurde auf einem echten Windows-PC (keiner war freigegeben). Alles, was nur dort zu
  klären ist, steht im Abschnitt «Offen» mit einem Testplan.
- **Quellen** sind mit URL und Datum angegeben; «abgerufen» heisst am 09.11.2026 abgerufen.
- **Kennzeichnung:** **[gemessen]** heisst selbst geprüft. **[Quelle]** heisst belegt, aber nicht selbst
  geprüft. **[unbelegt]** heisst weder gemessen noch belegt.

---

## Kurzfassung: Empfehlungen

| Frage | Empfehlung | Hauptgrund |
|---|---|---|
| 1 Laufzeit | **Nur Ollama portable** (`ollama-windows-amd64.zip`). Kein zweites Paket, kein llamafile. | Ollama 0.40.15 enthält bereits CUDA 12, CUDA 13, **Vulkan** und 14 CPU-Varianten. Alle Dateien sind von «Ollama Inc.» signiert und bringen die VC++-Laufzeit selbst mit [gemessen]. llama.cpp-Builds sind unsigniert und brauchen das VC++-Redistributable [gemessen]. |
| 2 Agent | **Eigener schlanker Loop in PowerShell 5.1** gegen Ollama `/api/chat` mit `tools`: geprüfte Aktionen, Bestätigung vor jeder Änderung. Codex höchstens als Expertenmodus. | Gleiche Aufgabe: ca. 260 Prompt-Token mit eigenem Loop, 3767 bis 8881 mit Codex [gemessen]. qwen3:0.6b ruft mit eigenem Loop korrekt ein Werkzeug auf, mit Codex gar keines [gemessen]. |
| 3 Oberfläche | **WinForms-Fenster aus PowerShell 5.1**, ohne Konsole gestartet (`CreateNoWindow`). Arbeit im Hintergrund-Runspace, Schrittliste mit Häkchen. Web-Oberfläche erst später. | Ohne Port, Browser, Erststart-Assistenten und URL-ACL. Edge `--app` und HttpListener ohne Admin sind nicht sauber belegt. |
| 4 Start | SSD in **exFAT**. `START.cmd` ruft `powershell.exe -NoProfile -ExecutionPolicy Bypass -File …\start.ps1` auf; dieses startet die Oberfläche mit `CreateNoWindow` und beendet sich. Keine Erhöhung beim Start, Admin nur pro Aktion. | MOTW kann auf exFAT nicht haften. `-WindowStyle Hidden` wirkt nicht, wenn Windows Terminal Standard ist. Smart App Control blockiert unsignierte EXE/DLL. |
| 5 Hardware | VRAM aus der Registry (`HardwareInformation.qwMemorySize`, Rückfall `MemorySize`). Entscheidend ist aber, was Ollama selbst meldet (Server-Log «inference compute», `/api/ps` → `size_vram`). RAM aus `Win32_OperatingSystem`. AVX2 nur als Auskunft. | `AdapterRAM` ist uint32 und über 4 GB falsch [Quelle]. Ollama wählt die CPU-Variante selbst [gemessen]. |
| 6 Erbauer | Programme per **`curl.exe -L -C -` in einer PowerShell-Schleife** (nicht BITS), danach SHA256 prüfen. Modelle per **Ollama `/api/pull`** mit `OLLAMA_MODELS` auf der SSD; direkter Registry-Download als Rückfall. | `ollama pull` setzt nach Abbruch fort und prüft den Digest [gemessen]. Direktdownload von Manifest und Blobs funktioniert ohne Ollama [gemessen]. BITS stolpert über signierte Redirects und braucht einen angemeldeten Benutzer [Quelle]. |

---

## 1. Laufzeit

### 1.1 Vergleich

| | Ollama 0.40.15 portable | llama.cpp b12233 (`llama-server`) | llamafile 0.10.6 |
|---|---|---|---|
| Datum | 03.11.2026 | 09.11.2026 (mehrere Builds pro Tag; seit 04.11.2026 zusätzlich Versions-Tags wie v0.9.0) | 15.09.2026 |
| Paket Windows x64 | `ollama-windows-amd64.zip` 1'614'941'966 Byte, entpackt 2'264 MB | Vulkan 37'871'472 Byte (entpackt 102 MB); CPU 24'909'609; CUDA 12.4 288'944'060 + cudart 391'443'627; CUDA 13.5 170'973'687 + cudart 426'314'199; ROCm 10.0 267'515'917; SYCL 156'232'103 | `llamafile-0.10.6` 368'094'430 Byte (mit GPU-DLLs), `-thin` 43'856'395 |
| Davon GPU | cuda_v12 1'187 MB, cuda_v13 950 MB, vulkan 42 MB, Rest (CPU, EXE) 85 MB [gemessen]. AMD-ROCm als Zusatz-ZIP 258'790'357 Byte, entpackt 1'040 MB | ein ZIP pro Backend | CUDA und Vulkan eingebettet, ROCm separat |
| NVIDIA | CUDA, Compute Capability ≥ 5.0, Treiber ≥ 550 (5.0–6.2: ≥ 570) [Q-O1]; Windows-Seite nennt ≥ 551.61 [Q-O2] | CUDA-Build oder Vulkan | CUDA (nur CC ≥ 7.5, ohne IQ-Kernel) oder Vulkan [Q-LF1] |
| AMD | **Vulkan im Standard-ZIP**, standardmässig an [Q-O1, gemessen: `OLLAMA_VULKAN:true` im Log]. ROCm-ZIP nur für RX 7600–7900 XTX und PRO W7500–W7900 [Q-O1] | Vulkan- oder ROCm-Build | Vulkan; ROCm nur mit separater Bibliothek und ROCm-Laufzeit, «best-effort» [Q-LF1] |
| Intel Arc / iGPU | Vulkan. **Integrierte GPUs werden standardmässig verworfen** (ausser CUDA-iGPU und AMD gfx1151); Freischaltung mit `OLLAMA_IGPU_ENABLE=1` [Q-O3, Quelltext v0.40.15] | Vulkan, SYCL, OpenVINO | Vulkan |
| CPU-Rückfall | 14 Varianten von `x64`/`sse42` bis `zen4`/`sapphirerapids`, Auswahl zur Laufzeit [gemessen: Dateiliste] | gleiche 14 Varianten in jedem Windows-ZIP [gemessen] | eingebaut, braucht AVX [Q-LF1] |
| Abhängigkeiten | Nur die Universal CRT (`api-ms-win-crt-*`, seit Windows 10 Teil des Systems [Q-MS1]). `msvcp140`/`vcruntime140*` liegen app-lokal in `lib/ollama/{cuda_v12,cuda_v13,vulkan}`, CPU-Teil mit eigener `libc++.dll`/`libomp.dll` [gemessen]. Windows 10 22H2 oder neuer [Q-O2] | **`VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`, `MSVCP140.dll` werden importiert, sind aber nicht im ZIP** [gemessen]. Ohne VC++-2015–2022-Redistributable startet `llama-server.exe` nicht (fehlende DLL; NTSTATUS 0xC0000135 = STATUS_DLL_NOT_FOUND) | keine (Cosmopolitan) |
| Signatur | **Signiert: «Ollama Inc.»** (DigiCert, EV-Merkmale), geprüft an `ollama.exe`, `llama-server.exe`, `ggml-*.dll`, `libllama*.dll` [gemessen] | **unsigniert** (alle geprüften EXE/DLL) [gemessen] | **unsigniert**: PE-Kopf ohne Zertifikatstabelle [gemessen] |
| API | `/api/chat` mit `tools` (Argumente als Objekt), `/v1/chat/completions` (OpenAI), `/v1/responses` (von Codex genutzt) [gemessen] | `/v1/chat/completions` mit `tools`, Jinja standardmässig an [Q-L1], Argumente als String, Denken getrennt in `reasoning_content` [gemessen] | llama.cpp-Server (Stand b10441, rund 1800 Builds hinter b12233) |
| Lizenz | MIT | MIT | Apache-2.0 (+ MIT für llama.cpp) |
| Windows-Besonderheiten | `ollama.exe` ist eine Konsolen-App, siehe 4.4 | sehr viele Einzel-EXE | EXE über 4 GB laufen nicht, Gewichte extern mit `-m` [Q-LF2]; Datei muss in `.exe` umbenannt werden; «treat the AMD and Windows paths … as best-effort» [Q-LF1] |

### 1.2 Gemessene Einzelheiten

**DLL-Importe:**
- `ollama.exe` importiert nur `KERNEL32.dll` und `api-ms-win-crt-*`.
- `ggml-vulkan.dll` (Ollama) importiert `MSVCP140.dll` und `VCRUNTIME140*.dll`, die im selben Ordner `lib/ollama/vulkan/` liegen.
- llama.cpp `llama-server.exe` importiert `VCRUNTIME140.dll`, `llama-server-impl.dll` zusätzlich `MSVCP140.dll` und
  `VCRUNTIME140_1.dll`. Keine davon liegt im Vulkan- oder CPU-ZIP.

**Signaturen:**
- Ollama: Leaf-Zertifikat `O=Ollama Inc., C=CA, jurisdictionST=Ontario, businessCategory=Private Organization`.
- Codex `codex-x86_64-pc-windows-msvc.exe`: «OpenAI OpCo, LLC».
- opencode: «Anomaly Innovations, Inc».
- Cline CLI: «Cline Bot Inc.».
- goose 1.58.0: unsigniert und mit VCRUNTIME-Import.

**Ollama 0.40.15 startet intern `llama-server`:**
- Log-Zeile: `starting llama-server … --offline … --no-jinja --chat-template chatml`.
- Ein Modell-Blob von Ollama (`blobs/sha256-…`) ist eine GGUF-Datei. llama.cpp b12233 hat den Blob von qwen3:4b direkt
  geladen und damit Tool-Calls ausgeführt.
- Ein Modellbestand kann also beiden Laufzeiten dienen. Für exotische Modelle ist das nicht garantiert [unbelegt].

**Standard-Kontext:**
- Ohne VRAM setzt Ollama 4096 Token: Log `vram-based default context total_vram="0 B" default_num_ctx=4096`.
- Laut Doku gilt: unter 24 GiB VRAM 4k, 24–48 GiB 32k, ab 48 GiB 256k. Für Agenten und Coding-Werkzeuge
  empfiehlt die Doku mindestens 64k [Q-O4].
- Im eigenen Loop `num_ctx` deshalb pro Anfrage ausdrücklich setzen.

**Spuren auf dem fremden PC:**
- `ollama serve` legt beim ersten Start `~/.ollama/id_ed25519(.pub)` an [gemessen, Linux].
- Unter Windows ist das `%USERPROFILE%\.ollama`, weil Go `os.UserHomeDir()` unter Windows `%USERPROFILE%` liefert [Q-GO1].
- `USERPROFILE` für den Kindprozess auf einen Ordner der SSD zu setzen, sollte das verhindern [unbelegt, auf Windows prüfen].

### 1.3 Empfehlung Laufzeit

**Ollama portable als einzige Laufzeit.** Eine Kombination «Ollama für NVIDIA, llama.cpp-Vulkan für AMD/Intel» ist
seit dem Vulkan-Backend im Standard-ZIP unnötig.

**Begründung:**
1. **Ein Paket für alle Hersteller:** CUDA 12 und 13, Vulkan, CPU-Rückfall.
2. **Signiert.** Das ist entscheidend für Smart App Control (Abschnitt 4.3) und die ASR-Regel gegen unsignierte
   Prozesse von USB.
3. **Keine Laufzeit-Voraussetzungen** auf dem Ziel-PC (VC++ app-lokal, UCRT im System).
4. **Native Tool-API** mit Argumenten als Objekt und `charset=utf-8` im Content-Type (wichtig für PowerShell 5.1,
   siehe 2.4).
5. **Modellverwaltung inklusive:** Pull mit Fortsetzen, Digest-Prüfung, `/api/ps` für die GPU-Belegung.

**Konfiguration beim Start** (pro Prozess setzen, nie systemweit):

```
OLLAMA_MODELS        = <SSD>\system\models        (aus $PSScriptRoot abgeleitet, Laufwerksbuchstabe wechselt)
OLLAMA_HOST          = 127.0.0.1:<freier Port>    (nicht 11434, falls Ollama installiert ist)
OLLAMA_NO_CLOUD      = 1                          (deaktiviert Cloud-Modelle und Websuche, Quelltext envconfig)
OLLAMA_CONTEXT_LENGTH= 8192 bzw. 16384            (je nach RAM/VRAM; Default waere 4096)
OLLAMA_FLASH_ATTENTION=1, OLLAMA_KV_CACHE_TYPE=q8_0  (spart Speicher; Wirkung auf Laien-Hardware [unbelegt])
OLLAMA_IGPU_ENABLE   = 1 nur nach Messung          (iGPU kann langsamer als CPU sein [unbelegt])
USERPROFILE          = <SSD>\system\home          (Schluesselpaar nicht im Profil des Kunden [unbelegt])
```

**Was weggelassen werden kann:**
- `cuda_v12` (1.19 GB) oder `cuda_v13` (0.95 GB): Davon rate ich ab. CUDA 12 braucht es für ältere Karten,
  CUDA 13 für neue.
- Platz ist auf einer SSD nicht der Engpass, die Modelle sind grösser.
- Das ROCm-ZIP (+1 GB entpackt) nur, wenn sich Vulkan auf Radeon RX 7000 als zu langsam erweist [unbelegt].

**llama.cpp als Reserve:**
- Nur für Fälle, in denen Ollama scheitert.
- Dann die VC++-DLLs app-lokal beilegen. Microsoft erlaubt die lokale Bereitstellung, rät aber ab, weil Windows Update
  sie nicht wartet [Q-MS1].
- Auf PCs mit Smart App Control bleibt llama.cpp trotzdem gesperrt (unsigniert).

**llamafile: nein.**
- unsigniert
- über 4 GB nur mit externen Gewichten
- Windows-GPU-Pfad selbst als «best-effort» bezeichnet
- llama.cpp-Stand mehrere Monate alt

---

## 2. Agent

### 2.1 Ollama-Tool-Calling: offizielles Format und Messung

Laut Doku [Q-O5, Q-O6]:
- Tools haben die Form `{"type":"function","function":{"name","description","parameters":<JSON-Schema>}}`.
- Die Antwort enthält `message.tool_calls[].function.{index,name,arguments}`, wobei `arguments` ein Objekt ist.
- Das Ergebnis geht als `{"role":"tool","tool_name":…,"content":…}` zurück.
- Davor muss die Assistant-Nachricht mit den `tool_calls` wieder in `messages` stehen.
- Bei mehreren Aufrufen pro Antwort wird jedes Ergebnis als eigene Tool-Nachricht zurückgeschickt.
- Beim Streaming müssen `thinking`, `content` und `tool_calls` über alle Chunks gesammelt werden.

**Gemessen** mit Ollama 0.40.15 offline, qwen3:0.6b, CPU:

```json
POST /api/chat
{
  "model": "qwen3:0.6b", "stream": false, "think": false,
  "options": {"temperature": 0, "num_ctx": 8192},
  "messages": [
    {"role": "system", "content": "Du bist ein Windows-Helfer. Benutze die Werkzeuge, um Probleme zu pruefen."},
    {"role": "user", "content": "Mein Computer sagt, die Festplatte C: sei voll. Pruefe bitte den freien Speicher auf C:."}
  ],
  "tools": [
    {"type": "function", "function": {
      "name": "freier_speicher",
      "description": "Gibt den freien Speicherplatz eines Laufwerks in GB zurueck.",
      "parameters": {"type": "object", "required": ["laufwerk"],
        "properties": {"laufwerk": {"type": "string", "description": "Laufwerksbuchstabe, z. B. C"}}}}},
    {"type": "function", "function": {
      "name": "temp_dateien_loeschen",
      "description": "Leert den Temp-Ordner des Benutzers (nur nach Bestaetigung).",
      "parameters": {"type": "object", "properties": {}}}}
  ]
}
```

Antwort (2.0 s, `prompt_eval_count` 268, `eval_count` 43):

```json
{"message": {"role": "assistant", "content": "",
  "tool_calls": [{"id": "call_ix1g1dkp",
                  "function": {"index": 0, "name": "freier_speicher", "arguments": {"laufwerk": "C:"}}}]},
 "done_reason": "stop"}
```

Zweite Runde: Die Assistant-Nachricht wird unverändert angehängt, dazu:

```json
{"role": "tool", "tool_name": "freier_speicher", "tool_call_id": "call_ix1g1dkp",
 "content": "{\"laufwerk\":\"C\",\"frei_gb\":0.8,\"gesamt_gb\":237}"}
```

→ Antwort: `"Der freien Speicherplatz auf C: ist aktuell **0,8 GB**. 📁"`. Funktioniert. Das Modell schreibt
allerdings fehlerhaftes Deutsch, Markdown und Emoji; der Systemprompt muss das unterbinden.

**Befunde für den eigenen Loop**

| Befund | Folgerung |
|---|---|
| Ollama liefert zusätzlich zu `index` eine `id` (`call_…`), die Doku zeigt nur `index` | `tool_name` mitschicken (dokumentiert); `tool_call_id` schadet nicht |
| Das Modell übergibt `"C:"` statt `"C"` | Argumente in jeder Aktion normalisieren und validieren, nie roh verwenden |
| qwen3:4b mit `think:false`: Die Überlegungen landen **im `content`**, in Runde 2 samt `</think>` [gemessen] | Bei Denkmodellen `think:true` setzen und nur `content` anzeigen (dann sauber getrennt, gemessen), oder ein Modell ohne Denkmodus wählen |
| Denken kostet Zeit: qwen3:4b mit `think:true`, eine Runde 1173 Token, 85 s auf 16 vCPU Zen 4 | Auf Laien-Notebooks ohne GPU ein Mehrfaches; Modellwahl und Denk-Budget sind Teil der Bedienbarkeit |
| `/v1/chat/completions` (OpenAI-Weg) liefert `arguments` als String und `Content-Type: application/json` **ohne charset**. `/api/chat` liefert `charset=utf-8` [gemessen] | Aus PowerShell 5.1 den nativen Weg nehmen. Ohne charset droht Umlaut-Salat beim Dekodieren [unbelegt, auf Windows prüfen] |

### 2.2 Codex CLI offline: gemessen

Aufruf (Linux-Container ohne Internet, Ollama 0.40.15, CPU):

```
codex exec --json --skip-git-repo-check --oss --local-provider ollama -c model_provider=ollama \
  -m <modell> --dangerously-bypass-approvals-and-sandbox \
  "Zeige mit dem Befehl df -h den freien Speicher an und fasse in einem Satz zusammen."
```

| Modell | Ergebnis | Eingabe-Token | Zeit |
|---|---|---|---|
| qwen3:0.6b | **kein Befehl ausgeführt**, nur «reasoning» | 3767 | 18 s |
| qwen3:4b | `/bin/sh -lc 'df -h'` ausgeführt; Antwort «Der freie Speicher beträgt aktuell 61,3 GB.» | 8881 (davon 3766 aus dem Cache), Ausgabe 1343 | 2 min 40 s (zwei Anfragen an `/v1/responses`: 1 min 40 s und 1 min 0 s) |
| zum Vergleich: eigener Loop, qwen3:4b | korrekter Tool-Call | 262 (Prompt-Verarbeitung 1.1 s) | Runde 1: 1.1 s Prompt + 21 s Ausgabe |

- Codex meldet bei beiden Modellen: «Model metadata for `qwen3:…` not found. Defaulting to fallback metadata; this can
  degrade performance and cause issues.»
- Die Prompt-Verarbeitung von 3767 Token dauerte mit qwen3:4b 20 s (186 Token/s) auf einem 16-vCPU-Zen-4-Server.
- Ein Notebook ohne GPU ist um ein Mehrfaches langsamer [unbelegt, Grössenordnung].

### 2.3 Andere Agenten

| Agent (Stand) | Windows-Einzeldatei | Signiert | Lizenz | Offline mit Ollama | Bewertung |
|---|---|---|---|---|---|
| Codex CLI 0.167.0 | `codex-x86_64-pc-windows-msvc.exe` 369 MB, oder Paket 202 MB | ja, OpenAI OpCo, LLC [gemessen] | Apache-2.0 | ja [gemessen vom Maintainer und hier] | funktioniert, aber grosser Coding-Prompt (englisch, Shell-zentriert); kleine Modelle versagen; mit `--dangerously-bypass…` läuft jeder Befehl ungeprüft |
| goose 1.58.0 (aaif-goose) | `goose.exe` 172 MB im ZIP (53 MB) | **nein** [gemessen] | Apache-2.0 | Ollama-Provider vorhanden [Q-AG1] | unsigniert und braucht das VC++-Redistributable (Import VCRUNTIME140/MSVCP140) [gemessen] → fällt auf Laien-PCs aus |
| opencode 1.19.5 | `opencode.exe` 212 MB | ja, Anomaly Innovations [gemessen] | MIT | über OpenAI-kompatiblen Provider [unbelegt, nicht getestet] | Verhalten offline beim Start (Modellkatalog) nicht geprüft |
| Cline CLI 3.0.74 | `cline.exe` 143 MB (npm `@cline/cli-windows-x64`) | ja, Cline Bot Inc. [gemessen] | Apache-2.0 | [unbelegt, nicht getestet] | wie opencode |
| Open Interpreter (rust-v0.0.60) | Rust-Neuschrieb; die Release-Dateien heissen `codex-*` (offenbar Codex-Ableger) | nicht geprüft | Apache-2.0 (früher AGPL) | Ziel laut README: «open models» | gleiche Klasse wie Codex |

**Allen gemeinsam:**
- Es sind Coding-Agenten mit freier Shell.
- Keiner hat einen Katalog geprüfter Windows-Reparaturen, deutsche Laienführung oder eine Bestätigungslogik, die eine
  Grossmutter versteht.

### 2.4 Empfehlung Agent: eigener Loop

**Begründung:**
- **Kleine Modelle:** Der Prompt ist 10- bis 30-mal kürzer (260–600 statt 3767–8881 Token) [gemessen].
  - Das zählt auf CPU-Notebooks doppelt, weil die Prompt-Verarbeitung die erste Wartezeit bestimmt.
  - Ein 0.6B-Modell schaffte den Tool-Call im eigenen Loop, in Codex nicht.
- **Sicherheit:** Das Modell wählt nur aus vordefinierten, geprüften Aktionen.
  - Jede ändernde Aktion trägt eine Laien-Erklärung und braucht ein «Ja».
  - Freie PowerShell nur optional für grosse Modelle, mit Bestätigung und Zeitlimit.
- **Robustheit:** Keine Abhängigkeit von Codex-Interna (Modell-Metadaten, `/v1/responses`, Sandbox-Setup, Prompt-Änderungen
  bei jedem Release).
- **Sprache:** Systemprompt, Werkzeugbeschreibungen und Antworten auf Deutsch, in einfacher Sprache.

**Bauregeln** (aus den Messungen abgeleitet):
1. **Zuerst messen, dann fragen:** Ein festes Diagnoseskript sammelt Fakten und gibt dem Modell eine kompakte
   Zusammenfassung (unter ~1500 Token). Inhalte: Speicherplatz, letzte Fehler im Ereignisprotokoll, Update-Status,
   Netzwerk, Drucker, Autostart. Das spart Runden.
2. **Werkzeugkatalog klein halten** (etwa 8–15 Aktionen mit sprechenden deutschen Namen und Beschreibungen). Pro Aktion:
   - Parameter-Schema
   - `aendert_system` (ja/nein)
   - `braucht_admin` (ja/nein)
   - Laien-Text für die Bestätigung
   - Zeitlimit
3. **Argumente validieren und normalisieren** (Beispiel `"C:"` → `C`). Ergebnisse als kurzes JSON, auf ca. 2000 Zeichen
   gekürzt.
4. **Schleife begrenzen:**
   - höchstens ~12 Runden
   - Abbruch bei wiederholt gleichem Aufruf
   - `num_ctx` ausdrücklich setzen
   - `stream:false` für Version 1 (einfacher); Fortschritt in der Oberfläche als Schritt «Ich überlege …»
5. **Denkmodelle:** `think:true` und nur `content` zeigen, oder ein Modell ohne Denkmodus wählen. Die Modellwahl gehört
   in eine eigene Recherche.
6. **Fallstricke in PowerShell 5.1** [Quelle bzw. unbelegt, auf Windows prüfen]:
   - `ConvertTo-Json` immer mit `-Depth 10` (Standard 2 schneidet Tool-Schemas ab).
   - Body als UTF-8-Bytes senden.
   - `Invoke-RestMethod` bzw. `Invoke-WebRequest` immer mit `-UseBasicParsing`. Seit dem Update vom 09.12.2025
     (CVE-2025-54100) fragt `Invoke-WebRequest` sonst interaktiv nach [Q-PS1].
7. **Codex** höchstens als ausdrücklich gewählter «Expertenmodus» für grosse Modelle und kundige Helfer. Er ist signiert,
   Apache-2.0 und läuft offline.

---

## 3. Bedienoberfläche ohne Installation

| Option | Vorteile | Nachteile | Urteil |
|---|---|---|---|
| **PowerShell 5.1 + WinForms** | auf jedem Windows 10/11 vorhanden (.NET Framework 4.8); kein Port, kein Browser, keine URL-ACL, keine Firewall-Abfrage; ein Prozess | DPI: ohne Opt-in vom System hochskaliert, leicht unscharf [Q-UI1]; lange Arbeit blockiert den UI-Thread → Runspace mit synchronisierter Hashtable und `Windows.Forms.Timer` [Q-UI2]; im Constrained Language Mode gesperrt (das trifft aber jede PowerShell-Lösung) | **Empfohlen für Version 1** |
| PowerShell + WPF | schöner, Vektor-DPI | XAML-Aufwand, STA nötig (ab PS 3.0 Standard [Q-UI3]) | möglich, kein klarer Vorteil |
| Lokale Web-Oberfläche: HttpListener + `msedge --app=` | HTML/CSS, schöner Chat | `HttpListener` auf `http://localhost:PORT/` ohne Admin: Belege widersprüchlich [Q-UI4]; Ausweg `TcpListener` auf Loopback; Edge-Schalter `--app`, `--no-first-run`, `--user-data-dir` sind Chromium-Schalter ohne Microsoft-Doku; Erststart-Dialog möglich; Edge ist im EWR unter Windows 11 deinstallierbar [Q-UI5]; Fenster-Schliessen nur per Herzschlag erkennbar | zweite Ausbaustufe |
| WebView2 in WinForms | modernes Rendering im eigenen Fenster; Runtime auf Windows 11 immer, auf Windows 10 «vast majority» [Q-UI6] | SDK-DLLs mitliefern, Loader-DLL, mehr Teile | später prüfen |
| HTA (`mshta.exe`) | ein Fenster aus HTML | VBScript abgekündigt (Phase 2 «around 2027»: standardmässig aus) [Q-UI7]; SAC sperrt `.hta` mit MOTW [Q-SAC2]; Defender empfiehlt Sperren von mshta-Netzverkehr [Q-UI8] | **nein** |

**Fortschritt verständlich anzeigen** [Q-UI9, Q-UI10, Q-UI11]:
- **Startseite:** ein grosser Knopf «Hilfe starten».
- **Danach eine Schrittliste mit Zustand:**
  - wartet: ○
  - läuft: Animation
  - fertig: ✓
  - Problem: ⚠
  - dazu «Schritt 2 von 5» und je Schritt ein Satz in Alltagssprache («Ich schaue nach, wie voll die Festplatte ist»).
- **Prozentbalken** nur, wo die Menge messbar ist (Download, Modell laden). Sonst eine Animation ohne Prozentwert.
  - Ab etwa 10 s eine ehrliche Zeitangabe («dauert meist 1 bis 2 Minuten»).
  - Microsoft: Fortschritt ab ca. 2 s anzeigen, «determinate» nur bei messbarer Menge [Q-UI9].
  - NN/g: Schleife bei 2–10 s, Prozentanzeige ab 10 s; sonst Schrittzahl zeigen, sagen was passiert, Abbruch anbieten [Q-UI10].
- **Vor jeder Änderung** ein eigenes Fenster mit grossen Knöpfen «Ja, machen» und «Nein»:
  - was passiert, warum, ob es rückgängig zu machen ist.
- **Immer sichtbar:** ein Knopf «Abbrechen».
- **Am Ende** eine kurze Zusammenfassung zum Vorlesen oder Abfotografieren (für den Enkel am Telefon).

**Gegenstimme (Subagent-Recherche):** Bevorzugt die Web-Oberfläche in Edge, weil WinForms bei DPI und UI-Thread
heikel sei.
- Beides ist lösbar.
- Der Constrained Language Mode trifft HttpListener genauso (kein erlaubter Kerntyp).
- Entscheidend für Laien ist die geringere Zahl beweglicher Teile.

---

## 4. Start-Hürden

### 4.1 Befunde

| Hürde | Befund | Gegenmittel |
|---|---|---|
| **Mark-of-the-Web (MOTW)** | Explorer «Alle extrahieren» überträgt `Zone.Identifier` auf entpackte Dateien (Zone 3/4). 7-Zip nur mit Option, `tar.exe` und `Expand-Archive` gar nicht [Q-M1]. MOTW lebt nur in NTFS-Streams und geht auf FAT32/exFAT verloren [Q-M2]. `Unblock-File` entfernt den Stream (= «Zulassen» in den Eigenschaften) [Q-M3]. `curl.exe`, `Invoke-WebRequest` und WinHTTP-Werkzeuge setzen keine MOTW [Q-M2, Q-EP1] | Die SSD wird vom Erbauer mit `curl.exe` beschrieben (keine MOTW) und ist exFAT (kann keine tragen). Das **Erbauer-ZIP** selbst vor dem Entpacken über Eigenschaften → «Zulassen» freigeben oder mit `tar -xf` entpacken |
| **ExecutionPolicy** | Windows-Client-Standard `Restricted`. `-ExecutionPolicy Bypass` setzt den Process-Bereich, **Gruppenrichtlinie (MachinePolicy/UserPolicy) geht vor**. Kein Sicherheitsmerkmal [Q-EP1] | Aufruf aus `.cmd` mit `-ExecutionPolicy Bypass`; in `start.ps1` prüfen `Get-ExecutionPolicy -List` und `$ExecutionContext.SessionState.LanguageMode`; bei GPO-Sperre oder `ConstrainedLanguage` eine klare Meldung («Firmen-PC, hier darf der Helfer nicht laufen») |
| **SmartScreen** | Reputationsprüfung für Dateien **mit MOTW**, gestartet über Explorer/ShellExecute [Q-M2] | Startdateien ohne MOTW (siehe oben) |
| **Smart App Control (SAC)** | Windows 11 ab 22H2. Blockiert «unknown, unsigned code»; erlaubt, was die Reputation kennt oder mit einem Zertifikat aus dem Trusted Root Program signiert ist [Q-SAC1]. Prüft Code beim Laden durch OS-Lader und Skript-Engines; zusätzlich sperrt es bestimmte Dateitypen nur mit MOTW (.bat, .cmd, .ps1, .hta, .lnk, .vbs …) [Q-SAC2]. Seit April 2026 (25H2) wieder einschaltbar ohne Neuinstallation [Q-SAC2]. Auf verwalteten Geräten in 48 h aus [Q-SAC3] | **Nur signierte EXE/DLL mitliefern** (Ollama: ja; llama.cpp/llamafile/goose: nein). Ob SAC unsignierte `.ps1` **ohne** MOTW in den Constrained Language Mode zwingt, ist **unbelegt**: erster Test auf echter Hardware. Vorsorglich die eigenen Skripte signieren lassen (SignPath Foundation: kostenlos für OSS, Zertifikat auf die Foundation [Q-SIG1]; Azure Artifact Signing laut Microsoft Q&A nicht für die Schweiz [Q-SIG2]). Kosten oder Verträge: vorbereiten, der Maintainer entscheidet |
| **ASR-Regel «Block untrusted and unsigned processes that run from USB»** | Standardmässig aus; per GPO/PowerShell auch auf Home setzbar [Q-ASR1] | Signierte Binärdateien; Meldung, wenn der Start scheitert |
| **AutoRun** | Für USB-Laufwerke seit Windows 7 aus; per KB971029 ab Februar 2011 auch für XP/Vista über Windows Update [Q-AR1] | Doppelklick ist Pflicht; `LIESMICH.txt` und ein auffällig benanntes `START.cmd` in der Wurzel |
| **UAC** | Erhöhte Prozesse starten im Systemverzeichnis, die Umgebung wird nicht vererbt [Q-UAC1]; zugeordnete **Netzlaufwerke** fehlen im erhöhten Prozess [Q-UAC2]. Lokale USB-Laufwerksbuchstaben sollten sichtbar sein (globaler Namensraum) [unbelegt]. Standardbenutzer müssen ein Admin-Passwort eingeben [Q-UAC3]. «Administrator protection» (25H2, opt-in) nutzt ein separates Konto mit eigenem HKCU/%TEMP% [Q-UAC4] | Start **ohne** Erhöhung. Nur Aktionen mit `braucht_admin` laufen in einem erhöhten Hilfsprozess mit absoluten Pfaden als Argumenten (`%~dp0`/`$PSScriptRoot`). Ohne Admin-Rechte erklären statt scheitern |
| **exFAT oder NTFS** | FAT32 erlaubt höchstens 4 GiB pro Datei, exFAT/NTFS 2^64 [Q-FS1]. Nur NTFS hat ein Journal [Q-FS1]. «Schnelles Entfernen» ist seit Windows 10 1809 Standard [Q-FS2]. macOS liest und schreibt exFAT nativ [Q-FS3] | **exFAT**: Modelle über 4 GB, keine MOTW, auf dem Mac befüllbar. Schreiblast auf der SSD klein halten (Protokolle gebündelt, Temp auf der internen Platte). Dass Ollama auf exFAT unter Windows einwandfrei läuft (mmap): **auf Windows prüfen** |
| **BitLocker To Go** | Einschalten nur Pro/Enterprise/Education; Entsperren mit Passwort auf anderen PCs laut FAQ [Q-BL1]; Home: nicht offiziell belegt | Nicht verwenden: Die SSD trägt keine eigenen Geheimnisse, und ein Passwortdialog überfordert |
| **Windows 10/11 im S-Modus** | `cmd.exe`/`powershell.exe` gesperrt [Q-S1] | Nicht lösbar; in `LIESMICH.txt` nennen |

### 4.2 Konsolenfenster

**Befunde:**
- `powershell -WindowStyle Hidden` blitzt immer kurz auf. Das Issue ist seit 2017 offen [Q-CON1].
- Ist **Windows Terminal Standard** (Windows 11 22H2+, «Windows entscheiden lassen»), wird `-WindowStyle Hidden` gar
  nicht beachtet.
  - Das Issue ist seit 11.02.2022 offen, Backlog.
  - Auch `WScript.Shell.Run …,0` zeigt dann ein Fenster [Q-CON2].
- `conhost.exe --headless` ist undokumentiert und laut Maintainer nicht unterstützt [Q-CON3].
- Dokumentiert ist `CREATE_NO_WINDOW` [Q-CON4]: «new console host is spawned … the first connection packet specifies
  that the window should be invisible» [Q-CON5].
- .NET setzt es mit `ProcessStartInfo.UseShellExecute=$false` und `CreateNoWindow=$true`.

**Folgerung:**
- `START.cmd` darf kurz ein Fenster zeigen; dafür einen freundlichen Titel setzen.
- Alles Weitere wird ohne Fenster gestartet: die Oberfläche, `ollama serve`, `curl.exe` und jedes Diagnose-Werkzeug.
  - Immer über **eine** Hilfsfunktion mit `ProcessStartInfo`: `CreateNoWindow`, Ausgabe umgeleitet und asynchron
    gelesen, `WaitForExit(Timeout)`, `ExitCode` auswerten.
  - Das erklärt auch die Beobachtung auf dem Laien-Notebook: `curl.exe` im eigenen Fenster, ohne zu warten. Ein so
    gestarteter Prozess wartet kontrolliert und zeigt kein Fenster.
- Wirkung unter Windows Terminal als Standard: **auf Windows 11 prüfen**. Laut Spezifikation entsteht kein sichtbares
  Fenster.
- Ganz ohne Aufblitzen geht es nur mit einem kleinen **signierten** Starter (Fenster-Subsystem). Er kostet ein
  Signaturzertifikat, also Entscheid des Maintainers.

### 4.3 Empfohlenes Startmuster (Skizze, auf Windows nicht getestet)

Aufbau der SSD (exFAT, Bezeichnung z. B. `NOTFALL-KI`):

```
X:\START.cmd
X:\LIESMICH.txt
X:\system\start.ps1, ui.ps1, agent.ps1, aktionen\*.ps1
X:\system\ollama\ollama.exe, lib\ollama\...
X:\system\models\blobs\..., manifests\...
```

`START.cmd`:

```bat
@echo off
title Notfall-Helfer startet ... bitte warten
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0system\start.ps1"
```

`start.ps1` (Kern):

```powershell
$root = Split-Path -Parent $PSScriptRoot          # Laufwerksbuchstabe nie speichern
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { <Meldung>; exit 2 }
$sig = Get-AuthenticodeSignature "$root\system\ollama\ollama.exe"
if ($sig.Status -ne 'Valid') { <Meldung: Programmdatei beschaedigt oder gesperrt>; exit 3 }

function Start-OhneFenster([string]$exe, [string]$argumente, [hashtable]$env) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = $argumente
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  if ($env) { foreach ($k in $env.Keys) { $psi.EnvironmentVariables[$k] = $env[$k] } }
  [System.Diagnostics.Process]::Start($psi)
}
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
[void](Start-OhneFenster $ps "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File `"$root\system\ui.ps1`"" $null)
exit 0                                             # Konsole von START.cmd schliesst sich
```

`ui.ps1` startet dann `ollama.exe serve` mit `Start-OhneFenster` und den Umgebungsvariablen aus 1.3. Es wartet, bis
`GET http://127.0.0.1:<port>/api/version` antwortet, und zeigt das Fenster.

---

## 5. Hardware-Erkennung ohne Zusatzsoftware

| Grösse | Zuverlässiger Weg | Fallstricke |
|---|---|---|
| **VRAM** | Registry unter `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\00xx`: zuerst `HardwareInformation.qwMemorySize` (QWORD, Bytes), sonst `HardwareInformation.MemorySize`. Zuordnung zur Karte über `MatchingDeviceId` ↔ `Win32_VideoController.PNPDeviceID` | `Win32_VideoController.AdapterRAM` ist uint32 und über 4 GiB gekappt [Q-HW1]. `qwMemorySize` ist nicht von Microsoft dokumentiert, nur indirekt (Wine bildet es nach, verbreitete Skripte) [Q-HW2]. Datentyp je Treiber QWORD, DWORD oder Binär. Microsoft-Doku zu `MemorySize` sagt «MB», beobachtet werden Bytes [Q-HW3] |
| VRAM genau | DXGI `DedicatedVideoMemory` ist laut Microsoft der genaue Weg [Q-HW4] | nur über Add-Type/C#; iGPUs nutzen geteilten RAM (bis zur Hälfte des RAM) [Q-HW5] → für iGPU mit RAM-Budget rechnen |
| **Massgeblich für die Modellwahl** | Was Ollama selbst sieht: Server-Log-Zeilen `inference compute … library=… total=… available=…` [gemessen]; nach dem Laden `GET /api/ps` → `size` gegen `size_vram` (gemessen: `size_vram:0` = «100% CPU») | Registry dient nur als Vorschau vor dem Start; die Entscheidung «passt das Modell auf die GPU?» erst nach `/api/ps` |
| NVIDIA zusätzlich | `nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits` [Q-HW6] | Fundort bei DCH-Treibern (System32 oder DriverStore) nicht offiziell dokumentiert; nur nutzen, wenn vorhanden |
| **RAM** | `Win32_OperatingSystem.TotalVisibleMemorySize` und `FreePhysicalMemory` (beide **KB**); `Win32_ComputerSystem.TotalPhysicalMemory` (Bytes) [Q-HW7] | `Win32_PhysicalMemory` (Summe Capacity) zeigt verbauten, nicht nutzbaren RAM |
| **CPU (AVX2)** | `IsProcessorFeaturePresent(40)` (PF_AVX2), 39 = AVX, 41 = AVX-512F; erst ab Windows 10 2004 zuverlässig, davor kann `false` «unbekannt» heissen [Q-HW8]. Braucht `Add-Type` (FullLanguage) | **Nur Auskunft:** Ollama und llama.cpp wählen die CPU-Variante selbst, Basis `x64`/`sse42` [gemessen]. Nützlich für die Tempo-Prognose («auf diesem PC dauert eine Antwort etwa …») |
| **Freier Platz** | `Get-Volume -FilePath $PSScriptRoot` (`SizeRemaining`, `FileSystem`); Rückfall `Win32_LogicalDisk.FreeSpace` [Q-HW9] | Laufwerksbuchstaben nie speichern, immer aus `$PSScriptRoot` ableiten; `FileSystem -eq 'FAT32'` → Warnung |

Skizze VRAM (PowerShell 5.1, ohne Admin; Rohfassung aus der Subagenten-Recherche, auf Windows nicht getestet):

```powershell
$cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
foreach ($vc in Get-CimInstance Win32_VideoController) {
  $vram = $null
  foreach ($k in Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object PSChildName -match '^\d{4}$') {
    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    if (-not $p.MatchingDeviceId -or $vc.PNPDeviceID -notlike "$($p.MatchingDeviceId)*") { continue }
    foreach ($n in 'HardwareInformation.qwMemorySize','HardwareInformation.MemorySize') {
      $v = $p.$n
      if ($v -is [byte[]]) { $s=[uint64]0; for($i=$v.Length-1;$i -ge 0;$i--){ $s=$s*256+$v[$i] }; $v=$s }
      elseif ($v -is [int] -and $v -lt 0) { $v = [int64]$v + 4294967296 }
      if ($v) { $vram = [uint64]$v; break }
    }
  }
  [pscustomobject]@{ Name=$vc.Name; Treiber=$vc.DriverVersion; PnP=$vc.PNPDeviceID; VRAM_GB=[math]::Round($vram/1GB,1) }
}
```

---

## 6. Erbauer: GBs zuverlässig auf die SSD

### 6.1 Programme (Ollama-ZIP und Agent-Dateien)

**Gemessene Redirects** (Subagent, 09.11.2026, Header mit `curl -sI`):

| Quelle | Verhalten | Signatur gültig | Range |
|---|---|---|---|
| GitHub Release (`ollama-windows-amd64.zip`) | 302 → `release-assets.githubusercontent.com` (Azure SAS) | ca. 35–60 min | ja (206) |
| Hugging Face `resolve/main/…gguf` | 302 → `us.aws.cdn.hf.co` (CloudFront) | `Expires` +3600 s | ja |
| Ollama-Registry-Blob | GET 307 → `*.r2.cloudflarestorage.com` | `X-Amz-Expires=86400` | ja; HEAD auf die R2-URL 403 |

**BITS (`Start-BitsTransfer`)**
- Anforderungen [Q-DL1, Q-DL2]:
  - Der Server muss HEAD mit Grösse und Range beherrschen.
  - Bei Redirects behält der Job standardmässig die Original-URL.
  - Der Job läuft nur, solange der Besitzer angemeldet ist.
  - `-Dynamic` lässt HEAD weg, beginnt dann aber nach jeder Unterbrechung von vorn.
- Früher scheiterten GitHub-Downloads an der für GET signierten HEAD-Anfrage [Q-DL3].
- Ob BITS nach Ablauf der Signatur neu umleitet: **unbelegt**.

**`curl.exe`**
- Seit Windows 10 Build 17063 in System32 [Q-DL4].
- Gemessen (Linux, curl 8.14.1):
  - Ein **neuer** Aufruf `curl -L -C -` folgt dem Redirect erneut, bekommt also eine frische Signatur, und setzt mit
    206 fort. Die zusammengesetzte Datei ist bytegleich.
  - `--retry` innerhalb **eines** Aufrufs verwirft die Daten des fehlgeschlagenen Versuchs; die Doku sagt dasselbe
    [Q-DL5].
  - Darum die Wiederholschleife in PowerShell führen, nicht curl allein.
- In PowerShell 5.1 ist `curl` ein Alias für `Invoke-WebRequest`, also immer `"$env:SystemRoot\System32\curl.exe"`
  aufrufen.

**`Invoke-WebRequest` (5.1)**
- Kein `-Resume` (kam erst mit 6.1).
- Seit dem 09.12.2025 fragt es ohne `-UseBasicParsing` interaktiv nach [Q-PS1].
- Für grosse Dateien ungeeignet.

**Prüfsummen**
- Ollama veröffentlicht `sha256sum.txt` im Release. Für `ollama-windows-amd64.zip` v0.40.15:
  `9ca74a7ab66ec86870b1eecac7df160df08dc4e3a291ab5d2d59bcf9310221c6` (Subagent gemessen).
- GitHub zeigt seit 03.06.2025 je Asset einen SHA256-Digest [Q-DL6].
- Hugging Face: `x-linked-etag` bzw. `lfs.oid` = SHA256 (nicht das oberste `oid` und nicht `x-xet-hash`).
- Prüfen mit `Get-FileHash -Algorithm SHA256` [Q-DL7].

Skizze:

```powershell
function Hole-Datei([string]$Url, [string]$Ziel, [uint64]$Groesse, [string]$Sha256) {
  $curl = "$env:SystemRoot\System32\curl.exe"
  for ($n = 1; $n -le 100; $n++) {
    if ((Test-Path $Ziel) -and (Get-Item $Ziel).Length -ge $Groesse) { break }
    $p = Start-OhneFenster $curl "-L --fail -C - -sS --connect-timeout 30 --speed-limit 1024 --speed-time 60 --ssl-revoke-best-effort -o `"$Ziel`" `"$Url`"" $null
    while (-not $p.HasExited) { <Fortschritt = (Get-Item $Ziel).Length / $Groesse>; Start-Sleep -Milliseconds 500 }
    if ($p.ExitCode -ne 0) { Start-Sleep -Seconds ([math]::Min(60, 5*$n)) }
  }
  (Get-FileHash $Ziel -Algorithm SHA256).Hash -eq $Sha256
}
```

### 6.2 Modelle

**Weg A, empfohlen: Ollama selbst laden lassen.**
- Ablauf: Erbauer startet `ollama.exe serve` von der SSD, mit `OLLAMA_MODELS` auf die SSD und Internetzugang; dann
  `POST /api/pull {"model":"<name>:<tag>"}`.
- Die gestreamten Zeilen tragen `status`, `digest`, `total`, `completed` [Q-O7]. Daraus entsteht der Prozentbalken.
- Gemessen:
  - Zum Schluss kommen `verifying sha256 digest`, `writing manifest`, `success`.
  - **Fortsetzen funktioniert:** Ein nach 4 s abgebrochener `ollama pull qwen3:1.7b` hinterliess
    `sha256-…-partial` und `-partial-N` (JSON mit `Offset/Size/Completed`, 1'353 von 1'359 MB).
  - Der Neustart setzte bei 100 % für diesen Blob ein und war nach 3 s fertig.

**Weg B, Rückfall: direkt aus der Registry, ohne laufendes Ollama** [gemessen].

Ablage wie vom Maintainer mit 0.40.15 gemessen:

```
GET https://registry.ollama.ai/v2/library/<name>/manifests/<tag>
    Accept: application/vnd.docker.distribution.manifest.v2+json      (auch ohne Accept gleiche Antwort)
→ JSON mit config.digest und layers[].digest/size
  (mediaType ...ollama.image.model / .template / .license / .params)
GET https://registry.ollama.ai/v2/library/<name>/blobs/sha256:<hex>    (307 → R2, -L folgen)
→ speichern als  <OLLAMA_MODELS>\blobs\sha256-<hex>   und SHA256 == <hex> pruefen
Manifest unveraendert speichern als  <OLLAMA_MODELS>\manifests\registry.ollama.ai\library\<name>\<tag>
```

- Ergebnis: Ollama 0.40.15 zeigt das Modell in einem Netz **ohne Internet** sofort in `ollama list` an (`qwen3:0.6b`,
  522 MB) und beantwortet Tool-Calls.
- Ein Gegenversuch `ollama pull` scheiterte an DNS; damit ist belegt, dass der Container wirklich offline war.
- Gleich gemessen mit `qwen3:4b` (2.5 GB). Blobs wie Lizenz und Parameter teilen sich mehrere Modelle.
- Vorbehalt: Die Registry-Schnittstelle ist nicht offiziell dokumentiert (OCI-Distribution-ähnlich) und kann sich ändern.
  Darum ist Weg A Standard.

**Für Laien im Erbauer**
- Eine Fortschrittsanzeige für alles zusammen: Summe aus den Manifest-`size`-Werten bzw. `total`.
- Dazu Restzeit über ein gleitendes Mittel und Klartext («Lade Sprachmodell, 2.1 von 5.2 GB, noch etwa 6 Minuten»).
- Vorher freien Platz auf der SSD prüfen. FAT32 ablehnen.

---

## Offen: unbelegt oder nur auf Windows zu klären

| Nr | Frage | Test |
|---|---|---|
| 1 | Zwingt **Smart App Control** (Enforcement) unsignierte `.ps1` **ohne** MOTW in den Constrained Language Mode? | Windows 11 25H2 mit SAC «Ein»: `START.cmd` von exFAT-SSD, LanguageMode protokollieren; dann signierte Skripte |
| 2 | `CreateNoWindow` unter **Windows Terminal als Standard**: wirklich kein Fenster? | Win 11 24H2/25H2, Standard «Windows entscheiden lassen» |
| 3 | Laufen Ollama 0.40.15 und Modelle von **exFAT** einwandfrei (mmap, Ladezeit, Defender-Scan beim ersten Lesen)? | exFAT- und NTFS-SSD vergleichen, Zeit bis zur ersten Antwort |
| 4 | `USERPROFILE` für `ollama serve` umlenken: landet `.ollama\id_ed25519` auf der SSD? Andere Spuren (`%LOCALAPPDATA%\Ollama` nur bei der App)? | Process Monitor bzw. Dateivergleich vorher/nachher |
| 5 | Vulkan auf **Intel-iGPU** (mit `OLLAMA_IGPU_ENABLE=1`) und **AMD Radeon** schneller als CPU? | Token/s mit und ohne |
| 6 | Umlaute: `Invoke-RestMethod` (5.1) gegen `/api/chat` (mit charset) und `/v1/…` (ohne charset) | Antwort mit «Grüezi» |
| 7 | BITS nach Ablauf der GitHub-Signatur (> 60 min Unterbruch) | nur relevant, falls BITS doch gewünscht |
| 8 | USB-Laufwerksbuchstabe im erhöhten Prozess sichtbar; Verhalten mit «Administrator protection» | erhöhter Hilfsprozess mit `$PSScriptRoot` |
| 9 | Edge `--app` mit `--no-first-run` ohne Erststart-Dialog; HttpListener `http://localhost:PORT/` ohne Admin | nur für eine spätere Web-Oberfläche |
| 10 | opencode und Cline CLI wirklich offline gegen Ollama | nur falls ein fremder Agent doch gewünscht wird |
| 11 | Tempo auf typischer Laien-Hardware (4 Kerne, 8–16 GB, ohne GPU) | Messreihe; die Zahlen hier stammen von einem 16-vCPU-Zen-4-Server und sind eine Obergrenze |

---

## Quellen

Ollama
- [Q-O1] https://docs.ollama.com/gpu (abgerufen)
- [Q-O2] https://docs.ollama.com/windows (abgerufen)
- [Q-O3] Quelltext v0.40.15: https://raw.githubusercontent.com/ollama/ollama/v0.40.15/envconfig/config.go und
  https://raw.githubusercontent.com/ollama/ollama/v0.40.15/discover/runner.go (`filterIntegratedGPUs`, abgerufen)
- [Q-O4] https://docs.ollama.com/context-length (abgerufen)
- [Q-O5] https://docs.ollama.com/capabilities/tool-calling (undatiert, abgerufen)
- [Q-O6] https://docs.ollama.com/api/chat (abgerufen)
- [Q-O7] https://docs.ollama.com/api/pull (abgerufen)
- Release-Assets: https://github.com/ollama/ollama/releases/tag/v0.40.15 (03.11.2026)

llama.cpp, llamafile
- [Q-L1] https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md und
  https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md (abgerufen)
- Release b12233: https://github.com/ggml-org/llama.cpp/releases/tag/b12233 (09.11.2026);
  v0.9.0: https://github.com/ggml-org/llama.cpp/releases/tag/v0.9.0 (04.11.2026)
- [Q-LF1] https://github.com/mozilla-ai/llamafile/blob/main/docs/support.md (abgerufen)
- [Q-LF2] https://github.com/mozilla-ai/llamafile/blob/main/docs/quickstart.md (abgerufen); Release 0.10.6 (15.09.2026)

Agenten
- Codex: https://github.com/openai/codex/releases/tag/rust-v0.167.0 (06.11.2026)
- [Q-AG1] goose: https://github.com/aaif-goose/goose (v1.58.0, 09.11.2026)
- opencode: https://github.com/anomalyco/opencode (v1.19.5, 28.10.2026)
- Cline CLI: https://registry.npmjs.org/@cline/cli-windows-x64 (3.0.74)
- Open Interpreter: https://github.com/openinterpreter/openinterpreter (rust-v0.0.60, 09.11.2026)

Microsoft und Windows
- [Q-MS1] https://learn.microsoft.com/en-us/cpp/windows/deployment-in-visual-cpp (ms.date 28.06.2022, akt. 05.11.2025)
- [Q-GO1] https://pkg.go.dev/os#UserHomeDir (abgerufen)
- [Q-PS1] https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-webrequest?view=powershell-5.1
  (ms.date 20.01.2026; KB5074596)
- [Q-EP1] https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1
  (ms.date 31.08.2026)
- [Q-M1] https://github.com/nmantani/archiver-MOTW-support-comparison (Stand 02.08.2026)
- [Q-M2] https://textslashplain.com/2016/04/04/downloads-and-the-mark-of-the-web/ (E. Lawrence, akt. 01.09.2026)
- [Q-M3] https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file (akt. 16.06.2026)
- [Q-SAC1] https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/overview (ms.date 30.09.2026)
- [Q-SAC2] https://textslashplain.com/2026/04/28/smart-app-control/ (28.04.2026)
- [Q-SAC3] https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appcontrol
  (ms.date 18.08.2026)
- [Q-SIG1] https://signpath.org/ und https://about.signpath.io/product/open-source (abgerufen; Bedingungen vor Antrag prüfen)
- [Q-SIG2] https://learn.microsoft.com/en-us/answers/questions/5810735/cant-create-a-new-trusted-signing-individual-ident
  (Microsoft Q&A, 2026); Preis Basic USD 9.99/Monat: https://azure.microsoft.com/pricing/details/artifact-signing/
- [Q-ASR1] https://learn.microsoft.com/en-us/defender-endpoint/attack-surface-reduction-rules-reference (ms.date 09.09.2026)
- [Q-AR1] https://www.microsoft.com/en-us/msrc/blog/2011/02/usb-autorun/ (17.02.2011)
- [Q-UAC1] https://devblogs.microsoft.com/oldnewthing/?p=3903 (R. Chen, 03.07.2013)
- [Q-UAC2] https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/mapped-drives-not-available-from-elevated-command
- [Q-UAC3] https://learn.microsoft.com/en-us/windows/security/application-security/application-control/user-account-control/how-it-works
- [Q-UAC4] https://specterops.io/blog/2025/06/18/administrator-protection/ (18.06.2025, Drittquelle)
- [Q-FS1] https://learn.microsoft.com/en-us/windows/win32/fileio/filesystem-functionality-comparison (15.04.2025)
- [Q-FS2] https://learn.microsoft.com/windows/client-management/change-default-removal-policy-external-storage-media
- [Q-FS3] https://support.apple.com/guide/disk-utility/dsku19ed921c/mac
- [Q-BL1] https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/faq
- [Q-S1] https://learn.microsoft.com/en-us/windows-hardware/drivers/install/Windows10SDriverRequirements
- [Q-CON1] https://github.com/PowerShell/PowerShell/issues/3028 (offen seit 22.01.2017)
- [Q-CON2] https://github.com/microsoft/terminal/issues/12464 (offen seit 11.02.2022)
- [Q-CON3] https://github.com/microsoft/terminal/issues/13914 (02.09.2022)
- [Q-CON4] https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags
- [Q-CON5] https://github.com/microsoft/terminal/blob/main/doc/specs/%237335%20-%20Console%20Allocation%20Policy.md
  (D. Howett, 16.08.2020, akt. 12.12.2023)
- [Q-UI1] https://learn.microsoft.com/en-us/windows/win32/hidpi/setting-the-default-dpi-awareness-for-a-process
- [Q-UI2] https://learn-powershell.net/2012/10/14/powershell-and-wpf-writing-data-to-a-ui-from-a-different-runspace/ (14.10.2012)
- [Q-UI3] https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1
- [Q-UI4] https://github.com/PowerShell/Polaris/issues/204 (08.11.2019; widersprüchliche Berichte)
- [Q-UI5] https://www.windowscentral.com/software-apps/windows-11/microsoft-will-let-windows-11-users-in-europe-uninstall-edge-bing-and-disable-ads-in-eea-dma
- [Q-UI6] https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution (akt. 02.10.2026)
- [Q-UI7] https://techcommunity.microsoft.com/blog/windows-itpro-blog/vbscript-deprecation-timelines-and-next-steps/4148301
  (22.05.2024); https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features (ms.date 23.09.2026)
- [Q-UI8] https://mc.merill.net/message/MC1266905 (Message-Center-Spiegel, 31.03.2026)
- [Q-UI9] https://learn.microsoft.com/windows/apps/design/controls/progress-controls
- [Q-UI10] https://www.nngroup.com/articles/progress-indicators/ (K. Sherwin, 26.10.2014)
- [Q-UI11] https://www.nngroup.com/articles/wizards/
- [Q-HW1] https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-videocontroller (09.11.2023)
- [Q-HW2] https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/win32u/sysparams.c;
  https://gist.github.com/komelgman/f5fefa1bdd2159cd263d539d4027ab4c (04.12.2023)
- [Q-HW3] https://learn.microsoft.com/en-us/windows-hardware/drivers/display/registering-hardware-information (25.03.2025)
- [Q-HW4] https://learn.microsoft.com/en-us/windows-hardware/drivers/display/retrieving-graphics-memory-numbers (25.03.2025)
- [Q-HW5] https://devblogs.microsoft.com/directx/gpus-in-the-task-manager/ (21.07.2017)
- [Q-HW6] https://docs.nvidia.com/deploy/nvidia-smi/index.html (abgerufen)
- [Q-HW7] https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem (09.11.2023)
- [Q-HW8] https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-isprocessorfeaturepresent
  (18.12.2025)
- [Q-HW9] https://learn.microsoft.com/en-us/powershell/module/storage/get-volume (14.05.2025)
- [Q-DL1] https://learn.microsoft.com/en-us/windows/win32/bits/http-requirements-for-bits-downloads (11.03.2025)
- [Q-DL2] https://learn.microsoft.com/en-us/windows/win32/bits/users-and-network-connections (11.03.2025);
  https://learn.microsoft.com/en-us/windows/win32/api/bits5_0/ne-bits5_0-bits_job_property_id (22.02.2024)
- [Q-DL3] https://forums.powershell.org/t/bits-transfer-with-github/8652 (2017/2018)
- [Q-DL4] https://curl.se/windows/microsoft.html (abgerufen)
- [Q-DL5] https://github.com/curl/curl/tree/master/docs/cmdline-opts (`retry.md`, `continue-at.md`, abgerufen)
- [Q-DL6] https://github.blog/changelog/2025-06-03-releases-now-expose-digests-for-release-assets/ (03.06.2025)
- [Q-DL7] https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash?view=powershell-5.1

**Messumgebung:**
- Ein Linux-Testrechner, Arbeitsordner `/var/tmp/notfall-ki-test-technik/` (nach der Messung entfernt).
- Docker-Netz `--internal` ohne Internet.
- Images `ollama/ollama:0.40.15` (nach der Messung entfernt), `alpine:3`, `python:3.13-slim`.
- Codex `codex-x86_64-unknown-linux-musl` 0.167.0, llama.cpp `llama-b12233-bin-ubuntu-x64`.
