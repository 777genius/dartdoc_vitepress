import DefaultTheme from 'vitepress/theme'
import './custom.css'
import DartPad from './components/DartPad.vue'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('DartPad', DartPad)
  }
}
