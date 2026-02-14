// Copyright (c) 2025, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Pure functions that render dartdoc model objects into VitePress-compatible
/// markdown strings.
///
/// All functions use [StringBuffer] to build markdown. They depend on
/// [VitePressPathResolver] for link/path computation and
/// [VitePressDocProcessor] for documentation processing.
library;

import 'package:dartdoc_vitepress/src/comment_references/parser.dart' show operatorNames;
import 'package:dartdoc_vitepress/src/element_type.dart';
import 'package:dartdoc_vitepress/src/generator/vitepress_doc_processor.dart';
import 'package:dartdoc_vitepress/src/generator/vitepress_paths.dart';
import 'package:dartdoc_vitepress/src/model/attribute.dart' show Attribute;
import 'package:dartdoc_vitepress/src/model/container_modifiers.dart';
import 'package:dartdoc_vitepress/src/model/model.dart';
import 'package:meta/meta.dart';

export 'package:dartdoc_vitepress/src/generator/vitepress_paths.dart'
    show isDuplicateSdkLibrary, isInternalSdkLibrary;

// ---------------------------------------------------------------------------
// Generic name helpers (ADR-7).
// ---------------------------------------------------------------------------

/// Builds a plain-text name with generic type parameters.
///
/// Uses `tp.element.name!` for the type parameter name (NOT `tp.name` which
/// contains HTML) and `tp.boundType?.nameWithGenericsPlain` for the bound.
String plainNameWithGenerics(ModelElement element) {
  if (element is TypeParameters && element.typeParameters.isNotEmpty) {
    final params = element.typeParameters.map((tp) {
      var result = tp.element.name!;
      final bound = tp.boundType;
      if (bound != null) {
        result += ' extends ${bound.nameWithGenericsPlain}';
      }
      return result;
    }).join(', ');
    return '${element.name}<$params>';
  }
  return element.name;
}

/// Escapes angle brackets for use in markdown headings and inline text.
///
/// In code fences and inline code, escaping is NOT needed.
String escapeGenerics(String text) =>
    text.replaceAll('<', r'\<').replaceAll('>', r'\>');

// ---------------------------------------------------------------------------
// Testable string helpers.
// ---------------------------------------------------------------------------

/// Escapes pipe characters and angle brackets in table cell content.
///
/// Pipes are escaped to prevent breaking the markdown table structure.
/// Angle brackets are escaped to prevent VitePress/Vue from interpreting
/// generic type parameters (e.g. `List<E>`) as HTML component tags.
/// Content that is already escaped (backslash-prefixed `\<`, `\>`) or
/// wrapped in inline code backticks is left untouched.
@visibleForTesting
String escapeTableCell(String cell) {
  var result = cell.replaceAll('|', r'\|');
  // Escape angle brackets that are not already escaped and not inside
  // backtick-delimited inline code spans.
  if (result.contains('<')) {
    result = _escapeAngleBracketsInCell(result);
  }
  return result;
}

/// Escapes unescaped angle brackets in a table cell, preserving:
/// - Already-escaped sequences (`\<`, `\>`)
/// - Content inside backtick-delimited inline code spans
/// - Markdown link syntax `[text](url)`
/// - VitePress Badge components (`<Badge .../>`)
String _escapeAngleBracketsInCell(String text) {
  final buf = StringBuffer();
  final len = text.length;
  var i = 0;

  while (i < len) {
    final ch = text[i];

    // Skip inline code spans without escaping.
    if (ch == '`') {
      final codeEnd = text.indexOf('`', i + 1);
      if (codeEnd != -1) {
        buf.write(text.substring(i, codeEnd + 1));
        i = codeEnd + 1;
        continue;
      }
    }

    // Skip already-escaped angle brackets.
    if (ch == r'\' && i + 1 < len && (text[i + 1] == '<' || text[i + 1] == '>')) {
      buf.write(text.substring(i, i + 2));
      i += 2;
      continue;
    }

    if (ch == '<') {
      // Preserve VitePress Badge components: <Badge type="..." text="..." />
      if (text.substring(i).startsWith('<Badge ')) {
        final closeIndex = text.indexOf('/>', i);
        if (closeIndex != -1) {
          buf.write(text.substring(i, closeIndex + 2));
          i = closeIndex + 2;
          continue;
        }
      }
      // Escape the angle bracket.
      buf.write(r'\<');
      i++;
    } else if (ch == '>') {
      buf.write(r'\>');
      i++;
    } else {
      buf.write(ch);
      i++;
    }
  }

  return buf.toString();
}

/// Escapes characters that are special in YAML double-quoted string values.
@visibleForTesting
String yamlEscape(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');

// ---------------------------------------------------------------------------
// Helper: _MarkdownPageBuilder
// ---------------------------------------------------------------------------

/// A helper class for building VitePress markdown pages with proper
/// frontmatter, consistent formatting, and reusable section patterns.
class _MarkdownPageBuilder {
  final StringBuffer _buffer = StringBuffer();

  /// Writes the YAML frontmatter block.
  ///
  /// Every generated page disables `editLink`, `prev`, and `next` because
  /// these are auto-generated API pages. `lastUpdated` is inherited from
  /// the site config (enabled by default).
  void writeFrontmatter({
    required String title,
    required String description,
    required Object outline, // bool or List<int>
    String? category,
    String? library,
  }) {
    _buffer.writeln('---');
    // Frontmatter values are YAML strings, not Vue templates. VitePress
    // stores them as plain JavaScript strings in the page data bundle.
    // Raw `<>` from generic types (e.g. `List<E>`) are safe here because:
    // - SSR: @unhead/vue properly HTML-encodes values in <title> and <meta>
    // - SPA: document.title is set via JS (text property, not innerHTML)
    // Using HTML entities (`&lt;`) would show literal `&lt;` in browser tabs
    // during SPA navigation since JS text assignment doesn't decode entities.
    _buffer.writeln('title: "${yamlEscape(title)}"');
    _buffer.writeln('description: "${yamlEscape(description)}"');
    if (category != null) {
      _buffer.writeln('category: "${yamlEscape(category)}"');
    }
    if (library != null) {
      _buffer.writeln('library: "${yamlEscape(library)}"');
    }
    if (outline is bool) {
      _buffer.writeln('outline: $outline');
    } else if (outline is List<int>) {
      _buffer.writeln('outline: [${outline.join(', ')}]');
    }
    _buffer.writeln('editLink: false');
    _buffer.writeln('prev: false');
    _buffer.writeln('next: false');
    _buffer.writeln('---');
    _buffer.writeln();
  }

  /// Writes a Vue breadcrumb component that reads category from frontmatter.
  void writeBreadcrumbComponent() {
    _buffer.writeln('<ApiBreadcrumb />');
    _buffer.writeln();
  }

  /// Writes a top-level heading (h1) with optional badges.
  void writeH1(
    String text, {
    bool deprecated = false,
    List<String> badges = const [],
  }) {
    final escaped = escapeGenerics(text);
    final buf = StringBuffer('# ');

    if (deprecated) {
      buf.write('<Badge type="warning" text="deprecated" /> ');
      buf.write('~~$escaped~~ ');
    } else {
      buf.write('$escaped ');
    }

    for (final badge in badges) {
      buf.write(badge);
      buf.write(' ');
    }

    _buffer.writeln(buf.toString().trimRight());
    _buffer.writeln();
  }

  /// Writes an h2 section heading with an explicit ID to prevent collisions
  /// with member-level anchors (e.g., `## Values` auto-generates `id="values"`
  /// which collides with an enum constant named `values`).
  void writeH2(String text) {
    final slug = text.toLowerCase().replaceAll(' ', '-');
    _buffer.writeln('## $text {#section-$slug}');
    _buffer.writeln();
  }

  /// Writes an h3 member heading with an anchor ID and optional badges.
  void writeH3WithAnchor(
    String text, {
    required String anchor,
    bool deprecated = false,
    List<String> badges = const [],
  }) {
    final escapedText = escapeGenerics(text);
    final buf = StringBuffer('### ');
    if (deprecated) {
      buf.write('<Badge type="warning" text="deprecated" /> ');
      buf.write('~~$escapedText~~');
    } else {
      buf.write(escapedText);
    }
    for (final badge in badges) {
      buf.write(' $badge');
    }
    buf.write(' {#$anchor}');
    _buffer.writeln(buf.toString());
    _buffer.writeln();
  }

  /// Writes a fenced code block (no escaping needed inside).
  void writeCodeBlock(String code, {String language = 'dart'}) {
    _buffer.writeln('```$language');
    _buffer.writeln(code);
    _buffer.writeln('```');
    _buffer.writeln();
  }

  /// Writes a member signature as raw HTML with clickable type links.
  void writeSignature(String htmlSignature) {
    _buffer.writeln(
        '<div class="member-signature"><pre><code>$htmlSignature</code></pre></div>');
    _buffer.writeln();
  }

  /// Writes a deprecation warning container.
  ///
  /// The [message] is escaped for angle brackets to prevent VitePress/Vue
  /// from interpreting generic type parameters in deprecation messages
  /// (e.g. "Use `Foo<Bar>` instead") as HTML component tags.
  void writeDeprecationNotice(String message) {
    _buffer.writeln(':::warning DEPRECATED');
    if (message.isNotEmpty) {
      _buffer.writeln(escapeGenerics(message));
    }
    _buffer.writeln(':::');
    _buffer.writeln();
  }

  /// Writes an info container (blue) for reference sections like
  /// "Implementers", "Superclass Constraints", "Available Extensions".
  ///
  /// Items should be pre-escaped by callers (e.g. via [_markdownLink] or
  /// [escapeGenerics]). This method does NOT apply additional escaping
  /// because items may contain valid markdown links with intentional
  /// backslash-escaped generics.
  void writeInfoContainer(String title, List<String> items) {
    if (items.isEmpty) return;
    _buffer.writeln(':::info $title');
    for (final item in items) {
      _buffer.writeln('- $item');
    }
    _buffer.writeln(':::');
    _buffer.writeln();
  }

  /// Writes a tip container (green) for best practices and important notes.
  void writeTipContainer(String title, String content) {
    _buffer.writeln(':::tip $title');
    if (content.isNotEmpty) {
      _buffer.writeln(content);
    }
    _buffer.writeln(':::');
    _buffer.writeln();
  }

  /// Writes a collapsible details container for source code, parameters, etc.
  void writeDetailsContainer(String summary, String content) {
    _buffer.writeln(':::details $summary');
    if (content.isNotEmpty) {
      _buffer.writeln(content);
    }
    _buffer.writeln(':::');
    _buffer.writeln();
  }

  /// Writes a danger container (red) for breaking changes.
  void writeDangerContainer(String title, String content) {
    _buffer.writeln(':::danger $title');
    if (content.isNotEmpty) {
      _buffer.writeln(content);
    }
    _buffer.writeln(':::');
    _buffer.writeln();
  }

  /// Writes a paragraph of text.
  void writeParagraph(String text) {
    if (text.isNotEmpty) {
      _buffer.writeln(text);
      _buffer.writeln();
    }
  }

  /// Writes an "Inherited from" notice.
  ///
  /// The [className] is escaped for angle brackets to prevent VitePress/Vue
  /// from interpreting generic type parameters in class names as HTML
  /// component tags. While `element.enclosingElement.name` typically returns
  /// a bare name without generics, this provides defensive safety.
  void writeInheritedFrom(String className) {
    _buffer.writeln('*Inherited from ${escapeGenerics(className)}.*');
    _buffer.writeln();
  }

  /// Writes a markdown table with header and rows.
  void writeTable({
    required List<String> headers,
    required List<List<String>> rows,
  }) {
    if (rows.isEmpty) return;
    _buffer.writeln('| ${headers.map(escapeTableCell).join(' | ')} |');
    _buffer.writeln('|${headers.map((_) => '---').join('|')}|');
    for (final row in rows) {
      _buffer.writeln('| ${row.map(escapeTableCell).join(' | ')} |');
    }
    _buffer.writeln();
  }

  /// Writes raw text without any processing.
  void writeRaw(String text) {
    _buffer.write(text);
  }

  @override
  String toString() => _buffer.toString();
}

/// Escapes special HTML characters in text for use inside HTML output.
String _htmlEsc(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Decodes common HTML entities back to plain text.
///
/// Source code from the dartdoc model may contain HTML entities (e.g.
/// `&lt;`, `&gt;`) from the analyzer's HTML-escape pipeline. These must
/// be decoded before embedding in markdown code fences.
String _htmlUnescape(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&#60;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&#62;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll('&#38;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#34;', '"')
    .replaceAll('&#39;', "'");

// ---------------------------------------------------------------------------
// Pre-compiled regular expressions (avoid re-creating on every call).
// ---------------------------------------------------------------------------

/// Matches HTML tags for stripping in [_annotationPlainText].
final _htmlTagRegExp = RegExp(r'<[^>]*>');

/// Matches a leading `# Title` line in documentation text.
final _leadingH1RegExp = RegExp(r'^#\s+(.+?)(\r?\n|$)');

/// Returns the plain-text length of [html] after stripping tags and decoding
/// common HTML entities. Used for measuring signature length against the
/// 80-column threshold.
int _stripHtmlForLength(String html) {
  return html
      .replaceAll(_htmlTagRegExp, '')
      .replaceAll('&lt;', '<')
      .replaceAll('&#60;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#62;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#34;', '"')
      .replaceAll('&#39;', "'")
      .length;
}

// ---------------------------------------------------------------------------
// Shared rendering helpers.
// ---------------------------------------------------------------------------

/// Builds VitePress Badge strings for a container's modifiers.
///
/// Skips modifiers that are already in the declaration (e.g., "class", "enum")
/// and filters using the `hideIfPresent` rules. Returns a list of Badge HTML
/// strings like `<Badge type="info" text="sealed" />`.
List<String> _buildModifierBadges(InheritingContainer container) {
  final badges = <String>[];
  final modifiers = container.containerModifiers;

  for (final modifier in modifiers) {
    // Skip modifiers that should be hidden when another modifier is present
    if (modifier.hideIfPresent.any(modifiers.contains)) continue;

    badges.add('<Badge type="info" text="${modifier.displayName}" />');
  }

  return badges;
}

/// Maps built-in [Attribute] constants to VitePress Badge (type, text) pairs.
///
/// Only "feature" attributes (no setter, inherited, override, etc.) are shown;
/// annotation attributes (like `@protected`) are rendered by [_renderAnnotations].
final _memberBadgeMap = <Attribute, (String type, String text)>{
  Attribute.noSetter: ('tip', 'no setter'),
  Attribute.noGetter: ('tip', 'no getter'),
  Attribute.getterSetterPair: ('tip', 'read / write'),
  Attribute.inherited: ('info', 'inherited'),
  Attribute.inheritedGetter: ('info', 'inherited-getter'),
  Attribute.inheritedSetter: ('info', 'inherited-setter'),
  Attribute.override_: ('info', 'override'),
  Attribute.overrideGetter: ('info', 'override-getter'),
  Attribute.overrideSetter: ('info', 'override-setter'),
  Attribute.extended: ('info', 'extended'),
  Attribute.late_: ('warning', 'late'),
  Attribute.final_: ('tip', 'final'),
  Attribute.covariant: ('info', 'covariant'),
};

/// Builds VitePress Badge strings for a member element's attributes.
///
/// Returns badges for properties (no setter, inherited, etc.), methods
/// (inherited, override), and constructors (factory, const).
List<String> _buildMemberBadges(ModelElement element) {
  final badges = <String>[];

  // Constructor-specific badges.
  if (element is Constructor) {
    if (element.isFactory) {
      badges.add('<Badge type="tip" text="factory" />');
    }
    if (element.isConst) {
      badges.add('<Badge type="tip" text="const" />');
    }
  }

  // Method-specific badges.
  if (element is Method) {
    if (element.isInherited) {
      badges.add('<Badge type="info" text="inherited" />');
    }
    if (element.attributes.contains(Attribute.override_)) {
      badges.add('<Badge type="info" text="override" />');
    }
    if (element.isProvidedByExtension) {
      badges.add('<Badge type="info" text="extension" />');
    }
  }

  // Field/property badges from attributes.
  if (element is Field) {
    if (element.isProvidedByExtension) {
      badges.add('<Badge type="info" text="extension" />');
    }
    // Sort attributes by sortGroup for consistent ordering.
    final sortedAttrs = element.attributes.toList()
      ..sort((a, b) => a.sortGroup.compareTo(b.sortGroup));
    for (final attr in sortedAttrs) {
      final badge = _memberBadgeMap[attr];
      if (badge != null) {
        badges.add('<Badge type="${badge.$1}" text="${badge.$2}" />');
      }
    }
  }

  return badges;
}

/// Builds a markdown link for a documentable element.
///
/// Returns `[DisplayName](/api/lib/ClassName)` if a URL is available,
/// or just the display name as plain text if not.
String _markdownLink(Documentable element, VitePressPathResolver paths) {
  final url = paths.linkFor(element);
  // Use full name with generics for elements that have type parameters.
  final rawName =
      element is ModelElement ? plainNameWithGenerics(element) : element.name;
  final name = escapeGenerics(rawName);
  if (url == null) return name;
  return '[$name]($url)';
}

/// Extracts the deprecation message from an element's annotations.
///
/// Uses the analyzer's `ElementAnnotation` to find the `@Deprecated` annotation
/// and retrieve its `message` field via `computeConstantValue()`.
String _extractDeprecationMessage(ModelElement element) {
  for (final annotation in element.element.metadata.annotations) {
    if (!annotation.isDeprecated) continue;
    final value = annotation.computeConstantValue();
    if (value == null) continue;
    final message = value.getField('message')?.toStringValue();
    if (message != null && message.isNotEmpty) return message;
  }
  return '';
}

// Plain-text container declaration (kept for potential future use, e.g. RSS,
// search index). Linked version below is used for rendering.
//
// String _buildContainerDeclaration(InheritingContainer container) { ... }

/// Builds linked HTML container declaration (class/enum) with clickable types.
String _buildLinkedContainerDeclaration(
    InheritingContainer container, VitePressPathResolver paths) {
  final buf = StringBuffer();

  // Modifiers as keyword spans
  for (final modifier in container.containerModifiers) {
    if (modifier == ContainerModifier.abstract &&
        container.containerModifiers.contains(ContainerModifier.sealed)) {
      continue;
    }
    buf.write('<span class="kw">${_htmlEsc(modifier.displayName)}</span> ');
  }

  // Kind keyword
  if (container is Class) {
    buf.write('<span class="kw">class</span> ');
  } else if (container is Enum) {
    buf.write('<span class="kw">enum</span> ');
  }

  // Name
  buf.write('<span class="fn">${_htmlEsc(container.name)}</span>');
  // Type parameters
  if (container.typeParameters.isNotEmpty) {
    buf.write('&lt;');
    buf.write(container.typeParameters.map((tp) {
      final tpBuf = StringBuffer(_htmlEsc(tp.element.name!));
      if (tp.boundType != null) {
        tpBuf.write(' <span class="kw">extends</span> ');
        tpBuf.write(_renderTypeLinked(tp.boundType!, paths));
      }
      return tpBuf.toString();
    }).join(', '));
    buf.write('&gt;');
  }

  // Extends clause
  final supertype = container.supertype;
  if (supertype != null &&
      supertype.modelElement.name != 'Object' &&
      supertype.modelElement.name != 'Enum') {
    buf.write(' <span class="kw">extends</span> ');
    buf.write(_renderTypeLinked(supertype, paths));
  }

  // With clause
  if (container is MixedInTypes) {
    final mixins = container.publicMixedInTypes.toList();
    if (mixins.isNotEmpty) {
      buf.write(' <span class="kw">with</span> ');
      buf.write(mixins.map((m) => _renderTypeLinked(m, paths)).join(', '));
    }
  }

  // Implements clause
  if (container.publicInterfaces.isNotEmpty) {
    buf.write(' <span class="kw">implements</span> ');
    buf.write(container.publicInterfaces
        .map((i) => _renderTypeLinked(i, paths))
        .join(', '));
  }

  return buf.toString();
}

/// Builds linked HTML mixin declaration with clickable types.
String _buildLinkedMixinDeclaration(
    Mixin mixin_, VitePressPathResolver paths) {
  final buf = StringBuffer();

  // Modifiers
  for (final modifier in mixin_.containerModifiers) {
    buf.write('<span class="kw">${_htmlEsc(modifier.displayName)}</span> ');
  }

  buf.write('<span class="kw">mixin</span> ');
  buf.write('<span class="fn">${_htmlEsc(mixin_.name)}</span>');

  // Type parameters
  if (mixin_.typeParameters.isNotEmpty) {
    buf.write('&lt;');
    buf.write(mixin_.typeParameters.map((tp) {
      final tpBuf = StringBuffer(_htmlEsc(tp.element.name!));
      if (tp.boundType != null) {
        tpBuf.write(' <span class="kw">extends</span> ');
        tpBuf.write(_renderTypeLinked(tp.boundType!, paths));
      }
      return tpBuf.toString();
    }).join(', '));
    buf.write('&gt;');
  }

  // On clause (superclass constraints)
  final constraints = mixin_.publicSuperclassConstraints.toList();
  if (constraints.isNotEmpty) {
    buf.write(' <span class="kw">on</span> ');
    buf.write(constraints.map((c) => _renderTypeLinked(c, paths)).join(', '));
  }

  // Implements clause
  if (mixin_.publicInterfaces.isNotEmpty) {
    buf.write(' <span class="kw">implements</span> ');
    buf.write(mixin_.publicInterfaces
        .map((i) => _renderTypeLinked(i, paths))
        .join(', '));
  }

  return buf.toString();
}

/// Builds linked HTML extension declaration with clickable "on" type.
String _buildLinkedExtensionDeclaration(
    Extension ext, VitePressPathResolver paths) {
  final buf = StringBuffer();
  buf.write('<span class="kw">extension</span> ');
  buf.write('<span class="fn">${_htmlEsc(ext.name)}</span>');

  // Type parameters
  if (ext.typeParameters.isNotEmpty) {
    buf.write('&lt;');
    buf.write(ext.typeParameters.map((tp) {
      final tpBuf = StringBuffer(_htmlEsc(tp.element.name!));
      if (tp.boundType != null) {
        tpBuf.write(' <span class="kw">extends</span> ');
        tpBuf.write(_renderTypeLinked(tp.boundType!, paths));
      }
      return tpBuf.toString();
    }).join(', '));
    buf.write('&gt;');
  }

  buf.write(' <span class="kw">on</span> ');
  buf.write(_renderTypeLinked(ext.extendedElement, paths));

  return buf.toString();
}

/// Builds linked HTML extension type declaration with clickable types.
String _buildLinkedExtensionTypeDeclaration(
    ExtensionType et, VitePressPathResolver paths) {
  final buf = StringBuffer();
  buf.write('<span class="kw">extension type</span> ');
  buf.write('<span class="fn">${_htmlEsc(et.name)}</span>');

  // Type parameters
  if (et.typeParameters.isNotEmpty) {
    buf.write('&lt;');
    buf.write(et.typeParameters.map((tp) {
      final tpBuf = StringBuffer(_htmlEsc(tp.element.name!));
      if (tp.boundType != null) {
        tpBuf.write(' <span class="kw">extends</span> ');
        tpBuf.write(_renderTypeLinked(tp.boundType!, paths));
      }
      return tpBuf.toString();
    }).join(', '));
    buf.write('&gt;');
  }

  // Representation type
  buf.write('(${_renderTypeLinked(et.representationType, paths)})');

  // Implements clause
  if (et.publicInterfaces.isNotEmpty) {
    buf.write(' <span class="kw">implements</span> ');
    buf.write(et.publicInterfaces
        .map((i) => _renderTypeLinked(i, paths))
        .join(', '));
  }

  return buf.toString();
}

// ---------------------------------------------------------------------------
// Plain-text signature helpers (kept for potential future use, e.g. RSS feeds,
// search index generation, or fallback rendering without HTML).
// ---------------------------------------------------------------------------

// String _renderTypePlain(ElementType type) {
//   if (type is Callable) {
//     final buf = StringBuffer();
//     buf.write(_renderTypePlain(type.returnType));
//     buf.write(' ');
//     buf.write(type.nameWithGenericsPlain);
//     buf.write('(');
//     buf.write(_buildCallableParameterList(type.parameters));
//     buf.write(')');
//     if (type.nullabilitySuffix.isNotEmpty) {
//       return '($buf)${type.nullabilitySuffix}';
//     }
//     return buf.toString();
//   }
//   return type.nameWithGenericsPlain;
// }
//
// String _buildCallableParameterList(List<Parameter> parameters) {
//   if (parameters.isEmpty) return '';
//   final parts = <String>[];
//   var inOptionalPositional = false;
//   var inNamed = false;
//   for (final param in parameters) {
//     final buf = StringBuffer();
//     if (param.isOptionalPositional && !inOptionalPositional) {
//       inOptionalPositional = true;
//       buf.write('[');
//     } else if (param.isNamed && !inNamed) {
//       inNamed = true;
//       buf.write('{');
//     }
//     if (param.isRequiredNamed) buf.write('required ');
//     buf.write(_renderTypePlain(param.modelType));
//     if (param.name.isNotEmpty) buf.write(' ${param.name}');
//     final defaultValue = param.defaultValue;
//     if (defaultValue != null && defaultValue.isNotEmpty) {
//       buf.write(' = $defaultValue');
//     }
//     parts.add(buf.toString());
//   }
//   var result = parts.join(', ');
//   if (inOptionalPositional) result += ']';
//   if (inNamed) result += '}';
//   return result;
// }
//
// String _buildParameterSignature(List<Parameter> parameters) {
//   if (parameters.isEmpty) return '()';
//   final parts = <String>[];
//   var inOptionalPositional = false;
//   var inNamed = false;
//   for (final param in parameters) {
//     final buf = StringBuffer();
//     if (param.isOptionalPositional && !inOptionalPositional) {
//       inOptionalPositional = true;
//       buf.write('[');
//     } else if (param.isNamed && !inNamed) {
//       inNamed = true;
//       buf.write('{');
//     }
//     if (param.isRequiredNamed) buf.write('required ');
//     buf.write(_renderTypePlain(param.modelType));
//     if (param.name.isNotEmpty) buf.write(' ${param.name}');
//     final defaultValue = param.defaultValue;
//     if (defaultValue != null && defaultValue.isNotEmpty) {
//       buf.write(' = $defaultValue');
//     }
//     parts.add(buf.toString());
//   }
//   var result = parts.join(', ');
//   if (inOptionalPositional) result += ']';
//   if (inNamed) result += '}';
//   return '($result)';
// }
//
// String _buildCallableSignature(ModelElement element) {
//   final buf = StringBuffer();
//   if (element is Method) {
//     buf.write('${_renderTypePlain(element.modelType.returnType)} ');
//   } else if (element is ModelFunctionTyped) {
//     buf.write('${_renderTypePlain(element.modelType.returnType)} ');
//   }
//   buf.write(plainNameWithGenerics(element));
//   buf.write(_buildParameterSignature(element.parameters));
//   return buf.toString();
// }
//
// String _buildConstructorSignature(Constructor constructor) {
//   final buf = StringBuffer();
//   if (constructor.isConst) buf.write('const ');
//   if (constructor.isFactory) buf.write('factory ');
//   buf.write(constructor.displayName);
//   buf.write(_buildParameterSignature(constructor.parameters));
//   return buf.toString();
// }

// ---------------------------------------------------------------------------
// Linked rendering helpers (HTML with clickable type links).
// ---------------------------------------------------------------------------

/// Renders an [ElementType] as HTML with `<a>` links for locally documented
/// types. Types without a local page (SDK types, type parameters, void,
/// dynamic, Never) render as plain HTML-escaped text — no broken links.
String _renderTypeLinked(ElementType type, VitePressPathResolver paths) {
  // DefinedElementType (includes ParameterizedElementType, TypeParameterElementType)
  if (type is DefinedElementType) {
    final url = paths.urlFor(type.modelElement);
    final name = _htmlEsc(type.name);
    final buf = StringBuffer();

    // Type name — link if we have a page, styled span otherwise
    buf.write(url != null
        ? '<a href="$url" class="type-link">$name</a>'
        : '<span class="type">$name</span>');

    // Type arguments (recursive)
    final args = type.typeArguments.toList();
    if (args.isNotEmpty) {
      buf.write('&lt;');
      buf.write(args.map((a) => _renderTypeLinked(a, paths)).join(', '));
      buf.write('&gt;');
    }

    buf.write(_htmlEsc(type.nullabilitySuffix));
    return buf.toString();
  }

  // Callable (Function types): ReturnType Function(params)
  if (type is Callable) {
    final buf = StringBuffer();
    buf.write(_renderTypeLinked(type.returnType, paths));
    buf.write(' <span class="type">Function</span>(');
    buf.write(_buildLinkedCallableParamList(type.parameters, paths));
    buf.write(')');
    if (type.nullabilitySuffix.isNotEmpty) {
      return '(${buf.toString()})${_htmlEsc(type.nullabilitySuffix)}';
    }
    return buf.toString();
  }

  // UndefinedElementType (void, dynamic, Never) — styled as type
  return '<span class="type">${_htmlEsc(type.nameWithGenericsPlain)}</span>';
}

/// Wraps a default value in an appropriate syntax-highlighting span.
///
/// Numeric literals → `.num-lit`, string literals → `.str-lit`,
/// `true`/`false`/`null` → `.kw`, everything else → plain escaped text.
String _wrapDefaultValue(String value) {
  final trimmed = value.trim();
  final escaped = _htmlEsc(trimmed);

  // Numeric literal (int or double, possibly negative)
  if (RegExp(r'^-?\d').hasMatch(trimmed)) {
    return '<span class="num-lit">$escaped</span>';
  }
  // String literal (single/double/raw/triple-quoted)
  if (RegExp(r'''^r?['"]''').hasMatch(trimmed)) {
    return '<span class="str-lit">$escaped</span>';
  }
  // Boolean / null keywords
  if (trimmed == 'true' || trimmed == 'false' || trimmed == 'null') {
    return '<span class="kw">$escaped</span>';
  }
  // Constant references, const expressions — plain text
  return escaped;
}

/// Builds the inner parameter list for a callable type with linked types.
String _buildLinkedCallableParamList(
    List<Parameter> parameters, VitePressPathResolver paths) {
  if (parameters.isEmpty) return '';

  final parts = <String>[];
  var inOptionalPositional = false;
  var inNamed = false;

  for (final param in parameters) {
    final buf = StringBuffer();

    if (param.isOptionalPositional && !inOptionalPositional) {
      inOptionalPositional = true;
      buf.write('[');
    } else if (param.isNamed && !inNamed) {
      inNamed = true;
      buf.write('{');
    }

    if (param.isRequiredNamed) {
      buf.write('<span class="kw">required</span> ');
    }

    buf.write(_renderTypeLinked(param.modelType, paths));
    if (param.name.isNotEmpty) {
      buf.write(' <span class="param">${_htmlEsc(param.name)}</span>');
    }

    final defaultValue = param.defaultValue;
    if (defaultValue != null && defaultValue.isNotEmpty) {
      buf.write(' = ${_wrapDefaultValue(defaultValue)}');
    }

    parts.add(buf.toString());
  }

  var result = parts.join(', ');
  if (inOptionalPositional) result += ']';
  if (inNamed) result += '}';
  return result;
}

/// Builds a linked parameter signature string for an element.
///
/// When [prefixLength] is provided, the total signature length is checked
/// against an 80-column threshold. If the single-line version exceeds the
/// limit, parameters are formatted in tall style (one per line, 2-space
/// indent, trailing commas) following `dart format` conventions.
String _buildLinkedParameterSignature(
    List<Parameter> parameters, VitePressPathResolver paths,
    {int prefixLength = 0}) {
  if (parameters.isEmpty) return '()';

  // Build individual parameter HTML strings (without group brackets).
  final requiredPositional = <String>[];
  final optionalPositional = <String>[];
  final named = <String>[];

  for (final param in parameters) {
    final buf = StringBuffer();

    if (param.isRequiredNamed) {
      buf.write('<span class="kw">required</span> ');
    }

    buf.write(_renderTypeLinked(param.modelType, paths));
    if (param.name.isNotEmpty) {
      buf.write(' <span class="param">${_htmlEsc(param.name)}</span>');
    }

    final defaultValue = param.defaultValue;
    if (defaultValue != null && defaultValue.isNotEmpty) {
      buf.write(' = ${_wrapDefaultValue(defaultValue)}');
    }

    if (param.isNamed) {
      named.add(buf.toString());
    } else if (param.isOptionalPositional) {
      optionalPositional.add(buf.toString());
    } else {
      requiredPositional.add(buf.toString());
    }
  }

  // Assemble single-line version with correct brackets.
  final singleLine = _buildSingleLineParams(
      requiredPositional, optionalPositional, named);

  // Check if it fits in 80 columns.
  if (prefixLength + _stripHtmlForLength(singleLine) <= 80) {
    return singleLine;
  }

  // Tall style: one parameter per line, 2-space indent, trailing commas.
  return _buildTallParameterSignature(
      requiredPositional, optionalPositional, named);
}

/// Assembles a single-line `(...)` parameter list with correct brackets.
String _buildSingleLineParams(List<String> requiredPositional,
    List<String> optionalPositional, List<String> named) {
  final all = <String>[];
  all.addAll(requiredPositional);

  if (optionalPositional.isNotEmpty) {
    all.add('[${optionalPositional.join(', ')}]');
  } else if (named.isNotEmpty) {
    all.add('{${named.join(', ')}}');
  }

  return '(${all.join(', ')})';
}

/// Builds a tall-style (multi-line) parameter signature following dart format.
///
/// Each parameter is on its own line with 2-space indent and a trailing comma.
/// Group brackets (`{`, `}`, `[`, `]`) follow dart format conventions:
/// - Only named: `({\n  p1,\n  p2,\n})`
/// - Only optional: `([\n  p1,\n  p2,\n])`
/// - Only required: `(\n  p1,\n  p2,\n)`
/// - Mixed: `(\n  pos, {\n  named,\n})` — `{`/`[` on same line as last positional
String _buildTallParameterSignature(List<String> requiredPositional,
    List<String> optionalPositional, List<String> named) {
  final buf = StringBuffer();

  if (named.isNotEmpty && requiredPositional.isEmpty) {
    // Only named: ({  p1,  p2,  })
    buf.write('({\n');
    for (final p in named) {
      buf.write('  $p,\n');
    }
    buf.write('})');
    return buf.toString();
  }

  if (optionalPositional.isNotEmpty && requiredPositional.isEmpty) {
    // Only optional positional: ([  p1,  p2,  ])
    buf.write('([\n');
    for (final p in optionalPositional) {
      buf.write('  $p,\n');
    }
    buf.write('])');
    return buf.toString();
  }

  // Has required positional params.
  buf.write('(\n');

  if (named.isNotEmpty) {
    // Mixed: required positional + named.
    // All required except last, then last + { on same line.
    for (var i = 0; i < requiredPositional.length - 1; i++) {
      buf.write('  ${requiredPositional[i]},\n');
    }
    buf.write('  ${requiredPositional.last}, {\n');
    for (final p in named) {
      buf.write('  $p,\n');
    }
    buf.write('})');
  } else if (optionalPositional.isNotEmpty) {
    // Mixed: required positional + optional positional.
    for (var i = 0; i < requiredPositional.length - 1; i++) {
      buf.write('  ${requiredPositional[i]},\n');
    }
    buf.write('  ${requiredPositional.last}, [\n');
    for (final p in optionalPositional) {
      buf.write('  $p,\n');
    }
    buf.write('])');
  } else {
    // Only required positional.
    for (final p in requiredPositional) {
      buf.write('  $p,\n');
    }
    buf.write(')');
  }

  return buf.toString();
}

/// Builds a linked method/function signature as HTML.
String _buildLinkedCallableSignature(
    ModelElement element, VitePressPathResolver paths) {
  final buf = StringBuffer();

  if (element is Method) {
    buf.write('${_renderTypeLinked(element.modelType.returnType, paths)} ');
  } else if (element is ModelFunctionTyped) {
    buf.write('${_renderTypeLinked(element.modelType.returnType, paths)} ');
  }

  buf.write('<span class="fn">${_htmlEsc(plainNameWithGenerics(element))}</span>');

  final prefixLength = _stripHtmlForLength(buf.toString());
  buf.write(_buildLinkedParameterSignature(element.parameters, paths,
      prefixLength: prefixLength));

  return buf.toString();
}

/// Builds a linked constructor signature as HTML.
String _buildLinkedConstructorSignature(
    Constructor constructor, VitePressPathResolver paths) {
  final buf = StringBuffer();

  if (constructor.isConst) buf.write('<span class="kw">const</span> ');
  if (constructor.isFactory) buf.write('<span class="kw">factory</span> ');

  buf.write('<span class="fn">${_htmlEsc(constructor.displayName)}</span>');

  final prefixLength = _stripHtmlForLength(buf.toString());
  buf.write(_buildLinkedParameterSignature(constructor.parameters, paths,
      prefixLength: prefixLength));

  return buf.toString();
}

/// Builds a linked field/property signature as HTML.
String _buildLinkedFieldSignature(
    Field field, VitePressPathResolver paths) {
  final sig = StringBuffer();
  if (field.isConst) {
    sig.write('<span class="kw">const</span> ');
  } else if (field.isFinal) {
    sig.write('<span class="kw">final</span> ');
  }
  if (field.isLate) {
    sig.write('<span class="kw">late</span> ');
  }

  final linkedType = _renderTypeLinked(field.modelType, paths);
  final fnName = '<span class="fn">${_htmlEsc(field.name)}</span>';
  if (field.hasExplicitGetter && !field.hasExplicitSetter) {
    sig.write('$linkedType <span class="kw">get</span> $fnName');
  } else if (field.hasExplicitSetter && !field.hasExplicitGetter) {
    sig.write(
        '<span class="kw">set</span> $fnName($linkedType <span class="param">value</span>)');
  } else if (field.hasExplicitGetter && field.hasExplicitSetter) {
    sig.write('$linkedType <span class="kw">get</span> $fnName');
  } else {
    sig.write('$linkedType $fnName');
  }

  if (field.isConst && field.hasConstantValueForDisplay) {
    sig.write(' = ${_wrapDefaultValue(field.constantValueBase)}');
  }

  return sig.toString();
}

/// Builds a linked top-level property/constant signature as HTML.
String _buildLinkedPropertySignature(
    TopLevelVariable prop, VitePressPathResolver paths) {
  final sig = StringBuffer();
  if (prop.isConst) {
    sig.write('<span class="kw">const</span> ');
  } else if (prop.isFinal) {
    sig.write('<span class="kw">final</span> ');
  }
  sig.write(
      '${_renderTypeLinked(prop.modelType, paths)} <span class="fn">${_htmlEsc(prop.name)}</span>');

  if (prop.isConst && prop.hasConstantValueForDisplay) {
    sig.write(' = ${_wrapDefaultValue(prop.constantValueBase)}');
  }

  return sig.toString();
}

/// Renders the documentation body for a member element.
///
/// This handles the full doc, deprecation notice, and inherited-from marker.
/// Post-processes member documentation to fix heading levels and IDs.
///
/// Doc comments may contain H2/H3 headings with explicit `{#id}` anchors.
/// When multiple members on the same page have the same headings (e.g.
/// `## Other resources {#other-resources}`), VitePress fails on duplicate IDs.
///
/// This function:
/// 1. Strips explicit `{#...}` heading IDs.
/// 2. Increases heading depth by 2 levels (## -> ####, ### -> #####) so that
///    headings within member docs nest properly under the H3 member heading.
/// 3. Appends a unique explicit `{#memberAnchor-heading-slug}` ID to each
///    heading, preventing VitePress auto-slug conflicts when multiple members
///    on the same page have identically-named headings.
String _postProcessMemberDoc(String doc, {required String memberAnchor}) {
  final lines = doc.split('\n');
  final result = <String>[];
  for (final line in lines) {
    var processed = line;
    // Match markdown headings: ^#{1,6} ...
    final headingMatch = RegExp(r'^(#{1,6})\s').firstMatch(processed);
    if (headingMatch != null) {
      // Strip explicit {#...} ID suffixes
      processed = processed.replaceAll(RegExp(r'\s*\{#[^}]+\}\s*$'), '');
      // Increase heading depth by 2 (members are under H3)
      final hashes = headingMatch.group(1)!;
      final newDepth = hashes.length + 2;
      if (newDepth <= 6) {
        processed = processed.replaceFirst(hashes, '#' * newDepth);
      }
      // Extract the heading text (after the hashes and space) for slug generation
      final headingText = processed.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
      final headingSlug = VitePressPathResolver.sanitizeAnchor(headingText);
      if (headingSlug.isNotEmpty) {
        processed = '$processed {#$memberAnchor-$headingSlug}';
      }
    }
    result.add(processed);
  }
  return result.join('\n');
}

void _renderMemberDocumentation(
  _MarkdownPageBuilder builder,
  ModelElement element,
  VitePressDocProcessor docs,
  VitePressPathResolver paths, {
  required String memberAnchor,
}) {
  // Deprecation warning
  if (element.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(element));
  }

  // Main documentation — separate getter/setter docs when both have documentation
  if (element is Field && element.getterSetterBothAvailable) {
    final getterDoc = docs.processDocumentation(element.getter!);
    final setterDoc = docs.processDocumentation(element.setter!);
    final combinedDoc = StringBuffer();
    if (getterDoc.isNotEmpty) {
      combinedDoc.writeln('**getter:**\n');
      combinedDoc.writeln(getterDoc);
      combinedDoc.writeln();
    }
    if (setterDoc.isNotEmpty) {
      combinedDoc.writeln('**setter:**\n');
      combinedDoc.writeln(setterDoc);
    }
    var doc = combinedDoc.toString().trimRight();
    doc = _postProcessMemberDoc(doc, memberAnchor: memberAnchor);
    builder.writeParagraph(doc);
  } else {
    var doc = docs.processDocumentation(element);
    doc = _postProcessMemberDoc(doc, memberAnchor: memberAnchor);
    builder.writeParagraph(doc);
  }

  // Inherited-from notice: use the analyzer element's enclosing element name
  // to find the defining class. This avoids accessing `definingEnclosingContainer`
  // which is @protected/@visibleForTesting.
  if (element is Inheritable && element.isInherited) {
    final definingClassName =
        element.element.enclosingElement?.name ?? 'unknown';
    builder.writeInheritedFrom(definingClassName);
  }

  // Extension attribution notice — matches api.dart.dev format:
  // "Available on Type, provided by the ExtensionName extension"
  if ((element is Method && element.isProvidedByExtension) ||
      (element is Field && element.isProvidedByExtension)) {
    final ext = element is Method
        ? element.enclosingExtension
        : (element as Field).enclosingExtension;
    final extLink = _markdownLink(ext, paths);
    final onType = ext.extendedElement;
    final onTypeName = onType is DefinedElementType
        ? _markdownLink(onType.modelElement, paths)
        : escapeGenerics(onType.nameWithGenericsPlain);
    builder.writeParagraph(
        '*Available on $onTypeName, provided by the $extLink extension*');
  }
}

/// Computes the anchor ID for a member element.
///
/// For operators, maps the symbol to a URL-safe name.
/// For constructors, uses the constructor name lowercased.
/// For other members, uses the element name lowercased.
String _memberAnchor(ModelElement element) {
  if (element is Operator) {
    // The reference name is the raw operator symbol (e.g., '==', '[]')
    final refName = element.referenceName;
    final anchorSuffix = operatorNames[refName] ?? refName.toLowerCase();
    return 'operator-$anchorSuffix';
  }
  if (element is Constructor) {
    if (element.isUnnamedConstructor) {
      // Prefix with 'ctor-' to avoid collision with VitePress auto-generated
      // ID for the class H1 heading (which would also be lowercased class name).
      return 'ctor-${element.enclosingElement.name.toLowerCase()}';
    }
    return element.element.name!.toLowerCase();
  }
  final name = element.name.toLowerCase();
  // Prefix property anchors to avoid collision with methods of the same name
  // (e.g. property `s` and method `s()` would both produce anchor `{#s}`).
  if (element is Field) {
    return 'prop-$name';
  }
  return name;
}

/// Renders a "View source" link for elements that have a source URL.
void _renderSourceLink(_MarkdownPageBuilder builder, ModelElement element) {
  if (element.hasSourceHref) {
    builder.writeParagraph('[View source](${element.sourceHref})');
  }
}

/// Renders annotations for an element (excluding `@Deprecated` which is
/// handled separately as a deprecation notice).
///
/// Uses the source representation of each annotation for plain-text output
/// (the `linkedNameWithParameters` getter produces HTML, which is not
/// suitable for markdown).
void _renderAnnotations(_MarkdownPageBuilder builder, ModelElement element) {
  if (!element.hasAnnotations) return;
  final annotations = element.annotations
      .map(_annotationPlainText)
      .where(
          (text) => text != '@deprecated' && !text.startsWith('@Deprecated('))
      .map((text) => '`$text`')
      .toList();
  if (annotations.isEmpty) return;
  builder.writeParagraph('**Annotations:** ${annotations.join(', ')}');
}

/// Converts an annotation's `linkedNameWithParameters` (which may contain
/// HTML tags and entities) into plain text suitable for markdown output.
String _annotationPlainText(Attribute annotation) {
  return annotation.linkedNameWithParameters
      .replaceAll(_htmlTagRegExp, '') // Strip HTML tags
      .replaceAll('&lt;', '<')
      .replaceAll('&#60;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#62;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#34;', '"')
      .replaceAll('&#39;', "'");
}

/// Renders the inheritance chain for a container (class/enum/mixin).
///
/// Shows: `Object → Ancestor → ... → CurrentClass` using `publicSuperChainReversed`.
/// Object is plain text, intermediate types are markdown links, current class is bold.
void _renderInheritanceChain(
  _MarkdownPageBuilder builder,
  InheritingContainer container,
  VitePressPathResolver paths,
) {
  final chain = container.publicSuperChainReversed.toList();
  if (chain.isEmpty) return;

  final parts = <String>['Object'];
  for (final type in chain) {
    parts.add(_markdownLink(type.modelElement, paths));
  }
  // Current class — bold, no link
  parts.add('**${escapeGenerics(plainNameWithGenerics(container))}**');

  builder.writeParagraph(':::info Inheritance\n${parts.join(' → ')}\n:::');
}

/// Renders the "Implemented types" info block for a container.
void _renderImplementedTypes(
  _MarkdownPageBuilder builder,
  InheritingContainer container,
  VitePressPathResolver paths,
) {
  final interfaces = container.publicInterfaces;
  if (interfaces.isEmpty) return;

  builder.writeInfoContainer(
    'Implemented types',
    interfaces.map((i) => _markdownLink(i.modelElement, paths)).toList(),
  );
}

/// Renders the "Mixed-in types" info block for a container.
void _renderMixedInTypes(
  _MarkdownPageBuilder builder,
  InheritingContainer container,
  VitePressPathResolver paths,
) {
  if (container is! MixedInTypes) return;
  final mixins = container.publicMixedInTypes.toList();
  if (mixins.isEmpty) return;

  builder.writeInfoContainer(
    'Mixed-in types',
    mixins.map((m) => _markdownLink(m.modelElement, paths)).toList(),
  );
}

/// Renders the "Implementers" section for a class/interface.
void _renderImplementors(
  _MarkdownPageBuilder builder,
  InheritingContainer container,
  VitePressPathResolver paths,
) {
  final implementors = container.publicImplementersSorted;
  if (implementors.isEmpty) return;

  builder.writeInfoContainer(
    'Implementers',
    implementors.map((impl) => _markdownLink(impl, paths)).toList(),
  );
}

/// Renders the "Available Extensions" section for a class.
void _renderAvailableExtensions(
  _MarkdownPageBuilder builder,
  InheritingContainer container,
  VitePressPathResolver paths,
) {
  final extensions = container.potentiallyApplicableExtensionsSorted;
  if (extensions.isEmpty) return;

  builder.writeInfoContainer(
    'Available Extensions',
    extensions.map((ext) => _markdownLink(ext, paths)).toList(),
  );
}

/// Renders a library overview table for a specific element kind group.
void _renderLibraryOverviewTable(
  _MarkdownPageBuilder builder,
  String sectionTitle,
  List<Documentable> elements,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  if (elements.isEmpty) return;

  // Filter out elements that don't have a link (e.g. re-exported external/SDK
  // classes whose canonical library is not local). The sidebar already excludes
  // these via _belongsToLibrary() filtering; apply the same logic here.
  final linkableElements =
      elements.where((e) => paths.linkFor(e) != null).toList();
  if (linkableElements.isEmpty) return;

  builder.writeH2(sectionTitle);

  final rows = <List<String>>[];
  for (final element in linkableElements) {
    final link = _markdownLink(element, paths);
    final oneLineDoc = element is ModelElement
        ? docs.extractOneLineDoc(element)
        : (element.documentation ?? '');

    final isDeprecated = element is ModelElement && element.isDeprecated;
    final nameCell = isDeprecated ? '~~$link~~' : link;

    final descCell = isDeprecated && oneLineDoc.isNotEmpty
        ? '**Deprecated.** $oneLineDoc'
        : oneLineDoc;

    rows.add([nameCell, descCell]);
  }

  const singularNames = {
    'Classes': 'Class',
    'Exceptions': 'Exception',
    'Enums': 'Enum',
    'Mixins': 'Mixin',
    'Extensions': 'Extension',
    'Extension Types': 'Extension Type',
    'Functions': 'Function',
    'Properties': 'Property',
    'Constants': 'Constant',
    'Typedefs': 'Typedef',
  };
  final singularName = singularNames[sectionTitle] ?? sectionTitle;

  builder.writeTable(
    headers: [singularName, 'Description'],
    rows: rows,
  );
}

// ---------------------------------------------------------------------------
// Container member sections renderer.
// ---------------------------------------------------------------------------

/// Renders all member sections for a container (class, enum, mixin, extension,
/// extension type).
///
/// Section order: Constructors, Properties, Methods, Operators,
/// Static Properties, Static Methods, Constants.
void _renderContainerMembers(
  _MarkdownPageBuilder builder,
  Container container,
  VitePressDocProcessor docs,
  VitePressPathResolver paths,
) {
  // Track used anchors per page to deduplicate (e.g., multiple `toJS`
  // extension getters from different extensions on the same class).
  // Pre-seed with the H1 heading slug (auto-generated by VitePress from
  // the page title) to avoid collisions with member anchors.
  final titleSlug = plainNameWithGenerics(container)
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  final usedAnchors = <String>{titleSlug};

  // 1. Constructors
  if (container.hasPublicConstructors) {
    builder.writeH2('Constructors');
    for (final ctor in container.publicConstructorsSorted) {
      _renderConstructorMember(builder, ctor, docs, usedAnchors, paths);
    }
  }

  // 2. Properties (instance fields)
  final instanceFields = container.availableInstanceFieldsSorted;
  if (instanceFields.isNotEmpty) {
    builder.writeH2('Properties');
    for (final field in instanceFields) {
      _renderFieldMember(builder, field, docs, usedAnchors, paths);
    }
  }

  // 3. Methods (instance methods)
  final instanceMethods = container.availableInstanceMethodsSorted;
  if (instanceMethods.isNotEmpty) {
    builder.writeH2('Methods');
    for (final method in instanceMethods) {
      _renderMethodMember(builder, method, docs, usedAnchors, paths);
    }
  }

  // 4. Operators
  final operators = container.availableInstanceOperatorsSorted;
  if (operators.isNotEmpty) {
    builder.writeH2('Operators');
    for (final op in operators) {
      _renderMethodMember(builder, op, docs, usedAnchors, paths);
    }
  }

  // 5. Static Properties
  final staticFields = container.publicVariableStaticFieldsSorted;
  if (staticFields.isNotEmpty) {
    builder.writeH2('Static Properties');
    for (final field in staticFields) {
      _renderFieldMember(builder, field, docs, usedAnchors, paths);
    }
  }

  // 6. Static Methods
  final staticMethods = container.publicStaticMethodsSorted;
  if (staticMethods.isNotEmpty) {
    builder.writeH2('Static Methods');
    for (final method in staticMethods) {
      _renderMethodMember(builder, method, docs, usedAnchors, paths);
    }
  }

  // 7. Constants
  final constants = container.publicConstantFieldsSorted;
  if (constants.isNotEmpty) {
    builder.writeH2('Constants');
    for (final constant in constants) {
      _renderFieldMember(builder, constant, docs, usedAnchors, paths);
    }
  }
}

/// Returns a unique anchor, appending `-2`, `-3`, etc. on collision.
String _uniqueAnchor(String anchor, Set<String> usedAnchors) {
  if (usedAnchors.add(anchor)) return anchor;
  var i = 2;
  while (!usedAnchors.add('$anchor-$i')) {
    i++;
  }
  return '$anchor-$i';
}

/// Renders a single constructor as an h3 member section.
void _renderConstructorMember(
  _MarkdownPageBuilder builder,
  Constructor constructor,
  VitePressDocProcessor docs,
  Set<String> usedAnchors,
  VitePressPathResolver paths,
) {
  final displayName = constructor.displayName;
  final anchor = _uniqueAnchor(_memberAnchor(constructor), usedAnchors);

  builder.writeH3WithAnchor(
    '$displayName()',
    anchor: anchor,
    deprecated: constructor.isDeprecated,
    badges: _buildMemberBadges(constructor),
  );

  builder.writeSignature(_buildLinkedConstructorSignature(constructor, paths));

  _renderMemberDocumentation(builder, constructor, docs, paths,
      memberAnchor: anchor);

  // Source code (only when --include-source is enabled)
  if (constructor.hasSourceCode) {
    builder.writeDetailsContainer(
        'Implementation', '```dart\n${_htmlUnescape(constructor.sourceCode)}\n```');
  }
}

/// Renders a single field/property as an h3 member section.
void _renderFieldMember(
  _MarkdownPageBuilder builder,
  Field field,
  VitePressDocProcessor docs,
  Set<String> usedAnchors,
  VitePressPathResolver paths,
) {
  final anchor = _uniqueAnchor(_memberAnchor(field), usedAnchors);

  builder.writeH3WithAnchor(
    field.name,
    anchor: anchor,
    deprecated: field.isDeprecated,
    badges: _buildMemberBadges(field),
  );

  builder.writeSignature(_buildLinkedFieldSignature(field, paths));

  _renderMemberDocumentation(builder, field, docs, paths,
      memberAnchor: anchor);

  // Source code (only when --include-source is enabled)
  if (field.hasSourceCode) {
    builder.writeDetailsContainer(
        'Implementation', '```dart\n${_htmlUnescape(field.sourceCode)}\n```');
  }
}

/// Renders a single method or operator as an h3 member section.
void _renderMethodMember(
  _MarkdownPageBuilder builder,
  Method method,
  VitePressDocProcessor docs,
  Set<String> usedAnchors,
  VitePressPathResolver paths,
) {
  final anchor = _uniqueAnchor(_memberAnchor(method), usedAnchors);

  // Display name: for operators, use the full name like "operator =="
  // For methods, append "()" to indicate it's callable
  final displaySuffix = '()';
  final displayName = '${method.name}$displaySuffix';

  builder.writeH3WithAnchor(
    displayName,
    anchor: anchor,
    deprecated: method.isDeprecated,
    badges: _buildMemberBadges(method),
  );

  builder.writeSignature(_buildLinkedCallableSignature(method, paths));

  _renderMemberDocumentation(builder, method, docs, paths,
      memberAnchor: anchor);

  // Source code (only when --include-source is enabled)
  if (method.hasSourceCode) {
    builder.writeDetailsContainer(
        'Implementation', '```dart\n${_htmlUnescape(method.sourceCode)}\n```');
  }
}

// ---------------------------------------------------------------------------
// Dynamic outline helper.
// ---------------------------------------------------------------------------

/// Computes the VitePress `outline` frontmatter value for a container page.
///
/// When a container (class, enum, mixin, extension, extension type) has more
/// than [threshold] public members, h3 member headings are excluded from the
/// right-hand TOC to prevent overflow (e.g. WebGL with 600+ members).
///
/// Returns `[2, 2]` (h2 only) for large containers and `[2, 3]` (h2 + h3)
/// for smaller ones.
List<int> _outlineForContainer(Container container, {int threshold = 50}) {
  final memberCount =
      (container.hasPublicConstructors
          ? container.publicConstructorsSorted.length
          : 0) +
      container.publicEnumValues.length +
      container.availableInstanceFieldsSorted.length +
      container.availableInstanceMethodsSorted.length +
      container.availableInstanceOperatorsSorted.length +
      container.publicVariableStaticFieldsSorted.length +
      container.publicStaticMethodsSorted.length +
      container.publicConstantFieldsSorted.length;
  return memberCount > threshold ? [2, 2] : [2, 3];
}

// ---------------------------------------------------------------------------
// Public rendering functions.
// ---------------------------------------------------------------------------

/// Renders the package overview page (`api/index.md`).
///
/// Lists all documented libraries with their descriptions.
String renderPackagePage(
  Package package,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();

  builder.writeFrontmatter(
    title: package.name,
    description: 'API documentation for the ${package.name} package',
    outline: false,
  );

  builder.writeH1(package.name);

  // Package documentation (strip leading H1 if it matches the package name
  // to avoid a duplicate heading, since README often starts with # PackageName).
  // Process through processRawDocumentation to convert dartdoc-style .html
  // links to VitePress paths.
  var packageDoc = package.documentation;
  if (packageDoc != null && packageDoc.isNotEmpty) {
    packageDoc = _stripLeadingH1(packageDoc, package.name);
    packageDoc = docs.processRawDocumentation(packageDoc);
    if (packageDoc.isNotEmpty) {
      builder.writeParagraph(packageDoc);
    }
  }

  // Libraries table (filter out stub libraries with no API elements and
  // duplicate internal SDK libraries like `dart.collection`).
  final allLibs = package.libraries.toList();
  final libraries = allLibs
      .where((lib) => lib.isPublic && lib.isDocumented)
      .where(_hasApiElements)
      .where((lib) => !isDuplicateSdkLibrary(lib, allLibs))
      .where((lib) => !isInternalSdkLibrary(lib))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  if (libraries.isNotEmpty) {
    builder.writeH2('Libraries');

    final rows = <List<String>>[];
    for (final lib in libraries) {
      final link = _markdownLink(lib, paths);
      var description = docs.extractOneLineDoc(lib);
      // Fall back to the pubspec.yaml description when the library itself
      // has no doc comment (common for single-library packages).
      if (description.isEmpty) {
        description = package.packageMeta.description;
      }
      rows.add([link, description]);
    }

    builder.writeTable(
      headers: ['Library', 'Description'],
      rows: rows,
    );
  }

  return builder.toString();
}

/// Renders a workspace overview page (`api/index.md`) when multiple local
/// packages are being documented together.
///
/// Shows each local package as a section with its pubspec description and
/// a table of its public libraries.
String renderWorkspaceOverview(
  PackageGraph packageGraph,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();
  final workspaceName = packageGraph.defaultPackageName;

  builder.writeFrontmatter(
    title: workspaceName,
    description: 'API documentation for the $workspaceName workspace',
    outline: [2, 3],
  );

  builder.writeH1(workspaceName);
  builder.writeParagraph(
    'This workspace contains the following packages.',
  );

  // Sort packages by name for deterministic output.
  final localPackages = [...packageGraph.localPackages]
    ..sort((a, b) => a.name.compareTo(b.name));

  builder.writeH2('Packages');

  for (final package in localPackages) {
    // Package sub-heading (h3 with anchor).
    final anchor = package.name.toLowerCase().replaceAll(' ', '-');
    builder.writeH3WithAnchor(package.name, anchor: anchor);

    // Package description from pubspec.yaml.
    final description = package.packageMeta.description;
    if (description.isNotEmpty) {
      builder.writeParagraph(description);
    }

    // Libraries table for this package (filter out stub libraries and
    // duplicate internal SDK libraries).
    final allPackageLibs = package.libraries.toList();
    final libraries = allPackageLibs
        .where((lib) => lib.isPublic && lib.isDocumented)
        .where(_hasApiElements)
        .where((lib) => !isDuplicateSdkLibrary(lib, allPackageLibs))
        .where((lib) => !isInternalSdkLibrary(lib))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    if (libraries.isNotEmpty) {
      final rows = <List<String>>[];
      for (final lib in libraries) {
        final link = _markdownLink(lib, paths);
        var libDescription = docs.extractOneLineDoc(lib);
        if (libDescription.isEmpty) {
          libDescription = package.packageMeta.description;
        }
        rows.add([link, libDescription]);
      }

      builder.writeTable(
        headers: ['Library', 'Description'],
        rows: rows,
      );
    }
  }

  return builder.toString();
}

/// Renders a library overview page (`api/<dirName>/index.md`).
///
/// Groups elements by kind (Classes, Exceptions, Enums, etc.) with tables
/// using `extractOneLineDoc()` for descriptions.
String renderLibraryPage(
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();

  builder.writeFrontmatter(
    title: library.name,
    description: 'API documentation for the ${library.name} library',
    outline: [2, 3],
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(library.name);

  // Library documentation (strip leading H1 if it matches the library name
  // to avoid a duplicate heading, since library doc comments sometimes start
  // with `# LibraryName`).
  var libDoc = docs.processDocumentation(library);
  if (libDoc.isNotEmpty) {
    libDoc = _stripLeadingH1(libDoc, library.name);
    builder.writeParagraph(libDoc);
  }

  // Element groups in specified order
  _renderLibraryOverviewTable(
    builder,
    'Classes',
    library.publicClassesSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Exceptions',
    library.publicExceptionsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Enums',
    library.publicEnumsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Mixins',
    library.publicMixinsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  // Extensions: include "on Type" column
  _renderExtensionsTable(builder, library.publicExtensionsSorted, paths, docs);

  _renderLibraryOverviewTable(
    builder,
    'Extension Types',
    library.publicExtensionTypesSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Functions',
    library.publicFunctionsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Properties',
    library.publicPropertiesSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Constants',
    library.publicConstantsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Typedefs',
    library.publicTypedefsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  return builder.toString();
}

/// Renders a class page with all members embedded.
String renderClassPage(
  Class clazz,
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();
  final nameWithGenerics = plainNameWithGenerics(clazz);
  final category = clazz.isErrorOrException ? 'Exceptions' : 'Classes';

  builder.writeFrontmatter(
    title: nameWithGenerics,
    description:
        'API documentation for $nameWithGenerics class from ${library.name}',
    outline: _outlineForContainer(clazz),
    category: category,
    library: library.name,
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(
    nameWithGenerics,
    deprecated: clazz.isDeprecated,
    badges: _buildModifierBadges(clazz),
  );

  // Declaration line (linked)
  builder.writeSignature(_buildLinkedContainerDeclaration(clazz, paths));

  // Deprecation notice
  if (clazz.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(clazz));
  }

  // Annotations
  _renderAnnotations(builder, clazz);

  // Documentation
  final doc = docs.processDocumentation(clazz);
  builder.writeParagraph(doc);

  // Source link
  _renderSourceLink(builder, clazz);

  // Inheritance chain
  _renderInheritanceChain(builder, clazz, paths);

  // Implemented types
  _renderImplementedTypes(builder, clazz, paths);

  // Mixed-in types
  _renderMixedInTypes(builder, clazz, paths);

  // Implementers
  _renderImplementors(builder, clazz, paths);

  // Available Extensions
  _renderAvailableExtensions(builder, clazz, paths);

  // All members
  _renderContainerMembers(builder, clazz, docs, paths);

  return builder.toString();
}

/// Renders an enum page with enum values and all members embedded.
String renderEnumPage(
  Enum enumeration,
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();
  final nameWithGenerics = plainNameWithGenerics(enumeration);

  builder.writeFrontmatter(
    title: nameWithGenerics,
    description:
        'API documentation for $nameWithGenerics enum from ${library.name}',
    outline: _outlineForContainer(enumeration),
    category: 'Enums',
    library: library.name,
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(
    nameWithGenerics,
    deprecated: enumeration.isDeprecated,
    badges: _buildModifierBadges(enumeration),
  );

  // Declaration line (linked)
  builder.writeSignature(_buildLinkedContainerDeclaration(enumeration, paths));

  // Deprecation notice
  if (enumeration.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(enumeration));
  }

  // Annotations
  _renderAnnotations(builder, enumeration);

  // Documentation
  final doc = docs.processDocumentation(enumeration);
  builder.writeParagraph(doc);

  // Source link
  _renderSourceLink(builder, enumeration);

  // Inheritance chain
  _renderInheritanceChain(builder, enumeration, paths);

  // Implemented types
  _renderImplementedTypes(builder, enumeration, paths);

  // Mixed-in types
  _renderMixedInTypes(builder, enumeration, paths);

  // Implementers
  _renderImplementors(builder, enumeration, paths);

  // Available Extensions
  _renderAvailableExtensions(builder, enumeration, paths);

  // Enum values section (before other members)
  final enumValues = enumeration.publicEnumValues;
  if (enumValues.isNotEmpty) {
    builder.writeH2('Values');
    for (final value in enumValues) {
      final anchor = 'value-${value.name.toLowerCase()}';
      builder.writeH3WithAnchor(
        value.name,
        anchor: anchor,
        deprecated: value.isDeprecated,
      );
      if (value.isDeprecated) {
        builder.writeDeprecationNotice(_extractDeprecationMessage(value));
      }
      final valueDoc = docs.processDocumentation(value);
      builder.writeParagraph(valueDoc);
    }
  }

  // Standard container members
  _renderContainerMembers(builder, enumeration, docs, paths);

  return builder.toString();
}

/// Renders a mixin page with superclass constraints and all members embedded.
String renderMixinPage(
  Mixin mixin_,
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();
  final nameWithGenerics = plainNameWithGenerics(mixin_);

  builder.writeFrontmatter(
    title: nameWithGenerics,
    description:
        'API documentation for $nameWithGenerics mixin from ${library.name}',
    outline: _outlineForContainer(mixin_),
    category: 'Mixins',
    library: library.name,
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(
    nameWithGenerics,
    deprecated: mixin_.isDeprecated,
    badges: _buildModifierBadges(mixin_),
  );

  // Declaration line (linked)
  builder.writeSignature(_buildLinkedMixinDeclaration(mixin_, paths));

  // Deprecation notice
  if (mixin_.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(mixin_));
  }

  // Annotations
  _renderAnnotations(builder, mixin_);

  // Documentation
  final doc = docs.processDocumentation(mixin_);
  builder.writeParagraph(doc);

  // Source link
  _renderSourceLink(builder, mixin_);

  // Inheritance chain
  _renderInheritanceChain(builder, mixin_, paths);

  // Implemented types
  _renderImplementedTypes(builder, mixin_, paths);

  // Mixed-in types
  _renderMixedInTypes(builder, mixin_, paths);

  // Implementers
  _renderImplementors(builder, mixin_, paths);

  // Available Extensions
  _renderAvailableExtensions(builder, mixin_, paths);

  // Superclass constraints
  final constraints = mixin_.publicSuperclassConstraints.toList();
  if (constraints.isNotEmpty) {
    builder.writeInfoContainer(
      'Superclass Constraints',
      constraints.map((c) => escapeGenerics(c.nameWithGenericsPlain)).toList(),
    );
  }

  // Standard container members
  _renderContainerMembers(builder, mixin_, docs, paths);

  return builder.toString();
}

/// Renders an extension page with extended type and all members embedded.
String renderExtensionPage(
  Extension ext,
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();
  final nameWithGenerics = plainNameWithGenerics(ext);

  builder.writeFrontmatter(
    title: nameWithGenerics,
    description:
        'API documentation for $nameWithGenerics extension from ${library.name}',
    outline: _outlineForContainer(ext),
    category: 'Extensions',
    library: library.name,
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(nameWithGenerics, deprecated: ext.isDeprecated);

  // Declaration line (linked)
  builder.writeSignature(_buildLinkedExtensionDeclaration(ext, paths));

  // Deprecation notice
  if (ext.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(ext));
  }

  // Annotations
  _renderAnnotations(builder, ext);

  // Documentation
  final doc = docs.processDocumentation(ext);
  builder.writeParagraph(doc);

  // Source link
  _renderSourceLink(builder, ext);

  // All members
  _renderContainerMembers(builder, ext, docs, paths);

  return builder.toString();
}

/// Renders an extension type page with representation type and all members
/// embedded.
String renderExtensionTypePage(
  ExtensionType et,
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();
  final nameWithGenerics = plainNameWithGenerics(et);

  builder.writeFrontmatter(
    title: nameWithGenerics,
    description: 'API documentation for $nameWithGenerics extension type '
        'from ${library.name}',
    outline: _outlineForContainer(et),
    category: 'Extension Types',
    library: library.name,
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(
    nameWithGenerics,
    deprecated: et.isDeprecated,
    badges: _buildModifierBadges(et),
  );

  // Declaration line (linked)
  builder.writeSignature(_buildLinkedExtensionTypeDeclaration(et, paths));

  // Deprecation notice
  if (et.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(et));
  }

  // Annotations
  _renderAnnotations(builder, et);

  // Documentation
  final doc = docs.processDocumentation(et);
  builder.writeParagraph(doc);

  // Source link
  _renderSourceLink(builder, et);

  // Implementers
  _renderImplementors(builder, et, paths);

  // All members (including constructors via Constructable)
  _renderContainerMembers(builder, et, docs, paths);

  return builder.toString();
}

/// Renders a top-level function page.
String renderFunctionPage(
  ModelFunction func,
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();
  final nameWithGenerics = plainNameWithGenerics(func);

  builder.writeFrontmatter(
    title: '$nameWithGenerics function',
    description: 'API documentation for the $nameWithGenerics function '
        'from ${library.name}',
    outline: false,
    category: 'Functions',
    library: library.name,
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(nameWithGenerics, deprecated: func.isDeprecated);

  // Signature
  builder.writeSignature(_buildLinkedCallableSignature(func, paths));

  // Deprecation notice
  if (func.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(func));
  }

  // Annotations
  _renderAnnotations(builder, func);

  // Documentation
  final doc = docs.processDocumentation(func);
  builder.writeParagraph(doc);

  // Source link
  _renderSourceLink(builder, func);

  return builder.toString();
}

/// Renders a top-level property or constant page.
String renderPropertyPage(
  TopLevelVariable prop,
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();

  final kindLabel = prop.isConst ? 'constant' : 'property';

  final sidebarKind = prop.isConst ? 'Constants' : 'Properties';

  builder.writeFrontmatter(
    title: '${prop.name} $kindLabel',
    description: 'API documentation for the ${prop.name} $kindLabel '
        'from ${library.name}',
    outline: false,
    category: sidebarKind,
    library: library.name,
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(prop.name, deprecated: prop.isDeprecated);

  // Signature
  builder.writeSignature(_buildLinkedPropertySignature(prop, paths));

  // Deprecation notice
  if (prop.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(prop));
  }

  // Annotations
  _renderAnnotations(builder, prop);

  // Documentation
  final doc = docs.processDocumentation(prop);
  builder.writeParagraph(doc);

  // Source link
  _renderSourceLink(builder, prop);

  return builder.toString();
}

/// Renders a typedef page.
String renderTypedefPage(
  Typedef td,
  Library library,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();
  final nameWithGenerics = plainNameWithGenerics(td);

  builder.writeFrontmatter(
    title: '$nameWithGenerics typedef',
    description: 'API documentation for the $nameWithGenerics typedef '
        'from ${library.name}',
    outline: false,
    category: 'Typedefs',
    library: library.name,
  );

  builder.writeBreadcrumbComponent();

  builder.writeH1(nameWithGenerics, deprecated: td.isDeprecated);

  // Typedef declaration
  final sig = StringBuffer(
      '<span class="kw">typedef</span> <span class="fn">${_htmlEsc(nameWithGenerics)}</span> = ');

  if (td is FunctionTypedef) {
    // Function typedef: show the return type and parameter types
    sig.write(_renderTypeLinked(td.modelType.returnType, paths));
    sig.write(' <span class="type">Function</span>');
    final prefixLength = _stripHtmlForLength(sig.toString());
    sig.write(_buildLinkedParameterSignature(td.parameters, paths,
        prefixLength: prefixLength));
  } else {
    // Type alias (ClassTypedef, GeneralizedTypedef)
    sig.write(_renderTypeLinked(td.modelType, paths));
  }

  builder.writeSignature(sig.toString());

  // Deprecation notice
  if (td.isDeprecated) {
    builder.writeDeprecationNotice(_extractDeprecationMessage(td));
  }

  // Documentation
  final doc = docs.processDocumentation(td);
  builder.writeParagraph(doc);

  return builder.toString();
}

/// Renders a category/topic page.
String renderCategoryPage(
  Category cat,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  final builder = _MarkdownPageBuilder();

  builder.writeFrontmatter(
    title: cat.name,
    description: 'API documentation for the ${cat.name} topic',
    outline: [2, 3],
  );

  builder.writeH1(cat.name);

  // Category documentation (processed through doc processor for directives)
  final catDoc = docs.processRawDocumentation(cat.documentation);
  if (catDoc.isNotEmpty) {
    builder.writeParagraph(catDoc);
  }

  // Element groups (same order as library pages)
  _renderLibraryOverviewTable(
    builder,
    'Classes',
    cat.publicClassesSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Exceptions',
    cat.publicExceptionsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Enums',
    cat.publicEnumsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Mixins',
    cat.publicMixinsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderExtensionsTable(builder, cat.publicExtensionsSorted, paths, docs);

  _renderLibraryOverviewTable(
    builder,
    'Extension Types',
    cat.publicExtensionTypesSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Functions',
    cat.publicFunctionsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Properties',
    cat.publicPropertiesSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Constants',
    cat.publicConstantsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  _renderLibraryOverviewTable(
    builder,
    'Typedefs',
    cat.publicTypedefsSorted.cast<Documentable>(),
    paths,
    docs,
  );

  return builder.toString();
}

// ---------------------------------------------------------------------------
// Private helpers.
// ---------------------------------------------------------------------------

/// Renders an extensions table with the special "on Type" column.
void _renderExtensionsTable(
  _MarkdownPageBuilder builder,
  List<Extension> extensions,
  VitePressPathResolver paths,
  VitePressDocProcessor docs,
) {
  if (extensions.isEmpty) return;

  builder.writeH2('Extensions');
  final rows = <List<String>>[];
  for (final ext in extensions) {
    final link = _markdownLink(ext, paths);
    final onType = ext.extendedElement.nameWithGenericsPlain;
    final oneLineDoc = docs.extractOneLineDoc(ext);
    final isDeprecated = ext.isDeprecated;
    final nameCell = isDeprecated ? '~~$link~~' : link;
    final descCell = isDeprecated && oneLineDoc.isNotEmpty
        ? '**Deprecated.** $oneLineDoc'
        : oneLineDoc;
    rows.add([nameCell, escapeGenerics(onType), descCell]);
  }
  builder.writeTable(
    headers: ['Extension', 'on', 'Description'],
    rows: rows,
  );
}

// Plain-text mixin/extension-type declarations (kept for potential future use).
//
// String _buildMixinDeclaration(Mixin mixin_) { ... }
// String _buildExtensionTypeDeclaration(ExtensionType et) { ... }

/// Returns `true` if the library has any public API elements (classes,
/// functions, enums, etc.).
///
/// Stub libraries (e.g. `dart.core` forwarding to `dart:core`) pass the
/// `isPublic && isDocumented` filters but contain zero actual elements.
/// This helper detects them so they can be excluded from index pages.
bool _hasApiElements(Library library) {
  return library.publicClassesSorted.isNotEmpty ||
      library.publicExceptionsSorted.isNotEmpty ||
      library.publicEnumsSorted.isNotEmpty ||
      library.publicMixinsSorted.isNotEmpty ||
      library.publicExtensionsSorted.isNotEmpty ||
      library.publicExtensionTypesSorted.isNotEmpty ||
      library.publicFunctionsSorted.isNotEmpty ||
      library.publicPropertiesSorted.isNotEmpty ||
      library.publicConstantsSorted.isNotEmpty ||
      library.publicTypedefsSorted.isNotEmpty;
}

/// Strips or downgrades a leading `# title` from documentation text.
///
/// If the H1 matches [expectedTitle], it is stripped entirely to avoid
/// duplication (README files often start with `# PackageName`).
/// If the H1 does NOT match, it is downgraded to H2 (`##`) to prevent
/// multiple H1 headings on the page (only the generator's own H1 should
/// remain as the page title).
String _stripLeadingH1(String text, String expectedTitle) {
  final match = _leadingH1RegExp.firstMatch(text);
  if (match == null) return text;

  final title = match.group(1)!.trim();
  // Normalize hyphens/underscores for comparison, since VitePress treats
  // them identically when generating heading slugs. A README titled
  // "dartdoc-vitepress" should match package name "dartdoc_vitepress".
  final normalizedTitle = title.toLowerCase().replaceAll('-', '_');
  final normalizedExpected = expectedTitle.toLowerCase().replaceAll('-', '_');
  if (normalizedTitle == normalizedExpected) {
    // Duplicate (modulo hyphen/underscore/case) — strip entirely.
    return text.substring(match.end).trimLeft();
  }
  // Different H1 from user content — downshift to H2.
  return '## ${match.group(1)}${text.substring(match.end)}';
}
