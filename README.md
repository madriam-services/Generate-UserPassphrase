# Generate-UserPassphrase

A PowerShell script that generates cryptographically random, Diceware-style
passphrases from the EFF Large Wordlist. It is designed to drop into a
[One Identity Active Roles] Script Module so that the Active Roles policy
engine can issue generated passwords for the `edsaPassword` attribute, but the
`New-Password` function is fully usable on its own from any PowerShell host.

[One Identity Active Roles]: https://www.oneidentity.com/products/active-roles/

## Features

- Cryptographically secure randomness via
  `System.Security.Cryptography.RandomNumberGenerator` &mdash; no use of
  `Get-Random` or `System.Random`.
- Uniform integer sampling with rejection to eliminate modulo bias.
- [EFF Large Wordlist for Passphrases][eff-wordlist] (7,776 words, average
  ~12.9 bits of entropy per word).
- Local cache of the wordlist under
  `%ProgramData%\One Identity\Active Roles\` with periodic, validated refresh
  from the EFF (configurable interval, default 30 days).
- Offline mode via `-SkipWordListUpdate` &mdash; never touches the network.
- Configurable word count, separator, capitalisation, and optional digit
  injection.
- Active Roles integration via the `onGetEffectivePolicy` event handler.
- Context-aware logging: writes to the Active Roles event log via the
  intrinsic `$EventLog` object when running inside Active Roles, or to
  the standard `Write-Verbose` / `Write-Warning` / `Write-Error` streams
  when run standalone.

[eff-wordlist]: https://www.eff.org/dice

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Network access on first run (or whenever the cache is older than the refresh
  interval) unless `-SkipWordListUpdate` is supplied with a pre-staged
  wordlist.
- For Active Roles integration: a configured Active Roles environment in which
  the script is loaded as a Script Module and bound to a Policy Object.

## Usage

### As a standalone function

```powershell
. .\Generate-UserPassphrase.ps1

New-Password
# -> Correct-Horse-Battery7

New-Password -NumberOfWords 5 -WordSeparator '.' -Capitalisation $false -IncludeNumber $false
# -> correct.horse.battery.staple.anvil
```

### Inside Active Roles

1. Import `Generate-UserPassphrase.ps1` as a Script Module.
2. Define a new or on include it in an existing policy object
3. Apply the Policy Object to the OUs / containers where Active Roles should
   server-side-generate the password.

The `onGetEffectivePolicy` handler signals to the Active Roles UI that the
password is server-side generated and supplies the generated value.

### `New-Password` parameters

- **`-NumberOfWords`** &mdash; _Default: `3`._
  Number of words in the passphrase (&ge; 1).

- **`-WordSeparator`** &mdash; _Default: `-`._
  String inserted between words.

- **`-Capitalisation`** &mdash; _Default: `$true`._
  Title-case each word.

- **`-IncludeNumber`** &mdash; _Default: `$true`._
  Append a single random digit (0&ndash;9) to one of the words.

- **`-WordListPath`** &mdash; _Default: empty._
  Override the cached wordlist path. When set, the cache logic is skipped
  and the file at this path is used directly.

- **`-WordListRefreshIntervalDays`** &mdash; _Default: `30`._
  How often (in days) the cached wordlist is re-fetched from the EFF
  (1&ndash;365).

- **`-SkipWordListUpdate`** &mdash; _Switch._
  Never contact the network; require the cache (or `-WordListPath`) to
  already be valid.

`New-Password` is an advanced function (`[CmdletBinding()]`), so all of
the standard PowerShell common parameters are supported &mdash; most
notably `-Verbose`, which surfaces Information-level diagnostics in
standalone use.

## Logging

The script chooses its log sink at runtime based on the host:

- **Inside Active Roles**, Warning and Error events are written to the
  Active Roles event log via the intrinsic `$EventLog.ReportEvent`
  method, using `$Constants.EDS_EVENTLOG_WARNING_TYPE` /
  `EDS_EVENTLOG_ERROR_TYPE` / `EDS_EVENTLOG_INFORMATION_TYPE` as
  documented in the
  [Active Roles SDK](https://support.oneidentity.com/active-roles/technical-documents).
  AR automatically prepends the request context (request ID, target
  object name, GUID, source container) to each entry, so script
  messages describe *what* was done, not *which* object it was done to.
- **Standalone**, the same calls are routed through `Write-Verbose`,
  `Write-Warning`, and `Write-Error` so PowerShell's normal preference
  variables and redirection (`-Verbose`, `-WarningAction`,
  `*> file.log`, &hellip;) apply as expected.

Information-level events are **suppressed by default in Active Roles**
to keep the AR event log quiet. They cover cache lifecycle (download,
refresh, fallback) and, optionally, a per-passphrase audit entry
emitted from `onGetEffectivePolicy`. To enable them while debugging,
set the script-scope toggle at the top of `Generate-UserPassphrase.ps1`:

```powershell
$script:LogInfoToEventLog = $true
```

Warning and Error events are always emitted regardless of the toggle.

The per-passphrase audit entry never includes the generated value
itself &mdash; only the fact that a passphrase was issued. The
generated value is delivered exclusively through the Active Roles
`SetEffectivePolicyInfo` API.

## Wordlist

The script uses the
[EFF Large Wordlist for Passphrases][eff-wordlist] (7,776 words), licensed
under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The wordlist
itself is not redistributed in this repository; it is downloaded from
`https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt` on first use
and cached locally.

If the script can't reach the EFF, it will keep using a previously cached copy
(if any) and emit a warning. If no cache exists and the network is
unavailable, you can pre-stage the file and point at it with `-WordListPath`,
optionally combined with `-SkipWordListUpdate`.

## Entropy

With the defaults (3 words from a 7,776-word list, plus one appended digit),
the raw entropy is roughly:

- 3 &times; log&#8322;(7776) &asymp; 38.8 bits from word selection
- +log&#8322;(10) &asymp; 3.3 bits from the appended digit
- +log&#8322;(3) &asymp; 1.6 bits from the choice of which word the digit
  attaches to

&asymp; 43.7 bits total. Increase `-NumberOfWords` for more entropy
(each additional word adds ~12.9 bits).

## AI-generated content

Portions of this script were drafted with the assistance of AI coding tools
&mdash; most notably the `Get-SecureRandomInt` function, which implements
rejection sampling to avoid modulo bias when reducing a 32-bit random value
into the desired range.

All AI-generated code in this repository has been reviewed, edited, and
tested by a human before being committed. You should still review it
yourself for your own environment and threat model; no warranty is implied.

## Acknowledgements

This project was inspired by
[AJLindner/ActiveRoles-GenerateUserPassphrase](https://github.com/AJLindner/ActiveRoles-GenerateUserPassphrase),
which demonstrated the approach of using the EFF Large Wordlist inside an
Active Roles policy script module as an alternative to the built-in password
generator.

## Authorship

Written and maintained by **Shawn Ferrier**.

## Copyright

Copyright &copy; 2026 Madriam Services. All rights reserved.

The EFF Large Wordlist that the script downloads at runtime is not part of
this repository and remains covered by its own [CC BY 4.0][cc-by] licence
from the Electronic Frontier Foundation.

[cc-by]: https://creativecommons.org/licenses/by/4.0/

## Licence

This project is released under the MIT Licence. The full licence text is
reproduced below and is also available in [LICENSE](LICENSE).

```
MIT License

Copyright (c) 2026 Madriam Services

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
