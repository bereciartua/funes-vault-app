# Screenshots for the website

The landing page (`site/index.html`) shows the README's screenshots: `vault-memory`, `share-panel`, `inbox`, `agents-access` and `activity`, each as `-light.png` and `-dark.png` (the page picks the dark one in dark mode). They live once in git, in `docs/images/`; the Pages workflow copies them here when it deploys. To preview the site locally with them:

```sh
cp docs/images/{vault-memory,share-panel,inbox,agents-access,activity}-{light,dark}.png site/assets/screenshots/
```

and don't commit the copies. Regenerate them with `sh scripts/ui_snapshots.sh` (sample data in a throwaway vault, never a real one).
