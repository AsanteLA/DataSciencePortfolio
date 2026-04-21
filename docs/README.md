# Portfolio site

This directory is the source for the GitHub Pages build of the project portfolio.

## Publish to GitHub Pages

1. Push this repo to GitHub.
2. Repo → **Settings** → **Pages**.
3. Source: **Deploy from a branch**.
4. Branch: `main` (or whatever your default is), folder: `/docs`.
5. Save.

GitHub will serve the site at `https://<your-username>.github.io/<repo-name>/`
within a minute or two. The `.nojekyll` file in this folder disables Jekyll
processing so the static HTML, CSS, and JS serve as-is.

## Local preview

Any static server works:

```bash
# from the docs/ directory
python3 -m http.server 4000
# then open http://localhost:4000
```

## Structure

```
docs/
├── index.html       Overview / landing page
├── project.html     Full project write-up
├── results.html     Accuracy table + forecast plots
├── about.html       About the author + AI-collaboration notes
├── assets/
│   ├── css/style.css
│   ├── js/main.js   Scroll reveal + page-fade transitions
│   └── images/      Plots copied from /plots
└── .nojekyll        Disables Jekyll so raw HTML serves
```

## Updating the plots

After running `forecast_pipeline.R` in RStudio:

```bash
cp plots/*.png docs/assets/images/
```

Then commit and push. GitHub Pages redeploys in ~60 seconds.
