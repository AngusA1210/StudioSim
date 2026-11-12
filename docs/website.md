# The website

StudioSim's website is in `website/`: a front page, a features page, a download page, the guide and an about page.
It is a static site, built by one Python script with nothing to install, and published free on Cloudflare.

```bash
python3 website/build.py --serve
```

builds it into `website/_site` (not kept in git) and serves it at http://localhost:8788 to look at. Without
`--serve` it only builds. With `--check` it builds and then follows every link and picture in the site, and fails if
one leads nowhere; `tools/build.sh` runs that with the other checks.

## How it's put together

```
website/
  build.py           builds the site: the pages set in the template, the guide made from docs/, static/ copied
  templates/         base.html (the header, footer and what every page shares) and guide.html (a guide page's frame)
  pages/             each page: a few lines saying what it is (title, description, nav), a line of ---, its content
  static/            copied as it is: css/site.css, js/site.js, img/ (the screenshots and icons), _headers
  tools/screenshots.gd   stages the app and takes the screenshots
wrangler.jsonc       (at the top of the repository) which folder Cloudflare serves
```

- **The pages** are plain HTML. `{{root}}` in one is the way back to the site's top (so links work from any folder).
- **The guide is the docs.** Each page under `/guide/` is one of `docs/*.md`, turned into HTML by the small Markdown
  reader in `build.py`. Change a doc and the guide changes with it; nothing is written twice. `GUIDE` at the top of
  `build.py` lists which docs are in it, in what order, and what the guide's front page says each covers. The reader
  knows the Markdown the docs use (headings, paragraphs, lists in lists, tables, code blocks, links, bold) and stops
  with a message at anything else, rather than guess.
- **The look** is `static/css/site.css`: dark, as the app is, with its accent and the instruments' colours. There are
  no fonts, scripts or pictures from other sites, so the pages load fast and nothing tracks a visitor.
- **`static/_headers`** is read by Cloudflare: it has the site refuse to load anything from elsewhere (a content
  security policy) and keeps pictures in visitors' browsers for a week.

## The screenshots

The pictures in `static/img/` are of the real app. `website/tools/screenshots.gd` makes a room, puts a miked-up kit
and an amp with pedals in it, records a few seconds, and takes each picture at 1920x1080 into `website/_shots/` (not
kept in git):

```bash
godot --path game --script ../website/tools/screenshots.gd -- --silent
```

Add names after `--silent` to take only some (`mixer,edit`). It runs on a Mac, in a window, without sound, and the
only plug-ins it loads are Apple's own. The pictures of windows are then cropped to the window, and all are saved as
JPEGs (`sips` on a Mac does both). Take them again when the app's look changes.

## Publishing it

The site is published by Cloudflare, from this repository, as a Worker that only serves files: every push to `main`
builds it and puts it live a minute or so later. `wrangler.jsonc`, at the top of the repository, tells Cloudflare
which folder to serve (`website/_site`) and to show the site's own page for an address that isn't there. Setting it
up is done once, in the Cloudflare dashboard, by whoever owns the repository:

1. In the Cloudflare dashboard, open **Workers & Pages**, then **Create application**, and import this repository
   from GitHub (sign in if asked, and give Cloudflare access to **this repository only**; private repositories work).
2. Set it up as follows:
   - **Build command**: `python3 website/build.py`
   - **Deploy command**: `npx wrangler deploy` (as it comes)
   - **Root directory**: `/` (left as it comes: the top of the repository, where `wrangler.jsonc` is. Not
     `website/_site`, which doesn't exist until the build has made it.)
3. Save and deploy. The build's log shows the pages built and the files uploaded, and the site is then at the
   `workers.dev` address the dashboard gives. (The Worker can have any name: Cloudflare's builds use the dashboard's
   name in place of the one in `wrangler.jsonc`.)
4. Once the address is known, add it as a **build variable** (the Worker's **Settings › Build › Build variables and
   secrets**): `SITE_URL` = the site's address, without a slash at its end. The site then gives its own address
   where a page is shared, and a sitemap for search engines. The next push picks it up.

Every push to `main` builds the site, whatever it changed. To build only when the site could have changed, set the
build's **watch paths** (the same settings page) to `website/*`, `docs/*` and `wrangler.jsonc`.

**A domain of its own** (optional, about $10 a year for a `.com`): buy it from any registrar, then in the Worker's
**Settings › Domains & Routes** add it as a custom domain and follow the steps. Change `SITE_URL` to match.

## Later

- **The downloads.** `pages/download.html` and the buttons on the other pages say "Coming soon". At the first
  release, the two cards get links to the release's files (`https://github.com/<owner>/<repository>/releases/latest`
  always leads to the newest), and the "coming soon" labels come out.
- **The videos.** The front page has a place for them. A video kept on another site (YouTube, say) needs that site
  allowed in `static/_headers` (`frame-src`), or it won't show.
- **The source link.** Once the repository is public, the footer and the about page should link to it.
