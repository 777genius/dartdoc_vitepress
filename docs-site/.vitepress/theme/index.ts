import { computed } from 'vue'
import DefaultTheme from 'vitepress/theme'
import { useData } from 'vitepress'
import { useCodeblockCollapse } from 'vitepress-codeblock-collapse'
import 'vitepress-codeblock-collapse/style.css'
import { useMermaidZoom } from 'vitepress-mermaid-zoom'
import 'vitepress-mermaid-zoom/style.css'
import './custom.css'

export default {
  extends: DefaultTheme,
  setup() {
    const { page } = useData()
    const pagePath = computed(() => page.value.relativePath)
    useCodeblockCollapse(pagePath)
    useMermaidZoom(pagePath)
  }
}
