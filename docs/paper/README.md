# Technical Report Build Guide

This directory contains an arXiv-friendly LaTeX technical report:

- `technical_report.tex`
- `references.bib`

## Prerequisites

- `tectonic` installed and available on `PATH`

Check installation:

```bash
tectonic --version
```

## Build PDF Locally

From the repository root:

```bash
mkdir -p docs/paper/build
tectonic docs/paper/technical_report.tex --outdir docs/paper/build
```

Expected output PDF:

- `docs/paper/build/technical_report.pdf`

## Optional Clean Rebuild

```bash
rm -rf docs/paper/build
mkdir -p docs/paper/build
tectonic docs/paper/technical_report.tex --outdir docs/paper/build
```

## Troubleshooting

1. `tectonic: command not found`
   - Install Tectonic, then re-run `tectonic --version`.
2. Missing bibliography or unresolved citations
   - Ensure `docs/paper/references.bib` exists and re-run the same build command.
3. First build fails while fetching LaTeX packages
   - Re-run once network/package cache is available.
4. Output PDF not found
   - Verify the `--outdir docs/paper/build` argument and check write permissions.
