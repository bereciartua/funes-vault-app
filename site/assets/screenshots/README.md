# Screenshots for the website

The landing page (`site/index.html`) shows two of the README's screenshots, `share-panel` and `remote-access`, each as `-light.png` and `-dark.png` (the page picks the dark one in dark mode). They live once in git, in `docs/images/`; the Pages workflow copies them here when it deploys. To preview the site locally with them:

```sh
cp docs/images/{share-panel,remote-access}-{light,dark}.png site/assets/screenshots/
```

and don't commit the copies. Regenerate them with `sh scripts/ui_snapshots.sh` (sample data in a throwaway vault, never a real one).
