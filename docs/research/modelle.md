Interne Recherche vom 09.11.2026, unverändert bis auf Anonymisierung; die Entscheide stehen in docs/ARCHITECTURE.md.

# Modell-Leiter für die Notfall-KI (1 GB bis 32 GB)

Stand: 09.11.2026. Recherche ohne Download: Grössen aus den Registry-Manifesten, Benchmarks aus Model Cards,
Leaderboards und Issues. Kein Modell wurde lokal ausgeführt.

## Methode und Lesehilfe

- **Grössen** sind gemessen: Summe aller Schichten im Manifest
  (`registry.ollama.ai/v2/library/<name>/manifests/<tag>`, abgerufen 09.11.2026 ca. 21:00 UTC), in GB (10^9 Byte).
  Enthalten sind Gewichte, Vision-Projektor (`proj`) und, wo vorhanden, ein Draft-Modell für spekulatives Dekodieren
  (`draft`). Die Werte stimmen mit den Angaben der Tag-Seiten überein.
- **Fähigkeit `tools`**: alle genannten Modelle stehen in `https://ollama.com/search?c=tools`. Für die empfohlenen
  Tags habe ich zusätzlich die Konfiguration im Manifest gelesen (Renderer, Parser, Mindestversion `requires`).
- **Herkunft der Benchmark-Zahlen**:
  - **H**: Hersteller (Model Card).
  - **D**: Drittmessung durch einen anderen Modellhersteller. Unabhängig vom Modell, aber mit eigenem Harness.
  - **U**: unabhängig (Leaderboard, Artificial Analysis).
  - **B**: Blog, Forum oder Reddit.
- **VRAM-Bedarf** ist gerechnet: Gewichte inkl. Projektor und Draft + KV-Cache für 32k Kontext (fp16) + 0,5 bis 1 GB
  Rechenpuffer. Wo eine Messung existiert, steht sie daneben. Ob Ollama den Vision-Projektor auch ohne Bild in den
  VRAM lädt, habe ich nicht geprüft; ich rechne ihn vorsichtshalber mit.

## 1. Empfohlene Leiter

| Klasse | Modell und Tag | Grösse (gemessen) | Lizenz | VRAM bei 32k / RAM ohne GPU | Warum |
|---|---|---|---|---|---|
| ~1 GB | `lfm3:1.7b-q4_K_M` | 1,10 GB | LFM Open License v1.0 (Sonderlizenz, siehe 4.) | ~2 GB / ab 8 GB RAM | Für lokale Agents gebaut. Mit Abstand die höchsten Tool-Werte bis 4B (H: BFCL V4 71,39, τ³ 68,0, IFBench 73,0). Deutsch offiziell. Kleiner KV-Cache, schnell auf CPU. |
| ~2–3 GB | `qwen3.5:4b-q4_K_M` | 3,32 GB (2,65 + 0,68 Vision) | Apache-2.0 | ~5 GB / ab 8 GB, besser 16 GB | Einziges Kleinmodell, dessen Tool-Werte drei Seiten bestätigen: H TAU2 79,9 / BFCL-V4 50,3; D Liquid BFCL V4 55,12, τ³ 65,98; D NVIDIA Tau2 75,06 (BF16) bzw. 61,74 (Q4_K_M). 201 Sprachen. Hybride Attention, also kleiner KV-Cache. |
| ~5 GB | `qwen3.5:9b-q4_K_M` | 6,55 GB (5,63 + 0,92 Vision) | Apache-2.0 | ~8,4 GB / ab 16 GB (CPU langsam) | H: BFCL-V4 66,1, TAU2 79,1, IFBench 64,5. D Liquid: BFCL V4 62,83, τ³ 67,11. Gleicher Parser und gleiche Prompts wie die Stufen darunter und darüber. |
| ~8–10 GB | `qwen3.5:9b-q8_0` | 10,45 GB (9,53 + 0,92) | Apache-2.0 | ~12,3 GB / ab 24 GB | Dasselbe Modell ohne Q4-Verlust, für 16-GB-Karten ohne genug RAM für die MoE-Stufe. Mit 64k Kontext rund 13,4 GB. |
| ~16–20 GB | `qwen3.8:27b-q4_K_M` (gleiche Blobs wie `27b`, `latest`, `27b-mtp-q4_K_M`) | 17,74 GB (16,81 + 0,93) | Apache-2.0 | ~21 GB (B gemessen: 20 GB bei 32k, 22 GB bei 64k, 26 GB bei 128k) | Stärkstes lokal lauffähiges Agentenmodell. H: Terminal-Bench 2.1 73,0, IFBench 79,5, OSWorld-Verified 84,3. B (Sekundärquelle zu Artificial Analysis): Agentic Index 51. |
| Zwischenstufe MoE (~23 GB) | `qwen3.6:35b-a3b-mtp-q4_K_M` (= `35b`) | 22,62 GB (21,72 + 0,90) | Apache-2.0 | ~24,3 GB; mit Teilauslagerung ab 16 GB VRAM + 32 GB RAM | Nur 3B aktiv: auf 16-GB-Karten mit Auslagerung und auf CPU deutlich schneller als dichte Modelle. H: TB2.0 51,5. D NVIDIA: TB2.1 44,4. Gleicher Parser wie Qwen3.5/3.8. |
| ~28–32 GB | **kein eigenes Modell**, sondern `qwen3.8:27b-q4_K_M` mit `num_ctx` 131072 | 17,74 GB | Apache-2.0 | ~27 GB (B: 26 GB bei 128k) | `qwen3.8:27b-q8_0` (29,98 GB) braucht mit 32k Kontext ~33 GB und passt nicht in eine RTX 5090. Mehr Kontext bringt dem Agenten mehr als Q8. |

Speicherbedarf auf der SSD: Alle empfohlenen Tags zusammen (inklusive `lfm3:1.7b-q8_0` und `gemma4:26b-a4b-it-qat`
aus der CPU-Regel) belegen rund 80 GB.

### Antwort auf die Qwen-Frage

- **Qwen3.8 gibt es nur als 27B.** Die Hugging-Face-API (09.11.2026) listet von Qwen3.8 nur 27B und 27B-FP8
  (05./13.08.2026), Flash-Next (125B-A6B, 24.08.2026) und 2.4T-A95B. Kleinere Modelle oder ein 35B-A3B gibt es nicht.
- Die kleinen Modelle der aktuellen Generation sind deshalb **Qwen3.5** (0.8B, 2B, 4B, 9B, Februar 2026). Qwen3.8
  baut ausdrücklich auf der Qwen3.5-Architektur auf.
- `qwen3.8-flash-next` gibt es in Ollama nur ab 105 GB und unter der Qwen Community License. Für dieses Projekt
  spielt es keine Rolle.
- **Für 32 GB (RTX 5090):** Kein MoE-Modell, das in Ollama auf die Karte passt, erreicht die Agentenwerte von
  qwen3.8:27b:

  | Modell | Terminal-Bench | Artificial Analysis Index |
  |---|---|---|
  | qwen3.8:27b | TB2.1 73,0 (H) | 52 (B) |
  | qwen3.6:35b-a3b | TB2.0 51,5 (H) | 32 (U) |
  | muse-glimmer:30b | TB2.1 51,7 (H) bzw. 52 % (U) | 35 (U) |
  | gemma4:26b | TB2.1 37,2 (D) | 31 (U) |

  Der Vorteil von MoE ist Tempo: qwen3.6:35b-a3b schafft auf der RTX 5090 rund 183 Token/s (B), qwen3.8:27b 29 bis
  75 Token/s (B). Empfehlung: auf der 5090 qwen3.8:27b mit 128k Kontext; qwen3.6:35b als optionaler Schnellmodus.
- **Achtung bei den Tags `nvfp4`, `mxfp8` und `mlx`:**
  - `qwen3.8:27b-nvfp4` und `qwen3.8:27b-mlx` haben denselben Digest (5642e97495e1). Es sind
    Safetensors-Tensorschichten für die MLX-Engine, kein GGUF.
  - `qwen3.8:27b-mxfp8` meldet `runner: mlx`.
  - Ob diese Tags unter Windows mit NVIDIA laufen, habe ich nicht geprüft. Für Windows deshalb die GGUF-Tags
    `q4_K_M` oder `q8_0` verwenden.

## 2. Alternativen je Klasse

### ~1 GB

| Modell und Tag | Grösse | Lizenz | Befund | Urteil |
|---|---|---|---|---|
| `qwen3.5:2b-q4_K_M` | 1,95 GB | Apache-2.0 | H: BFCL-V4 43,6, TAU2 48,8 (mit Thinking). Standardmässig ohne Thinking. Die Card warnt, dass das 2B im Thinking-Modus eher in Denkschleifen gerät. | **Apache-Ersatz** für lfm3, falls die LFM-Lizenz nicht passt |
| `qwen3:1.7b` | 1,36 GB | Apache-2.0 | U (BFCL V4, Stand 12.04.2026): gesamt 28,41 %, Multi-Turn 11,0 %. Template-Bug #14601 (siehe Abschnitt 5) | nicht empfohlen |
| `qwen3.5:0.8b-q8_0` | 1,02 GB | Apache-2.0 | H: BFCL-V4 25,3, TAU2 11,6 | zu schwach, um selbständig zu handeln |
| `lfm2.5-thinking:1.2b` | 0,73 GB | LFM | H: BFCL v3 56,97. Ein Ollama-Maintainer nennt das Modell in #14742 "very bad at tool use" (bei grossen Tool-Sets) | nicht empfohlen |
| `granite4:350m` | 0,71 GB (BF16) | Apache-2.0 | U: BFCL V4 18,98 %, Multi-Turn 2,5 % | nicht empfohlen |

`granite4:1b` ist in Ollama BF16 und 3,27 GB gross, also keine 1-GB-Option.

### ~2–3 GB

- **`lfm3:1.7b-q8_0`** (1,85 GB, LFM)
  - Dasselbe Modell wie die 1-GB-Stufe, mit weniger Quantisierungsverlust.
  - Die bessere Wahl für CPU-Rechner mit 8 bis 16 GB RAM.
- **`granite4.1:3b`** (2,10 GB, Apache-2.0)
  - Kein Thinking, also kurze und vorhersehbare Antworten. Tool-Format JSON im Hermes-Stil. Deutsch offiziell.
  - H: BFCL v3 60,80.
  - Nachteile:
    - Dichte volle Attention: KV-Cache bei 32k ≈ 2,7 GB (gerechnet: 40 Layer × 8 KV-Köpfe × Kopfdim. 64). Der
      Gesamtbedarf liegt damit über dem von qwen3.5:4b.
    - Template als Go-Template (6843 Byte); ob es von #14601 betroffen ist, habe ich nicht geprüft.
- **`qwen3:4b`** (2,50 GB, Apache-2.0)
  - Bester **unabhängiger** Wert unter 4B in der offiziellen Library: U BFCL V4 35,68 %, Multi-Turn 22,12 %
    (gemessen an Qwen3-4B-Instruct-2507). Geringe Formatempfindlichkeit.
  - Nachteile: Der Ollama-Tag ist die Thinking-Variante; Template-Bug #14601.
- **`nemotron-3-nano:4b`** (2,84 GB, NVIDIA Nemotron Open Model License)
  - H: BFCL v3 61,1.
  - Laut Model Card nur Englisch. Für Laien im deutschsprachigen Raum nicht erste Wahl.
- **Nicht in der offiziellen Library:**
  - Nanbeige4-3B-Thinking-2511 (U: BFCL V4 51,40 %, Multi-Turn 51,12 %; bester Wert bis 4B auf dem Berkeley-Board).
  - Es gibt nur Community-Uploads (zum Beispiel `softw8/nanbeige4.1-3b-tools`). Ohne offiziellen Tag und Pflege
    nicht empfohlen.

### ~5 GB

- **`ornith-1.5:9b`** (6,55 GB, MIT)
  - Feinabstimmung von Qwen3.5-9B für agentisches Coding.
  - H: TB2.1 46,2. Zum Vergleich gibt dieselbe Quelle für die Qwen3.5-9B-Basis 21,3 an.
  - Kandidat für einen A/B-Test, weil Terminal-Bench der Shell-Arbeit am nächsten kommt.
  - Vorbehalte: nur Herstellerzahlen; zum 35B-Geschwister ist Parser-Issue #16992 offen.
- **`lfm2.5:8b-a1b-q4_K_M`** (5,16 GB, LFM)
  - MoE mit 1,5B aktiven Parametern: auf CPU klar am schnellsten. H: 146 Token/s auf Ryzen AI Max+ 395 (Unified
    Memory, keine reine CPU).
  - H: τ² Telecom 88,07.
  - Aber Liquid misst selbst nur BFCL V4 48,5 bis 49,7 und damit weniger als lfm3:1.7b.
- **`granite4.1:8b`** (5,35 GB, Apache-2.0)
  - H: BFCL v3 68,27. Kein Thinking.
  - KV-Cache bei 32k ≈ 5,4 GB, also rund 11 GB VRAM. Bei der Grösse deshalb ungünstig.
- **`gemma4:e4b-it-q4_K_M`** (6,58 GB inkl. 0,10 GB Draft, Apache-2.0)
  - Deutsch laut Blogberichten besser als Qwen.
  - Agentisch aber schwächer: H Tau2 42,2; D Liquid BFCL V4 48,25 und τ³ 33,53.
  - Offene Ollama-Fehler #18468 und #18861.

### ~8–10 GB

- **`gemma4:12b-it-q4_K_M`** (8,02 GB inkl. 0,47 GB Draft, Apache-2.0)
  - H: Tau2 69,0, MMMLU 83,4. Beste Mehrsprachigkeit dieser Klasse.
  - Offene Ollama-Fehler:
    - #18275: Schleife bis zum Token-Limit bei 12b.
    - #18468: Parameter mit den Namen `description`, `type`, `properties`, `required` oder `nullable` werden verworfen.
  - Gute Zweitwahl, wenn Deutsch wichtiger ist.
- **`nemotron-3.5-bolt:e4b-q4_K_M`** (7,91 GB inkl. 0,74 GB DFlash-Draft, OpenMDW-1.1)
  - Von NVIDIA auf Gemma-4-E4B nachtrainiert, für mehrstufige Tool-Nutzung.
  - Höchster IHEval (H: 84,79). IHEval misst die Befolgung der Instruktionshierarchie und ist relevant, weil
    Befehlsausgaben Anweisungen enthalten können.
  - In derselben NVIDIA-Tabelle liegt Qwen3.5-4B Q4_K_M bei Tau2 vor Bolt Q4_K_M (61,74 zu 52,32).
  - Kontext höchstens 64K. Deutsch unterstützt. Braucht Ollama ≥ 0.40.10.
- **`bonsai-2:27b`** (8,26 GB, Q2_0 ternär, Apache-2.0)
  - Ternäre Version von Qwen3.8-27B. H: BFCL v3 74,92, IFBench 74,00. Potenziell das stärkste Modell dieser Klasse.
  - Offen ist:
    - ob Q2_0 in Ollama sauber läuft (Ollama-Issue #19388, llama.cpp-Unterstützung erst ab b11556),
    - Thinking ist fest auf `xhigh`,
    - es gibt keine unabhängige Prüfung.
  - **Beobachten, noch nicht einsetzen.**
- **`mimo-v2.6:9b`** (6,55 GB, MIT)
  - Xiaomi-Destillat auf Qwen3.5-9B. H: TB2.1 37,1 (Basis 27,0).
  - Kandidat für einen A/B-Test.

### ~16–20 GB

- **`muse-glimmer:30b-q4_K_M`** (18,16 GB inkl. 1,40 GB Vision, Apache-2.0 mit Usage Policy)
  - Werte:
    - H: TB2.1 51,7, IFBench 77,0, MCP-Atlas 75,5.
    - U (Artificial Analysis, 10.08.2026): TB2.1 52 %, τ³-Banking 24 %.
  - KV-Cache bei 32k nur ~0,48 GB. 128k Kontext passen deshalb auch auf 24-GB-Karten.
  - **Die Usage Policy sagt "not intended for individuals under the age of 18"** und empfiehlt Bestätigung durch einen
    Menschen bei irreversiblen Aktionen.
  - Windows-Issue #19439 (offen): Runner bricht beim Tool-Calling auf der RTX 5090 ab.
  - Zweitwahl für 24 GB.
- **`qwen3.6:27b`** (17,77 GB, Apache-2.0)
  - Vorgänger von qwen3.8. H (Qwen-3.8-Card): TB2.1 63,4. U (Artificial Analysis): TB2.1 61 %.
  - Ausweichmodell, falls Issue #17778 mit qwen3.8 stört.
- **`gemma4:26b-a4b-it-qat`** (15,63 GB, Apache-2.0)
  - MoE mit 3,8B aktiven Parametern. Passt fast ganz in 16 GB.
  - H: Tau2 68,2. D NVIDIA: TB2.1 37,2.
  - Die Drittmessungen widersprechen sich stark: SWE-bench 17,4 bis 57,4, IFBench 47 bis 77.
  - Ausweichmodell für 16-GB-Karten ohne viel RAM und für CPU-Rechner mit 32 GB.
- **Nicht empfohlen: `gpt-oss:20b`** (13,79 GB, Apache-2.0)
  - Issue #17638 (offen): bei langen String-Argumenten in etwa 2 von 5 Fällen HTTP 500. Lange Strings sind genau der
    Fall bei PowerShell-Befehlen.
  - Agentisch schwach: D NVIDIA TB2.1 15,2.

### ~28–32 GB

| Modell und Tag | Grösse | Lizenz | Befund |
|---|---|---|---|
| `qwen3.6:35b-a3b-mtp-q4_K_M` | 22,62 GB | Apache-2.0 | Schnellmodus auf der 5090 |
| `ornith-1.5:35b` | 22,62 GB | MIT | H: TB2.1 67,8 und damit die besten Herstellerzahlen aller MoE-Kandidaten. Keine Drittbestätigung; Parser-Issue #16992 offen. Nur nach eigenem Test |
| `qwen3.8:27b-q8_0` | 29,98 GB | Apache-2.0 | Erst ab rund 40 GB VRAM sinnvoll (Workstation-Karte, zwei GPUs) |
| `gemma4:26b-a4b-it-q8_0` | 28,05 GB | Apache-2.0 | Passt dank kleinem KV-Cache mit 32k knapp in 32 GB. Agentisch aber schwächer als qwen3.8:27b in Q4 |
| `nemotron-3.5-bolt:74b-a9b-iq2` | 24,75 GB | OpenMDW-1.1 | 2-Bit-Experten, experimentell |

## 3. Auswahlregel für den Starter

Grundsätze:

- **Feste Quantisierungs-Tags verwenden, keine schwebenden Tags.** Gleitende Tags wie `gemma4:e4b`, `qwen3.5:0.8b`
  oder `latest` liefern je nach Client unterschiedliche Varianten. Die Tag-Seite zeigt dafür Spannen
  ("6.6GB - 9.5GB"), und die Registry antwortet mit `vary: User-Agent`. Ausserdem wurden diese Tags umgebaut: Sie
  verweisen heute auf Validierungs-Builds mit Draft-Modell (`…-validation-20260930…`).
- **Modelle auf der SSD mitliefern.** Die SSD trägt die fertig gezogenen Modelle (`OLLAMA_MODELS` auf die SSD
  zeigen lassen). So bleibt alles offline und die Grössen stehen fest.
- **Ollama-Version festlegen: mindestens 0.40.13.** Das Manifest von lfm3 verlangt `requires: 0.40.13`, Bolt
  0.40.10, qwen3.8 0.32.12. Aktuell ist 0.40.15 vom 03.11.2026.
- **`num_ctx` immer ausdrücklich setzen.** Laut Ollama-Doku ist der Standard bei weniger als 24 GiB VRAM nur 4k.
  Für Agents empfiehlt die Doku mindestens 64000.

```text
GPU messen:  nvidia-smi --query-gpu=memory.total,memory.free --format=csv
V = memory.total der grössten NVIDIA-GPU in GB minus 1,5 GB (Windows-Desktop, Reserve)
R = installierter Arbeitsspeicher in GB

NVIDIA vorhanden:
  V >= 28        -> qwen3.8:27b-q4_K_M          num_ctx 131072   (RTX 5090, ~27 GB)
  V >= 21        -> qwen3.8:27b-q4_K_M          num_ctx 32768    (24-GB-Karten, ~21 GB)
  V >= 13:
      R >= 32    -> qwen3.6:35b-a3b-mtp-q4_K_M  num_ctx 65536    (16-GB-Karten, Teilauslagerung)
      sonst      -> qwen3.5:9b-q8_0             num_ctx 65536    (~13,4 GB, ganz auf der GPU)
  V >= 8,5       -> qwen3.5:9b-q4_K_M           num_ctx 65536 bei V >= 9,5, sonst 32768
  V >= 5         -> qwen3.5:4b-q4_K_M           num_ctx 32768    (6- und 8-GB-Karten, ~5 GB)
  V >= 2,5       -> lfm3:1.7b-q8_0              num_ctx 32768
  sonst          -> wie ohne GPU

Ohne NVIDIA (AMD/Intel bis zur eigenen Messung wie CPU behandeln):
  R >= 48        -> qwen3.6:35b-a3b-mtp-q4_K_M  (3B aktiv)
  R >= 32        -> gemma4:26b-a4b-it-qat       (3,8B aktiv, 15,6 GB)
  R >= 16        -> qwen3.5:4b-q4_K_M, wenn die Geschwindigkeitsprobe >= 8 Token/s ergibt,
                    sonst lfm3:1.7b-q8_0
  R >= 8         -> lfm3:1.7b-q8_0
  sonst          -> lfm3:1.7b-q4_K_M (nur Diagnose, keine Reparatur ohne Rückfrage)

Danach immer messen, nicht annehmen:
  1. Modell laden, `ollama ps` lesen: Spalte PROCESSOR muss "100% GPU" zeigen
     (Ausnahme: bewusste Teilauslagerung bei qwen3.6:35b).
  2. Probe-Generation (z. B. 64 Token) messen. Liegen die Token/s unter einer Schwelle,
     eine Stufe tiefer gehen.
  3. Ein Probe-Tool-Call gegen das eigene Schema. Scheitert er zweimal, eine Stufe tiefer gehen.
```

Hinweise zur Regel:

- **Dichte Modelle nie auf der CPU.** Die Schwellen ohne GPU folgen der Zahl der *aktiven* Parameter, nicht der
  Gesamtgrösse. Ein dichtes 27B bringt auf der CPU nur wenige Token/s (B: dichtes 32B auf Ryzen AI 9 HX 370 rund
  3,5 Token/s). Qwen3.5-4B schafft auf der CPU rund 8,5 Token/s, Qwen3.5-9B rund 6,5 Token/s (B, EPYC mit 16
  Kernen). Mit Thinking kostet ein Schritt dann leicht Minuten.
- **Die 8-GB-Klasse ist eine Abwägung.** Gewählt ist qwen3.5:4b, weil es ganz auf die GPU passt. qwen3.5:9b-q4_K_M
  mit 16k Kontext und leichter Auslagerung ist der Gegenkandidat für einen A/B-Test.
- **Stufen unter 4B nur mit Rückfrage reparieren lassen.** Für die Zielgruppe "Oma" sollten diese Stufen im Modus
  "diagnostizieren und vor jeder Änderung fragen" laufen. Kein Kleinmodell ist unabhängig als stabiler
  Mehrschritt-Agent belegt (siehe 5.).
- **KV-Cache halbieren.** `OLLAMA_FLASH_ATTENTION=1` mit `OLLAMA_KV_CACHE_TYPE=q8_0` halbiert den KV-Cache. Das
  lohnt sich bei Granite und Ministral; bei den hybriden Qwen-Modellen ist der Gewinn klein.

### KV-Cache bei 32k (fp16), gerechnet aus config.json

| Modell | Layer mit vollem KV | KV-Köpfe × Kopfdim. | KV bei 32k |
|---|---|---|---|
| LFM3-1.7B | 6 von 24 (13 Faltungs-, 5 Sliding-Window-Layer mit Fenster 256) | 4 × 128 | 0,40 GB |
| Qwen3.5-2B | 6 von 24 | 2 × 256 | 0,40 GB |
| Qwen3.5-4B | 8 von 32 | 4 × 256 | 1,07 GB |
| Qwen3.5-9B | 8 von 32 | 4 × 256 | 1,07 GB |
| Qwen3.8-27B | 16 von 64 (`full_attention_interval` 4) | 4 × 256 | 2,15 GB |
| Qwen3.6-35B-A3B | 10 von 40 | 2 × 256 | 0,67 GB |
| Granite 4.1 3B | 40 von 40 | 8 × 64 | 2,68 GB |
| Granite 4.1 8B | 40 von 40 | 8 × 128 | 5,37 GB |

## 4. Lizenzen

| Lizenz | Modelle in der Leiter oder als Alternative | Bedingungen für Weitergabe und Nutzung |
|---|---|---|
| Apache-2.0 | Qwen3.5, Qwen3.6, Qwen3.8 (laut Card), Gemma 4 (laut HF-API, Gemma Terms gelten nicht mehr), Granite 4.1, gpt-oss | Lizenztext und NOTICE beilegen, Änderungen kennzeichnen. Kommerziell frei |
| Apache-2.0 mit Usage Policy | Muse Glimmer | Policy: nicht für unter 18-Jährige gedacht; verbietet unter anderem unlizenzierte Berufsausübung; empfiehlt menschliche Bestätigung bei irreversiblen Aktionen |
| MIT | Ornith 1.5, MiMo-V2.6, GLM-4.7-Flash | Copyright- und Lizenzhinweis beilegen |
| **LFM Open License v1.0** | lfm3, lfm2.5 | Weitergabe "in any medium" erlaubt, mit Lizenzkopie und erhaltenen Hinweisen. **Kommerzielle Nutzung ist nur lizenziert, solange die nutzende Organisation unter 10 Mio. USD Jahresumsatz bleibt (Abschnitt 5).** Ausnahme: gemeinnützige Organisationen bei nicht-kommerzieller Nutzung. Ein Open-Source-Projekt darf lfm3 auf der SSD weitergeben. Setzt aber zum Beispiel ein grösserer IT-Dienstleister die SSD kommerziell ein, ist er nicht lizenziert. Deshalb gibt es den Apache-Ersatz `qwen3.5:2b-q4_K_M` |
| OpenMDW-1.1 | Nemotron 3.5 Bolt, Nemotron 3.5 Lightning | Nutzung ohne Einschränkung. Bei Weitergabe Lizenzkopie und Hinweise beilegen. Die Rechte enden bei einer Patent- oder Urheberrechtsklage |
| NVIDIA Nemotron Open Model License | nemotron-3-nano | Kommerziell erlaubt. Lizenzkopie und Notice "Licensed by NVIDIA Corporation under the NVIDIA Nemotron Model License" beilegen |

Wer eine reine Apache-Leiter will, ersetzt `lfm3:1.7b-q4_K_M` und `lfm3:1.7b-q8_0` durch `qwen3.5:2b-q4_K_M`
(1,95 GB). Alle übrigen Stufen sind schon Apache-2.0.

## 5. Stabilität kleiner Modelle beim Tool-Calling

**Zur eigenen Beobachtung (qwen3:1.7b bildete den ersten Aufruf ohne Pflichtfeld):** Dafür gibt es zwei belegte
Erklärungen.

1. **Das Modell ist schwach bei mehrstufigen Aufrufen.** U, BFCL V4 (Stand 12.04.2026):
   - Qwen3-1.7B: gesamt 28,41 %, Multi-Turn 11,0 %.
   - In der Kategorie "Miss Param" (fehlende Angaben erkennen) erreicht es 12,0 %.
2. **Ollama hat einen offenen Template-Fehler: Issue #14601** (seit 03.03.2026, letzter Kommentar 10.10.2026).
   - Seit v0.14.0-rc0 rendern Library-Templates mit `{{ .Function }}` die Tool-Definition als Go-Struct statt als JSON.
   - Dabei gehen Schlüssel verloren, und die `required`-Liste erscheint als `[city]`.
   - Bestätigt ist das für qwen3:8b und qwen2.5. Für qwen3:1.7b ist es wahrscheinlich, weil es dasselbe Template
     verwendet, aber nicht nachgemessen.
   - Gemessene Wirkung bei qwen2.5:0.5b: exakte Argumente 31 von 40 statt 39 von 40.
   - **Qwen3.5, 3.6 und 3.8 sind nicht betroffen.** Ihre Manifeste nutzen eingebaute Renderer und Parser
     (`renderer: qwen3.5` bzw. `qwen3.8`), kein Go-Template.

**Rangfolge der kleinen Modelle nach Beleglage:**

| Rang | Modell | Beleg |
|---|---|---|
| 1 | `qwen3.5:4b` | Drei unabhängige Quellen stimmen überein: Qwen, Liquid und NVIDIA (siehe Abschnitt 1). NVIDIA misst auch die Q4_K_M-Variante: Tau2 61,74, BFCL-v3 70,56, ToolSandbox 74,51 |
| 2 | `lfm3:1.7b` | Höchste Zahlen (H), aber nur vom Hersteller. In Ollama für Windows erst seit 0.40.13 vom 28.10.2026, also ohne Felderfahrung. Die Card rät selbst von "complex multi-step reasoning" ab |
| 3 | `qwen3:4b` | Einziger unabhängig gemessener Wert ≥ 35 % unter 4B in der offiziellen Library. Template-Bug #14601 |
| 4 | `granite4.1:3b` | H BFCL v3 60,8, ohne Thinking. Ollamas eigener Go-Parser antwortete bei einem abgeschnittenen Aufruf sauber mit HTTP 200 statt 500 (#19493, laut Teilrecherche) |

**Nachweislich instabil** (U, Multi-Turn):

| Modell | Multi-Turn |
|---|---|
| llama3.2:1b | 0 % |
| llama3.2:3b | 4 % |
| granite4:350m | 2,5 % |
| qwen3:0.6b | 3,6 % |

Dazu kommen `qwen3.5:0.8b` (H: TAU2 11,6) und `functiongemma:270m` (laut Card nur für einzelne Aufrufe, mit
Feinabstimmung).

**Folgerungen für den Agenten-Harness** (gilt für alle Grössen):

- **Tool-Calls prüfen und gezielt wiederholen.** Jeden Aufruf gegen das JSON-Schema prüfen. Schlägt die Prüfung
  fehl, mit einem Formathinweis neu anfragen. In #16383 ergab die Wiederholung mit Hinweis 35 von 60 gültigen
  Aufrufen, ohne Hinweis 18 von 60.
- **HTTP 500 und leere Antworten als Formatfehler behandeln, nicht als Absturz.** Dazu gehören:
  - #16383: Qwen3.5/3.6-Parser antwortet mit 500.
  - #17638: gpt-oss.
  - #19439: RTX 5090 unter Windows.
  - PR #18624: Ein Tool-Call, der im Thinking beginnt, geht verloren.
- **Das Tool-Schema klein und neutral halten.** Zum Beispiel `run_powershell(command: string)`, `ask_user(question)`,
  `finish(summary)`.
  - Keine Parameter mit den Namen `name`, `type`, `description`, `properties`, `required` oder `nullable`
    (Gemma-Renderer #18468, Mistral-Parser #16932).
- **Tool-Ausgaben kürzen.** Dazu `num_ctx` gross genug setzen. Bei qwen3.8 tritt sonst #17778 auf: "no user query
  found", wenn beim Kürzen des Kontexts die User-Nachricht wegfällt.

## 6. Quellen

Alle abgerufen am 09.11.2026. Das Datum in Klammern ist das Datum der Quelle.

**Selbst gemessen oder selbst gelesen:**

- Ollama-Suche, Fähigkeit tools: https://ollama.com/search?c=tools
- Tag-Seiten: https://ollama.com/library/qwen3.8/tags, …/qwen3.6/tags, …/qwen3.5/tags, …/lfm3/tags, …/gemma4/tags,
  …/granite4.1/tags, …/lfm2.5/tags, …/muse-glimmer/tags, …/nemotron-3.5-bolt/tags, …/bonsai-2/tags
  sowie die weiteren in Abschnitt 2 genannten Modelle
- Manifeste und Konfigurations-Blobs:
  `https://registry.ollama.ai/v2/library/<name>/manifests/<tag>`, `…/blobs/<config-digest>` (gemessen 09.11.2026,
  ca. 21:00 UTC)
- Ollama-Doku Kontextlänge: https://docs.ollama.com/context-length (ohne Datum)
- Ollama-Release v0.40.15 (03.11.2026): https://github.com/ollama/ollama/releases
- Ollama-Issues, Status "offen" am 09.11.2026 selbst geprüft:
  - https://github.com/ollama/ollama/issues/14493 (27.02.2026)
  - https://github.com/ollama/ollama/issues/14601 (03.03.2026)
  - https://github.com/ollama/ollama/issues/16383 (01.06.2026)
  - https://github.com/ollama/ollama/issues/17638 (09.08.2026)
  - https://github.com/ollama/ollama/issues/17778 (15.08.2026)
  - https://github.com/ollama/ollama/issues/18468 (15.09.2026)
  - https://github.com/ollama/ollama/pull/18624 (24.09.2026)
  - https://github.com/ollama/ollama/issues/18916 (10.10.2026)
  - https://github.com/ollama/ollama/issues/19439 (31.10.2026)
- Qwen3.8-27B Model Card und config.json (05.08.2026): https://huggingface.co/Qwen/Qwen3.8-27B
- Qwen-Modelle über die API: https://huggingface.co/api/models?author=Qwen&search=Qwen3.8 (ebenso für 3.6 und 3.5)
- Qwen3.5-9B Card (27.02.2026, enthält auch die Werte für 4B): https://huggingface.co/Qwen/Qwen3.5-9B
- Qwen3.5-2B Card (28.02.2026, enthält 0.8B, Qwen3-1.7B und Qwen3-4B-2507): https://huggingface.co/Qwen/Qwen3.5-2B
- Qwen3.5-4B und Qwen3.6-35B-A3B config.json: https://huggingface.co/Qwen/Qwen3.5-4B,
  https://huggingface.co/Qwen/Qwen3.6-35B-A3B
- LFM3-1.7B Card, config.json und LICENSE (Oktober 2026): https://huggingface.co/LiquidAI/LFM3-1.7B
- Nemotron-3.5-Bolt-E4B Card (05.10.2026): https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-BF16
- Muse Glimmer Card und USAGE_POLICY.md (09.08.2026): https://huggingface.co/meta-models/Muse-Glimmer-30B
- Lizenzfelder über die HF-API für Gemma 4 E4B, 12B, 26B-A4B und 31B, Granite 4.1, Ministral 3, MiMo-V2.6,
  Ornith-1.5, gpt-oss-20b, LFM2.5-8B-A1B, GLM-4.7-Flash, Nemotron-3-Nano-4B und Nemotron-3.5-Lightning:
  `https://huggingface.co/api/models/<org>/<modell>`
- Granite 4.1 3B config.json: https://huggingface.co/ibm-granite/granite-4.1-3b
- BFCL V4 Leaderboard und Rohdaten (Stand 12.04.2026): https://gorilla.cs.berkeley.edu/leaderboard.html,
  https://gorilla.cs.berkeley.edu/data_overall.csv
- Qwen3.8-27B Hardwaretest, VRAM und Token/s, llama.cpp Q4_K_S (B, 17.08.2026):
  https://www.hardware-corner.net/qwen3-8-27b-hardware-tests/

**Aus den Teilrecherchen übernommen, nicht einzeln nachgeprüft:**

Artificial Analysis:
- https://artificialanalysis.ai/articles/muse-glimmer (10.08.2026)
- https://artificialanalysis.ai/articles/nemotron-3-5-lightning-launch (11.08.2026)
- https://artificialanalysis.ai/articles/sub-32b-open-weights (13.04.2026)
- Qwen3.8 im AA-Index nur über die Presse (B): https://gigazine.net/gsc_news/en/20260818-qwen3-8-27b-performance/
  (18.08.2026)

Model Cards:
- Qwen: https://huggingface.co/Qwen/Qwen3.6-27B (April 2026), https://huggingface.co/Qwen/Qwen3.6-35B-A3B (April 2026)
- Gemma 4: https://huggingface.co/google/gemma-4-E4B-it, https://huggingface.co/google/gemma-4-31B-it
- Granite: https://huggingface.co/ibm-granite/granite-4.1-8b (29.04.2026)
- Liquid: https://huggingface.co/LiquidAI/LFM2.5-8B-A1B (28.05.2026), https://www.liquid.ai/blog/lfm3 (27.10.2026)
- Ornith: https://huggingface.co/ornith-ai/Ornith-1.5-9B, https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B
  (18.08.2026)
- MiMo: https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B (September 2026)
- NVIDIA: https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16 (März 2026)
- Bonsai: https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf (September 2026)

Lizenzen:
- OpenMDW-1.1 (27.05.2026): https://openmdw.ai/license/1-1/
- NVIDIA Nemotron Open Model License (15.12.2025):
  https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license

Ollama-Issues (Status laut Teilrecherche):
- https://github.com/ollama/ollama/issues/14742
- https://github.com/ollama/ollama/issues/16932
- https://github.com/ollama/ollama/issues/16992
- https://github.com/ollama/ollama/issues/18275
- https://github.com/ollama/ollama/issues/18861
- https://github.com/ollama/ollama/issues/19388
- https://github.com/ollama/ollama/issues/19493

Blogs (B):
- https://zenn.dev/toki_mwc/articles/rtx5090-qwen36-35b-a3b-llmacpp-bench (28.06.2026, 183 Token/s auf der 5090)
- https://www.glukhov.org/post/2026/01/choosing-best-llm-for-ollama-on-16gb-vram-gpu/ (09.03.2026, 16-GB-Karte)
- https://bkataru.github.io/igllama/showcase/qwen35-small/ (Qwen3.5 auf der CPU, ohne Datum)
- https://runaihome.com/blog/cpu-vs-gpu-llm-inference-home-lab-2026/ (10.08.2026)
- https://hackernoon.com/running-nvidia-nemotron-35-bolt-e4b-without-a-gpu-benchmark-results (28.10.2026)

## 7. Was nicht verifiziert ist

- **Nichts lokal ausgeführt.**
  - Kein Modell wurde heruntergeladen oder unter Windows mit Ollama getestet.
  - Alle Qualitätsaussagen stammen aus Benchmarks, nicht aus PowerShell-Aufgaben.
  - Vor dem Festschreiben braucht es eine eigene Testreihe: je Stufe mindestens 50 Läufe mit echten
    Reparaturaufgaben, Thinking ein und aus, Zählung gültiger Aufrufe und korrekt *unterlassener* Aufrufe.
- **Fast keine unabhängigen Messungen.**
  - Für lfm3, Qwen3.5-4B/9B, Qwen3.8-27B und die meisten Kandidaten gibt es keine unabhängigen BFCL- oder
    τ²-Werte. Das Berkeley-Leaderboard steht seit 12.04.2026 still und führt keines dieser Modelle.
  - Die Leaderboards von tbench.ai und swebench.com werden per JavaScript geladen und waren nicht auslesbar.
- **Herstellerzahlen sind untereinander kaum vergleichbar.** Beispiele:
  - Qwen3.5-4B BFCL V4: 50,3 (Qwen) gegenüber 55,12 (Liquid).
  - Gemma 4 26B SWE-bench Verified: 17,4 (Qwen) gegenüber 57,4 (NVIDIA).
  - Die Rangfolge innerhalb einer Tabelle ist belastbarer als ein Vergleich über Tabellen hinweg.
- **Welche Variante bekommt der echte Ollama-Client?**
  - Mit Ollama-User-Agent verlangt die Registry eine signierte Anmeldung (401). Ich habe deshalb nur die Variante
    gemessen, die ohne Anmeldung ausgeliefert wird (GGUF, `runner: llamacpp`).
  - Für die festen Quantisierungs-Tags erwarte ich dieselben Blobs, belegt ist das nicht.
- **Ob der Vision-Projektor ohne Bildeingabe VRAM belegt**, ist nicht geprüft. Die Bedarfswerte rechnen ihn mit
  (0,2 bis 1,4 GB).
- **Ob die `nvfp4`-, `mxfp8`- und `mlx`-Tags unter Windows mit NVIDIA laufen**, ist nicht geprüft.
- **Wie sich die Denktiefe von qwen3.8 über Ollama steuern lässt**, ist nicht geprüft. Gemeint ist
  `reasoning_effort` (Standard `xhigh`, sehr gesprächig); unklar ist, ob und wie Ollama das über `think` abbildet.
- **CPU-Geschwindigkeit der MoE-Modelle** (qwen3.6:35b-a3b, gemma4:26b) auf typischen Desktop- oder Laptop-CPUs:
  nur Schätzungen und Blogwerte. Die RAM-Schwellen der CPU-Regel sind deshalb vorläufig.
- **Auffälliger Wert im Blog:** Bei hardware-corner ist die RTX 5090 ab 16k Kontext langsamer als die 4090
  (32k: 28,96 gegenüber 42,17 Token/s). Die Ursache ist ungeklärt; der Wert stammt aus llama.cpp, nicht aus Ollama.
- **Deutsch-Qualität:** Für keinen Kandidaten habe ich einen deutschspezifischen Benchmark gefunden. Dass Gemma
  beim Deutschen besser ist als Qwen, ist nur ein Reddit-Eindruck.
- **Weitere offene Punkte:**
  - Q2_0-Laufzeit von `bonsai-2` in Ollama.
  - Ob das Granite-Template von #14601 betroffen ist.
  - Unterstützung von AMD- und Intel-GPUs in Ollama unter Windows.
  - Status der Issues, die nur die Teilrecherche gelesen hat.
