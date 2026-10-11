# Iodine III

Games, Movies & TV, Music, Videos, AI Chat and a proxy in one page.
The live site is **[iodine3.wasmer.app](https://iodine3.wasmer.app/)**.

This is the public copy of the code. It contains no server addresses,
keys or account names, so the **Iodine Network (IDN)** is switched off
here: accounts, posts, DMs and IDN+ only work on the live site. Everything
else works as it does there.

## Run it

It is a plain static site with no build step.

- **GitHub Pages:** Settings → Pages → deploy from the `main` branch, root folder.
- **Anywhere else:** upload the folder as-is. `index.html` must stay in the
  top folder, next to `gx-sw.js` (the game-file relay needs to sit there).
- **On your computer:** run `python3 -m http.server` in this folder and open
  `http://localhost:8000`. Opening `index.html` straight from disk will not
  load games.

## Turning IDN on for your own copy

1. Make your own Supabase project. The database setup script is not part
   of this repository.
2. Fill in `assets/config.js` **on your host only**. Do not commit it with
   real values.
3. Only the publishable (anon) key ever goes in the browser. Never put a
   `secret` or `service_role` key in any file here.

## What is where

| | |
|---|---|
| `index.html` | The page. Loads everything in `assets/`. |
| `gx-sw.js` | Relay that helps game files load from backup servers. |
| `sandstone.html` | The built-in proxy. |
| `assets/config.js` | Site settings. Empty in this copy. |
| `assets/view-*.js` | One file per tab. |
| `assets/supa.js`, `auth.js` | Iodine Network sign-in and data. |
| `assets/sync.js` | Keeps mirrors in step when opened through the rotator. |
