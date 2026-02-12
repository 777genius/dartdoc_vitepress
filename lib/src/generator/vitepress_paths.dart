// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dartdoc_vitepress/src/comment_references/parser.dart' show operatorNames;
import 'package:dartdoc_vitepress/src/model/model.dart';
import 'package:dartdoc_vitepress/src/model_utils.dart';
import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// Pre-compiled regular expressions for sanitization methods.
// ---------------------------------------------------------------------------

/// Characters unsafe for file names on Windows/macOS/Linux.
final _unsafeFileChars = RegExp(r'[:<>|?*"/\\]');

/// One or more consecutive hyphens.
final _multiDash = RegExp(r'-+');

/// Leading or trailing hyphen.
final _leadTrailDash = RegExp(r'^-|-$');

/// Any non-alphanumeric character (for anchor sanitization).
final _nonAlphanumeric = RegExp(r'[^a-zA-Z0-9]');

/// Computes VitePress-compatible file paths and URLs for documentation elements.
///
/// This class NEVER reads `element.fileName`, `element.filePath`, or
/// `element.href` as those produce HTML-specific paths. All paths are computed
/// from raw `name` and `library.dirName`.
///
/// In multi-package mode, libraries with conflicting `dirName` values are
/// disambiguated by prefixing with the package name (e.g., `auth_core`
/// instead of just `core`).
class VitePressPathResolver {
  /// Maps library identity to its unique directory name.
  ///
  /// Built by [initFromPackageGraph] to handle multi-package dirName
  /// collisions.
  final Map<Library, String> _libraryDirNames = {};

  /// Maps library **name** to its canonical directory name.
  ///
  /// This is a secondary index built alongside [_libraryDirNames] that
  /// allows [_resolvedDirName] to resolve libraries even when the Library
  /// object instance returned by `element.canonicalLibrary` differs from
  /// the instance stored in [_libraryDirNames]. The Dart SDK analyzer may
  /// create multiple Library objects with the same name (e.g. `dart.io`),
  /// and identity-based map lookups can fail for cross-library references.
  final Map<String, String> _nameBasedDirNames = {};

  /// Maps each library to the set of lowercased sanitized file names of its
  /// container-type elements (classes, enums, mixins, extensions, extension
  /// types).
  ///
  /// Used by [_safeFileName] to detect case-insensitive collisions between
  /// container pages and top-level element pages (e.g., class `Document` vs
  /// top-level property `document` would both map to `document.md` on
  /// case-insensitive file systems like macOS HFS+ and Windows NTFS).
  final Map<Library, Set<String>> _containerNames = {};

  /// Initializes the resolver with unique directory names for all libraries.
  ///
  /// Must be called before any path resolution when documenting multiple
  /// packages. Detects dirName collisions and prefixes with package name.
  ///
  /// Also maps internal SDK library duplicates (e.g. `dart.io`) to their
  /// canonical counterpart's directory name (e.g. `dart-io`), so that
  /// cross-references using internal library names resolve to the correct
  /// paths instead of producing broken `/api/dart.io/` URLs.
  void initFromPackageGraph(PackageGraph packageGraph) {
    _libraryDirNames.clear();
    _nameBasedDirNames.clear();
    _containerNames.clear();

    // Collect all (library, dirName) pairs. Normalize dots to hyphens for
    // SDK-style library names (e.g. `dart.dom.svg` → `dart-dom-svg`) to
    // match the convention used by canonical `dart:xxx` libraries.
    // Non-SDK library names (e.g. `class_modifiers.dart`) keep their dots.
    final allLibraries = <Library>[];
    final dirNameCounts = <String, int>{};

    for (final package in packageGraph.localPackages) {
      for (final library in package.publicLibrariesSorted) {
        allLibraries.add(library);
        final normalized = _normalizeDots(library.dirName);
        dirNameCounts[normalized] =
            (dirNameCounts[normalized] ?? 0) + 1;
      }
    }

    // Assign unique dir names: prefix with package name only on collision.
    for (final library in allLibraries) {
      final baseName = _normalizeDots(library.dirName);
      if (dirNameCounts[baseName]! > 1) {
        _libraryDirNames[library] = '${library.package.name}_$baseName';
      } else {
        _libraryDirNames[library] = baseName;
      }
    }

    // Map internal SDK library duplicates to their canonical counterpart's
    // directory name. The Dart SDK analyzer creates two Library objects per
    // library: canonical (`dart:io` → dirName `dart-io`) and internal
    // (`dart.io` → dirName `dart.io`). Doc comment cross-references often
    // resolve to elements whose canonical library is the internal variant,
    // producing broken paths like `/api/dart.io/` instead of `/api/dart-io/`.
    //
    // Build a name→dirName index of canonical libraries, then assign the
    // canonical dirName to each internal duplicate.
    final canonicalDirNames = <String, String>{};
    for (final library in allLibraries) {
      if (library.name.contains(':')) {
        canonicalDirNames[library.name] = _libraryDirNames[library]!;
      }
    }

    for (final package in packageGraph.localPackages) {
      for (final library in package.libraries) {
        // Skip libraries already mapped (canonical/public libraries).
        if (_libraryDirNames.containsKey(library)) continue;

        final name = library.name;
        if (!name.startsWith('dart.')) continue;

        // Heuristic 1: `dart.xxx` → `dart:xxx`
        final directCanonical = 'dart:${name.substring('dart.'.length)}';
        if (canonicalDirNames.containsKey(directCanonical)) {
          _libraryDirNames[library] = canonicalDirNames[directCanonical]!;
          continue;
        }

        // Heuristic 2: `dart.dom.xxx` → `dart:xxx`
        if (name.startsWith('dart.dom.')) {
          final domCanonical = 'dart:${name.substring('dart.dom.'.length)}';
          if (canonicalDirNames.containsKey(domCanonical)) {
            _libraryDirNames[library] = canonicalDirNames[domCanonical]!;
            continue;
          }
        }

        // No canonical counterpart (e.g. `dart._http`, `dart._internal`).
        // Leave unmapped — _resolvedDirName() will fall back to library.dirName
        // and _libraryDirName() will return null for non-local packages,
        // causing the reference to render as inline code.
      }
    }

    // Build a name-based secondary index from all mapped libraries.
    // This allows _resolvedDirName() to resolve libraries by name when the
    // Library object instance doesn't match (e.g. canonicalLibrary returns
    // a different instance than the one iterated here).
    for (final entry in _libraryDirNames.entries) {
      _nameBasedDirNames[entry.key.name] = entry.value;
    }

    // Build the set of lowercased container names per library for
    // case-insensitive collision detection in _safeFileName().
    for (final package in packageGraph.localPackages) {
      for (final lib in package.libraries.whereDocumented) {
        final names = <String>{};
        for (final c in lib.classesAndExceptions.whereDocumentedIn(lib)) {
          names.add(sanitizeFileName(c.name).toLowerCase());
        }
        for (final e in lib.enums.whereDocumentedIn(lib)) {
          names.add(sanitizeFileName(e.name).toLowerCase());
        }
        for (final m in lib.mixins.whereDocumentedIn(lib)) {
          names.add(sanitizeFileName(m.name).toLowerCase());
        }
        for (final x in lib.extensions.whereDocumentedIn(lib)) {
          names.add(sanitizeFileName(x.name).toLowerCase());
        }
        for (final xt in lib.extensionTypes.whereDocumentedIn(lib)) {
          names.add(sanitizeFileName(xt.name).toLowerCase());
        }
        _containerNames[lib] = names;
      }
    }
  }

  /// Returns the collision-safe directory name for [library].
  ///
  /// Uses the mapping from [initFromPackageGraph] if available, otherwise
  /// falls back to [Library.dirName]. This is the public accessor for use
  /// by the sidebar generator.
  String dirNameFor(Library library) => _resolvedDirName(library);

  /// Returns the file path (relative to output root) for a documentation page.
  ///
  /// Returns `null` for member-level elements that do not have their own page
  /// (constructors, methods, fields, operators) -- these are rendered as
  /// anchors on their container's page.
  ///
  /// Also returns `null` for elements that have no page at all (parameters,
  /// type parameters, dynamic, Never).
  ///
  /// Examples:
  /// - Package: `api/index.md`
  /// - Library: `api/modularity_core/index.md`
  /// - Class: `api/modularity_core/SimpleBinder.md`
  /// - Category: `topics/MyTopic.md`
  String? filePathFor(Documentable element) {
    if (element is Package) {
      return 'api/index.md';
    }

    if (element is Category) {
      return 'topics/${sanitizeFileName(element.name)}.md';
    }

    if (element is Library) {
      if (isInternalSdkLibrary(element)) return null;
      return 'api/${_resolvedDirName(element)}/index.md';
    }

    // Elements that never have their own pages (parameters, type parameters,
    // dynamic, Never).
    if (element is HasNoPage) {
      return null;
    }

    // Member-level elements do not have their own pages.
    if (_isMemberElement(element)) {
      return null;
    }

    // Container-level and top-level elements get their own pages.
    if (element is ModelElement) {
      if (!element.isPublic) return null;
      final dirName = _libraryDirName(element);
      if (dirName == null) return null;
      final fileName = _safeFileName(element.name, element);
      return 'api/$dirName/$fileName.md';
    }

    return null;
  }

  /// Returns the URL path for linking to an element's page.
  ///
  /// For member-level elements, returns the URL of their container page
  /// (without anchor). Use [linkFor] for a full URL including anchors.
  ///
  /// Returns `null` for elements that have no page (parameters, type
  /// parameters, dynamic, Never).
  ///
  /// Examples:
  /// - Package: `/api/`
  /// - Library: `/api/modularity_core/`
  /// - Class: `/api/modularity_core/SimpleBinder`
  /// - Category: `/topics/MyTopic`
  String? urlFor(Documentable element) {
    if (element is Package) {
      return '/api/';
    }

    if (element is Category) {
      return '/topics/${sanitizeFileName(element.name)}';
    }

    if (element is Library) {
      if (isInternalSdkLibrary(element)) return null;
      return '/api/${_resolvedDirName(element)}/';
    }

    // Elements that never have their own pages.
    if (element is HasNoPage) {
      return null;
    }

    // Member-level elements: return the container's URL.
    if (_isMemberElement(element)) {
      final container = _containerOf(element as ModelElement);
      if (container != null) {
        return urlFor(container);
      }
      return null;
    }

    // Container-level and top-level elements.
    if (element is ModelElement) {
      if (!element.isPublic) return null;
      final dirName = _libraryDirName(element);
      if (dirName == null) return null;
      final fileName = _safeFileName(element.name, element);
      return '/api/$dirName/$fileName';
    }

    return null;
  }

  /// Returns the anchor ID for a member element.
  ///
  /// Strips generic type parameters from the name and converts operator
  /// symbols to human-readable names.
  ///
  /// Examples:
  /// - Method `get`: `#get`
  /// - Method `get<T>`: `#get` (generics stripped)
  /// - Operator `operator ==`: `#operator-equals`
  /// - Constructor `SimpleBinder`: `#simplebinder`
  /// - Constructor `SimpleBinder.named`: `#named`
  String? anchorFor(ModelElement element) {
    if (!_isMemberElement(element)) return null;

    if (element is Operator) {
      // Use referenceName which gives the raw operator symbol (e.g., '==')
      // without the 'operator ' prefix.
      final operatorSymbol = element.referenceName;
      final mappedName = operatorNames[operatorSymbol];
      if (mappedName != null) {
        return '#operator-$mappedName';
      }
      // Fallback: sanitize the operator symbol.
      return '#operator-${sanitizeAnchor(operatorSymbol)}';
    }

    // For constructors, prefix with 'ctor-' for unnamed constructors to avoid
    // collision with VitePress auto-generated ID for the class H1 heading.
    if (element is Constructor) {
      final name = stripGenerics(element.referenceName).toLowerCase();
      if (element.isUnnamedConstructor) {
        return '#ctor-$name';
      }
      return '#$name';
    }

    // For enum values, add value- prefix to match renderer's _memberAnchor().
    // Must be checked BEFORE Field because EnumField extends Field.
    if (element is EnumField) {
      final name = stripGenerics(element.name);
      return '#value-${name.toLowerCase()}';
    }

    // For fields, add prop- prefix to match renderer's _memberAnchor().
    if (element is Field) {
      final name = stripGenerics(element.name);
      return '#prop-${name.toLowerCase()}';
    }

    // For accessors (getters/setters resolved from bracket references like
    // [length]), map to the enclosing combo's field anchor with prop- prefix.
    // Strip trailing '=' from setter names (e.g., 'findProxy=' → 'findProxy').
    if (element is Accessor) {
      var name = stripGenerics(element.name);
      if (name.endsWith('=')) {
        name = name.substring(0, name.length - 1);
      }
      return '#prop-${name.toLowerCase()}';
    }

    // For methods, strip generics and lowercase.
    final name = stripGenerics(element.name);
    return '#${name.toLowerCase()}';
  }

  /// Returns the full link URL for any element (container or member).
  ///
  /// For containers: `/api/modularity_core/SimpleBinder`
  /// For members: `/api/modularity_core/SimpleBinder#get`
  /// For packages: `/api/`
  /// For libraries: `/api/modularity_core/`
  /// For categories: `/topics/MyTopic`
  ///
  /// Returns `null` for elements that have no page (parameters, type
  /// parameters, dynamic, Never) -- these are rendered as inline code.
  String? linkFor(Documentable element) {
    // Elements that never have their own pages.
    if (element is HasNoPage) {
      return null;
    }

    if (_isMemberElement(element) && element is ModelElement) {
      final containerUrl = _containerUrl(element);
      if (containerUrl == null) return null;
      final anchor = anchorFor(element);
      if (anchor == null) return containerUrl;
      return '$containerUrl$anchor';
    }
    return urlFor(element);
  }

  /// Returns the library directory name for an element, or `null` if the
  /// element's canonical library is not documented locally.
  ///
  /// Uses `canonicalLibrary` with null-safety for re-exported elements.
  /// Falls back to `library` if `canonicalLibrary` is null.
  ///
  /// Returns `null` for elements whose canonical library belongs to a
  /// non-local package (SDK, external pub packages) so that the caller
  /// can fall back to the model's built-in remote `href`.
  String? _libraryDirName(Documentable element) {
    if (element is Library) {
      if (element.package.documentedWhere != DocumentLocation.local) {
        return null;
      }
      if (isInternalSdkLibrary(element)) return null;
      return _resolvedDirName(element);
    }
    if (element is ModelElement) {
      final lib = element.canonicalLibrary ?? element.library;
      if (lib == null) return null;
      if (lib.package.documentedWhere != DocumentLocation.local) {
        return null;
      }
      if (isInternalSdkLibrary(lib)) return null;
      return _resolvedDirName(lib);
    }
    return null;
  }

  /// Returns the unique directory name for [library], using the collision-safe
  /// mapping from [initFromPackageGraph] if available, otherwise falling back
  /// to a name-based lookup, and finally to the library's own [Library.dirName].
  ///
  /// The name-based fallback handles the case where `element.canonicalLibrary`
  /// returns a Library instance that is different from the one stored in
  /// [_libraryDirNames] (the Dart SDK analyzer may create multiple Library
  /// objects with the same name, e.g. `dart.io`).
  String _resolvedDirName(Library library) {
    return _libraryDirNames[library] ??
        _nameBasedDirNames[library.name] ??
        _normalizeDots(library.dirName);
  }

  /// Returns a safe file name for an element.
  ///
  /// 1. Sanitizes characters that are invalid on common file systems
  ///    (Windows, macOS, Linux).
  /// 2. Avoids collision with `index.md` (used for library overview pages)
  ///    by appending a kind-based suffix.
  /// 3. Avoids case-insensitive collision between top-level elements and
  ///    container-type elements in the same library. On macOS (HFS+) and
  ///    Windows (NTFS), `Document.md` and `document.md` resolve to the same
  ///    physical file. When a top-level property/function/typedef name
  ///    differs from a container name only by case, append a kind suffix
  ///    (e.g., `document-property`).
  ///
  /// Examples:
  /// - Class named "index" -> `index-class`
  /// - Class named "MyClass" -> `MyClass` (no suffix needed)
  /// - Class named `Foo<Bar>` -> `Foo` (generics stripped)
  /// - Top-level property "document" with class "Document" -> `document-property`
  String _safeFileName(String name, Documentable element) {
    var safe = sanitizeFileName(name);
    if (safe.toLowerCase() == 'index') {
      // Collision avoidance: append element kind suffix.
      safe = '$safe-${_kindSuffix(element)}';
    }

    // Case-insensitive collision avoidance for top-level elements whose
    // sanitized name matches a container name in the same library.
    // Only top-level non-container elements need disambiguation; container
    // types keep their original casing and the top-level element yields.
    if (element is TopLevelVariable ||
        element is ModelFunction ||
        element is Typedef) {
      final lib = _resolveLibrary(element);
      if (lib != null) {
        final containerSet = _containerNames[lib];
        if (containerSet != null &&
            containerSet.contains(safe.toLowerCase())) {
          safe = '$safe-${_kindSuffix(element)}';
        }
      }
    }

    return safe;
  }

  /// Resolves the canonical (or fallback) library for an element.
  ///
  /// Returns `null` if the element has no associated library.
  Library? _resolveLibrary(Documentable element) {
    if (element is Library) return element;
    if (element is ModelElement) {
      return element.canonicalLibrary ?? element.library;
    }
    return null;
  }

  /// Sanitizes a string for use as a file name.
  ///
  /// Replaces characters that are invalid or problematic on common file
  /// systems with hyphens, then collapses runs of hyphens.
  @visibleForTesting
  static String sanitizeFileName(String name) {
    // Strip generic type parameters first (e.g., `Foo<Bar>` -> `Foo`).
    final angleBracketIndex = name.indexOf('<');
    if (angleBracketIndex != -1) {
      name = name.substring(0, angleBracketIndex);
    }
    // Replace chars problematic on Windows/macOS/Linux: : < > | ? * " / \
    return name
        .replaceAll(_unsafeFileChars, '-')
        .replaceAll(_multiDash, '-')
        .replaceAll(_leadTrailDash, '');
  }

  /// Returns a kind-based suffix string for collision avoidance.
  String _kindSuffix(Documentable element) {
    if (element is Class) return 'class';
    if (element is Enum) return 'enum';
    if (element is Mixin) return 'mixin';
    if (element is Extension) return 'extension';
    if (element is ExtensionType) return 'extension-type';
    if (element is ModelFunction) return 'function';
    if (element is TopLevelVariable) return 'property';
    if (element is Typedef) return 'typedef';
    return 'element';
  }

  /// Returns true if the element is a member-level element that should be
  /// rendered as an anchor on its container's page rather than having its
  /// own page.
  ///
  /// Includes [Accessor] (getters/setters) which are resolved via bracket
  /// references like `[imports]` and should link to the corresponding field's
  /// anchor on the container page.
  bool _isMemberElement(Documentable element) {
    return element is Method ||
        element is Constructor ||
        element is Field ||
        element is Accessor;
  }

  /// Returns the enclosing container of a member element.
  Container? _containerOf(ModelElement element) {
    if (element is ContainerMember) {
      return element.enclosingElement;
    }
    return null;
  }

  /// Returns the URL for the container page of a member element.
  String? _containerUrl(ModelElement element) {
    final container = _containerOf(element);
    if (container == null) return null;
    return urlFor(container);
  }

  /// Strips generic type parameters from a name.
  ///
  /// `get<T>` -> `get`
  /// `Map<String, int>` -> `Map`
  /// `SimpleBinder` -> `SimpleBinder` (unchanged)
  @visibleForTesting
  static String stripGenerics(String name) {
    final angleBracketIndex = name.indexOf('<');
    if (angleBracketIndex == -1) return name;
    return name.substring(0, angleBracketIndex);
  }

  /// Normalizes dots to hyphens in SDK-style library directory names.
  ///
  /// Only affects names starting with `dart.` (SDK namespace separators like
  /// `dart.dom.svg` → `dart-dom-svg`). Non-SDK library names (e.g.
  /// `class_modifiers.dart`) are returned unchanged.
  static String _normalizeDots(String dirName) {
    if (dirName.startsWith('dart.')) {
      return dirName.replaceAll('.', '-');
    }
    return dirName;
  }

  /// Sanitizes a string for use as an anchor ID.
  ///
  /// Replaces non-alphanumeric characters with hyphens and lowercases.
  static String sanitizeAnchor(String value) {
    return value
        .replaceAll(_nonAlphanumeric, '-')
        .replaceAll(_multiDash, '-')
        .replaceAll(_leadTrailDash, '')
        .toLowerCase();
  }
}

/// Returns `true` if the library is a dot-prefixed SDK duplicate that has a
/// canonical colon-prefixed counterpart (e.g. `dart.io` → `dart:io`).
///
/// These internal library objects are created by the Dart SDK analyzer alongside
/// the canonical versions. They contain no unique content and should be
/// filtered out to avoid duplicate sidebar entries and broken paths.
///
/// Libraries that start with `dart.` but have NO canonical counterpart
/// (e.g. `dart._wasm`, `dart.dom.svg`, `dart.mirrors`) -- those must be kept.
///
/// Mapping heuristics:
/// 1. `dart.xxx` -> `dart:xxx` (direct replacement of first `.` with `:`)
/// 2. `dart.dom.html` -> `dart:html` (strip `.dom.` prefix)
bool isDuplicateSdkLibrary(Library lib, Iterable<Library> allLibraries) {
  final name = lib.name;

  // Canonical libraries (containing `:`) are never duplicates.
  if (!name.contains('.') || name.contains(':')) return false;

  // Only handle `dart.xxx` prefixed names.
  if (!name.startsWith('dart.')) return false;

  // Build the set of canonical library names for fast lookup.
  final canonicalNames = <String>{
    for (final l in allLibraries)
      if (l.name.contains(':')) l.name,
  };

  // Heuristic 1: direct mapping `dart.xxx` -> `dart:xxx`.
  final directCanonical = 'dart:${name.substring('dart.'.length)}';
  if (canonicalNames.contains(directCanonical)) return true;

  // Heuristic 2: `dart.dom.xxx` -> `dart:xxx` (strip `.dom.`).
  if (name.startsWith('dart.dom.')) {
    final domCanonical = 'dart:${name.substring('dart.dom.'.length)}';
    if (canonicalNames.contains(domCanonical)) return true;
  }

  return false;
}

/// Returns `true` if the library is an internal SDK or runtime library
/// that should not appear in public API documentation.
///
/// These libraries pass dartdoc's `isPublic && isDocumented` checks but are
/// not intended for external use. The official api.dart.dev excludes them.
///
/// Detected patterns:
/// - Names starting with `_` (private: `_internal_js_runtime_*`)
/// - Names containing `._` (private sub-library: `dart._http`, `dart2js._js_primitives`)
/// - Known SDK/compiler runtime libraries without underscore prefix
bool isInternalSdkLibrary(Library lib) {
  final name = lib.name;
  // Private libraries (Dart convention: leading underscore).
  if (name.startsWith('_')) return true;
  // Private sub-libraries (e.g., dart._http, dart2js._js_primitives).
  if (name.contains('._')) return true;
  // Known SDK/compiler internal libraries without underscore prefix.
  const internalNames = {
    'rti',
    'vmservice_io',
    'metadata',
    'nativewrappers',
    'html_common',
    'dart2js_runtime_metrics',
  };
  if (internalNames.contains(name)) return true;
  return false;
}
