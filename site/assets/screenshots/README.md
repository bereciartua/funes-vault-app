# Screenshots for the website

The landing page (`site/index.html`) shows two of the README's Mac screenshots, `share-panel` and `remote-access`, each as `-light.png` and `-dark.png` (the page picks the dark one in dark mode), and two of the iPhone app, `iphone-home.png` (Home) and `iphone-approval.png` (the Share panel), light only. They live once in git, in `docs/images/`; the Pages workflow copies them here when it deploys, so replacing one is a file drop in `docs/images/`. To preview the site locally with them:

```sh
cp docs/images/{share-panel,remote-access}-{light,dark}.png docs/images/iphone-{home,approval}.png site/assets/screenshots/
```

and don't commit the copies. Regenerate the Mac ones with `sh scripts/ui_snapshots.sh` (sample data in a throwaway vault, never a real one). The iPhone ones come from demo mode (`sh scripts/app_store_screenshots.sh`, scenes `home` and `share`), scaled to about 588 × 1280: `sips -Z 1280`.
