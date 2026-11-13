# Vision

Araneola exists to answer one question about a site: which URLs does it actually
serve, and which of them should a search engine index? Its answer is a file whose
format is somebody else's specification, and every rule in the code exists so that
the file is earned rather than guessed at — in scope, allowed by `robots.txt`,
canonically one URL, fetched before it is listed. This document is about where that
idea should go next.

## Where araneola is today

Araneola is about 2,100 lines of GNU Guile Scheme in six modules and a
command-line front end, plus a 600-line suite that runs against a local fixture
site with no network: `url.scm` owns every decision about what a URL is,
`html.scm` turns a document into links, `robots.scm` implements RFC 9309,
`http.scm` fetches under every failure it can imagine, `sitemap.scm` writes the
file, and `araneola.scm` walks the frontier.

What exists is a policy, not just a loop:

- a breadth-first frontier with an explicit queue, and a URL marked visited
  *before* it is fetched, so two parents linking to one page cannot both fetch it;
- `robots.txt` consulted once per host and cached, with `Crawl-delay` folded into
  the politeness delay as a floor rather than an alternative;
- `<meta name="robots">`, `X-Robots-Tag` and Google's own spellings of noindex read
  per page, and `rel="canonical"` folding two spellings of a page into one URL;
- redirects followed with loop detection, the final URL reported to the writer,
  and `--exclude`/`--include` regular expressions matched against canonical URLs
  *before* a request is made, so a pagination trap costs nothing at all;
- per-request timeouts, a body cap, and retries with exponential backoff that
  honour `Retry-After`;
- sitemaps written to `.tmp` and renamed when the crawl finishes, split into an
  index past 50,000 URLs or 50 MB, with XML escaping and `lastmod` from
  `Last-Modified`.

Two design decisions constrain everything after this. The first is that a crawl is
*serial and polite*: one request is in flight at a time and the delay is a sleep in
the frontier loop, so throughput is deliberately the last thing the crawler
optimises. The second is that the crawl is assembled from parts that already know
how to be reused — the `visited-urls` parameter exists so a caller can hand in a
warm table, the writer behind `open-sitemap-writer` is an interface of four calls,
and the statistics alist carries a `stopped-by` reason. Those are seams for
features that are not built yet, and this document is largely about which to take.

Distribution is the honest gap: a Guile channel, a Nix flake, a container image and
recipes for Debian, openSUSE and Arch under `packaging/`, but no archive ships the
crawler yet.

## The vision

1. **A crawl is evidence, not an assertion.** Every listed URL has been fetched,
   allowed by `robots.txt` and proven to be the canonical URL for what it points
   at, and every URL that was *not* listed comes with a reason.

2. **A crawl is interruptible without being lossy.** The frontier and the set of
   URLs already written survive the process, so a crawl of two hundred thousand
   pages can be stopped on Friday and continued on Monday, and what it produces is
   indistinguishable from a single run.

3. **Araneola speaks the whole sitemap family.** Image, video and news extensions,
   `xhtml:link` alternates for translations, and an index that is read as readily
   as it is written — with per-entry metadata taken from the page.

4. **Politeness is per host, and it does not cost throughput.** The delay becomes a
   per-host budget rather than a global sleep, so one crawl can walk several sites
   at once while each is still asked for no more than its own `Crawl-delay` allows.

5. **A crawl is something a build can fail on.** A machine-readable report and an
   exit status turn the crawler into a site-health check: a page that has started
   returning 404, or grown a noindex, breaks the build rather than being found late.

## Features that are in scope and not built yet

- **Image sitemaps.** The README's own `TODO` documents the `sitemap-image/1.1`
  extension, and `page-analysis` already walks the SXML tree for links, so
  collecting `src` and `srcset` is a sibling traversal. The hard part is
  provenance: image URLs may be CDN-hosted, must be absolutised against
  `<base href>`, are capped at 1,000 per URL, and are only useful when the sitemap
  and the `robots.txt` that governs them agree about where they live.
- **Reading a sitemap index.** The writer splits past 50,000 URLs and nothing reads
  those files back. A sitemap used as a *seed* breaks the one assumption the crawl
  rests on — that it never leaves the seed host — so `is-interesting-url?` needs a
  scope that is a set of URLs rather than an origin, without becoming a way to
  crawl the web by accident.
- **Resumable crawls.** `visited-urls` and `stopped-by` are the seams. The hard
  part is that "visited" and "written" are different sets: a resume that trusts the
  visited table produces a complete-looking sitemap with holes, so the state has to
  record what the writer accepted, not what the fetcher saw.
- **Video and news extensions.** The writer streams one `<url>` at a time, so the
  extension is a widening of `sitemap-add!`. The hard part is the required tags —
  `video:thumbnail_loc`, `news:publication_date` — and a page that does not carry
  them must be omitted from that extension rather than emitted as invalid XML.
- **`xhtml:link` alternates.** Grouping them is the work: recognising that two URLs
  under different hosts are one page in two languages means reading `hreflang` and
  `rel="alternate"`, which the HTML module does not look at today.
- **A report mode.** The crawl already counts what it refused — `noindex`,
  `filtered`, `skipped-robots`, `error-kinds` as a histogram. The hard part is
  deciding what belongs in a report a human reads and what belongs in one a script
  reads, without shipping the same information twice.

## New features that would be worth having

- **A per-host politeness budget.** A token bucket per host, refilled by
  `Crawl-delay` or by a default, with the frontier asking it for the next slot. The
  cheapest route to concurrency that is still defensible to a site owner, because
  the guarantee is per host rather than per crawl.
- **A JSON crawl report on `--report FILE`.** Every counter exists in the
  statistics alist already. A small versioned schema — pages fetched, statuses by
  code, what was excluded and why — makes araneola usable from a build without
  parsing a log line.
- **Structured data extraction.** Parsing `application/ld+json` would let the
  crawler emit news and video entries from what the page already declares, and give
  it a place to notice structured data that is invalid.
- **Diffing two crawls.** "Which URLs appeared, which disappeared, which changed
  status" is the answer a site that deploys weekly wants, and it is a pure function
  of two reports.
- **Feeds as a link source.** RSS and Atom name pages that often have no inbound
  link. Reading them with the existing SXML parser is small; the scope question — a
  feed URL is not a page URL — is the part to think about.
- **A headless rendering hook** (speculative, and probably not in scope): a
  `--render` that shells out to a browser would show what a JavaScript-heavy site
  actually serves, at two orders of magnitude per page and at the cost of the whole
  politeness model. A Shepherd service for nightly crawls is speculative in the same
  way, and is what most operators actually want.

## Contributions that would move the needle

1. **The JSON report.** Highest value per hour by a wide margin: the data is
   gathered, the shape is a design decision rather than an engineering one, and it
   turns the project into something a build runs.
2. **Image sitemaps.** Bounded, documented, self-contained, with a specification to
   test against, a README section already written and no architectural risk.
3. **Per-host politeness accounting.** Small and testable, and it removes the main
   obstacle to every later performance idea, concurrency included.
4. **Crawl state on disk.** The largest, and the one with the widest consequences:
   a prerequisite for conditional requests, incremental crawling and the resume
   story the vision rests on.
5. **Sitemap index ingestion.** Valuable and dangerous, being the one feature that
   can widen the crawl scope; it wants a design note before a patch.
6. **Packaging into the archives.** Turning the three recipes into accepted
   packages is unglamorous, out-of-tree work with a real payoff: an operator who
   installs from their distribution has no reason to trust a checkout. The README's
   installation section, still describing 0.0.2, is the same chore seen from the
   other side, and just as worth the hour.

## Compared to related projects

| Project | What it is | Where araneola differs |
| --- | --- | --- |
| Scrapy | A Python crawling *framework*: you write spiders and it supplies scheduling, pipelines and concurrency | A finished program with one output; no spider to write, no Python runtime, and the crawl policy is not assembled by the caller |
| Katana (projectdiscovery) | A fast Go crawler for security reconnaissance, with headless-browser support | Built for discovery breadth and speed against targets you are testing; here `robots.txt`, `noindex` and `rel="canonical"` decide the output rather than decorate it |
| `wget --mirror` / wget2 | Recursive downloaders that walk a site and save what they find | wget saves files and leaves the analysis to the reader; araneola publishes a protocol-valid sitemap and refuses to leave the seed host |
| Screaming Frog SEO Spider | A proprietary desktop crawler with rendering, segmentation and reporting | Free, headless and scriptable, with every rule in 2,100 readable lines — at the cost of no rendering and no report UI |
| Crawlee | A Node/TypeScript crawling and browser-automation library | The same class as Scrapy with a browser bundled in; araneola needs nothing beyond Guile and never runs a page's JavaScript |
| Hosted sitemap generators | Upload-and-wait services, usually quota-bound | Runs on your own machine, with no URL quota and no credentials handed to anybody |
| Haunt and site generators' sitemap plugins | Emit a sitemap at build time from the source tree | araneola crawls the *deployed* site, so it sees the redirect, the 404, the canonical a template got wrong — and the pages that never were in the source tree |

What the others do that araneola could still add sits on two axes: the frameworks
have concurrency and rendering, both winnable without becoming a framework (a
per-host budget gives the first, an explicit opt-in hook as much of the second as a
politeness-first crawler can honour), and the commercial crawlers have reporting,
which is a schema and a renderer away.

Where araneola is ahead and should stay ahead: one package with no runtime beside
Guile; correctness rules for `robots.txt`, canonicalisation and noindex that are
tested assertions rather than heuristics; an atomically written sitemap; and
defaults safe enough that pointing it at a site you do not own is not reckless.
Those properties are why it can run on a production host, and trading them for
throughput would trade the reason it exists.

## In the long run

The first multi-year bet is that **the crawler becomes a library with a CLI on
top**. The writer interface, the statistics alist and the `visited-urls` parameter
are already that shape, and the CLI could be one caller among several: a site
generator checking its own output, a linter failing a build on a dead internal link,
a monitor noticing a page that started returning 500 — one crawl, several writers.

The second is that **correctness over throughput ages well**. Crawlers that are fast
and careless get blocked, which makes them slow; one whose default behaviour a site
owner would not object to can be run against anything.

The third is **distribution as a feature**. The channel and the flake exist; an
araneola in Debian, openSUSE and Arch, with a licence, a manual page and a launcher
in the usual places, is the difference between a project people try and one they
depend on. The one thing this document does not argue for is a crawl of the open
web: that is a different project with different ethics, and none of the code here
is pointed at it.

## What would make this document wrong

If the sitemap protocol stops mattering, items one and three become historical and
the report, the resumability and the per-host politeness are what remain worth
having. If a rendering crawler becomes the only kind anyone needs, the politeness
model is the part to revisit first, because it assumes a page costs one request.
Either way, the seams this document leans on are the ones the code already has.

*A vision describes intent, not commitments: nothing here is promised for a
release, and the speculative items say so.*
