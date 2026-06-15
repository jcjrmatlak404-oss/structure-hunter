# Publishing Structure Hunter to GitHub — step by step

You have a complete, ready-to-publish repository. Here's how to get it onto GitHub. Two routes: the easy web-only way (no command line), and the standard `git` way.

---

## What you have

Unzip `structure-hunter.zip` and you'll get a folder `structure-hunter/` containing:

```
structure-hunter/
├── hunter.rb          the program (v34)
├── README.md          the front page people see
├── LICENSE            MIT license
├── DISCLAIMER.md      responsible-use notice
├── setup.sh           dependency installer (macOS/Linux)
├── setup.bat          dependency installer (Windows)
├── run.sh             convenience launcher
├── .gitignore         keeps cache/output files out of the repo
└── docs/
    └── screenshot.png shown in the README
```

This is the whole repository. Nothing else is needed.

---

## Route A — the easy way (web browser only, no git)

1. **Make a GitHub account** at https://github.com if you don't have one (free).

2. **Create a new repository:**
   - Click the **+** in the top-right → **New repository**.
   - **Repository name:** `structure-hunter` (or whatever you like).
   - **Description:** *Find structures missing from official records using footprints, addresses, and LiDAR.*
   - Set it to **Public**.
   - Do **not** check "Add a README" (you already have one).
   - Click **Create repository**.

3. **Upload your files:**
   - On the new empty repo page, click **uploading an existing file** (the link in the page text), or go to **Add file → Upload files**.
   - Open your unzipped `structure-hunter` folder, select **all the files inside it** (including the `docs` folder), and drag them into the browser.
   - Wait for them to finish uploading.
   - At the bottom, click **Commit changes**.

4. **Done.** Your repo is live at `https://github.com/YOUR-USERNAME/structure-hunter`. The README displays automatically with the screenshot.

> Note: when dragging, drag the **contents** of the `structure-hunter` folder (the files and the `docs` folder), not the outer folder itself — so that `README.md` ends up at the top level of the repo.

---

## Route B — the standard way (using git)

If you have `git` installed:

```bash
# unzip, then:
cd structure-hunter

git init
git add .
git commit -m "Initial release — Structure Hunter v34"

# create an empty repo on github.com first (Route A step 2, without uploading),
# then copy its URL and:
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/structure-hunter.git
git push -u origin main
```

---

## After publishing — nice touches

- **Add topics** (on the repo page, click the gear next to "About"): `lidar`, `gis`, `geospatial`, `ruby`, `openstreetmap`, `remote-sensing`. This helps people find it.
- **Fill the "About" sidebar** with the one-line description and, optionally, leave the website field blank (it runs locally).
- **Pin it** to your profile if you'd like it featured.
- **Releases:** later, you can cut a "Release" (Releases → Draft a new release, tag `v34`) so people can download a versioned snapshot.

---

## When people ask "how do I run it?"

The README already answers this, but the short version you can tell anyone:

1. Install Ruby (and Python 3 for the LiDAR features).
2. Download or clone the repo.
3. Run `ruby hunter.rb`.
4. Open `http://localhost:8080`.

That's the whole pitch of the GitHub route: anyone technical can be running their own copy in a couple of minutes, at no cost to you and with no servers to maintain.
