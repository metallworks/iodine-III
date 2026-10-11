<div align="center">

<img src="assets/logo.png" alt="Iodine III" width="320">

### Games, movies, music and friends in one tab.

**[▶ Open Iodine III](https://iodine.wasmer.app/)**

</div>

---

Iodine III is a single-page site with thousands of browser games, a movie and TV player, a music player, an AI assistant, a web proxy and its own social network, the **Iodine Network (IDN)**. It runs entirely in the browser, with no installs and no build step.

This repository is the **public copy** of the code. Everything works here except the Iodine Network, which only runs on the [live site](https://iodine.wasmer.app/) (see [Running your own copy](#running-your-own-copy)).

<div align="center">
<img src="docs/games.jpg" alt="The Games tab" width="820">
</div>

## What's inside

| Tab | What it does |
|---|---|
| **Home** | Trending games, posts and songs, the update log, and one search box for everything. |
| **Games** | Several game collections in one place: Game Stash, gn-math, Greeni Game Hub, Yuki, 3kh0, Sebastian, Retro Consoles and more. Games play inside the page, and if one server is blocked or down, Iodine tries backup servers on its own. |
| **IDN** | The Iodine Network: private messages and group chats, a **For You** feed with posts and replies, and **Videos** with Shorts. |
| **Music** | Search and play free music from Audius, Openverse and Wikimedia, with a player that keeps going while you switch tabs. |
| **Movies & TV** | Browse popular movies and shows, pick a season and episode, and switch servers if one won't play. |
| **Videos** | Video search and playback. |
| **Chat** | The Iodine Assistant. It can run a small AI model right on your computer, so it works without a server. |
| **Proxy** | A built-in proxy (Sandstone) for opening other sites. |
| **Settings** | Themes, highlight colours, your own background, background music, game saves and your account. |

### Also

- **Eight themes**: Electro, Golden, Silver, Emerald, Fire, Violet, Mono and Paper. Each one has its own animated background.
- **Game saves you can keep.** Back up your saves to a file and load them on another computer, or keep them in the cloud with an IDN account.
- **Several users on one computer.** Each person gets their own profile, picture, settings and saves.
- **Sized for your screen.** Pick small laptop, large laptop, desktop or tablet the first time you open it.
- **Keeps working when things get blocked.** Iodine notices when a server is unreachable and moves to the next one, so you rarely have to do anything.

<div align="center">
<img src="docs/settings.jpg" alt="Theme settings" width="820">
</div>

## Accounts

| | Local | IDN | IDN+ |
|---|:---:|:---:|:---:|
| Games, movies, music, chat, proxy | ✓ | ✓ | ✓ |
| No sign-up | ✓ | | |
| Messages, posts and Shorts | | ✓ | ✓ |
| Cloud saves on any computer | | ✓ | ✓ |
| Extra game collections | | some | all |
| Voice calls | | | ✓ |

A **local account** lives only in your browser. An **IDN account** is free and comes with a day of IDN+. To get **IDN+**, message `IDNPLUSDEALER` on the Iodine Network.

## Running your own copy

Iodine III is a plain static site. Put the files on any static host and open `index.html`.

**GitHub Pages**
1. Fork this repository.
2. Go to **Settings → Pages**, choose **Deploy from a branch**, then select `main` and `/ (root)`.
3. Your copy will be at `https://<your-name>.github.io/<repo-name>/`.

**Anywhere else:** upload the whole folder as it is. Keep `index.html` and `gx-sw.js` together in the top folder, because the game-file relay has to sit next to the page.

**On your own computer:** run a small local server in this folder rather than opening the file directly, or games won't load:

```sh
python3 -m http.server 8000
# then open http://localhost:8000
```

### The Iodine Network in your copy

IDN is turned off in this repository. It needs a Supabase project, and the server addresses, keys and database setup aren't published here. All of IDN's settings are in [`assets/config.js`](assets/config.js), which is empty on purpose.

> [!WARNING]
> Never commit a filled-in `config.js`, and never put a Supabase `secret` or `service_role` key in any file. Only the publishable (anon) key ever belongs in a browser.

## Project layout

```
index.html          the page
gx-sw.js            relay that lets game files load from backup servers
sandstone.html      the built-in proxy
assets/
  config.js         site settings (empty in this copy)
  router.js         start-up: device picker, user profiles, page routing
  shell.js          the sidebar and the layout every tab sits in
  view-*.js         one file per tab (games, idn, music, movies, ...)
  library.js        game collections and where their files come from
  supa.js, auth.js  Iodine Network sign-in and data
  saves.js          game-save backup and restore
  sync.js           keeps mirrors in step when opened through the rotator
  app.css           all of the styling
docs/               screenshots for this page
```

## Credits

- Game collections by their original curators, including [bubbls / UGS](https://github.com/bubbls/ugs-singlefile), gn-math, Greeni Game Hub, Yuki, 3kh0 and Sebastian.
- Music from [Audius](https://audius.co), [Openverse](https://openverse.org) and [Wikimedia Commons](https://commons.wikimedia.org).
- Movie and show listings from Cinemeta.
- *Electrodoodle* by Kevin MacLeod ([incompetech.com](https://incompetech.com)), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- Accounts and the Iodine Network run on [Supabase](https://supabase.com). Files are served through [jsDelivr](https://www.jsdelivr.com).

---

<div align="center">

Made by Metalworks· **[iodine3.wasmer.app](https://iodine.wasmer.app/)**

</div>
