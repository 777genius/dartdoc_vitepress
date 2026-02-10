import { defineConfig } from 'vitepress'
import { apiSidebar } from './generated/api-sidebar'
import { guideSidebar } from './generated/guide-sidebar'
import { dartpadPlugin } from './theme/plugins/dartpad'
import llmstxt, { copyOrDownloadAsMarkdownButtons } from 'vitepress-plugin-llms'

export default defineConfig({
  title: 'dartdoc-vitepress',
  description: 'Modern API documentation generator for Dart — VitePress fork of dartdoc',
  base: '/dartdoc_vitepress/',
  ignoreDeadLinks: true,
  vite: {
    plugins: [llmstxt()],
  },
  markdown: {
    config: (md) => {
      md.use(dartpadPlugin)
      md.use(copyOrDownloadAsMarkdownButtons)
    },
  },
  themeConfig: {
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
})
