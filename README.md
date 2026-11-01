# The Student Shelf

A campus marketplace prototype for Babson College students: buy, sell, rent, and rehome dorm items, with waste tracking.

**Status:** demo. Listings, students, replies, and payments are simulated, and data is saved only in each visitor's browser.

## What's here

| Path | What it is |
| --- | --- |
| `index.html` | The app (single file, no build step) |
| `terms/` | Terms and Policies page and PDF, served at `/terms/` |
| `assets/logo/` | Logo files |
| `backend/supabase-setup.sql` | Database setup for the future real version (not used by the demo) |

## Deploy

Netlify serves this repo as a static site. In Netlify: **Site configuration → Build & deploy → Link repository**, pick this repo, leave the build command empty, and set the publish directory to `.`. Every push to `main` then redeploys the site.

## Keep secrets out

This repo is public. Never commit API keys, passwords, or Supabase secret/service_role keys.
