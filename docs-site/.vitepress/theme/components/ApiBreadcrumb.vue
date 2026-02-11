<script setup lang="ts">
import { computed } from 'vue'
import { useData, withBase } from 'vitepress'

const { frontmatter, page } = useData()

const libraryDirName = computed(() => {
  const parts = page.value.relativePath.split('/')
  if (parts.length >= 2 && parts[0] === 'api') {
    return parts[1]
  }
  return null
})

const libraryDisplayName = computed(() => {
  return frontmatter.value.library ?? libraryDirName.value
})

const category = computed(() => frontmatter.value.category ?? null)
</script>

<template>
  <div v-if="libraryDirName && category" class="api-breadcrumb">
    <a :href="withBase(`/api/${libraryDirName}/`)" class="breadcrumb-link">{{ libraryDisplayName }}</a>
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
