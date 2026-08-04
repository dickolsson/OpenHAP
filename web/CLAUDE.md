# web/

Applies when working on files under `web/`, on `.fuguwebrc`, or on the `web`
target in the top-level `Makefile`.

## What this is

`web/` holds content and nothing else: the `*.body.html` fragments, `robots.txt`
and `CNAME`. There is no script here and no chrome. `.fuguwebrc` at the
repository root describes the site, and `bin/fuguweb` builds it — see
`fuguweb(1)` and the `.pod` sidecars under `lib/App/FuguWeb/`.

```sh
make web                # build into $(WEBOUT), default web/build
make web-clean          # remove it
bin/fuguweb check --out web/build
```

Nothing here is part of `make check`. `mandoc` and `lowdown` are develop-only
dependencies.

`.github/workflows/web.yml` builds and checks the site on every pull request and
deploys it to GitHub Pages on pushes to `main`. The site is served from
<https://www.openhap.org/>. The custom domain lives in two places on purpose: as
a repository setting, and as `web/CNAME`, which the asset rule copies into the
output so the deploy artifact always carries it. Change both together.

## How a page is made

Every source format is reduced to one HTML **body fragment** and wrapped in the
shared chrome:

| Source                | Renderer                        |
| --------------------- | ------------------------------- |
| `web/*.body.html`     | none — the fragment is the file |
| `INSTALL.md`          | `lowdown -Thtml`                |
| `man/*/*.1 .3p .5 .8` | `mandoc -Thtml -O fragment`     |
| `lib/**/*.pod`        | `pod2man` then the same mandoc  |

`web/footer.body.html` is the footer prose, and `web/manuals.body.html` would
replace the opening of the manual index. Both are optional.

## Adding a page or a manual

- **A hand-written page** — add `web/<name>.body.html` and one `page` block to
  `.fuguwebrc`. Add a `nav` block only if it belongs there; the navigation is
  six items and should stay that way. Nothing else needs an edit:
  `fuguweb check` reads the same description the build reads.
- **A manual** — write it under a directory that a `manuals` group already
  names, and it is staged, rendered and indexed with no further edit. A `.pod`
  sidecar under a `modules` directory needs no edit either.
- **A new namespace** — add one `modules` block. Never name `lib/App` as a
  `modules` directory: it holds three namespaces, and one group would swallow
  all of them.
- **Prose that belongs to the project rather than the site** — it goes in
  `README.md`, `INSTALL.md`, `man/`, or a `.pod` sidecar, and the site renders
  it. The root `CLAUDE.md` placement table decides; `web/*.body.html` is for
  site-specific framing only.

## Findings worth not rediscovering

- **mandoc picks a local or a remote `.Xr` target by looking for a file named
  `%N.%S` in its working directory**, exactly as mandoc(1) documents. That is
  why `App::FuguWeb::Site` stages every mdoc source into `$(WEBOUT)/.man/` under
  its `staged_name` and runs mandoc there, with the `cwd` option of
  `Fugu::Process->run`. The Fugu pages are staged under their full
  `Fugu::<Module>.3p` names, which the `namespace` setting of their group
  supplies.
- **Local links carry a `./` prefix.** A relative URL whose first path segment
  contains a colon is parsed as a scheme, so a bare `Fugu::Daemon.3p.html` href
  would be read as the `fugu:` protocol. `App::FuguWeb::Render` emits `./` in
  its `-O man=` template, `App::FuguWeb::Index` emits it in every entry, and
  `App::FuguWeb::Check` fails a page that drops it.
- **`pod2man` renders `L<Some::Module>` as italic text, not a link.** POD pages
  therefore cross-reference as plain text while mdoc pages link. This is
  accepted: making it work would mean post-processing mandoc's HTML.
- **The build must not vary with the machine.** `mandoc -I os=` pins the footer,
  which otherwise names the build host's OS, and `App::FuguWeb::Site->pod_date`
  gives `pod2man --date` the checkout's last commit date, because the default is
  the file mtime and git does not preserve those.
- **`!=` shell assignment is not portable enough to rely on.** GNU make 3.81,
  which is what macOS ships, silently ignores it. This is why no list of sources
  is computed in the `Makefile` any more: `.fuguwebrc` names directories, and
  the tool reads them.
