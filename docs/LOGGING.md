# Logging

BuildWIM always logs to:

- Console output (level-based, colorized)
- Log file: `C:\BuildWIM\Logs\BuildWIM-<timestamp>.log`
- Transcript: `C:\BuildWIM\Logs\BuildWIM-<timestamp>.transcript.txt`

## Levels

- INFO: Normal operation
- WARN: Non-fatal deviation; run may continue
- ERROR: Fatal error; run stops
- DEBUG: Extra details, including DISM command lines

## DISM traceability

Every executed DISM command is captured in:
- the log file
- the HTML report ("DISM commands" section)

This makes it easy to reproduce runs and troubleshoot failures.
