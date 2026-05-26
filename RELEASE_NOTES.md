# Release notes

## v1.0.0 &mdash; Initial public release

First public release of `Generate-UserPassphrase` for One Identity Active
Roles. Generates cryptographically random, Diceware-style passphrases from
the EFF Large Wordlist and serves them through the Active Roles policy
engine as the server-side value for the `edsaPassword` attribute on user
objects.

### GitHub release description (one line)

> Initial release. Cryptographically secure, Diceware-style passphrase
> generator for One Identity Active Roles, using the EFF Large Wordlist
> with a local validated cache.

### Highlights

- Cryptographically secure randomness from
  `System.Security.Cryptography.RandomNumberGenerator`, with rejection
  sampling in `Get-SecureRandomInt` to eliminate modulo bias.
- [EFF Large Wordlist for Passphrases][eff-wordlist] (7,776 words),
  downloaded and cached under
  `%ProgramData%\One Identity\Active Roles\` with periodic, validated
  refresh from the EFF (default 30 days, configurable).
- Offline / air-gapped support via `-SkipWordListUpdate` &mdash; the
  script will never contact the network if a valid cache is in place.
- Configurable word count, separator, capitalisation, and optional
  appended digit.
- Active Roles integration via the `onGetEffectivePolicy` event handler,
  emitting diagnostics through the intrinsic `$EventLog` object.

### Logging

All diagnostics are written to the Active Roles event log via
`$EventLog.ReportEvent` using the matching `$Constants.EDS_EVENTLOG_*_TYPE`
constants. Warning and Error events are always emitted. Information-level
events are **suppressed by default** to keep the AR event log quiet in
normal operation; flip `$script:LogInfoToEventLog = $true` at the top of
the script to enable them while debugging.

The optional per-passphrase audit entry never includes the generated
value &mdash; only the fact that a passphrase was issued. The generated
value is delivered exclusively through the Active Roles
`SetEffectivePolicyInfo` API.

### Versioning and integrity

- Running version is exposed as `$script:ScriptVersion` (currently
  `1.0.0`).
- `checksums.txt` lists the SHA-256 hash of every `.ps1` file in the
  release. Regenerate with the **Update checksums** VS Code task.
- `Generate-UserPassphrase.ps1` is Authenticode-signed before release.
  Re-sign locally with the **Sign PowerShell script** VS Code task.

### Verifying this release

After downloading or cloning the release tag:

```powershell
# Confirm the signature
Get-AuthenticodeSignature .\Generate-UserPassphrase.ps1 |
    Select-Object Status, SignerCertificate, TimeStamperCertificate

# Confirm SHA-256 hashes match checksums.txt
Get-FileHash -Algorithm SHA256 .\Generate-UserPassphrase.ps1
Get-Content .\checksums.txt
```

### Known limitations

- Requires network egress from the Active Roles Administration Service
  host on first run, and again whenever the cache is older than
  `-WordListRefreshIntervalDays`, unless a pre-staged wordlist is
  combined with `-SkipWordListUpdate`.
- The EFF wordlist itself is not redistributed in this repository; it is
  fetched at runtime and remains covered by its own
  [CC BY 4.0][cc-by] licence.

### Acknowledgements

Inspired by
[AJLindner/ActiveRoles-GenerateUserPassphrase](https://github.com/AJLindner/ActiveRoles-GenerateUserPassphrase),
which demonstrated the approach of using the EFF Large Wordlist inside
an Active Roles policy script module as an alternative to the built-in
password generator.

[eff-wordlist]: https://www.eff.org/dice
[cc-by]: https://creativecommons.org/licenses/by/4.0/
