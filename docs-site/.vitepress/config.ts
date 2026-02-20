import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'
import { apiSidebar } from './generated/api-sidebar'
import { guideSidebar } from './generated/guide-sidebar'
import { dartpadPlugin } from './theme/plugins/dartpad'
import llmstxt from 'vitepress-plugin-llms'

export default withMermaid(defineConfig({
  title: 'dartdoc-vitepress',
  description: 'Modern API documentation generator for Dart — VitePress fork of dartdoc',
  base: '/dartdoc_vitepress/',
  ignoreDeadLinks: true,
  vite: {
    plugins: [llmstxt()],
    optimizeDeps: {
      include: ['mermaid'],
    },
    ssr: {
      noExternal: ['mermaid'],
    },
  },
  markdown: {
    config: (md) => {
      md.use(dartpadPlugin)
    },
  },
  themeConfig: {
    logo: { src: '/logo.svg', width: 36, height: 36 },
    search: {
      provider: 'local',
    },
    nav: [
      { text: 'Guide', link: '/guide/' },
      { text: 'API Reference', link: '/api/' },
    ],
    sidebar: {
      ...apiSidebar,
      ...guideSidebar,
    },
    socialLinks: [{ icon: 'github', link: 'https://github.com/777genius/dartdoc_vitepress' }],
  },
}))
