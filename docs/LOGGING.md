# Loggning

BuildWIM loggar alltid till:

- Konsol (färgkodade nivåer)
- Loggfil: `C:\BuildWIM\Logs\BuildWIM-<timestamp>.log`
- Transcript: `C:\BuildWIM\Logs\BuildWIM-<timestamp>.transcript.txt`

## Nivåer

- INFO: Normal drift
- WARN: Avvikelse som inte nödvändigtvis stoppar körning
- ERROR: Fel som stoppar körning
- DEBUG: DISM-kommandon och extra detaljer

## DISM spårbarhet

Alla DISM-kommandon som körs sparas både i loggfil och i HTML-rapporten under "DISM commands".
Det gör det lätt att:
- reproducera en körning
- felsöka exakt var det bröt
- dokumentera servicing-order och åtgärder
