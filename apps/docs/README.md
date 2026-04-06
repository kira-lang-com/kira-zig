# Kira Documentation Site

This app contains the Bun-powered Kira documentation website built with Fumadocs and React Router.

## Run Locally

```bash
bun install
bun run dev
```

The dev server is served by React Router.

## Build Static Assets

```bash
bun run build
```

Static output is written to `build/client`.

## Preview The Static Build

```bash
bun run start
```

That serves the generated static site from `build/client/`.

## Content Layout

- `app/` contains the React Router routes, home page, shared layout helpers, and search wiring.
- `content/docs/` contains the English documentation source in MDX.
- `source.config.ts` defines the Fumadocs MDX source.

## Notes

- The site is structured for future versioning, but currently ships only the latest English docs.
- Search uses Fumadocs static Orama indexes so the site can be hosted as static files without a separate search service.
