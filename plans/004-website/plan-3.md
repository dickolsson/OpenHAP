# Phase 3 — FuguLib section 3p manuals

Give FuguLib real manual pages. This phase is worth shipping on its own terms:
it documents two modules that have no documentation at all, and it makes
`man FuguLib::Daemon` work on an installed system. The website benefit — a
FuguLib section that renders like every other manual — follows for free from
phase 2's pipeline. Depends on phase 2.

## Tasks

### 3.1 Write six mdoc(7) pages

`man/fugulib/{Daemon,Log,Privdrop,Process,Signal,State}.3p`, each starting from
the ISC header and `# ex:ts=8 sw=4:` conventions of the existing man pages.

- `.Dt FuguLib::Daemon 3p` gives the title; the filename drops the prefix
  because a colon cannot appear in a make target.
- Standard structure: `NAME`, `SYNOPSIS`, `DESCRIPTION`, a `.Sh` per public
  method with `.Fn`/`.Fa`, `RETURN VALUES`, `ERRORS`, `EXAMPLES`, `SEE ALSO`,
  `AUTHORS`. Follow `openhapd.conf.5` for house style.
- **Daemon, Privdrop, Process, Signal** convert from their existing `.pod`
  sidecars — the content is written, this is a format change, and the sidecar is
  the authority for what the module does.
- **Log and State** are new documentation. Read `lib/FuguLib/Log.pm` (177 lines)
  and `lib/FuguLib/State.pm` (104 lines) and document the public interface as it
  actually is. Do not describe intended behaviour: if something is surprising,
  say what it does.
- `SEE ALSO` cross-links sibling modules with `.Xr FuguLib::Signal 3p`, which
  phase 2's staging directory resolves into local links.
- `AUTHORS` uses `.An Dick Olsson Aq Mt hi@senzilla.io`, matching the rest of
  the tree.

### 3.2 Retire the `.pod` sidecars

Delete `lib/FuguLib/{Daemon,Privdrop,Process,Signal}.pod`. Two copies of the
same API description is exactly the failure this plan exists to prevent, and a
sidecar that no longer gets updated is worse than none.

- Remove the FuguLib `.pod` lines from the `install` and `package` targets.
- Check nothing else reads them: `grep -rn 'FuguLib.*\.pod'` across `Makefile`,
  `scripts/`, `t/`, and `.github/`.

### 3.3 Build, install, and package

- `MAN3P = man/fugulib/Daemon.3p man/fugulib/Log.3p ...` alongside
  `MAN1`/`MAN5`/`MAN8`, plus `CATMAN3P` and a `%.cat3p: %.3p` rule for
  `make man`, and `*.cat3p` added to `clean-man` and `.gitignore`.
- `install-man` installs into `$(DESTDIR)$(MANDIR)/man3p/` under the full
  `FuguLib::<Module>.3p` name — one `install` line per page, since the rename
  cannot be expressed as a glob.
- `uninstall` removes them. `package` copies them into
  `build/$(PACKAGE)/man/fugulib/`.
- FuguLib manuals ship with the product; unlike `man/openhvf/`, they are not
  development-only.

### 3.4 Amend the documentation-placement rule

The root `CLAUDE.md` table says a Perl module's API belongs in a sidecar `.pod`.
That is now true of OpenHAP and OpenHVF but not FuguLib. Amend row 2 to state
the split and the reason: FuguLib is a library intended for reuse and is
documented as a library, in `man/fugulib/*.3p`; OpenHAP and OpenHVF modules are
internal and keep their sidecars. Without this, the next module added to FuguLib
gets a `.pod` and the split silently rots.

Also update the `## Layout` section, which currently lists only `man/openhap/`
and `man/openhvf/`.

### 3.5 Render onto the site

- Add `$(MAN3P)` to phase 2's staging copy and add one render rule per page,
  output `FuguLib.Daemon.3p.html` and so on (`::` → `.` in the filename only).
- `mkindex.sh` gains the FuguLib group.
- `web/fugulib.body.html` — replace the phase 1 "manuals coming" pointer with
  real links, or simply point at `manuals.html#fugulib`.

## Deliverables

- `man/fugulib/{Daemon,Log,Privdrop,Process,Signal,State}.3p`
- Deleted: `lib/FuguLib/{Daemon,Privdrop,Process,Signal}.pod`
- `Makefile` — `MAN3P`, `CATMAN3P`, `%.cat3p`, `man`, `clean-man`,
  `install-man`, `uninstall`, `package`, `web`
- `CLAUDE.md` — placement table row 2, Layout section
- `.gitignore` — `*.cat3p`
- `web/fugulib.body.html`, `web/mkindex.sh`, `t/web/site.t`

## Acceptance criteria

- All six pages pass `mandoc -Tlint -W warning` with no output.
- `make man` builds `.cat3p` files for all six; `make clean` removes them.
- `make install DESTDIR=<tmp>` places
  `<tmp>/usr/local/man/man3p/FuguLib::Daemon.3p`, and
  `man -M <tmp>/usr/local/man FuguLib::Daemon` renders it. `make uninstall`
  removes all six.
- `make package` includes the six pages and no FuguLib `.pod`.
- No `.pod` file remains under `lib/FuguLib/`, and no reference to one remains
  anywhere in the tree.
- Every public method of all six modules appears in its page — checked against
  the `.pm` sources, not against the retired sidecars, so the two
  previously-undocumented modules get real coverage rather than a stub.
- The site shows six FuguLib manuals, grouped under FuguLib in `manuals.html`,
  with working `SEE ALSO` links between them.
- `make check` stays green.
