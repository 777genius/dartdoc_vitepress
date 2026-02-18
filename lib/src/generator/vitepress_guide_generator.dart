// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/file_system/file_system.dart';
import 'package:dartdoc_vitepress/src/generator/vitepress_doc_processor.dart';
import 'package:dartdoc_vitepress/src/generator/vitepress_sidebar_generator.dart'
    show escapeForTs;
import 'package:dartdoc_vitepress/src/logging.dart';
import 'package:dartdoc_vitepress/src/model/model.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Matches a markdown level-1 heading (e.g. `# My Title`).
final _headingPattern = RegExp(r'^#\s+(.+)$');

/// Matches inline markdown formatting (`**bold**`, `*italic*`, `` `code` ``).
final _inlineMarkdown = RegExp(r'\*{1,2}|`');

/// Matches hyphens or underscores for kebab/snake-case splitting.
final _kebabSnakeDelimiter = RegExp(r'[-_]');

/// Matches YAML frontmatter block delimited by `---`.
final _frontmatterPattern = RegExp(r'^---\n([\s\S]*?)\n---', multiLine: true);

/// Matches `sidebar_position: <number>` in frontmatter.
final _sidebarPositionPattern =
    RegExp(r'^sidebar_position:\s*(\d+)\s*$', multiLine: true);

/// An entry representing a single guide markdown file.
class GuideEntry {
  final String packageName;

  /// Output path relative to the output root (e.g. `guide/pkg/intro.md`).
  final String relativePath;

  final String title;

  /// The raw markdown content read from the source file.
  final String content;

  /// Optional sidebar position from frontmatter `sidebar_position`.
  /// Lower values appear first. `null` means no explicit order (sorted last).
  final int? sidebarPosition;

  GuideEntry({
    required this.packageName,
    required this.relativePath,
    required this.title,
    required this.content,
    this.sidebarPosition,
  });
}

/// Generates guide pages from `doc/` and `docs/` directories of packages.
///
/// Scans configured directories in each local package for `.md` files,
/// collects them as [GuideEntry] objects, and generates a VitePress
/// sidebar configuration file.
///
/// This class does NOT write files itself. Instead, it returns entries
/// with content so the caller (backend) can write them via its own
/// `_writeMarkdown()` to get incremental checks and statistics.
class VitePressGuideGenerator {
  final ResourceProvider resourceProvider;
  final List<String> scanDirs;
  final List<RegExp> _includeRegexps;
  final List<RegExp> _excludeRegexps;
  final Set<String> _allowedIframeHosts;

  /// Creates a guide generator with validated regex patterns.
  ///
  /// Throws [FormatException] if any [include] or [exclude] pattern
  /// is not a valid regular expression.
  VitePressGuideGenerator({
    required this.resourceProvider,
    required this.scanDirs,
    List<String> include = const [],
    List<String> exclude = const [],
    Set<String> allowedIframeHosts = const {},
  })  : _includeRegexps = _compilePatterns(include, 'include'),
        _excludeRegexps = _compilePatterns(exclude, 'exclude'),
        _allowedIframeHosts = allowedIframeHosts;

  /// Compiles regex patterns with validation.
  static List<RegExp> _compilePatterns(List<String> patterns, String label) {
    return patterns.map((pattern) {
      try {
        return RegExp(pattern);
      } on FormatException catch (e) {
        throw FormatException(
          'Invalid guide $label regex "$pattern": ${e.message}',
        );
      }
    }).toList();
  }

  /// Scans `doc/`/`docs/` in each local package and collects `.md` files.
  ///
  /// Returns a list of [GuideEntry] containing the content and output paths.
  /// The caller is responsible for writing the files.
  List<GuideEntry> collectGuideEntries({
    required PackageGraph packageGraph,
    required bool isMultiPackage,
  }) {
    final entries = <GuideEntry>[];
    final usedPaths = <String>{};

    for (final package in packageGraph.localPackages) {
      final packageDir = package.packagePath;

      for (final dirName in scanDirs) {
        final docDirPath = p.join(packageDir, dirName);
        final docFolder = resourceProvider.getFolder(docDirPath);
        if (!docFolder.exists) continue;

        final mdFiles = _collectMarkdownFiles(docFolder);
        for (final mdFile in mdFiles) {
          var relativeToDocs = p.relative(mdFile.path, from: docDirPath);
          // Normalize to forward slashes for consistent regex matching.
          relativeToDocs = relativeToDocs.replaceAll(r'\', '/');

          if (!matchesFilters(relativeToDocs)) continue;

          var content = mdFile.readAsStringSync();
          // Convert [TOC] directive to VitePress syntax.
          content = content.replaceAll(
              RegExp(r'^\[TOC\]\s*$', multiLine: true), '[[toc]]');
          final sanitizedContent = VitePressDocProcessor.sanitizeHtml(content,
              extraAllowedHosts: _allowedIframeHosts);
          final title = extractTitle(content, relativeToDocs);

          String outputRelative;
          if (isMultiPackage) {
            outputRelative =
                p.posix.join('guide', '_generated', package.name, relativeToDocs);
          } else {
            outputRelative = p.posix.join('guide', '_generated', relativeToDocs);
          }

          // Skip duplicate paths (e.g. same file from doc/ and docs/).
          if (!usedPaths.add(outputRelative)) {
            logWarning('Duplicate guide file path: $outputRelative (skipping)');
            continue;
          }

          final sidebarPosition = _extractSidebarPosition(content);

          entries.add(GuideEntry(
            packageName: package.name,
            relativePath: outputRelative,
            title: title,
            content: sanitizedContent,
            sidebarPosition: sidebarPosition,
          ));
        }
      }
    }

    if (entries.isNotEmpty) {
      logInfo('Guide: ${entries.length} markdown file(s) collected.');
    }

    return entries;
  }

  /// Generates VitePress sidebar TypeScript for guide entries.
  ///
  /// For multi-package: groups entries by package name.
  /// For single-package: flat list of items.
  ///
  /// Returns the content of `guide-sidebar.ts`.
  String generateSidebar(
    List<GuideEntry> entries, {
    required bool isMultiPackage,
  }) {
    if (entries.isEmpty) {
      return "import type { DefaultTheme } from 'vitepress'\n\n"
          'export const guideSidebar: DefaultTheme.Sidebar = {}\n';
    }

    final buffer = StringBuffer();
    buffer.writeln("import type { DefaultTheme } from 'vitepress'");
    buffer.writeln();
    buffer.writeln('export const guideSidebar: DefaultTheme.Sidebar = {');
    buffer.writeln("  '/guide/': [");

    if (isMultiPackage) {
      // Group by package.
      final byPackage = <String, List<GuideEntry>>{};
      for (final entry in entries) {
        byPackage.putIfAbsent(entry.packageName, () => []).add(entry);
      }

      for (final packageName in byPackage.keys.toList()..sort()) {
        final packageEntries = _sortEntries(byPackage[packageName]!);
        buffer.writeln('    {');
        buffer.writeln("      text: '${escapeForTs(packageName)}',");
        buffer.writeln('      collapsed: false,');
        buffer.writeln('      items: [');
        for (final entry in packageEntries) {
          final link = '/${entry.relativePath}'.replaceAll('.md', '');
          buffer.writeln(
            "        { text: '${escapeForTs(entry.title)}', "
            "link: '${escapeForTs(link)}' },",
          );
        }
        buffer.writeln('      ],');
        buffer.writeln('    },');
      }
    } else {
      // Flat list.
      final sorted = _sortEntries(entries);
      for (final entry in sorted) {
        final link = '/${entry.relativePath}'.replaceAll('.md', '');
        buffer.writeln(
          "    { text: '${escapeForTs(entry.title)}', link: '${escapeForTs(link)}' },",
        );
      }
    }

    buffer.writeln('  ],');
    buffer.writeln('}');

    return buffer.toString();
  }

  /// Checks if [relativePath] passes the include/exclude filters.
  ///
  /// Rules:
  /// - If include patterns are non-empty, the path must match at least one.
  /// - If exclude patterns are non-empty, the path must NOT match any.
  /// - If both are empty, the path passes.
  @visibleForTesting
  bool matchesFilters(String relativePath) {
    if (_includeRegexps.isNotEmpty) {
      final matches = _includeRegexps.any((re) => re.hasMatch(relativePath));
      if (!matches) return false;
    }

    if (_excludeRegexps.isNotEmpty) {
      final excluded = _excludeRegexps.any((re) => re.hasMatch(relativePath));
      if (excluded) return false;
    }

    return true;
  }

  /// Extracts a title from the markdown content.
  ///
  /// Looks for the first `# heading` line. Falls back to the file name
  /// (without extension) converted from kebab/snake case to title case.
  @visibleForTesting
  static String extractTitle(String content, String relativePath) {
    final lines = content.split('\n');
    for (final line in lines) {
      final match = _headingPattern.firstMatch(line.trim());
      if (match != null) {
        return _stripInlineMarkdown(match.group(1)!.trim());
      }
    }

    // Fallback: use the file name.
    var name = p.basenameWithoutExtension(relativePath);
    // Convert kebab-case or snake_case to Title Case.
    name = name
        .replaceAll(_kebabSnakeDelimiter, ' ')
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
    return name;
  }

  /// Strips inline markdown formatting from a heading title.
  static String _stripInlineMarkdown(String title) =>
      title.replaceAll(_inlineMarkdown, '').trim();

  /// Extracts `sidebar_position` from YAML frontmatter if present.
  static int? _extractSidebarPosition(String content) {
    final fmMatch = _frontmatterPattern.firstMatch(content);
    if (fmMatch == null) return null;
    final posMatch = _sidebarPositionPattern.firstMatch(fmMatch.group(1)!);
    if (posMatch == null) return null;
    return int.tryParse(posMatch.group(1)!);
  }

  /// Sorts guide entries: by `sidebarPosition` first (ascending),
  /// entries without position go last, sorted by title alphabetically.
  static List<GuideEntry> _sortEntries(List<GuideEntry> entries) {
    return entries.toList()
      ..sort((a, b) {
        final ap = a.sidebarPosition;
        final bp = b.sidebarPosition;
        if (ap != null && bp != null) return ap.compareTo(bp);
        if (ap != null) return -1;
        if (bp != null) return 1;
        return a.title.compareTo(b.title);
      });
  }

  /// Recursively collects all `.md` files in [folder].
  ///
  /// Tracks visited canonical paths to prevent infinite loops from symlinks.
  List<File> _collectMarkdownFiles(Folder folder, [Set<String>? visited]) {
    visited ??= {};
    final resolvedPath = folder.resolveSymbolicLinksSync().path;
    if (!visited.add(resolvedPath)) return [];

    final files = <File>[];

    for (final child in folder.getChildren()) {
      if (child is Folder) {
        files.addAll(_collectMarkdownFiles(child, visited));
      } else if (child is File && child.path.endsWith('.md')) {
        files.add(child);
      }
    }

    // Sort for deterministic output.
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }
}
