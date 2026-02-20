import { computed, h } from 'vue'
import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import { useData } from 'vitepress'
import { useCodeblockCollapse } from 'vitepress-codeblock-collapse'
import 'vitepress-codeblock-collapse/style.css'
import { useMermaidZoom } from 'vitepress-mermaid-zoom'
import 'vitepress-mermaid-zoom/style.css'
import HeroDoc from './components/HeroDoc.vue'
import './custom.css'
import '../generated/api-styles.css'
import DartPad from './components/DartPad.vue'
import ApiBreadcrumb from './components/ApiBreadcrumb.vue'

export default {
  extends: DefaultTheme,
  Layout() {
    return h(DefaultTheme.Layout, null, {
      'home-hero-image': () => h(HeroDoc),
    })
  },
  enhanceApp({ app }) {
    app.component('DartPad', DartPad)
    app.component('ApiBreadcrumb', ApiBreadcrumb)
  },
  setup() {
    const { page } = useData()
    const pagePath = computed(() => page.value.relativePath)
    useCodeblockCollapse(pagePath)
    useMermaidZoom(pagePath)
  }
} satisfies Theme
