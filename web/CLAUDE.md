# web/

Applies when working on files under `web/`, or on the `web` target in the
top-level `Makefile`.

## What this is

`make web` builds a static site into `$(WEBOUT)` (default `web/build`, override
it to build elsewhere). There is no generator, no templating language and no
JavaScript: two `sh` scripts, a stylesheet, and renderers that read formats
already in the tree. `plans/004-website/design.md` records why.

Nothing here is installed, packaged, or part of `make check`. `mandoc` and
`lowdown` are develop-only dependencies.

`.github/workflows/web.yml` builds and checks the site on every pull request and
deploys it to GitHub Pages on pushes to `main`. The site is served from
<https://www.openhap.org/>. The custom domain lives in two places on purpose: as
a repository setting, and as `web/CNAME`, which the `web` target copies into the
output so the deploy artifact always carries it. Change both together.

## How a page is made

Every source format is reduced to one HTML **body fragment** and wrapped in the
shared chrome:

| Source                 | Renderer                        |
| ---------------------- | ------------------------------- |
| `web/*.body.html`      | none — the fragment is the file |
| `INSTALL.md`           | `lowdown -Thtml`                |
| `man/*/*.1 .3p .5 .8`  | `mandoc -Thtml -O fragment`     |
| `lib/OpenHAP/**/*.pod` | `pod2man` then the same mandoc  |

- `web/mkpage.sh <title>` reads a fragment on stdin, substitutes `@TITLE@` into
  `head.html`, and appends `foot.html`. Titles are substituted with `sed`, so
  they must not contain `/`, `&`, or a newline; `t/web/site.t` asserts this.
- `web/mkindex.sh <source>...` emits the body of `manuals.html`, grouped by
  source directory. Descriptions come from `.Nd` or from `=head1 NAME`, never
  from a list kept here.

## Adding a page

- **A hand-written page** — add `web/<name>.body.html`, one `$(MKPAGE)` line to
  the `web` target, and the file name to `@SITE` in `t/web/site.t`. Add it to
  the nav in `head.html` and to `@NAV` in the test only if it belongs there; the
  nav is six items and should stay that way.
- **A manual** — add it to `MAN3P`/`MAN5`/`MAN8` and it is staged, rendered and
  indexed with no further edit. A `.pod` sidecar needs no edit at all: the `web`
  target finds them.
- **Prose that belongs to the project rather than the site** — it goes in
  `README.md`, `INSTALL.md`, `man/`, or a `.pod` sidecar, and the site renders
  it. The root `CLAUDE.md` placement table decides; `web/*.body.html` is for
  site-specific framing only.

## Findings worth not rediscovering

- **mandoc picks a local or a remote `.Xr` target by looking for a file named
  `%N.%S` in its working directory**, exactly as mandoc(1) documents. That is
  why all mdoc sources are staged into `$(WEBOUT)/.man/` and mandoc is run from
  there, and why the FuguLib pages are staged under their full
  `FuguLib::<Module>.3p` names rather than the file names in `man/fugulib/`.
- **Local links carry a `./` prefix.** A relative URL whose first path segment
  contains a colon is parsed as a scheme, so a bare `FuguLib::Daemon.3p.html`
  href would be read as the `fugulib:` protocol. Both `mandoc -O man=` and
  `mkindex.sh` emit `./`.
- **`pod2man` renders `L<Some::Module>` as italic text, not a link.** POD pages
  therefore cross-reference as plain text while mdoc pages link. This is
  accepted: making it work would mean post-processing mandoc's HTML.
- **The build must not vary with the machine.** `mandoc -I os=OpenBSD` pins the
  footer, which otherwise names the build host's OS, and `pod2man --date` is
  given the checkout's last commit date, because the default is the file mtime
  and git does not preserve those.
- **`!=` shell assignment is not portable enough to rely on.** GNU make 3.81,
  which is what macOS ships, silently ignores it. The `.pod` list is built in
  the recipe instead.
