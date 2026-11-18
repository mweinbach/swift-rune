# Windows UI Automation activation

From a Windows Swift developer PowerShell with the Visual C++ tools available, run

```powershell
.\Tests\Support\WindowsTextAccessibility\Demand\Run.ps1
```

The native provider check sends unrelated accessibility queries to six new HWNDs and verifies that each window stays dormant until its first client or root query. It checks signed and zero-extended object IDs and verifies that publication occurs inside that first query. A seventh window defers publication during its first query, then publishes a newer revision during the second query before a paint message arrives.

The public Rune app renames a row across six commits, scrolls it by 80 points, and puts its rendered geometry in the window caption. A separate UI Automation process waits for that caption using Win32, then makes one descendant lookup and checks the row’s current name and screen bounds. The runner exits with an error on a missing, stale, or misplaced row.
