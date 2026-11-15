#!/usr/bin/env python3
"""Builds StudioSim's website (docs/website.md says how it is put together and published).

    python3 website/build.py            the site, into website/_site
    python3 website/build.py --check    and every link in it followed: a page, picture or heading that isn't there fails
    python3 website/build.py --serve    and served at http://localhost:8788, to look at (--serve 9000 for another port)

The pages are website/pages/*.html (a few lines saying what each is, then its content), set in
website/templates/base.html. The guide's pages are the project's own documentation, docs/*.md, turned into HTML by the
small Markdown reader below, which reads the Markdown the docs are written in (headings, paragraphs, lists in lists,
tables, code) and stops at anything else rather than guess. website/static/ is copied as it is. There is nothing to
install: it needs Python 3 and its standard library alone.
"""

import html
import os
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DOCS = HERE.parent / "docs"
OUT = HERE / "_site"
# Where the site is published ("https://studiosim.example"), for the addresses a page gives of itself (its canonical
# link, its picture when it is shared, the sitemap). Left empty, those are left out. Set it where the site is built.
SITE_URL = os.environ.get("SITE_URL", "").rstrip("/")
# The source, and the downloads: always the latest release's (made by .github/workflows/release.yml, under these names),
# its version the one in the game's project file.
SOURCE_URL = "https://github.com/AngusA1210/StudioSim"
LATEST = SOURCE_URL + "/releases/latest/download/"
VERSION = re.search(r'^config/version="([^"]*)"', (HERE.parent / "game" / "project.godot").read_text(encoding="utf-8"), re.M).group(1)

# The guide: the docs it is made of, in order, in two groups. [file's name without .md, its name in the list, what it
# covers (the page's description, for search engines and where it is shared)]
GUIDE = [
    ("Using StudioSim", [
        ("controls", "Controls", "Every key and shortcut, your body in the room, and the free camera."),
        ("playing-and-menu", "Playing, patterns and the menu", "The tutorial, playing by hand, the pattern editor, tempo and the menu's pages."),
        ("instruments", "Instruments, microphones and amps", "Every instrument, microphones and stereo pairs, live inputs, desktop audio, amps and pedals."),
        ("rooms-and-recording", "Rooms and recording", "Saving rooms, templates, the timeline, recording, editing clips and automation."),
        ("mixing", "Tracks, folders and the mix", "Routing folders, aux tracks and sends, the room and the mix, the mix window."),
        ("room-acoustics", "The room: size, walls and materials", "Walls, materials, reverb, reflections and how sound gets round a wall."),
        ("plugins", "Plug-ins and presets", "VST3 and Audio Unit plug-ins, plug-in instruments, and presets."),
        ("playing-together", "Playing together", "The room browser, hosting and joining, what is shared, recording together."),
    ]),
    ("Under the hood", [
        ("architecture", "How it's put together", "The source tree, the audio engine and its threads."),
        ("building", "Building and running", "What each platform needs, the build script, and making the app."),
        ("session-server", "Running a session server", "The small program players can meet through where routers won't open ports."),
        ("website", "The website", "How this site is built from the docs, its screenshots, and how it is published."),
        ("roadmap", "Roadmap", "What is done, and what comes next."),
    ]),
]
GUIDE_PAGES = [page for _, pages in GUIDE for page in pages]


# ── Markdown ─────────────────────────────────────────────────────────────────────────────────────────────────

class Markdown:
    """The Markdown the docs are written in, as HTML. `link` is given each link's address and returns the one to use."""

    LIST_ITEM = re.compile(r"^( *)([-*]|\d+\.)( +)(.*)$")
    HEADING = re.compile(r"^(#{1,6}) +(.*?)\s*$")
    FENCE = re.compile(r"^```(\S*)\s*$")
    TABLE_RULE = re.compile(r"^\|?( *:?-+:? *\|)+ *:?-*:? *$")

    def __init__(self, link=None):
        self.link = link or (lambda address: address)
        self.headings = []  # (level, id, its words as HTML), in order
        self._ids = {}

    # Inline: code, links, bold and italics, with everything else made safe to put in a page.
    def inline(self, text):
        kept = []

        def keep(piece):
            kept.append(piece)
            return "\x00%d\x00" % (len(kept) - 1)

        text = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|<>~])", lambda m: keep(html.escape(m.group(1))), text)
        text = re.sub(r"(`+)(.+?)(?<!`)\1(?!`)", lambda m: keep("<code>%s</code>" % html.escape(m.group(2).strip())), text)
        text = html.escape(text, quote=False)

        def anchor(m):
            address = self.link(html.unescape(m.group(2)))
            outside = ' rel="noopener"' if re.match(r"https?://", address) else ""
            return keep('<a href="%s"%s>' % (html.escape(address), outside)) + m.group(1) + keep("</a>")

        text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", anchor, text)
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])", r"<em>\1</em>", text)
        while "\x00" in text:
            text = re.sub(r"\x00(\d+)\x00", lambda m: kept[int(m.group(1))], text)
        return text

    # A heading's id, as GitHub makes them (so the docs' own links to their headings work here too).
    def heading_id(self, words):
        plain = re.sub(r"<[^>]+>", "", words)
        plain = html.unescape(plain).lower()
        slug = re.sub(r"[^\w\- ]", "", plain).replace(" ", "-")
        count = self._ids.get(slug, 0)
        self._ids[slug] = count + 1
        return slug if count == 0 else "%s-%d" % (slug, count)

    def _starts_block(self, line, in_paragraph=False):
        if self.HEADING.match(line) or self.FENCE.match(line.strip()) or line.lstrip().startswith("|"):
            return True
        item = self.LIST_ITEM.match(line)
        if not item:
            return False
        # (a numbered list breaks into a paragraph only from 1: "5. The panel..." mid-paragraph is a sentence)
        return not in_paragraph or item.group(2) in ("-", "*", "1.")

    def render(self, text):
        return self.blocks(text.replace("\t", "    ").split("\n"))

    def blocks(self, lines):
        out = []
        i = 0
        while i < len(lines):
            line = lines[i]
            if not line.strip():
                i += 1
                continue
            fence = self.FENCE.match(line.strip())
            if fence:
                body = []
                i += 1
                while i < len(lines) and not self.FENCE.match(lines[i].strip()):
                    body.append(lines[i])
                    i += 1
                i += 1
                language = ' class="language-%s"' % html.escape(fence.group(1)) if fence.group(1) else ""
                out.append("<pre><code%s>%s</code></pre>" % (language, html.escape("\n".join(body))))
                continue
            heading = self.HEADING.match(line)
            if heading:
                level = len(heading.group(1))
                words = self.inline(heading.group(2))
                ident = self.heading_id(words)
                self.headings.append((level, ident, words))
                out.append('<h%d id="%s">%s</h%d>' % (level, ident, words, level))
                i += 1
                continue
            if line.lstrip().startswith("|") and i + 1 < len(lines) and self.TABLE_RULE.match(lines[i + 1].strip()):
                rows = []
                while i < len(lines) and lines[i].lstrip().startswith("|"):
                    rows.append(lines[i].strip())
                    i += 1
                out.append(self.table(rows))
                continue
            if self.LIST_ITEM.match(line):
                i, made = self.list(lines, i)
                out.append(made)
                continue
            if line.startswith(" " * 4) or line.lstrip().startswith((">", "<", "![")):
                raise ValueError("Markdown this reader doesn't know: %r" % line)
            paragraph = [line.strip()]
            i += 1
            while i < len(lines) and lines[i].strip() and not self._starts_block(lines[i], True):
                paragraph.append(lines[i].strip())
                i += 1
            out.append("<p>%s</p>" % self.inline(" ".join(paragraph)))
        return "\n".join(out)

    def table(self, rows):
        def cells(row):
            row = row.strip()
            row = row[1:] if row.startswith("|") else row
            row = row[:-1] if row.endswith("|") and not row.endswith("\\|") else row
            return [cell.strip() for cell in re.split(r"(?<!\\)\|", row)]

        head = cells(rows[0])
        out = ['<div class="table"><table>', "<thead><tr>%s</tr></thead>" % "".join("<th>%s</th>" % self.inline(c) for c in head), "<tbody>"]
        for row in rows[2:]:
            out.append("<tr>%s</tr>" % "".join("<td>%s</td>" % self.inline(c) for c in cells(row)))
        out.append("</tbody></table></div>")
        return "\n".join(out)

    # A list from line `i`: each item's lines (those set in under it, a blank line between them or not) read as blocks
    # of their own, so that lists in lists, and paragraphs after them, come out as written.
    def list(self, lines, i):
        first = self.LIST_ITEM.match(lines[i])
        indent = len(first.group(1))
        ordered = first.group(2)[0].isdigit()
        items = []
        while i < len(lines):
            item = self.LIST_ITEM.match(lines[i])
            if not item or len(item.group(1)) != indent or item.group(2)[0].isdigit() != ordered:
                break
            inside = indent + len(item.group(2)) + len(item.group(3))
            body = [item.group(4)]
            i += 1
            while i < len(lines):
                line = lines[i]
                if not line.strip():  # a blank line: the item goes on only if what follows is set in under it
                    after = i
                    while after < len(lines) and not lines[after].strip():
                        after += 1
                    if after < len(lines) and len(lines[after]) - len(lines[after].lstrip(" ")) >= inside:
                        body.extend([""] * (after - i))
                        i = after
                        continue
                    break
                set_in = len(line) - len(line.lstrip(" "))
                if set_in >= inside:
                    body.append(line[inside:])
                elif self._starts_block(line) or not body[-1].strip():
                    break
                else:  # (a line of the paragraph above, not set in as far as it should be)
                    body.append(line.strip())
                i += 1
            items.append(self.blocks(body))
            while i < len(lines) and not lines[i].strip():  # (blank lines between items)
                following = i
                while following < len(lines) and not lines[following].strip():
                    following += 1
                next_item = self.LIST_ITEM.match(lines[following]) if following < len(lines) else None
                if next_item and len(next_item.group(1)) == indent and next_item.group(2)[0].isdigit() == ordered:
                    i = following
                else:
                    break
        tag = "ol" if ordered else "ul"
        made = []
        for body in items:
            # An item of one paragraph alone reads as a line, without the paragraph's own spacing.
            single = re.fullmatch(r"<p>(.*)</p>", body, re.S)
            if single and "<p>" not in single.group(1):
                body = single.group(1)
            made.append("<li>%s</li>" % body)
        return i, "<%s>\n%s\n</%s>" % (tag, "\n".join(made), tag)


# ── Pages ────────────────────────────────────────────────────────────────────────────────────────────────────

def fill(template, values):
    """`template` with each {{name}} replaced by its value, and {{active:name}} marking the page's own link."""
    def active(m):
        return ' aria-current="page"' if values.get("nav") == m.group(1) else ""

    template = re.sub(r"\{\{active:([\w-]+)\}\}", active, template)

    def value(m):
        if m.group(1) not in values:
            raise KeyError("nothing given for {{%s}}" % m.group(1))
        return str(values[m.group(1)])

    return re.sub(r"\{\{([\w-]+)\}\}", value, template)


def read_page(path):
    """A page's source: lines of `name: value` (title, description, nav, and so on), a line of ---, then its content."""
    head, _, content = path.read_text(encoding="utf-8").partition("\n---\n")
    about = {}
    for line in head.splitlines():
        if line.strip():
            name, _, value = line.partition(":")
            about[name.strip()] = value.strip()
    return about, content


def write(relative, text):
    target = OUT / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def page_html(base, relative, about, content):
    """A whole page: its content set in the base template, with the addresses it gives of itself."""
    depth = relative.count("/")
    root = "../" * depth
    if relative == "404.html":  # (shown for an address anywhere in the site: its links start from the top)
        root = "/"
    address = "" if relative == "index.html" else relative
    share = ""
    if SITE_URL:
        share = ('<link rel="canonical" href="%s/%s">\n<meta property="og:url" content="%s/%s">\n<meta property="og:image" content="%s/img/%s">\n'
                 '<meta name="twitter:card" content="summary_large_image">') % (
            SITE_URL, address, SITE_URL, address, SITE_URL, about.get("image", "room-overview.jpg"))
    values = {"title": html.escape(about["title"], quote=False), "description": html.escape(about["description"].replace("{{version}}", VERSION), quote=True), "nav": about.get("nav", ""), "root": root,
              "version": VERSION, "source": SOURCE_URL, "mac_dmg": LATEST + "StudioSim-macOS.dmg",
              "windows_setup": LATEST + "StudioSim-Windows-Setup.exe", "releases": SOURCE_URL + "/releases",
              "share": share, "content": content, "class": about.get("class", "page")}
    values["content"] = fill(content, values) if about.get("fill", "yes") == "yes" else content
    return fill(base, values)


def build_guide(base):
    names = {name for name, _, _ in GUIDE_PAGES}
    template = (HERE / "templates" / "guide.html").read_text(encoding="utf-8")

    def link(address):
        if re.match(r"(https?:|mailto:|#)", address):
            return address
        target, _, part = address.partition("#")
        if target == "../README.md":  # (the project's own front page: here, the site's)
            return "../index.html"
        if target.endswith(".md") and target[:-3] in names:
            return target[:-3] + ".html" + ("#" + part if part else "")
        raise ValueError("a link to %r, which isn't one of the guide's pages" % address)

    for n, (name, label, _) in enumerate(GUIDE_PAGES):
        reader = Markdown(link)
        try:
            article = reader.render((DOCS / (name + ".md")).read_text(encoding="utf-8"))
        except ValueError as problem:
            sys.exit("docs/%s.md: %s" % (name, problem))
        title = re.sub(r"<[^>]+>", "", next((words for level, _, words in reader.headings if level == 1), label))
        sidebar = []
        for group, pages in GUIDE:
            sidebar.append('<p class="guide-group">%s</p>\n<ul>' % group)
            for other, other_label, _ in pages:
                current = ' aria-current="page"' if other == name else ""
                sidebar.append('<li><a href="%s.html"%s>%s</a></li>' % (other, current, html.escape(other_label)))
            sidebar.append("</ul>")
        sections = [(ident, words) for level, ident, words in reader.headings if level == 2]
        contents = ""
        if len(sections) > 1:
            contents = '<nav class="on-this-page" aria-label="On this page">\n<p>On this page</p>\n<ul>\n%s\n</ul>\n</nav>' % "\n".join(
                '<li><a href="#%s">%s</a></li>' % (ident, re.sub(r"</?(a|code)[^>]*>", "", words)) for ident, words in sections)
        before = GUIDE_PAGES[n - 1] if n > 0 else None
        after = GUIDE_PAGES[n + 1] if n + 1 < len(GUIDE_PAGES) else None
        turn = '<nav class="turn" aria-label="More of the guide">%s%s</nav>' % (
            '<a class="turn-back" href="%s.html"><span>Before</span>%s</a>' % (before[0], html.escape(before[1])) if before else "<span></span>",
            '<a class="turn-on" href="%s.html"><span>Next</span>%s</a>' % (after[0], html.escape(after[1])) if after else "")
        content = fill(template, {"sidebar": "\n".join(sidebar), "article": article, "contents": contents, "turn": turn})
        about = {"title": "%s · StudioSim guide" % html.unescape(title), "description": GUIDE_PAGES[n][2], "nav": "guide", "fill": "no", "class": "page guide-page"}
        write("guide/%s.html" % name, page_html(base, "guide/%s.html" % name, about, content))

    # The guide's front page: its pages in their groups.
    cards = []
    for group, pages in GUIDE:
        cards.append('<h2>%s</h2>\n<div class="guide-list">' % group)
        for name, label, _ in pages:
            cards.append('<a class="guide-card" href="%s.html"><strong>%s</strong></a>' % (name, html.escape(label)))
        cards.append("</div>")
    about, content = read_page(HERE / "pages" / "guide.html")
    about["fill"] = "no"
    write("guide/index.html", page_html(base, "guide/index.html", about, fill(content, {"guide": "\n".join(cards), "root": "../"})))


def build():
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(HERE / "static", OUT)
    base = (HERE / "templates" / "base.html").read_text(encoding="utf-8")
    made = []
    for source in sorted((HERE / "pages").glob("*.html")):
        if source.name == "guide.html":
            continue
        about, content = read_page(source)
        write(source.name, page_html(base, source.name, about, content))
        made.append(source.name)
    build_guide(base)
    made += ["guide/index.html"] + ["guide/%s.html" % name for name, _, _ in GUIDE_PAGES]
    if SITE_URL:
        listed = [page for page in made if page != "404.html"]
        write("sitemap.xml", '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n%s\n</urlset>\n' % "\n".join(
            "  <url><loc>%s/%s</loc></url>" % (SITE_URL, "" if page == "index.html" else page) for page in listed))
        write("robots.txt", "User-agent: *\nAllow: /\nSitemap: %s/sitemap.xml\n" % SITE_URL)
    else:
        write("robots.txt", "User-agent: *\nAllow: /\n")
    return made


# ── Checking ─────────────────────────────────────────────────────────────────────────────────────────────────

def check():
    """Every link and picture in the built site followed: the file there, and the heading in it if one is named."""
    ids = {}
    pages = sorted(OUT.rglob("*.html"))
    for page in pages:
        ids[page] = set(re.findall(r'\bid="([^"]+)"', page.read_text(encoding="utf-8")))
    problems = []
    for page in pages:
        text = page.read_text(encoding="utf-8")
        for address in re.findall(r'\b(?:href|src)="([^"]+)"', text):
            address = html.unescape(address)
            if re.match(r"(https?:|mailto:|data:)", address):
                continue
            target, _, part = address.partition("#")
            file = page if target == "" else (OUT / target.lstrip("/") if target.startswith("/") else page.parent / target).resolve()
            if file.is_dir():
                file = file / "index.html"
            if not file.exists():
                problems.append("%s: %s isn't there" % (page.relative_to(OUT), address))
            elif part and file.suffix == ".html" and part not in ids.get(file, set()):
                problems.append("%s: %s has no heading called #%s" % (page.relative_to(OUT), target or "the page", part))
        if "{{" in re.sub(r"<code[^>]*>.*?</code>", "", text, flags=re.S):  # (but for code that speaks of them)
            problems.append("%s: something was left unfilled ({{...}})" % page.relative_to(OUT))
    for problem in problems:
        print("  [FAIL] " + problem)
    print("The website: %d pages, %s" % (len(pages), "every link leads somewhere" if not problems else "%d links lead nowhere" % len(problems)))
    return not problems


def serve(port):
    import functools
    import http.server

    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(OUT))
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as server:
        print("The website is at http://localhost:%d (Ctrl-C stops it)" % port)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    arguments = sys.argv[1:]
    pages = build()
    if "--check" in arguments:
        sys.exit(0 if check() else 1)
    print("Built %d pages into %s" % (len(pages), OUT))
    if "--serve" in arguments:
        after = arguments[arguments.index("--serve") + 1:]
        serve(int(after[0]) if after and after[0].isdigit() else 8788)
