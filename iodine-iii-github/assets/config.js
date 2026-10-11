/* Iodine III - site settings
   ------------------------------------------------------------------
   This public copy ships with everything below left empty, so it holds
   no server addresses, keys or account names. As shipped:

     - Games, Movies & TV, Music, Videos, AI Chat, Proxy and Settings
       all work.
     - Local accounts work (they live in the browser).
     - The Iodine Network (IDN accounts, posts, DMs, IDN+) is switched
       off until you fill in idnServers.

   To run your own copy with IDN, make your own Supabase project, then
   fill in the values below ON YOUR HOST ONLY. Do not commit a filled-in
   copy of this file - see README.md.
   ------------------------------------------------------------------ */
(function (global) {
  "use strict";
  global.IodineConfig = {
    /* Supabase projects for the Iodine Network, tried in order.
       e.g. [{ url: "https://YOUR-PROJECT.supabase.co", key: "sb_publishable_..." }]
       Only ever use the PUBLISHABLE / anon key here, never a secret
       or service_role key. */
    idnServers: [],

    /* The made-up email domain IDN IDs are signed in with
       (IDN ID "bob" signs in as bob@<this>). It has to match whatever
       your Supabase project's accounts were made with. */
    emailDomain: "",

    /* Addresses that count as "your" site. Anyone using IDN from any
       other address is listed in the admin panel as using a copy. */
    officialHosts: [],

    /* The page that rotates between mirrors and keeps them in sync
       (see assets/sync.js). Only these may talk to the site. */
    rotators: ["https://iodine3.wasmer.app"],

    /* IDN display names that see the admin tab before the server has
       answered. The server decides what they may actually do. */
    adminNames: [],

    /* The one IDN display name that sees the debug panel. */
    ownerName: "",

    /* SHA-256 (hex) of the optional "verification code" on local
       accounts. Empty = nobody can verify. */
    verifyDigest: ""
  };
})(window);
