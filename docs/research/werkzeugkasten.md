Interne Recherche vom 09.11.2026, unverändert bis auf Anonymisierung; die Entscheide stehen in docs/ARCHITECTURE.md.

# Werkzeugkasten: geprüfte Reparaturaktionen für den Offline-Agenten

Stand 09.11.2026. Entwurf aus der Recherche; maschinenlesbar in `werkzeugkasten-entwurf.json` im selben Ordner.
Alle PowerShell-Befehle sind mit dem PowerShell-Parser geprüft, aber noch auf keinem Windows-Gerät ausgeführt worden (siehe Abschnitt 8).

## 1. Kurzfassung

- **93 Aktionen in 19 Bereichen**: 27 nur lesende Diagnosen, 63 ändernde Aktionen (davon 2 reine Sicherungen und 1 Diagnose mit vorübergehender Änderung), 3 Anleitungen für den Benutzer.
- Risiko: 73 niedrig, 18 mittel, 2 hoch. 26 Aktionen verlangen eine Bestätigung (alles Löschende oder Verschiebende, alles mit Neustart, alles mittel/hoch).
- Offline: 88 voll, 4 teilweise (Wirkung erst mit Netz), 1 nur mit Internet.
- **Kernsatz für Version 1: 20 Aktionen** (Feld `stufe`). Der Rest ist ausformuliert, aber zweite Priorität.
- **Das Modell wählt, das Skript handelt.** Die Bestandsaufnahme liefert Befund-Codes; jeder Code nennt 1-7 Kandidaten-Aktionen. Dem Modell werden nur diese Kandidaten angeboten, nicht 93 Werkzeuge. Parameter stammen ausschliesslich aus der Erkennung (Positivliste).
- Jede ändernde Aktion hat Sicherung, Rückweg (oder eine Begründung, warum keiner), und eine Erfolgsprüfung, die genau `True` oder `False` liefert.
- Ausgewertet werden nur Exit-Codes, Objekte, Registry und XML, nie lokalisierter Text. Der Katalog ist damit auf jede Windows-Sprache ausgelegt (auf echten Geräten noch zu bestätigen).
- **"Allgemeiner Fehler" bei ping** wird sprachunabhängig als Code 11050 erkannt; eine eigene Eingrenzung unterscheidet defekten Netzwerkstapel, fehlende Schnittstelle und lokalen Filter. Für den lokalen Filter benennen `net.wfp_drop_events` und `net.wfp_audit_trace` den blockierenden WFP-Filter, ohne die Firewall abzuschalten.
- **Defender-for-Endpoint-Isolation** ist erkennbar (Hinweise, kein eindeutiger Schalter) und führt zum Stopp aller Netzwerk-Reparaturen.
- Wichtigste Grenzen: kein Windows Update, keine Treiber, kein Online-DISM ohne Netz; DISM offline nur mit passendem Abbild; Defender-Signaturen nur so frisch wie das Paket auf der SSD; Firmengeräte nur lesen; S Mode und App Control können PowerShell bzw. Add-Type sperren.

## 2. Grundprinzip

Kleine lokale Modelle sind unzuverlässig: Sie erfinden Befehle, verwechseln Parameter und schlagen zu grosse Hämmer vor (im Praxisfall, der zu diesem Projekt führte, empfahl ein lokales Modell `netsh advfirewall reset`). Deshalb trennt der Werkzeugkasten Entscheidung und Ausführung:

| Rolle | Aufgabe | Darf nicht |
|---|---|---|
| Bestandsaufnahme (Skript) | misst in unter 30 s, nur lesend, liefert Fakten und Befund-Codes | ändern |
| Modell | erklärt dem Benutzer, wählt EINE Aktion aus den Kandidaten, wählt Parameter aus der Erkennung | Befehle schreiben, Werte erfinden |
| Ausführer (Skript) | prüft Zulässigkeit, holt Bestätigung, sichert, führt aus, prüft Erfolg, protokolliert | ohne Sicherung ändern |
| Benutzer | bestätigt, liefert Wissen (WLAN-Passwort, richtige Uhrzeit), führt Anleitungen aus | - |

Der Ablauf je Aktion (im JSON unter `konventionen.ablauf`):

1. Bestandsaufnahme ausführen (nur lesend), JSON an das Modell.
2. Modell wählt EINE Aktion aus den Kandidaten der Befund-Codes und gegebenenfalls Parameter aus der Erkennung.
3. Ausführer prüft: Aktion existiert, Parameter in Positivliste, Adminrechte, Kontext (system/benutzer), Verbot bei MANAGED_DEVICE bzw. STOPP-Befunden.
4. Bestätigung des Benutzers einholen, wenn "bestaetigung" = true (Text: Titel, Risiko, Dauer, Neustart, Rückweg).
5. "vorher_ausfuehren" abarbeiten (z. B. Wiederherstellungspunkt, Netzwerk-Sicherung).
6. Sicherungsbefehle ausführen. Scheitert die Sicherung, wird die Reparatur NICHT ausgeführt.
7. Reparatur ausführen, Ausgabe und Exit-Codes protokollieren.
8. Erfolgsprüfung ausführen (bei nach_neustart = true erst nach dem Neustart). Ergebnis ist genau ein [bool]: True = erledigt, False = nicht erledigt.
9. Bei False: Rückweg anbieten (falls umkehrbar), dann nächste Kandidaten-Aktion. Nach zwei erfolglosen Reparaturen im selben Bereich: anhalten und Befund für einen Menschen zusammenfassen.
10. Jede Aktion als eine JSON-Zeile ins Protokoll auf der SSD (Zeit, id, Parameter, Ergebnis, Sicherungsordner).

## 3. Konventionen für den Ausführer

| Thema | Regel |
|---|---|
| Laufzeit | Windows PowerShell 5.1, 64-Bit-Prozess (C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe), Start mit -NoProfile. Kein PowerShell 7 (Checkpoint-Computer, WinRT-Aufrufe fehlen dort). |
| Fehler | Der Ausführer setzt $ErrorActionPreference = "Stop". Jede Ausnahme bricht den Schritt ab. |
| Hilfsfunktionen | Gemeinsame, getestete Funktionen (Präfix `Nk`) im JSON-Feld `hilfsfunktionen`; Tabelle in Anhang B. |
| `$NkRoot` | Wurzel des Werkzeugkastens auf der SSD; Pfad ohne Leerzeichen. |
| `$NkBackup` | Neuer, leerer Ordner je Aktionslauf auf der SSD (z. B. <NkRoot>\sicherung\20261109-213000_net.flush_dns); bleibt nach Neustarts erhalten. |
| `$NkParam` | Hashtable der Parameter. Werte stammen ausschliesslich aus der Ausgabe der Erkennung (Positivliste); das Modell wählt, erfindet aber keine Werte. |
| `$NkStart` | [datetime] Startzeit der Aktion; der Ausführer speichert sie für Prüfungen nach einem Neustart. |
| `$NkToolBuildDate` | [datetime] Erstellungsdatum des Werkzeugkastens (Plausibilität der Uhr). |
| Erfolgsprüfung | Der Befehl liefert als letzte Ausgabe genau einen Wahrheitswert. Der Ausführer wertet nur diesen aus (nicht Text). |
| Sprache | Konsolenausgaben (netsh, ipconfig, sfc, w32tm, auditpol, chkdsk) sind lokalisiert. Ausgewertet werden nur Exit-Codes, Objekte, Registrywerte und XML. |
| Kodierung | Skripte nur ASCII oder UTF-8 mit BOM; Windows PowerShell 5.1 liest UTF-8 ohne BOM als ANSI. |
| Pfade | SSD-Pfade ohne Leerzeichen (vereinfacht die Übergabe an Konsolenprogramme in PowerShell 5.1). |
| Kontext | Aktionen mit `kontext = benutzer` (HKCU, Ton, Explorer, Standarddrucker) laufen im Konto des angemeldeten Benutzers. Hat ein Laie mit den Adminrechten eines anderen Kontos bestätigt, meldet die Bestandsaufnahme `ELEVATED_OTHER_USER`; dann diese Aktionen ohne Erhöhung starten. |
| Ausführungsrichtlinie | Start mit `-ExecutionPolicy Bypass` nur für den eigenen Prozess; Microsoft beschreibt die Richtlinie ausdrücklich nicht als Sicherheitsgrenze [108]. Besser: Skripte signieren, weil App Control/AppLocker unsignierte Skripte in den Constrained Language Mode zwingen (dann scheitern `Add-Type` und WinRT) [109]. |
| Bestätigung | Pflicht, wenn `bestaetigung = true`. Text für den Benutzer aus Titel, Risiko, Dauer, Neustart und Rückweg; Antwort "Ja" ausdrücklich. |
| Wiederherstellungspunkt | Vor jeder Aktion mit Risiko mittel/hoch (`vorher_ausfuehren`). |
| Stopp | Befund-Codes mit Stopp-Hinweis (MANAGED_DEVICE, DISK_UNHEALTHY, MDE_ISOLATION_SUSPECT, WHEA_ERRORS) beenden Reparaturen im Bereich. |
| Abbruchgrenze | Zwei erfolglose Reparaturen im selben Bereich: anhalten, Befund für einen Menschen zusammenfassen. |

## 4. Bestandsaufnahme (Diagnose zuerst)

Das Skript läuft immer zuerst, nur lesend, ohne Netz, und liefert eine Zeile kompaktes JSON. Jede Messung steht einzeln in try/catch; ein Fehler erscheint unter `err` und bricht nichts ab. Ziel ist eine Ausgabe unter etwa 1500 Token (Bauregel aus `technik.md`); das Beispiel unten hat rund 3500 Zeichen (etwa 1200 Token). Wird es grösser, kürzt der Ausführer zuerst `ev.top` und Adapter, die nicht "Up" sind.

| Block | Inhalt | Warum zuerst |
|---|---|---|
| `meta` | Zeit, Adminrechte, Benutzer des Prozesses und der Shell (erkennt "als anderer Admin gestartet"), UI-Sprache, PS-Version, 64 Bit | Rechte und Konto entscheiden, welche Aktionen überhaupt laufen dürfen |
| `os` | Version, Build.UBR, Uptime, ausstehender Neustart (CBS, WU, PFRO), Schnellstart, Domäne/Entra/MDM | Ausstehender Neustart und Uptime lösen viele Fälle ohne Reparatur; Firmengeräte nur lesen |
| `hw` | Hersteller, Modell, RAM, Akku | Einordnung (Laptop, RAM) |
| `disk` | Volumes (frei, Zustand, Werkzeug-SSD markiert), physische Datenträger (Zustand) | Voller Datenträger ist eine häufige Ursache; die Werkzeug-SSD wird markiert und nie bereinigt |
| `net` | Adapter mit IPv4, DHCP, festen DNS; Gateway; Tests lo/gw/ext/dns/tcp als Codes; Proxy; hosts; Firewall-Profile; VPN; NRPT; fremde Winsock-Anbieter und NDIS-Filter; Defender for Endpoint; Funk | Häufigste Laienmeldung; die Tests liefern Codes statt Text |
| `sec` | Defender-Modus, Echtzeitschutz, Signaturalter, Manipulationsschutz, andere Virenschutzprogramme, Funde 30 Tage | Schadsoftware-Verdacht und abgeschalteter Schutz |
| `wu` | Update-Dienste, letztes Update, Pause, Richtlinie, Fehler 30 Tage | Update-Zustand, Fehler, Richtlinien |
| `svc` | Wichtige Dienste, die nicht laufen | Gestoppte Kerndienste erklären ganze Problemklassen |
| `time` | Zeit, Zeitzone, NTP-Konfiguration, Plausibilität | Falsche Uhr bricht HTTPS und Anmeldungen |
| `ev` | Zähler bekannter Fehlermuster und die 15 häufigsten Fehler (7 Tage) | Fakten über Abstürze, Platten, Treiber |
| `prn` | Spooler, Drucker, Aufträge | Drucker sind ein Dauerbrenner |
| `aud` | Tongeräte, Lautstärke, stumm | Stumm/leise ist häufigste Tonursache |
| `disp` | Grafikkarten mit Treiber und Problemcode | Basistreiber, Problemcodes |
| `dev` | Geräte mit Fehlerstatus (max. 15) | Geräte mit Problemcode |
| `prof` | Profilpfad, temporäres Profil, .bak-Schlüssel, Temp-Ordner | Temporäres Profil, fehlender Temp-Ordner |
| `appx` | Store-Apps mit Status ungleich Ok | Kaputte Store-Apps |
| `start` | Anzahl Autostart-Einträge | Autostart-Last |
| `rp` | Computerschutz an, letzter Wiederherstellungspunkt | Sicherheitsnetz vorhanden? |
| `bl` | BitLocker-Status und Art der Schutzvorrichtungen (nie Schlüssel) | Schlüssel bereithalten, bevor ein Neustart nötig wird |
| `flags` | Befund-Codes, siehe "befund_codes" | Befund-Codes: die Brücke zum Katalog |

Beispielausgabe (gekürzt formatiert; Muster des Praxisfalls: Ping meldet "Allgemeiner Fehler", nur DNS geht hinaus, Gerät in Defender for Endpoint):

```json
{"v":"0.1","meta":{"ts":"2026-11-09T19:05:12","utc":"2026-11-09T18:05:12","admin":true,"user":"PC\\anna","shell_user":"PC\\anna","ui":"de-CH","ps":"5.1.26100.2161","x64":true},"os":{"name":"Windows 11","edition":"Professional","ver":"24H2","build":"26100.4652","lang":"de-CH","boot":"2026-11-09T06:14:02","uptime_h":12.9,"pending_reboot":[],"fast_startup":true,"domain":false,"entra":false,"mdm":false},"hw":{"maker":"LENOVO","model":"21K5","ram_gb":31.7,"ram_free_gb":18.2,"battery":true},"disk":{"vol":[{"l":"C","tool":false,"fs":"NTFS","size_gb":475.8,"free_gb":212.4,"free_pct":44.6,"health":"Healthy","op":"OK"},{"l":"E","tool":true,"fs":"exFAT","size_gb":931.5,"free_gb":880.1,"free_pct":94.5,"health":"Healthy","op":"OK"}],"phys":[{"name":"SAMSUNG MZVL2512","media":"SSD","bus":"NVMe","health":"Healthy","op":"OK","size_gb":512}]},"net":{"ad":[{"n":"Ethernet 3","d":"Intel(R) Ethernet Controller I225-V","st":"Up","hw":true,"wifi":false,"vpn":false,"speed":"2.5 Gbps","dhcp":"Enabled","ip4":["192.168.1.20/24"],"dns_manual":null},{"n":"WLAN","d":"Intel(R) Wi-Fi 6E AX211 160MHz","st":"Disconnected","hw":true,"wifi":true,"vpn":false,"speed":"0 bps","dhcp":"Enabled","ip4":[],"dns_manual":null}],"gw":"192.168.1.1","test":{"lo":"SUCCESS","gw":"GENERAL_FAILURE","ext":"GENERAL_FAILURE","dns":"RESOLVED","tcp":"BLOCKED_LOCAL"},"profile":[{"n":"Netzwerk","ifc":"Ethernet 3","cat":"Private","v4":"LocalNetwork"}],"proxy":{"user":0,"server":null,"pac":null,"winhttp":"DIRECT"},"hosts":0,"fw":[{"p":"Domain","on":"True","out":"Allow"},{"p":"Private","on":"True","out":"Allow"},{"p":"Public","on":"True","out":"Allow"}],"vpn":[],"split":0,"nrpt":0,"lsp":[],"ndis":[],"mde":{"onboarded":true,"sense":"Running","org":"00000000-0000-0000-0000-000000000000","iso_hint":false},"radio":[{"k":"WiFi","s":"On"},{"k":"Bluetooth","s":"On"}]},"sec":{"mode":"Normal","rtp":true,"sig_age_d":0,"sig_ver":"1.441.120.0","tamper":true,"qscan_age":1,"av":["Windows Defender"],"threats30d":0},"wu":{"svc":[{"n":"wuauserv","st":"Stopped","start":"Manual"},{"n":"BITS","st":"Stopped","start":"Manual"},{"n":"CryptSvc","st":"Running","start":"Automatic"},{"n":"UsoSvc","st":"Running","start":"Automatic"}],"last_kb":"KB5066835","last_kb_date":"2026-10-15","paused_until":null,"policy":false,"fail_30d":0},"svc":[],"time":{"local":"2026-11-09T19:05:14","tz":"W. Europe Standard Time","ntp_type":"NTP","ntp_server":"time.windows.com,0x9","w32time":"Running","implausible":false,"future_ev":false},"ev":{"days":7,"known":{"unexpected_shutdown":0,"bugcheck":0,"disk":0,"ntfs":0,"tdr":0,"whea":0,"svc_fail":2,"dns_timeout":14,"profile_temp":0,"app_crash":1,"app_hang":0},"top":[{"src":"Microsoft-Windows-DNS-Client","id":1014,"n":14,"last":"2026-11-09T19:01:40"}]},"prn":{"spooler":"Running","printers":[{"n":"Microsoft Print to PDF","def":true,"offline":false,"net":false,"jobs":0,"stuck":0}]},"aud":{"endpoints":[{"n":"Lautsprecher (Realtek(R) Audio)","st":"OK"}],"vol_pct":40,"mute":false},"disp":[{"n":"Intel(R) Graphics","drv":"32.0.101.6913","date":"2026-06-20","st":"OK","cm_err":0,"res":"2880x1800"}],"dev":[],"prof":{"profile":"C:\\Users\\anna","temp_profile":false,"bak_keys":[],"temp":"C:\\Users\\anna\\AppData\\Local\\Temp\\","temp_ok":true},"appx":[],"start":{"entries":9},"rp":{"on":false,"last":null},"bl":{"status":"FullyEncrypted","prot":"On","pct":100,"protectors":["Tpm","RecoveryPassword"]},"flags":["PING_GENERAL_FAILURE","TCP_BLOCKED_LOCAL","ONLY_DNS_WORKS","MDE_ONBOARDED","MDE_ISOLATION_SUSPECT","RESTORE_OFF","BITLOCKER_ON"],"err":{},"ms":14210}
```

Das vollständige Skript steht in Anhang A und im JSON unter `bestandsaufnahme.skript`.

### Befund-Codes und Kandidaten

| Code | Bedeutung | Kandidaten (in dieser Reihenfolge) | Stopp |
|---|---|---|---|
| `NOT_ADMIN` | Bestandsaufnahme lief ohne Adminrechte; einige Messungen fehlen. | - | - |
| `ELEVATED_OTHER_USER` | Mit Adminrechten eines anderen Kontos gestartet: HKCU-, Ton-, Explorer- und Drucker-Standard-Aktionen müssen im Konto des angemeldeten Benutzers laufen. | - | - |
| `MANAGED_DEVICE` | Gerät gehört zu einer Domäne, zu Entra ID oder einer Geräteverwaltung (Firma, Schule). | - | Nur lesen und Befund für die IT zusammenfassen; keine Netz-, Proxy-, DNS- oder Update-Einstellungen ändern. |
| `PENDING_REBOOT` | Windows wartet auf einen Neustart. | `sys.restart` | - |
| `UPTIME_LONG` | Seit über 7 Tagen kein echter Neustart. | `sys.restart`, `boot.fast_startup_off` | - |
| `C_FREE_CRITICAL` | Unter 2 GB frei auf dem Systemlaufwerk. | `disk.report`, `disk.clean_user_temp`, `disk.clean_windows_temp`, `disk.clean_delivery_optimization`, `disk.move_crash_dumps`, `disk.hibernation_off`, `disk.open_storage_settings` | - |
| `C_FREE_LOW` | Unter 10 GB oder 10 % frei. | `disk.report`, `disk.clean_user_temp`, `disk.clean_windows_temp`, `disk.clean_delivery_optimization`, `disk.open_storage_settings` | - |
| `VOLUME_NOT_HEALTHY` | Ein Laufwerk meldet Dateisystemfehler. | `fs.health`, `fs.scan_online` | - |
| `DISK_UNHEALTHY` | Ein physischer Datenträger meldet einen schlechten Zustand. | `fs.health` | Zuerst Daten sichern lassen; keine Aktion mit Neustart, kein chkdsk. |
| `DISK_ERRORS_EVENTS` | Datenträger- oder NTFS-Fehler im Ereignisprotokoll. | `fs.health` | - |
| `NO_ADAPTER_UP` | Keine Netzwerkkarte ist verbunden. | `net.enable_adapter`, `wifi.report`, `net.restart_adapter` | - |
| `ADAPTER_DISABLED` | Eine physische Netzwerkkarte ist ausgeschaltet. | `net.enable_adapter` | - |
| `NET_SERVICE_STOPPED` | Ein Netzwerkdienst (DHCP, DNS-Client, NLA, NSI) läuft nicht. | `sys.restart` | - |
| `APIPA_ADDRESS` | Adresse 169.254.x.x: kein DHCP-Server erreicht. | `net.renew_dhcp`, `net.restart_adapter` | - |
| `NO_DEFAULT_GATEWAY` | Kein Standard-Gateway (Router) eingetragen. | `net.renew_dhcp`, `net.restart_adapter` | - |
| `LOOPBACK_FAILS` | Ping auf 127.0.0.1 scheitert: Netzwerkstapel defekt. | `net.triage_general_failure`, `net.reset_winsock`, `net.reset_tcpip` | - |
| `PING_GENERAL_FAILURE` | Ping meldet "Allgemeiner Fehler": Windows sendet das Paket gar nicht. | `net.triage_general_failure`, `net.mde_isolation_check`, `net.wfp_drop_events` | - |
| `GW_UNREACHABLE` | Router antwortet nicht (Zeitüberschreitung). | `net.restart_adapter`, `net.renew_dhcp`, `wifi.report` | - |
| `TCP_BLOCKED_LOCAL` | Verbindungsaufbau lokal verweigert (WSAEACCES 10013): Filter auf dem Rechner. | `net.triage_general_failure`, `net.mde_isolation_check`, `net.wfp_drop_events`, `net.firewall_report` | - |
| `ONLY_DNS_WORKS` | DNS antwortet, aber weder Ping noch TCP gehen hinaus. | `net.mde_isolation_check`, `net.wfp_drop_events`, `net.vpn_report` | - |
| `DNS_FAILS_NET_OK` | Internet per IP erreichbar, aber DNS antwortet nicht. | `net.dns_auto`, `net.flush_dns`, `net.hosts_reset` | - |
| `MANUAL_DNS` | Fest eingetragene DNS-Server auf einer aktiven Karte. | `net.dns_auto` | - |
| `PROXY_USER_SET` | Benutzer-Proxy oder PAC-Skript aktiv. | `net.proxy_user_reset` | - |
| `PROXY_WINHTTP_SET` | System-Proxy (WinHTTP) gesetzt. | `net.proxy_system_reset` | - |
| `HOSTS_MODIFIED` | hosts-Datei enthält aktive Einträge. | `net.hosts_reset` | - |
| `VPN_ADAPTER` | VPN-Adapter vorhanden. | `net.vpn_report` | - |
| `SPLIT_DEFAULT_ROUTE` | Routen 0.0.0.0/1 und 128.0.0.0/1 (typisch für VPN). | `net.vpn_report` | - |
| `NON_MS_LSP` | Fremde Winsock-Anbieter im Katalog. | `net.reset_winsock` | - |
| `NON_MS_NDIS_FILTER` | Fremde Netzwerkfilter an Adaptern (VPN, Virenschutz, Virtualisierung). | `net.vpn_report`, `net.wfp_drop_events` | - |
| `FIREWALL_OFF` | Windows-Firewall in mindestens einem Profil aus. | `net.firewall_report`, `net.firewall_enable` | - |
| `FIREWALL_OUTBOUND_BLOCK` | Firewall sperrt ausgehend standardmässig. | `net.firewall_report` | - |
| `FIREWALL_SERVICE_STOPPED` | Firewall- oder Filter-Dienst (mpssvc, BFE) läuft nicht. | `sys.restart` | - |
| `MDE_ONBOARDED` | Gerät ist in Microsoft Defender for Endpoint eingebunden (Firmenschutz). | `net.mde_isolation_check` | - |
| `MDE_ISOLATION_SUSPECT` | Verdacht: Gerät wurde über Defender for Endpoint vom Netz isoliert. | `net.mde_isolation_check` | Keine Netzwerk-Reparaturen. Benutzer an die IT verweisen, die das Gerät schützt (OrgId nennen). |
| `WLAN_RADIO_OFF` | WLAN-Funk ist aus. | `wifi.radio_on` | - |
| `WLANSVC_STOPPED` | WLAN-Dienst läuft nicht. | `wifi.restart_service` | - |
| `DEFENDER_RTP_OFF` | Defender-Echtzeitschutz aus, obwohl Defender zuständig ist. | `defender.report`, `defender.realtime_on` | - |
| `DEFENDER_SIG_OLD` | Virensignaturen älter als 7 Tage. | `defender.update_from_ssd` | - |
| `DEFENDER_THREATS` | Defender meldete in 30 Tagen Bedrohungen. | `defender.report`, `defender.quick_scan`, `defender.offline_scan` | - |
| `NO_ACTIVE_AV` | Kein aktiver Virenschutz erkennbar. | `defender.report` | - |
| `TIME_IMPLAUSIBLE` | Systemzeit ist sicher falsch. | `time.report`, `time.set_timezone`, `time.set_manual` | - |
| `W32TIME_NOSYNC` | Automatische Zeitsynchronisierung aus. | `time.enable_sync` | - |
| `WU_SERVICE_DISABLED` | Ein Update-Dienst ist deaktiviert. | `wu.service_defaults` | - |
| `WU_ERRORS` | Update-Fehler in den letzten 30 Tagen. | `wu.report`, `wu.restart_services`, `wu.reset_components` | - |
| `SPOOLER_STOPPED` | Druckdienst läuft nicht. | `print.report`, `print.restart_spooler` | - |
| `PRINTER_OFFLINE` | Standarddrucker steht auf "offline verwenden". | `print.set_online` | - |
| `PRINT_JOBS_STUCK` | Druckaufträge hängen. | `print.restart_spooler`, `print.clear_queue` | - |
| `AUDIO_SERVICE_STOPPED` | Audiodienst läuft nicht. | `audio.restart_services` | - |
| `AUDIO_NO_ENDPOINT` | Kein funktionierendes Tongerät. | `audio.report`, `audio.restart_device` | - |
| `AUDIO_MUTED` | Standard-Tongerät ist stumm geschaltet. | `audio.unmute` | - |
| `AUDIO_VOLUME_LOW` | Lautstärke unter 5 %. | `audio.unmute` | - |
| `DISPLAY_TDR` | Grafiktreiber wurde von Windows neu gestartet (Ereignis 4101). | `display.report` | - |
| `DEVICE_ERRORS` | Geräte mit Problemcode. | `hw.problem_devices` | - |
| `TEMP_PROFILE` | Hinweis auf temporäres Profil. | `profile.report` | - |
| `TEMP_DIR_MISSING` | Temp-Ordner fehlt. | `profile.fix_temp_folder` | - |
| `APPX_BROKEN` | Store-App(s) mit Status ungleich Ok. | `apps.report` | - |
| `MANY_AUTOSTARTS` | Mehr als 15 Autostart-Einträge. | `boot.startup_list`, `boot.report` | - |
| `RESTORE_OFF` | Computerschutz für das Systemlaufwerk aus. | `sys.enable_restore` | - |
| `BITLOCKER_ON` | Systemlaufwerk ist mit BitLocker geschützt. | `bitlocker.recovery_key_hint` | - |
| `BITLOCKER_SUSPENDED` | BitLocker ist angehalten (Schutz aus). | `bitlocker.report` | - |
| `CRASHES` | Unerwartete Abschaltungen oder Bluescreens. | `events.crashes` | - |
| `WHEA_ERRORS` | Hardwarefehler gemeldet (WHEA). | `events.crashes` | Hardwareproblem; Werkzeugkasten kann nur beschreiben. |
| `APP_CRASHES` | Viele Programmabstürze. | `events.crashes`, `apps.report` | - |

## 5. Katalog nach Bereichen

Legende: Art "Diagnose*" = Diagnose mit vorübergehender, automatisch zurückgenommener Änderung. "(Kern)" = Kernsatz für Version 1. Befehle, Sicherung, Rückweg und Erfolgsprüfung jeder Aktion stehen im JSON.

### 5.1 Grundlagen: Neustart und Wiederherstellungspunkte (`sys`, 5 Aktionen)

Neustart und Wiederherstellungspunkte sind das Sicherheitsnetz für alle anderen Aktionen. Vor jeder Aktion mit Risiko mittel oder hoch erstellt der Ausführer einen Wiederherstellungspunkt. `Checkpoint-Computer` gibt es nur in Windows PowerShell 5.1 und erlaubt einen Punkt je 24 Stunden; ein jüngerer Punkt wird deshalb wiederverwendet. Auf manchen Windows-11-Geräten ist der Computerschutz ab Werk aus; dann schaltet ihn `sys.enable_restore` ein (maximal 5 % des Laufwerks).

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `sys.restart` (Kern) | Computer neu starten | Restart the computer | Reparatur | niedrig | nein | ja | ja | ja | ja | 1-5 min | [1] [2] |
| `sys.restore_status` | Wiederherstellungspunkte anzeigen | Show restore points | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | < 5 s | [3] [4] |
| `sys.enable_restore` | Computerschutz (Wiederherstellungspunkte) einschalten | Turn on System Protection (restore points) | Reparatur | niedrig | ja | nein | nein | ja | ja | < 10 s | [5] [6] |
| `sys.create_restore_point` (Kern) | Wiederherstellungspunkt erstellen | Create a restore point | Sicherung | niedrig | ja | nein | nein | ja | ja | 1-3 min | [7] [4] |
| `sys.rollback_restore_point` | Computer auf einen früheren Stand zurücksetzen | Roll back to a restore point | Reparatur | hoch | ja | ja | ja | ja | ja | 15-45 min | [8] [3] [4] |

### 5.2 Netzwerk und Internet (`net`, 21 Aktionen)

Netzwerk ist der grösste Bereich, weil "kein Internet" die häufigste Laienmeldung ist und die Ursachen weit auseinanderliegen: ausgeschaltete Karte, kein DHCP, falscher DNS, Proxy-Rest, manipulierte hosts-Datei, defekter Winsock-Katalog, VPN-Reste, Firewall- oder Fremdfilter, bis hin zur Isolation durch Defender for Endpoint. Die Reihenfolge ist immer: messen (`net.test_connectivity`, `net.triage_general_failure`), dann die kleinste passende Änderung. Vor `net.reset_tcpip` und `net.dns_auto` sichert `net.backup_ip_config` die festen Einstellungen auf zwei Wegen: mit dem von Microsoft beschriebenen `netsh -c interface dump` und als JSON je Adapter-GUID, weil der netsh-Weg scheitert, wenn sich Adapternamen ändern [[9]].

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `net.test_connectivity` (Kern) | Internetverbindung prüfen | Check the internet connection | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | 5-10 s | [9] [10] [11] [12] |
| `net.triage_general_failure` (Kern) | "Allgemeiner Fehler" beim Ping eingrenzen | Narrow down "General failure" on ping | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | 5-10 s | [9] [10] [13] [14] |
| `net.enable_adapter` (Kern) | Ausgeschaltete Netzwerkkarte einschalten | Turn a disabled network adapter back on | Reparatur | niedrig | ja | nein | nein | ja | ja | < 10 s | [15] [16] |
| `net.restart_adapter` (Kern) | Netzwerkkarte aus- und wieder einschalten | Restart the network adapter | Reparatur | niedrig | ja | nein | nein | ja | ja | 10-30 s | [17] |
| `net.renew_dhcp` (Kern) | Neue IP-Adresse vom Router holen | Get a new IP address from the router | Reparatur | niedrig | ja | nein | nein | ja | ja | 5-60 s | [18] [19] |
| `net.flush_dns` (Kern) | Gespeicherte Internet-Adressen leeren (DNS-Cache) | Clear the DNS cache | Reparatur | niedrig | ja | nein | nein | ja | ja | < 5 s | [20] [18] |
| `net.dns_auto` | DNS-Server wieder automatisch vom Router beziehen | Get DNS servers automatically again | Reparatur | mittel | ja | nein | ja | ja | ja | < 5 s | [21] |
| `net.backup_ip_config` | Netzwerk-Einstellungen sichern | Back up network settings | Sicherung | niedrig | ja | nein | nein | ja | ja | < 15 s | [9] [22] [23] |
| `net.reset_winsock` | Windows-Netzwerkschnittstelle zurücksetzen (Winsock) | Reset Winsock | Reparatur | mittel | ja | ja | ja | ja | ja | 1 min + Neustart | [24] [9] |
| `net.reset_tcpip` | TCP/IP-Einstellungen auf Werkszustand setzen | Reset TCP/IP to defaults | Reparatur | mittel | ja | ja | ja | ja | ja | 1 min + Neustart | [9] [22] |
| `net.restore_static_ip` | Feste IP-Einstellungen zurückspielen | Restore static IP settings | Reparatur | mittel | ja | nein | ja | ja | ja | < 30 s | [9] [21] [25] |
| `net.proxy_user_reset` | Proxy-Einstellung des Benutzers ausschalten | Turn off the user proxy setting | Reparatur | niedrig | nein | nein | nein | ja | ja | < 5 s | [26] |
| `net.proxy_system_reset` | System-Proxy (WinHTTP) ausschalten | Reset the system proxy (WinHTTP) | Reparatur | niedrig | ja | nein | nein | ja | ja | < 5 s | [26] |
| `net.hosts_reset` | hosts-Datei auf Werkszustand setzen | Reset the hosts file to default | Reparatur | mittel | ja | nein | ja | ja | ja | < 5 s | [27] |
| `net.firewall_report` | Firewall-Zustand anzeigen | Show firewall status | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 10 s | [28] [29] [30] |
| `net.firewall_enable` | Windows-Firewall wieder einschalten | Turn Windows Firewall back on | Reparatur | niedrig | ja | nein | nein | nein | ja | < 5 s | [31] [32] |
| `net.wfp_drop_events` | Herausfinden, welcher Filter Netzwerkverkehr verwirft | Find out which filter drops network traffic | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | 10-60 s | [33] [13] [34] |
| `net.wfp_audit_trace` | Blockierte Verbindungen kurz protokollieren | Briefly log blocked connections | Diagnose* | niedrig | ja | nein | nein | ja | ja | 15-30 s | [35] [36] [37] [38] [39] |
| `net.mde_isolation_check` (Kern) | Prüfen, ob die Firma das Gerät vom Netz getrennt hat (Defender for Endpoint) | Check whether the device was isolated by Defender for Endpoint | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | 5-15 s | [14] [40] [41] [42] [43] |
| `net.vpn_report` | VPN-Programme und ihre Reste anzeigen | Show VPN software and leftovers | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 15 s | [44] [25] [45] [46] |
| `net.vpn_disable_adapter` | Übrig gebliebenen VPN-Adapter ausschalten | Disable a leftover VPN adapter | Reparatur | mittel | ja | nein | ja | ja | ja | < 10 s | [47] [15] |

Nicht umkehrbar, mit Begründung:

- `net.firewall_enable`: Bewusst kein Rückweg im Werkzeugkasten: er würde den Schutz wieder abschalten. Die Sicherung firewall.wfw kann eine Fachperson mit "netsh advfirewall import" einspielen.

#### "Allgemeiner Fehler" bei ping

Microsoft beschreibt "General Failure" beim Ping auf die eigene Adresse als "keine gültige Schnittstelle", also Hardware- oder Stapelproblem [9]. Der Status heisst in der API `IP_GENERAL_FAILURE` = 11050 [10]; die .NET-Aufzählung `IPStatus` kennt den Wert nicht [11], deshalb wertet `Test-NkPing` den Zahlenwert aus. In der Praxis erzeugt auch ein WFP-Filter, der ausgehende Pakete verwirft, genau diese Meldung. `net.triage_general_failure` grenzt ein:

| Messung | Ergebnis | Bedeutung | Nächster Schritt |
|---|---|---|---|
| Ping 127.0.0.1 | scheitert | Netzwerkstapel defekt (`STACK_BROKEN`) | `net.reset_winsock`, dann `net.reset_tcpip` |
| eigene IPv4, Gateway | fehlt oder 169.254.x.x | keine gültige Schnittstelle (`NO_VALID_INTERFACE`) | `net.enable_adapter`, `net.renew_dhcp`, `wifi.report` |
| Ping Gateway | 11050, ARP zum Router "Reachable" | Windows verwirft selbst (`LOCAL_FILTER`) | `net.mde_isolation_check`, `net.wfp_drop_events`, `net.firewall_report`, `net.vpn_report`; KEIN Reset |
| TCP 443 | WSAEACCES 10013 | lokaler Filter verweigert die Verbindung | wie oben |
| Ping Gateway | Zeitüberschreitung | Kabel, WLAN oder Router | `net.restart_adapter`, Router prüfen |

Der Praxisfall zeigte das Muster "ARP geht, IP nicht, nur DNS geht hinaus, auf allen Adaptern, auch mit ausgeschalteter Firewall". Ein Reset von Winsock oder TCP/IP hätte daran nichts geändert. Die Diagnose ohne Abschalten der Firewall geht so: `netsh wfp show netevents` zeigt kürzlich verworfene Pakete mit Filter-ID, `netsh wfp show filters` und `show state` ordnen die ID einem Filter und Anbieter zu [33]. Reicht das nicht, schaltet `net.wfp_audit_trace` für wenige Sekunden die Überwachung "Filterplattform: Paket verworfen/Verbindung" ein (über die GUIDs, weil die Namen lokalisiert sind), liest die Ereignisse 5152/5157 mit Filter-ID und ab Windows 11 "Filter Origin" und stellt die Überwachungsrichtlinie aus der Sicherung wieder her [35] [36].

#### Isolation durch Defender for Endpoint

Laut Microsoft trennt "Isolate device" das Gerät vom Netz, lässt aber die Verbindung zum Defender-Dienst offen; Outlook und Teams können ausgenommen sein, eine Aufhebung geht nur im Portal ("Release from isolation"), und die Isolation wird nach sieben Tagen automatisch aufgehoben [14] [40]. Einen dokumentierten lokalen Schalter "isoliert" gibt es nicht. `net.mde_isolation_check` kombiniert deshalb:

| Hinweis | Beleg | Gewicht |
|---|---|---|
| `OnboardingState = 1` unter `HKLM\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status`, Dienst `Sense` läuft | Microsoft [42] | Voraussetzung |
| Ereignisse 59/71 ("Starting/Succeeded to run command") mit "isolat" im Protokoll SENSE/Operational | Microsoft [41] (Text des Befehls nicht dokumentiert) | stark, auf Testgerät bestätigen |
| Registrywert `DisableEnterpriseAuthProxyValueToRestoreAfterIsolation` | Gemeinschaftsquelle [43] | Hinweis |
| Muster: Ping 11050 oder TCP 10013, aber DNS antwortet | Praxisfall | Hinweis |

Folge bei Verdacht: keine Netzwerk-Reparaturen, dem Benutzer erklären, dass die Organisation, die das Gerät schützt, es vom Netz getrennt hat, und die `OrgId` für die Rückfrage bei der IT nennen. Umgehen (Filter löschen, Dienst stoppen) ist ausgeschlossen.

#### VPN-Reste, Proxy, hosts, Fremdfilter

VPN-Programme hinterlassen virtuelle Adapter (TAP, Wintun, WireGuard), geteilte Standardrouten (0.0.0.0/1, 128.0.0.0/1), NRPT-DNS-Regeln, WinHTTP-Proxys und eigene WFP-Filter ("Kill Switch") [44] [45] [26]. Der Werkzeugkasten zeigt alles an, schaltet aber nur einen übrig gebliebenen Adapter ab (umkehrbar). Fremde NDIS-Filter und WFP-Filter bleiben unangetastet, weil sie auch zu Schutzsoftware gehören können; die Software entfernt der Benutzer selbst. Die Winsock-Kataloge werden aus der Registry gelesen statt mit `netsh winsock show catalog` (lokalisiert). Die hosts-Datei wird auf Microsofts Standardinhalt gesetzt [27], die alte Datei bleibt als Sicherung.

### 5.3 WLAN (`wifi`, 5 Aktionen)

WLAN-Funk, WLAN-Dienst und gespeicherte Profile. Der Funkzustand kommt über die WinRT-Schnittstelle `Windows.Devices.Radios`, weil `netsh wlan show interfaces` lokalisierten Text liefert. Profile werden ohne `key=clear` exportiert: der Schlüssel bleibt maschinengebunden verschlüsselt und der Import funktioniert auf demselben Gerät, ohne dass ein WLAN-Passwort im Klartext auf der SSD landet.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `wifi.report` (Kern) | WLAN-Zustand und gespeicherte WLANs anzeigen | Show Wi-Fi status and saved networks | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 10 s | [48] [49] [50] |
| `wifi.radio_on` (Kern) | WLAN-Funk einschalten | Turn on the Wi-Fi radio | Reparatur | niedrig | nein | nein | nein | ja | ja | < 5 s | [49] |
| `wifi.restart_service` | WLAN-Dienst neu starten | Restart the Wi-Fi service | Reparatur | niedrig | ja | nein | nein | ja | ja | < 15 s | [49] |
| `wifi.forget_profile` | Gespeichertes WLAN vergessen (danach neu verbinden) | Forget a saved Wi-Fi network | Reparatur | mittel | ja | nein | ja | ja | ja | < 10 s | [48] [49] |
| `wifi.connect` | Mit einem gespeicherten WLAN verbinden | Connect to a saved Wi-Fi network | Reparatur | niedrig | nein | nein | nein | ja | ja | < 30 s | [48] |

### 5.4 Windows Update (`wu`, 4 Aktionen)

Ohne Internet lässt sich Windows Update weder reparieren noch prüfen. Offline möglich sind: Zustand lesen, Dienste neu starten, deaktivierte Dienste wieder zulassen und den Zwischenspeicher nach Microsofts Anleitung umbenennen (nicht löschen) [[51]]. Ob Updates danach gehen, zeigt sich erst mit Netz; die Erfolgsprüfung bestätigt nur den technischen Schritt.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `wu.report` | Zustand von Windows Update anzeigen | Show Windows Update status | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | < 15 s | [51] [52] [53] |
| `wu.restart_services` | Update-Dienste neu starten | Restart the update services | Reparatur | niedrig | ja | nein | nein | ja | ja | < 30 s | [51] |
| `wu.reset_components` | Windows-Update-Zwischenspeicher neu anlegen | Reset Windows Update components | Reparatur | mittel | ja | nein | ja | ja | teilweise | < 1 min | [51] |
| `wu.service_defaults` | Ausgeschaltete Update-Dienste wieder zulassen | Re-enable disabled update services | Reparatur | mittel | ja | nein | ja | nein | ja | < 5 s | [51] |

Nicht umkehrbar, mit Begründung:

- `wu.service_defaults`: Bewusst kein Rückweg: er würde Sicherheitsupdates wieder abschalten. Die alten Starttypen stehen in starttypes.json.

Was offline geht und was nicht:

| Möglich offline | Nicht möglich offline |
|---|---|
| Zustand, Fehlercodes (Ereignis 20), ausstehender Neustart | Updates suchen und herunterladen |
| Dienste neu starten, Starttypen korrigieren | Prüfen, ob Updates wieder gehen |
| Zwischenspeicher umbenennen (DataStore, Download, catroot2) | Online-DISM (`/RestoreHealth` ohne Quelle) |
| Einzelne .msu/.cab von der SSD installieren (nicht im Katalog, siehe Grenzen) | Treiber über Windows Update |

### 5.5 Speicherplatz (`disk`, 7 Aktionen)

Gelöscht werden nur eindeutig temporäre Daten: Dateien in %TEMP% und C:\Windows\Temp, die älter als sieben Tage sind, und der Cache der Übermittlungsoptimierung über das dokumentierte Cmdlet [[56]]. Vor jedem Löschen wird die vollständige Liste geschrieben. Die Aufzählung folgt keinen Junctions oder Symlinks, damit ein Link im Temp-Ordner nie zu Benutzerdateien führt (im Container getestet). Absturzabbilder sind Diagnosedaten und werden nur auf die SSD verschoben. Papierkorb, Downloads und Windows.old entscheidet der Benutzer selbst.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `disk.report` (Kern) | Zeigen, was Platz auf C: belegt | Show what uses space on C: | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | 10-60 s | [54] [55] |
| `disk.clean_user_temp` (Kern) | Alte temporäre Dateien des Benutzers löschen | Delete old temporary files of the user | Reparatur | niedrig | nein | nein | ja | nein | ja | < 2 min | [54] [55] |
| `disk.clean_windows_temp` | Alte temporäre Dateien von Windows löschen | Delete old Windows temporary files | Reparatur | niedrig | ja | nein | ja | nein | ja | < 2 min | [54] |
| `disk.clean_delivery_optimization` | Zwischenspeicher der Update-Übermittlung leeren | Clear the Delivery Optimization cache | Reparatur | niedrig | ja | nein | ja | nein | ja | < 1 min | [56] |
| `disk.move_crash_dumps` | Absturzabbilder auf die Notfall-SSD verschieben | Move crash dumps to the rescue SSD | Reparatur | niedrig | ja | nein | ja | ja | ja | 1-10 min | [54] [57] |
| `disk.hibernation_off` | Ruhezustand ausschalten (gibt Platz frei) | Turn off hibernation to free space | Reparatur | mittel | ja | nein | ja | ja | ja | < 10 s | [58] [1] |
| `disk.open_storage_settings` | Speicher-Einstellungen und Papierkorb für den Benutzer öffnen | Open storage settings and the Recycle Bin for the user | Anleitung | niedrig | nein | nein | nein | - | ja | Benutzer | [54] [55] |

Nicht umkehrbar, mit Begründung:

- `disk.clean_user_temp`: Nicht umkehrbar. Begründung: nur Dateien in %TEMP%, älter als 7 Tage, die Programme bei Bedarf neu anlegen; Verknüpfungen werden nicht verfolgt; die Liste bleibt als Nachweis.
- `disk.clean_windows_temp`: Nicht umkehrbar. Begründung wie bei disk.clean_user_temp.
- `disk.clean_delivery_optimization`: Nicht umkehrbar. Begründung: reiner Download-Zwischenspeicher; Windows lädt fehlende Teile mit Internet erneut.

### 5.6 Langsamer Start und Autostart (`boot`, 4 Aktionen)

Startdauer und Bremsen liest `boot.report` aus dem Protokoll Diagnostics-Performance (Ereignis 100 und 101-109). Autostart-Einträge werden über denselben Schalter deaktiviert, den der Task-Manager verwendet (StartupApproved); der Eintrag selbst bleibt unverändert und lässt sich mit einem Klick zurückholen. Sicherheitssoftware ist durch eine Musterliste geschützt (im Container getestet). Häufig unterschätzt: Mit aktivem Schnellstart ist "Herunterfahren" kein Neustart; viele Probleme verschwinden nur bei "Neu starten".

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `boot.report` | Startdauer und Bremsen beim Start anzeigen | Show boot time and what slows it down | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | < 10 s | [2] [59] [1] |
| `boot.startup_list` | Programme im Autostart anzeigen | List startup programs | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 5 s | [60] [61] |
| `boot.startup_disable` | Programm aus dem Autostart nehmen | Disable a startup program | Reparatur | niedrig | ja | nein | nein | ja | ja | < 5 s | [60] |
| `boot.fast_startup_off` | Schnellstart ausschalten | Turn off Fast Startup | Reparatur | niedrig | ja | nein | nein | ja | ja | < 5 s | [1] |

### 5.7 Drucker (`print`, 5 Aktionen)

Spooler neu starten, hängende Aufträge entfernen, "Drucker offline verwenden" zurücknehmen, Standarddrucker festlegen. Spool-Dateien werden nur bei gestopptem Spooler angefasst, wie Microsoft es vorgibt [[62]], und auf die SSD verschoben statt gelöscht. Ist der Spooler deaktiviert, bleibt er es: das kann eine bewusste Härtung sein.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `print.report` (Kern) | Drucker und Druckaufträge anzeigen | Show printers and print jobs | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | < 10 s | [62] [63] [64] [65] [66] |
| `print.restart_spooler` (Kern) | Druckdienst neu starten | Restart the print spooler | Reparatur | niedrig | ja | nein | nein | ja | ja | < 15 s | [62] |
| `print.clear_queue` (Kern) | Hängende Druckaufträge entfernen | Clear stuck print jobs | Reparatur | niedrig | ja | nein | ja | ja | ja | < 30 s | [62] [63] |
| `print.set_online` | Drucker von "Offline verwenden" zurückholen | Take the printer out of "Use printer offline" | Reparatur | niedrig | ja | nein | nein | ja | ja | < 5 s | [66] |
| `print.set_default` | Standarddrucker festlegen | Set the default printer | Reparatur | niedrig | nein | nein | nein | ja | ja | < 5 s | [66] [64] |

### 5.8 Ton (`audio`, 4 Aktionen)

Häufigste Laienursache ist schlicht "stumm" oder Lautstärke 0. Dafür nutzt der Werkzeugkasten die Core-Audio-Schnittstelle über einen kleinen C#-Helfer (`Add-Type`), der im Container kompiliert wurde. Danach folgen Audiodienste und das Neustarten des Geräts (`pnputil /restart-device`, ab Windows 10 2004 [[69]]).

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `audio.report` (Kern) | Ton-Geräte und Lautstärke prüfen | Check sound devices and volume | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 10 s | [67] [68] |
| `audio.restart_services` | Audiodienste neu starten | Restart the audio services | Reparatur | niedrig | ja | nein | nein | ja | ja | < 15 s | [67] |
| `audio.unmute` (Kern) | Ton einschalten und Lautstärke hochstellen | Unmute and raise the volume | Reparatur | niedrig | nein | nein | nein | ja | ja | < 5 s | [67] |
| `audio.restart_device` | Soundkarte neu starten | Restart the sound device | Reparatur | mittel | ja | nein | ja | ja | ja | < 30 s | [69] [70] [67] |

### 5.9 Anzeige und Grafiktreiber (`display`, 3 Aktionen)

Bei schwarzem oder eingefrorenem Bild ist die Tastenkombination Win+Strg+Umschalt+B der sanfteste Schritt [[72]]; sie lässt sich nicht skripten und ist deshalb eine Anleitung. Treiber lassen sich offline nicht verlässlich installieren oder zurückrollen; "Microsoft Basic Display Adapter" in der Diagnose ist ein Hinweis für einen Menschen.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `display.report` | Grafikkarte und Bildschirme prüfen | Check graphics adapter and monitors | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 10 s | [71] [68] |
| `display.hotkey_reset` | Grafiktreiber mit Tastenkombination neu starten | Reset the graphics driver with a key combination | Anleitung | niedrig | nein | nein | nein | - | ja | < 10 s | [72] [71] |
| `display.restart_adapter` | Grafikkarte neu starten | Restart the graphics adapter | Reparatur | mittel | ja | nein | ja | ja | ja | < 30 s | [69] [71] |

### 5.10 Geräte allgemein (`hw`, 3 Aktionen)

Allgemeine Geräte mit Problemcode (Geräte-Manager). Deaktivierte Kameras oder Mikrofone können Absicht sein (Privatsphäre); Einschalten braucht deshalb Bestätigung. Speicher- und Systemgeräte werden nie neu gestartet.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `hw.problem_devices` | Geräte mit Problemen anzeigen | Show devices with problems | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 10 s | [68] |
| `hw.enable_device` | Deaktiviertes Gerät einschalten | Enable a disabled device | Reparatur | mittel | ja | nein | ja | ja | ja | < 10 s | [70] [68] |
| `hw.restart_device` | Gerät neu starten | Restart a device | Reparatur | mittel | ja | nein | ja | ja | ja | < 30 s | [69] |

### 5.11 Zeit und Uhr (`time`, 4 Aktionen)

Eine falsche Uhr bricht HTTPS, Anmeldungen und Updates. Offline gibt es keine Referenzzeit; die Bestandsaufnahme erkennt aber sichere Fehler: Zeit vor dem Erstellungsdatum des Werkzeugkastens oder ein Ereignisprotokoll-Eintrag in der Zukunft. Die richtige Zeit liefert der Benutzer (Handy), der Zeitdienst wird nur konfiguriert und gleicht erst mit Netz ab [[73]].

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `time.report` | Uhrzeit und Zeitzone prüfen | Check time and time zone | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 5 s | [73] [74] |
| `time.set_timezone` | Zeitzone einstellen | Set the time zone | Reparatur | niedrig | nein | nein | nein | ja | ja | < 5 s | [74] |
| `time.enable_sync` | Automatische Uhrzeit wieder einschalten | Turn automatic time sync back on | Reparatur | niedrig | ja | nein | nein | ja | teilweise | < 15 s | [73] |
| `time.set_manual` | Uhrzeit von Hand stellen | Set the time manually | Reparatur | mittel | ja | nein | ja | nein | ja | < 5 s | [73] |

Nicht umkehrbar, mit Begründung:

- `time.set_manual`: Nicht sinnvoll umkehrbar: eine falsche Uhrzeit wiederherzustellen hilft nie. Die Zeit lässt sich jederzeit erneut stellen; mit Internet korrigiert sie der Zeitdienst.

### 5.12 Virenschutz (Defender) (`defender`, 5 Aktionen)

Nur lesen, prüfen und Schutz erhöhen: Signaturen aus einem von Microsoft signierten Paket auf der SSD einspielen [[78] [79]], Echtzeitschutz einschalten, Schnell- und Offline-Prüfung starten. Nichts davon hat einen Rückweg, der den Schutz senken würde. Ist ein anderes Virenschutzprogramm aktiv (Defender im passiven Modus), fasst der Werkzeugkasten Defender nicht an.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `defender.report` (Kern) | Virenschutz-Zustand anzeigen | Show antivirus status | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | < 10 s | [75] [76] [77] |
| `defender.update_from_ssd` | Virenschutz-Signaturen von der SSD aktualisieren | Update antivirus signatures from the SSD | Reparatur | niedrig | ja | nein | nein | nein | ja | 1-3 min | [78] [79] [80] |
| `defender.realtime_on` | Echtzeitschutz wieder einschalten | Turn real-time protection back on | Reparatur | niedrig | ja | nein | nein | nein | ja | < 10 s | [81] [75] [77] |
| `defender.quick_scan` | Schnellprüfung auf Schadsoftware | Quick malware scan | Reparatur | niedrig | ja | nein | nein | ja | ja | 5-20 min | [82] [76] |
| `defender.offline_scan` | Gründliche Prüfung beim Neustart (Defender Offline) | Thorough scan at restart (Defender Offline) | Reparatur | mittel | ja | ja | ja | ja | ja | ca. 15 min | [83] [84] |

Nicht umkehrbar, mit Begründung:

- `defender.update_from_ssd`: Bewusst kein Rückweg: ältere Signaturen würden den Schutz verschlechtern.
- `defender.realtime_on`: Bewusst kein Rückweg: würde den Schutz abschalten.

### 5.13 Systemdateien (SFC, DISM) (`sysfile`, 5 Aktionen)

SFC repariert aus dem Komponentenspeicher, DISM repariert den Komponentenspeicher. `DISM /RestoreHealth` braucht eine Quelle: Windows Update (online) oder ein Abbild mit `/Source` und `/LimitAccess` [[85] [89]]. Offline heisst das: Auf der SSD muss ein install.wim/.esd derselben Version liegen, und selbst dann fehlen Komponenten neuerer Updates (Fehler 0x800f081f). Für die meisten Fälle reicht SFC; die Auswertung erfolgt über die [SR]-Zeilen in CBS.log wie in Microsofts Anleitung [[87]], weil die Bildschirmausgabe lokalisiert ist.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `sysfile.dism_checkhealth` | Windows-Komponentenspeicher schnell prüfen | Quick check of the component store | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | < 1 min | [85] [86] |
| `sysfile.dism_scanhealth` | Windows-Komponentenspeicher gründlich prüfen | Thorough check of the component store | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | 5-30 min | [85] [86] |
| `sysfile.sfc` | Windows-Systemdateien prüfen und reparieren (SFC) | Check and repair Windows system files (SFC) | Reparatur | niedrig | ja | nein | nein | nein | ja | 10-30 min | [87] [88] [85] |
| `sysfile.dism_restorehealth_ssd` | Komponentenspeicher mit Windows-Abbild von der SSD reparieren | Repair the component store from an image on the SSD | Reparatur | niedrig | ja | nein | nein | nein | ja | 15-60 min | [85] [89] [90] |
| `sysfile.dism_restorehealth_online` | Komponentenspeicher über Windows Update reparieren | Repair the component store via Windows Update | Reparatur | niedrig | ja | nein | nein | nein | nein | 15-60 min | [85] [86] |

Nicht umkehrbar, mit Begründung:

- `sysfile.sfc`: Nicht umkehrbar im Einzelnen. Begründung: ersetzt nur Dateien, die vom Original abweichen, durch das Original; Gesamtrückweg ist der Wiederherstellungspunkt.
- `sysfile.dism_restorehealth_ssd`: Nicht umkehrbar im Einzelnen. Begründung: ersetzt beschädigte Komponenten durch Originale; Gesamtrückweg ist der Wiederherstellungspunkt.
- `sysfile.dism_restorehealth_online`: Wie sysfile.dism_restorehealth_ssd.

### 5.14 Startmenü, Taskleiste, Explorer (`shell`, 4 Aktionen)

Explorer, Startmenü und Suche lassen sich gefahrlos beenden; Windows startet sie neu. Das Neu-Registrieren des Startmenü-Pakets ist ein verbreiteter Weg, den Microsofts Anleitung aber nicht empfiehlt [[91]]; deshalb Risiko mittel und nur für das eine Paket.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `shell.restart_explorer` (Kern) | Taskleiste und Explorer neu starten | Restart the taskbar and File Explorer | Reparatur | niedrig | nein | nein | nein | ja | ja | < 15 s | [91] |
| `shell.restart_startmenu` | Startmenü neu starten | Restart the Start menu | Reparatur | niedrig | nein | nein | nein | ja | ja | < 20 s | [91] |
| `shell.restart_search` | Windows-Suche neu starten | Restart Windows Search | Reparatur | niedrig | nein | nein | nein | ja | ja | < 10 s | [91] |
| `shell.reregister_startmenu` | Startmenü-Komponente neu registrieren | Re-register the Start menu component | Reparatur | mittel | nein | nein | ja | ja | ja | < 1 min | [91] [92] |

### 5.15 Store-Apps (`apps`, 3 Aktionen)

Store-Apps neu registrieren (Daten bleiben) und den Store-Zwischenspeicher leeren. "App zurücksetzen" löscht App-Daten und ist deshalb nicht im Katalog. Fehlende Apps lassen sich offline nicht installieren.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `apps.report` | Defekte Store-Apps anzeigen | Show broken Store apps | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 15 s | [93] |
| `apps.reregister` | Eine Store-App neu registrieren | Re-register a Store app | Reparatur | niedrig | nein | nein | nein | ja | ja | < 1 min | [92] [93] |
| `apps.store_reset` | Zwischenspeicher des Microsoft Store leeren | Reset the Microsoft Store cache | Reparatur | niedrig | nein | nein | nein | nein | teilweise | < 1 min | [93] |

Nicht umkehrbar, mit Begründung:

- `apps.store_reset`: Nicht umkehrbar. Begründung: leert nur den Store-Zwischenspeicher, der neu geladen wird.

### 5.16 Benutzerprofil und Temp (`profile`, 3 Aktionen)

Das temporäre Profil ist selten, aber für Laien dramatisch ("alles weg"). Die Reparatur benennt Registry-Schlüssel nur um, nichts wird gelöscht; der TEMP-Eintrag wird geparkt, nicht entfernt. Vorher werden Dateien vom Desktop des temporären Profils auf die SSD kopiert, weil sie sonst beim Abmelden verloren gehen. Risiko hoch, Bestätigung und Neustart Pflicht.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `profile.report` | Benutzerprofil prüfen (temporäres Profil?) | Check the user profile (temporary profile?) | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 5 s | [94] [95] |
| `profile.fix_temp_folder` | Fehlenden Temp-Ordner anlegen | Create the missing temp folder | Reparatur | niedrig | nein | nein | nein | ja | ja | < 5 s | [94] |
| `profile.fix_bak_entry` | Altes Benutzerprofil wieder verbinden (temporäres Profil beheben) | Reconnect the original user profile (fix temporary profile) | Reparatur | hoch | ja | ja | ja | ja | ja | < 1 min + Neustart | [95] [94] |

### 5.17 Dateisystem und Datenträger (`fs`, 3 Aktionen)

Vor jeder Dateisystem-Reparatur steht die Frage, ob der Datenträger selbst stirbt. Dann gilt: zuerst Daten sichern, keine Prüfung mit Neustart. Bei gesundem Datenträger: `Repair-Volume -Scan` (entspricht `chkdsk /scan`, ändert nichts) [[99]], danach die Reparatur beim Neustart über das Dirty-Bit (`fsutil dirty set`) [[100]]. Das ist sprachunabhängig; `chkdsk C: /f` fragt dagegen lokalisiert J/N bzw. Y/N.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `fs.health` | Zustand der Festplatten prüfen | Check disk health | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | < 15 s | [96] [97] [98] |
| `fs.scan_online` | Laufwerk C: im laufenden Betrieb auf Fehler prüfen | Scan drive C: for errors while running | Reparatur | niedrig | ja | nein | nein | ja | ja | 1-15 min | [99] [98] |
| `fs.check_on_restart` | Laufwerk C: beim nächsten Start reparieren lassen | Repair drive C: at the next restart | Reparatur | mittel | ja | ja | ja | nein | ja | 10 min bis mehrere Stunden | [100] [101] [98] |

Nicht umkehrbar, mit Begründung:

- `fs.check_on_restart`: Vor dem Neustart lässt sich die Prüfung mit "chkntfs /x C:" aufschieben (Ausnahme bleibt, bis "chkntfs /d" sie aufhebt). Die Reparatur selbst ist nicht umkehrbar. Begründung: chkdsk korrigiert die Dateisystem-Struktur.

### 5.18 BitLocker (`bitlocker`, 2 Aktionen)

BitLocker wird nur gelesen. Viele Windows-11-Geräte sind durch die Geräteverschlüsselung automatisch verschlüsselt, und der Schlüssel liegt im Microsoft-Konto, ohne dass die Besitzer es wissen [[104]]. Keine Aktion im Katalog verändert die Startkonfiguration oder Firmware, deshalb löst keine davon eine Schlüsselabfrage aus. Der Schlüssel selbst wird nie angezeigt, protokolliert oder gespeichert.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `bitlocker.report` | Verschlüsselung (BitLocker) prüfen | Check encryption (BitLocker) | Diagnose | niedrig | ja | nein | nein | nur lesend | ja | < 5 s | [102] [103] [104] |
| `bitlocker.recovery_key_hint` | Zeigen, wo der Wiederherstellungsschlüssel zu finden ist | Show where to find the recovery key | Anleitung | niedrig | ja | nein | nein | - | teilweise | Benutzer | [105] [104] |

### 5.19 Ereignisanzeige (`events`, 3 Aktionen)

Ereignisprotokolle werden nach Quelle und ID ausgewertet, nicht nach lokalisiertem Text. Bekannte Muster (Kernel-Power 41, Bugcheck 1001, disk 7/51/153, Display 4101, WHEA, User Profiles Service 1511) sind in der Bestandsaufnahme bereits gezählt und auf Aktionen abgebildet.

| ID | Titel (DE) | Title (EN) | Art | Risiko | Admin | Neustart | Bestätigung | Umkehrbar | Offline | Dauer | Quellen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `events.summary` | Häufigste Fehler in der Ereignisanzeige | Most frequent errors in Event Viewer | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | 5-20 s | [59] [106] |
| `events.crashes` | Abstürze und Bluescreens der letzten 30 Tage | Crashes and blue screens in the last 30 days | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | < 15 s | [106] [57] [59] |
| `events.reliability` | Zuverlässigkeitsverlauf auswerten | Evaluate reliability history | Diagnose | niedrig | nein | nein | nein | nur lesend | ja | 5-30 s | [107] |

## 6. Bewusst nicht im Katalog

| Aktion | Grund |
|---|---|
| Defender, Echtzeitschutz, Manipulationsschutz oder Firewall abschalten; Ausnahmen in Defender eintragen | Verboten (Auftrag). Zur Diagnose "liegt es an der Firewall?" dienen stattdessen net.wfp_drop_events und net.wfp_audit_trace, die den blockierenden Filter benennen, ohne Schutz abzuschalten. |
| netsh advfirewall reset | Löscht alle Ausnahmen von Programmen und gesetzte Regeln; zu breit, Folgeprobleme. Ein kleines lokales Modell schlug genau das im Praxisfall vor. |
| "Netzwerk zurücksetzen" in den Einstellungen | Entfernt und installiert alle Netzwerkadapter neu, löscht VPN-Clients und virtuelle Switches, gespeicherte WLANs; nicht umkehrbar. |
| Isolation von Defender for Endpoint aufheben oder umgehen; WFP-Filter löschen; Fremd-NDIS-Filter abschalten | Umgeht Sicherheitsfunktionen; Aufhebung nur durch die verwaltende Organisation im Defender-Portal. |
| BitLocker anhalten, entschlüsseln, Schlüssel anzeigen oder speichern | Sicherheitsfunktion; der Schlüssel gehört weder ins Protokoll noch auf eine tragbare SSD. |
| DISM /StartComponentCleanup /ResetBase | Nicht umkehrbar; installierte Updates lassen sich danach nicht mehr deinstallieren. |
| Papierkorb leeren, Downloads, Windows.old, Wiederherstellungspunkte löschen | Keine eindeutig temporären Daten; entscheidet der Benutzer selbst (disk.open_storage_settings). |
| Reset-AppxPackage / "App zurücksetzen"; alle Apps aller Benutzer neu registrieren | Löscht App-Daten bzw. ist zu breit. |
| Benutzerprofile löschen (z. B. Remove-CimInstance Win32_UserProfile) | Löscht Benutzerdaten. |
| chkdsk /r oder Prüfung beim Start auf einem auffälligen Datenträger | Belastet eine sterbende Platte; zuerst Datensicherung. |
| Treiber installieren, aktualisieren oder zurückrollen | Braucht passende Pakete; offline nicht verlässlich; Fehler können zu schwarzem Bildschirm oder Startproblemen führen. |
| Druckerwarteschlange aktivieren, wenn der Dienst deaktiviert ist | Kann eine absichtliche Härtung (PrintNightmare) sein. |
| Registry-Reiniger, "Tuning"- und "Debloat"-Skripte, Dienste pauschal abschalten | Nicht nachvollziehbar, nicht prüfbar, häufige Ursache von Problemen. |
| Ausführungsrichtlinie dauerhaft ändern (Set-ExecutionPolicy LocalMachine) | Der Ausführer startet seine eigenen, signierten Skripte; dauerhafte Änderungen am System sind nicht nötig. |
| Kennwörter, Konten, Anmeldeoptionen ändern | Ausserhalb des Auftrags; Missbrauchsgefahr. |
| MSDT-Problembehandlungen (msdt.exe) | Von Microsoft abgekündigt und in aktuellen Windows-Versionen entfernt. |
| Geplante Aufgaben und Dienste im Autostart abschalten | Schwer zu beurteilen, oft systemrelevant; nur Run-Einträge und Autostart-Ordner werden angeboten. |

## 7. Grenzen

| Grenze | Folge | Umgang |
|---|---|---|
| Kein Internet | Kein Windows Update, keine Treiber, kein Online-DISM, keine Zeitsynchronisierung, keine Store-Installationen | Aktionen mit `offline = teilweise/nein` sind gekennzeichnet; Erfolgsprüfung bestätigt dort nur den technischen Schritt |
| DISM offline | Braucht install.wim/.esd mit gleichem Build; neuere Komponenten aus späteren Updates fehlen trotzdem (0x800f081f) | SFC zuerst; DISM-Abbild nur für verbreitete Versionen auf die SSD; sonst Fall für einen Menschen |
| Defender-Signaturen | Nur so aktuell wie `mpam-fe.exe` auf der SSD | SSD regelmässig neu bauen; Signatur des Pakets vor dem Start prüfen |
| Lokalisierung | Texte von netsh, ipconfig, sfc, chkdsk, auditpol, Ereignismeldungen sind übersetzt | Nur Exit-Codes, Objekte, Registry, XML, GUIDs auswerten |
| Konto-Kontext | Bei Erhöhung mit fremdem Admin-Konto zeigen HKCU und Ton auf das falsche Konto | `ELEVATED_OTHER_USER` erkennen, Benutzer-Aktionen unerhöht starten |
| App Control, AppLocker, Smart App Control | Unsignierte Skripte werden blockiert oder laufen im Constrained Language Mode (kein `Add-Type`, kein WinRT) [109] | Skripte signieren; Ton- und Funk-Helfer fallen sauber weg |
| Windows im S Mode | Keine PowerShell und keine Kommandozeile (laut Fachpresse, nicht von Microsoft belegt [111]) | Werkzeugkasten kann nicht arbeiten; nur Anleitungen |
| Firmengeräte (Domäne, Entra, Intune, Defender for Endpoint) | Richtlinien überschreiben Änderungen; Eingriffe können gegen Vorgaben verstossen | `MANAGED_DEVICE`: nur lesen, Befund für die IT |
| BitLocker | Eingriffe an Firmware oder Startkonfiguration lösen die Schlüsselabfrage aus | Keine solche Aktion im Katalog; Schlüsselort vorher klären |
| Hardware | Sterbende Platte, Hitze, RAM-Fehler, leere Uhrbatterie | Nur erkennen und erklären; bei DISK_UNHEALTHY zuerst Datensicherung |
| WinPE-Start von der SSD | Nicht Gegenstand dieses Katalogs: alle Aktionen arbeiten im laufenden Windows; aus WinPE wäre ein BitLocker-Laufwerk gesperrt | Eigener Katalog, falls Windows nicht mehr startet |
| Undokumentierte Mechanismen | StartupApproved (Autostart-Schalter), SPP-Registrywert (Computerschutz), Isolations-Hinweise, XML-Pfade der WFP-Abbilder | Im JSON als Hinweis markiert; auf Testgeräten bestätigen |
| Datenschutz | Protokolle enthalten Benutzernamen, IP-Adressen, Gerätenamen | Bleiben auf der SSD; WLAN-Schlüssel nie im Klartext, BitLocker-Schlüssel nie |
| Kleine Modelle | Wählen trotz Kandidatenliste falsch oder wiederholen sich | Positivliste, Abbruch nach zwei Fehlschlägen pro Bereich, Erfolgsprüfung entscheidet, nicht das Modell |

## 8. Prüfung der Befehle

| Prüfung | Ergebnis |
|---|---|
| Syntax aller 284 Befehlsblöcke (Erkennung, Sicherung, Reparatur, Rückweg, Erfolgsprüfung, Hilfsfunktionen, Bestandsaufnahme) mit `[System.Management.Automation.Language.Parser]::ParseInput` in `mcr.microsoft.com/powershell:lts-debian-12` | 0 Fehler |
| Suche nach Syntax, die es nur in PowerShell 7 gibt (`??`, `?.`, `&&`, `||`, Ternär, `-Parallel`, `-AsHashtable` u. a.) | 0 Treffer |
| Funktionstest der sicherheitsrelevanten Hilfsfunktionen im Container (ohne Netz): Dateiliste folgt keinem Symlink, Löschfunktion verweigert Nicht-Temp-Ordner, Dokument bleibt unberührt, JSON-Rundlauf inkl. Ein-Element-Array, Konsolenaufruf mit stderr ohne Ausnahme, Schutzliste Autostart, C#-Audiohelfer kompiliert | 13 von 13 bestanden |
| Alle IDs in Befund-Codes, `vorher_ausfuehren` und Querverweisen existieren; jede ändernde Aktion hat Rückweg und Prüfung; Bestätigungsregel maschinell gesetzt | im Generator erzwungen |
| Alle Microsoft-Links per HTTP abgefragt | 200, ausser `microsoft.com/wdsi/defenderupdates` und TechRepublic (403 für automatische Abrufe, im Browser erreichbar) |

Nicht geprüft und vor Version 1 nötig: Ausführung auf Windows. Vorschlag für die Testmatrix: Windows 10 22H2 und Windows 11 24H2/25H2, jeweils Deutsch und Englisch, je ein Gerät mit und ohne Adminrechte, ein Gerät mit BitLocker, eines mit Drittanbieter-Virenschutz, eines in Defender for Endpoint (Isolation im Testmandanten auslösen und die Hinweise bestätigen). Besonders zu bestätigen: XML-Pfade der WFP-Abbilder, Feldnamen der Diagnostics-Performance-Ereignisse, Schreibbarkeit von `Win32_Printer.WorkOffline`, Restore-Punkt-Typ 6 nach einer Systemwiederherstellung, CSV-Spalten von `auditpol /backup`.

## 9. Offene Punkte

| Punkt | Warum |
|---|---|
| Testmatrix auf echten Windows-Geräten (Abschnitt 8) | Syntax ist geprüft, Verhalten nicht |
| Ausführer bauen (Bestätigungsdialog, Sicherungsordner, Protokoll, Fortsetzen nach Neustart) | Die Felder im JSON setzen ihn voraus |
| Skripte signieren | App Control/AppLocker, Constrained Language Mode |
| Laientexte für Bestätigungen aus `titel_de`, Risiko, Dauer und Rückweg ableiten und mit echten Laien testen | "Oma-tauglich" ist eine Behauptung, bis jemand es ausprobiert |
| Englische Texte (`titel_en`) für alle Ausgaben, falls das Projekt mehrsprachig wird | Nur Titel sind zweisprachig |
| Entscheiden, ob offline installierbare Update-Pakete (.msu) oder DISM-Abbilder auf die SSD gehören | Grösse und Aktualität gegen Nutzen |

## 10. Quellen

Microsoft-Dokumentation (learn.microsoft.com, support.microsoft.com) ist die Hauptquelle; Gemeinschafts- und Fachpresse-Quellen sind als solche markiert. Abgerufen am 09.11.2026.

1. Microsoft Learn: System power states (Hybrid shutdown / Fast startup): <https://learn.microsoft.com/en-us/windows/win32/power/system-power-states>
2. Microsoft Learn: Advanced troubleshooting for Windows boot problems: <https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/windows-boot-issues-troubleshooting>
3. Microsoft Learn: Get-ComputerRestorePoint: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-computerrestorepoint?view=powershell-5.1>
4. Microsoft Learn: SRSetRestorePointW (Haeufigkeit, Typen): <https://learn.microsoft.com/en-us/windows/win32/api/srrestoreptapi/nf-srrestoreptapi-srsetrestorepointw>
5. Microsoft Learn: Enable-ComputerRestore: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/enable-computerrestore?view=powershell-5.1>
6. Microsoft Learn: vssadmin resize shadowstorage: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/vssadmin-resize-shadowstorage>
7. Microsoft Learn: Checkpoint-Computer (nur 5.1, ein Punkt je 24 h): <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/checkpoint-computer?view=powershell-5.1>
8. Microsoft Learn: Restore-Computer: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/restore-computer?view=powershell-5.1>
9. Microsoft Learn: Guidance for troubleshooting TCP/IP communication (General Failure, netsh dump, int ip reset, winsock reset): <https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/troubleshoot-tcp-ip-communication-guidance>
10. Microsoft Learn: ICMP_ECHO_REPLY (IP_GENERAL_FAILURE = 11050): <https://learn.microsoft.com/en-us/windows/win32/api/ipexport/ns-ipexport-icmp_echo_reply>
11. Microsoft Learn: IPStatus Enum: <https://learn.microsoft.com/en-us/dotnet/api/system.net.networkinformation.ipstatus>
12. Microsoft Learn: Test-NetConnection: <https://learn.microsoft.com/en-us/powershell/module/nettcpip/test-netconnection>
13. Microsoft Learn: Windows Filtering Platform: <https://learn.microsoft.com/en-us/windows/win32/fwp/windows-filtering-platform-start-page>
14. Microsoft Learn: Take response actions on a device (Isolate device): <https://learn.microsoft.com/en-us/defender-endpoint/respond-machine-alerts>
15. Microsoft Learn: Enable-NetAdapter: <https://learn.microsoft.com/en-us/powershell/module/netadapter/enable-netadapter>
16. Microsoft Learn: Get-NetAdapter: <https://learn.microsoft.com/en-us/powershell/module/netadapter/get-netadapter>
17. Microsoft Learn: Restart-NetAdapter: <https://learn.microsoft.com/en-us/powershell/module/netadapter/restart-netadapter>
18. Microsoft Learn: ipconfig: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ipconfig>
19. Microsoft Learn: Get-NetIPConfiguration: <https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-netipconfiguration>
20. Microsoft Learn: Clear-DnsClientCache: <https://learn.microsoft.com/en-us/powershell/module/dnsclient/clear-dnsclientcache>
21. Microsoft Learn: Set-DnsClientServerAddress: <https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress>
22. Microsoft Learn: netsh interface: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-interface>
23. Microsoft Learn: reg export: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/reg-export>
24. Microsoft Learn: netsh winsock: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-winsock>
25. Microsoft Learn: Get-NetRoute: <https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-netroute>
26. Microsoft Learn: Netsh.exe commands for WinHTTP: <https://learn.microsoft.com/en-us/windows/win32/winhttp/netsh-exe-commands>
27. Microsoft Support: How to reset the Hosts file back to the default (KB972034): <https://support.microsoft.com/en-us/help/972034>
28. Microsoft Learn: Get-NetFirewallProfile: <https://learn.microsoft.com/en-us/powershell/module/netsecurity/get-netfirewallprofile>
29. Microsoft Learn: Get-NetFirewallRule: <https://learn.microsoft.com/en-us/powershell/module/netsecurity/get-netfirewallrule>
30. Microsoft Learn: Windows Firewall quarantine behavior: <https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/quarantine>
31. Microsoft Learn: Set-NetFirewallProfile: <https://learn.microsoft.com/en-us/powershell/module/netsecurity/set-netfirewallprofile>
32. Microsoft Learn: netsh advfirewall (export/import): <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-advfirewall>
33. Microsoft Learn: netsh wfp: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-wfp>
34. Microsoft Learn: Introduction to WFP callout drivers: <https://learn.microsoft.com/en-us/windows-hardware/drivers/network/introduction-to-windows-filtering-platform-callout-drivers>
35. Microsoft Learn: Filter Origin Audit Log (5152/5157, auditpol): <https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/filter-origin-documentation>
36. Microsoft Learn: 5157(F) The Windows Filtering Platform has blocked a connection: <https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-5157>
37. Microsoft Learn: WFP Auditing and Logging: <https://learn.microsoft.com/en-us/windows/win32/fwp/auditing-and-logging>
38. Microsoft Learn: auditpol set: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/auditpol-set>
39. Microsoft Learn: auditpol backup: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/auditpol-backup>
40. Microsoft Learn: Isolation exclusions: <https://learn.microsoft.com/en-us/defender-endpoint/network-isolation-exclusions>
41. Microsoft Learn: Review events and errors using Event Viewer (SENSE/Operational): <https://learn.microsoft.com/en-us/defender-endpoint/event-error-codes>
42. Microsoft Learn: Troubleshoot Defender for Endpoint onboarding (OnboardingState): <https://learn.microsoft.com/en-us/defender-endpoint/troubleshoot-onboarding>
43. Gemeinschaftsquelle (nicht Microsoft): KQL-Abfrage "Identify Isolated Endpoints" mit Registrywert DisableEnterpriseAuthProxyValueToRestoreAfterIsolation: <https://www.kqlsearch.com/query/identify-isolated-endpoints&clt7ah1gs00n9mc0po580bcdg>
44. Microsoft Learn: Get-VpnConnection: <https://learn.microsoft.com/en-us/powershell/module/vpnclient/get-vpnconnection>
45. Microsoft Learn: Get-DnsClientNrptPolicy: <https://learn.microsoft.com/en-us/powershell/module/dnsclient/get-dnsclientnrptpolicy>
46. Microsoft Learn: Get-NetAdapterBinding: <https://learn.microsoft.com/en-us/powershell/module/netadapter/get-netadapterbinding>
47. Microsoft Learn: Disable-NetAdapter: <https://learn.microsoft.com/en-us/powershell/module/netadapter/disable-netadapter>
48. Microsoft Learn (Archiv): Netsh Commands for Wireless Local Area Network (WLAN): <https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-R2-and-2008/cc755301(v=ws.10)>
49. Microsoft Support: Fix Wi-Fi connection issues in Windows (inkl. Netzwerk zuruecksetzen): <https://support.microsoft.com/en-us/windows/fix-wi-fi-connection-issues-in-windows-9424a1f7-6a3b-65a6-4d78-7f07eee84d2c>
50. Microsoft Learn: Get-NetConnectionProfile: <https://learn.microsoft.com/en-us/powershell/module/netconnection/get-netconnectionprofile>
51. Microsoft Learn: Windows Update resources (Komponenten manuell zuruecksetzen): <https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/additional-resources-for-windows-update>
52. Microsoft Learn: Windows Update log files: <https://learn.microsoft.com/en-us/windows/deployment/update/windows-update-logs>
53. Microsoft Learn: Get-HotFix: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-hotfix>
54. Microsoft Support: Free up drive space in Windows: <https://support.microsoft.com/en-us/windows/free-up-drive-space-in-windows-85529ccb-c365-490d-b548-831022bc9b32>
55. Microsoft Learn: Storage Sense: <https://learn.microsoft.com/en-us/windows/configuration/storage/storage-sense>
56. Microsoft Learn: Delete-DeliveryOptimizationCache: <https://learn.microsoft.com/en-us/powershell/module/deliveryoptimization/delete-deliveryoptimizationcache>
57. Microsoft Learn: Bug check code reference: <https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/bug-check-code-reference2>
58. Microsoft Learn: Powercfg command-line options (/hibernate): <https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options>
59. Microsoft Learn: Get-WinEvent: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-winevent?view=powershell-5.1>
60. Microsoft Support: Configure startup applications in Windows: <https://support.microsoft.com/en-us/windows/configure-startup-applications-in-windows-115a420a-0bff-4a6f-90e0-1934c844e473>
61. Microsoft Learn: Win32_StartupCommand: <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-startupcommand>
62. Microsoft Learn: Troubleshooting scenarios for printing (Spool-Ordner nur bei gestopptem Spooler): <https://learn.microsoft.com/en-us/troubleshoot/windows-server/printing/troubleshoot-printing-scenarios>
63. Microsoft Support: Fix print job stuck in queue errors in Windows: <https://support.microsoft.com/en-us/windows/fix-print-job-stuck-in-queue-errors-in-windows-9ee21bad-4488-45b5-b497-2d8299bd74aa>
64. Microsoft Learn: Get-Printer: <https://learn.microsoft.com/en-us/powershell/module/printmanagement/get-printer>
65. Microsoft Learn: Get-PrintJob: <https://learn.microsoft.com/en-us/powershell/module/printmanagement/get-printjob>
66. Microsoft Learn: Win32_Printer (WorkOffline, SetDefaultPrinter): <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-printer>
67. Microsoft Support: Fix sound or audio problems in Windows: <https://support.microsoft.com/en-us/windows/fix-sound-or-audio-problems-in-windows-73025246-b61c-40fb-671a-2535c7cd56c8>
68. Microsoft Learn: Get-PnpDevice: <https://learn.microsoft.com/en-us/powershell/module/pnpdevice/get-pnpdevice>
69. Microsoft Learn: PnPUtil command syntax (/restart-device ab Windows 10 2004): <https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax>
70. Microsoft Learn: Disable-PnpDevice: <https://learn.microsoft.com/en-us/powershell/module/pnpdevice/disable-pnpdevice>
71. Microsoft Learn: Timeout Detection and Recovery (TDR): <https://learn.microsoft.com/en-us/windows-hardware/drivers/display/timeout-detection-and-recovery>
72. Microsoft Support: Keyboard shortcuts in Windows (Win+Ctrl+Shift+B): <https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec>
73. Microsoft Learn: Windows Time service tools and settings (w32tm): <https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings>
74. Microsoft Learn: Set-TimeZone: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/set-timezone>
75. Microsoft Learn: Get-MpComputerStatus: <https://learn.microsoft.com/en-us/powershell/module/defender/get-mpcomputerstatus>
76. Microsoft Learn: Get-MpThreatDetection: <https://learn.microsoft.com/en-us/powershell/module/defender/get-mpthreatdetection>
77. Microsoft Learn: Tamper protection: <https://learn.microsoft.com/en-us/defender-endpoint/tamper-protection-overview>
78. Microsoft Learn: Microsoft Defender Antivirus security intelligence and product updates: <https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-updates>
79. Microsoft: Manuelle Downloads der Security Intelligence (mpam-fe.exe); Seite sperrt automatische Abrufe (HTTP 403), im Browser erreichbar: <https://www.microsoft.com/en-us/wdsi/defenderupdates>
80. Microsoft Learn: Get-AuthenticodeSignature: <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature?view=powershell-5.1>
81. Microsoft Learn: Set-MpPreference: <https://learn.microsoft.com/en-us/powershell/module/defender/set-mppreference>
82. Microsoft Learn: Start-MpScan: <https://learn.microsoft.com/en-us/powershell/module/defender/start-mpscan>
83. Microsoft Learn: Start-MpWDOScan: <https://learn.microsoft.com/en-us/powershell/module/defender/start-mpwdoscan>
84. Microsoft Learn: Microsoft Defender Offline scan: <https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-offline>
85. Microsoft Learn: Repair a Windows Image (CheckHealth, ScanHealth, RestoreHealth /Source /LimitAccess): <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image>
86. Microsoft Learn: Repair-WindowsImage: <https://learn.microsoft.com/en-us/powershell/module/dism/repair-windowsimage>
87. Microsoft Support: Use the System File Checker tool (findstr [SR] CBS.log): <https://support.microsoft.com/en-us/topic/use-the-system-file-checker-tool-to-repair-missing-or-corrupted-system-files-79aa86cb-ca52-166a-92a3-966e85d4094e>
88. Microsoft Learn: sfc: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sfc>
89. Microsoft Learn: Configure a Windows repair source: <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-a-windows-repair-source>
90. Microsoft Learn: Get-WindowsImage: <https://learn.microsoft.com/en-us/powershell/module/dism/get-windowsimage>
91. Microsoft Learn: Start menu troubleshooting guidance: <https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/troubleshoot-start-menu-errors>
92. Microsoft Learn: Add-AppxPackage (-Register): <https://learn.microsoft.com/en-us/powershell/module/appx/add-appxpackage>
93. Microsoft Learn: Get-AppxPackage: <https://learn.microsoft.com/en-us/powershell/module/appx/get-appxpackage>
94. Microsoft Learn: Scripts to clean up profile information and prevent temp profiles: <https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/scripts-to-cleanup-profile-folder-information-and-prevent-temp-user-profiles-from-being-created>
95. Microsoft Learn (Archiv-Blog): A corrupted or missing profile problem (.bak-Schluessel): <https://learn.microsoft.com/en-us/archive/blogs/deployment_field_notes/a-corrupted-or-missing-profile-problem>
96. Microsoft Learn: Get-PhysicalDisk: <https://learn.microsoft.com/en-us/powershell/module/storage/get-physicaldisk>
97. Microsoft Learn: Get-StorageReliabilityCounter: <https://learn.microsoft.com/en-us/powershell/module/storage/get-storagereliabilitycounter>
98. Microsoft Learn: chkdsk: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk>
99. Microsoft Learn: Repair-Volume (-Scan = chkdsk /scan): <https://learn.microsoft.com/en-us/powershell/module/storage/repair-volume>
100. Microsoft Learn: fsutil dirty: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-dirty>
101. Microsoft Learn: chkntfs: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkntfs>
102. Microsoft Learn: Get-BitLockerVolume: <https://learn.microsoft.com/en-us/powershell/module/bitlocker/get-bitlockervolume>
103. Microsoft Learn: BitLocker recovery overview: <https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/recovery-overview>
104. Microsoft Support: Device encryption in Windows: <https://support.microsoft.com/en-us/windows/device-encryption-in-windows-cf7e2b6f-3e70-4882-9532-18633605b7df>
105. Microsoft Support: Find your BitLocker recovery key: <https://support.microsoft.com/en-us/windows/find-your-bitlocker-recovery-key-6b71ad27-0b89-ea08-f143-056f5ab347d6>
106. Microsoft Learn: Event ID 41 "The system has rebooted without cleanly shutting down first": <https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/event-id-41-restart>
107. Microsoft Learn: Win32_ReliabilityRecords: <https://learn.microsoft.com/en-us/previous-versions/windows/desktop/racwmiprov/win32-reliabilityrecords>
108. Microsoft Learn: about_Execution_Policies (keine Sicherheitsgrenze): <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1>
109. Microsoft Learn: App Control for Business: <https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appcontrol>
110. Microsoft Learn: Deprecated features for Windows client (u. a. MSDT-Problembehandlungen): <https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features>
111. TechRepublic (Fachpresse, nicht Microsoft): Windows 10/11 in S Mode, keine Kommandozeile/PowerShell; Seite sperrt automatische Abrufe (HTTP 403), per Suche gefunden: <https://www.techrepublic.com/article/windows-10-s-mode-pros-and-cons/>
112. Microsoft Learn: Clean up the WinSxS folder (ResetBase nicht umkehrbar): <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder>
113. Microsoft Learn: cleanmgr: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cleanmgr>
114. Microsoft Learn: Troubleshoot Windows freeze: <https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/windows-based-computer-freeze-troubleshooting>
115. Microsoft Learn: Troubleshoot TCP/IP connectivity: <https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/tcp-ip-connectivity-issues-troubleshooting>

## Anhang A: Bestandsaufnahme (Skript)

Benötigt die Hilfsfunktionen aus Anhang B (im JSON: `hilfsfunktionen`). Nur ASCII, damit Windows PowerShell 5.1 es ohne BOM korrekt liest.

```powershell
# Notfall-KI Bestandsaufnahme v0.1 (Windows PowerShell 5.1, 64 Bit) - NUR LESEND
# Aufruf durch den Ausfuehrer, nachdem hilfsfunktionen.ps1 geladen ist:
#   . .\hilfsfunktionen.ps1 ; .\bestandsaufnahme.ps1 -ToolRoot E:\NotfallKI -ToolBuildDate 2026-11-01
# Ausgabe: eine Zeile kompaktes JSON auf stdout (Ziel unter ca. 1500 Token). Ziel: unter 30 Sekunden, ohne Netz lauffaehig.
# Jede Messung laeuft einzeln in try/catch; ein Fehler steht unter "err" und bricht nichts ab.
param(
    [string]$ToolRoot = $PSScriptRoot,
    [datetime]$ToolBuildDate = '2026-11-01',
    [int]$EventDays = 7
)
$ErrorActionPreference = 'Stop'
$NkRoot = $ToolRoot
$sw = [Diagnostics.Stopwatch]::StartNew()
$R = [ordered]@{ v = '0.1' }
$F = New-Object System.Collections.Generic.List[string]
$Err = [ordered]@{}

function Add-NkFlag([string]$Code) { if (-not $F.Contains($Code)) { $F.Add($Code) } }

function Invoke-NkProbe([string]$Name, [scriptblock]$Block) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    try { $R[$Name] = & $Block } catch { $Err[$Name] = $_.Exception.Message; $R[$Name] = $null }
    if ($t.ElapsedMilliseconds -gt 5000) { $Err[$Name + '_ms'] = $t.ElapsedMilliseconds }
}

# --- Kontext: wer laeuft, mit welchen Rechten, in welcher Sprache ---
Invoke-NkProbe 'meta' {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $shellUser = $null
    $ex = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ex) {
        $o = Invoke-CimMethod -InputObject $ex -MethodName GetOwner
        if ($o.User) { $shellUser = "$($o.Domain)\$($o.User)" }
    }
    $admin = Test-NkAdmin
    if (-not $admin) { Add-NkFlag 'NOT_ADMIN' }
    if ($shellUser -and ($shellUser -ne $me)) { Add-NkFlag 'ELEVATED_OTHER_USER' }
    [ordered]@{
        ts         = (Get-Date).ToString('s')
        utc        = (Get-Date).ToUniversalTime().ToString('s')
        admin      = $admin
        user       = $me
        shell_user = $shellUser
        ui         = (Get-UICulture).Name
        ps         = $PSVersionTable.PSVersion.ToString()
        x64        = [Environment]::Is64BitProcess
    }
}

# --- Betriebssystem, Neustart ausstehend, Verwaltung ---
Invoke-NkProbe 'os' {
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $build = [int]$cv.CurrentBuild
    $up = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    $pend = @()
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pend += 'CBS' }
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pend += 'WU' }
    if ((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $pend += 'PFRO' }
    if ($pend -contains 'CBS' -or $pend -contains 'WU') { Add-NkFlag 'PENDING_REBOOT' }
    if ($up -gt 168) { Add-NkFlag 'UPTIME_LONG' }
    $hb = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
    $aad = $false
    $ds = Invoke-NkNative -FilePath 'dsregcmd.exe' -ArgumentList @('/status')
    if ($ds.Output -match 'AzureAdJoined\s*:\s*YES') { $aad = $true }
    $mdm = [bool](Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
            Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).UPN })
    if ($cs.PartOfDomain -or $aad -or $mdm) { Add-NkFlag 'MANAGED_DEVICE' }
    [ordered]@{
        name           = $(if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' })
        edition        = $cv.EditionID
        ver            = $(if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId })
        build          = "$($cv.CurrentBuild).$($cv.UBR)"
        lang           = (Get-Culture).Name
        boot           = $os.LastBootUpTime.ToString('s')
        uptime_h       = $up
        pending_reboot = $pend
        fast_startup   = ($hb -eq 1)
        domain         = [bool]$cs.PartOfDomain
        entra          = $aad
        mdm            = $mdm
    }
}

# --- Hardware grob ---
Invoke-NkProbe 'hw' {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    [ordered]@{
        maker       = $cs.Manufacturer
        model       = $cs.Model
        ram_gb      = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        ram_free_gb = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
        battery     = [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    }
}

# --- Datentraeger und Platz ---
Invoke-NkProbe 'disk' {
    $sys = $env:SystemDrive.TrimEnd(':')
    $tool = $(if ($ToolRoot) { (Split-Path -Path $ToolRoot -Qualifier).TrimEnd(':') } else { '' })
    $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Fixed' } | ForEach-Object {
            $pct = $(if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size, 1) } else { $null })
            if ("$($_.DriveLetter)" -eq $sys) {
                if ($_.SizeRemaining -lt 2GB) { Add-NkFlag 'C_FREE_CRITICAL' }
                if ($_.SizeRemaining -lt 10GB -or $pct -lt 10) { Add-NkFlag 'C_FREE_LOW' }
            }
            if ("$($_.HealthStatus)" -ne 'Healthy' -or "$($_.OperationalStatus)" -ne 'OK') { Add-NkFlag 'VOLUME_NOT_HEALTHY' }
            [ordered]@{
                l        = "$($_.DriveLetter)"
                tool     = ("$($_.DriveLetter)" -eq $tool)
                fs       = $_.FileSystemType
                size_gb  = [math]::Round($_.Size / 1GB, 1)
                free_gb  = [math]::Round($_.SizeRemaining / 1GB, 1)
                free_pct = $pct
                health   = "$($_.HealthStatus)"
                op       = "$($_.OperationalStatus)"
            }
        })
    $phys = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            if ("$($_.HealthStatus)" -ne 'Healthy') { Add-NkFlag 'DISK_UNHEALTHY' }
            [ordered]@{
                name    = $_.FriendlyName
                media   = "$($_.MediaType)"
                bus     = "$($_.BusType)"
                health  = "$($_.HealthStatus)"
                op      = "$($_.OperationalStatus -join ',')"
                size_gb = [math]::Round($_.Size / 1GB, 0)
            }
        })
    [ordered]@{ vol = $vols; phys = $phys }
}

# --- Netzwerk: Adapter, Adressen, Tests, Proxy, hosts, Firewall, VPN, Filter, Defender for Endpoint ---
Invoke-NkProbe 'net' {
    $vpnRx = Get-NkVpnPattern
    $ad = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $adapters = foreach ($a in $ad) {
        $ip4 = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $dhcp = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)"
        $manDns = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).NameServer
        $isVpn = ($a.InterfaceDescription -match $vpnRx) -or ($a.Name -match $vpnRx)
        $isWifi = ("$($a.PhysicalMediaType)" -match '802\.11') -or ($a.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11')
        if ("$($a.Status)" -eq 'Disabled' -and $a.HardwareInterface) { Add-NkFlag 'ADAPTER_DISABLED' }
        if ("$($a.Status)" -eq 'Up' -and ($ip4 | Where-Object { $_.IPAddress -like '169.254.*' })) { Add-NkFlag 'APIPA_ADDRESS' }
        if ($manDns -and "$($a.Status)" -eq 'Up') { Add-NkFlag 'MANUAL_DNS' }
        if ($isVpn) { Add-NkFlag 'VPN_ADAPTER' }
        [ordered]@{
            n          = $a.Name
            d          = $a.InterfaceDescription
            st         = "$($a.Status)"
            hw         = [bool]$a.HardwareInterface
            wifi       = $isWifi
            vpn        = $isVpn
            speed      = $a.LinkSpeed
            dhcp       = "$dhcp"
            ip4        = @($ip4 | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
            dns_manual = $manDns
        }
    }
    if (-not ($ad | Where-Object { "$($_.Status)" -eq 'Up' })) { Add-NkFlag 'NO_ADAPTER_UP' }
    $gw = Get-NkDefaultGateway
    if (-not $gw) { Add-NkFlag 'NO_DEFAULT_GATEWAY' }
    $split = @(Get-NetRoute -DestinationPrefix '0.0.0.0/1', '128.0.0.0/1' -ErrorAction SilentlyContinue)
    if ($split.Count) { Add-NkFlag 'SPLIT_DEFAULT_ROUTE' }

    $dnsSrv = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | Select-Object -First 1 -ExpandProperty ServerAddresses)
    $t = [ordered]@{
        lo   = (Test-NkPing -Target '127.0.0.1').Result
        gw   = $(if ($gw) { (Test-NkPing -Target $gw).Result } else { 'NO_GATEWAY' })
        ext  = (Test-NkPing -Target '1.1.1.1').Result
        dns  = $(if ($dnsSrv) { (Test-NkDns -Server $dnsSrv[0]).Result } else { 'NO_SERVER' })
        tcp  = (Test-NkTcp -Target '1.1.1.1' -Port 443).Result
    }
    if ($t.lo -ne 'SUCCESS') { Add-NkFlag 'LOOPBACK_FAILS' }
    if ($t.gw -eq 'GENERAL_FAILURE' -or $t.ext -eq 'GENERAL_FAILURE') { Add-NkFlag 'PING_GENERAL_FAILURE' }
    if (@('TIMED_OUT', 'HOST_UNREACHABLE') -contains $t.gw) { Add-NkFlag 'GW_UNREACHABLE' }
    if ($t.tcp -eq 'BLOCKED_LOCAL') { Add-NkFlag 'TCP_BLOCKED_LOCAL' }
    if (@('RESOLVED', 'NXDOMAIN') -notcontains $t.dns -and $t.tcp -eq 'CONNECTED') { Add-NkFlag 'DNS_FAILS_NET_OK' }
    if (@('RESOLVED', 'NXDOMAIN') -contains $t.dns -and $t.tcp -ne 'CONNECTED' -and $t.ext -ne 'SUCCESS') { Add-NkFlag 'ONLY_DNS_WORKS' }

    $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($is.ProxyEnable -eq 1 -or $is.AutoConfigURL) { Add-NkFlag 'PROXY_USER_SET' }
    $wh = Get-NkWinHttpProxyFlags
    if ($wh -ne 'DIRECT') { Add-NkFlag 'PROXY_WINHTTP_SET' }

    $hostsLines = @(Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[^#\s]' })
    if ($hostsLines.Count) { Add-NkFlag 'HOSTS_MODIFIED' }

    $fw = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue | ForEach-Object {
            if ("$($_.Enabled)" -ne 'True') { Add-NkFlag 'FIREWALL_OFF' }
            if ("$($_.DefaultOutboundAction)" -eq 'Block') { Add-NkFlag 'FIREWALL_OUTBOUND_BLOCK' }
            [ordered]@{ p = "$($_.Name)"; on = "$($_.Enabled)"; out = "$($_.DefaultOutboundAction)" }
        })

    $vpnc = @(@(Get-VpnConnection -ErrorAction SilentlyContinue) + @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue) | Where-Object { $_ })
    $nrpt = @(Get-DnsClientNrptPolicy -Effective -ErrorAction SilentlyContinue)
    $lsp = @(Get-NkWinsockProviders | Where-Object { -not $_.Microsoft })
    if ($lsp.Count) { Add-NkFlag 'NON_MS_LSP' }
    $lwf = @(Get-NetAdapterBinding -AllBindings -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -and $_.ComponentID -notlike 'ms_*' } |
            Select-Object -ExpandProperty DisplayName -Unique)
    if ($lwf.Count) { Add-NkFlag 'NON_MS_NDIS_FILTER' }

    $atpKey = 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection'
    $atp = Get-ItemProperty -Path "$atpKey\Status" -ErrorAction SilentlyContinue
    $mde = [ordered]@{
        onboarded = ($atp.OnboardingState -eq 1)
        sense     = "$((Get-Service -Name Sense -ErrorAction SilentlyContinue).Status)"
        org       = $atp.OrgId
        iso_hint  = [bool](Get-ItemProperty -Path $atpKey -Name 'DisableEnterpriseAuthProxyValueToRestoreAfterIsolation' -ErrorAction SilentlyContinue)
    }
    if ($mde.onboarded) { Add-NkFlag 'MDE_ONBOARDED' }
    if ($mde.onboarded -and ($mde.iso_hint -or $F.Contains('ONLY_DNS_WORKS') -or $F.Contains('PING_GENERAL_FAILURE'))) { Add-NkFlag 'MDE_ISOLATION_SUSPECT' }

    $radio = @()
    try { $radio = @(Get-NkRadios | ForEach-Object { [ordered]@{ k = "$($_.Kind)"; s = "$($_.State)" } }) } catch { }
    if ($radio | Where-Object { $_.k -eq 'WiFi' -and $_.s -ne 'On' }) { Add-NkFlag 'WLAN_RADIO_OFF' }
    $wl = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
    if ($wl -and "$($wl.Status)" -ne 'Running' -and ($adapters | Where-Object { $_.wifi })) { Add-NkFlag 'WLANSVC_STOPPED' }

    [ordered]@{
        ad      = @($adapters)
        gw      = $gw
        test    = $t
        profile = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ n = $_.Name; ifc = $_.InterfaceAlias; cat = "$($_.NetworkCategory)"; v4 = "$($_.IPv4Connectivity)" } })
        proxy   = [ordered]@{ user = [int]$is.ProxyEnable; server = $is.ProxyServer; pac = $is.AutoConfigURL; winhttp = $wh }
        hosts   = $hostsLines.Count
        fw      = $fw
        vpn     = @($vpnc | ForEach-Object { [ordered]@{ n = $_.Name; st = "$($_.ConnectionStatus)" } })
        split   = $split.Count
        nrpt    = $nrpt.Count
        lsp     = @($lsp | ForEach-Object { $_.Path })
        ndis    = $lwf
        mde     = $mde
        radio   = $radio
    }
}

# --- Sicherheit: Defender und andere Virenschutzprogramme ---
Invoke-NkProbe 'sec' {
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object { $_.displayName })
    $thr = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-30) })
    if ($mp) {
        if (-not $mp.RealTimeProtectionEnabled -and "$($mp.AMRunningMode)" -eq 'Normal') { Add-NkFlag 'DEFENDER_RTP_OFF' }
        if ($mp.AntivirusSignatureAge -gt 7) { Add-NkFlag 'DEFENDER_SIG_OLD' }
    }
    if ($thr.Count) { Add-NkFlag 'DEFENDER_THREATS' }
    $other = @($av | Where-Object { $_ -notmatch 'Defender' })
    if (-not ($mp -and $mp.RealTimeProtectionEnabled) -and -not $other.Count) { Add-NkFlag 'NO_ACTIVE_AV' }
    [ordered]@{
        mode       = "$($mp.AMRunningMode)"
        rtp        = $mp.RealTimeProtectionEnabled
        sig_age_d  = $mp.AntivirusSignatureAge
        sig_ver    = $mp.AntivirusSignatureVersion
        tamper     = $mp.IsTamperProtected
        qscan_age  = $mp.QuickScanAge
        av         = $av
        threats30d = $thr.Count
    }
}

# --- Windows Update (nur Zustand; Updates selbst brauchen Netz) ---
Invoke-NkProbe 'wu' {
    $svc = foreach ($n in 'wuauserv', 'BITS', 'CryptSvc', 'UsoSvc') {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) {
            if ("$($s.StartType)" -eq 'Disabled' -and $n -ne 'UsoSvc') { Add-NkFlag 'WU_SERVICE_DISABLED' }
            [ordered]@{ n = $n; st = "$($s.Status)"; start = "$($s.StartType)" }
        }
    }
    $last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $fail = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = 20; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 50 -ErrorAction SilentlyContinue)
    if ($fail.Count) { Add-NkFlag 'WU_ERRORS' }
    $pause = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
    [ordered]@{
        svc          = @($svc)
        last_kb      = $last.HotFixID
        last_kb_date = $(if ($last) { $last.InstalledOn.ToString('yyyy-MM-dd') } else { $null })
        paused_until = $pause
        policy       = (Test-Path -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate')
        fail_30d     = $fail.Count
    }
}

# --- Wichtige Dienste, die laufen sollten ---
Invoke-NkProbe 'svc' {
    $want = 'Dhcp', 'Dnscache', 'NlaSvc', 'nsi', 'BFE', 'mpssvc', 'EventLog', 'Winmgmt', 'ProfSvc', 'Audiosrv', 'AudioEndpointBuilder', 'Spooler', 'CryptSvc'
    $bad = foreach ($n in $want) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s -and "$($s.Status)" -ne 'Running') {
            if ($n -eq 'Spooler') { Add-NkFlag 'SPOOLER_STOPPED' }
            if ($n -eq 'Audiosrv' -or $n -eq 'AudioEndpointBuilder') { Add-NkFlag 'AUDIO_SERVICE_STOPPED' }
            if ($n -eq 'BFE' -or $n -eq 'mpssvc') { Add-NkFlag 'FIREWALL_SERVICE_STOPPED' }
            if (@('Dhcp', 'Dnscache', 'NlaSvc', 'nsi') -contains $n) { Add-NkFlag 'NET_SERVICE_STOPPED' }
            [ordered]@{ n = $n; st = "$($s.Status)"; start = "$($s.StartType)" }
        }
    }
    @($bad)
}

# --- Uhrzeit: plausibel? ---
Invoke-NkProbe 'time' {
    $now = Get-Date
    $w = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction SilentlyContinue
    $newest = Get-WinEvent -LogName System -MaxEvents 1 -ErrorAction SilentlyContinue
    $future = [bool]($newest -and $newest.TimeCreated -gt $now.AddMinutes(10))
    $implausible = ($now -lt $ToolBuildDate) -or $future
    if ($implausible) { Add-NkFlag 'TIME_IMPLAUSIBLE' }
    if ($w.Type -eq 'NoSync') { Add-NkFlag 'W32TIME_NOSYNC' }
    [ordered]@{
        local       = $now.ToString('s')
        tz          = (Get-TimeZone).Id
        ntp_type    = $w.Type
        ntp_server  = $w.NtpServer
        w32time     = "$((Get-Service -Name W32Time -ErrorAction SilentlyContinue).Status)"
        implausible = $implausible
        future_ev   = $future
    }
}

# --- Ereignisprotokolle: haeufigste Fehler und bekannte Muster ---
Invoke-NkProbe 'ev' {
    $since = (Get-Date).AddDays(-$EventDays)
    $sysEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = $since } -MaxEvents 5000 -ErrorAction SilentlyContinue)
    $appEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2, 3; StartTime = $since } -MaxEvents 3000 -ErrorAction SilentlyContinue)
    function Get-NkCount($List, [string]$Provider, [int[]]$Ids) { @($List | Where-Object { $_.ProviderName -like $Provider -and $Ids -contains $_.Id }).Count }
    $cnt = [ordered]@{
        unexpected_shutdown = (Get-NkCount $sysEv 'Microsoft-Windows-Kernel-Power' 41) + (Get-NkCount $sysEv 'EventLog' 6008)
        bugcheck            = Get-NkCount $sysEv 'Microsoft-Windows-WER-SystemErrorReporting' 1001
        disk                = Get-NkCount $sysEv 'disk' 7, 51, 153
        ntfs                = Get-NkCount $sysEv '*Ntfs' 55, 98
        tdr                 = Get-NkCount $sysEv 'Display' 4101
        whea                = Get-NkCount $sysEv 'Microsoft-Windows-WHEA-Logger' 17, 18, 19, 47
        svc_fail            = Get-NkCount $sysEv 'Service Control Manager' 7000, 7001, 7009, 7011, 7023, 7031, 7034
        dns_timeout         = Get-NkCount $sysEv 'Microsoft-Windows-DNS-Client' 1014
        profile_temp        = Get-NkCount $appEv 'Microsoft-Windows-User Profiles Service' 1511, 1515
        app_crash           = Get-NkCount $appEv 'Application Error' 1000
        app_hang            = Get-NkCount $appEv 'Application Hang' 1002
    }
    if ($cnt.unexpected_shutdown -or $cnt.bugcheck) { Add-NkFlag 'CRASHES' }
    if ($cnt.disk -or $cnt.ntfs) { Add-NkFlag 'DISK_ERRORS_EVENTS' }
    if ($cnt.whea) { Add-NkFlag 'WHEA_ERRORS' }
    if ($cnt.tdr) { Add-NkFlag 'DISPLAY_TDR' }
    if ($cnt.profile_temp) { Add-NkFlag 'TEMP_PROFILE' }
    if ($cnt.app_crash -gt 5) { Add-NkFlag 'APP_CRASHES' }
    $errs = @($sysEv + $appEv | Where-Object { $_.Level -le 2 })
    $top = @($errs | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
            $g = @($_.Group | Sort-Object TimeCreated -Descending)
            [ordered]@{ src = $g[0].ProviderName; id = $g[0].Id; n = $_.Count; last = $g[0].TimeCreated.ToString('s') }
        })
    [ordered]@{ days = $EventDays; known = $cnt; top = $top }
}

# --- Drucker ---
Invoke-NkProbe 'prn' {
    $sp = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    $list = @()
    if ($sp -and "$($sp.Status)" -eq 'Running') {
        $list = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue | ForEach-Object {
                $jobs = @(Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue)
                $stuck = @($jobs | Where-Object { "$($_.JobStatus)" -match 'Error|Blocked|Offline|PaperOut|UserIntervention' -or $_.SubmittedTime -lt (Get-Date).AddHours(-2) })
                if ($_.WorkOffline -and $_.Default) { Add-NkFlag 'PRINTER_OFFLINE' }
                if ($stuck.Count) { Add-NkFlag 'PRINT_JOBS_STUCK' }
                [ordered]@{ n = $_.Name; def = [bool]$_.Default; offline = [bool]$_.WorkOffline; net = [bool]$_.Network; jobs = $jobs.Count; stuck = $stuck.Count }
            })
    }
    [ordered]@{ spooler = "$($sp.Status)"; printers = $list }
}

# --- Ton ---
Invoke-NkProbe 'aud' {
    $ep = @(Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue)
    if (-not @($ep | Where-Object { "$($_.Status)" -eq 'OK' }).Count) { Add-NkFlag 'AUDIO_NO_ENDPOINT' }
    $vol = $null
    $mute = $null
    try { $st = Get-NkAudioState; $vol = $st.Volume; $mute = $st.Mute } catch { }
    if ($mute -eq $true) { Add-NkFlag 'AUDIO_MUTED' }
    if ($null -ne $vol -and $vol -lt 0.05) { Add-NkFlag 'AUDIO_VOLUME_LOW' }
    [ordered]@{
        endpoints = @($ep | Select-Object -First 10 | ForEach-Object { [ordered]@{ n = $_.FriendlyName; st = "$($_.Status)" } })
        vol_pct   = $(if ($null -ne $vol) { [math]::Round($vol * 100) } else { $null })
        mute      = $mute
    }
}

# --- Anzeige und Geraete mit Problemcode ---
Invoke-NkProbe 'disp' {
    @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{
                n      = $_.Name
                drv    = $_.DriverVersion
                date   = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null })
                st     = $_.Status
                cm_err = $_.ConfigManagerErrorCode
                res    = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"
            }
        })
}
Invoke-NkProbe 'dev' {
    $bad = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -eq 'Error' })
    if ($bad.Count) { Add-NkFlag 'DEVICE_ERRORS' }
    @($bad | Select-Object -First 15 | ForEach-Object { [ordered]@{ n = $_.FriendlyName; cls = $_.Class; code = $_.ConfigManagerErrorCode; id = $_.InstanceId } })
}

# --- Benutzerprofil und Temp ---
Invoke-NkProbe 'prof' {
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $bak = @(Get-ChildItem -Path $pl -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '*.bak' } | ForEach-Object { $_.PSChildName })
    $isTemp = ($env:USERPROFILE -match '\\Users\\TEMP(\.|$)')
    if ($isTemp -or $bak.Count) { Add-NkFlag 'TEMP_PROFILE' }
    $tmp = [IO.Path]::GetTempPath()
    $tmpOk = Test-Path -LiteralPath $tmp
    if (-not $tmpOk) { Add-NkFlag 'TEMP_DIR_MISSING' }
    [ordered]@{ profile = $env:USERPROFILE; temp_profile = $isTemp; bak_keys = $bak; temp = $tmp; temp_ok = $tmpOk }
}

# --- Store-Apps ---
Invoke-NkProbe 'appx' {
    $broken = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -ne 'Ok' })
    if ($broken.Count) { Add-NkFlag 'APPX_BROKEN' }
    @($broken | Select-Object -First 10 | ForEach-Object { [ordered]@{ n = $_.Name; st = "$($_.Status)" } })
}

# --- Autostart (nur Anzahl; Details liefert boot.startup_list) ---
Invoke-NkProbe 'start' {
    $n = 0
    foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        $i = Get-Item -Path $k -ErrorAction SilentlyContinue
        if ($i) { $n += $i.ValueCount }
    }
    $n += @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Startup')), ([Environment]::GetFolderPath('CommonStartup')) -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }).Count
    if ($n -gt 15) { Add-NkFlag 'MANY_AUTOSTARTS' }
    [ordered]@{ entries = $n }
}

# --- Wiederherstellungspunkte ---
Invoke-NkProbe 'rp' {
    $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' -ErrorAction SilentlyContinue).'{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}'
    $on = [bool](@($v) -match [regex]::Escape('(' + $env:SystemDrive.TrimEnd(':') + '%3A)'))
    if (-not $on) { Add-NkFlag 'RESTORE_OFF' }
    $last = $null
    if (Test-NkAdmin) {
        $rpl = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if ($rpl) { $last = $rpl.ConvertToDateTime($rpl.CreationTime).ToString('s') }
    }
    [ordered]@{ on = $on; last = $last }
}

# --- BitLocker (nie den Wiederherstellungsschluessel selbst ausgeben) ---
Invoke-NkProbe 'bl' {
    if (-not (Test-NkAdmin)) { return 'needs_admin' }
    $b = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
    if (-not $b) { return $null }
    if ("$($b.ProtectionStatus)" -eq 'On') { Add-NkFlag 'BITLOCKER_ON' }
    if ("$($b.VolumeStatus)" -ne 'FullyDecrypted' -and "$($b.ProtectionStatus)" -eq 'Off') { Add-NkFlag 'BITLOCKER_SUSPENDED' }
    [ordered]@{
        status     = "$($b.VolumeStatus)"
        prot       = "$($b.ProtectionStatus)"
        pct        = $b.EncryptionPercentage
        protectors = @($b.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })
    }
}

$R['flags'] = @($F)
$R['err'] = $Err
$R['ms'] = $sw.ElapsedMilliseconds
ConvertTo-Json -InputObject $R -Depth 10 -Compress
```

## Anhang B: Hilfsfunktionen (Übersicht)

Volltext im JSON unter `hilfsfunktionen`.

| Funktion | Zweck |
|---|---|
| `Test-NkAdmin` | Prüft Adminrechte des Prozesses |
| `Write-NkJson / Read-NkJson` | Zustand in den Sicherungsordner schreiben und lesen (UTF-8, Tiefe 10) |
| `Invoke-NkNative` | Konsolenprogramm starten, Exit-Code und Ausgabe sammeln, ohne dass stderr in PS 5.1 eine Ausnahme auslöst |
| `Save-NkRegKey / Restore-NkRegKey` | Registry-Schlüssel exportieren und zurückspielen; fehlender Schlüssel wird markiert und beim Rückweg wieder entfernt |
| `Get-NkDefaultGateway` | Standard-Gateway mit kleinster Metrik |
| `Test-NkPing` | Ping mit sprachunabhängigem Ergebnis (11050 = GENERAL_FAILURE) |
| `Test-NkTcp` | TCP-Verbindungstest; 10013 = BLOCKED_LOCAL |
| `Test-NkDns` | DNS-Abfrage direkt an einen Server (ohne Zwischenspeicher); NXDOMAIN gilt als "DNS antwortet" |
| `Get-NkWinHttpProxyFlags` | WinHTTP-Proxy aus der Registry statt aus lokalisiertem netsh-Text |
| `Get-NkVpnPattern` | Namensmuster bekannter VPN-Adapter und -Dienste |
| `Get-NkWinsockProviders` | Winsock-Kataloge aus der Registry, Markierung Microsoft/fremd |
| `Backup-NkIpConfig / Restore-NkIpConfig / Test-NkIpConfigRestored` | Feste IP-Einstellungen sichern, zurückspielen, prüfen (über Adapter-GUID) |
| `Get-NkWfpDrops` | WFP-Abbilder auswerten: welcher Filter und Anbieter verwirft Pakete |
| `Get-NkFilesSafe / Get-NkSizeMB` | Dateien auflisten bzw. Grösse summieren, ohne Junctions/Symlinks zu folgen |
| `Remove-NkOldFiles` | Einzige löschende Funktion: nur Ordner namens Temp/Tmp, nicht auf der SSD, nur älter als N Tage, Liste vorher |
| `Move-NkToQuarantine` | Dateien auf die SSD verschieben, mit manifest.csv für den Rückweg |
| `Test-NkProtectedStartup` | Schutzliste für Sicherheitssoftware im Autostart |
| `Get-NkWlanProfiles` | WLAN-Profile ohne Klartext-Schlüssel exportieren und aus dem XML lesen |
| `Invoke-NkAwait / Get-NkRadios / Set-NkRadioState` | WLAN-/Bluetooth-Funk über WinRT (nur PS 5.1) |
| `Initialize-NkAudio / Get-NkAudioState / Set-NkAudioState` | Lautstärke und Stummschaltung über Core Audio (C# via Add-Type) |
| `Get-NkDefenderPackage` | Defender-Paket auf der SSD finden, Version und Microsoft-Signatur prüfen |
| `Get-NkCbsSrLines` | SFC-Ergebniszeilen ([SR]) aus CBS.log ab einem Zeitpunkt |
| `Get-NkEventData` | EventData eines Ereignisses als Tabelle (Feldnamen nicht lokalisiert) |
