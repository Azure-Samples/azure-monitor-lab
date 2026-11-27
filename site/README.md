# Scenario guide

Static, read-only companion to the [lab README](../README.md) and [numbered scenarios](../docs/DEMO-SCENARIOS.md). The architecture browser uses the same four lanes and separate Fabric workspace band as the README diagram. Six representative scenarios have shorter guided checklists; all 82 numbered scenarios link to their full walkthroughs in the repository. The source walkthroughs remain authoritative for prerequisites, commands, safety and recovery.

## Run locally

From the repository root:

```powershell
npm test --prefix site
python -m http.server 8000 --directory _site
```

Open `http://localhost:8000/`. Node.js 22+ is required for the build. No package install is needed. The build reads `docs/DEMO-SCENARIOS.md` and copies the architecture assets into the ignored `_site/` output folder. It fails if the source scenario numbering/index changes unexpectedly. Use a local HTTP server rather than opening `index.html` directly, since the catalog is fetched as JSON.

The site stores **only checklist step IDs** in the visitor's browser storage. Checkmarks do not deploy, monitor or validate Azure resources and are not evidence of completion. Search, architecture filters and guide selection work without Azure credentials.

## Publishing

[Scenario Guide Pages](../.github/workflows/scenario-guide-pages.yml) validates pull requests and publishes `_site/` on pushes to `main`. Enable GitHub Pages with **Source: GitHub Actions** in repository settings (if not already enabled). The production URL will be `https://azure-samples.github.io/azure-monitor-lab/`. Branch previews are local; pushing this feature branch does not publish to the production site.
