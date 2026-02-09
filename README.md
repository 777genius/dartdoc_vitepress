# dartdoc-vitepress

> Fork of [dart-lang/dartdoc](https://github.com/dart-lang/dartdoc) with a **VitePress backend** for generating modern, beautiful API documentation as a static VitePress site instead of default HTML.

## What's different from dartdoc?

| Feature | dartdoc | dartdoc-vitepress |
|---|---|---|
| Output format | Static HTML | VitePress Markdown site |
| Search | Built-in (basic) | VitePress local search (MiniSearch) |
| Theming | CSS customization | Full Vue.js theming |
| Guide docs | Not supported | Auto-discovers `doc/` & `docs/` markdown files (configurable via `--guide-dirs`) |
| Workspace mode | Not supported | `--workspace-docs` for mono-repos |
| Sidebar | HTML nav | Auto-generated TypeScript sidebar data |
| Customization | Templates | Full VitePress ecosystem (Vue components, plugins) |

The fork adds a `--format vitepress` option while keeping full backward compatibility with the original `dart doc` HTML output.

## Installation

```bash
# From pub.dev (recommended)
dart pub global activate dartdoc_vitepress
```

## Quick Start

```bash
# Generate VitePress docs for a single package
dart pub global run dartdoc_vitepress --format vitepress --output docs-site

# Generate docs for a Dart workspace (mono-repo)
dart pub global run dartdoc_vitepress \
  --format vitepress \
  --workspace-docs \
  --exclude-packages 'example_app,test_utils' \
  --output docs-site

# Preview locally
cd docs-site && npm install && npx vitepress dev
```

## How it works

```
Dart source -> [analyzer] -> PackageGraph -> [VitePress backend] -> Markdown + sidebar data
```

1. **API docs** — each library, class, function, property gets a `.md` file under `api/`
2. **Guide docs** — markdown files from `doc/` or `docs/` are copied to `guide/` with sidebar generation
3. **Scaffold files** — `config.ts`, `package.json`, `index.md` are created once and never overwritten, so you can customize them freely
4. **Sidebar data** — `api-sidebar.ts` and `guide-sidebar.ts` are auto-generated and imported by `config.ts`

### Generated structure

```
docs-site/
├── .vitepress/
│   ├── config.ts                 # Your customizable config (created once)
│   └── generated/
│       ├── api-sidebar.ts        # Auto-generated API sidebar
│       └── guide-sidebar.ts      # Auto-generated guide sidebar
├── api/                          # Auto-generated API markdown
│   ├── index.md
│   ├── my_package/
│   │   ├── MyClass-class.md
│   │   └── ...
│   └── ...
├── guide/                        # Copied from doc/ & docs/ directories
│   ├── index.md                  # Created once (customizable)
│   └── my-guide.md
├── index.md                      # Landing page (created once)
└── package.json                  # VitePress dependency (created once)
```

## CI/CD with GitHub Pages

Add to `.github/workflows/docs.yml`:

```yaml
name: Deploy Documentation

on:
  push:
    branches: [main]

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
          cache-dependency-path: docs-site/package-lock.json

      - name: Install dartdoc-vitepress
        run: dart pub global activate dartdoc_vitepress

      - name: Generate API docs
        run: dart pub global run dartdoc_vitepress --format vitepress --output docs-site

      - run: npm ci
        working-directory: docs-site

      - run: npx vitepress build
        working-directory: docs-site

      - uses: actions/configure-pages@v5
      - uses: actions/upload-pages-artifact@v3
        with:
          path: docs-site/.vitepress/dist

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    permissions:
      pages: write
      id-token: write
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

Don't forget: **Settings → Pages → Source: GitHub Actions**.

## Key CLI options

| Option | Description |
|---|---|
| `--format vitepress` | Generate VitePress markdown instead of HTML |
| `--workspace-docs` | Document all packages in a Dart workspace |
| `--exclude-packages 'a,b,c'` | Skip specific packages |
| `--output <dir>` | Output directory (default: `doc/api`) |
| `--guide-dirs 'doc,docs'` | Directories to scan for guide markdown (default: `doc,docs`) |

All original dartdoc options (`--exclude`, `--include`, `--header`, etc.) are still supported.

## Extensible Plugin Architecture

The generated site is a standard VitePress project — you can add custom markdown-it plugins, Vue components, and CSS to extend functionality beyond what dartdoc provides.

### Bundled plugin examples

These are not part of the generator itself, but patterns you can add to `docs-site/.vitepress/theme/plugins/`:

#### API Auto-linker

A markdown-it plugin that scans the generated `api/` directory at build time and automatically converts inline code references in guide pages to clickable links pointing to API docs.

Write `` `ModuleScope` `` in your guide — it renders as a styled link to `/api/your_package/ModuleScope`. Handles dotted access (`` `Modularity.observer` ``), generics (`` `ModuleScope<Auth>` ``), and skips Dart/Flutter built-in types.

```ts
// .vitepress/theme/plugins/api-linker.ts
// Scans api/ at init, builds symbol map, transforms code_inline tokens
md.use(apiLinkerPlugin)
```

#### Interactive DartPad Embeds

A markdown-it plugin + Vue component that turns ` ```dartpad ` code fences into interactive playgrounds with syntax highlighting, a "Run" button, and a DartPad iframe — all without leaving the docs page.

```markdown
  ```dartpad height=400 mode=flutter
  import 'package:flutter/material.dart';
  void main() => runApp(const Text('Hello'));
  ```
```

#### API Breadcrumbs

A Vue component (`<ApiBreadcrumb />`) auto-injected into API pages that renders `package > category > class` navigation from the route path and frontmatter.

### Why this matters

Standard dartdoc generates a closed HTML output. dartdoc-vitepress generates **open markdown + TypeScript data** that you can extend:

| What you can add | How |
|---|---|
| Custom markdown-it plugins | `md.use(yourPlugin)` in `config.ts` |
| Vue components in markdown | Register in `theme/index.ts`, use in `.md` files |
| Theme customization | `custom.css` or full theme override |
| Build-time data transforms | Import generated `api-sidebar.ts` or scan `api/` directory |

## Upstream

Based on [dart-lang/dartdoc v9.0.2](https://github.com/dart-lang/dartdoc) (commit `af008503`).

The VitePress backend is implemented as an additional `GeneratorBackend`, not a replacement — the original HTML generation is fully intact.

## License

Same as [dartdoc](https://github.com/dart-lang/dartdoc/blob/main/LICENSE) — BSD-3-Clause.
