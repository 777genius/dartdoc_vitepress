// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/file_system/file_system.dart';
import 'package:dartdoc_vitepress/src/generator/generator.dart';
import 'package:dartdoc_vitepress/src/generator/resource_loader.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Matches characters not allowed in a display-safe package name.
///
/// Allows uppercase letters so that names like "Dart" are preserved for
/// display in titles and hero sections. For npm-safe names (which must be
/// lowercase), use [String.toLowerCase] on the result.
final _unsafePackageNameChars = RegExp(r'[^a-zA-Z0-9_-]');

/// Matches `/tree/<branch>/...` suffix common in pub.dev repository URLs.
final _treePathSuffix = RegExp(r'/tree/[^/]+(/.*)?$');

/// Generates initial VitePress project scaffold files.
///
/// Creates the following files (only if they don't already exist):
/// - `package.json` with VitePress dependency
/// - `.vitepress/config.ts` importing generated sidebar data
/// - `index.md` with a VitePress hero section
///
/// Templates are stored as separate files in `lib/resources/vitepress/`
/// for easy editing and syntax highlighting. Placeholders like
/// `{{packageName}}` are substituted at generation time.
class VitePressInitGenerator {
  final FileWriter writer;
  final ResourceProvider resourceProvider;
  final String outputPath;

  /// Package URI prefix for VitePress template files.
  static const _templatePrefix = 'package:dartdoc_vitepress/resources/vitepress';

  VitePressInitGenerator({
    required this.writer,
    required this.resourceProvider,
    required this.outputPath,
  });

  /// Generates scaffold files. Only creates files that don't exist.
  Future<void> generate({
    required String packageName,
    String repositoryUrl = '',
  }) async {
    // Display name: preserves original casing (e.g. "Dart" stays "Dart").
    final safeName = packageName.replaceAll(_unsafePackageNameChars, '-');
    // npm package name: must be lowercase per npm naming rules.
    final npmSafeName = safeName.toLowerCase();
    final placeholders = {
      '{{packageName}}': safeName,
      '{{npmPackageName}}': npmSafeName,
      '{{socialLinks}}': buildSocialLinks(repositoryUrl),
    };

    final templateDir =
        (await resourceProvider.getResourceFolder(_templatePrefix)).path;

    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: 'package.json',
      outputFile: 'package.json',
      placeholders: placeholders,
    );
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: 'config.ts',
      outputFile: '.vitepress/config.ts',
      placeholders: placeholders,
    );
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: 'index.md',
      outputFile: 'index.md',
      placeholders: placeholders,
    );
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: 'guide-index.md',
      outputFile: 'guide/index.md',
      placeholders: placeholders,
    );

    // LLM instructions (so AI tools know what's generated vs editable)
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: 'CLAUDE.md',
      outputFile: 'CLAUDE.md',
      placeholders: placeholders,
    );
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: 'AGENTS.md',
      outputFile: 'AGENTS.md',
      placeholders: placeholders,
    );

    // .gitignore for node_modules, dist and cache
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: '.gitignore',
      outputFile: '.gitignore',
      placeholders: placeholders,
    );

    // Theme customization (glassmorphism nav)
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: p.join('theme', 'index.ts'),
      outputFile: '.vitepress/theme/index.ts',
      placeholders: placeholders,
    );
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: p.join('theme', 'custom.css'),
      outputFile: '.vitepress/theme/custom.css',
      placeholders: placeholders,
    );

    // DartPad interactive playground component and markdown-it plugin
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: p.join('theme', 'components', 'DartPad.vue'),
      outputFile: '.vitepress/theme/components/DartPad.vue',
      placeholders: placeholders,
    );

    // ApiBreadcrumb component for API page navigation
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: p.join('theme', 'components', 'ApiBreadcrumb.vue'),
      outputFile: '.vitepress/theme/components/ApiBreadcrumb.vue',
      placeholders: placeholders,
    );
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: p.join('theme', 'plugins', 'dartpad.ts'),
      outputFile: '.vitepress/theme/plugins/dartpad.ts',
      placeholders: placeholders,
    );

    // API auto-linker: transforms inline code references into clickable links
    _writeTemplateIfAbsent(
      templateDir: templateDir,
      templateFile: p.join('theme', 'plugins', 'api-linker.ts'),
      outputFile: '.vitepress/theme/plugins/api-linker.ts',
      placeholders: placeholders,
    );

    // Generate empty guide-sidebar.ts stub so config.ts import works
    // even before the first full generation run.
    // Written directly to disk (not through writer) because the full
    // generation will overwrite this file via _writeMarkdown, and the
    // writer's duplicate-file detection would trigger an assertion.
    _writeFileToDisk(
      outputFile: '.vitepress/generated/guide-sidebar.ts',
      content: "import type { DefaultTheme } from 'vitepress'\n\n"
          'export const guideSidebar: DefaultTheme.Sidebar = {}\n',
    );
  }

  /// Builds the VitePress `socialLinks` array value from a repository URL.
  ///
  /// Returns `[]` when [url] is empty — valid TS, VitePress shows no icons.
  /// Detects GitHub/GitLab by hostname; defaults to `github` icon.
  @visibleForTesting
  static String buildSocialLinks(String url) {
    if (url.isEmpty) return '[]';

    // Strip /tree/... suffix common in pub.dev-style repository URLs.
    var cleanUrl = url.replaceFirst(_treePathSuffix, '');

    String icon;
    if (cleanUrl.contains('github.com')) {
      icon = 'github';
    } else if (cleanUrl.contains('gitlab.com')) {
      icon = 'gitlab';
    } else {
      icon = 'github';
    }

    final escapedUrl = cleanUrl.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    return "[{ icon: '$icon', link: '$escapedUrl' }]";
  }

  /// Writes [content] directly to disk (bypassing [writer]) only if the file
  /// doesn't exist. Use this for stub files that will be overwritten by the
  /// main generation pass to avoid writer duplicate-file assertions.
  void _writeFileToDisk({
    required String outputFile,
    required String content,
  }) {
    final fullOutputPath = p.normalize(p.join(outputPath, outputFile));
    final existingFile = resourceProvider.getFile(fullOutputPath);
    if (existingFile.exists) return;

    // Ensure parent directory exists.
    final parent = existingFile.parent;
    if (!parent.exists) {
      parent.create();
    }
    existingFile.writeAsStringSync(content);
  }

  /// Reads a template, applies placeholder substitution, and writes to output
  /// only if the file doesn't already exist.
  void _writeTemplateIfAbsent({
    required String templateDir,
    required String templateFile,
    required String outputFile,
    required Map<String, String> placeholders,
  }) {
    // Skip if output file already exists.
    // outputFile uses POSIX separators (for writer.write()); normalize
    // to platform separators before accessing the file system.
    final fullOutputPath = p.normalize(p.join(outputPath, outputFile));
    final existingFile = resourceProvider.getFile(fullOutputPath);
    if (existingFile.exists) return;

    // Read template from package resources.
    final templatePath = p.join(templateDir, templateFile);
    var content = resourceProvider.getFile(templatePath).readAsStringSync();

    // Apply placeholder substitution.
    for (final entry in placeholders.entries) {
      content = content.replaceAll(entry.key, entry.value);
    }

    writer.write(outputFile, content);
  }
}
