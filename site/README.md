# MultiverseWP — Landing Site

Static landing page for **wpmultiverse.ssilistre.tech**, served from Cloudflare Pages.

Stack:
- [Astro 5](https://astro.build) static output
- [Tailwind CSS 4](https://tailwindcss.com) via `@tailwindcss/vite`
- Built-in Astro i18n (TR default, EN under `/en/`)
- Zero JavaScript at runtime by default

## Develop

```sh
cd site
npm install
npm run dev    # http://localhost:4321
```

## Build

```sh
npm run build      # → site/dist
npm run preview    # serve dist locally
```

Output is fully static HTML + CSS. No SSR.

## Structure

```
site/
├── astro.config.mjs       # i18n + Tailwind plugin
├── package.json
├── public/                # favicon, robots.txt, OG image
└── src/
    ├── components/        # Hero, Features, MCPSection, Download, Footer, Header, LangSwitcher
    ├── i18n/
    │   ├── ui.ts          # all TR + EN strings
    │   └── utils.ts       # getLangFromUrl, useTranslations, localizedPath
    ├── layouts/Layout.astro
    ├── pages/
    │   ├── index.astro    # TR default at /
    │   └── en/index.astro # EN at /en/
    └── styles/global.css  # Tailwind import + custom @theme tokens
```

Adding a string: edit both `ui.tr` and `ui.en` in `src/i18n/ui.ts`, then reference via
`t('your.key')` in any component. TypeScript enforces the key set across both locales.

## Deploy — Cloudflare Pages

One-time setup:

1. Push `site/` to GitHub (already part of `multiversewp` repo).
2. Cloudflare dashboard → **Workers & Pages → Create → Pages → Connect to Git**.
3. Pick the `unkownpr/multiversewp` repo.
4. **Build configuration:**
   - Framework preset: **Astro**
   - Build command: `cd site && npm install && npm run build`
   - Build output directory: `site/dist`
   - Root directory: *(leave blank)*
   - Node version: `20` (Environment variable `NODE_VERSION=20`)
5. **Custom domain:** Cloudflare → your Pages project → Custom domains → add
   `wpmultiverse.ssilistre.tech`. CF auto-creates the CNAME if `ssilistre.tech` is on
   the same account; otherwise add a CNAME pointing to
   `<your-pages-project>.pages.dev`.

After the first build the URL responds in ~30s. Every push to `main` triggers a new
deploy; PR branches get preview URLs.

## SEO

- `<link rel="alternate" hreflang>` between TR and EN.
- Canonical URL on every page from `Astro.site`.
- OpenGraph + Twitter Card meta tags.
- `robots.txt` allows all, sitemap points at `/sitemap-index.xml` (Astro generates this
  when the `@astrojs/sitemap` integration is added — currently omitted to keep the
  surface tiny; add it later if you want full sitemap support).

## License

MIT — same as the parent project.
