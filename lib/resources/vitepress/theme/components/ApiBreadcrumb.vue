<script setup lang="ts">
import { computed } from 'vue'
import { useData, withBase } from 'vitepress'

const { frontmatter, page } = useData()

const packageName = computed(() => {
  // relativePath example: "api/modularity_contracts/Binder.md"
  const parts = page.value.relativePath.split('/')
  // parts[0] = "api", parts[1] = package name
  if (parts.length >= 2 && parts[0] === 'api') {
    return parts[1]
  }
  return null
})

const category = computed(() => frontmatter.value.category ?? null)
</script>

<template>
  <div v-if="packageName && category" class="api-breadcrumb">
    <a :href="withBase(`/api/${packageName}/`)" class="breadcrumb-link">{{ packageName }}</a>
    <span class="breadcrumb-separator">›</span>
    <span class="breadcrumb-current">{{ category }}</span>
  </div>
</template>

<style scoped>
.api-breadcrumb {
  font-size: 0.85em;
  margin-bottom: 0.5em;
  color: var(--vp-c-text-3);
  line-height: 1.5;
}

.breadcrumb-link {
  color: var(--vp-c-text-2);
  text-decoration: none;
  transition: color 0.2s;
}

.breadcrumb-link:hover {
  color: var(--vp-c-brand-1);
}

.breadcrumb-separator {
  margin: 0 0.4em;
  color: var(--vp-c-text-3);
}

.breadcrumb-current {
  color: var(--vp-c-text-2);
}
</style>
