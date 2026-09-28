# Iodine III

**Iodine III is the 3rd version of the unblockable unblocked games site, Iodine.** It upgrades the stealth architecture of its predecessors by introducing an auto-update system contained entirely within a single file: `iodine.html`. 

Most network filters automatically block standard gaming domains, but they rarely block the trusted open-source CDNs used to pull the latest game assets. This project exploits that blind spot to keep games continuously updated and accessible without manual redeployments.

## How It Works

* **The Engine:** The entire user interface and core logic are contained in a single, portable **`iodine.html`** file.
* **The Auto-Updater:** When opened, the script automatically checks for and fetches the latest patches and game links, keeping the site unblockable and up-to-date.
* **The Delivery:** The site assets, scripts, and updates are hosted and delivered through **jsDelivr**, a trusted open-source CDN.

## Repository Structure

* `iodine.html` — The all-in-one portable entry point featuring the gaming interface and auto-update engine.
* `assets` — The actual assets for Iodine.
* `LICENSE` — Project terms under the **GPL-3.0 License**.
* `README.md` — Project documentation.

## Setup & Deployment

1. **Upload to GitHub:** Fork this repository and host your updated game assets in your main branch.
2. **Configure Auto-Update:** Ensure your update endpoints point to your raw repository structure via jsDelivr.
3. **Distribute the File:** Share the `iodine.html` file directly with users, or host it on a trusted static platform.

## License

This project is licensed under the **Metal Public License v1.0 (MPL-1)** - see the [LICENSE](LICENSE) file for details.
